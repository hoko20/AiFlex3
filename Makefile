PACKAGE_IDENTIFIER = com.hoko20.aiflex3
PACKAGE_NAME = AiFlex3
PACKAGE_VERSION = 3.3.0
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
    grep -v "frida/vendor/")

# Capstone 只保留头文件，实现由 frida-gum 静态库提供。
#
# 原因：libfrida-gum.a 内置了一份完整 capstone 5.0.1（cs.c/Mapping/MCInst/arch_*），
# 与仓库自己的 capstone 会全量重名，链接期必然 duplicate symbol。两边 ABI 又不同
# （cs_detail 里 MAX_IMPL_W_REGS 是 47 vs 20、MAX_NUM_GROUPS 16 vs 8，union 偏移
# 92 vs 154），所以既不能简单保留一份，也不能靠前缀重命名糊过去。
#
# 处置：把 x/capstone/include 降到 5.0.1（与 gum 内置版本一致），停止编译
# x/capstone/*.c，x/Disassembler 改用 5.0 的 cs_arm64 API（#include <capstone/arm64.h>）。
# 这样全进程只有一份 capstone 实现，且 UCDisassembler 用的头文件与实现同版本。
# 注意：x/capstone 下的 .c 仍是 6.0 源码，不要重新加入编译，否则立刻回到冲突状态。
CAPSTONE_INCLUDE = -I./x/capstone/include

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
# 注意：gum 的 capstone 与仓库 x/capstone 只在链接期按需拉取 .o，
# 本项目不引用 stalker/relocator，因此正常情况下不会发生 duplicate symbol。
FRIDA_VENDOR = ./frida/vendor
ifneq ($(wildcard $(FRIDA_VENDOR)/libfrida-gum.a),)
$(LIBRARY_NAME)_CFLAGS += -I$(FRIDA_VENDOR) -DGUM_STATIC
# -liconv：gum 自带 iconv 实现，需要系统 libiconv 的 locale_charset。
$(LIBRARY_NAME)_LDFLAGS += $(FRIDA_VENDOR)/libfrida-gum.a -lc++ -liconv
else
$(LIBRARY_NAME)_CFLAGS += -DGX_NO_GUM=1
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@find "$(THEOS_STAGING_DIR)" -name "$(LIBRARY_NAME).dylib" -exec ldid -S {} \;
	@mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/com.hoko20.aiflex3"
	@cp ThirdPartyNotices/NOTICE ThirdPartyNotices/DylixTouch-APACHE-2.0.txt "$(THEOS_STAGING_DIR)/usr/share/doc/com.hoko20.aiflex3/"

after-package::
	@cp "$(THEOS_STAGING_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/$(LIBRARY_NAME).dylib" "$(THEOS_PACKAGE_DIR)/$(LIBRARY_NAME)-$(PACKAGE_VERSION)-$(PACKAGE_ARCHITECTURE)-rootless.dylib"
