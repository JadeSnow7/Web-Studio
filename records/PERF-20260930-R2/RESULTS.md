# Web Studio VT 性能优化第二轮结果（2026-09-30）

范围：在第一轮（`records/PERF-20260929/`）已合入、未提交的工作树上继续。主代理 Opus 5.5 负责计划、审查、合并与权威复测；具体实现与测量由 Sonnet 5.5 子代理完成。**没有提交、推送、stash 或切换默认后端（仍为 GhosttyKit）。** 所有数字均来自已运行且留有原始数据的命令；未测项明确标为未测。

## 0. 起点与方法

- 对照根：`/private/tmp/ws-vt-perf/post-batch1-src`，即第一轮合并后工作树的冻结拷贝（`Web Studio/`、`Vendor/`、`scripts/module.modulemap`，615 个文件，清单见 `evidence/data/post-batch1-src.sha256`）。
- 起点门槛（P0，主树）：11 项 headless 门槛全部 exit 0，font-equivalence 9/9 与金标一致（`evidence/data/gates-p0.txt`）。
- 噪声底：对照根 vs 自身，Release，6 组交替配对（`evidence/data/noise-floor*.json`）。hot_100 已降到 20–50 ms 量级，单对相对波动可达 25–50%，因此 hot/blink 只看"有无可重复退化"。
- 电源：交流电、低电量模式关闭。子代理并行期间 loadavg 为 2–6，所以权威数字只取合并后由主代理持锁串行重跑的配对结果。
- 泳道隔离的偏差：原计划用 `isolation: worktree`，但 HEAD 的 worktree 不含第一轮改动。因此每条泳道改用 `/private/tmp/ws-vt-perf/r2/<lane>/src`（冻结树的 `git init` 拷贝），补丁路径与主仓库一致，直接 `git apply`。没有产生新的 worktree 或分支。

## 1. 交付汇总

| 任务 | 状态 | 补丁 |
|---|---|---|
| T1 真实 App 验证 | **未测**（用户决定本轮跳过 GUI）：computer-use 授权被拒；shell 无辅助功能/事件权限（`AXIsProcessTrusted=false`、`CGPreflightPostEventAccess=false`） | — |
| T2 R3 增量图集 | 已合入 | `evidence/patches/R3-incremental-atlas.diff` |
| T3 输入次序与静默丢弃 | 已合入 | `evidence/patches/T3-input-order-drops.diff` |
| T4 scrollback 取舍 | 已测量；用户选定 10 MB，**已实施** | `evidence/patches/T4-scrollback-10MB.diff` |
| T5 前台进度 tick | 已合入 | `evidence/patches/T5-progress-mirror.diff` |
| T6 B1 领先沿 | 已测量，候选补丁**未合入**（与"不改 16ms 合并"冲突，待用户决定） | `evidence/patches/B1L-leading-edge-CANDIDATE-not-applied.diff` |
| T6 其他 | 分析结论见 §6，无代码改动 | — |

四个已合入补丁的文件互不重叠，各自可独立 `git apply -R <补丁>` 回退。T5 补丁的基准是含用户 B1 改动的当前文件，只包含本轮 hunk。

## 2. T2 — R3 增量图集（`Web Studio/TerminalMetalRenderer.swift`、`scripts/terminal-metal-smoke.swift`）

