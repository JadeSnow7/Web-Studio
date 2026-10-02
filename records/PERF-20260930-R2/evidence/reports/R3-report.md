# R3 增量字形图集 (incremental glyph atlas) 报告

Lane: `/private/tmp/ws-vt-perf/r2/R3/src` (基线 commit `0d8997c post-batch1 baseline`)。只改了两个文件:
`Web Studio/TerminalMetalRenderer.swift`、`scripts/terminal-metal-smoke.swift`。`patch.diff` 已用 `git archive HEAD` 解出的干净基线做 `git apply --check`: OK。

## 结论
- `render_churn/cpu_s` 0.311 s -> 0.083 s (ratio 0.267, 配对 6/6 improved, 噪声底线 max pair 0.255, verdict=improvement); excl. first frame 0.279 -> 0.058 (ratio 0.207, 6/6)。每帧约 0.8-1.1 ms(追加页) + 每 16 帧一次 4-5 ms(compaction); 基线每帧 ~4.3 ms。
- hot/blink 无回归: blink 0.960 (6/6), hot ASCII120 0.893 (5/6), SGR_MIXED 0.974 (5/6), CJK60 1.022 (2/6, 23 ms 级, 远小于噪声底线 0.54, 属噪声)。verdict 计数: improvement 4 / regression 0 / within_noise 36。
- 像素: bench `pixel_hashes_all_equal: true` (16 keys), `check_pixel_golden --bench` ALL EQUAL; font-equiv golden 9 张图 ALL EQUAL。
- 整数缩放(1x/2x/3x/4x)以及 1.25/1.5 的 sweep 中相对基线 0 帧差异(见"像素等价"一节, 这一项有重要保留意见)。

## 改动 (Web Studio/TerminalMetalRenderer.swift, 行号为改后)
1. L45-61 `GlyphRequest`/`RasterItem`/`RasterKey`: 请求元组别名; 光栅缓存 key 由 String 插值 `"\(fontName)|\(pointSize)|\(scale)|\(text)"` 改为 struct(fontName, size bits, scale bits, text), 无字符串插值。原因: 约束 4。key 不能用 renderer 局部 font id, 因为缓存是进程内共享的。
2. L63-131 `GlyphLRU<Key,Value>` (internal, 泛型): 数组+双向链表+字典, 命中刷新/插入/淘汰全部 O(1), 取代 FIFO + O(n) `rasterOrder.removeAll`。容量仍 1024。原因: 约束 4。设为 internal 以便 smoke 直接测试 LRU 语义。
3. L135-160 `PagePlan`/`ShelfCursor`: 与基线相同的 shelf packing 与 1-px 零 gutter 规则(原 `fits`/inline 逻辑合并为一个 `place`), 页边长为 2 的幂。
4. L163-340 `PreparedAtlas` 重写为 append-only: 不再 `init(requests)` 整页重建。`rasterize(_:reusing:)` 取/光栅化位图; `plan(_:)` 按小页分页(见阈值一节); `append(_:plan:)` 为每个新页分配一个 `PageSize^2` 的 `[UInt8]`、一个复用的 CGContext(每页一个, 而非每字形一个整页 context)、一个新纹理, 一次性 `replace` 后才发布; 已发布纹理永不再写。分配失败时不发布任何东西。`isIncremental` 标记该 atlas 是否追加过页。
5. L422-435 `GlyphRun` + `VertexScratch.glyphs: [Vertex]` / `runs`: 字形顶点改为单个 cell 顺序数组 + 同页连续 run 列表(原来是 `[[Vertex]]` 按页分组)。原因见"绘制顺序"。
6. L441-455 `atlas` 仍是 `didSet { lookup.resetASCII() }`: 追加页原地修改 atlas 对象(索引稳定, 不触发 didSet), 只有 compaction 替换对象才是新 generation 并重置 ASCII 表。新增常量 `maxAtlasPages=16`、`maxAtlasBytes=64 MiB`、`maxGlyphRuns=48`, 计数器 `atlasCompactions`。
7. render() L~535-555: miss 路径由 `atlas = try PreparedAtlas(...)` 改为 `extendAtlas(missing:all:)`; 追加后若 `isIncremental` 且帧的 run 数 > 48 则 `compactAtlas`。
8. L~766-800 绘制: 单顶点缓冲, `isIncremental` atlas 按 cell 顺序逐 run 绘制(`drawPrimitives(vertexStart:)` 切换纹理); 一次性构建的 atlas 多页时保持基线的"按页分组"顺序; 单页(热路径)一次 draw, 同以前。
9. L899-960 `extendAtlas`/`compactAtlas`/`glyphRunCount`/`missingGlyphRequests`: miss 帧只对缺失字形取位图+建页(`missingGlyphRequests` 不再像 `glyphRequests` 那样对整帧 Set 去重); 只有 compaction 时才惰性求整帧字形集。`prepareGlyphs` 公开 API 签名不变, 内部走同一 `extendAtlas`。
10. L947-960 `commandQueueForTesting`、`atlasDiagnostics`(internal): 仅供 smoke 用(在同一队列前塞 blocker 让帧保持 in-flight; 读取页纹理/字节数/compaction 次数)。不改公开 API。

