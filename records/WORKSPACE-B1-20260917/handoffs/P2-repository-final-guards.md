# P2 配置恢复的最后边界（待派发）

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

仅 WorkspaceRepository.swift、WorkspaceConfiguration.swift、WorkspacePersistenceTests.swift。与 Registry/窗口集成保持独立，不修改它们。目标仍为 SPEC 的坏项保留有效配置与未知版本保护，无额外产品功能。

主线程现读代码发现：逐项解码能跳过未知 kind，但 .web(url:) 只要求字符串，SSH 端口和 host 也未做语义检查；pins 未去重。以下需要收敛：

- 对 web 目的地接受有效 http/https URL（非空host），非法 URL/不支持 scheme 作为 invalidResource 或 invalidPinnedDestination 跳过，并修复引用；资源目录是否存在延迟到明确启动，本层不把已移动目录描述删除。
- SSH host 非空且合法基本主机形式、user/host 不含控制字符，port 1…65535；不要因为离线/DNS不可达而删描述。
- pins 重复 ID 拒绝后项并给诊断，保留其它合法项。资源/pane重复处理保持原语义。
- 不更改未知未来 schema 的只读保护，也不把未知数据覆盖为默认空配置。保留坏主文件及有效备份恢复语义。
- 增加同目录两个Repository旧revision冲突已有用例之外的可控 advisory lock 占用测试；持有真实 .lock 的另一个打开fd，save应busy且原文件hash不变，释放后正常写入。不宣称受控锁测试证明断电持久性。

新增测试要混合合法与非法resource/pin、断言合法项可用/diagnostic/原件不被load改写。仅 parse，主线程统一Xcode。
