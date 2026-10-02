# P2a：纯配置与文件仓库

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

P1工程checkpoint：94 tests / 5 suites passed，见p1-engineering-review.json；原生验收仍待P4。先读SPEC、ARCHITECTURE、ACCEPTANCE及P2-coder通用合同。

单写者：coder_workspace_core 独占新 WorkspaceConfiguration.swift、WorkspaceRepository.swift、Web StudioTests/WorkspacePersistenceTests.swift。其余源码只读，不格式化或重写ContentView及其他现有文件。另一coder负责ResourceStore的描述/启动分离，主线程负责接口审查和记录。保留所有已有修改，不提交推送。

先给出公共类型/函数签名，再实现。具体Swift类型是权威，以下描述是结果要求。

- 配置是纯值Codable，不引用Session/WebKit/AppKit/Provider。字段包括schemaVersion、workspaceID、revision、name、可选目录、archived、资源目的地/自定义名称/顺序、固定入口、pane IDs/resource refs/ratio/focus、面板偏好、可选lastActivatedAt元信息。类型不得接受AI正文/快照/进程输出/密钥。不要直接encode ResourceRecord运行态。
- Repository以actor/串行后台IO执行，注入rootURL及故障点；不在MainActor做文件写入。协议提供目录、读取、带expectedRevision的保存。配置读取为值，不创建运行时。默认Application Support根路径留给应用装配；测试只用独立临时目录。
- 每空间一个UUID命名的主JSON与上一有效备份。持有文件锁后比较expectedRevision，写临时文件、完整解码回验、备份上一有效版本、原子替换主文件。多实例相同旧revision不能静默覆盖；使用advisory lock拒绝并发冲突。只清理本次创建的临时文件，不删除原件。
- 文件不存在、损坏、未知新schema、ID冲突、布局修复、权限写失败、revision冲突分开返回可呈现诊断。未知schema不能被save覆盖。损坏主文件保留原字节，尝试有效备份；恢复后下一次save也不能把损坏主文件当有效backup。无备份隔离该文件。
- 读取坏资源项/重复ID要报告，保留其他有效项；无效pane引用/重复挂载/focus/ratio需修复并报告，不让坏项使整个有效空间丢失。持久化解码按schema版本先判断，不能因为资源新字段把未来版本误归损坏。
- 目录可从文件重建。lastActivatedAt用于选择最近活动空间即可，不能依赖必须和空间文件同时写成功的强索引事务。
- 保存返回实际新revision及规范化配置。失败不能修改有效主文件，UI保存代次/合并/关闭选择属于后续集成，本子任务不伪造UI状态。

验证至少覆盖：全部配置字段往返；编码没有AI/输出/密钥字段；写拒绝/替换前故障原件hash不变；截断主文件+有效备份及无效备份；未知新schema原件不被save覆盖；两个Repository同root旧revision冲突；重复资源ID/失效引用/不支持目的地保留有效项；目录可重建。原件hash用实际bytes前后比较，不能只assert抛错。测试明确注入点的范围，不宣称断电零丢失。

不修改运行态/终端后端，不调整Provider协议。保持Swift language5与当前MainActor设置，纯DTO避免误带UI actor隔离。公共API发送主线程后再定下游适配。可先swiftc parse；完整测试由主线程等两个基础子任务稳定后统一record_execution，避免测试同时源码变化。每个阶段回传实际路径、设计与未满足项，完成只报待审查。