未改: `inflightGate`(3 槽, 非阻塞), VertexRing 语义, `lastError`, 彩色字形路径(`textured==2`), shader, 绘制组顺序(背景 -> 光标下层 -> 字形 -> 装饰 -> overlay), render 路径无 `waitUntilCompleted`。

## 阈值及理由
- `maxAtlasPages = 16`: 限制每帧字形 draw 数与绑定状态; churn 中每 16 帧 compaction 一次, 摊销 ~0.28 ms/帧。
- `maxAtlasBytes = 64 MiB`: 4 张满 2048^2 页。稠密全屏 CJK 2x 约 2-3 页 + 一轮 miss 的余量。压力测试(2x, 每帧 1200 新字形)在第 5 帧触发 compaction, 峰值恰为 64 MiB。若一帧 compaction 后自身就超过上限(超大屏), 行为退化为基线(每个 miss 帧重建), 不会死循环。
- `maxGlyphRuns = 48`: 追加过页的 atlas 每帧最多 48 次字形 draw(约 50-100 us 上限); 超过则 compaction 回一页, 这也是保证"cell 顺序绘制"的成本上界。churn 场景下 16 页 -> 约 33 run, 页数上限先触发。
- 页尺寸: 2 的幂, 最小 64, 最大 2048; 每页取"能放下本次 miss 的最小尺寸, 且 packed 高度 <= `packedHeightBudget`=256 行", 否则升级(最大页取能放下的部分)。8 个新字形在 1x 得到 128^2(64 KiB)页。

## 像素等价 — 重要发现与保留意见
- 追加页 + 按页 UV(x/pageSize)本身没有问题; 但发现两个会改变输出的因素, 都已处理:
  1. **绘制顺序**: 相邻 cell 的字形 quad 会在 padding 处重叠, 按"页顺序"绘制与基线的"cell 顺序"混合次序不同, 可能差 1/255。所以追加过页的 atlas 改为 cell 顺序逐 run 绘制(见改动 8)。
  2. **1x 下的纵向双线性 tie**: 1x 时字形 quad 的 y 小数部分恰为 221/512(`bearing.y = -(ascent+2)` 的小数), 采样权重恰好落在 17.5/256 的舍入 tie 上, 最终 bit 由 float 噪声决定, 而噪声取决于所采样纹理行(y 坐标)的量级。我在基线自身上验证: 仅把基线图集起始 Y 由 1 改为 300, 1x 的 122/122 帧就出现 ±1/255 差异(起始 Y=200 则 0 差异); 2x 权重 163/256 精确, 不存在 tie。所以**在 1x 下, 任何改变图集纹理行布局的实现都不能被证明与基线逐字节相同**, 只能经验上相同。我用 `packedHeightBudget=256`(让新页里字形行号保持在基线单页的量级)实测: 没有此规则时(最小页 512)在 1x churn 出现 12/244 帧 7 个像素 ±1 的差异; 加上后 0 差异。
- 我做的额外对照(scratch, 在 `/private/tmp/ws-vt-perf/r2/R3/equiv/`, 不在交付补丁中): 相对 `post-batch1-src` 逐帧 SHA-256 —
  - churn 60 帧 x 2 变体(彩色/粗斜体/emoji) x 缩放 1,2: 244 帧, 0 差异; 缩放 1.5,1.25,3: 366 帧, 0 差异。
  - 伪随机 sweep(3 种字形池 20/150/600, 亮暗主题, 粗斜体, 每帧新 core) x 缩放 1,2: 520 帧, 0 差异; 缩放 3,4: 520 帧, 0 差异。
  - 基线自身 `--reversed request order` 重跑: 0 差异; 基线自身重复运行确定。
