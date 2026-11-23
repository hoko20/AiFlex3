#import "FLEXAiFlexDumper.h"

#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/vm_page_size.h>
#import <string.h>
#import <stdlib.h>

// Mach-O 内存导出（脱壳）。
//
// 核心事实：App Store 下发的 Mach-O 里，可执行段是按页 FairPlay 加密的
// （LC_ENCRYPTION_INFO_64.cryptid == 1）。磁盘文件永远是密文，但内核在页错误时
// 逐页解密再映射，所以本进程内存里的那一段就是明文。把 segment 表对着内存搬一遍，
// 再把 cryptid 改成 0，就得到可静态分析的明文二进制。
//
// 几个必须守住的点：
//   * 段源地址 = segment.vmaddr + slide。不是 header + vmaddr，header 本身已经带 slide。
//   * 逐页 vm_read，失败页填零并记数。有反 dump 的实现会把页设成 PROT_NONE，
//     整段 memcpy 会直接 SIGBUS。
//   * dump 出的文件不参与签名校验，只给 IDA / Hopper / Ghidra 用，不用于安装运行。
//   * 单文件上限 512 MiB；写盘前检查可用空间（原子写需要约两倍空间）。

#pragma mark - 常量

static const uint64_t DXMaxDumpBytes = 512ULL * 1024 * 1024;
static const NSUInteger DXDefaultImageLimit = 50;
static const NSUInteger DXMaxImageLimit = 512;
static NSString * const DXDumpDirectoryName = @"AiFlex3Dump";

static NSString * const DXErrorNoImage = @"找不到指定的镜像（index 越界，或 name 没有匹配到已加载镜像）";

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

static NSString *DXBaseName(const char *path) {
    if (!path) return @"";
    const char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    return [NSString stringWithUTF8String:name] ?: @"";
}

// segname 是 char[16]，不保证 null 结尾，不能直接 stringWithUTF8String。
static NSString *DXSegmentName(const char *segname) {
    if (!segname) return @"";
    size_t length = strnlen(segname, 16);
    if (length == 0) return @"";
    NSString *name = [[NSString alloc] initWithBytes:segname length:length encoding:NSUTF8StringEncoding];
    return name ?: @"";
}

static NSString *DXDumpDirectory(void) {
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!documents.length) documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:DXDumpDirectoryName];
}

#pragma mark - 镜像解析

typedef struct {
    uint32_t index;
    const struct mach_header_64 *header;
    intptr_t slide;
    const char *path;
    char name[256];
    BOOL isMain;
    BOOL encrypted;
    BOOL hasEncryptionInfo;
    uint32_t cryptid;
    uint32_t cryptoff;
    uint32_t cryptsize;
    uint64_t fileSize;        // 按 segment 表算出的完整文件长度
    uint32_t segmentCount;
    uint32_t commandCount;
    BOOL valid;
} DXImageInfo;

// 只认 64 位 Mach-O。iOS 15+ 的 arm64 / arm64e 全部是 MH_MAGIC_64，
// 遇到 MH_MAGIC 说明是 32 位镜像（已在 iOS 11 之后绝迹），直接跳过。
static BOOL DXLoadImageInfo(uint32_t index, DXImageInfo *info) {
    if (!info) return NO;
    memset(info, 0, sizeof(*info));

    uint32_t count = _dyld_image_count();
    if (index >= count) return NO;

    const struct mach_header *raw = _dyld_get_image_header(index);
    if (!raw) return NO;
    if (raw->magic != MH_MAGIC_64) return NO;

    const struct mach_header_64 *header = (const struct mach_header_64 *)raw;
    info->index = index;
    info->header = header;
    info->slide = _dyld_get_image_vmaddr_slide(index);
    info->path = _dyld_get_image_name(index);
    info->isMain = (index == 0);
    info->commandCount = header->ncmds;

    NSString *name = DXBaseName(info->path);
    const char *rawName = name.UTF8String;
    strncpy(info->name, rawName ? rawName : "", sizeof(info->name) - 1);
    info->name[sizeof(info->name) - 1] = '\0';

    // load commands 区必须落在 header 声明的 sizeofcmds 内，
    // 损坏的 cmdsize 会把游标带出映射区，所以每一步都做上界检查。
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *limit = cursor + header->sizeofcmds;

    uint64_t fileSize = 0;
    uint32_t segments = 0;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) break;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (cursor + command->cmdsize > limit) break;

        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                uint64_t end = segment->fileoff + segment->filesize;
                if (end > fileSize) fileSize = end;
                segments++;
            }
        } else if (command->cmd == LC_ENCRYPTION_INFO_64) {
            if (command->cmdsize >= sizeof(struct encryption_info_command_64)) {
                const struct encryption_info_command_64 *encryption =
                    (const struct encryption_info_command_64 *)command;
                info->hasEncryptionInfo = YES;
                info->cryptid = encryption->cryptid;
                info->cryptoff = encryption->cryptoff;
                info->cryptsize = encryption->cryptsize;
                info->encrypted = (encryption->cryptid != 0);
            }
        }

        cursor += command->cmdsize;
    }

    info->fileSize = fileSize;
    info->segmentCount = segments;
    info->valid = (segments > 0 && fileSize > 0);
    return info->valid;
}

