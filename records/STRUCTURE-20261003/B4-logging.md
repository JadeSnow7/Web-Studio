# B4 生命周期与错误日志

基线：`9e0170431393c1575106e830608a627480d1a80c`。新增 StudioLog.swift，集中声明 agent、workspace、terminal、persistence 四类 os.Logger；subsystem 取当前应用 Bundle ID，本轮运行实际为 com.huaodong.Web-Studio。仅修改 AgentController、WorkspaceSession、WorkspaceRegistry、WorkspaceSaveController、TerminalSession 五个既有文件；没有修改 VT 后端、测试、项目配置、脚本或业务错误映射。

主线程逐段审查后另做机械复核：从五个既有文件剔除新增日志调用和 import os 后，内容与 B3 基线逐字节一致。辅助函数的所有状态分支仅选择日志事件和等级，不抛错、不增加业务断言、不修改业务状态或调度。没有增加配置、存储、重试。

## 事件范围与隐私

| 类别 | 源码覆盖 | 本轮实际条数 |
| --- | --- | ---: |
| agent | 公共请求启动、完成、失败和取消路径 | 34 |
| workspace | 目录加载及配置诊断、工作区加载成功/失败、实际关闭开始/完成 | 100 |
| terminal | 现有 PTY/Ghostty 启动成功/失败、退出及关闭路径；未修改 VT | 98 |
| persistence | 保存控制器的自动/手动保存，以及注册表复制、归档、取消归档的直接保存成功/失败 | 87 |

共捕获 319 条、19 种事件。主线程逐条验证 eventMessage 仅含固定事件、UUID、整数或布尔，生命周期均 Info，失败均 Error。全部 42 处源码日志插值白名单复核通过：没有问题、回答、快照、密钥、命令参数、终端输出或任意错误描述。没有插入路径或 URL，因此无路径/URL 的公开插值；系统日志自带的进程路径元数据不属于应用消息。

以下四个事件仅静态审查，本轮未触发：request_state（辅助函数完整状态分支）、terminal_io_failed、terminal_start_rejected、workspace_directory_load_failed。未声称日志的每条分支均已动态覆盖。

采集使用 log stream，限定当前应用 subsystem 和四 category；测试结束后终止本次创建的采集子进程，退出码 -15（预期 SIGTERM），不是应用失败。未修改系统日志配置。

## 验证与保留失败

| 验证 | 退出码 | 结果 |
| --- | ---: | --- |
| 第一次 ./scripts/check.sh | 65 | build 65；Logger 插值中的属性引用缺少显式 self，单元测试未开始 |
| 修正后的 ./scripts/check.sh | 0 | build 0、unit 0；291 passed / 0 failed / 0 skipped，27 suites |
| 六源码两遍格式化 | 0 / 0 | 两遍字节相同，最终源码与测试时哈希一致 |
| git diff --check | 0 | 无空白错误 |
| 新文件 diff --no-index --check | 1 | 与 /dev/null 不同的正常 diff 状态，无空白诊断 |

原有 283 项与新增 8 项均保留；29 个测试源码（含 UI 源码）与前置测试提交字节相同。UI 未运行。首轮失败 check.log/check.exit 和初版 diff 原样保留；成功复验单独保存在 attempt2/。

初稿新增日志 helper 曾带额外断言。自动审批首次拒绝修改该断言，主线程补充“新文件、新断言、不属于基线契约”的证据后，纯日志修正经复审通过；详见 approval-review.md。最终代码没有这条新增断言，也未删除基线断言。没有剩余审批阻塞。

## 证据

目录：`/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/b4-logging`。主线程已核对原始输出、运行日志、实际 diff 和源码摘要；没有仅凭编译成功判定日志内容合格。

| 文件 | SHA-256 |
| --- | --- |
| `check.log` | `b11336823add3d3411ca2bc88c3b7297a9877b5564170c4ebe33ba53c546c979` |
| `check.exit` | `979b894f2d91bf199766571d58024f020d1a44a417da5f48e1fa1cdf554a14f5` |
| `attempt2/check.log` | `c614d1427de1732e405cc6960210ca8ec4d1d8ea12e53af6208b192b51fc94df` |
| `attempt2/check.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `attempt2/unified-log.ndjson` | `df4304f941fef3bdcf74b7792d5eba962aa86794862ddc406ee0a288854c259e` |
| `attempt2/log-stream-result.json` | `6eea055204e7d47731601e1b960fb766533196cc71a7eac3238334b21d34b634` |
| `primary-static-review.json` | `7bbf193da7c4d3e5b15312a42f36e2a6bdc9626250c2dee677a67e98de0fa14f` |
| `primary-runtime-review.json` | `c7548f2d22f92ea0225516ba511bcd0809ac74b0ddab949e5be7d4f53b83851c` |
