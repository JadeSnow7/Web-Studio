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

# 当前 M2 实测记录（2026-09-16）

## 2026-09-16 性能调查最新检查点

已完成无 coverage 的新旧 Release 36 轮输出测量（ASCII/中文/mixed 各六对），CPU 中位数比分别为 1.240/1.374/1.286，write+DSR 回执更早；仅作整体后端比较，不等同呈现或 Unicode 根因。旧冻结 legacy 带 coverage 插桩，原三轮不再作为同配置定量比较依据，历史证据保留。

放大 mixed 负载调用栈支持重复字体获取为候选热点；一个帧内字体复用 patch 只在隔离 worktree，主线程独立版本绑定的 Release 构建和 Metal smoke 通过。未完成 A/B 性能和四 traits/GUI 回归，未采用到生产源码。

Mac 锁屏且自动解锁失败，现场后续采集受阻；空闲只有一个 VT 有效样本，隐藏空闲/匹配距离滚动/连续 resize/并发输入输出六对均未完成。原 GUI 和既有 Apps 保留，已停止自有等待 runner。下一依赖：用户解锁、修正并发测量协议、补齐场景和实验验证。预算 proposed，M2 全部验收未判定。

详情与证据：[性能调查报告](evidence/performance-investigation-20260916/REPORT.md)、[六对完整结果](evidence/performance-investigation-20260916/CLEAN-OUTPUT-RESULTS.md)、[新版候选预算](evidence/performance-investigation-20260916/budget-proposal.json)。主仓库生产默认旧后端，无提交推送/M3/依赖移除/合并部署。

## 2026-09-16 新增人工回执与现场复验

扩展 IME 已由用户确认完成；VoiceOver 终端普通文本朗读已由用户确认正常，字幕文字据用户报告为 `ASCII abc XYZ 0123`。这两项不再重复询问。当前证据目录没有找到对应 VoiceOver 原始字幕截图，本轮消息未附图片；回执明确区分用户确认、用户报告的截图内容、AX 可访问文本与自动接口测试。语音输入另列未判定，疑似网络问题尚无根因证据。

当前 GUI 是旧 Debug PID 21524，哈希与此前记录一致；冻结 Debug / 新旧 Release 五个二进制文件均匹配旧记录，没有把新构建通过迁移为其 GUI 通过。HEAD 和 origin/main 现场核对均为 `ced7edc25bd6ab6434712ce4da0b4bd16afad499`，本轮不提交推送。

精确 900×560 工具栏下方内容区已补亮色双栏、亮色单栏、深色单栏选区/光标 PNG。独立 AX/CG 实测外框900×600、toolbar40、内容split group高560；横向674点终端布局加左侧226点。截图是工具传输尺寸，不当作原生2×像素采集。实际显示2×；其他实际缩放未判定。外观已恢复原“自动”，见 AX 回执。

资源隐藏/恢复后 PID22208 与历史保持；⌘L、⌘K、Escape、点击返回后收到 `VO_INPUT=[FOCUS_RETURN_0123]`，这是普通键盘/焦点实测，不替代 VoiceOver 导航。专属关闭资源 PID4959、5418、5419、5420 在取消后存活，确认后只读检查均不存在；无关终端 PID22208、81191 存活。此为关闭后轮询结果，不声称测量即时回收延迟。

原始证据：`evidence/m2-followup-*`；逐项结果见 [恢复实测结果](evidence/m2-resume-results.md)。剩余 VoiceOver 导航、返回输入与选区朗读已准备持续读取程序等待用户回执，输入不会作为命令执行。隔离性能字体/格距已实测对齐，新旧Release现场同为45×134网格、深色、2×；逐场景数据、trace限制与候选预算统一见 `evidence/performance-normalized-20260916/RESULTS.md`。预算需用户确认，整体 M2 未判定。

以下保留先前检查点的原始范围；与本节冲突的“扩展IME待回执”等描述已被本节结果取代。


源码基线 `2631e149787c6cfd8d9b0903c89995e8cde96083`。本轮未修改 App 源码或生产默认。构建、host、PTY/backend/ASan 的命令、时间和结果见 `evidence/m2-current-*.json`。

## 真实窗口已验证

