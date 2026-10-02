> 2026-09-26 当前导航：M2 仍未完整验收，M3 未执行，默认目标仍为 GhosttyKit。后续 W0/W1 离屏实验和本机测试包已记录在 [性能路线](../../records/PERF-20260917/task-summary.md)，候选未合入生产。本文以下为各自版本的历史检查点，PID、锁屏和等待用户状态不代表当前现场；统一状态见 [STATUS](../../STATUS.md)。

## 2026-09-17 本轮性能调查交付

已完成八个基础场景各六组配对（96个正式App窗口）、四类VT离屏Unicode负载各六轮、独立调用栈和存活分配快照。一个帧内字体复用实验在隔离构建验证，未采用到生产。

[完整报告及证据索引](evidence/performance-investigation-20260916/RESULTS-20260917.md) · [Unicode诊断](evidence/performance-investigation-20260916/UNICODE-DIAGNOSTIC-RESULTS.md) · [预算建议v5](evidence/performance-investigation-20260916/budget-proposal-v5.json)。本轮调查结果已交付，GPU/实际帧时间/输入显示延迟、分配生命周期及精确阻塞时长仍未可靠测得。预算proposed、MET-004 undetermined、M2整体仍in_progress；不代表发布就绪。

原GUI存活，七个二进制hash匹配，主仓库renderer不变，自有App和限时辅助进程已清理；未提交推送/M3/移除依赖/合并部署。以下为保留的历史进度。

## 2026-09-17 并发六组完成，归因继续

要求的八个基础场景（可见/隐藏空闲、ASCII、中文、mixed、滚动、resize、并发）现均有六组新旧配对。并发12个正式窗口及36个含预热负载的实际hash、序列、身份和完成边界均核验通过；App CPU中位VT5.538143秒/旧1.657350秒（约23秒包络，含逐次AX）。独立5秒调用栈再次支持VT重复字体获取为主要候选成本，但不解释全部差值。

[并发结果与限制](evidence/performance-investigation-20260916/CONCURRENT-RESULTS-20260917.md) · [全部重复值](evidence/performance-investigation-20260916/concurrent-results-20260917.json) · [预算v4](evidence/performance-investigation-20260916/budget-proposal-v4.json)。正在补充有界内存快照与VT离屏Unicode诊断；预算保持proposed，整体M2和发布条件未满足。以下为保留的历史进度。

## 2026-09-17 解锁后续跑进度

历史容量对齐后的滚动与 resize 已各完成六组配对。主线程独立核对24个测量窗，滚动 CPU 中位数 VT/旧为0.264733/0.253190秒，resize为0.828831/0.649825秒；均为约20秒App包络，含AX/截图/查询，不代表帧时间。按事先记录的续跑选择保留 matrix-02 第一组并完成第2–6组，原整体中断失败不改写。

[完整交互结果](evidence/performance-investigation-20260916/HISTORY-INTERACTION-RESULTS-20260917.md) · [逐轮证据](evidence/performance-investigation-20260916/history-interaction-results-20260917.json) · [预算建议 v3](evidence/performance-investigation-20260916/budget-proposal-v3.json)。并发试采第一轮预热20输入/200输出及DSR成功，第二轮因输入方就绪竞态失败，工具修正中，正式并发仍0组。预算proposed、M2未完整验收；生产默认旧后端、无提交推送/M3/合并部署。以下检查点为历史记录。

## 2026-09-17 最新性能检查点

已完成无 coverage 输出 36 轮、可见/隐藏空闲 24 轮，以及隔离帧内字体复用 12 轮对照和九幅离屏像素一致检查；两个 5 秒调用栈有效。默认历史保留量不一致被实测发现，已建立可回到第 0 行的独立历史对齐副本。滚动/resize 四轮试采有效，正式六对批次再次因 Mac 锁屏中断；并发真实 App 数据仍未采集。原始失败及部分样本保留，不合并凑足六对。

[完整调查检查点](evidence/performance-investigation-20260916/CHECKPOINT-20260917.md) · [全部重复和配对数据](evidence/performance-investigation-20260916/checkpoint-20260917-data.json) · [修订预算建议](evidence/performance-investigation-20260916/budget-proposal-v2.json)。字体实验未合入生产；默认旧后端、无提交推送/M3/依赖移除/合并部署。预算 proposed，M2完整验收未判定。当前下一依赖是手动解锁及未完成场景/归因，不重复询问已有 IME/VoiceOver 普通朗读回执。以下保留历史内容。

## 2026-09-17 活动检查点（后续结果待归档）

用户已解锁，现场调查恢复。可见/隐藏空闲各六对已完成；帧内字体缓存隔离实验完成六对 mixed 对照和九幅离屏像素逐字节一致检查，生产源码未采用。两组独立 5 秒调用栈有效，均完成 500 个匹配回执负载；尚不代表 GPU、帧时间或输入显示延迟。