改动（行号为合并后）：
- `PreparedAtlas` 改为追加式（约 176–300 行）。miss 时只把缺失字形打包进新的 2 的幂小页（64–2048），每页一个 CGContext，保留 1 px 零间隙。纹理在被任何命令缓冲引用前写入一次，之后不再修改。表索引在两次压缩之间稳定。
- 原因：旧实现任一 miss 都要整表重建（16 MiB 清零页、每字形一个整页 CGContext、16 MiB 纹理）。
- raster 缓存改为 O(1) LRU `GlyphLRU`（63 行），key 为结构体，替换了原来的 FIFO、O(n) `removeAll` 和字符串插值 key。
- 上限（447 行起）：`maxAtlasPages = 16`、`maxAtlasBytes = 64 MiB`、`maxGlyphRuns = 48`，超限即按当前帧的字形集压缩一次（`extendAtlas`/`compactAtlas`，899 行起）。压缩会替换 `atlas`，由 `didSet` 清 ASCII 表；追加不清表。
- 增量图集按 cell 顺序分段绘制（同页相邻的 quad 合成一次 draw），以保持与整表重建相同的混合次序；一次性构建的图集仍按页分组绘制。
- `packedHeightBudget = 256`（204 行）：见下文像素说明。

门槛（主树，合并后，`gates-after-R3.txt`）：11 项全部 exit 0，含 `test-terminal-metal.sh` 的 1200+1200 图集压力与新增断言：
- 长 churn 下页数 ≤16、字节 ≤64 MiB，发生了压缩；
- 旧页的纹理对象与 SHA-256 均不变；
- 每帧与串行参考逐字节相同；
- 压缩后 ASCII 表确实被清；
- 三帧真实在途（blocker 挡住渲染器队列，24/24 轮）期间追加页并发生 8 次压缩，72 帧 0 不一致；
- LRU 淘汰次序正确。

变异检查（子代理，10 项全部被抓到）：改写旧页、替换旧页、改写不采样的 texel、去掉任一上限、去掉 `resetASCII`、去掉 run 上限、LRU 命中不刷新。

**权威基准**（`evidence/data/bench-merged-summary.json`；对照 post-batch1-src，候选为主树，6 组交替，持锁串行）：

| 指标（CPU s） | 对照 | 候选 | 倍数 | 改善配对 |
|---|---:|---:|---:|---:|
| render_churn（60 帧，每帧有新字形） | 0.2940 | 0.0814 | 3.6× | 6/6 |
| render_churn，去掉首帧 | 0.2649 | 0.0566 | 4.7× | 6/6 |
| render_cold_first ASCII120 / CJK60 | 0.0088 / 0.0109 | 0.0055 / 0.0070 | 1.6× / 1.6× | 6/6 各 |
| render_hot_100 ASCII120 / CJK60 / SGR | 0.0378 / 0.0224 / 0.0478 | 0.0374 / 0.0235 / 0.0459 | 噪声内 | 4 / 1 / 6 |
| render_blink_100 | 0.0227 | 0.0219 | 噪声内 | 6/6 |
| snapshot_100 | 0.0209 | 0.0211 | +1.3%（噪声底 1.4%；本轮未改 core） | 0/6 |

- 相对噪声底的判定：4 项改善、**0 项退化**、36 项在噪声内。
- 像素：16 个哈希 control==candidate，且与第一轮金标一致（ALL EQUAL）。
- 每帧 churn 成本约从 4.9 ms 降到 1.4 ms。这是离屏渲染 CPU，不是整机 CPU、GPU 时间或输入延迟。

**像素等价的保留意见（已裁定接受）**：1× 时字形 quad 的纵向双线性权重恰好落在舍入 tie（17.5/256）上，最末一位取决于采样纹理行坐标的量级。子代理在基线自身上验证过：只把基线图集起始行从 1 改到 300，1× 的 122/122 帧就出现 ±1/255 差异；2× 没有 tie。
- 由此可知，**任何会改变图集布局的实现，在 1× 下都只能在经验上与基线逐字节一致**。基线本身也按每帧字形的首现顺序排布，同样有这个性质。
- 加上 `packedHeightBudget` 后，1×/2×/3×/4× 及 1.25/1.5 的扫描共 1600+ 帧与基线 0 差异；不加时 1× churn 有 12/244 帧出现 ±1 差异。
- 所有既定门槛（金标、bench 哈希含 churn 取样帧）均逐字节一致，并未放宽标准，因此没有回退。只测了默认的 13 pt 字号，其他字号下 tie 的位置会变（未测）。

