# M2 性能调查检查点（2026-09-16）

本轮完成了测量链路修正、无覆盖率插桩的 36 轮输出基线、独立调用栈调查，以及一个未采用的隔离实验构建和 Metal smoke 检查。**全计划尚未完成**：现场 Mac 锁屏、自动解锁失败，后续 GUI 配对被阻塞。已请求用户手动解锁，未绕过锁屏。生产源码和默认旧后端不变；无提交、推送、M3、合并或部署。M2 整体及性能验收均未判定。

## 现场与方法

原人工 GUI PID 21524 与五个冻结构建哈希核对见 `frozen-hash-recheck.json`；构建来源和依赖见 `build-provenance.json`、`dependency-hashes.json`。原 GUI、旧冻结 Release、字体规范化副本、新无覆盖率 Release 和字体缓存实验是不同对象，不能混用。HEAD `ced7edc` 只是检查点，不替代实际构建来源。

审查发现旧冻结 legacy Release 含 LLVM coverage instrumentation，VT 不含。因此重新以相同 Release、arm64、Sandbox NO、`ENABLE_CODE_COVERAGE=NO`、`CLANG_COVERAGE_MAPPING=NO` 构建两者，两端 LLVM profile symbols 均为 0。来源、执行绑定和二进制见 `clean-build-final-audit.json`，规范化副本及 hash 见 `clean-copy-manifest.json`。原文件均保留。

每次新 App、新会话，唯一 run ID；真实 child→App 祖先链、路径、启动身份与 hash 校验；两轮预热，每次 reset，正式前再 reset、静置。输入是固定 UTF-8/CRLF 文件序列、10,000 行；ASCII 350,000 字节，mixed 510,000 字节，各种类实际字节数与 SHA 在逐轮记录。跨进程统一 `CLOCK_MONOTONIC_RAW`。新旧顺序按配对交替，三个场景各六对，没有按结果剔除样本。

窗口 1400×859 points、深色、2×、134×45 raw TTY 网格；规范化字体请求系统等宽 13pt，格距 17×35 pixels。实际 fallback、连字、全部历史和中间绘制工作量尚未证明一致，所以只报告**整体后端比较**。全部最终 AX/PNG 在采样窗外且 child 存活时采集；主线程检查 mixed 第六对末屏 009956–009999 与空光标行一致、中文/组合重音/rocket 可见，不能外推为全部历史逐字核验。

| 指标 | 定义、边界与限制 |
|---|---|
| App CPU 秒 / 单核百分比 | libproc user+system 累计差，Mach ticks 按 timebase 125/3 换算；实际约 5 秒采样包络，启动/预热/AX 不在窗内；百分比=CPU秒/实际单调时间×100。校验 3.01246 秒与 ps 3.01 秒相符。不是输出完成时间。 |
| 工具开销 | 对 sleep 目标的一次空载 pilot：采集器及回收子进程整个生命周期 CPU 0.129289 秒，wall 5.1562 秒。不是 App 开销估算，不从 App CPU 中扣除；尚无多轮误差界。 |
| 完成与吞吐 | 记录生成器 write_end 与 DSR 回复；逐轮预期光标位置匹配且事件落在包络内。write+reply 是协议往返完成，不是呈现；bytes/该区间只能称该负载的往返有效速率。未把仅生成器写完称为终端完成。 |
| RSS | 每约 50ms 离散读取，表内为最后样本的跨轮中位数；max 仅“采样最大值”，不是可靠峰值。稳定持有量、allocation profiling 尚未完成。 |
| 主线程与栈 | 独立 5 秒 sample，目标路径/PID 与符号校验；包含等待栈，计数不是精确 CPU 时间，也不能累加嵌套区间。 |
| 子进程、GPU、帧时间、输入到显示 | 未形成可靠数据。不能从 App CPU 推子进程消耗；无可靠呈现关联，不报告 GPU 利用率、帧时间或输入显示延迟。 |

背景 `ps` 平滑 CPU、RSS、memory_pressure 与 pmset 在窗外记录；用户既有 Apps 未关闭。`no_recorded_warning` 不等于测得温度；RSS 相加重复计算共享页。背景活动不低，本次未将其伪装成空载机器。

## 分场景结果

CPU 是 App 约 5 秒包络；DSR 单位 ms；RSS 单位 MiB。

