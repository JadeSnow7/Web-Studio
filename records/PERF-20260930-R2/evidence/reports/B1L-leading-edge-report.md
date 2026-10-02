# VT 后端 "前沿即时发布 (leading-edge immediate publish)" 测量报告 (B1L)

日期 2026-09-30。**本报告只给数据与候选补丁，不做采纳决定。**
**重要限定：所有延迟均为「backend 收到 encodeKey 调用 → 首个含回显的 `onFrame` 回调入口」(backend-to-onFrame)，不是 input-to-photon。** 不含主线程 Task 跳转、TerminalVTView 更新、Metal 渲染、显示器刷新、键盘事件到 AppKit 的延迟。

## 1. 结论摘要 (数据)

| 项目 | 当前 | 候选 (空闲>=16 ms 即前沿发布) |
|---|---|---|
| 空闲后回显延迟 p50 / p90 / p99 / max (ms, n=1320) | 18.90 / 21.85 / 24.30 / 25.38 | 0.55 / 0.68 / 1.05 / 4.12 |
| 30 字连击 (8-12 ms 间隔) 全部字符延迟 p50 / p99 / mean (ms) | 16.26 / 24.13 / 13.11 | 0.86 / 19.62 / 6.61 |
| 连击首字符 p50 (ms) | 19.05 | 0.59 |
| 连击每 30 字发布帧数 (均值 / max) | 15.00 / 16 | 16.10 / 19 |
| 持续输出 yes, 5 s: 帧/s | 54.5 +- 2.3 | 62.16 +- 0.05 |
| 持续输出 SGR 混合: 帧/s | 54.5 +- 2.0 | 61.9 +- 0.3 |
| 持续输出 CPU (每 GB 输出的 CPU 秒, yes / sgr) | 11.87 / 7.89 | 11.75 / 8.01 |
| 20 s 空闲 (0 输出): 帧数 / 快照数 / 中断唤醒次数每秒 | 0 / 0 / 20.04 | 0 / 0 / 20.05 |

要点:
1. 当前代码的回显延迟**不是** 0-16 ms 均匀分布。`encodeKey/sendTyped/sendRaw` 在写入 PTY 后立刻 `scheduleFrame()` 设 16 ms 定时器，回显 (约 0.2 ms 后) 到达时 `framePending` 已为 true，不会重排。所以延迟是「16 ms + 定时器 leeway」的近似常数，实测 p50 18.9 ms，范围 16.9-25.4 ms（`DispatchSource` 未指定 leeway，系统默认 leeway 造成额外 1-4 ms，负载高时更大）。相位无关。
2. 突发内也不会被推迟：`guard ... !framePending` 使 deadline 只在一次突发的第一次 `scheduleFrame` 设定，后续调度不重排 (已读代码并由数据佐证)。
3. 候选**不能**只放在 `scheduleFrame()` 的按键路径上 (按键写 PTY 时回显还没回来，此时发布的帧不含回显；随后回显到达又落入 16 ms 窗口，收益为零)。有效的前沿点是 `consume()` (PTY 输出到达)。因此候选只在 `consume()` 里以 `scheduleFrame(leading: true)` 调用；按键、滚动、选择、resize、主题等路径保持原 16 ms 尾沿。
4. 候选在连击中收益大于「仅首字符」：任何时刻只要 PTY 输出到达且距上次发布 >=16 ms 就立即发布，等价于「最小间隔 16 ms 的前沿节流」，连击平均延迟 13.1 -> 6.6 ms (每 burst 均值 6/6 轮全部改善)，但 burst 内最大字符延迟仍约 19-20 ms (p50 18.5 vs 20.5)。
5. **代价/风险**：持续输出下候选发布率被推到名义上限 62.1/s (=1000/16.07)，当前因定时器 leeway 只有 54.5/s。任务里写的「<= ~60/s」在候选下被略微超出 (+14% 快照次数)；每 GB CPU 差异 <=1.5% 且方向不一致 (yes 3/3 好/差，sgr 候选 4/6 更差)，在噪声内。候选最小帧间隔 16.06 ms，未出现 <16 ms。
6. 附加观察：持续输出下候选的中断唤醒 18.5/s vs 当前 68.8/s (6/6 轮更少)，因为前沿发布抢在定时器之前，不再依赖 16 ms 定时器唤醒。

