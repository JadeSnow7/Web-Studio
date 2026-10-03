# B3 前置测试与旧实现结果

用户已确认 B3 单一状态来源设计，并批准关闭后拒绝直接写 question；明确保留 shutdownAndWait 后 newChat 的内部清空。继续 B4 的授权已给出，推送和开 PR 未授权。

起点：`27183e071ad5f7e437dd6384f9b3c90dc7ca0b20`，分支 `refactor/structure-20261003`，起始工作树干净。本提交仅添加测试与记录，31 个生产 Swift 文件 SHA-256 均未变化。旧测试每一行按原顺序保留；没有放宽断言。

## 特征基准：先在旧实现通过

| 新测试方法 | 固定的行为 |
| --- | --- |
| newChatAfterShutdownClearsQuestionStateWithoutReopeningController | 先填充消息、草稿、快照和运行历史，关闭后清空投影与字典；run 为 nil，仍不允许新问题和发送 |
| emptyPreviewCannotBeConfirmed | 空预览不能确认，字典确认标志为 false |
| rereadingConfirmedPreviewClearsSnapshotsAndConfirmationUntilCompletion | 重读期间快照为空且确认取消，完成后仍需重新确认 |
| resourceSelectionChangeInvalidatesConfirmedPreview | add/remove 两个参数场景分别取消预览和确认，不可发送 |
| sendFreezesDraftBeforeClearingProjectedAndStoredDraft | 发送前草稿进入实际请求及用户消息，然后输入和字典草稿为空 |
| observedObjectDraftBindingPublishesAndWritesQuestionState | 真实 ObservedObject 可写绑定更新草稿并触发通知 |
| backgroundQuestionReadCompletionPublishesAndKeepsCurrentProjection | 后台问题读取完成发通知且不污染当前问题，切回能看到结果 |

上述 7 个方法加入后执行 `./scripts/check.sh`，exit 0；build 0、unit 0；290/290 passed，0 failed、0 skipped，27 suites。相对原有 283 项增加 7 项；参数化 add/remove 有两次运行，Xcode 顶层按一个测试方法统计。

## 批准的行为修正：旧实现必须失败

在特征基准通过后，新增 `closedControllerRejectsDirectDraftEdits(waitForShutdown:)`，分别覆盖 shutdown 与 shutdownAndWait。先设置非空旧草稿，关闭后直接赋新值，期望投影和字典均保留旧值。

单独 xcodebuild 运行此测试，exit 65：1 个方法失败、2 个参数运行失败，passed 0、skipped 0。失败是运行时断言 `controller.question == "draft before shutdown"`；实际值是 `edit after shutdown`，字典仍保留旧值。构建通过，非环境或编译失败。原始诊断块见 `B3-pretests-red-output.txt`，它逐字节截取自完整原始日志；完整日志与命令在下列证据目录。

本提交刻意保留该失败测试，生产实现尚未开始；后续 B3 必须让同一测试通过，同时保留上述绿色特征测试。新增红测后的全量测试未运行，已单独运行红测，不声称此测试提交全绿。UI 未运行。

## 证据

本地目录：`/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/b3-pretests/`。原始日志、xcresult、命令参数、阶段快照与生产摘要均保留。主线程已读原始结果，并独立核对生产摘要及旧测试行未变。

| 文件 | SHA-256 |
| --- | --- |
| `characterization-check.log` | `8634534af6de752d90b7f1f7f3c6d84ccdc620db4ffb84d67d49fb60d29b8913` |
| `characterization-check.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `shutdown-edit-red.log` | `dad84e4fce7066033fdca78e058efa2c41013ad984f6a74b52bf9b04c005b98a` |
| `shutdown-edit-red.exit` | `979b894f2d91bf199766571d58024f020d1a44a417da5f48e1fa1cdf554a14f5` |
| `shutdown-edit-command.json` | `4505b0f74687b853f2a958d49bdb27ef44e18ba3250f311e7dcdf56bb94980f7` |
| `production-before.sha256.json` | `bf3a42d43902ad1b49e75c7b2a6927c3a5b970dc82f9746f9216eb69724e0f35` |
| `WorkspaceQuestionTests.characterization.swift` | `814e237f399d48220f02bb930d6e6a7be6a26d8ec6c90ce796d20143b9e07a1a` |
| `WorkspaceQuestionTests.with-shutdown-test.swift` | `79ad1ae5fd808e244fd3253421f1dbfdcd6aacfcdfa003b2de74459162d126e2` |
| `primary-pretests-review.json` | `b5abece291b2310b3cddc0b92e00d843d1ed2db4993b3e8ef09a429cb3173543` |
