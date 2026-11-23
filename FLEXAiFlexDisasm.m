#import "FLEXAiFlexDisasm.h"

#import "x/Disassembler/UCDisassembler.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_page_size.h>
#import <string.h>
#import <stdlib.h>

// 本文件只做「把 UCDisassembler 的结果翻译成 MCP JSON」，不重复实现反汇编逻辑。
//
// 几个必须守住的点：
//   * capstone 的 csh 是全局单例，cs_disasm 不可并发。UCDisassembler 内部有
//     g_disasmQueue 串行化，本引擎再加一层专属队列，保证 MCP 侧同一时刻只有一次反汇编。
//   * capstone 反汇编是同步阻塞、无中断点，所以「限时」只能靠「限输入」：
//     反汇编区间、单函数上限、函数数量、返回条数全部设硬上限。
//   * UCDisassembler.analyzeFunctionAtAddress:maxSize: 会把 maxSize 一次性反汇编
//     （内部两次 vm_read + cs_disasm），传 65536 对短函数是巨大浪费。这里默认 8 KiB。
//   * 序列化只输出模型真正要用的字段。一条指令的 operand 结构体（类型/立即数/寄存器/
//     偏移/比例）全量导出会让 200 条指令就膨胀到几百 KB，默认不给，verbose=1 才给。

#pragma mark - 常量

static const NSUInteger DXDefaultInstructionBytes = 4 * 1024;
static const NSUInteger DXMaxInstructionBytes     = 64 * 1024;
static const NSUInteger DXDefaultFunctionBytes    = 8 * 1024;
static const NSUInteger DXMaxFunctionBytes        = 32 * 1024;
static const NSUInteger DXDefaultScanBytes        = 32 * 1024;
static const NSUInteger DXMaxScanBytes            = 128 * 1024;
static const NSUInteger DXDefaultScanFunctions    = 32;
static const NSUInteger DXMaxScanFunctions        = 128;
static const NSUInteger DXDefaultLimit            = 200;
static const NSUInteger DXMaxLimit                = 2000;
static const NSUInteger DXDefaultXrefBytes        = 16 * 1024;
static const NSUInteger DXMaxXrefBytes            = 64 * 1024;
static const double     DXScanBudget              = 4.0;

static NSString * const DXErrorUnavailable =
    @"反汇编引擎不可用：capstone 初始化失败，当前只能返回十六进制 dump。";

#pragma mark - 小工具

static NSString *DXHex(uint64_t value) {
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value];
}

static NSString *DXStringArg(NSDictionary *arguments, NSString *key) {
    id value = arguments[key];
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSUInteger DXIntArg(NSDictionary *arguments, NSString *key, NSUInteger fallback, NSUInteger minimum, NSUInteger maximum) {
    id value = arguments[key];
    long long parsed = (long long)fallback;
    if ([value isKindOfClass:NSNumber.class]) {
        parsed = [(NSNumber *)value longLongValue];
    } else if ([value isKindOfClass:NSString.class]) {
        parsed = [(NSString *)value longLongValue];
    }
    if (parsed < (long long)minimum) parsed = (long long)minimum;
    if (parsed > (long long)maximum) parsed = (long long)maximum;
    return (NSUInteger)parsed;
}

static BOOL DXBoolArg(NSDictionary *arguments, NSString *key) {
    id value = arguments[key];
    if (![value isKindOfClass:NSNumber.class]) return NO;
    return [(NSNumber *)value boolValue];
}

// 地址一律按字符串传：JSON number 是 double，超过 2^53 会丢精度。
static BOOL DXParseAddress(NSString *text, uint64_t *out) {
    if (!text.length) return NO;
    const char *raw = text.UTF8String;
    if (!raw || !*raw) return NO;
    while (*raw == ' ') raw++;
    char *end = NULL;
    unsigned long long value = strtoull(raw, &end, 0);
    if (end == raw) return NO;
    if (out) *out = (uint64_t)value;
    return YES;
}

static BOOL DXReadU32(uint64_t address, uint32_t *out) {
    if (address < 0x100000000ULL) return NO;
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         (vm_size_t)sizeof(uint32_t),
                                         (vm_address_t)out,
                                         &outSize);
    return (kr == KERN_SUCCESS && outSize == sizeof(uint32_t));
}