## 2. 方法

- 无 GUI，真实 PTY (`StudioPTY.c` + `TerminalPTYTransport`) + 真实 `GhosttyVTBackend` + 真实 libghostty-vt。
- 消费者模拟 Session：`onFrame` 记录时间 (`CLOCK_UPTIME_RAW`，回调入口第一件事) 后写入 latest-wins 邮箱，专用消费者线程取出并调用 `frameDrained()`；`hasUndrainedFrame` = 邮箱有值。`setVisible(true)`。
- 回显夹具 `scripts/terminal-vt-echo-fixture.c echo`：raw 模式，收到第 n 个字节即写出 `ESC[H ESC[2J E<n>;`（一次 write）。首个满足「最新标记 >= i 且时间 >= 发送时刻」的帧即第 i 个字符的到屏时刻。字符通过 `backend.encodeKey(GHOSTTY_KEY_A, text:"a")` 发送。
- 回显测试：每轮 220 样本，样本间空闲 = 上一回显被观察到之后随机 20-300 ms 均匀（种子固定，同一轮内各变体用同一序列，`seed=<round>`）。
- 连击：40 个 burst x 30 字符，字符间隔 8-12 ms 随机 (mach_wait_until 绝对时间)，burst 间空闲 150-400 ms，每 burst 统计帧数 (burst 起点到下一 burst 起点)。
- 持续输出：`/usr/bin/yes` 和夹具 `sgr` 模式（256 色/真彩/粗体/下划线/反显混合，每行 76 列，循环写 64 KB），出现输出后稳定 0.5 s，再取 5 s 窗口；`getrusage(RUSAGE_SELF)` 与 `proc_pid_rusage(RUSAGE_INFO_V4)`（cycles、interrupt_wkups）的差值。RUSAGE_SELF 不含子进程。
- 空闲：夹具 `idle`（输出 READY 后阻塞读），稳定 1 s 后取 20 s 窗口，0 输出。
- 6 轮；每轮持有机器锁整轮，三个变体各跑全部场景。顺序：奇数轮 `cur cand wide`，偶数轮 `wide cand cur`，因此 cur/cand 的相对先后严格交替。`wide` 是补充的第三臂 (空闲阈值 32 ms，其余与候选相同)，用于回答「如何把持续输出保持在 ~56/s」。
- 合并分布为 6 轮池化，逐轮结果见下表和 `raw/*.json`。
- 构建：`swiftc -O`、`clang -O2`，其余 flags 同 `scripts/test-terminal-vt-backend.sh`。

### 精确命令
```
# 构建 (每个变体一次)
scripts/terminal-vt-echo-latency-build.sh <backend.swift> build/<arm>     # arm=cur|cand|wide
# 一轮 (R=1..6)，全程持有 bench.lock
/private/tmp/ws-vt-perf/r2/B1L/withlock.sh /private/tmp/ws-vt-perf/r2/B1L/bench.sh R
#   bench.sh 内: harness echo|burst|flood-yes|flood-sgr|idle raw/rR-<arm>-<scenario>.json label=<arm> seed=R samples=220 bursts=40 seconds=5|20
# 汇总
python3 analyze.py > analysis.md
# 门禁 (持锁)
withlock.sh gates.sh   # 见第 5 节
```
`TMPDIR=/private/tmp/ws-vt-perf/tmp`。机器锁使用 owner 校验（`withlock.sh`，仅在 `B1L $$` 匹配时删除）。