| 场景 | 每后端有效重复 | VT / 旧 CPU 中位数秒 | VT / 旧 write+DSR 中位数 ms | VT / 旧末样本 RSS 中位数 |
|---|---:|---:|---:|---:|
| ASCII 10,000 行 | 6 / 6 | 0.02707 / 0.02183 | 3.405 / 6.052 | 154.91 / 132.63 |
| 中文 10,000 行 | 6 / 6 | 0.02566 / 0.01867 | 2.630 / 4.943 | 155.30 / 135.82 |
| mixed Unicode 10,000 行 | 6 / 6 | 0.02898 / 0.02252 | 4.077 / 8.032 | 156.79 / 136.94 |
| 可见空闲 20 秒 | 1 VT，0 旧 | 不汇总、不构成配对基线 | 不适用 | 待六对 |
| 隐藏空闲 20 秒 | 0 / 0 | 仅隐藏/恢复操作 pilot 已验证 | 不适用 | 待测 |
| 10,000 行历史滚动 | 0 / 0 | 实际路径匹配未完成 | 不适用 | 待测 |
| 连续 resize | 0 / 0 | 实际 surface/grid 序列未完成 | 不适用 | 待测 |
| 并发输入输出 20 秒 | 0 / 0 | 工具协议仍有缺口，未作为有效数据使用 | 未验证 | 待测 |

全部 36 个重复值、范围、配对差值、字节 hash、身份及背景记录见 [完整输出表](CLEAN-OUTPUT-RESULTS.md)、`clean-output-results.json` 和 `clean-output-matrix-01/`。ASCII 六对 VT CPU 均更高；中文和 mixed 各五对更高、一对更低。CPU 中位数比依次为 1.240、1.374、1.286；配对差中位数依次为 5.395、6.181、6.492ms。VT 查询回执更早，不能据此声称画面更早呈现。

原三轮 0.15/0.07 秒使用彩色 ANSI、不同 reset/历史协议且旧构建有 coverage，**不能直接归因到 Unicode，也不能与本轮纯文本数值相减当优化收益**。本轮支持 VT 存在小幅整体 CPU 增量，但尚未证明 Unicode 特有放大、fallback 差异或实际绘制量的因果贡献。同字节、同可见 cell、冷暖/新增字形诊断仍待完成。

## 热点：事实、推断、假设

**已测事实**：无覆盖率 VT 的独立放大 mixed 负载（500×10,000 行，255MB）全部 500 次 DSR 匹配。外层 profiler 窗约 5.9 秒，负载约 4.12 秒，实际 sample 配置 5 秒。目标主线程栈出现 `render` 原源码 358 行字体获取分支 1748 个 inclusive samples、249 行分支 503 个，后继为 `__NSGetSystemFontVariants`、`NSFont fontWithDescriptor`、字体 descriptor/hash 查找。数字只是对应分支样本，不是可加 CPU 秒。参见 `vt-output-sample-v4-sanitized.json`、`profile-v4-workload-review.json`。

**有证据支持的推断**：重复请求等宽字体是此放大负载的主要可优化路径之一。代码在两次 cell 遍历中重复调用 `font(for:)`，函数只依赖 bold/italic，字体大小固定 13pt。这足以支持一次帧内复用实验；尚不足以证明其解释常规 10,000 行场景的新旧差值或 Unicode 特有成本。

**仍属假设**：全量 snapshot、重复字符串 key、atlas 重建/上传、隐藏 snapshot、锁竞争、内存缓存增长可能有成本。现有静态路径与少量栈不构成各自的热点证明；不据此改 renderer。PTY 读取和 VT UTF-8/print 栈确实出现，但尚无可比分阶段时间/吞吐归因。分配/可靠峰值/稳定持有量未建立。

Time Profiler xctrace 试采文件存在，但导出只有 8 个目标行且没有可归因 stack，判不可用。sample v1/v2 因解析树前缀丢行不可用，v3 因统计口径校验误判保留，v4 完整解析 3465 行；其 rejected=1 实为尾部分隔空行，最终 parser 修正由 10 项主线程绑定测试通过。未更改 v4 历史数据。所有原始采集在私有临时目录，以最小环境运行；先脱敏再读取/归档，未读取环境原始元数据。未将零目标 GPU 事件解释为零消耗。

## 优化排序与实验

| 优先级 | 候选与位置 | 证据与机制 | 场景、风险、成本 | 决策与最小验证 |
|---|---|---|---|---|
| 1 | render 两循环帧内四种字体组合复用，TerminalMetalRenderer.swift 原249/358/457行 | 符号栈+函数依赖直接支持；把每 cell NSFont 获取变为每帧每 trait 一次 | 输出/scroll/resize redraw；每帧≤4对象，无跨帧增长。需验证 bold/italic 正确性和小字典成本；改动小 | 已制作隔离单因素 patch，尚未采用。需同配置六对无 profiler 改善+同负载字体栈下降+四 traits/GUI 回归；撤回仅弃用隔离构建 |
| 2 | glyph key 中重复 fontName/pointSize/scale 字符串拼接 | 静态重复明确，少量字符串栈；独立贡献未量化 | 绘制多 cell；key 相等性/缓存命中风险，低到中成本 | 暂缓，不与字体 cache 混改；先隔离计数/栈证明 |
| 3 | 隐藏状态 snapshot/全量快照及脏区域 | 静态路径存在，隐藏空闲/持续输出基线未完成 | 隐藏输出/大量状态更新；恢复正确性、时序和维护风险较高 | 暂缓；先可见/隐藏同负载六对及 snapshot 计数 |
| 4 | atlas 增量更新、纹理上传或 shaping 缓存改造 | 当前没有可靠 atlas/fallback/GPU 热点量化 | 新字形负载可能受益；资源在途、缓存增长和字体正确性风险高 | 不实施；先新增/重复字形诊断及可靠上传事件 |

