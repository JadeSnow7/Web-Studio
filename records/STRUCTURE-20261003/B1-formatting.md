# B1 格式化与历史证据边界

本次只格式化 Swift 源码，无手工生产代码修改。

- 格式化前：`9109b01554163cdc466a03d3342e53430f0016f1`。
- 格式化后：`a9023121e298d2bf090c9e1bc662fa55235daa09`。
- 分支：`refactor/structure-20261003`。
- Xcode 工具：`xcrun swift format --version` 输出 `main`；Swift 6.4，swiftlang-6.4.0.34.1。
- 配置：`.swift-format` 仅设 `lineLength: 120`；其余默认，`DoNotUseSemicolons` 保持开启。
- 输入：`Web Studio/`、`Web StudioTests/`、`Web StudioUITests/` 的 58 个 Swift 文件，56 个发生变化。
- `.c`、`.h`、`scripts/`、`Vendor/` 和全部旧记录未修改。

**此前的源码摘要对应格式化之前的版本。** 不更新旧记录里的 SHA-256，也不把旧执行证据视为本次新源码的运行证据；旧记录继续绑定各自记载的 revision。`.git-blame-ignore-revs` 登记格式化提交，便于追溯语义修改。

## 验证

| 命令或核验 | 退出码 | 结果 |
| --- | --- | --- |
| main 前置 `./scripts/check.sh` | 0 | build 0，unit 0；283/283，失败 0，跳过 0，27 suites |
| B1 后 `./scripts/check.sh` | 0 | build 0，unit 0；283/283，失败 0，跳过 0，27 suites |
| 第一遍与第二遍 Xcode 格式化 | 各 0 | 58 个文件的 SHA-256 完全一致 |
| 主线程从原提交逐文件格式化并比对 | 0 | 58/58 与工作区逐字节相同，无混入手工修改 |
| `git diff --check` | 0 | 通过 |
| 暂存扫描 | 0（复核完成） | 无私钥、provider token、.env 文件；15 个字面凭证命中为旧测试占位值，4 个非回环 IP 命中为旧文档 IPv6 测试地址 |
| UI | 未运行 | 本阶段不据此新增 UI 验收结论 |

相对基线通过数不变。本说明与 blame 元数据后置独立提交，因为格式化提交本身只允许源码格式结果和配置文件。

## 本地原始证据

目录：`/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/`。以下摘要绑定本机保存的原始文件；它们不包含在本次 Git 提交中。

| 相对路径 | SHA-256 |
| --- | --- |
| `../web-studio-preflight.log` | `700a4be78e5bebc2cdf7ae07d2cb8bf195b5a92852219a82ca50af104595dfe5` |
| `check-b1.log` | `25c528ffd4d2a68e9e59908120fc508768f70645eeca4c051bf3eca24432bc92` |
| `swift-before.sha256.json` | `c2209071d560e60beb8fa8ea00566a08178cba57f9db7b4939ae257913cf1700` |
| `swift-pass1.sha256.json` | `08b306ef6921f9d53d192a0bfcc47d920b4a042d2d4165154d42ae2b7a3f62a1` |
| `swift-pass2.sha256.json` | `08b306ef6921f9d53d192a0bfcc47d920b4a042d2d4165154d42ae2b7a3f62a1` |
| `primary-format-review.json` | `d4146320cb46bff49d450045235439c1336273ae01d9f6d4d487fa09356ea56c` |
| `staged-scan-b1.json` | `bff3fa61601f83063094a64c5251d0a75dca5261b2a34966c381b7a704d664d2` |