- 结论: 已通过所有既定 gate 与上述扫描, 但**1x 的逐字节一致是经验性的, 不是结构性保证**。若 owner 要求结构性保证, 只有"所有页都用基线布局(2048 页 + 相同请求顺序)"才能做到, 那会丢掉小页收益(每次追加 16 MiB 分配), 所以我没有这样做; 请 owner 裁定。这一点是对 brief 约束 5 的偏离风险, 已如实标出。

## Gates (命令 + 退出码; 全部在 lane 最终代码上; TMPDIR=/private/tmp/ws-vt-perf/tmp)
| 命令 | 退出码 |
|---|---|
| `sh src/scripts/test-terminal-metal.sh` (含 1200+1200 压力、光标像素、及新增断言, 日志 `gate-metal.log`) | 0 |
| `sh src/scripts/test-terminal-vt-host.sh` (`gate-host.log`, 0 warning) | 0 |
| `sh src/scripts/test-terminal-vt-visuals.sh` (`gate-visuals.log`) | 0 |
| `sh src/scripts/test-terminal-font-frame-equivalence.sh --source-root .../src --output .../font-equiv-1` | 0 |
| `python3 /private/tmp/ws-vt-perf/tools/check_pixel_golden.py --font-equiv .../font-equiv-1` | 0, ALL EQUAL (9 images) |
| `run_bench.sh 2` = `test-terminal-render-bench.sh --source-root .../post-batch1-src --compare-root .../R3/src --output .../bench-2 --noise-floor /private/tmp/ws-vt-perf/r2/noise/noise-floor.json` | 0 |
| `check_pixel_golden.py --bench .../bench-2` | 0, ALL EQUAL |

新增 headless 断言(`scripts/terminal-metal-smoke.swift`, 均在 test-terminal-metal.sh 内; `SMOKE_ONLY=ascii,runcap,churn,inflight,bytecap` 可单独运行):
- `runGlyphLRUCheck`: LRU 淘汰最久未用、更新不增长、2 万次 churn 容量有界。
- `runLongChurn` (1x/2x, 各 72 帧, 每帧新字形): 页数 <= 16(硬编码上限, 同时校验渲染器常量)、字节 <= 64 MiB、compaction >= 3(实测 4)、最多页数 >= 8(实测 16); 同一 generation 内旧页 texture 对象不变且字节 SHA-256 不变; compaction 后无旧页复用; 每帧与全新 renderer 的串行参考**逐字节相同**。
- `runASCIITableInvalidation`: 字母表升序建 ASCII 表, 之后每帧降序 + 新字形直到 compaction; compaction 帧及之后纯 ASCII 帧与参考逐字节相同。
- `runRunCapCompaction`: ASCII(page 0)与新 CJK(追加页)交替的帧触发 compaction, 页数回到 1。
- `runInFlightOverlap` (1x/2x): 在 renderer 自己的队列前塞一个等待 `MTLSharedEvent` 的 blocker, 让 3 帧真正 in-flight(24/24 轮确认三帧均未完成, 第 4 帧被 gate 拒绝且不改 atlas), 期间追加页并在 in-flight 时发生 compaction(8 次); 放行后 72 帧对比串行参考: 0 mismatch。
- `runByteCapPressure`: 2x 6 帧各 1200 新字形, 字节峰值 64 MiB, compaction >= 1, 之后的帧与参考逐字节相同。

## 变异检查 (在 `mut/<name>/` 的拷贝里改代码, lane 源码未被改动; 汇总 `mut/summary.txt`, 各日志 `mut/*.log`, 运行器 `mut/run_mut.py`)
| 变异 | 单独运行的检查 | 结果 |
|---|---|---|
| M1a 每次追加把旧页 0 清零(`replace`) | churn | 失败 Code 82 (帧与参考不同) |
| M1b 同上 | inflight | 失败 Code 112 (69/72 帧不同) |
| M1c 追加时只改旧页一个不被采样的 texel | churn | 失败 Code 86 "page 0 was modified after creation" (不依赖像素) |
| M1d 追加时替换旧页 texture 对象 | churn | 失败 Code 82 |
| M2a 去掉页/字节/run 上限 | churn | 失败 Code 83 "17 pages" |
| M2b 只去掉页上限 | churn | 失败 Code 83 |
| M2c 只去掉字节上限 | bytecap | 失败 Code 122 "83886080 bytes, 5 pages" |
| M3 去掉 `didSet` 里的 `resetASCII()` | ascii | 失败 Code 92 (compaction 帧 "reversed 15" 与参考不同) |
| M4 关掉 run 上限 | runcap | 失败 Code 103 "fragmented frame did not compact" |
| M5 LRU 命中不刷新 | 全量 | 失败 Code 71 |
全部退出码 133(Swift 顶层错误), 均为被断言拦截。