发现默认历史保留量不同，原输出与空闲数据仅支持默认策略下整体后端比较。新建独立历史容量对齐副本，真实 GUI 两端均能回到第 0 行；滚动、resize、并发输入输出正式配对仍在准备，工具审查发现的问题先修正再使用。预算仍 proposed，M2 完整验收未判定。以下保留此前检查点。

# M2 性能调查检查点

## 2026-09-16 性能调查最新检查点

已完成无 coverage 的新旧 Release 36 轮输出测量（ASCII/中文/mixed 各六对），CPU 中位数比分别为 1.240/1.374/1.286，write+DSR 回执更早；仅作整体后端比较，不等同呈现或 Unicode 根因。旧冻结 legacy 带 coverage 插桩，原三轮不再作为同配置定量比较依据，历史证据保留。

放大 mixed 负载调用栈支持重复字体获取为候选热点；一个帧内字体复用 patch 只在隔离 worktree，主线程独立版本绑定的 Release 构建和 Metal smoke 通过。未完成 A/B 性能和四 traits/GUI 回归，未采用到生产源码。

Mac 锁屏且自动解锁失败，现场后续采集受阻；空闲只有一个 VT 有效样本，隐藏空闲/匹配距离滚动/连续 resize/并发输入输出六对均未完成。原 GUI 和既有 Apps 保留，已停止自有等待 runner。下一依赖：用户解锁、修正并发测量协议、补齐场景和实验验证。预算 proposed，M2 全部验收未判定。

详情与证据：[性能调查报告](evidence/performance-investigation-20260916/REPORT.md)、[六对完整结果](evidence/performance-investigation-20260916/CLEAN-OUTPUT-RESULTS.md)、[新版候选预算](evidence/performance-investigation-20260916/budget-proposal.json)。主仓库生产默认旧后端，无提交推送/M3/依赖移除/合并部署。

本轮待提交：六个 scripts/terminal-m2-*.py 工具/测试、performance-investigation-20260916 证据及共享文档；原 dirty 修改保留。default.profraw 是旧 coverage App 的非交付物，保留但不建议提交。隔离实验源码不在主仓库生产 diff。

以下为历史摘要，当前范围以上文为准：


# M2 本轮交付状态

M2整体验收未判定。HEAD和已核查远端均为`ced7edc25bd6ab6434712ce4da0b4bd16afad499`；本轮未提交推送，生产默认旧后端，未进入M3、移除旧依赖、合并或部署。

已完成：归档扩展IME与VoiceOver普通朗读人工回执；精确900×560亮色双栏/亮暗单栏选区与光标PNG；恢复自动外观；普通⌘L/⌘K往返输入、隐藏恢复PID/历史、关闭取消保活/确认回收及无关进程保活。原GUI PID21524及二进制边界单列，新旧冻结构建文件hash保持一致。

隔离Release已实测同13pt字体、17×35px格距、45×134网格、同窗口/深色/2×。每后端输出、可见/隐藏空闲、工具滚动和布局resize均采3轮；输出/空闲有初始可比基线，交互场景有滚动距离/AX开销/内存回收限制。VT Unicode CPU中位数0.15秒，旧0.07秒；候选2倍预算尚未确认，不能判通过。见[性能实测与候选预算](evidence/performance-normalized-20260916/RESULTS.md)。

新增六个测量工具/脚本已由coder实现、主线程审查并以record_execution --repo --state独立验证，token一致。原App及既有回归输入未变，不重复构建测试。主线程真实字体/grid复测也通过。原回归保留旧token；新规范文档改变全局token后已机械标stale，不伪造重跑。

仍待：VoiceOver导航/地址栏及命令面板往返/选区朗读人工回执；预算确认及至少5轮复测；可靠GPU性能比、帧时间、输入延迟；语音输入仍未判定，网络根因未经验证。原终端持续安全读取程序已保留，不重复询问IME或普通朗读。

两个对照App及其shell已退出，原人工终端PID22208、81191保留，外观为自动。trace导出曾把继承的API密钥带入一次工具输出；归档已脱敏，含环境变量的原始trace已清理，需用户轮换该密钥。

待提交范围仅本轮`scripts/terminal-performance-probe*`六个文件及`output/terminal-vt-migration/`文档、回执、截图和性能证据；App源码、Vendor、生产配置未改。归档中的终端AX文本保留网格尾空格，不按格式化清理。

结构校验：`m2-followup-record-review-v2.json`仍failed，唯一error是历史EVD-014的仓库外fixture，即使标stale也检查其inputs。当前EVD-017以仓库内fixture+cmp实际副本重测通过。保留历史证据、不修改skill，MET-005整体一致性保持未判定；另有历史提交授权与本轮禁止提交的两条warning。详见[evidence/m2-followup-skill-additional.md](evidence/m2-followup-skill-additional.md)。
