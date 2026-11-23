#!/usr/bin/env bash
# 编译 Capstone 6.0（仅 AArch64）为静态库，并把它的全局符号加 flx6 前缀。
#
# 为什么需要前缀：libfrida-gum.a 内置一份 Capstone 5.0.1，aiflex_hook 走 gum
# Interceptor 时 arm64 relocator 会硬引用 cs_arch_register_arm64，那份剥不掉。
# 两份实现若同名会 duplicate symbol；共用一份又因 cs_detail 布局不同
# （MAX_IMPL_W_REGS 47 vs 20、union 偏移 154 vs 92）读出错位的 arm64 operands。
#
# 不能全量前缀：AArch64InstPrinter.h 用 CONCAT(printPostIncOperand_, N) 拼接
# 函数名，拼接结果不再被命令行 -D 宏替换，会导致声明 flx6_ 开头而调用仍是
# 原名。而且这类符号 gum 里根本没有，不该前缀。只取两边符号集的交集：
#   1. 无前缀编译一遍，nm 收集 6.0 已定义的全局符号
#   2. nm 收集 libfrida-gum.a 的全局符号
#   3. comm 取交集，逐个 -Dfoo=flx6_foo 重新编译
# undefined 的 libc 符号不在已定义集合里，原名保留。
#
# 只在 CI / 有 Xcode 的 macOS 上跑；缺 gum devkit 时维持 5.0.1 行为。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC_DIR="$ROOT/x/capstone6"
OUT_DIR="$SRC_DIR/.build"
LIB="$SRC_DIR/lib/libcapstone6.a"
PREFIX="flx6"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "[capstone6] xcrun not found, skip" >&2
    exit 0
fi

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CC="$(xcrun -sdk iphoneos --find clang)"
AR="$(xcrun -sdk iphoneos --find ar)"
GUM_LIB="$ROOT/frida/vendor/libfrida-gum.a"

if [[ ! -f "$GUM_LIB" ]]; then
    echo "[capstone6] frida-gum devkit not found, skip" >&2
    exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/probe" "$SRC_DIR/lib"

CFLAGS=(
    -arch arm64
    -isysroot "$SDK"
    -miphoneos-version-min=15.0
    -O2
    -fno-stack-protector
    -DCAPSTONE_HAS_AARCH64
    -DCAPSTONE_USE_SYS_DYN_MEM
    -I"$SRC_DIR/include"
)

SRCS=(
    "$SRC_DIR/cs.c"
    "$SRC_DIR/MCInst.c"
    "$SRC_DIR/MCInstPrinter.c"
    "$SRC_DIR/MCInstrDesc.c"
    "$SRC_DIR/MCRegisterInfo.c"
    "$SRC_DIR/Mapping.c"
    "$SRC_DIR/SStream.c"
    "$SRC_DIR/utils.c"
    "$SRC_DIR/arch/AArch64/AArch64BaseInfo.c"
    "$SRC_DIR/arch/AArch64/AArch64Disassembler.c"
    "$SRC_DIR/arch/AArch64/AArch64DisassemblerExtension.c"
    "$SRC_DIR/arch/AArch64/AArch64InstPrinter.c"
    "$SRC_DIR/arch/AArch64/AArch64Mapping.c"
    "$SRC_DIR/arch/AArch64/AArch64Module.c"
)

for src in "${SRCS[@]}"; do
    if [[ ! -f "$src" ]]; then
        echo "[capstone6] missing source: $src" >&2
        exit 1
    fi
done

# ---- pass 1: 收集所有已定义的全局符号 ----
for src in "${SRCS[@]}"; do
    "$CC" "${CFLAGS[@]}" -c "$src" -o "$OUT_DIR/probe/$(basename "${src%.c}").o"
done

# 只前缀「同时出现在 gum 和 capstone6 里」的符号。全量前缀会破坏
# AArch64InstPrinter.h 的 CONCAT(printPostIncOperand_, N) token 拼接——
# 拼接产生的名字不再被命令行 -D 宏替换，头里声明的是 flx6_ 开头、
# .inc 里调用的却是原名，直接编译失败；而这类符号 gum 里根本没有，
# 不前缀也不会冲突。取交集既消除 duplicate symbol，又避开 token 拼接。
GUM_SYMS="$OUT_DIR/gum.syms"
CS6_SYMS="$OUT_DIR/cs6.syms"
nm -gU "$GUM_LIB" 2>/dev/null | awk 'NF >= 3 {print $NF}' \
    | grep '^_' | sed 's/^_//' | sort -u > "$GUM_SYMS"
nm -gU "$OUT_DIR/probe"/*.o 2>/dev/null | awk 'NF >= 3 {print $NF}' \
    | grep '^_' | sed 's/^_//' | sort -u > "$CS6_SYMS"

SYMS=()
while IFS= read -r name; do
    [[ -n "$name" ]] && SYMS+=("$name")
done < <(comm -12 "$GUM_SYMS" "$CS6_SYMS")
if (( ${#SYMS[@]} == 0 )); then
    echo "[capstone6] no overlapping symbols with gum (unexpected)" >&2
    exit 1
fi
echo "[capstone6] ${#SYMS[@]} overlapping symbols will be prefixed"

PFX_FLAGS=()
for name in "${SYMS[@]}"; do
    PFX_FLAGS+=("-D${name}=${PREFIX}_${name}")
done

# ---- pass 2: 带前缀重新编译 ----
for src in "${SRCS[@]}"; do
    "$CC" "${CFLAGS[@]}" "${PFX_FLAGS[@]}" -c "$src" \
        -o "$OUT_DIR/$(basename "${src%.c}").o"
done

"$AR" rcs "$LIB" "$OUT_DIR"/*.o
echo "[capstone6] built $LIB (${#SRCS[@]} objects, ${#SYMS[@]} prefixed symbols)"
echo "[capstone6] prefixed symbols sample:"
nm -gU "$LIB" 2>/dev/null | awk 'NF >= 3 {print $NF}' | grep "^_${PREFIX}_cs_" | sort -u | head -12 || true