### 源码哈希 (sha256)
- 车道基线 commit: `f569285` ("post-T3-R3 main tree")
- `TerminalVTBackend.swift` 当前 (=基线): `8b0fb1eab0d07d54de62647deef628ed5d43581ce79f714e3dbc7b1faf05a70e`
- `TerminalVTBackend.swift` 候选 (lane 内): `db28a12adeccd7d4aa7849ac623f9b8f67abba3302560d4476bba8b7d762648d`
- 补充 wide 变体 (`build/TerminalVTBackend.wide.swift`，仅 `leadingIdle`=32 ms): `4f9194a4c0afaf5f9e47bb6d3546ef2c82c7a0e61db2c9804c2ada6a51bfe925`
- `scripts/terminal-vt-echo-latency.swift`: `fc3e5f1585ad7f0df30e06c920e80f4cba6b6984d89cdb1046908e139498327e`
- `scripts/terminal-vt-echo-fixture.c`: `171e28ecf9a533aabbb21884e71e56c7dd44dfcf91d4e0859218e526e383010a`
- `scripts/terminal-vt-echo-latency-build.sh`: `1c55b0e33d85e9ce0e90f33871226f6075ae3e561422ea06ebceb5db002588cde`
- `scripts/terminal-vt-backend-smoke.swift` (含新断言): `2e9dc336e08e4c5718f3c8a8437f0ba153a17ed6c34bc34b38acf58c825cc196`
- `candidate.diff`: `e0a8739bf7bb6887c5ab30faa70527d9f1de551712984752b0b0055182bc7acc`

### 原始数据
- `raw/r<R>-<arm>-<scenario>.json` (R=1..6, arm=cur|cand|wide, scenario=echo|burst|flood-yes|flood-sgr|idle)，共 90 个；echo/burst 含逐样本 `latency_raw_ms`、`gaps_ms`。
- `raw/rounds.log` (每轮顺序与开始/结束 loadavg)，`raw/bench.out`，`raw/machine-before.txt`，`raw/machine-after.txt`。
- `analysis.md` 为 `analyze.py` 的完整输出 (本报告表格取自其中)。
- 机器状态：Apple M4 (Mac16,12, 10 核)，AC 供电，电量 80% 未充电，lowpowermode 0；loadavg 前 2.76/3.14/3.28，后 4.25/4.43/3.91 (其他车道在同机；第 5 轮 wide 臂开始时曾出现 load 10.3，见风险)。

## 3. 数据表

### 3.1 回显延迟 (ms)，6 轮池化，n=1320/臂，超时 0

| 变体 | p50 | p90 | p99 | max | mean |
|---|---|---|---|---|---|
| current | 18.90 | 21.85 | 24.30 | 25.38 | 19.12 |
| candidate (16 ms) | 0.55 | 0.68 | 1.05 | 4.12 | 0.55 |
| wide (32 ms, 补充) | 0.58 | 0.71 | 19.66 | 43.74 | 1.19 |

逐轮 (p50 / p99 / max ms):

| 轮 | current | candidate | wide |
|---|---|---|---|
| 1 | 18.56 / 20.52 / 20.55 | 0.51 / 1.09 / 4.12 | 0.62 / 20.06 / 20.44 |
| 2 | 18.57 / 20.58 / 20.84 | 0.56 / 1.02 / 3.11 | 0.53 / 19.54 / 20.00 |
| 3 | 18.79 / 20.62 / 21.22 | 0.52 / 1.04 / 2.24 | 0.62 / 19.44 / 20.10 |
| 4 | 19.62 / 24.46 / 25.38 | 0.61 / 0.83 / 2.06 | 0.61 / 19.84 / 20.48 |
| 5 | 20.12 / 24.60 / 25.01 | 0.62 / 1.36 / 2.99 | 0.56 / 19.82 / 43.74 |
| 6 | 18.96 / 20.58 / 21.55 | 0.54 / 0.89 / 2.97 | 0.49 / 18.60 / 19.65 |

配对 (每轮 cand vs cur 的 p50 与 p99)：6 轮全部改善，0 轮变差。
按上一次回显后的空闲间隔分组 (合并): 间隔 <32 ms (n=60) current p50 18.71，candidate 0.58，wide 17.91；间隔 >=32 ms (n=1260) current 18.92，candidate 0.55，wide 0.57。wide 的 p99 由这 4.5% 的 20-32 ms 间隔样本产生；wide 的 max 43.74 出现在第 5 轮 (同时 loadavg 升到 10)，属于负载尖峰。

