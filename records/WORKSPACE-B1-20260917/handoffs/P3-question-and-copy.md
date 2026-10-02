# P3 问答来源与自有文案收尾

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

在 Registry/copy 修复及统一测试后，由 coder_workspace_core 取得以下独占路径：AgentViews.swift、StartPageView.swift、StudioDesign.swift 的 ProviderStatus 显示扩展、ProviderSettings.swift、AgentService.swift 的 LocalizedError 文案、WebRuntime.swift 的应用自有错误视图；必要 AgentController 状态格式化 helper 与独立测试。ContentView 继续归 UI coder。终端后端14文件禁止修改。

1. 输入框上方常显本题 selectedResourceIDs 的来源标签。每个标签有标题/短ID、待读取或采集时间、已截断、读取失败文字；选中已关闭资源不能静默消失。失败时提供重读与移除，移除使确认失效。资料未重读不伪造实时/过期判断。限制区域高度并可滚动，900×560不得挤掉输入框。
2. 问答标题、新问题空态、收起问答、用原快照重试等语义准确。保持原 Controller 单问题快照、显式确认、单请求含取消清理不变。不把问题列表称连续对话。
3. StartPage去28pt hero和RadialGradient，改为轻量实际入口；常用入口/最近资源保持，无预设资源。术语统一常用入口，不保留New Tab fallback。
4. Provider设置/状态/应用自有错误文案简中。外部错误、URL、JSON keys、CLI协议、system prompt、系统/第三方内容不作替换。保留技术专名。不要全文件盲replace协议文本。
5. 有意义的标签状态逻辑可抽小型pure helper测试；现有模型/服务tests会受文案影响，要同步准确预期，不删除失败断言。不修改其它coder拥有的Web_StudioTests，报告所需调整给主线程。

完成需列真实文件/函数/反例，parse不算执行验收。主线程统一Xcode及原生走查。
