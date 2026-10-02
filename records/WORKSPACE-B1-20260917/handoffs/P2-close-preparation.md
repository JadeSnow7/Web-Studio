# P2c batch2B：先准备整批保存，再清理

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

等待2A实际保存/目录/按需载入端口审查后，由同一 core coder 独占 Registry、WindowCoordinator、必要 SaveController 端口和新 WorkspaceClosePreparationTests（RestorationTests 由另一 coder 独占）。UI 不在此批；保持源代码为接口权威。

## 需要的行为

1. 模型层定义可注入的保存失败选择（重试、取消、不保存）；无 UI resolver 时默认取消，模型不得弹 NSAlert。关闭方法返回 Bool 并可丢弃返回值以兼容旧调用。
2. 单空间、窗口整批、应用整批共享保存准备。每批先封锁相关 coordinator 的创建/选择/异步load，收集全部 Session，按稳定顺序 flush；失败交 resolver。任何取消都在清理前返回 false，解除封锁，已有 Session/进程/问答继续可用。
3. 不保存的选择先记录在本批，不立刻调用永久 suspend。全批允许关闭后，才对这些 Session 调用 discardPendingChanges，等在途回执；其他 Session 也在关闭前停止保存观察队列。最后实际 savedConfig 决定目录内容，不能把丢弃的内存名字/布局留作目录事实。
4. 准备通过后等待每个 Session.close，再去掉 owner/loaded/保存控制器。临时项或从未成功落盘的项移出目录；真正已保存项保留。清理阶段重复请求等待同一 Task；取消后的再次关闭可正常进行。
5. 应用退出必须先准备所有窗口，不能“准备窗口一→清理窗口一→窗口二取消”。临时空间保存/丢弃提示由 UI 上层处理，模型 nil repository 继续支持旧无磁盘测试。
6. 归档读取最新配置。loaded 空间成功写 archived=true 后才关闭；失败取消应恢复内存归档标志并保留运行会话。选择不保存关闭不得返回归档成功。unloaded 空间纯配置 CAS 写回即可。恢复归档只改纯配置，明确打开后才实例化 Session。
7. 窗口/应用批量清理内部选择剩余空间不能更新 lastActivatedAt，否则重启恢复目标会变成清理顺序的最后一项。保留用户关闭前的最后活动记录；单空间关闭后真实显示的下一空间可正常记录活动。

## 必须能发现错误的测试

- 单空间 save failure→cancel：未调用shutdown；修改/再次save/再次close可用。
- A失败选discard，B失败选cancel：A/B均存活，A controller未永久停止，随后retry可成功。
- 两窗口 app-close 在第二窗口cancel：第一窗口仍存活。
- discard后晚写不能发生；reopen得到最后实际落盘配置，关闭中的首写成功/失败两种都区分。
- first named save失败后discard：目录中没有不存在文件的幽灵项。
- close与重复close等待同一受控cleanup，不重复释放。
- 归档包含最新名称/资源而非Registry旧缓存，关闭后从常用列表消失，恢复无终端启动。

注入临时root和受控writer/cleanup，不依赖NSAlert或真实用户目录。先parse和差异检查，主线程统一测试。

## 端口与测试注入补充

Registry 可增加 saveWriter: WorkspaceSaveController.Writer? 注入并用于创建/恢复后的 controller，以便测试按空间ID控制失败、恢复和在途写入。关闭 resolver 建议使用 @MainActor (WorkspaceSession, String) async -> WorkspaceSaveFailureChoice；实际 Swift 签名确定后立即交接。窗口和应用只通过统一整批准备机制关闭，UI 不复制 flush/discard 循环。保存成功的 controller 也应在清理前停止观察，避免 cleanup 期间生成无意义的新写入。

准备阶段仍有异步回调：界面用 isClosing 禁用变更操作；不能仅封锁select而让名称/目录表单继续写入。全批flush后，在真正停止队列前复核已通过项的配置generation/纯配置是否又变化，必要时再flush；失败仍可整批取消。运行态/标题更新不会改变配置无需重写。不要在prepare前清问答、拆owner或把Session.isClosed置true。
