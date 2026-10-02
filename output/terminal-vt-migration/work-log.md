# VT-M2-20260916 执行日志

- 2026-09-16T06:31:14.444895+00:00 EVENT-001：核实基线并建立文档、验收与写入所有权；开始执行已获准计划。

- 2026-09-16T06:59:27.700170+00:00 EVENT-002：Veriflow 修复 a4e841f 已推送，push/PR 两轮共六个矩阵 job 通过。当前 Web Studio Debug、VT/legacy Release 构建及主线程 host/PTY/backend/ASan 回归通过。Swift smoke 仍有异步上下文 NSLock 警告，未将其当 Swift 6 严格模式通过。系统中文输入法仍待用户实测。
- EVENT-003：性能工具独立审查退回：真实 ESC、CPU 时间分母与字节计数已修；CPU 计数回退、采样错误分类和单样本状态仍由 coder 修正。修复审查通过前不作 App 性能结论。

- 2026-09-16T07:11:27.286187+00:00 EVENT-004：coder v5 性能工具经主线程九项测试通过；完成两App各5轮空闲与各5次Unicode负载的探索性CPU/RSS，误采login原始记录隔离保留。专用SSH资源首次指纹/输入/resize/PID保持/exit7画面通过，fixture清理完成。当前结果与限制写入M2-CURRENT-RESULTS.md；真实IME仍待用户输入，整体M2保持未判定。

- 2026-09-16T07:26:34.550665+00:00 EVENT-005：用户使用微信输入法，反馈输入一切正常；原始截图归档并记录SHA256，中文提交及预编辑可见。默认窗口手测记通过，来源为用户人工确认；跨焦点/最小尺寸/分栏继续待验。同步STATUS、ACCEPTANCE、当前结果和人工清单。

- 2026-09-16T07:30:12.140026+00:00 EVENT-006：恢复核查HEAD 2631e14及现有未提交范围；纠正结构状态clean为dirty_dependency_confirmed。读取Veriflow当前skill及恢复/证据规则。专用SSH与默认IME沿用已记录结果；只读几何工具委派coder，其余共享文件由主线程维护。

- 2026-09-16T07:44:47.187521+00:00 EVENT-007：只读几何工具首轮真实PID因非有限AX坐标崩溃，退回coder修复后主线程复测；实测外框900×600、toolbar40、分栏内容高560，显示2×。深色双栏SPLIT_IME现场已准备并发出人工协助请求；旧默认IME不重复询问。冻结回归原始命令全部退出0但pycache改变revision，保留不作有效门禁，准备禁用字节码重跑。

- 2026-09-16T07:48:27.838961+00:00 EVENT-008：清理本轮pycache并禁用字节码写入，三个构建v2及终端回归v2均以相同revision token通过；真实窗口几何也按冻结版本重测。性能字体候选已核对但Ghostty实际字体/格距未验证；未采不可比新数字、未定预算。人工现场保留，整体M2未判定。

- 2026-09-16T07:56:39.979819+00:00 EVENT-009：用户明确要求准备提交并推送，替代此前本轮不提交推送限制。完成阶段差异与证据匹配审查；只交付当前快照，M2整体继续未判定。commit/push动作planned，目标main/origin/main。

- 2026-09-16T07:58:37.805686+00:00 EVENT-010：阶段快照6f789f4d33e9dd62cf00c438dc8ded752fefc91f提交推送成功，ls-remote确认origin/main同SHA；更新结构状态、摘要和推送回执，并同步该文档更新。当前M2仍未判定，未修改App/生产配置，未合并部署。

- 2026-09-16T08:14:52.099505+00:00 EVENT-011：恢复核验HEAD/远端ced7edc，初始worktree干净；用户扩展IME及普通VO朗读通过已归档，原始VO截图未找到；语音输入未判定。使用Veriflow L2继续。当前GUI PID21524；先前误定位Final bundle仅只读观察，不纳入本轮证据。当前授权不提交推送。

- 2026-09-16T08:20:55.895110+00:00 EVENT-012：精确亮色双栏/亮暗单栏PNG已归档、自动外观已恢复；资源隐藏恢复、普通焦点返回输入、专属关闭取消/确认和4所属PID回收及2无关PID保活通过。剩余VO安全现场已交用户；性能probe沙箱失败后宿主重试成功，正在对齐。原冻结记录保持历史token，新增工具/规范文档改变全局token故机械current改stale，不伪造旧测试重跑。

