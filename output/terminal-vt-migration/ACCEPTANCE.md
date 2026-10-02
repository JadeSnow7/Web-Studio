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

# 自有终端迁移验收

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


## 当前结论

新后端在独立 `Web Studio VT` 构建目标中开发。默认 `Web Studio` 仍使用旧后端，等待下表各项验收后再切换。效果图仅作为设计参考；离屏 Metal 图片不能替代真实窗口截图。

M2 已实现系统增加对比度、减少动态效果和非闪动光标偏好。主线程已独立通过增强键盘精确字节、IME 接口、AX 范围/坐标和 Metal 宿主测试；最终窗口已验证原生滚动条拖动、跨外观选区、Agent 显式预览和退出画面保留。PTY 已独立通过同会话前台、后台进程组回收和自然退出测试。微信输入法默认窗口手测已获用户确认正常；跨焦点/最小窗口/分栏 IME、完整无障碍和性能对照仍待验收。

最新现场记录见 [GUI-20260916.md](GUI-20260916.md)：Shell、Ctrl-C、复制粘贴确认、vim/less/top、资源隐藏、亮暗切换、分栏和隔离 SSH 输入/resize/退出已通过所列场景。后续源码变化仍需复验。

## 验收记录

| 范围 | 已有证据 | 尚需验证 |
|---|---|---|
| 固定依赖 | 固定 SHA、Zig 0.16.0、头文件清单、归档校验、独立重建与运行 smoke | 无自动跟随 main |
| 终端核心 | ANSI、Unicode、查询响应、网格、resize、主题覆盖、64 KiB UTF-8 边界测试 | 新增选择、鼠标、粘贴接口的完整回归 |
| PTY | 大量输出、退出、实际 Ctrl-C；不配合退出的同会话前台/后台进程在关闭返回后即时 ESRCH，自然退出保留 code 7 和最终输出；继承信号屏蔽复位和像素尺寸 | App 退出确认后 PID 回收已复验；更多资源关闭/焦点场景仍待验收 |
| 自有渲染 | Apple M4 CoreText / Metal，亮暗和 1x/2x 离屏图；真实窗口亮暗、分栏、缩小窗口、选区与光标观察 | 精确 900×560、其他实际显示缩放、真实 PNG 归档 |
| App 链接 | 最终 arm64 Debug/Release 构建通过；最终 Release 链接检查未混入旧依赖 | 生产默认切换尚未执行 |
| 原生交互 | Shell、Ctrl-C、复制/确认粘贴、滚轮、vim/less/top、SGR 左键报告；微信输入法默认窗口手测正常（用户确认） | IME 跨焦点/最小窗口/分栏、完整鼠标/键盘协议、VoiceOver（原生滚动条拖动已通过） |
| 会话与 Agent | 实际隐藏/显示、主题、分栏后 PID/历史保持；有界读取和最终画面脚本通过 | 选区跨外观和最终窗口 Agent 显式预览已通过；剩余焦点/关闭场景待验证 |
| 应用测试 | Swift 6.4 下明确三个服务协议 nonisolated；主线程独立通过 128 项 / 11 套件 | 单元测试不替代 GUI/IME/性能 |
| 性能 | 保留旧后端探索性记录 | 相同固定负载的帧时间、输入延迟、CPU/GPU、内存、空闲绘制对照 |
| 默认切换 | 尚未执行 | 上述门槛通过后迁移测试、移除生产目标旧依赖并更新文档 |

## GUI 验收顺序

1. 使用隔离的 VT App 创建本地终端，执行同一组 ANSI、中文、组合字符、Emoji 和真彩色输出，保存亮暗真实截图。
2. 在默认窗口、900×560 和左右分栏中检查 16/12 pt 留白、基线、裁切、光标、选区和输入法候选框。
3. 使用系统中文输入法完成预编辑、候选切换、回车提交和 Escape 取消。合成 NSTextInputClient 调用只验证接口契约，不算这一项通过。
4. 执行 Shell、Ctrl-C、vim、less、top；检查应用光标、备用屏幕、粘贴模式、焦点与鼠标事件。
5. 通过隔离的 localhost SSH 服务验证输入、退出、远端 `stty size` 和主机密钥确认。该结果不代表用户真实远端已验证。
6. 记录 PID，依次切换资源、分栏、隐藏/显示和主题，确认 PID、历史、选区和焦点保持。关闭时检查所属进程回收且无关进程仍运行。
7. 回归 ⌘L、⌘K、关闭确认、显式 Agent 资源读取及网页区域。
8. 在新旧构建中运行同一固定负载，分别记录测量条件和原始计数；避免把 GPU 命令耗时称为帧时间或输入延迟。

用户处理许可后，Xcode 27 编译器和 GUI 访问均已恢复。主线程已独立复跑并通过修复后的宿主 smoke（包括 NSEvent Ctrl-C）和 C 适配层 AddressSanitizer 检查。M2 仍有后续实现与完整窗口验收，生产切换仍未执行；阶段性通过记录不能代表后续修改已经验收。

详细时间线和本机证据路径见 [STATUS.md](STATUS.md)。阶段快照已于本轮提交并推送为 `2631e14`；这不表示已完成分发签名、公证或生产切换。后续验收按当前构建分别记录，人工项目见 [本轮现场清单](MANUAL-ACCEPTANCE.md)。

本轮当前源码的复验及数据见 [M2 当前结果](M2-CURRENT-RESULTS.md)：独立 Debug/Release、host/PTY/backend/ASan、专用 SSH 首次密钥/输入/resize/退出，以及有限的 CPU/RSS 探索记录。微信输入法默认窗口手测已获用户确认；IME扩展场景、完整 VoiceOver、精确尺寸与规范化性能仍未验收。

## 恢复执行记录入口

2026-09-16 后续窗口、人工回执、生命周期、性能可比性和冻结版本回归统一记录于 [恢复实测结果](evidence/m2-resume-results.md)。下文或上述旧结果保留各自版本边界；本轮最新判定以该记录和 task-state.json 为准。

## 性能调查新增矩阵（非 M2 总验收）

| 项目 | 状态 | 依据/下一依赖 |
|---|---|---|
| 输出三个场景六对 | 已测，有限可比 | clean-output-results.json；fallback/绘制/全历史等价性未证 |
| 可见/隐藏空闲六对 | 未完成 | VT 可见仅一轮，Mac 锁屏 |
| 匹配距离滚动、实际 resize、并发六对 | 未完成 | 解锁与协议/动作验证 |
| 字体重复获取热点 | 栈支持候选 | 放大负载5秒sample；不能外推全部Unicode根因 |
| 隔离字体cache | 构建/smoke通过，效果未验证 | A/B及四traits/GUI回归待做，生产未采用 |
| GPU/帧/输入显示、allocation/可靠峰值 | 未判定 | 关联与分层采集不足 |
| 性能预算 | proposed | 用户确认前不判通过/失败 |
| record gate | failed | final-record-gate-v2：历史CHG-001/002 revision stale，原记录保留 |