## 3. T3 — 键盘输入次序与静默丢弃（`TerminalPTYTransport.swift`、`TerminalVTBackend.swift`、`TerminalVTSession.swift`、`TerminalVTView.swift`、`scripts/terminal-vt-backend-smoke.swift`）

- 根因：`encodeKey` 在队列块里调用 `transport.write`，后者再 `queue.async` 一次；`sendRaw` 从主线程直接入队。于是 `encodeKey('a')` 后紧跟 `sendRaw('b')`，子进程收到的是 "ba"。另外，256 KiB 准入满时，键盘、focus/mouse 报告、DSR/DA 查询回复以及提交的 IME 文本都被静默丢弃。
- 先写失败测试：在未修改的基线上，O1/O2（乱序）、D1（键/焦点/鼠标/DSR 回复丢失）失败（`evidence/data/T3-baseline-fail.log`），T2（粘贴占满准入时提交文本被丢）失败（`T3-typed-fail.log`）。
- 修复：
  - 在传输队列上发起的写入立即追加到待写缓冲，排空仍延后一个 turn，避免在读回调里重入（`TerminalPTYTransport.swift` 112 行起）。
  - 交互写入走独立的 64 KiB 额外额度（19 行 `interactiveAllowance`）：`writeInteractive`（`TerminalVTBackend.swift` 219 行）与新的 `sendTyped`（119 行）。
  - 超出额度时计数（`droppedInteractiveBytes`），并通过新增的 `onInputDropped` 上报，不走 `onError`（后者会把会话置为 failed）。
  - 视图 `insertText` 的多字符/IME 提交改用 `sendTyped`。`sendRaw`/`send(data:)`/`paste` 保持 256 KiB 批量语义和返回值。
- `reservedInput` 恰好释放一次：新测试断言写完、close、子进程退出三种路径后都归零。
- 变异检查：去掉次序修复，O1/O2 失败；去掉丢弃修复，D1/D2 失败；`sendTyped` 改回批量写入，T2 的 5 项失败。
- 合并后主树门槛（`gates-after-T3.txt`）11/11 exit 0；`Web Studio VT` Release 构建成功，警告 37 条，与合并前相同，均不在终端文件里。
- 残留：
  - `onInputDropped` 尚未接到 UI，额度用尽时的丢弃只计数、不提示（产品决定）；
  - 两个不同线程之间竞争写入的相对次序仍无保证（主线程内按 FIFO）；
  - EIO 写错误路径没有单独测试。

## 4. T5 — 前台标签进度 tick（`WebRuntime.swift`、`ContentView.swift`、`Web StudioTests/ObservationChurnTests.swift`）

- 改动：
  - 新增 `WebNavigationState.toolbarMirror`（`WebRuntime.swift:44`），即去掉 `progress` 的镜像。
  - `StudioModel.activeWebState` 的三个写入点都改为写入镜像：`ContentView.swift:534`、`1559`、`1621-1622`；196 行更新了文档注释。
- 依据：`activeWebState` 的全部读者只用 `canGoBack`/`canGoForward`/`isLoading`（`ContentView.swift` 2476–2496、`Web_StudioApp.swift` 175–180）；进度条（`WebRuntime.swift` 约 541 行）直接观察 runtime。
- 红 → 绿：
  - 新测试 `progressTicksOfTheActiveTabDoNotInvalidateTheModel`：前台加载期间 100 次进度 tick，runtime 发射 100 次，`StudioModel.objectWillChange` 发射 0 次；随后 `isLoading`/`canGoBack` 的变化仍会发布。
  - 旧代码上 3 个测试失败（`T5-red.txt`）。
  - 修改后 `Web StudioTests` 串行运行 283/283 通过（`T5-green.txt`；基线 282 + 新增 1）。