static NSDictionary *DXImageJSON(const DXImageInfo *info) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"index"] = @(info->index);
    entry[@"name"] = [NSString stringWithUTF8String:info->name] ?: @"";
    if (info->path) entry[@"path"] = [NSString stringWithUTF8String:info->path] ?: @"";
    entry[@"base"] = DXHex((uint64_t)(uintptr_t)info->header);
    entry[@"slide"] = DXHex((uint64_t)info->slide);
    entry[@"size"] = @(info->fileSize);
    entry[@"segments"] = @(info->segmentCount);
    entry[@"mainExecutable"] = @(info->isMain);
    entry[@"encrypted"] = @(info->encrypted);
    if (info->hasEncryptionInfo) {
        entry[@"cryptid"] = @(info->cryptid);
        entry[@"cryptoff"] = @(info->cryptoff);
        entry[@"cryptsize"] = @(info->cryptsize);
    } else {
        // 系统库与内嵌 dylib 通常没有 LC_ENCRYPTION_INFO_64，本身就不是 FairPlay 加密的。
        entry[@"note"] = @"镜像不含 LC_ENCRYPTION_INFO_64，本身就是明文 dylib";
    }
    return entry;
}

// 选出要处理的镜像：index 优先，其次 name 子串匹配，都没有就用主可执行文件。
static BOOL DXResolveImage(NSDictionary *arguments, DXImageInfo *info) {
    NSString *indexText = DXStringArg(arguments, @"index");
    if (indexText.length) {
        uint32_t index = (uint32_t)[indexText longLongValue];
        return DXLoadImageInfo(index, info);
    }

    NSString *name = DXStringArg(arguments, @"name");
    if (name.length) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *path = _dyld_get_image_name(i);
            NSString *candidate = DXBaseName(path);
            if ([candidate isEqualToString:name] || (path && strstr(path, name.UTF8String))) {
                if (DXLoadImageInfo(i, info)) return YES;
            }
        }
        return NO;
    }

    return DXLoadImageInfo(0, info);
}

#pragma mark - 引擎

@interface FLEXAiFlexDumper ()
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FLEXAiFlexDumper

+ (instancetype)sharedEngine {
    static FLEXAiFlexDumper *engine = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [[self alloc] init];
    });
    return engine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.hoko20.aiflex3.dumper", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    }
    return self;
}

+ (BOOL)engineAvailable {
    return YES;
}

+ (NSArray<NSString *> *)supportedOperations {
    return @[@"status", @"image", @"dump", @"list"];
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
            error = [NSString stringWithFormat:@"导出异常（%@）：%@",
                     exception.name ?: @"unknown", exception.reason ?: @"无详细信息"];
        }
        if (!error.length && !result) error = @"导出未返回结果";
        completion(result, error);
    });
}

- (NSDictionary *)run:(NSString *)operation
            arguments:(NSDictionary *)arguments
                error:(NSString **)error {
    if ([operation isEqualToString:@"status"]) return [self opStatus];
    if ([operation isEqualToString:@"image"])  return [self opImage:arguments error:error];
    if ([operation isEqualToString:@"dump"])   return [self opDump:arguments error:error];
    if ([operation isEqualToString:@"list"])   return [self opList];
    if (error) *error = [@"未知 operation：" stringByAppendingString:operation ?: @""];
    return nil;
}

