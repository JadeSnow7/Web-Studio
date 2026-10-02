# P2b：描述恢复、显式启动与实例身份

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

单写者：coder_p0_repair 转为此原生子任务，独占 Web Studio/ResourceModel.swift、新 Web StudioTests/WorkspaceResourceLifecycleTests.swift；AgentController.swift只允许给裁剪ResourceSnapshot副本传递新增instanceID参数，其他逻辑不动。另一coder独占新的配置/Repository文件，主线程负责集成设计、状态与审查。不要改原型或既有terminal/VT/performance文件。当前P1模型94测试通过，完整产品仍未验收。

先读SPEC、P2-coder、ResourceStore/TerminalSession/AgentController的实际代码。保留其他人的修改，不回退，不提交。终端后端不改，所有新编排在ResourceStore。

1. 独立的描述注册/恢复端口，接受ResourceRecord或纯参数。不得创建TerminalSession/WKWebView/Provider，不执行进程。恢复lifecycle归idle/待启动，不信任输入运行态。顺序、ID、自定义名保留。搜索/来源选择只读描述。
2. 现有显式新建入口仍可启动（保持调用方同步获得刚建session的兼容行为）；新manual startResource(resourceID:) async与endResourceSession(resourceID:) async可测试，具体签名先报主线程。启动本地目录先验证存在且为目录，不静默回退Home；恢复失效目录仍保留描述和可恢复错误。Shell/SSH创建计数可读取（不冒充真实进程启动）。
3. 一个资源并发启动只创建一次；结束/关闭中拒绝新启动，重复结束等同一任务。结束保留描述行，关闭资源仍移除行；shutdown包含正在结束与原有closingTasks。不能把已shutdown ResourceStore复用。结束后再明确启动新运行实例ID。
4. 资源instanceID由Store管理，不改TerminalSession后端；配置读取无实例ID，实际创建runtime才产生。ResourceSnapshot追加可选instanceID（默认nil保持原API），所有read路径及AgentController裁剪副本保留采集身份。旧快照在重启后保持旧身份。资源重启迟到回调不能污染新实例，绑定时校验捕获的session/instance。
5. 已恢复、未启动终端被read要明确未启动/不可读取，不能隐式启动。Web仍按runtime(for:)可见访问懒创建，不在恢复时创建。

必要测试：restore Web/Shell/SSH后工厂创建计数0与activeRuntimeCount0；读取未启动也0；手动启动连续/并发一次；end保留记录、重复end等待、restart新instance；关闭/全store shutdown等待已有end；失效目录保留描述且没有factory调用；旧快照instance不变。测试launchTerminalProcesses:false不能证明真实Shell/SSH成功；真实后续P4验证。使用真实临时目录fixture，不依赖不存在的/tmp/tools等路径当有效目录。

只改上述文件，若有现有测试明确依赖无效目录仍启动，请列出来给主线程，不随意删测试。新增测试先parse，主线程统一recorded Xcode；期间按完成边界回报并暂停。禁止把整文件格式化作为小改动副作用。
