# P3c：导航、显式并排、复制与中文界面（待 P2 原生入口之后）

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

coder_p0_repair 独占 ContentView.swift、WorkspaceSplitView.swift、StartPageView.swift、Web_StudioApp.swift、必要 PanelCoordinator/ResourceModel 显示文案与模型测试。不能与 P2 UI 同时写这些文件；按阶段接续，不改终端后端。Registry 若需要新领域端口，先请主线程协调 core coder，不在 UI 另造保存路径。

- split() 无参数改为打开本空间资源选择器；可选现有资源、新网页、新终端。显式 split(resourceID:) 保持可测试直接入口。不得自动选另一个资源或暗建空网页。菜单提供左右显示，已挂载资源只转焦点；收起不结束进程。空侧按钮先显式 focusPane(pane.id)，再创建，保证目标侧。
- ⌘K 分“资源/操作”，默认本空间优先、可查全部空间。纯配置搜索不创建 runtime；同名资源带空间名、类型、目的地摘要。选择未载入空间结果后按需打开且定位描述，不启动 Shell/SSH。异步结果需要 query/selection 代次守卫；源目标失效给出错误。
- 资源菜单“复制入口到其他空间”：只把目的地及自定义名称复制为新 resource ID；源会话/快照不动，目标终端不启动。loaded target可更新自己Store的descriptor；unloaded target走统一纯配置保存服务，不能为搜索/复制而启动会话。保留各目标的其它资源、布局和revision。
- 空工具栏显示“空空间”，不暗示已经有New Tab。分组/Task Group全部改为“工作空间”，不增加层级；主要快捷键保持。自有help、accessibility、错误和标签简中，API/CLI/SSH等技术专名保留。
- 原生地址 delegate 的 Enter/Escape 先尊重 marked text；命令面板同样处理。保存空间/SSH/目录表单捕获发起 workspace/resource/pane；关闭目标后不重定向另一个当前空间。
- 900×560提供可达的内容/问答切换，保留draft/layout；可在toolbar使用紧凑切换而不增加常驻内容标题栏。1440/1920可并存侧栏、内容与问答。StartPage弱化大标题/背景hero，维持轻量真实入口，无固定示例卡片。
- 收起问答/视图、结束终端会话、关闭资源、关闭空间分别用词明确；问答只保留到关闭/退出的提示不被narrow layout挤掉。

测试覆盖显式split、不重复mount、empty右侧新建、搜索零工厂、跨空间同名结果、复制新ID零终端工厂与源实例不变、captured target失效，以及本地化引发的预期文案变化。Xcode/真实GUI由主线程统一；不要通过删除反例或改成纯最终截图宣称通过。

## 原方案逐项复核补充

- 顶部工作空间切换器替换旧资源胶囊；移除与侧栏重复的资源菜单胶囊，资源快速切换由侧栏和⌘K承担。保持地址场景提示，空时明确“空空间”。
- 左侧当前空间显示常用入口及资源；单独折叠按钮只控制展开，名称按钮才切换。资源行标“左/右”，运行数字只统计真实liveTerminalCount / isRequesting，不把待启动描述计为运行。
- 工具栏问答入口显示真实请求状态，隐藏问答仍能看到/返回正在请求的问题。
- 问答输入框附近常显已选来源标签及待读取、采集时间、截断、读取失败；不凭猜测标过期。P3 AgentViews基础版目前只有资源/预览按钮，需补这一项。由UI coder在P2 UI后取得AgentViews写权（core不写此文件）。
