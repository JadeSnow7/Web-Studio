# W0 基线入口与试采：部分完成

已交付场景目录与进程采样入口；全应用基线未完成。

新增 scripts/app-performance-baseline.py 复用既有 libproc/Mach timebase 计数器，只附着已有 PID，核验路径/二进制 hash、进程 UUID/启动时间和每个样本。输出记录实际 CPU 区间、离散 RSS、原始样本，未测值为 null；调用者提供的 GUI 场景字段保持 verified=false。七项边界测试由主线程经 Veriflow 执行通过。

默认产品和 VT 控制组各一次真实 20 秒采样试跑通过；均为新进程驻留 5 秒后采集，80 个样本，身份与二进制 hash 稳定。默认样本 CPU 为 0.026400 秒；VT 样本为 0.607205 秒。没有可靠 GUI readiness、资源状态和重复对齐，因此这两个值只证明采样入口工作，不能据此排序后端性能或确认空闲预算。原始数据、起止边界、命令和进程清理见 evidence/default-pilot*、evidence/vt-control-pilot*。

初次默认 Release 构建仍带 Swift coverage；编译日志复查发现后排除。重新使用 ENABLE_CODE_COVERAGE=NO、CLANG_COVERAGE_MAPPING=NO 构建成功，最终默认/VT 控制/候选均核验 arm64、无 LLVM profile 符号。旧插桩构建、错误参数和 revision_changed 记录保留；初版 app-builds.json 的 default.coverage 字段以 build-metadata-correction.json 纠正，实际可用二进制以 final-binary-audit.json 为准。

未完成：成对区间标记、启动/首交互、资源挂载、Web 发布/截图与 SwiftUI body 计数、1/10/30 页面、隐藏持续输出、多终端、30 次关闭循环、60 分钟混合、Agent 预览和长对话、子进程归属、可靠 GPU/present/峰值。详细入口与结果状态见 SCENARIOS.json；预算仍 proposed。W2-W5 未据未测假设改动产品。

后续优先恢复可靠且有界的 GUI 观察，再补默认产品关键场景和区间计数；已授权工作无需再次批准，完整结果仍依赖这些证据。
