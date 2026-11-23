PACKAGE_IDENTIFIER = com.hoko20.aiflex3
PACKAGE_NAME = AiFlex3
PACKAGE_VERSION = 3.5.2
PACKAGE_ARCHITECTURE = arm64
PACKAGE_REVISION = 1
PACKAGE_SECTION = Tweaks
PACKAGE_DEPENDS = firmware (>= 15.0)
PACKAGE_DESCRIPTION = FLEX调试工具 · AiFlex3 MCP

define Package/com.hoko20.aiflex3
  Package: com.hoko20.aiflex3
  Name: AiFlex3
  Version: $(PACKAGE_VERSION)
  Architecture: arm64
  Author: FLEX Team & hoko20
  Section: Tweaks
  Depends: firmware (>= 15.0)
  Description: FLEX调试工具 · AiFlex3 MCP
endef

# 支持更旧版本的iOS设备(从15.6降到15.0，AiFlex3 MCP 要求 iOS 15+)
TARGET = iphone:latest:15.0
ARCHS = arm64

# 名称和类型
LIBRARY_NAME = FLEX++

# 对外产物文件名加 AiFlex2 标识（内部 dylib 名仍为 FLEX++，Theos target 依赖它）
ARTIFACT_BASE = AiFlex2-$(LIBRARY_NAME)-$(PACKAGE_VERSION)-$(PACKAGE_ARCHITECTURE)-rootless

# 动态库类型 - 兼容各种越狱环境
LIBRARY_TYPE = dynamic

# 直接输出到当前目录
export THEOS_PACKAGE_DIR = $(CURDIR)

# Rootless
export THEOS_PACKAGE_SCHEME = rootless
THEOS_PACKAGE_INSTALL_PREFIX = /var/jb

# 设置路径
$(LIBRARY_NAME)_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

# 包含所有源文件（排除FLEX原版和重复文件）
$(LIBRARY_NAME)_FILES = $(shell find . \( -name '*.m' -o -name '*.mm' -o -name '*.c' \) | \
    grep -v "^./FLEX/" | \
    grep -v "x/retdec/" | \
    grep -v "x/retdec-build/" | \
    grep -v "x/Shared/FLEXKeychain.m" | \
    grep -v "x/Shared/FLEXKeychainQuery.m" | \
    grep -v "x/capstone/" | \
    grep -v "x/capstone6/" | \
    grep -v "frida/vendor/")

# 两套 Capstone 并存（3.5.0 起）：
#
#  5.0.1 —— 实现来自 libfrida-gum.a。aiflex_hook 走 gum Interceptor，arm64 侧
#           经 relocator 重定位被覆盖的指令，而 relocator 硬引用
#           cs_arch_register_arm64，这份实现剥不掉。
#  6.0   —— 单独编成 libcapstone6.a，所有已定义的全局符号加 flx6 前缀。
#           A19 Pro 的 SME2 / SVE2p1 / MTE4 指令只有 6.0（LLVM 17/18 解码表）
#           能识别；5.0.1 是 LLVM 7 的表，这些扩展一个枚举都没有。
#
#  两者 cs_detail 布局不同（MAX_IMPL_W_REGS 47 vs 20、union 偏移 154 vs 92），
#  所以不能共用一份实现；重名又会 duplicate symbol。前缀隔离后各自 ABI 自洽。
#
#  x/capstone/include 仍是 5.0.1 头（gum 侧用它）；UCDisassembler.m 用相对路径
#  include x/capstone6/include 下的 6.0 头，两套头不在同一个 -I 搜索域里。
#
#  CI 先跑 scripts/build-capstone6.sh 生成 libcapstone6.a；本机没跑过该脚本时
#  Makefile 自动降级回 5.0.1（UCDisassembler 里的 #ifdef 分支不会引用前缀符号）。
CAPSTONE_INCLUDE = -I./x/capstone/include
CAPSTONE6_LIB = $(CURDIR)/x/capstone6/lib/libcapstone6.a

# 必要的框架和库
$(LIBRARY_NAME)_FRAMEWORKS = Foundation UIKit CoreGraphics CoreFoundation Security Network
$(LIBRARY_NAME)_PRIVATE_FRAMEWORKS = 

# 系统库
$(LIBRARY_NAME)_LIBRARIES = system xml2