## Bench 表 (bench-2, 6 对交替, Release; control=post-batch1-src, candidate=lane)
| 指标(cpu_s 中位数) | control | candidate | ratio | 配对 improved | 噪声底线 max pair | verdict |
|---|---|---|---|---|---|---|
| render_churn | 0.3113 | 0.0831 | 0.267 | 6/6 | 0.255 | improvement |
| render_churn excl first frame | 0.2788 | 0.0576 | 0.207 | 6/6 | 0.276 | improvement |
| render_blink_100 | 0.0235 | 0.0225 | 0.960 | 6/6 | 0.637 | within noise |
| render_hot_100/ASCII120 | 0.0334 | 0.0298 | 0.893 | 5/6 | 0.346 | within noise |
| render_hot_100/CJK60 | 0.0231 | 0.0236 | 1.022 | 2/6 | 0.537 | within noise |
| render_hot_100/SGR_MIXED | 0.0486 | 0.0474 | 0.974 | 5/6 | 0.476 | within noise |
| render_cold_first ASCII120 / CJK60 / SGR_MIXED | 0.0106/0.0094/0.0224 | 0.0065/0.0057/0.0227 | 0.62/0.61/1.01 | 6/6, 6/6, 4/6 | 0.24/0.49/0.43 | improvement / within / within |
`pixel_hashes_all_equal: true`。第一次运行 `bench-1`(同代码, 早于最后一次 warning 清理)结果一致(churn 0.326 -> 0.0885, ratio 0.271, 6/6), 但**可能被 T4 的计时运行污染**(锁曾被别人 rmdir), 仅供参考; 判断以 bench-2 为准。bench-2 使用 PID 所有权的锁(`run_bench.sh` 写 `owner`, 释放前核对 PID), 起止 loadavg 分别为 3.49 / 3.57(`bench-2.loadavg-*.txt`; 负载来自其他 agent 的非计时工作, 不能排除对绝对值的影响, 配对交替限制偏差)。`resize_seq/*` 在 bench-1 里报过 regression(ratio 1.045), 它只跑 core 不碰渲染器, 在 bench-2 里没有出现(regression 0), 属噪声。协调者将在合并后重跑权威 bench。

## 未验证项 / 剩余风险
- 1x 逐字节一致是经验性的(见上); 不同字体/字号(ascent 小数不同)下 tie 位置会变, 我只测了默认 13 pt monospaced system font。
- 没有 GUI/xcodebuild test/UI test, 没有在真实 app 中观察; 没有测多显示器缩放切换(scale 变化时旧 scale 的字形留在 atlas 直到 compaction, 由字节/页上限约束; 只在 sweep 中间接覆盖 1/2/3/4/1.25/1.5 分别的独立 renderer)。
- 追加页同一 atlas 上的 `groupByPage` 分支(一次性构建的多页 atlas 按页分组绘制)只在 2x 1200 字形压力中间接走到; 没有单独断言它与基线的 draw 顺序逐字节相同。
- `maxAtlasBytes` 是 CPU 侧统计的页字节数, 非驱动实际显存。
- 光栅缓存容量仍 1024, 一帧 >1024 个不同字形时 compaction 需要重新光栅化(与基线相同)。
- 页尺寸最小 64 x 64, 每次追加约 64 KiB - 1 MiB 的纹理分配, 未做池化。
- smoke 全量约 17-20 s。

## 与 brief 的偏离
- 增加了 cell 顺序逐 run 绘制及 `maxGlyphRuns` compaction(brief 未提及, 为保证与基线的混合顺序一致)。绘制"组"顺序未变。
- 增加了 internal 诊断/测试入口 `commandQueueForTesting`、`atlasDiagnostics`、`atlasCompactions`、`GlyphLRU`(非 private)。
- 页高度预算 256(brief 未提及, 用于 1x tie 稳定性, 见上)。
- 1x 逐字节一致无法结构性保证(见上), 已如实报告而非放宽标准或回退, 请裁定。