- 用户文件校验：改前后各存 `git diff`，interdiff 只包含上述 4 处（`/private/tmp/ws-vt-perf/r2/diffs/`）。
- 语义变化：`model.activeWebState.progress` 恒为 0。全仓库没有读者；两个第一轮测试的断言已相应更新。

## 5. T4 — VT scrollback（`evidence/reports/T4-scrollback-report.md`、`T4-scrollback-tables.md`）

**实施（用户于 2026-10-02 选定 10 MB）**：
- `StudioVTCore.c` 的 `studio_vt_create` 新增一行：设置 `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES = 10000000`，设置失败则创建失败，与其他选项一致。
- 先写失败测试：`scripts/vt-core-test.c` 在 134×45 的终端上输出 12000 行 ASCII，断言总行数 ≥7000 且 <12000（既保留了历史，也确实被裁剪过）。
  - 改前为 673 行，断言失败（`evidence/data/T4-red.txt`）。
  - 改后为 8461 行，通过（`T4-green.txt`）。
- 最终门槛 11/11 exit 0，含 ASan（`gates-final.txt`）；`Web Studio VT` Release 构建成功。

**最终基准中可见的代价**（`bench-final-summary.json`，对照 post-batch1-src，6 组交替）：
- 渲染侧不受影响：churn 0.280 → 0.078 s，6/6；16 个像素哈希与金标一致。
- `feed_throughput` 退化 40–70%（ASCII 0.74 → 1.22 ms/MiB，0/6）。原因是这个基准只输出 1 万行，正处在历史增长期，每 353 行要新分配一页。
  - T4 的稳态数据：喂 10 万行、达到上限之后，ASCII 只多约 5%（0.65 → 0.68 ms/MiB），混合内容不变。
- `resize_seq` 的 reflow 从 0.55 ms 升到 5.3 ms（12 次，约 0.44 ms/次），因为现在真的有 8000 多行历史要重排；T4 实测混合内容单次最坏约 15 ms。
- 判定计数：4 项改善，11 项"退化"全部来自 feed/resize 这两组（scrollback 的预期代价），25 项在噪声内。
- 内存：每个满历史的终端约 10.6 MB（ASCII），8 个终端约 80 MB。

- 事实：未设置时 `SCROLLBACK_MAX_BYTES = 10000`（约 10 KB），`MAX_LINES` 不限。134 列下一页固定为 353 行，因此只稳定保留 310–663 行（1 万行输出后剩 442 行）。单设 `MAX_LINES` 无效，必须同时清除字节上限。
- 旧 GhosttyKit 路径：App 没有传 scrollback 配置（`GhosttyTerminalSession.swift:32-39`、`Vendor/ghostty/web-studio.conf`），使用 Ghostty 内置默认值；本地文档（`ghostty.5.md:1550-1571`）没有写出数值。10 MB 是上游默认值，**本地未验证**。
- 取舍（单终端喂 10 万行，中位数，ASCII / SGR 混合；8 终端为实测线性拟合）：

| 上限 | 保留行 | footprint/终端 | 单次 reflow 中位/最大（混合） | 8 终端 |
|---|---|---|---|---|
| 现默认 | 482 / 482 | 1.6 MB | 0.3 / 0.9 ms | — |
| 4 MB | 2960 / 2252 | 4.4 MB | 1.4 / 5.7 ms | ≈35 MB |
| 10 MB | 8270 / 6146 | 10.6 MB | 4.1 / 14.9 ms | ≈80 MB |
| 25 MB | 21368 / 16058 | 25.8 MB | 11.1 / 39 ms | ≈200 MB |
| 50 MB | 42962 / 32342 | 50.8 MB | 22.6 / 75 ms | ≈400 MB |

