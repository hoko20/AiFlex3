# AiFlex3

把 [FLEX](https://github.com/FLEXTool/FLEX) 从「手动点选的调试器」扩展成**可被 AI 编程操作**的 iOS 运行时调试平台：插件注入宿主 App 后，在进程内起一个标准 **MCP（Streamable HTTP / JSON-RPC 2.0）服务**，桌面端任意 MCP 客户端（Claude Desktop、Cursor、自研 Agent）即可读取界面、调用方法、注入触摸、抓包解密、反汇编。

```
包标识   com.hoko20.aiflex3
版本     3.3.1
产物     FLEX++-3.3.1-arm64-rootless.dylib
        com.hoko20.aiflex3_3.3.1_iphoneos-arm64.deb
目标     iOS 15.0+ / arm64 / 越狱（rootless，安装到 /var/jb）
构建     Theos library，ldid 假签名
```

## 1. 能力

**FLEX 原有能力全量保留**：视图层级、对象浏览器、堆与引用、网络记录、文件系统、UserDefaults、Keychain、Live Objects、DoKit 增强（日志/崩溃/CPU/内存泄漏/弱网/Mock/H5/取色）、Lookin/Reveal 式视图检查。

**`x/` 目录下的自研扩展**：

| 模块 | 内容 |
|---|---|
| `x/Decrypt` | 运行时抓明文：fishhook 打 `SSL_get_psk_identity`、OpenSSL `EVP_*` / `AES_*`、CommonCrypto 与哈希入口、`NSURLResponse` 回调，落 SQLite |
| `x/ClassDump` | 运行时类导出，含 Swift dumper 与打包 |
| `x/Disassembler` | capstone 5.0.1 AArch64 反汇编、函数边界识别、基本块 CFG、交叉引用、符号化；界面支持**汇编列表 / CFG 图形**双视图切换与 `.asm` 导出（**无伪代码生成器**） |
| `x/AppProtection` | 给调试面板自己上锁（`LAContext` 人脸/密码 + 时间码 + 计算器伪装），防止别人拿到手机就能翻数据 |
| `x/filza` | 文件管理入口，含 Mach-O load commands 查看 |

**MCP operation 层**：93 个 operation 归一到一个分发点，覆盖 observe / control / sensitive / script / trace / frida / disasm / dump / hook 九组，详细契约见 [`MCP-CAPABILITIES.md`](MCP-CAPABILITIES.md)。

**原生层只读观测（`aiflex_frida`，基于 frida-gum）**：模块与符号枚举（`modules` / `exports` / `imports`）、地址与符号互查（`resolve`）、线程列表（`threads`）、主线程符号化调用栈（`backtrace`）、映射区间（`memory_ranges`）、分页校验的内存读（`read_mem`，hex/utf8/u32/u64/ptr）、特征码扫描（`scan`，`??` 通配、4 秒预算）、崩溃记录（`crash_log`）。**只读**：不做 inline hook、不写内存、不打补丁、不开 Stalker。构建时没有 `frida/vendor` 会自动降级，不影响出包。

**机器码分析（`aiflex_disasm`，基于 capstone）**：地址反汇编（`at`）、函数边界 + 基本块 CFG + 调用点（`function`）、区间函数序言扫描（`scan_functions`，4 秒预算）、符号双向解析（`symbol`，`dladdr` / `-[Class sel]` / 类名 / `dlsym`）、交叉引用（`xref`，直接分支 + 8 字节指针字面量）、ObjC 方法体反汇编（`objc_method`）。**只读**：从不写代码字节。输入规模全部设硬上限——capstone 反汇编是同步阻塞、无中断点的，限时只能靠限输入。

**二进制导出（`aiflex_dump`）**：App Store 下发的 Mach-O 可执行段是 FairPlay 按页加密的，磁盘上永远是密文，但内核解密后映射进内存。本引擎按 segment 表把内存里的明文搬到 `Documents/AiFlex3Dump/`，并把 `LC_ENCRYPTION_INFO_64.cryptid` 置 0，得到可直接丢进 IDA / Hopper / Ghidra 的明文二进制。**只读运行时**：只读内存 + 写一个新文件。读不到的页填零并计入 `failedBytes`，绝不把 partial 报成完整。导出文件不带有效签名，**只能静态分析，不能安装运行**。

**真实触摸注入**：`IOHIDEventCreateDigitizerEvent` + `UITouch` 私有 setter，tap / double_tap / long_press / swipe / drag / pinch / rotate。

**代码改写（`aiflex_hook`，唯一的写类工具，独占「代码改写」开关）**：inline hook（`hook` / `unhook`，`GumInterceptor` trampoline）、调用记录（`events`，无锁环形缓冲抓 x0-x3 与返回值）、字节补丁（`patch`，只写 4 字节对齐的整指令）、逐条还原（`restore`）、端到端自检（`selftest`，attach `getpid` 真调三次再 detach 验证）。目标可以给地址、`module`+`name` 或 `class`+`selector`（`meta=true` 是类方法）。写入前三重校验（4 字节对齐 / 可执行页 / 非自身镜像），补丁自动备份 + 写后读回 + 不一致自动回滚。**只在本进程有效**：进程结束后 trampoline 与补丁都消失，审计日志只供查看、不自动重放。

## 2. 安装

```bash
# 已构建的 deb
dpkg -i com.hoko20.aiflex3_3.3.1_iphoneos-arm64.deb
# 或直接把 dylib 放进
/var/jb/Library/MobileSubstrate/DynamicLibraries/FLEX++-3.3.1-arm64-rootless.dylib
```

装完**重启目标 App**（不是重启桌面），FLEX 悬浮工具条上会出现 **AiFlex3** 按钮，点进去是控制面板。

## 3. 构建

依赖：Theos（含 `vendor/include`、`vendor/lib`）、`ldid`、`xz`、iOS SDK 15+。

```bash
export THEOS=/opt/theos
make clean package FINALPACKAGE=1 DEBUG=0 -j1
# 产物：FLEX++-3.3.1-arm64-rootless.dylib + com.hoko20.aiflex3_3.3.1_iphoneos-arm64.deb
```

CI：`.github/workflows/build.yml`，push 到 `main` 自动在 `macos-latest` 上构建并上传 artifact `AiFlex3`。注意该 workflow 只拉取 Theos 的 `vendor/include`、`vendor/lib` 两个子模块（`vendor/orion` 已私有，不能全量 init）。

## 4. 连接 MCP

1. 手机面板里确认服务状态「运行中」，记下端口（默认 `8790`）。
2. 面板「服务设置」里把 `endpointHost` 改成**手机局域网 IP**（默认 `127.0.0.1` 只能本机访问）。
3. 「复制 MCP 客户端配置」，粘进桌面客户端：

```json
{
  "mcpServers": {
    "aiflex3": {
      "type": "http",
      "url": "http://192.168.1.10:8790/mcp",
      "headers": { "Authorization": "Bearer <访问令牌>" }
    }
  }
}
```

4. 先调 `aiflex_status` 核对 bundleID 与授权组，再按需在面板打开「敏感读取 / 界面控制 / 脚本执行 / 方法追踪」。

授权关闭时对应工具**不会出现在 `tools/list`**，从协议层就不可见。

## 5. 目录

```
FLEXAiFlexMCPServer.m        进程内 MCP 服务：nw_listener + 手写 HTTP/1.1，鉴权、看门狗、工具组
FLEXAiFlexRuntime.m          operation 分发与语义层（弱引用 id 表、参数校验、副作用边界）
FLEXAiFlexFrida.m            原生层只读观测（frida-gum）：模块/符号/线程/内存/扫描/调用栈/崩溃
FLEXAiFlexDisasm.m           机器码分析（capstone）：反汇编/函数 CFG/符号解析/交叉引用/ObjC 方法体
FLEXAiFlexDumper.m           二进制导出：按 segment 搬明文 Mach-O、cryptid 置零、逐页失败记账
FLEXAiFlexHook.m             代码改写：inline hook / 字节补丁 / 无锁事件缓冲 / 备份还原 / 自检
FLEXAiFlex3ViewController.m  控制面板：端点/令牌/工具开关/现场报告
FLEXAiFlex3UI.m              面板视觉组件
FLEXAiFlexTouchDriver.m      触摸注入后端
FLEX*.m                      上游 FLEX 4.x（未改动）
FLEXDoKit* / FLEXLookin* / FHS* / RTB*   DoKit 与 Lookin 能力移植
x/                           扩展工具（Decrypt / ClassDump / Disassembler / AppProtection / filza）
```

## 6. 使用边界

- 服务是**明文 HTTP + Bearer 令牌**，只应在可信局域网内开启；「授权保护」默认开启，关掉后同一网段任何人都能连。
- 能读取界面文字、网络正文、沙盒文件、Keychain 元数据；只在有权限的测试设备上使用。
- `invoke_method` 会真实执行方法，只对黑名单里的 5 个 selector 做了拦截，误调可能崩溃。
- 长操作（`sandbox_grep`、`capture_screen`、`view_tree`、快照）在主线程同步执行，大页面上会卡住宿主。
- 反汇编、内存读、二进制导出都在**独立串行队列**上跑，不占主线程；但 `scan_functions` 与 `xref` 仍是同步阻塞调用，大区间会独占该队列几十毫秒到几秒，期间其它同组请求排队。
- `aiflex_dump` 导出的 Mach-O 不带有效签名（`cryptid` 已改、哈希全对不上），**只能静态分析，不能安装或运行**。取文件用 `sandbox_read` 读 `relativePath`，单次上限 512 KiB，大文件靠 `next_offset` 续读。
- `aiflex_hook` 是唯一会改变宿主行为的组，**默认关闭且必须单独授权**。打开后任何连上的客户端都能改运行中的指令：`patch` 写错位置会让目标进程立刻崩溃，`hook` 高频函数会明显拖慢 App。所有改动只在本进程内有效，进程结束后全部消失；`restore` 依赖内存中的备份，**崩溃重启后无法从磁盘重放**。改动前先跑 `selftest`，改完用 `aiflex_read` 复核，不要凭 hook 返回成功推断逻辑正确。

## 7. 许可

上游 FLEX 代码遵循其原始许可；触摸注入部分派生自 KIF / EarlGrey，见 `ThirdPartyNotices/DylixTouch-APACHE-2.0.txt`；其余见 `ThirdPartyNotices/NOTICE`。
