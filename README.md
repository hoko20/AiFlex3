# AiFlex3

把 [FLEX](https://github.com/FLEXTool/FLEX) 从「手动点选的调试器」扩展成**可被 AI 编程操作**的 iOS 运行时调试平台：插件注入宿主 App 后，在进程内起一个标准 **MCP（Streamable HTTP / JSON-RPC 2.0）服务**，桌面端任意 MCP 客户端（Claude Desktop、Cursor、自研 Agent）即可读取界面、调用方法、注入触摸、抓包解密、反汇编。

```
包标识   com.hoko20.aiflex3
版本     3.0.0
产物     FLEX++-3.0.0-arm64-rootless.dylib
        com.hoko20.aiflex3_3.0.0_iphoneos-arm64.deb
目标     iOS 15.0+ / arm64 / 越狱（rootless，安装到 /var/jb）
构建     Theos library，ldid 假签名
```

## 1. 能力

**FLEX 原有能力全量保留**：视图层级、对象浏览器、堆与引用、网络记录、文件系统、UserDefaults、Keychain、Live Objects、DoKit 增强（日志/崩溃/CPU/内存泄漏/弱网/Mock/H5/取色）、Lookin/Reveal 式视图检查。

**`x/` 目录下的自研扩展**：

| 模块 | 内容 |
|---|---|
| `x/Decrypt` | 抓包与解密：fishhook 打 `SSL_get_psk_identity`、OpenSSL `EVP_*` / `AES_*`、`CFNetworkCopySystemProxySettings` |
| `x/ClassDump` | 运行时类导出，含 Swift dumper 与打包 |
| `x/Disassembler` | 基于 capstone AArch64 的反汇编与伪代码 |
| `x/AppProtection` | App 保护绕过检测 |
| `x/filza` | 文件管理入口 |

**MCP operation 层**：40+ 个 operation 归一到一个分发点，覆盖 observe / control / sensitive / script / trace 五组，详细契约见 [`MCP-CAPABILITIES.md`](MCP-CAPABILITIES.md)。

**真实触摸注入**：`IOHIDEventCreateDigitizerEvent` + `UITouch` 私有 setter，tap / double_tap / long_press / swipe / drag / pinch / rotate。

## 2. 安装

```bash
# 已构建的 deb
dpkg -i com.hoko20.aiflex3_3.0.0_iphoneos-arm64.deb
# 或直接把 dylib 放进
/var/jb/Library/MobileSubstrate/DynamicLibraries/FLEX++-3.0.0-arm64-rootless.dylib
```

装完**重启目标 App**（不是重启桌面），FLEX 悬浮工具条上会出现 **AiFlex3** 按钮，点进去是控制面板。

## 3. 构建

依赖：Theos（含 `vendor/include`、`vendor/lib`）、`ldid`、`xz`、iOS SDK 15+。

```bash
export THEOS=/opt/theos
make clean package FINALPACKAGE=1 DEBUG=0 -j1
# 产物：FLEX++-3.0.0-arm64-rootless.dylib + com.hoko20.aiflex3_3.0.0_iphoneos-arm64.deb
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
FLEXAiFlexMCPServer.m        进程内 MCP 服务：nw_listener + 手写 HTTP/1.1，鉴权、看门狗、5 组工具
FLEXAiFlexRuntime.m          operation 分发与语义层（弱引用 id 表、参数校验、副作用边界）
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

## 7. 许可

上游 FLEX 代码遵循其原始许可；触摸注入部分派生自 KIF / EarlGrey，见 `ThirdPartyNotices/DylixTouch-APACHE-2.0.txt`；其余见 `ThirdPartyNotices/NOTICE`。