- snapshot 耗时与历史长度无关；混合内容的 feed 成本与上限无关。
- 缩到 108 列时 footprint 会临时升到上限的约 1.5 倍，恢复列宽后回落。
- 局限：footprint 不是 RSS；测量期间有其他泳道在跑（loadavg 2–6）。
- 过程披露：该子代理对用户仓库执行过一次只读 `git status`，并手动删除过一次 bench 锁。受影响的 R3 bench-1 已作废，R3 用 bench-2，且权威数字来自合并后主代理的重跑。

## 6. T6 门控项

- **B1 领先沿（已测量，未合入）**（`evidence/reports/B1L-leading-edge-report.md`，backend-to-onFrame，不是 input-to-photon）：
  - 现状下空闲后的回显延迟近似常数，p50 为 18.9 ms（16.9–25.4）。原因是按键路径先武装了 16 ms 定时器，回显约 0.2 ms 后才到。
  - 候选只在 `consume()` 做领先沿：距上次发布 ≥16 ms 就立即发布。结果回显 p50 从 18.9 降到 0.55 ms、p99 从 24.3 降到 1.05 ms（6/6）；连打时平均延迟从 13.1 降到 6.6 ms。
  - 代价：持续输出帧率从 54.5 升到 62.1/s（最小帧间隔仍为 16.06 ms），每 GB 的 CPU 在噪声内，唤醒次数反而更少。
  - 与本轮约束"不改 16ms 合并"冲突，**未合入，交由用户决定**。
- **B7 数据（新发现）**：同一次测量里，空闲终端（0 输出、0 帧）仍有约 **20 次/s 唤醒**，即每终端 50 ms 的 `waitid` 退出轮询。这是 B7（改用 `DispatchSource` 进程事件）的第一份占比数据；B7 涉及关闭与 SIGKILL 升级路径，风险最高，本轮未做。
- **B5/B6**：feed 约 0.75 ms/MiB（ASCII）、1.05 ms/MiB（混合），snapshot 约 0.21 ms/帧。R 系优化之后，snapshot 在"快照+热渲染"离屏 CPU 中约占 36%，但绝对值很小（60 fps 下约为单核的 1.3%），而且没有 App 级占比数据。未做。
- **V4d：不应用**。视图在 `session.encode` 返回 true 时无条件 `scrollToBottom`，后端只在编码结果非空时滚动。按键编码为空时两者不等价，而收益只是每次按键少一次队列 hop。
- **`PWD_CHANGED` 回调**：API 存在（`terminal.h:1344`）。第一轮 B2 之后，`pwd()` 只在有新输入且发布帧时才读取，替换它几乎没有收益。未做。
- **A2 拖动**：侧栏/Agent 栏拖动在每个 `onChanged` 写 `@Published`（`ContentView.swift:2183-2205`），分栏拖动在比例变化超过 0.001 时写 `layout.splitRatio`（`WorkspaceSplitView.swift:73`），都会使整棵 `StudioModel` 树失效。量化需要 GUI 或 SwiftUI Instruments，通道不可用，未做。
- **A3 / A4 / A5**：未做（A3 需要 GUI 数据；A4/A5 需先征得用户同意）。

## 7. 未测与残留风险

- **T1 全部未测**：中文 IME（用户手测）、VoiceOver（用户手测）、选区复制、主题、缩放、隐藏恢复、双栏 resize、SSH、退出确认、光标闪烁、Agent 读取；V3、V4c、B1、B4 在真实窗口中的行为；并发/resize 端到端配对。本轮新增的 R3/T3/T5 同样没有 GUI 数据。
- `Web StudioTests` 在全部合入后的最终树上又串行跑了一次：283/283 通过（xcresult `Test-Web Studio-2026.09.30_07-06-59`，`evidence/data/final-web-studio-tests.txt`）。R3/T3 的六个文件包在 `#if WEB_STUDIO_VT` 中，默认宿主目标不编译它们；VT 目标没有可运行的单元测试（其 scheme 的 TestAction 为空）。
- 所有离屏数字都不能说成整机 CPU、输入延迟或 GPU 时间。