# 链接器标志
$(LIBRARY_NAME)_LDFLAGS += -Wl,-no_warn_inits,-search_paths_first,-headerpad_max_install_names
$(LIBRARY_NAME)_CFLAGS = -fobjc-arc -include flex_fishhook.h \
                 -DFLEX_LIVE_OBJECTS_CONTROLLER_IS_VIEW_CONTROLLER=1 \
                 -DFLEX_LIVE_OBJECTS_VIEW_CONTROLLER=FLEXLiveObjectsController \
                 -Wno-unsupported-availability-guard \
                 -Wno-unused-but-set-variable \
                 -Wno-unguarded-availability-new \
                 -Wno-incompatible-pointer-types \
                 -Wno-deprecated-declarations \
                 -Wno-nullability-completeness \
                 -Wno-arc-retain-cycles \
                 -Wno-objc-missing-property-synthesis \
                 -Wno-unused-variable \
                 -Wno-unused-function \
                 -Wno-objc-protocol-method-implementation \
                 -Wno-implicit-function-declaration \
                 -Wno-nonnull \
                 -Wno-format \
                 -Wno-shift-op-parentheses \
                 -DCAPSTONE_HAS_AARCH64 \
                 -DCAPSTONE_USE_SYS_DYN_MEM \
                 -I./x \
                 $(CAPSTONE_INCLUDE)

# 编译兼容性
$(LIBRARY_NAME)_CCFLAGS = -std=c++17 -Wno-unused-function -Wno-objc-missing-property-synthesis
$(LIBRARY_NAME)_OBJCFLAGS = -fobjc-arc

# 兼容性
$(LIBRARY_NAME)_CFLAGS += -miphoneos-version-min=15.0

# ---- Frida gum（只读原生观测引擎）----
# CI 会把 frida-gum-devkit 解压到 frida/vendor。本地没有 devkit 时定义 GX_NO_GUM，
# 引擎降级为「仅 status / backtrace / crash_log 可用」，其余 operation 返回明确错误，
# 构建照常通过——不会因为缺库把整条流水线拖红。
# 注意：gum 的 capstone 与仓库头文件不同源——gum 那份是 5.0.1 且剥不掉。
# aiflex_hook 用到 gum Interceptor，arm64 侧会经 relocator 重定位被覆盖的指令，
# 而 relocator 硬引用 `cs_arch_register_arm64`。第二份实现（6.0）必须走
# scripts/build-capstone6.sh 的 flx6 前缀隔离，直接加进 *_FILES 会立刻重名。
FRIDA_VENDOR = ./frida/vendor
ifneq ($(wildcard $(FRIDA_VENDOR)/libfrida-gum.a),)
$(LIBRARY_NAME)_CFLAGS += -I$(FRIDA_VENDOR) -DGUM_STATIC
# -liconv：gum 自带 iconv 实现，需要系统 libiconv 的 locale_charset。
$(LIBRARY_NAME)_LDFLAGS += $(FRIDA_VENDOR)/libfrida-gum.a -lc++ -liconv
else
$(LIBRARY_NAME)_CFLAGS += -DGX_NO_GUM=1
endif

# 必须放在所有 *_CFLAGS = 赋值之后：Makefile 中段有一处 `*_CFLAGS = ...`
# 是纯赋值，若在这之前 += 会被整段覆盖，导致 UCDisassembler 仍走 5.0.1
# 分支、libcapstone6.a 进了链接命令却没有任何符号引用它（体积白涨）。
ifneq ($(wildcard $(CAPSTONE6_LIB)),)
$(LIBRARY_NAME)_CFLAGS += -DAIFLEX_USE_CAPSTONE6
$(LIBRARY_NAME)_LDFLAGS += $(CAPSTONE6_LIB)
$(info [AiFlex3] capstone6 enabled: $(CAPSTONE6_LIB))
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	# 产出两份 dylib：unsigned 版供 LiveContainer / 侧载注入器使用——它们靠
	# "签名缺失/无效"触发用用户导入的证书重签（JIT-less 模式必需）；若带 ldid
	# 假签名会被误判为已签好而跳过重签，dlopen 报 code signature invalid errno=1。
	# staging 里的那份照常 ldid -S 签名，供 .deb 和传统越狱注入使用。
	@STAGED_DYLIB=$$(find "$(THEOS_STAGING_DIR)" -name "$(LIBRARY_NAME).dylib" | head -1); \
	test -n "$$STAGED_DYLIB" || { echo "staged dylib not found"; exit 1; }; \
	cp "$$STAGED_DYLIB" "$(THEOS_PACKAGE_DIR)/$(ARTIFACT_BASE)-unsigned.dylib"; \
	codesign --remove-signature "$(THEOS_PACKAGE_DIR)/$(ARTIFACT_BASE)-unsigned.dylib"; \
	otool -l "$(THEOS_PACKAGE_DIR)/$(ARTIFACT_BASE)-unsigned.dylib" | grep -c LC_CODE_SIGNATURE || true
	@find "$(THEOS_STAGING_DIR)" -name "$(LIBRARY_NAME).dylib" -exec ldid -S {} \;
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/com.hoko20.aiflex3"
	@cp ThirdPartyNotices/NOTICE ThirdPartyNotices/DylixTouch-APACHE-2.0.txt "$(THEOS_STAGING_DIR)/usr/share/doc/com.hoko20.aiflex3/"

after-package::
	@cp "$(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/$(LIBRARY_NAME).dylib" "$(THEOS_PACKAGE_DIR)/$(ARTIFACT_BASE).dylib"