// arm64 / arm64e 的函数序言特征：
//   stp x29, x30, [sp, #-imm]!  → 0xA98003E0 掩码命中，rt=29, rt2=30
//   pacibsp / paciasp          → arm64e 的指针认证序言
static BOOL DXLooksLikePrologue(uint32_t instruction) {
    if ((instruction & 0xFFC003E0) == 0xA98003E0) {
        uint32_t rt  = instruction & 0x1F;
        uint32_t rt2 = (instruction >> 10) & 0x1F;
        if (rt == 29 && rt2 == 30) return YES;
    }
    if (instruction == 0xD503233F) return YES;   // pacibsp
    if (instruction == 0xD503237F) return YES;   // paciasp
    return NO;
}

#pragma mark - 指令序列化

static NSArray<NSString *> *DXInstructionFlags(UCDisasmInstruction *instruction) {
    NSMutableArray<NSString *> *flags = [NSMutableArray array];
    if (instruction.isCall) [flags addObject:@"call"];
    if (instruction.isReturn) [flags addObject:@"ret"];
    if (instruction.isConditionalBranch) [flags addObject:@"cond_jump"];
    // isUnconditionalBranch 对 bl/blr 也为真，所以要排掉 call
    if (instruction.isUnconditionalBranch && !instruction.isCall && !instruction.isReturn) {
        [flags addObject:@"jump"];
    }
    if (instruction.isNop) [flags addObject:@"nop"];
    if (instruction.setsFramePointer) [flags addObject:@"frame"];
    if (instruction.isFunctionStart) [flags addObject:@"new_func"];
    if (instruction.isBasicBlockStart) [flags addObject:@"new_block"];
    if (instruction.isValid) [flags addObject:@"ok"];
    return flags;
}

static NSDictionary *DXOperandJSON(UCDisasmOperand *operand) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    switch (operand.type) {
        case UCDisasmOperandTypeRegister:    entry[@"kind"] = @"reg"; break;
        case UCDisasmOperandTypeImmediate:   entry[@"kind"] = @"imm"; break;
        case UCDisasmOperandTypeMemory:      entry[@"kind"] = @"mem"; break;
        case UCDisasmOperandTypeFPRegister:  entry[@"kind"] = @"fpreg"; break;
        default:                             entry[@"kind"] = @"other"; break;
    }
    if (operand.text.length) entry[@"text"] = operand.text;
    if (operand.registerName.length) entry[@"reg"] = operand.registerName;
    if (operand.type == UCDisasmOperandTypeImmediate) {
        entry[@"value"] = DXHex(operand.immediateValue);
    }
    if (operand.type == UCDisasmOperandTypeMemory) {
        if (operand.memoryBaseReg.length) entry[@"base"] = operand.memoryBaseReg;
        if (operand.memoryIndexReg.length) entry[@"index"] = operand.memoryIndexReg;
        entry[@"offset"] = @(operand.memoryOffset);
        if (operand.memoryScale) entry[@"scale"] = @(operand.memoryScale);
    }
    return entry;
}

static NSDictionary *DXInstructionJSON(UCDisasmInstruction *instruction, BOOL verbose) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"address"] = DXHex(instruction.address);
    if (instruction.size) entry[@"size"] = @(instruction.size);
    entry[@"bytes"] = instruction.bytesHex ?: @"";
    entry[@"text"] = instruction.fullText ?: (instruction.mnemonic ?: @"");

    NSArray<NSString *> *flags = DXInstructionFlags(instruction);
    if (flags.count) entry[@"flags"] = flags;

    if (instruction.isBranch && instruction.branchTarget) {
        entry[@"target"] = DXHex(instruction.branchTarget);
        NSString *targetName = [UCDisassembler symbolNameAtAddress:instruction.branchTarget];
        if (!targetName) targetName = [UCDisassembler objcMethodNameAtAddress:instruction.branchTarget];
        if (targetName.length) entry[@"targetName"] = targetName;
    }

    if (instruction.functionName.length) entry[@"symbol"] = instruction.functionName;
    if (instruction.comment.length) entry[@"comment"] = instruction.comment;
    if (instruction.xrefComment.length) entry[@"xref"] = instruction.xrefComment;

    if (verbose && instruction.operandList.count) {
        NSMutableArray *operands = [NSMutableArray arrayWithCapacity:instruction.operandList.count];
        for (UCDisasmOperand *operand in instruction.operandList) {
            [operands addObject:DXOperandJSON(operand)];
        }
        entry[@"operands"] = operands;
    }
    return entry;
}

