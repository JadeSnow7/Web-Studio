# P3a：独立问题与不可变发送边界

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

待P2基础测试后派发。coder_p0_repair 独占 AgentController.swift、新 WorkspaceQuestionTests.swift、AgentControllerTests.swift 中受影响的确认步骤。只读AgentViews/Session/ResourceStore。另一coder同步P2保存/Registry，不改相同文件；主线程负责接口审查、共享记录和文档。

读取P3-coder总合同。先提供公共签名，再编码。保留AgentController当前选中问题的兼容投影（question可Binding、selectedResourceIDs、previewSnapshots、isReading、previewError、messages、run、runHistory）；问题集合有稳定UUID，newQuestion/selectQuestion仅选题，不取消旧题已发请求，不删除旧草稿。

- 问题状态分别拥有draft、selection、preview/confirmed generation、read token和结果、run/message记录。选中题变化让UI更新；后台完成写原questionID，绝不借currentQuestion定位。
- 空间级activeRequest（含questionID/runID）唯一；canSend/canRetry检查全空间槽，别从当前题run推断。另题可编辑/读预览但不能启动第二请求。取消明确操作active request及其原问题；cancelReading针对指定/当前读取题。关闭取消并等待全部读/请求及已取消任务的cleanup。
- 选择增删当场失效预览和确认，增加该题read generation且取消对应task。正在读取旧选择时不能接收迟到结果。切题可保留原题读取，其完成仅回原题。
- 新增显式confirmPreview或同等端口，只有当前完整成功预览可确认；读取、选择变化撤销确认。发送必须确认，UI后续提供“确认这些资料”按钮。编辑提问正文不需要重读资源；发送时冻结实际提问+已确认快照+Provider配置。读取错误或source数量不符不能确认。
- resource删除/实例重启后已有快照保留并可查看；它是采集时资料，UI须提示来源现状态差异。重试使用旧request，不读provider最新配置，不再调用reader。新预览绑定新instanceID。不要默默丢掉旧快照或重新采集。
- AgentRequest依旧只带本次question/snapshots/config，不带其他题或聊天历史。run(for:)可查当前载入空间全部题历史的不可变请求。newChat可保留为关闭清理的兼容清空端口，UI必须迁移到newQuestion；shutdown后任何newQuestion/send/read不得复活控制器。
- 中文自有错误，第三方错误原文可保留。保持现有12k/48k采集预算与裁剪instanceID。

必要受控测试：A题draft/preview确认与B题独立；A请求期间新B不取消A、B不能send，A完成不写B；选择变动后旧reader结果无效；切题读取回原题；取消迟到response不追加；关闭等已取消任务；retry reader调用不增加且旧config/snapshots不变；无确认拒发；newQuestion不清旧题；请求体不包含旧题。现有测试有“read后直接send”的地方加显式confirmPreview，不能放宽新契约以通过旧测试。

完成后回报用于UI的questions/currentQuestionID/select/new/confirmation/activeRequest/cancel/retry签名，指出WindowCoordinator/App退出计数应迁移到空间级isRequesting。完整测试统一由主线程录证。
