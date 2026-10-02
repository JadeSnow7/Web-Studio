# Web Studio VT 性能优化 Batch 0/1 结果（2026-09-29/30）

范围与来源：按 `~/.claude/plans/web-studio-vt-serialized-sprout.md` 执行，由 Sonnet 5.5 子代理实现，主代理逐个审查 diff 并合入主工作树。**没有提交、推送或切换默认后端；所有改动都在未提交的工作树里，回退方式见 §5。** 本文只陈述已运行并留有原始数据的结果；未测项明确标为未测。

## 1. 权威前后对照（合并后的主树 vs 冻结基线，headless）

对照：`/private/tmp/ws-vt-perf/baseline-src`（`git archive HEAD` 的冻结源码，VT 相关文件与工作树 HEAD 一致）。候选：包含 R/B/V/A 全部改动的主工作树。方法：`scripts/test-terminal-render-bench.sh` 的 compare 模式，Release（`swiftc -O`/`clang -O2`），134×45 网格，2× 缩放，深色主题，**6 组交替配对**，CPU 为 `getrusage` user+system，完成边界为 `waitUntilCompleted`（**不是 GPU 时间，也不是呈现或输入延迟**）。本次跑时机器接交流电、低电量模式关闭；Batch 0 的基线数字是在电池 + 低电量模式下测的，因此**只比较同一次运行里的配对值**。原始数据：`/private/tmp/ws-vt-perf/final/bench-compare/`。

| 指标 | 控制（HEAD） | 候选 | 倍数 | 改善配对 |
|---|---:|---:|---:|---:|
| 热提交 ×100 · ASCII120（CPU s） | 1.8588 | 0.0369 | 50× | 6/6 |
| 热提交 ×100 · CJK60 | 1.5367 | 0.0230 | 67× | 6/6 |
| 热提交 ×100 · SGR 混合（256 色/粗斜体/下划线） | 3.2852 | 0.0467 | 70× | 6/6 |
| 光标闪烁重绘 ×100 | 1.9038 | 0.0224 | 85× | 6/6 |
| 新字形持续出现（churn，60 帧） | 1.1140 | 0.2804 | 4.0× | 6/6 |
| 冷首帧 · ASCII120 / CJK60 / SGR | 0.0283 / 0.0215 / 0.0539 | 0.0082 / 0.0092 / 0.0203 | 3.4× / 2.3× / 2.6× | 6/6 各 |
| 快照 ×100、feed、resize_seq（本轮未改代码） | 0.0210 / — / 0.0027 | 0.0210 / — / 0.0027 | 无变化 | 噪声内 |

- **像素等价：`pixel_hashes_all_equal = true`**（ASCII120/CJK60/SGR 的冷/热末帧、churn 各取样帧与末帧、闪烁可见/隐藏相位）；9 幅 font-equivalence 金标由各泳道单独核对通过。
- 相对 Batch 0 噪声底的判定：17 项改善、0 项退化、23 项在噪声内或混合。
- 单帧热提交 CPU 约 18.6 ms → 0.37 ms（ASCII120，134×45）。**这是离屏渲染 CPU，不代表整机 CPU、输入延迟或 GPU 时间**；并发场景（早期 App 实测 5.54s vs 旧后端 1.66s）的收敛程度需要真实 App 复测，见 §6。
- churn 场景每帧仍要重建整张图集，约 4.7 ms/帧，是热帧的 12 倍，这是剩余最大的渲染成本（R3，见 §6）。

## 2. 各泳道实际改动

**R — `TerminalMetalRenderer.swift`（仅此文件）**
- R1：四个 traits 字体常驻；字符串 key 换成结构体 `GlyphKey`；ASCII 单字节直查表；图集全命中时每 cell 零堆分配，只有未命中才建请求列表并按原样重建图集（图集构造与光栅化代码未动）。
- R2：最终背景色等于清屏色的 cell 不再发背景 quad（唯一例外：上一格的双宽背景 quad 会覆盖到本格时仍要画，变异测试证明该例外必要）；`quad()` 直接追加顶点、去掉临时数组；`[Int:[Vertex]]` 改按图集页下标的数组；三槽只增不缩的共享存储缓冲环，槽位与在途 permit 绑定，一帧所有绘制组写入同一缓冲按 256 字节对齐偏移绘制，绘制顺序不变。
- R0（着色器缓存）已取消：Batch 0 实测同进程内第 2 次起 `TerminalMetalRenderer.init` 仅约 0.15 ms。
- 泳道自测的额外证据：169 个合成场景的差分测试（下划线 1–5、划线/上划线、隐藏/淡化/反色/选中、光标 0–4、宽字符异常状态、缩放 1/1.5/2/3、多页图集、三帧在途重叠）R1+R2 与 R1 逐位一致；900 帧流水线缓冲环压力测试对照串行渲染 0 处不一致，且故意让所有帧共用一个缓冲会产生 6 处不一致（说明测试能抓到该危害）。

