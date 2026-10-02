# W0 coder 交接

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

状态：实现完成，待主线程审查与 Veriflow 记录。

范围：新增 `scripts/app-performance-baseline.py`、`scripts/test-app-performance-baseline.py`、`records/PERF-20260917/SCENARIOS.json`。工具只附着既有 PID，不启动、终止或驱动应用；输出拒绝覆盖已有路径。

契约要点：

- 复用 `scripts/terminal-m2-investigate.py` 的 `libproc.proc_pid_rusage` 与 Mach timebase；累计 user+system CPU 为 `cumulative_cpu_seconds`，RSS 字段命名为 `rss_bytes_discrete`，并明确不是峰值。
- 二进制真实路径与 SHA-256、进程 UUID 与启动时间在采样开始/结束校验；每个带身份字段的样本也逐个校验。采样失败逐条保留，失败样本、计数器回退、PID 复用、二进制变化或不足两个有效端点均整体失败。
- backend/scenario/resource_count/visibility 是调用者观察值，输出 `verified: false`。
- 采样时长与间隔均有上限；PID、身份、计数器异常和超时会失败关闭。
- `SCENARIOS.json` 覆盖 W0-W5，所有结果初始为 `status: not_run`、`results: null`，并写出测量边界与缺口。

验证命令：

```text
python3 scripts/test-app-performance-baseline.py
```

结果：7 tests passed，另通过 `py_compile` 与 `json.tool`。尚未执行真实应用采样，也未构建或修改 Swift。主线程应使用 `scripts/record_execution.py` 记录测试和后续真实采样；真实采样需由主线程提供已运行 PID、期望二进制路径和固定场景观察字段。