### 3.2 连击 (30 字 x 40 burst x 6 轮 = 7200 字符/臂)

全部字符延迟 (ms):

| 变体 | p50 | p90 | p99 | max | mean |
|---|---|---|---|---|---|
| current | 16.26 | 20.40 | 24.13 | 31.18 | 13.11 |
| candidate | 0.86 | 14.34 | 19.62 | 24.93 | 6.61 |
| wide | 11.08 | 19.86 | 20.50 | 39.01 | 12.42 |

首字符 (n=240): current p50 19.05 / p99 24.24；candidate 0.59 / 1.90；wide 0.57 / 1.41。
第 2-30 字符 (n=6960): current p50 11.72 / p90 20.34 / mean 12.90；candidate 9.36 / 14.38 / 6.82；wide 16.52 / 19.89 / 12.82。
每 burst 均值 (n=240): current 13.11 (p99 15.05)；candidate 6.61 (p99 7.87)；wide 12.42。
每 burst 最大 (n=240): current p50 20.49；candidate 18.53 (p99 24.16 vs 26.56)；wide 20.43。

每 30 字 burst 发布帧数：current 均值 15.00 (max 16)；candidate 16.10 (p50 16，max 19，仅第 5 轮出现 >16，均值 16.62，该轮机器负载升高)；wide 15.83。
逐轮 burst 均值延迟/帧数 (candidate vs current)：6/6 轮延迟改善 (6.5-6.9 vs 12.6-14.1)，帧数 +1 / burst。

### 3.3 持续输出 (5 s 窗口, 6 轮均值 +- 标准差)

**yes**

| 指标 | current | candidate | wide | cand vs cur 配对 |
|---|---|---|---|---|
| 帧/s (=快照/s) | 54.54 +- 2.27 | 62.16 +- 0.05 | 55.99 +- 0.72 | 6/6 更高 |
| 输出 MB/s | 82.25 +- 5.68 | 84.57 +- 1.19 | 85.22 +- 1.42 | (无优劣定义) |
| CPU % 单核 | 97.39 +- 3.95 | 99.36 +- 0.96 | 99.28 +- 1.35 | 3 改善 / 3 变差 |
| 每 MB 周期数 (x1e6) | 41.38 +- 1.53 | 40.45 +- 0.23 | 40.26 +- 0.27 | 4 改善 / 2 变差 |
| 每 GB CPU 秒 | 11.87 +- 0.39 | 11.75 +- 0.06 | 11.65 +- 0.07 | 3 改善 / 3 变差 |
| 中断唤醒/s | 68.83 +- 4.49 | 18.48 +- 0.54 | 70.21 +- 2.32 | 6 改善 / 0 变差 |

帧间隔：current min 16.11 / p50 17.74 / max 43.43；candidate 16.06 / 16.07 / 21.33；wide 16.10 / 17.55 / 28.13。

**sgr 混合**

| 指标 | current | candidate | wide | cand vs cur 配对 |
|---|---|---|---|---|
| 帧/s | 54.48 +- 1.98 | 61.93 +- 0.31 | 55.98 +- 0.75 | 6/6 更高 |
| 输出 MB/s | 124.09 +- 4.69 | 122.23 +- 3.35 | 124.83 +- 2.06 | (无优劣定义) |
| CPU % 单核 | 97.81 +- 2.04 | 97.88 +- 1.94 | 98.71 +- 1.05 | 3 改善 / 3 变差 |
| 每 MB 周期数 (x1e6) | 26.92 +- 1.02 | 26.85 +- 0.39 | 26.59 +- 0.38 | 2 改善 / 4 变差 |
| 每 GB CPU 秒 | 7.89 +- 0.14 | 8.01 +- 0.07 | 7.91 +- 0.05 | 2 改善 / 4 变差 |
| 中断唤醒/s | 68.76 +- 5.00 | 18.58 +- 1.45 | 72.40 +- 1.99 | 6 改善 / 0 变差 |

帧间隔：current min 16.11 / p50 18.05 / max 45.95；candidate 16.07 / 16.08 / 34.77；wide 16.11 / 17.45 / 32.34。

