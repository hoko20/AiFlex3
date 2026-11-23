#!/usr/bin/env bash
# 编译 Capstone 6.0（仅 AArch64）为静态库，并把它的全局符号加 flx6 前缀。
#
# 为什么需要前缀：libfrida-gum.a 内置一份 Capstone 5.0.1，aiflex_hook 走 gum
# Interceptor 时 arm64 relocator 会硬引用 cs_arch_register_arm64，那份剥不掉。
# 两份实现若同名会 duplicate symbol；共用一份又因 cs_detail 布局不同
# （MAX_IMPL_W_REGS 47 vs 20、union 偏移 154 vs 92）读出错位的 arm64 operands。
# 所以只重命名 6.0 侧已定义的全局符号，让两侧各自 ABI 自洽、并存于一个 dylib。
#
# 这一步只在 CI / 有 Xcode 的 macOS 上跑；缺 Xcode 时维持 5.0.1 行为。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC_DIR="$ROOT/x/capstone6"
OUT_DIR="$SRC_DIR/.build"
LIB_DIR="$SRC_DIR/lib"
LIB="$LIB_DIR/libcapstone6.a"
PREFIX="flx6"

if ! command -v xcrun >/dev/null 2>&1; then
    echo "[capstone6] xcrun not found, skip" >&2
    exit 0
fi

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CC="$(xcrun -sdk iphoneos --find clang)"
AR="$(xcrun -sdk iphoneos --find ar)"
OBJCOPY="${CAPSTONE6_OBJCOPY:-$(xcrun -find llvm-objcopy 2>/dev/null || command -v llvm-objcopy || true)}"

if [[ -z "$OBJCOPY" || ! -x "$OBJCOPY" ]]; then
    echo "[capstone6] llvm-objcopy not found; cannot build isolated capstone 6" >&2
    exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" "$LIB_DIR"

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
    obj="$OUT_DIR/$(basename "${src%.c}").o"
    "$CC" "${CFLAGS[@]}" -c "$src" -o "$obj"
done

# 只重命名「已定义的全局符号」。undefined（malloc/memcpy/printf 等 libc 符号）
# 必须保持原名，否则链接期会找不到系统函数。objcopy 的 --redefine-sym 会
# 同时改写定义和所有引用点，所以这批 .o 之间的内部调用会自动跟着走。
for obj in "$OUT_DIR"/*.o; do
    args=()
    while IFS= read -r sym; do
        [[ -n "$sym" ]] && args+=(--redefine-sym "$sym=${PREFIX}${sym}")
    done < <(nm -gU "$obj" 2>/dev/null | awk 'NF >= 3 {print $NF}' | grep '^_' || true)
    if (( ${#args[@]} > 0 )); then
        "$OBJCOPY" "${args[@]}" "$obj"
    fi
done

"$AR" rcs "$LIB" "$OUT_DIR"/*.o
echo "[capstone6] built $LIB ($(find "$OUT_DIR" -name '*.o' | wc -l | tr -d ' ') objects)"
echo "[capstone6] prefixed symbols sample:"
nm -gU "$LIB" 2>/dev/null | awk 'NF >= 3 {print $NF}' | grep "^${PREFIX}_cs_" | sort -u | head -12 || true
