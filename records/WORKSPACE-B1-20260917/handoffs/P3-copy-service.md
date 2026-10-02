# P3：纯配置复制端口（2B 完成后派发）

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

由 core coder 独占 Registry，必要 Session 的纯描述转换 helper，新 WorkspaceCopyTests。与 UI navigation coder 文件互不重叠。不能创建活动 runtime，也不改终端后端。Swift 签名确定后立即发 UI coder。

- 输入捕获源 workspace/resource ID 与目标 workspace ID，只复制原目的地及 customTitle，新 resourceID；不复制输出、snapshot、运行实例、读取历史。
- 已载入目标向自己的 ResourceStore 添加 idle descriptor，保持其它资源、layout、焦点；命名空间走既有自动保存。目标不自动打开资源。
- 未载入目标纯配置 load + revision CAS，追加新资源且保留所有其它字段；不得实例化 Session 或调用 runtime 工厂。
- 异步读取后复核目标没有关闭、归档或新 owner 状态；若目标在等待期间变为 loaded，应更新最新 loaded Session，不能以旧磁盘配置覆盖其修改。
- 源目标不存在、归档、关闭中或 CAS conflict 给出明确失败状态；不错误回报复制成功。保存失败保留原目标文件，源会话始终不变。
- `configurationsForSearch` 提供全部非归档纯描述，包括loaded临时空间；查询本身零factory/零正文读取。

测试：loaded目标新ID且source实例/问答不变；unloaded目标零Session/零factory，配置回读含新资源、原layout/order/name保持；复制终端仍idle且点击启动前factory0；无效或已归档目标拒绝；CAS冲突不覆盖。使用临时目录和可控loader，不扫描用户目录。