**B — `TerminalVTBackend/Session/Core.swift`（外加 3 个 smoke 脚本的新增断言）**
- B1：不可见时不再快照（也不再排 16ms 定时器）；删除从未被读的 `lastFrame`；邮箱里仍有未消费帧时跳过快照，消费方 `frameDrained()` 后补一次调度（先置位再读邮箱、先取出再通知，无丢唤醒）；`finish()` 强制发最后一帧。领先沿立即发布（可选项）**未实现**。
- B2：目录不再由主线程每帧 `queue.sync` 读取；PTY 队列侧仅在有新输入且发布可见帧时读 `core.pwd()`，原始字符串变化才通过新增的 `onDirectory` 回调交给会话，会话先比较原始串、再比较规范化值，变化才赋 `knownDirectory`。
- B3：`mouseReporting()` 改为 `Atomic<Bool>` 镜像（每次 feed/resize 后刷新）；8 个选区调用的异步变体（旧同步方法保留）；主题未变时 `setTheme` 直接返回；空的键编码结果（松键/纯修饰键）与空 `sendRaw` 不再触发 `scrollToBottom`/`scheduleFrame`。
- B4：resize 同尺寸为完全空操作；突发内首个立即执行、24ms 内后续合并为一个尾沿；`core.resize` 与 ioctl 成对保序；退出时把待处理尺寸只应用到 core 再发最后一帧。
- 语义变化（已披露）：会话的 `selectionBegin/Update/End` 仍返回 `Bool`，但现在恒为 `true`，含义是"已排队"；全仓库没有调用方使用该返回值。

**V — `TerminalVTView.swift`、`TerminalVisuals.swift`（外加两个新的 headless 测试文件）**
- V1：`update(frame:)` 不再每帧构建整套 AX 模型；指纹改为 generation + 行列 + 滚动条 + 选区签名（零分配扫描）；`accessibilityModel()` 惰性构建并按帧/几何缓存。
- V2：`layout()` 仅在 (cols, rows, 单元像素尺寸) 变化时发 resize，`drawableSize` 仅在变化时设置（`TerminalGeometry` 缓存已取消：构造仅约 3 µs）。
- V3：先检查在途命令数，再取 `currentDrawable`。
- V4：`displayDebug` 改 `@autoclosure`（Release 二进制里对应字符串字面量为 0）；滚动条属性仅变化时写；光标闪烁不再每帧销毁重建 timer（重新锚定 fireDate + 过期 tick 保护）。**V4d（删除视图里重复的 `scrollToBottom`）没有合入**：并非严格冗余，见 `V4d-optional.diff`。

**A — `ResourceModel.swift`、`WebRuntime.swift`、`ContentView.swift`（外加 `ObservationChurnTests.swift`，均在用户已有未提交改动之上做外科式增改）**
- 所有 `records[id] = record` 写入改为"值变化才写"（`writeIfChanged`）；两个 `$knownDirectory` sink 加 `.removeDuplicates()`；`WebTabRuntime` 的 KVO 写入全部走 `mutateState`（相等不再触发 `@Published`）；`updateTitle`、`webStates`、`activeWebState` 同理。
- 新增 10 个 Swift Testing 用例；在旧写法上其中 8 个失败（100 次无变化更新分别产生 100/200/700 次 store/model/runtime 发射），改后为 0。**仍未解决**：被选中标签的 `activeWebState` 每次真实进度变化仍会发布，即前台标签的每个进度 tick 还会使整棵树失效（需要把进度从镜像里拆出，超出本轮范围）。

## 3. 门槛与测试证据（子代理自测，各自日志在 `/private/tmp/ws-vt-perf/<lane>/`）