#pragma mark - 结果分页

// 分页是硬要求：一个 64 KiB 区间能反汇编出一万六千条指令，
// 全量序列化会把 MCP 响应撑到几 MB，客户端直接超时。
static NSDictionary *DXPagedInstructions(NSArray<UCDisasmInstruction *> *instructions,
                                         NSUInteger offset,
                                         NSUInteger limit,
                                         BOOL verbose) {
    NSUInteger total = instructions.count;
    if (offset >= total) offset = total;
    NSUInteger available = total - offset;
    NSUInteger take = MIN(available, limit);

    NSMutableArray *payload = [NSMutableArray arrayWithCapacity:take];
    for (NSUInteger i = 0; i < take; i++) {
        [payload addObject:DXInstructionJSON(instructions[offset + i], verbose)];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"offset"] = @(offset);
    result[@"limit"] = @(limit);
    result[@"count"] = @(take);
    result[@"total"] = @(total);
    result[@"hasMore"] = @(offset + take < total);
    if (offset + take < total) result[@"nextOffset"] = @(offset + take);
    result[@"instructions"] = payload;
    return result;
}

static NSArray<NSDictionary *> *DXBlocksJSON(UCFunction *function) {
    if (!function.basicBlocks.count) return @[];
    NSMutableArray *blocks = [NSMutableArray arrayWithCapacity:function.basicBlocks.count];
    for (UCBasicBlock *block in function.basicBlocks) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"id"] = @(block.blockId);
        entry[@"start"] = DXHex(block.startAddress);
        entry[@"end"] = DXHex(block.endAddress);
        entry[@"count"] = @(block.instructionCount);
        switch (block.type) {
            case UCBasicBlockTypeEntry:            entry[@"type"] = @"entry"; break;
            case UCBasicBlockTypeExit:             entry[@"type"] = @"exit"; break;
            case UCBasicBlockTypeConditionalTrue:  entry[@"type"] = @"cond_true"; break;
            case UCBasicBlockTypeConditionalFalse: entry[@"type"] = @"cond_false"; break;
            default:                               entry[@"type"] = @"normal"; break;
        }
        if (block.successors.count) {
            NSMutableArray *succ = [NSMutableArray arrayWithCapacity:block.successors.count];
            for (UCBasicBlock *next in block.successors) [succ addObject:@(next.blockId)];
            entry[@"successors"] = succ;
        }
        if (block.predecessors.count) {
            NSMutableArray *pred = [NSMutableArray arrayWithCapacity:block.predecessors.count];
            for (UCBasicBlock *prev in block.predecessors) [pred addObject:@(prev.blockId)];
            entry[@"predecessors"] = pred;
        }
        [blocks addObject:entry];
    }
    return blocks;
}

#pragma mark - 引擎

@interface FLEXAiFlexDisasm ()
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FLEXAiFlexDisasm

+ (instancetype)sharedEngine {
    static FLEXAiFlexDisasm *engine = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [[self alloc] init];
    });
    return engine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 专属串行队列：与 Frida 引擎、MCP 主队列互不阻塞，同时保证 capstone 不被并发调用。
        _queue = dispatch_queue_create("com.hoko20.aiflex3.disasm", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}

+ (BOOL)engineAvailable {
    return [UCDisassembler sharedInstance].isAvailable;
}

+ (NSString *)engineVersion {
    return [UCDisassembler sharedInstance].engineName;
}

+ (NSArray<NSString *> *)supportedOperations {
    return @[@"status", @"at", @"function", @"scan_functions", @"symbol", @"xref", @"objc_method"];
}

- (void)operation:(NSString *)operation
        arguments:(NSDictionary *)arguments
       completion:(void (^)(NSDictionary *, NSString *))completion {
    dispatch_async(self.queue, ^{
        NSString *error = nil;
        NSDictionary *result = nil;
        @try {
            result = [self run:operation arguments:arguments ?: @{} error:&error];
        }
        @catch (NSException *exception) {
            // 反汇编引擎内部有大量指针运算，越界时可能抛 NSRangeException 一类异常。
            // 捕获后转成明确错误，不让异常穿透到 MCP 连接。
            error = [NSString stringWithFormat:@"反汇编异常（%@）：%@",
                     exception.name ?: @"unknown", exception.reason ?: @"无详细信息"];
        }
        if (!error.length && !result) error = @"反汇编未返回结果";
        completion(result, error);
    });
}

