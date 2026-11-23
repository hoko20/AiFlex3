#!/usr/bin/env bash
# 编译 Capstone 6.0（仅 AArch64）为静态库，并把它的全局符号加 flx6 前缀。
#
# 为什么需要前缀：libfrida-gum.a 内置一份 Capstone 5.0.1，aiflex_hook 走 gum
# Interceptor 时 arm64 relocator 会硬引用 cs_arch_register_arm64，那份剥不掉。
# 两份实现若同名会 duplicate symbol；共用一份又因 cs_detail 布局不同
# （MAX_IMPL_W_REGS 47 vs 20、union 偏移 154 vs 92）读出错位的 arm64 operands。
#
# 不能只前缀公共 API：5.0.1 和 6.0 还共享 id2name / map_cs_id /
# ARM_get_detail_op 等一批内部符号，照样会 duplicate symbol。这里用两遍编译：
#   1. 无前缀编译，nm 收集全部「已定义的全局符号」（undefined 的 libc 符号
#      不会被收进来）
#   2. 为每个符号生成 -Dfoo=flx6_foo，重新编译。定义与所有引用一起换名，
#      效果和 objcopy --redefine-sym 一致，但不需要 macOS 上不存在的工具。
#
# 只在 CI / 有 Xcode 的 macOS 上跑；缺 Xcode 时维持 5.0.1 行为。
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

SYMS=()
while IFS= read -r name; do
    [[ -n "$name" ]] && SYMS+=("$name")
done < <(
    nm -gU "$OUT_DIR/probe"/*.o 2>/dev/null \
        | awk 'NF >= 3 {print $NF}' \
        | grep '^_' \
        | sed 's/^_//' \
        | sort -u
)
if (( ${#SYMS[@]} == 0 )); then
    echo "[capstone6] failed to collect defined symbols" >&2
    exit 1
fi

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