- 2026-09-16T08:59:47.711101+00:00 EVENT-013：独立新工具回归及actual副本字体/grid复测通过，token=patch:2631e149787c6cfd8d9b0903c89995e8cde96083:3de8294d1281516f5f82186dc0ad20de0c4ecce9ff7e32cea704cd763f009fa9；完成六类CPU/RSS三轮采样，完整时间窗复核；GPU trace缺呈现/输入关联且VT无目标GPU导出，保留未判定。预算已proposed并问用户；无人工VO剩余回执。trace环境秘密已脱敏及原始文件清理，事件已告知用户。对照App和shell退出，原安全现场保留、自动外观恢复。未提交推送。

- 2026-09-16T09:02:07.483582+00:00 EVENT-014：首次record gate因仓库外fixture失败，保留m2-followup-record-review.json；main-v2先cmp实际副本与仓库fixture后复测通过，EVD-014历史、EVD-017当前。skill问题仅记录evidence/m2-followup-skill-additional.md。

- 2026-09-16T09:03:19.906698+00:00 EVENT-015：v2 record gate仍因stale历史EVD-014外部fixture失败。保留证据、记录skill限制，MET-005整体一致性设undetermined；实际新增工具回归、EVD-017字体/grid复测仍passed。当前原终端安全现场保留；预算与VO回执未收到。

- 2026-09-16T09:24:06.887137+00:00 EVENT-016：开始已获准性能调查；新证据目录performance-investigation-20260916。主线程冻结协议，coder独占新增测量工具。生产源码不变，六组配对前先校验观测链路。

- 2026-09-16T09:27:58.647477+00:00 EVENT-017：测量工具草稿提前审查发现自身PTY模拟未经过App、DSR模拟回复及rusage字段偏移错误，已退回coder；未用于实测。隔离VT/legacy窗口均1400×859、2×。Instruments沙箱只读查询失败，最小环境宿主查询成功。

- 2026-09-16T09:31:26.552255+00:00 EVENT-018：再次审查测量工具未通过：reset未发终端序列、未处理短写、并发负载未读真实输入；要求coder修正并补契约测试。trace工具同时退回完整路径身份校验和真实export语法问题。两者均未作为正式采集工具使用；未修改生产渲染。

- EVENT-019：主线程按本机Xcode27 help纠正自身审查判断：export位置参数合法，也支持--input；不将其记为工具缺陷。完整进程路径、脱敏和上限审查继续。

- 2026-09-16T09:41:54.306544+00:00 EVENT-020：真实VT reset/load DSR及末行图像通过pilot；发现系统Python单调时钟参照与主线程不同，统一CLOCK_MONOTONIC_RAW；发现libproc ticks须按125/3换算，修正后3.01246秒与ps3.01秒相符。工具8tests绑定执行通过。TimeProfiler v2录制产物44.8MB但墙钟超时，保留失败；同次record还因coder pycache标revision_changed。正式配对尚未开始。

- 2026-09-16T13:44:37.232402+00:00 EVENT-021：修正Mach ticks/单调时钟/真实DSR/短写/祖先链和采样有效性；发现旧legacy coverage不等价，保留失败与旧诊断，重建两端无coverage Release并核查symbols/hash。

- 2026-09-16T13:44:37.232402+00:00 EVENT-022：clean-output-matrix-01完成36轮（3场景×6对），主线程核验计数、负载、时间窗及末屏；版本绑定batch passed。样本不剔除；CPU、回执和RSS分报，fallback/全历史/呈现未证明等价。

- 2026-09-16T13:44:37.232402+00:00 EVENT-023：独立5秒sample放大500次mixed负载取得完整符号栈，字体获取为候选。coder单文件隔离帧内字体cache经主审，独立Release及Metal smoke绑定passed；性能改善和完整正确性待测，不合入生产。

- 2026-09-16T13:44:37.232402+00:00 EVENT-024：idle采样启动两次失败保留，第三批仅VT可见空闲一轮后Mac锁屏，CUA自动解锁失败。已请求手动解锁并停止自有runner，未触及原GUI。报告/候选预算/状态同步；M2仍未判定，未提交推送。

- 2026-09-16T13:47:04.858108+00:00 EVENT-025：主线程只读复核原GUI PID21524仍在、自有比较App均退出、生产renderer diff为空。最终record gate v2仅余CHG-001/002历史revision不匹配；保留旧review与原执行，不刷新为当前通过。CUA再次确认Mac锁屏；待手动解锁。

- 2026-09-16T16:08:57.994102+00:00 EVENT-026：解锁后完成idle24轮、字体实验12轮与9幅像素等价；两次有效5秒profile各500负载DSR通过。实际历史不等价被发现并隔离对齐；工具错误如实退回，后续交互配对进行中，未修改生产renderer。

- 2026-09-16T16:39:10.008153+00:00 EVENT-027：历史/resize四轮pilot主线程逐一核验；formal-01准备阶段额外隔离App身份不匹配被拦截，formal-02完整重跑第一组末尾Mac再次锁定。只SIGINT自有协调器清理，原GUI不动；不合池补足六对。checkpoint、预算v2、状态与验收同步，保留proposed/未判定。