#pragma mark - 分发

- (NSDictionary *)run:(NSString *)operation
            arguments:(NSDictionary *)arguments
                error:(NSString **)error {
    if ([operation isEqualToString:@"status"])      return [self opStatus];
    if ([operation isEqualToString:@"at"])           return [self opAt:arguments error:error];
    if ([operation isEqualToString:@"function"])     return [self opFunction:arguments error:error];
    if ([operation isEqualToString:@"scan_functions"]) return [self opScanFunctions:arguments error:error];
    if ([operation isEqualToString:@"symbol"])       return [self opSymbol:arguments error:error];
    if ([operation isEqualToString:@"xref"])         return [self opXref:arguments error:error];
    if ([operation isEqualToString:@"objc_method"])  return [self opObjcMethod:arguments error:error];
    if (error) *error = [@"未知 operation：" stringByAppendingString:operation ?: @""];
    return nil;
}

#pragma mark - status

- (NSDictionary *)opStatus {
    UCDisassembler *engine = [UCDisassembler sharedInstance];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"available"] = @(engine.isAvailable);
    result[@"engine"] = engine.engineName ?: @"unknown";
    result[@"architecture"] = @"arm64";
    result[@"readOnly"] = @YES;
    result[@"operations"] = [FLEXAiFlexDisasm supportedOperations];
    result[@"limits"] = @{
        @"atBytes": @[@(DXDefaultInstructionBytes), @(DXMaxInstructionBytes)],
        @"functionBytes": @[@(DXDefaultFunctionBytes), @(DXMaxFunctionBytes)],
        @"scanBytes": @[@(DXDefaultScanBytes), @(DXMaxScanBytes)],
        @"scanFunctions": @[@(DXDefaultScanFunctions), @(DXMaxScanFunctions)],
        @"instructions": @[@(DXDefaultLimit), @(DXMaxLimit)],
        @"scanBudgetSeconds": @(DXScanBudget)
    };
    if (!engine.isAvailable) result[@"note"] = DXErrorUnavailable;
    return result;
}

#pragma mark - at

- (NSDictionary *)opAt:(NSDictionary *)arguments error:(NSString **)error {
    uint64_t address = 0;
    if (!DXParseAddress(DXStringArg(arguments, @"address"), &address)) {
        if (error) *error = @"需要 address（字符串形式，如 \"0x104a2b000\"）";
        return nil;
    }
    NSUInteger size = DXIntArg(arguments, @"size", DXDefaultInstructionBytes, 4, DXMaxInstructionBytes);
    size &= ~(NSUInteger)3;              // 对齐到 4 字节（AArch64 指令宽度）
    if (size < 4) size = 4;
    NSUInteger offset = DXIntArg(arguments, @"offset", 0, 0, DXMaxLimit * 16);
    NSUInteger limit = DXIntArg(arguments, @"limit", DXDefaultLimit, 1, DXMaxLimit);
    BOOL verbose = DXBoolArg(arguments, @"verbose");

    UCDisassembler *engine = [UCDisassembler sharedInstance];
    if (!engine.isAvailable) {
        if (error) *error = DXErrorUnavailable;
        return nil;
    }

    UCDisasmResult *disassembly = [engine disassembleAtAddress:address size:size];
    if (!disassembly) {
        if (error) *error = [NSString stringWithFormat:
                             @"%@ 起始的 %lu 字节不可读或无法反汇编（地址无效、跨页越界或未映射）",
                             DXHex(address), (unsigned long)size];
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"start"] = DXHex(disassembly.startAddress);
    result[@"size"] = @(size);
    result[@"engine"] = disassembly.engineName ?: @"unknown";
    [result addEntriesFromDictionary:DXPagedInstructions(disassembly.instructions, offset, limit, verbose)];
    return result;
}

#pragma mark - function