解读：持续输出下进程被 PTY 读线程占满约一个核，CPU % 两者都 ~98-99%，无法区分；每 GB CPU 差异 <1.5%，在标准差内，配对方向不一致。唯一稳定的差异是帧率 (+14%) 和唤醒 (-73%)。PTY 背压未变：输出吞吐无劣化 (yes 82.3 -> 84.6 MB/s，sgr 124.1 -> 122.2 MB/s，均在噪声内)。

### 3.4 20 s 空闲 (0 输出)，6 轮

| 变体 | 帧数(合计) | 快照数(合计) | CPU ms (均值) | 中断唤醒/s (均值) | 主动上下文切换 | cycles (x1e6) |
|---|---|---|---|---|---|---|
| current | 0 | 0 | 22.99 | 20.04 | 0.0 | 33.70 |
| candidate | 0 | 0 | 23.22 | 20.05 | 0.0 | 33.76 |
| wide | 0 | 0 | 22.09 | 20.05 | 0.0 | 35.27 |

无额外唤醒/帧；CPU 与唤醒配对为 3/3 与 4/2 的随机分布 (差值在噪声内；~20/s 的基线唤醒来自 harness 自身线程，三者相同)。

## 4. 候选实现 (candidate.diff)

`Web Studio/TerminalVTBackend.swift` (+24/-6) 与 `scripts/terminal-vt-backend-smoke.swift` (+56)。新增的测量文件 (`scripts/terminal-vt-echo-latency.swift`、`terminal-vt-echo-latency-build.sh`、`terminal-vt-echo-fixture.c`) 是未跟踪文件，其 diff 在 `measurement-files.diff`。

后端改动:
- 新增 `lastPublish` (仅在真正调用 `onFrame` 前更新)、`frameDeadline`、`frameInterval`=16 ms、`leadingIdle`=`frameInterval`。
- `consume()` 末尾 `scheduleFrame(leading: true)`；`scheduleFrame(leading:)`：不可见则直接返回 (隐藏路径不变)；若 `leading` 且距上次发布 >=16 ms (或从未发布) 则直接 `publishFrame()` 并返回 (这同时使按键路径此前预设的定时器失效)；否则走原有 16 ms 尾沿逻辑。
- 定时器回调改为 `frameTimerFired()`：仅当 `framePending` 且已到 `frameDeadline` 才发布，忽略被前沿发布抢先后残留 / 已重排的旧触发。
- 保持不变量：`publishFrame` 未改逻辑，仍走 skip-if-undrained/`publishDeferred`/`frameDrained()`；不可见不快照；`finish()` 仍 `publishFrame(force: true)`；任意两次发布的间隔 >=16 ms (定时器路径至少 16 ms 后触发；前沿路径要求距上次发布 >=16 ms)，实测最小帧间隔 16.06 ms；PTY 读取路径/背压未改；latest-wins 邮箱在消费者侧未改。
- 未改动：按键 (`encodeKey`/`sendRaw`/`sendTyped`)、滚动、选择、resize、主题、`setVisible(true)` 仍走 16 ms 尾沿 (例如无回显的输入、回滚到底部的帧仍等 16 ms)。

新增烟雾断言 (`LaneBSmoke`):
1. `leadingEdgeFrameDoesNotWaitForTimer`：空闲 100 ms 后 5 次探测，>=4 次「onFrame 时间 - 同一 PTY 块 onOutput 时间 < 8 ms」(尾沿路径此差值约 15 ms 以上)；>=4 次探测恰好只多一帧 (旧定时器不会重复发帧)；退出时 `finish()` 最后一帧含 `LAST_L`。
2. `sustainedOutputStaysRateLimited`：`yes` 泛洪 1 s，帧率 <=64/s，>=20 帧，最小间隔 >=15 ms。
3. 隐藏不快照：已有 `hiddenOutputTakesNoSnapshots` 在空闲 120 ms 后发输出，正是前沿路径会触发的场景，仍通过；`finish()` 最终帧：已有 `undrainedFrameDefersSnapshots` (FIN 帧) 通过。
- 红/绿验证：把新烟雾测试对**当前**后端编译运行 → 失败于 `leading: only 0/5 idle output frames were published without waiting for the trailing timer` (exit 133)；对候选 → 通过。

