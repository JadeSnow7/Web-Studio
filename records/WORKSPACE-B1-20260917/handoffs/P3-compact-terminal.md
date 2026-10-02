# P3 窄窗与终端入口收尾

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

搜索完成后，UI coder继续独占 ContentView / WorkspaceSplitView / Web_StudioApp / ModelTests / Web_StudioTests，必要ResourceModel的描述更新接口需在主线程授权后取得写权。AgentViews/StartPage由另一coder处理，不要覆盖。

- 900×560应显式“内容 / 问答”切换，在toolbar内，不新增内容标题栏。宽窗仍内容+问答并存。切换只显示隐藏，保留布局/运行时/问题草稿；不要因窄窗把agentsWidth压到不可用。阈值由900/1440/1920样本复核。用户panel preference与临时compact choice区分。
- 问答toolbar在隐藏时仍显示真实请求中状态，不能只有AX label变化。切回可定位正在请求的问题。
- 保留所有原快捷键，Enter/Escape尊重IME markedText。自有toolbar/context menu/form/validation/status简中，技术专名保留。所有原面板捕获目标，切换时不可串写。
- restoredSSH显示“尚未连接”/“连接”；local显示“终端尚未启动”/“启动终端”。目录失效保留原描述、显示具体原因和“重新选择目录…”；捕获owner/resource在modal返回后复核，不创建另一个资源或静默回退Home。
- terminal resource菜单增加“结束会话”：确认live影响后调用store.endResourceSession，保留行/layout，不同于关闭资源；再启动形成新实例。进行中操作防重复，await后检查原owner，不从model当前空间取store。结束后的idle/exited等状态应可手动启动。
- sidebar隐藏时workspace menu仍可保存/设置/归档/恢复/关闭，所有入口可达。
- 补：narrow模式/布局草稿保留、end保留descriptor及新实例、失效目录重新选取、旧splitpicker跨空间无效/已挂载资源focus而非duplicate。