- (NSDictionary *)opFunction:(NSDictionary *)arguments error:(NSString **)error {
    uint64_t address = 0;
    if (!DXParseAddress(DXStringArg(arguments, @"address"), &address)) {
        if (error) *error = @"需要 address（字符串形式）";
        return nil;
    }
    NSUInteger maxSize = DXIntArg(arguments, @"max_size", DXDefaultFunctionBytes, 16, DXMaxFunctionBytes);
    NSUInteger offset = DXIntArg(arguments, @"offset", 0, 0, DXMaxLimit * 16);
    NSUInteger limit = DXIntArg(arguments, @"limit", DXDefaultLimit, 1, DXMaxLimit);
    BOOL verbose = DXBoolArg(arguments, @"verbose");

    UCDisassembler *engine = [UCDisassembler sharedInstance];
    if (!engine.isAvailable) {
        if (error) *error = DXErrorUnavailable;
        return nil;
    }

    UCFunction *function = [engine analyzeFunctionAtAddress:address maxSize:maxSize];
    if (!function || function.instructions.count == 0) {
        if (error) *error = [NSString stringWithFormat:
                             @"%@ 处未能识别出函数（地址不可读，或 %lu 字节内没有函数序言）",
                             DXHex(address), (unsigned long)maxSize];
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"start"] = DXHex(function.startAddress);
    result[@"end"] = DXHex(function.endAddress);
    result[@"size"] = @(function.size);
    result[@"name"] = function.name ?: @"";
    if (function.demangledName.length) result[@"demangled"] = function.demangledName;
    result[@"basicBlockCount"] = @(function.basicBlockCount);
    result[@"instructionCount"] = @(function.instructions.count);
    if (function.callSites.count) {
        NSMutableArray *sites = [NSMutableArray array];
        for (NSNumber *number in function.callSites) [sites addObject:DXHex(number.unsignedLongLongValue)];
        result[@"callSites"] = sites;
    }
    if (function.calledFrom.count) {
        NSMutableArray *callers = [NSMutableArray array];
        for (NSNumber *number in function.calledFrom) [callers addObject:DXHex(number.unsignedLongLongValue)];
        result[@"calledFrom"] = callers;
    }
    result[@"blocks"] = DXBlocksJSON(function);
    [result addEntriesFromDictionary:DXPagedInstructions(function.instructions, offset, limit, verbose)];
    return result;
}

#pragma mark - scan_functions

// 这里没有直接调 scanFunctionsInRange:size:，因为它内部对每个 prologue 命中都调用
// analyzeFunctionAtAddress:maxSize:65536——一个 32 KiB 区间若有 50 个函数，就是 50 次
// 64 KiB 的 vm_read + cs_disasm，耗时不可控。这里自己扫，单函数上限默认 8 KiB，
// 并加时间预算与函数数量上限，超限即停并标 truncated。
- (NSDictionary *)opScanFunctions:(NSDictionary *)arguments error:(NSString **)error {
    uint64_t start = 0;
    if (!DXParseAddress(DXStringArg(arguments, @"address"), &start)) {
        if (error) *error = @"需要 address（区间起始地址，字符串形式）";
        return nil;
    }
    NSUInteger size = DXIntArg(arguments, @"size", DXDefaultScanBytes, 4, DXMaxScanBytes);
    size &= ~(NSUInteger)3;
    if (size < 4) size = 4;
    NSUInteger maxFunctions = DXIntArg(arguments, @"limit", DXDefaultScanFunctions, 1, DXMaxScanFunctions);
    NSUInteger perFunction = DXIntArg(arguments, @"max_size", DXDefaultFunctionBytes, 16, DXMaxFunctionBytes);

    UCDisassembler *engine = [UCDisassembler sharedInstance];
    if (!engine.isAvailable) {
        if (error) *error = DXErrorUnavailable;
        return nil;
    }

    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSMutableArray *functions = [NSMutableArray array];
    uint64_t cursor = start;
    uint64_t end = start + size;
    BOOL budgetExhausted = NO;
    BOOL stoppedOnUnreadable = NO;

    while (cursor + 4 <= end && functions.count < maxFunctions) {
        if ((CFAbsoluteTimeGetCurrent() - began) > DXScanBudget) { budgetExhausted = YES; break; }

        uint32_t raw = 0;
        if (!DXReadU32(cursor, &raw)) { stoppedOnUnreadable = YES; break; }

        if (DXLooksLikePrologue(raw)) {
            UCFunction *function = [engine analyzeFunctionAtAddress:cursor maxSize:perFunction];
            if (function && function.instructions.count > 0) {
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[@"address"] = DXHex(function.startAddress);
                entry[@"end"] = DXHex(function.endAddress);
                entry[@"size"] = @(function.size);
                entry[@"name"] = function.name ?: @"";
                entry[@"blocks"] = @(function.basicBlockCount);
                entry[@"instructions"] = @(function.instructions.count);
                [functions addObject:entry];

                uint64_t next = function.endAddress > cursor ? function.endAddress : cursor + 4;
                cursor = next;
                continue;
            }
        }
        cursor += 4;
    }

    NSUInteger covered = (NSUInteger)(MIN(cursor, end) - start);
    BOOL truncated = budgetExhausted || stoppedOnUnreadable || functions.count >= maxFunctions || cursor < end;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"start"] = DXHex(start);
    result[@"size"] = @(size);
    result[@"covered"] = @(covered);
    result[@"functionCount"] = @(functions.count);
    result[@"truncated"] = @(truncated);
    result[@"elapsedMs"] = @((NSInteger)((CFAbsoluteTimeGetCurrent() - began) * 1000));
    if (budgetExhausted) result[@"stopReason"] = @"time_budget";
    else if (stoppedOnUnreadable) result[@"stopReason"] = @"unreadable_page";
    else if (functions.count >= maxFunctions) result[@"stopReason"] = @"function_limit";
    else if (cursor < end) result[@"stopReason"] = @"range_end";
    result[@"functions"] = functions;
    return result;
}