| 泳道 | 结果 |
|---|---|
| R | font-equivalence 9/9 金标、metal smoke（含 1200+1200 图集压力）、host smoke 均 exit 0；bench 16 个像素哈希全等；unicode 诊断跑完 24 条记录，**退出码未记录** |
| B | backend / host / core / core-asan / pty-transport / pty-transport-swift / metal 全部 exit 0（含最终树上 backend 与 host 又各重跑 2 次，4/4 通过）；Debug 应用目标构建成功且告警与对照一致；每个修复都做过"还原修复→断言失败"的变异检查 |
| V | host / metal / core / 新增 visuals 全部 exit 0；Debug 与 Release 应用目标构建成功，告警列表与对照一致（33 条，均不在改动文件中）；11 个变异中 10 个被测试抓到（漏掉的一个是 `needsDisplay` 的冗余赋值） |
| A | `Web StudioTests` 串行运行：基线 272/272，改后 282/282；`Web Studio VT` 目标构建成功 |

**基线里已存在的问题（非本轮引入）**：① `Web Studio VT` scheme 的 TestAction 为空，单元测试只能通过默认 `Web Studio` scheme 以 App 为宿主运行；② 默认并行运行时，`AgentControllerTests.sequentialRunsDisplayTranscriptAndKeepIndividualPayloads`（约 112 行）在负载下 `Index out of range` 崩掉测试宿主，之后所有在途测试被记为 crash，需要 `-parallel-testing-enabled NO`；③ 并行运行下 `ProviderSettingsTests.unsavedDraftDoesNotChangeCommittedStatus` 在 HEAD 上也会失败。

## 4. 合并后主代理复核

见 §7。

## 5. 回退

- 每个泳道有独立累计补丁：`/private/tmp/ws-vt-perf/{R/R1R2.diff, B/B1-B4.diff, V/V1-V4.diff, A/A1.diff}`；B 泳道另有 `B2-only/B3-only/B4-only.diff`，需按 LIFO（B4→B3→B2）逆向应用。`git apply -R <补丁>` 即可回退。
- 最终补丁和关键数据已复制到 `records/PERF-20260929/evidence/{patches,data}/`（`/private/tmp` 不是持久存储）。**注意**：`V1-V4.diff` 是泳道原样交付的版本，不含合并时对 `scripts/terminal-vt-visuals-smoke.swift` 的 `coreFollowsGrid` 修复（§7）；该修复只在工作树里。完整的原始运行数据与日志仍在 `/private/tmp/ws-vt-perf/`。
- 尚未 `git commit`；`scripts/terminal-render-bench.swift`、`scripts/test-terminal-render-bench.sh`、`scripts/terminal-vt-visuals-smoke.swift`、`scripts/test-terminal-vt-visuals.sh`、`Web StudioTests/ObservationChurnTests.swift` 是新增的未跟踪文件。

## 6. 未完成项与剩余成本（按数据排序）

1. **R3 增量图集**：churn 每帧仍要重建整张图集（约 4.7 ms/帧，热帧的 12 倍）；在滚动大量不同字形（CJK/emoji/日志里的新字符）时会主导。风险最高的是在途纹理安全，设计为"页不可变、miss 只追加小页"。
2. **R4 闪烁/静态帧复用**：闪烁重绘已降到约 0.22 ms，收益边际很小，暂不建议做。
3. **B5/B6/B7（快照瘦身、PTY 读路径、退出轮询改事件）**：快照/feed 基准没有变化且占比小，没有证据支持优先做。
4. **A2/A3/A4/A5（拖动状态、页面色截图轮询、⌘K 搜索、启动路径）**：需要单独量化 SwiftUI 更新次数和唤醒；A5 与用户的 B1 工作区代码耦合。
5. **前台标签的进度 tick 仍触发整树失效**（见 §2 A）。
6. **端到端未测**：真实 App 的并发/resize CPU、输入到显示延迟、GPU 时间、VoiceOver 通知实际行为、光标闪烁的窗口内行为、V3 的 drawable 路径、Web StudioTests 与 UI 测试在 VT 宿主下的运行——以上均没有数据，不能据本文推断。
7. 已知的取舍：字体在渲染器生命周期内只解析一次（运行中更换系统字体要重建渲染器才生效）；每个渲染器多占约 4 帧顶点数据（134×45 满屏约 7 MB，背景暂存的最坏容量按虚拟内存预留）。