#pragma mark - status

- (NSDictionary *)opStatus {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"available"] = @YES;
    result[@"operations"] = [FLEXAiFlexDumper supportedOperations];
    result[@"outputDirectory"] = [@"Documents/" stringByAppendingString:DXDumpDirectoryName];
    result[@"maxDumpBytes"] = @(DXMaxDumpBytes);
    result[@"readOnly"] = @YES;
    result[@"note"] = @"只读内存 + 写新文件；不改运行时代码、不 hook、不 patch。导出的二进制不带有效签名，仅供静态分析。";

    DXImageInfo info;
    if (DXLoadImageInfo(0, &info)) {
        NSMutableDictionary *main = [DXImageJSON(&info) mutableCopy];
        main[@"executablePath"] = [NSString stringWithUTF8String:(info.path ? info.path : "")] ?: @"";
        result[@"mainExecutable"] = main;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = DXDumpDirectory();
    BOOL isDirectory = NO;
    if ([manager fileExistsAtPath:directory isDirectory:&isDirectory] && isDirectory) {
        NSUInteger files = 0;
        unsigned long long totalBytes = 0;
        for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
            NSString *full = [directory stringByAppendingPathComponent:name];
            NSDictionary *attributes = [manager attributesOfItemAtPath:full error:nil];
            if (!attributes) continue;
            files++;
            totalBytes += attributes.fileSize;
        }
        result[@"exported"] = @{@"files": @(files), @"bytes": @(totalBytes)};
    } else {
        result[@"exported"] = @{@"files": @0, @"bytes": @0};
    }
    return result;
}

#pragma mark - image

- (NSDictionary *)opImage:(NSDictionary *)arguments error:(NSString **)error {
    NSUInteger limit = DXIntArg(arguments, @"limit", DXDefaultImageLimit, 1, DXMaxImageLimit);
    NSString *filter = DXStringArg(arguments, @"filter");

    uint32_t count = _dyld_image_count();
    NSMutableArray *images = [NSMutableArray array];
    NSUInteger matched = 0;

    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (filter.length) {
            NSString *candidate = DXBaseName(path);
            BOOL hit = [candidate rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit && path) {
                hit = [[NSString stringWithUTF8String:path] rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound;
            }
            if (!hit) continue;
        }
        matched++;
        if (images.count >= limit) continue;

        DXImageInfo info;
        if (!DXLoadImageInfo(i, &info)) {
            // 32 位镜像或被 dyld 卸载的镜像，只报最小信息。
            [images addObject:@{@"index": @(i), @"name": DXBaseName(path), @"unsupported": @YES}];
            continue;
        }
        [images addObject:DXImageJSON(&info)];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"totalImages"] = @(count);
    result[@"matched"] = @(matched);
    result[@"returned"] = @(images.count);
    result[@"images"] = images;
    if (matched > images.count) {
        result[@"hasMore"] = @YES;
        result[@"note"] = @"匹配数超过 limit，请用 filter 缩小范围或调大 limit。";
    }
    return result;
}

#pragma mark - dump