#pragma mark - symbol

- (NSDictionary *)opSymbol:(NSDictionary *)arguments error:(NSString **)error {
    NSString *addressText = DXStringArg(arguments, @"address");
    NSString *name = DXStringArg(arguments, @"name");

    if (addressText.length) {
        uint64_t address = 0;
        if (!DXParseAddress(addressText, &address)) {
            if (error) *error = @"address 无法解析为整数地址";
            return nil;
        }
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"address"] = DXHex(address);

        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr((void *)(uintptr_t)address, &info)) {
            if (info.dli_fname) {
                result[@"image"] = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
            }
            if (info.dli_sname) {
                result[@"symbol"] = [NSString stringWithUTF8String:info.dli_sname] ?: @"";
                result[@"symbolKind"] = @"exported";
            }
            result[@"imageBase"] = DXHex((uint64_t)(uintptr_t)info.dli_fbase);
        } else {
            result[@"symbolKind"] = @"unmapped";
        }

        NSString *objcMethod = [UCDisassembler objcMethodNameAtAddress:address];
        if (objcMethod.length) result[@"objcMethod"] = objcMethod;
        NSString *objcClass = [UCDisassembler objcClassNameFromClassRef:address];
        if (objcClass.length) result[@"objcClass"] = objcClass;

        // 只有指针看起来落在可读数据区时才尝试当字符串读，避免把代码当 C 字符串解析。
        NSString *literal = [UCDisassembler stringAtAddress:address maxLength:128];
        if (literal.length) result[@"string"] = literal;

        if (!result[@"symbol"] && !result[@"objcMethod"] && !result[@"objcClass"]) {
            result[@"note"] = @"该地址没有导出符号，属 stripped 内部函数；用 function 反汇编后按 CFG 分析。";
        }
        return result;
    }

    if (name.length) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"name"] = name;

        // 1) ObjC 方法名写法：-[Class selector] 或 +[Class selector]
        if ((name.length > 4) && ([name hasPrefix:@"-["] || [name hasPrefix:@"+["]) && [name hasSuffix:@"]"]) {
            BOOL isClassMethod = [name hasPrefix:@"+["];
            NSString *body = [name substringWithRange:NSMakeRange(2, name.length - 3)];
            NSRange space = [body rangeOfString:@" "];
            if (space.location != NSNotFound) {
                NSString *className = [body substringToIndex:space.location];
                NSString *selectorName = [body substringFromIndex:space.location + 1];
                Class cls = NSClassFromString(className);
                if (!cls) {
                    if (error) *error = [@"找不到类：" stringByAppendingString:className];
                    return nil;
                }
                Method method = isClassMethod ? class_getClassMethod(cls, NSSelectorFromString(selectorName))
                                              : class_getInstanceMethod(cls, NSSelectorFromString(selectorName));
                if (!method) {
                    if (error) *error = [NSString stringWithFormat:@"%@ 上找不到方法 %@", className, selectorName];
                    return nil;
                }
                IMP imp = method_getImplementation(method);
                result[@"address"] = DXHex((uint64_t)(uintptr_t)imp);
                result[@"type"] = isClassMethod ? @"class_method" : @"instance_method";
                result[@"objcMethod"] = name;
                return result;
            }
        }

        // 2) ObjC 类名 → 类对象地址
        Class cls = NSClassFromString(name);
        if (cls) {
            result[@"address"] = DXHex((uint64_t)(uintptr_t)(__bridge void *)cls);
            result[@"type"] = @"objc_class";
            return result;
        }

        // 3) C 符号 → dlsym
        void *handle = dlsym(RTLD_DEFAULT, name.UTF8String);
        if (handle) {
            result[@"address"] = DXHex((uint64_t)(uintptr_t)handle);
            result[@"type"] = @"c_symbol";
            Dl_info info;
            memset(&info, 0, sizeof(info));
            if (dladdr(handle, &info) && info.dli_fname) {
                result[@"image"] = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
            }
            return result;
        }

        if (error) *error = [NSString stringWithFormat:
                             @"无法解析 %@：不是已加载的 ObjC 类、不是 -[Class sel] 形式、也不在 dlsym 可见符号表中",
                             name];
        return nil;
    }

    if (error) *error = @"需要 address 或 name 之一";
    return nil;
}

