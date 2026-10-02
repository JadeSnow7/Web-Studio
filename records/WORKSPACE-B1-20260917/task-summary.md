# B1 核心及后续修复已实现；完整产品验收未完成

状态核对：2026-09-26。本地代码已实现工作空间与窗口唯一归属、各空间资源/布局/问题隔离、配置保存恢复、整批关闭准备、配置搜索和复制、显式双视图、独立问题与资料确认、中文控件、窄窗切换、终端结束/重启/目录修复。9 月 19 日又完成三项修复：归档后宿主窗口继续可用、未加载空间创建等待加载结果、配置诊断定位与重扫。源码及测试的 57 文件组合清单与现有文件一致。

## 验证时间线

| 检查点 | 结果 | 限制 |
| --- | --- | --- |
| B1 核心最终检查点 | [255 项 / 23 套件通过](evidence/p4-final-model-tests-02.execution.json)；[原生局部走查](evidence/native-final-review-01.json) | 修复前版本；离线 CLI 是协议夹具，不证明外部模型服务 |
| 早期 XCTest UI | [automation 初始化超时](evidence/p4-ui-tests-01.execution.json) | 当次未执行界面断言，保留为历史 |
| 9 月 18 日完整 XCTest 重跑 | [历史工具回执摘录](../DOCS-20260926/xctest-history-excerpts.json)：273 项中 261 通过、12 失败；模型日志为 260 项/25 套件通过 | 已进入 UI 断言，首屏复测 AX 窗口数为 0；最终源码根因未确定。原临时日志/结果包已不存在，计数来自当时工具输出，各种计数口径不相加 |
| 9 月 19 日三项修复 | 专项 12 项；[受影响回归 163 项 / 17 套件通过](review-fixes/evidence/main-final-regression.json)；[三条原生流程通过](review-fixes/evidence/native-final.json) | 仅验收 F1/F2/F3，没有证明上述全量 UI 失败已解决 |
| 9 月 26 日文档审查 | [源码、证据与文档核对](../DOCS-20260926/REVIEW.md) | 未新跑构建、测试或原生验收；不是新的产品通过回执 |

## 尚未完成

完整 B1 的真实 SSH/外部 Provider、中文 IME、VoiceOver、用户理解度、1440×900 和 1920×1080 精确样本，以及完整 A01–A16 路径仍未完整通过。早期终端或 CLI 的成功不外推为当前 B1 验收。完整指标保持 **undetermined**；验收标准见 [ACCEPTANCE.md](ACCEPTANCE.md)，目标合同及输入保持冻结。

原失败记录和版本绑定全部保留；9 月 19 日专项通过不替代全仓验收。本轮文档更新也不重新标记旧 task-state.json 的全仓 revision 为通过。原摘要保存在 [文档同步前摘要](../DOCS-20260926/prior-b1-task-summary.md)，后续修复详情见 [review-fixes](review-fixes/task-summary.md)。

**B1 实现及修复未提交、推送、合并或发布。** 性能路线曾交付独立本机测试包，其范围另见 [统一状态](../../STATUS.md)。