## 5. 车道门禁 (候选，持锁，退出码)

| 脚本 | 退出码 | 耗时 |
|---|---|---|
| `scripts/test-terminal-vt-backend.sh` 第 1 次 | 0 | 30 s |
| 第 2 次 | 0 | 28 s |
| 第 3 次 | 0 | 30 s |
| `scripts/test-terminal-vt-host.sh` | 0 | 12 s |
| `scripts/test-terminal-vt-visuals.sh` | 0 | 12 s |
| `scripts/test-terminal-pty-transport-swift.sh` | 0 | 7 s |

日志: `gates/*.log`、`gates/summary.txt`。

## 6. 风险

1. **帧率上限**：持续输出 62.1/s vs 现状 54.5/s (+14% 快照和主线程 `update(frame:)`/渲染次数)；超出任务写的「~60/s」。它仍等于 1000/16 的设计名义上限，且帧间隔从不 <16 ms。如需把持续输出保持在现状水平，wide (空闲阈值 32 ms) 给出 56.0/s，但空闲 20-32 ms 之后的回显回到 ~18 ms (本次数据 4.5% 样本)，且连击内均值只从 13.1 降到 12.4。
2. 下游成本未测：候选让主线程更频繁被 `Task { drainFrames }` 唤醒 (持续输出多约 7.6 帧/s)；本测试的消费者是专用线程，不含 MainActor 争用。
3. 连击中偶发多余一帧：按键路径的 `scheduleFrame()` 与回显到达的顺序若颠倒 (回显先到)，前沿发布后按键块再武装一个 16 ms 定时器，多出一个无变化帧 (burst 平均 +1.1 帧，负载高时最多 19 帧/burst)。
4. 前沿发布在 PTY 读回调线程内同步执行 `core.snapshot()` 和 `onFrame`，与原定时器路径工作量相同，但发生在读取路径内；持续输出下它只在静默 >=16 ms 后触发，故对吞吐无可测影响 (MB/s 在噪声内)。
5. 大块输出的第一段会先发布一帧不完整屏幕，16 ms 后再补一帧 (每次突发多一次快照)。
6. 实测在其他车道占机时进行 (loadavg 2-4，第 5/6 轮出现 8-10 的尖峰，已在每轮 JSON 记录 `load_before/after`)；候选 max 4.12 ms，current max 25.4 ms 均出现在同一批数据中。持续输出的 CPU 百分比受 PTY 读线程饱和限制，区分度低。
7. 新烟雾断言含 8 ms/15 ms 时间阈值，采用 >=4/5 容错；在重负载 CI 上仍有偶发失败可能 (本机 3 次门禁 + 若干次预跑均通过)。

## 7. 未测量 / 不能由本数据得出

- **不是 input-to-photon**：不含键盘事件 -> `keyDown` -> `encodeKey` 之前的延迟，不含主线程 `Task`/`drainFrames` 调度，不含 `TerminalVTView.update(frame:)`、Metal 提交、显示器刷新 (60/120 Hz 相位) 与合成器延迟。回显是 C 夹具在 raw 模式下的回显，不含真实 zsh/readline/ZLE 的回显时间与 shell 提示符重绘。
- 未测真实 GUI Session 的 MainActor 争用、多标签同时可见、电池/低电量模式、Retina 大窗口 (仅 80x24)、ssh 后端、IME 路径、鼠标/选择拖动 (这些仍是 16 ms 尾沿)、定时器 leeway 为 0/1 ms 的替代方案 (预计可去掉现状中约 2-3 ms 的 leeway 部分，**未测**)。
- 未测大屏 snapshot 成本随尺寸变化对前沿发布的影响。
- 未做 Instruments/能耗 (energy impact) 测量；仅有 getrusage、cycles 与中断唤醒计数。
- 统计功效：6 轮配对；CPU 类指标的方向在 3/3 或 4/2 之间，视为无差异；延迟与帧率/唤醒类差异 6/6 一致。