- (NSDictionary *)opDump:(NSDictionary *)arguments error:(NSString **)error {
    DXImageInfo info;
    if (!DXResolveImage(arguments, &info)) {
        if (error) *error = DXErrorNoImage;
        return nil;
    }

    if (info.fileSize == 0) {
        if (error) *error = [NSString stringWithFormat:@"%@ 的 segment 表为空，无法导出", [NSString stringWithUTF8String:info.name]];
        return nil;
    }
    if (info.fileSize > DXMaxDumpBytes) {
        if (error) *error = [NSString stringWithFormat:
                             @"%@ 需要 %llu MiB，超过单次导出上限 %llu MiB",
                             [NSString stringWithUTF8String:info.name],
                             info.fileSize / (1024 * 1024),
                             DXMaxDumpBytes / (1024 * 1024)];
        return nil;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = DXDumpDirectory();
    NSString *baseName = [NSString stringWithUTF8String:info.name] ?: @"image";
    if (!baseName.length) baseName = @"image";
    NSString *fileName = DXStringArg(arguments, @"output") ?: [baseName stringByAppendingString:@"_dump"];
    if ([fileName rangeOfString:@"/"].location != NSNotFound) {
        if (error) *error = @"output 只能是文件名，不能带路径";
        return nil;
    }
    NSString *fullPath = [directory stringByAppendingPathComponent:fileName];

    // 原子写会先落一个临时文件，实际需要约两倍空间。
    NSDictionary *filesystem = [manager attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    unsigned long long freeBytes = [filesystem[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long required = info.fileSize * 2 + 8 * 1024 * 1024;
    if (freeBytes > 0 && freeBytes < required) {
        if (error) *error = [NSString stringWithFormat:
                             @"磁盘空间不足：需要约 %llu MiB，可用 %llu MiB",
                             required / (1024 * 1024), freeBytes / (1024 * 1024)];
        return nil;
    }

    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (error) *error = [@"无法创建导出目录：" stringByAppendingString:directory];
        return nil;
    }

    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();

    // calloc 而不是 malloc：segment 的 filesize 之外、以及读失败的页都要是 0，
    // 不能残留堆里的旧数据，否则 IDA 会加载出一堆随机指令。
    uint8_t *buffer = calloc(1, (size_t)info.fileSize);
    if (!buffer) {
        if (error) *error = @"内存不足，无法分配导出缓冲区";
        return nil;
    }

    const struct mach_header_64 *header = info.header;
    uint64_t slide = (uint64_t)info.slide;
    NSUInteger pageSize = (NSUInteger)vm_page_size;
    if (pageSize < 4096) pageSize = 4096;

    uint64_t failedBytes = 0;
    uint64_t copiedBytes = 0;
    NSMutableArray *segmentReports = [NSMutableArray array];

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *limit = cursor + header->sizeofcmds;
    const uint8_t *encryptionCommand = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) break;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (cursor + command->cmdsize > limit) break;

        if (command->cmd == LC_ENCRYPTION_INFO_64) {
            encryptionCommand = cursor;
        } else if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;

            if (segment->filesize == 0) {
                [segmentReports addObject:@{@"name": DXSegmentName(segment->segname),
                                            @"skipped": @"filesize=0 (__PAGEZERO)"}];
                cursor += command->cmdsize;
                continue;
            }
            if (segment->fileoff + segment->filesize > info.fileSize) {
                // segment 表自相矛盾，跳过而不是越界写。
                [segmentReports addObject:@{@"name": DXSegmentName(segment->segname),
                                            @"skipped": @"fileoff+filesize 超出计算长度"}];
                cursor += command->cmdsize;
                continue;
            }

            // 关键：源地址 = vmaddr + slide。header 自身已经带 slide，
            // 用 header + vmaddr 会把整段搬错位置。
            uint64_t source = (uint64_t)segment->vmaddr + slide;
            uint64_t destination = segment->fileoff;
            uint64_t remaining = segment->filesize;
            uint64_t offset = 0;
            uint64_t segmentFailed = 0;

            while (remaining > 0) {
                size_t chunk = (size_t)(remaining < (uint64_t)pageSize ? remaining : (uint64_t)pageSize);
                vm_size_t outSize = 0;
                kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                                     (vm_address_t)(source + offset),
                                                     (vm_size_t)chunk,
                                                     (vm_address_t)(buffer + destination + offset),
                                                     &outSize);
                if (kr != KERN_SUCCESS || outSize != chunk) {
                    segmentFailed += chunk;
                    // 抢救：整页失败时逐 4 字节再试一次。
                    // 反 dump 检测通常只锁住部分页，逐字节能把可用部分捞回来。
                    for (size_t sub = 0; sub + 4 <= chunk; sub += 4) {
                        vm_size_t subSize = 0;
                        if (vm_read_overwrite(mach_task_self(),
                                              (vm_address_t)(source + offset + sub),
                                              4,
                                              (vm_address_t)(buffer + destination + offset + sub),
                                              &subSize) == KERN_SUCCESS && subSize == 4) {
                            segmentFailed -= 4;
                        }
                    }
                } else {
                    copiedBytes += chunk;
                }
                offset += chunk;
                remaining -= chunk;
            }

            failedBytes += segmentFailed;
            NSMutableDictionary *report = [NSMutableDictionary dictionary];
            report[@"name"] = DXSegmentName(segment->segname);
            report[@"fileoff"] = @(segment->fileoff);
            report[@"filesize"] = @(segment->filesize);
            report[@"source"] = DXHex(source);
            if (segmentFailed) report[@"failedBytes"] = @(segmentFailed);
            [segmentReports addObject:report];
        }

        cursor += command->cmdsize;
    }

    // 把 cryptid 改成 0：不这么做的分析工具会以为可执行段仍是密文，
    // 直接拒绝反汇编或显示乱码。
    if (encryptionCommand) {
        uint64_t offset = (uint64_t)(encryptionCommand - (const uint8_t *)header);
        if (offset + sizeof(struct encryption_info_command_64) <= info.fileSize) {
            struct encryption_info_command_64 *dumped =
                (struct encryption_info_command_64 *)(buffer + offset);
            dumped->cryptid = 0;
        }
    }

    NSData *payload = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)info.fileSize freeWhenDone:YES];
    NSError *writeError = nil;
    BOOL written = [payload writeToURL:[NSURL fileURLWithPath:fullPath]
                               options:NSDataWritingAtomic
                                 error:&writeError];
    if (!written) {
        // writeToURL 失败时 payload 仍持有 buffer，交给 ARC 释放即可。
        if (error) *error = [NSString stringWithFormat:@"写入失败：%@",
                             writeError.localizedDescription ?: @"unknown"];
        return nil;
    }

    double elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"file"] = fullPath;
    result[@"relativePath"] = [@"Documents/" stringByAppendingPathComponent:
                               [DXDumpDirectoryName stringByAppendingPathComponent:fileName]];
    result[@"size"] = @(info.fileSize);
    result[@"image"] = [NSString stringWithUTF8String:info.name] ?: @"";
    result[@"imageIndex"] = @(info.index);
    result[@"slide"] = DXHex(slide);
    result[@"wasEncrypted"] = @(info.encrypted);
    result[@"cryptidBefore"] = @(info.cryptid);
    result[@"cryptidAfter"] = @0;
    if (info.hasEncryptionInfo) {
        result[@"cryptoff"] = @(info.cryptoff);
        result[@"cryptsize"] = @(info.cryptsize);
    }
    result[@"copiedBytes"] = @(copiedBytes);
    result[@"failedBytes"] = @(failedBytes);
    result[@"complete"] = @(failedBytes == 0);
    result[@"elapsedMs"] = @((NSInteger)elapsedMs);
    result[@"segments"] = segmentReports;
    if (failedBytes) {
        result[@"note"] = @"有页读不到（可能被反 dump 检测锁成不可读），这些位置在导出文件里是 0。二进制仍可加载，但这部分指令会显示为非法。";
    } else {
        result[@"note"] = @"导出完整。用 sandbox_read 取走后可直接用 IDA / Hopper / Ghidra 打开；文件不带有效签名，不要用于安装。代码段是内核解密后的明文；__DATA 里的指针已按 slide 重定位，静态分析时按 image base = __TEXT.vmaddr 加载即可，跨段指针会有 slide 大小的偏差。";
    }
    return result;
}

#pragma mark - list

- (NSDictionary *)opList {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = DXDumpDirectory();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"directory"] = [@"Documents/" stringByAppendingString:DXDumpDirectoryName];

    if (![manager fileExistsAtPath:directory]) {
        result[@"files"] = @[];
        result[@"count"] = @0;
        return result;
    }

    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in names) {
        NSString *full = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [manager attributesOfItemAtPath:full error:nil];
        if (!attributes) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"name"] = name;
        entry[@"size"] = @(attributes.fileSize);
        NSDate *modified = attributes.fileModificationDate;
        if (modified) {
            entry[@"modifiedAt"] = @((long long)modified.timeIntervalSince1970);
        }
        entry[@"relativePath"] = [NSString stringWithFormat:@"Documents/%@/%@", DXDumpDirectoryName, name];
        [files addObject:entry];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"modifiedAt"] compare:a[@"modifiedAt"]];
    }];

    result[@"files"] = files;
    result[@"count"] = @(files.count);
    return result;
}

@end
