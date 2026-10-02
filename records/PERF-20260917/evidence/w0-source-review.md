# W0 采样入口主线程审查

审查者：main-thread；实现者：coder w0_baseline。仅两个新 Python 文件，生产 Swift 未改。主线程读取实际代码、测试及 record_execution 原始输出。

初稿使用 ps TIME、排除最后端点、弱 PID 身份检查，不能用于小量 CPU 比较，已退回修正。第二次审查补齐缺失 UUID/启动时间、逐样本身份、结束时可执行文件 hash，以及非法计数器；最终反例补齐缺少样本身份、bool 数值与 CPU 求和溢出。最终方案复用现有 terminal-m2-investigate.py 的 libproc/Mach timebase 实现，保持工具来源与计数语义一致。

最终七个测试方法覆盖有效两端点、失败采样、CPU 回退、独立的 PID 复用、逐样本身份缺失/变化、NaN/负数/bool/溢出、错误路径、结束身份/二进制变化、覆盖拒绝与时长上限。主线程执行记录：w0-tests-final.execution.json；不是只引用 coder 的 tests passed。

能力边界：仅附着已有 PID，最长 20 秒；读进程 CPU/RSS，保留原始样本。backend/scenario/resource_count/visibility 是调用者陈述，工具标 verified=false，不能证明 GUI 处于该场景。无启动首帧、首交互、SwiftUI body、截图计数、GPU 或 input-to-present 标记；不声称完成 W0。

不会启动/关闭 App，不保存或发送用户网页/对话内容，不读取凭据；输出拒绝覆盖。CLI 主线程将继续做真实 PID 的集成试采，其结果独立于单元测试。