## 7. 合并后主代理复核结果（R+B+V+A 全部在主工作树上）

日志：`/private/tmp/ws-vt-perf/final/gates/`。全部在合并后的主树上串行运行（脚本 `run_final_gates.sh`，由子代理执行并汇报，主代理逐项核对）。

| 门槛 | 结果 |
|---|---|
| `test-terminal-metal.sh`（含 1200+1200 图集压力与光标像素检查） | exit 0 |
| `test-terminal-vt-core.sh` / `-asan.sh` | exit 0 / exit 0 |
| `test-terminal-vt-backend.sh` / `test-terminal-vt-host.sh` | exit 0 / exit 0 |
| `test-terminal-pty-transport.sh` / `-swift.sh` | exit 0 / exit 0 |
| `test-terminal-font-frame-equivalence.sh` + 金标校验 | exit 0，9/9 哈希与金标一致 |
| 基准像素金标校验（16 个哈希） | exit 0，ALL EQUAL |
| `test-terminal-unicode-diagnostic.sh` | exit 0，24 条记录；warm_100 CPU 中位：ASCII120 0.0222 s、CJK60 0.0212 s、CJK40 0.0173 s、CJK40distinct 0.0199 s（Batch 0 在低电量模式下测得 3.85/3.14/3.07/2.88 s，不同电源状态，仅供量级参考） |
| `xcodebuild -scheme "Web Studio VT" -configuration Release build` | BUILD SUCCEEDED，0 error；37 条 warning 行，均不在本轮改动的文件里（`WebRuntime`/`CodexProcessRunner`/`WorkspaceRepository`/`WindowCoordinator`/`AgentService` 的既有隔离/未使用警告，统计含多行诊断的重复箭头行） |
| `xcodebuild build-for-testing -scheme "Web Studio"`（默认目标 + `Web StudioTests`） | TEST BUILD SUCCEEDED |
| `test-terminal-vt-visuals.sh`（V 泳道新增） | **首次合并运行失败，已修复**：见下；修复后连跑 4 次全部 exit 0 |

**合并时发现的跨泳道问题（已修）**：V 泳道的 `scripts/terminal-vt-visuals-smoke.swift` 在自己的 worktree 里通过，但合并 B4 之后失败，报 “the backend core must follow the new grid”。原因是 V 的测试假设 `layout()` 发出 resize 后核心网格立即变化，而 B4 让"突发内的第二个 resize"进入 24 ms 尾沿合并，同步快照读到的还是旧网格。产品行为符合 B4 设计（最终尺寸必落地，B 泳道的断言已覆盖），所以改的是测试：新增 `coreFollowsGrid(_:)` 轮询（10 ms 间隔、最长 2 s）并用于两处断言，并注释了原因。这是唯一一处由集成暴露的问题，说明泳道各自的 worktree 自测不能代替合并后的重跑。

**没有做的复核**：合并后没有重新运行 `Web StudioTests` 的实际测试（宿主为 GUI 应用，会启动 App）；A 泳道在合并 R/B/V 之前串行运行为 282/282，而 R/B/V 的六个文件全部包在 `#if WEB_STUDIO_VT` 中，默认目标不编译它们，因此该结果预期不受影响——这是推断，不是重跑得到的数据。VT 目标本身没有可运行的单元测试（scheme 的 TestAction 为空）。

## 8. 与本轮性能无关、但审计中发现的问题

1. **键盘输入次序与静默丢弃**：`TerminalVTBackend.encodeKey` 经 `queue.async` 再 `transport.write` 二次 hop，而 `sendRaw`/IME 文本直接入队，积压时字节可能乱序；256KB 准入满时键盘与查询回复的返回值被忽略而静默丢失（`TerminalVTBackend.swift`、`TerminalPTYTransport.swift`）。
2. **VT 默认 scrollback 明显小于旧后端**：`studio_vt_create` 未设置 `SCROLLBACK_MAX_*`，10000 行输出后只保留约 442 行（旧后端约 10 MB）。调大会增加内存与 reflow 耗时，需要产品决定。
3. 既有 GUI 采样通道不可靠（锁屏/请求超时），真实 App 配对仍为 0。