#pragma mark - xref

// 交叉引用两路都做，因为它们是不同类型的事实：
//   1) 直接分支引用：b/bb.xx/cbz/bl 等指令的 target 等于目标地址。
//   2) 字面量引用：8 字节数据等于目标地址，典型是函数指针表、虚表、block literal。
//      漏掉这一路会看不见「谁的表里登记了这个函数」。
- (NSDictionary *)opXref:(NSDictionary *)arguments error:(NSString **)error {
    uint64_t target = 0;
    if (!DXParseAddress(DXStringArg(arguments, @"address"), &target)) {
        if (error) *error = @"需要 address（被引用的目标地址，字符串形式）";
        return nil;
    }
    uint64_t start = 0;
    if (!DXParseAddress(DXStringArg(arguments, @"range"), &start)) {
        // 没有指定区间时，以目标所在函数起点为基准向前回溯一个窗口。
        start = target > 0x4000 ? (target - 0x4000) : target;
    }
    NSUInteger size = DXIntArg(arguments, @"size", DXDefaultXrefBytes, 4, DXMaxXrefBytes);
    size &= ~(NSUInteger)3;
    if (size < 4) size = 4;
    NSUInteger limit = DXIntArg(arguments, @"limit", 60, 1, DXMaxLimit);

    UCDisassembler *engine = [UCDisassembler sharedInstance];
    if (!engine.isAvailable) {
        if (error) *error = DXErrorUnavailable;
        return nil;
    }

    NSMutableArray *branches = [NSMutableArray array];
    NSMutableArray *pointers = [NSMutableArray array];

    // ---- 1) 直接分支引用 ----
    UCDisasmResult *disassembly = [engine disassembleAtAddress:start size:size];
    if (disassembly) {
        for (UCDisasmInstruction *instruction in disassembly.instructions) {
            if (branches.count >= limit) break;
            if (!instruction.isBranch) continue;
            if (instruction.branchTarget != target) continue;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"from"] = DXHex(instruction.address);
            entry[@"kind"] = instruction.isCall ? @"call"
                            : (instruction.isConditionalBranch ? @"cond_branch" : @"branch");
            entry[@"text"] = instruction.fullText ?: @"";
            NSString *owner = [UCDisassembler symbolNameAtAddress:instruction.address];
            if (owner.length) entry[@"symbol"] = owner;
            [branches addObject:entry];
        }
    }

    // ---- 2) 8 字节字面量引用 ----
    // 逐页读：按真实页大小对齐（iOS arm64 常见 16 KiB），整页读不到就整页跳过。
    // 绝不假设区间连续可读——中间夹一段 guard page 就是 SIGBUS。
    NSUInteger pageSize = (NSUInteger)vm_page_size;
    if (pageSize < 4096) pageSize = 4096;
    uint8_t *page = malloc(pageSize);
    if (page) {
        uint64_t cursor = start & ~((uint64_t)pageSize - 1);
        uint64_t end = start + size;
        while (cursor < end && pointers.count < limit) {
            vm_size_t outSize = 0;
            kern_return_t kr = cursor >= 0x100000000ULL
                ? vm_read_overwrite(mach_task_self(), (vm_address_t)cursor, (vm_size_t)pageSize,
                                    (vm_address_t)page, &outSize)
                : KERN_INVALID_ADDRESS;
            if (kr == KERN_SUCCESS && outSize == pageSize) {
                for (NSUInteger offset = 0; offset + 8 <= pageSize; offset += 8) {
                    uint64_t at = cursor + offset;
                    if (at < start || at >= end) continue;   // 页内但落在区间外的字节不算
                    uint64_t candidate = 0;
                    memcpy(&candidate, page + offset, sizeof(candidate));
                    if (candidate != target) continue;
                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"at"] = DXHex(at);
                    entry[@"kind"] = @"pointer_literal";
                    [pointers addObject:entry];
                    if (pointers.count >= limit) break;
                }
            }
            cursor += pageSize;
        }
        free(page);
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"target"] = DXHex(target);
    result[@"rangeStart"] = DXHex(start);
    result[@"rangeSize"] = @(size);
    result[@"branchCount"] = @(branches.count);
    result[@"pointerCount"] = @(pointers.count);
    result[@"branches"] = branches;
    result[@"pointers"] = pointers;
    if (branches.count == 0 && pointers.count == 0) {
        result[@"note"] = @"区间内没有找到对该地址的引用。可扩大 size，或用 range 指定更靠近调用方的区间。";
    }
    return result;
}

