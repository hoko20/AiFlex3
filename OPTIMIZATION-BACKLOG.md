# AiFlex3 优化清单（Backlog）

> 状态：2026-11-24 · 基于当前代码逐条核查（不是泛泛而谈）
> 对应版本：3.5.2 · 仓库 https://github.com/hoko20/AiFlex3
> 用法：在想做的条目前打勾或直接报编号，我按 1→2→… 顺序实现并出下一版。

---

## A. 已完成（本轮顺手修掉）

- [x] **A1 文档版本残留 3.1.0** — `MCP-CAPABILITIES.md` 顶部版本、产物名停在 3.1.0，与代码 3.5.2 不符。已对齐 3.5.2、产物名加 AiFlex2 前缀、补版本沿革与 QUICKSTART 入口。commit `9139b90`。

---

## B. 建议优先做

### 1. 写类操作全跑在主线程，长操作卡 UI

- **证据**：`FLEXAiFlexMCPServer.m:668-741`，control 类 operation 的分发全部是 `dispatch_async(dispatch_get_main_queue(), ^{...})`。read/sensitive 已走专属串行队列，write 路径没有。
- **影响**：`aiflex_dump`（512 MB 导出）、`aiflex_disasm function`（capstone 同步阻塞、4 秒预算）、`aiflex_frida scan`（4 秒预算）如果从 control 路径触发，宿主 App 界面会冻结。用户感知就是"AI 一操作 App 就卡一下"。
- **改法**：在 Runtime 里区分"必须主线程"（UIKit 视图树、手势、控制器导航）和"纯计算/IO"（dump、反汇编、文件读写、扫描）。后者派到专属串行队列（可复用已有的 `com.hoko20.aiflex3.dumper/.disasm` 队列），只有读写 UI 对象的一小段 dispatch 回主线程。注意对象句柄注册表要加锁或限制在单队列内访问。
- **成本**：中。风险点在主线程与后台队列的对象句柄交接，需要回归 `invoke_method` / `object_info` 全链路。
- **价值**：高。唯一直接影响使用体验的一项。

### 2. 手写 HTTP 不支持 chunked 请求体

- **证据**：`FLEXAiFlexMCPServer.m:578-582` 只读 `Content-Length`；没有解析 `Transfer-Encoding: chunked`，遇到时 length=0，body 被当成空 → `:603` JSON 解析失败 → 400。
- **影响**：Claude Desktop / Cursor / 标准 MCP SDK 都发 Content-Length，日常不受影响。走 HTTP 代理、某些流式客户端、或手工拼的 chunked 请求会直接失败。
- **改法**：在 `parseHeadersAndBody` 里加 chunked 解码：按 `\r\n` 分块，读十六进制长度行 → 读该长度数据 → 跳过尾部 `\r\n` → 长度 0 结束；同时拒绝 `Content-Length` 与 `Transfer-Encoding` 同时出现（请求走私口径）。保持现有 2 MB 上限，按累计字节检查。
- **成本**：低。改动局限在一个函数，可加纯 C 单测覆盖分块/截断/超限三种输入。
- **价值**：中。兼容性补强。

### 3. 抓包看不到自定义请求头

- **证据**：`FLEXAiFlexRuntime.m:1332` 只取 `Content-Type` 一个头字段，`network_detail` 没有 headers 字段。
- **影响**：现在很多 App 把签名、token、设备指纹放在 `X-Sign` / `Authorization` / `X-Device-Id` 里，这些参数 AI 完全看不到，抓包能力残半。
- **改法**：`network_detail` 增 `requestHeaders` / `responseHeaders` 字典，复用 `DXShort` 做单值截断（如 512 字符/值、总 8 KiB）；整条记录仍归 sensitive 组，不新增开关。同步更新 `MCP-CAPABILITIES.md` 与 `MCP-QUICKSTART.md` 的字段表。
- **成本**：低。
- **价值**：中高。与 recently 补的 §5.4 请求参数说明直接配套。

---

## C. 可选（收益递减 / 看你场景）

### 4. 100.64/10 被当私网放行

- **证据**：`FLEXAiFlexMCPServer.m:479` `PrivateIPv4()` 把 `0x64400000/0xFFC00000` 判为私网，注释写明为 Tailscale / CGNAT。
- **现状**：手机装 Tailscale 后，挂进同一 tailnet 的任意公网机器都能连 MCP；有 Bearer token 兜底，不算裸奔。
- **改法**：加 `FLEXAiFlexMCP.allowCGNAT` 开关（默认关），只在打开时才放行 100.64/10。
- **成本**：低。**价值取决于你是否用 Tailscale 远程连**——常用就别动，不用就收紧。

### 5. 无 TLS

- **证据**：`nw_listener` 裸 HTTP + Bearer token 明文传输。
- **影响**：同一 WiFi 下可嗅探 token。本地调试可接受，公共 WiFi 有实际风险。
- **改法**：要么上 TLS（需要自签证书 + 客户端信任，移动端麻烦），要么改成"仅允许 loopback / 需 USB 反向代理"。后者更现实。
- **成本**：高。**价值**：看场景，一般不建议为本地调试工具引入证书管理。

### 6. tools/list schema 超长单行

- **证据**：`FLEXAiFlexMCPServer.m:92` / `:118` 把十类工具的完整 JSON schema 塞在单行里，单行两千+字符。
- **影响**：改一个 operation 参数要在超长行里找位置，diff 不可读，容易误伤。
- **改法**：抽成多行的静态字典字面量，或按工具拆成独立函数返回。
- **成本**：低（纯排版）。**价值**：低，但每次改契约都受益。

### 7. 无自动化测试 / CHANGELOG

- **证据**：仓库无 `CHANGELOG.md`，无测试 target；93 个 operation 的参数校验只能靠真机 + CI 编译回归。
- **改法**：先加 CHANGELOG（从 3.0.0 倒序补，成本几乎为零）；测试部分给 `DXShort` / `DXBody` / `safePath` / chunked 解码这类纯函数加 XCTest，UI 依赖重的放真机验证。
- **成本**：中高。**价值**：长期，但当前迭代速度下优先级低。

---

## D. 明确不动

- 上游 FLEX 自带 TODO（`FHSSnapshotView.m:242/277`、`FLEXLookinInspector.m:148/410/416`、`FLEXAPNSViewController.m:132` 等）——第三方代码，改了会在上游更新时冲突。
- `x/capstone` / `x/capstone6` 的第三方源码 TODO——供应商代码。
- 抓包 50 条窗口 / body 16 KiB 截断 / dump 512 MiB 上限——这些是有意的安全与性能护栏，不是缺陷。

---

## 我的推荐顺序

**1 → 3 → 2 → 6**（先解决卡顿，补上抓包头字段，再补 chunked 兼容，最后顺手拆 schema）。
4/5 看你的网络使用方式决定，7 可以合并到下一版的文档工作里。
