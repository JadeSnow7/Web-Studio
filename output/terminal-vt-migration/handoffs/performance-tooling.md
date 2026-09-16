# 固定负载与进程采样合同

所有者 coder；你不是唯一执行者，不撤销其他修改。仅可写 `scripts/terminal-benchmark.py`、`scripts/test-terminal-benchmark.py`、`output/terminal-vt-migration/evidence/performance-tooling/`。主线程维护 STATUS、task-state、work-log。禁止改 App 源码、skill 或生产默认。

目标：为同一机器的新旧真实 App 提供可复跑的终端负载和原始进程采样，不把工具自测当性能验收。

使用 Python 标准库，兼容本机 `/usr/bin/python3`。CLI 提供：

- `output --kind ascii|unicode --lines N`：确定性的 ANSI/纯文本或中文、组合字符、Emoji、真彩色负载；固定种子或完全确定性；首尾明确 BEGIN/DONE 标记，记录实际字节/行数；默认 10000 行，可调；不读用户数据。
- `sample --pid PID --duration SECONDS --interval SECONDS --output PATH`：目标仅指定 PID，保存 argv、时间、系统版本、每次原始 ps 输出与退出码、样本时间戳、累计 CPU 时间、RSS。可用 ps 的累计 CPU 时间差估算区间 CPU%，必须注明解析精度与采样误差；不要将 ps 的历史平均 %CPU 当区间 CPU。进程消失记失败/部分样本，不能静默通过。
- 汇总只提供已有数据支持的 duration、CPU 时间增量/区间占比、RSS 范围；帧时间、输入延迟、GPU 均明确 unavailable，后续由主线程实际 trace 或人工量测补充。不得制造估值。

测试应覆盖 CPU 时间格式、PID 消失、JSON 原始字段以及确定性负载；对临时 sleep/CPU 子进程做一轮真实采样自测，清理自己创建的进程。每次输出路径不覆盖已有数据；不自动操作桌面应用。

证据写到本任务 evidence/performance-tooling/；完成立即报告文件、测试、命令与输出、方法局限、文档同步、skill 候选问题。不提交推送。主线程将独立运行工具并在真实 App 中采样。
