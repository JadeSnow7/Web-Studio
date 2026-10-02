# 独立内存快照旁证

固定10,000行mixed、同历史容量副本，各有两轮预热和正式前重置。工具先验证PID/路径，以最小环境运行heap与vmmap，每项5秒、输出总上限256MiB。只归档白名单汇总；heap类名/对象内容/地址/原始metadata不归档。主线程复验7项测试后进行真实格式校准。

|后端|存活分配节点|heap汇总MiB|当前physical footprint MiB|
|---|---:|---:|---:|
|VT|160689|22.817|119.300|
|旧|167273|26.488|157.800|

heap COUNT/BYTES/AVG每行数字校验，节点数之和必须等于工具报告nodes，平均字节一致才接受；MALLOC列未确认语义，仍unavailable。Physical footprint仅取当前字段，忽略peak字段。VT初始未知格式快照保留；随后仅查看数字/固定词脱敏结构，校准后重新绑定采集。

这是每端一次存活分配快照，不是累计分配总量、可靠峰值、稳定持有量或泄漏证据。两端采样时点、运行时长及后台压力不同，不能以本表排序性能；heap与footprint不可相加。未建立对象所有者/缓存增长归因，尚需独立分配生命周期工具。

VT快照之后CUA服务断开，附加滚动场景失败；此发生在内存工具退出之后，快照有效性与额外场景分别记录。memory-scene-execution.json还记录无关新诊断工具写入导致revision_changed，不能将其当通过的整个交互批次。VT独立内存执行memory-vt-execution-v2.json与旧memory-legacy-execution-v1.json退出0；旧额外历史检查恢复0–9999并正常退出。所有内存相关场景CPU排除于正式基线。

原始安全汇总：memory-vt-snapshot-v2.json、memory-legacy-snapshot-v1.json；工具检查memory-tool-checks-v3.json。