#pragma mark - objc_method

- (NSDictionary *)opObjcMethod:(NSDictionary *)arguments error:(NSString **)error {
    NSString *className = DXStringArg(arguments, @"class");
    NSString *selectorName = DXStringArg(arguments, @"selector");
    if (!className.length) { if (error) *error = @"需要 class"; return nil; }
    if (!selectorName.length) { if (error) *error = @"需要 selector"; return nil; }

    Class cls = NSClassFromString(className);
    if (!cls) {
        if (error) *error = [@"找不到类：" stringByAppendingString:className];
        return nil;
    }

    BOOL isClassMethod = DXBoolArg(arguments, @"meta");
    SEL selector = NSSelectorFromString(selectorName);
    Method method = isClassMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) {
        if (error) *error = [NSString stringWithFormat:@"%@ 上找不到%s方法 %@",
                             className, isClassMethod ? "类" : "实例", selectorName];
        return nil;
    }

    UCDisassembler *engine = [UCDisassembler sharedInstance];
    if (!engine.isAvailable) {
        if (error) *error = DXErrorUnavailable;
        return nil;
    }

    IMP imp = method_getImplementation(method);
    uint64_t impAddress = (uint64_t)(uintptr_t)imp;

    NSUInteger offset = DXIntArg(arguments, @"offset", 0, 0, DXMaxLimit * 16);
    NSUInteger limit = DXIntArg(arguments, @"limit", DXDefaultLimit, 1, DXMaxLimit);
    BOOL verbose = DXBoolArg(arguments, @"verbose");

    UCDisasmResult *disassembly = [engine disassembleMethod:method];
    if (!disassembly || disassembly.instructions.count == 0) {
        if (error) *error = [NSString stringWithFormat:
                             @"%@ 的实现地址 %@ 无法反汇编",
                             selectorName, DXHex(impAddress)];
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"class"] = className;
    result[@"selector"] = selectorName;
    result[@"meta"] = @(isClassMethod);
    result[@"imp"] = DXHex(impAddress);
    // 类方法的父类仍是父类本身（不是它的 metaclass），两个分支都取 class_getSuperclass(cls)。
    NSString *superName = NSStringFromClass(class_getSuperclass(cls));
    if (superName.length) result[@"superclass"] = superName;
    result[@"engine"] = disassembly.engineName ?: @"unknown";

    if (disassembly.functions.count) {
        UCFunction *function = disassembly.functions.firstObject;
        result[@"functionStart"] = DXHex(function.startAddress);
        result[@"functionEnd"] = DXHex(function.endAddress);
        result[@"basicBlockCount"] = @(function.basicBlockCount);
        result[@"blocks"] = DXBlocksJSON(function);
    }
    [result addEntriesFromDictionary:DXPagedInstructions(disassembly.instructions, offset, limit, verbose)];
    return result;
}

@end