- 2026-09-16T16:42:02.732417+00:00 EVENT-028：最终核验原GUI自身hash与五冻结文件均匹配，自有比较App已清理，主renderer无diff；纠正cleanup v1错用冻结build参照的比较，保留v1/v2。原REPORT恢复精确历史hash，新检查点独立存储；record gate保留CHG-001/002 stale失败，未改skill、提交或切换默认。

- EVENT-029：用户再次解锁。恢复前修正performance_investigation旧平行字段的过时计数/路径；预先确定续跑相同协议pair2..6，保留matrix-02第一组4个已核验测量窗，末轮测量后锁屏清理单列。未按CPU结果选样；早先matrix-01和pilot不纳入正式系列。

## EVENT-030 — 2026-09-17 历史交互六组完成

按 EVENT-029 预先声明的续跑选择完成 pair 2–6，主线程独立检查24个窗：身份链、CPU实例UUID、实际负载hash/字节、预热及重置、动作网格、DSR和采样边界全部匹配。结果见 HISTORY-INTERACTION-RESULTS-20260917.md 与 history-interaction-results-20260917.json。resize六对CPU差值均正，滚动四正两负；含UI观测成本，不作帧率或验收判断。恢复批次绑定退出0；原中断执行失败保持。并发协调器源代码审查发现错误路由、漏reset/状态校验与DSR超时未传播，已交原coder修正，暂未开启GUI并发测量。

## EVENT-031 — 2026-09-17 真实并发六组及调用栈完成

主线程独立绑定matrix18、sampler9、child4检查通过。最初unittest discover因连字符文件名发现0 tests并退出5，记录concurrent-coordinator-checks-v1.json保留；改为实际逐脚本执行，未标成通过。试采01暴露跨CUA调用的phase启动竞态，试采02为现场函数绑定失败，均保留；03完整两端真实PTY通过后启动正式六组。正式12个窗口/36个含预热负载全部hash/序列/身份/DSR边界匹配。App CPU中位VT5.538143秒/旧1.657350秒；子进程0.070839/0.121325秒，单列，含AX成本。独立两端5秒调用树有效，VT字体分支再次明显。报告与完整数值见CONCURRENT-RESULTS-20260917.md、concurrent-results-20260917.json。所有profile轮次排除基线。下一步live allocation/VM与Unicode诊断，未改生产渲染。

## EVENT-032 — 2026-09-17 内存快照与Unicode诊断工具复验

主线程审查内存工具发现buffered read超时风险、MALLOC列语义不明与peak覆盖current风险，coder修正。真实heap按COUNT/BYTES/AVG行与nodes汇总交叉校准，多词类名仅丢弃、不导出。绑定memory-tool-checks-v3七项通过；VT/旧独立快照退出0，存活节点160689/167273、heap字节23924925/27774839，仅单次旁证。原未知格式及VT后续CUA断开失败保留，详见MEMORY-SNAPSHOT-RESULTS-20260917.md。

Unicode四fixture离屏工具由coder独占新文件实现；主线程退回静态字符串检查，改真实Release构建执行。v1编译暴露CGGlyph初始化/CF条件转换错误；v2编译成功但Swift CRLF单Character导致expected多删一字，运行严格内容校验失败。修正工具预期后新目录重验，不改生产renderer。

## EVENT-033 — 2026-09-17 本轮性能调查结果整合

Unicode v3真实Release执行24记录通过，逐行内容/hash/cells/glyph无零值复核。相同占用cells的重复CJK热CPU低于ASCII，同bytes/cells不同字形热差约1.6%，首帧波动保留；不支持Unicode普遍更慢。全报告RESULTS-20260917.md及EVD-019为新证据，原REPORT及历史hash不改。96个正式App窗口及所有重复/配对差值、调用栈、内存旁证、唯一隔离字体实验及未测边界集中交付；预算v4仍proposed、MET004/M2不判通过。独立收尾七hash一致、原PID21524存活、生产renderer空diff、自有App归零、仅停止本轮caffeinate。下一依赖为预算用户审查和优化采用所需完整场景/GUI回归，及精确生命周期/presentation指标。

## EVENT-034 — 最终记录一致性复核

首个final-investigation-record-gate除历史CHG001/002外报告新EVD019绑定较早Unicode执行revision。该新报告尚在本轮编辑，主线程完成最终报告/预算v5/共享入口内容核对后对EVD019自身重新绑定当前内容；不改历史证据，不隐藏首个gate错误。最终gate-v2用于核验修正后的新报告引用。