检索顺序为仓库实现/固定依赖，再核对 [Apple NSFont monospacedSystemFont](https://developer.apple.com/documentation/appkit/nsfont/monospacedsystemfont(ofsize:weight:))、[NSFont](https://developer.apple.com/documentation/appkit/nsfont)。这些文档支持 API 语义，不提供本项目性能收益证据。呈现指标依赖 [MTLDrawable.presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)，本轮没有建立可靠呈现关联。

隔离 worktree `/private/tmp/web-studio-m2-font-cache-experiment-20260916`，仅一个 renderer 源码改变；补丁/源和二进制 hash 见 `experiments/manifest.json` 与 `font-frame-cache.patch`。主线程独立 `record_execution --repo --state` 的 Release build、Metal smoke 均 passed，绑定同一实验 revision。

smoke 覆盖中文、组合字符、ZWJ Emoji、下划线/颜色、dark/light、1×/2×、两组 1200 个不同 CJK 字形、command 完成与空光标相位像素。它仅检查部分像素性质，不是逐字/基线像素相等证明；没有四 traits、history、resize、真实隐藏恢复或专门资源释放压力验证。**未做实验前后性能配对、没有可报告优化收益，不合入生产路径。**

## 预算与下一依赖

[新预算建议](budget-proposal.json) 保持 `proposed`，旧建议原样保留。建议仅对本协议输出：CPU 中位数比≤1.5 且配对 CPU 差中位数≤10ms，末样本 RSS 比≤1.25，write+DSR 中位数比≤1.25。它们是围绕现有基线的工程裕量提议，非置信区间、非用户已确认需求；空闲/交互/峰值/GPU 等预算暂缓。不得据此判通过或失败。

下一依赖依次为：用户解锁 Mac；先完成 idle、实际距离 scroll、实际尺寸 resize 和经修正协议的并发六对；补诊断负载与内存/子进程分层；四字体 trait 与 GUI 正确性；字体实验同条件 A/B 和 stack 复验；用户确认预算后再作性能验收判断。已确认的 IME、VoiceOver 普通朗读不重复询问。

并发工具目前缺 expected 序列、丢失/重复/乱序/半行判定和完整 echo 写入证据，不能用当前循环结束作为有效并发基线。下一次工具修改仍须 coder 独占并由主线程绑定复验。

## 证据与待提交边界

- 基线：`clean-*-build*.json`、`clean-build-final-audit.json`、`clean-copy-manifest.json`、`clean-output-matrix-execution.json`、`clean-output-matrix-01/`。
- 计数与工具：`counter-pilot-corrected.json`、`observer-overhead*.json`、`investigate-tests-v2.json`、`matrix-tests-v5.json`、`profile-tests-v6.json`。profile v5 因生成 pycache revision_changed 保留，v6 使用 -B 通过。
- 无效/限制：旧 mixed 诊断保留于 `mixed-matrix-02/`，不能替代 clean 基线；失败 output/idle batches 与全部 trace parser 尝试保留。idle-03 只完成一个 VT 样本，锁屏中断不凑成配对。
- 本轮新增待提交：六个 `scripts/terminal-m2-*.py` 工具/测试、此证据目录与任务共享文档。此前 `terminal-performance-probe*`、人工回执及现有 dirty edits 继续保留。根目录 `default.profraw` 为旧 coverage App 生成的非交付物，保留但不建议提交；没有自动删除。
- 实验源码只在临时 worktree，不在主仓库生产 diff；主仓库仅存实验补丁和证据。未写入 Vendor 或默认后端配置。
- 历史 Veriflow EVD-014 外部 fixture 结构校验问题继续保留，不篡改历史绕过 gate；本轮 skill 问题只记录。

## 本轮 record gate 限制

`final-record-gate.json` 失败：历史 stale 条目缺 stale_reason、旧证据/变更审查 revision 与新增工具后的全局 token 不匹配；新增报告条目初次漏填 revision。当前验证器另提示旧 schema 1.2 尚无 1.3 Spec/history binding。既有执行结果与输入未被重写；本轮只为历史证据补充真实 stale 原因并为新报告绑定当前 revision，旧变更审查不伪装为当前审查。后续 gate 原始输出保留，不据此重跑未变化的既有检查，不修改 skill。

复核 `final-record-gate-v2.json`：仅余历史 CHG-001/CHG-002 的 CHANGE_STALE 两项错误；另有 legacy schema 与历史 commit/push 授权警告。历史 EVD-014 外部 fixture 错误在旧版本记录保留，本次验证器未重报该项，不能描述为本次仍报同一错误。