- 微信输入法：用户反馈“使用微信输入法，输入一切正常”，本轮默认窗口中文输入手测记为通过（用户确认）。[用户截图](evidence/m2-wechat-ime-user.png)显示 `IME_RESULT=[中文]` 和底部拼音预编辑文本；截图不包含候选框或取消操作的完整时序，不将这些写为主线程独立观察。组合中切换焦点、精确尺寸及分栏仍单列待验。[人工回执](evidence/m2-wechat-ime-user.json)。

- 当前 VT Release 的 ⌘K 打开命令面板，Escape 返回；⌘L 选中地址；点击终端后输入生效，shell PID 49591 保持。尚非完整焦点矩阵。
- Unicode/组合字符/Emoji/真彩色：新旧各五次 10000 行，均出现 `FIVE_BURSTS_DONE`。每次生成器正文 767067 字节、含标记总计 767248 字节；这是脚本输出计数，不是 PTY 实传计数。
- VT 退出时显示运行中会话确认；确认后 App PID 49064 和 shell PID 49591 均消失。
- 专用 SSH 资源：地址栏 `ssh://huaodong@127.0.0.1:60013` 创建独立资源，首次提示指纹与夹具公钥一致；用完整指纹确认后登录。远端 shell PID 82164，隐藏 Agent 前后 `stty size` 为 `45 98` → `45 134`，PID 不变。`exit 7` 后 App 显示 `Exited (7)` 并保留 `SSH_FINAL_7`。完整 AX 在 [最终状态](evidence/m2-ssh-final.ax.txt)，真实画面见 [首次指纹](evidence/m2-ssh-first-use.png)、[最终画面](evidence/m2-ssh-final.png)。这不是用户真实远端验收。
- 临时 sshd/专用 agent 已停止；仅移除本次端口及精确公钥的 known_hosts 条目，未改变既有记录。对照 App 均已退出，Debug 人工 IME 窗口保留。清理操作见 [回执](evidence/m2-ssh-cleanup.json)。

## 探索性 CPU/RSS 数据

| 构建 | 5轮空闲区间 CPU 中位数 | Unicode 25秒包络 CPU时间增量 | 负载离散 RSS 范围 |
| --- | --- | --- | --- |
| legacy | 0.399% | 0.82 s | 90560–120592 KiB |
| vt | 0.200% | 1.67 s | 77696–144288 KiB |

五轮空闲各5秒、0.5秒采样间隔。负载为单次25秒包络内五次固定输出，不是五次独立精确计时。VT 网格45×98、legacy为47×108；VT终端亮色、legacy终端深色。其他用户进程继续运行，RSS 也受操作系统回收影响。包络包含UI下发与空闲尾部。这组数据不能归因于单独渲染器，不能宣称整体更快/更慢，不能作性能验收阈值。原始数据、二进制及脚本哈希、条件见 [conditions](evidence/performance-baseline/conditions.json)。

首轮 legacy 误采了 `/usr/bin/login`，已保留到 `rejected-login-pid/` 并从此表排除。修正后的全部样本命令明确指向实际 App。CPU是单PID累计时间差；RSS是离散范围，非峰值；帧时间、输入延迟、GPU尚未测得。仍需同网格/外观、ASCII、隐藏空闲、滚动/resize、独立重复与trace。

## 尚需完成

IME 在组合中切换焦点、900×560及分栏场景的专项复验、VoiceOver全流程、精确900×560内容区和其他显示缩放、完整鼠标/键盘/焦点/关闭矩阵、规范化性能对照。`--minimum-window` 启动参数没有独立尺寸测量，不算精确尺寸通过。截图由真实窗口采集，工具会缩放；JPEG转PNG只转换编码，不恢复原生显示尺寸。

本轮不切换生产默认，不把脚本/构建通过写为M2整体通过。流程改进候选见 [skill观察](SKILL-OBSERVATIONS.md)。

记录限制：上述构建/smoke原始执行结果为通过，记录包含源码哈希；主线程未传递任务版本绑定参数，缺少task revision token。结构状态中已标为stale，不能用于skill最终验收门禁。正式收尾应在冻结变更后按绑定版本重跑；没有事后补填执行token。

## 恢复执行记录入口

2026-09-16 后续窗口、人工回执、生命周期、性能可比性和冻结版本回归统一记录于 [恢复实测结果](evidence/m2-resume-results.md)。下文或上述旧结果保留各自版本边界；本轮最新判定以该记录和 task-state.json 为准。
