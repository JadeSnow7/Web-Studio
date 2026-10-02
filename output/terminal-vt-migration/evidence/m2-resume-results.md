# M2 恢复实测结果

状态：进行中，M2 整体验收未判定。当前HEAD为ced7edc，App源码与2631e14相同；生产默认旧后端，本轮不提交推送。

## 2026-09-16 新增人工回执与现场复验

扩展 IME 已由用户确认完成；VoiceOver 终端普通文本朗读已由用户确认正常，字幕文字据用户报告为 `ASCII abc XYZ 0123`。这两项不再重复询问。当前证据目录没有找到对应 VoiceOver 原始字幕截图，本轮消息未附图片；回执明确区分用户确认、用户报告的截图内容、AX 可访问文本与自动接口测试。语音输入另列未判定，疑似网络问题尚无根因证据。

当前 GUI 是旧 Debug PID 21524，哈希与此前记录一致；冻结 Debug / 新旧 Release 五个二进制文件均匹配旧记录，没有把新构建通过迁移为其 GUI 通过。HEAD 和 origin/main 现场核对均为 `ced7edc25bd6ab6434712ce4da0b4bd16afad499`，本轮不提交推送。

精确 900×560 工具栏下方内容区已补亮色双栏、亮色单栏、深色单栏选区/光标 PNG。独立 AX/CG 实测外框900×600、toolbar40、内容split group高560；横向674点终端布局加左侧226点。截图是工具传输尺寸，不当作原生2×像素采集。实际显示2×；其他实际缩放未判定。外观已恢复原“自动”，见 AX 回执。

资源隐藏/恢复后 PID22208 与历史保持；⌘L、⌘K、Escape、点击返回后收到 `VO_INPUT=[FOCUS_RETURN_0123]`，这是普通键盘/焦点实测，不替代 VoiceOver 导航。专属关闭资源 PID4959、5418、5419、5420 在取消后存活，确认后只读检查均不存在；无关终端 PID22208、81191 存活。此为关闭后轮询结果，不声称测量即时回收延迟。

原始证据：`evidence/m2-followup-*`；逐项结果见 [恢复实测结果](evidence/m2-resume-results.md)。剩余 VoiceOver 导航、返回输入与选区朗读已准备持续读取程序等待用户回执，输入不会作为命令执行。性能实际字体/格距对齐仍进行中，预算未提出，整体 M2 未判定。

以下为上轮恢复检查点的历史记录，不覆盖上面的新增回执。

## 窗口现场

目标 Debug App PID 21524，shell PID 22208；路径 `/private/tmp/web-studio-m2-20260916/Build/Products/Debug/Web Studio VT.app`。实际二进制 SHA256：主 executable `22dcef89c15360bb3a0c0ad5212ac3e853dcbb6ec77688c711240b5aa1cbf9fe`，debug dylib `e11c66bfa754c5628cc0c1b55502d478987ee9a0c61a3e412b64261896c89324`。

AX 与 CGWindow 独立观测外框 900×600 点、AXToolbar 900×40 点，内容布局的 AXSplitGroup 高560点、宽674点（左侧导航占余宽226点）；两者同一上/下边界支持工具栏下方内容区域900×560。这是实际布局几何证据，未直接读取进程内 NSWindow.contentView。原始记录 `m2-exact-split-geometry.json`。

显示：backing scale 2；逻辑1470×956，当前显示模式渲染像素2940×1912。1×实际显示仍未判定。CUA窗口截图为传输图像，转换PNG只改变编码，不作原生2×像素证明。

初始亮/暗单栏截图 `m2-minimum-{light,dark}-selection.png` 是900×602外框/562高内容的过渡现场，不冒充精确尺寸。AX读出选区 `Unicode 中文 é 😀`，切暗后保持；之后已微调外框到600高。

右栏 shell PID 81191，终端实测30×35；已准备 SPLIT_IME 读取程序。用户人工确认与VoiceOver听读待回执，AX文本不替代实际朗读。

## 版本绑定与回归

本节由后续执行回执更新。冻结检查前不把探索记录写作最终门禁通过。

## 性能

旧探索数据继续不用于验收；规范化基线与用户确认预算尚未完成。

### 第一次冻结回归的有效性问题

`m2-frozen-regression.json` 中全部子命令退出0：9项采样工具测试、几何自测/JSON、VT host、Metal、C/Swift PTY、backend和ASan均成功。但脚本导入生成 `scripts/__pycache__/terminal-benchmark.cpython-314.pyc`，revision前后变化，记录结果为 `revision_changed`，不算最终有效回归。将清理本次生成物后用PYTHONDONTWRITEBYTECODE=1重跑。NSLock异步上下文警告继续存在，未声称严格Swift6模式通过。

## 本轮验收矩阵

| 用例 | 判定 | 证据类别与范围 |
|---|---|---|
| 工具栏下方900×560内容区域、2×显示 | passed | 外部AX/CG实际几何；非截图像素推断；未直接读取NSWindow.contentView |
| 900×560深色双栏ASCII/Unicode/组合字符/Emoji、光标 | passed | 主线程查看真实截图，AX读取两栏文本；见m2-exact-dark-split.png |
| 单栏跨亮暗选区保持 | passed（562高过渡窗口） | 真实图像与AX选区文本；不算精确560高单栏 |
| 精确560高亮色/单栏、扩展IME | undetermined | 深色双栏读取程序已就绪，人工回执未收到 |
| VoiceOver实际朗读/导航 | undetermined | 未收到听读回执，AX文本不替代 |
| 资源隐藏恢复、取消关闭/确认、进程回收 | 本轮未运行 | 等当前人工现场结束后执行；保留历史通过边界 |
| Debug及新旧Release冻结构建 | passed | m2-frozen-*-build*-v2.json，重建目录独立于当前GUI App |
| 规范化性能与预算 | undetermined | 字体/单元格尚未对齐，没有有效基线；未提出无依据的预算 |

### 性能准备与trace可用性

主线程核对候选夹具与VT源码颜色及字距计算公式一致。`performance-normalization/vt-font-metrics-2x.json` 是coder的AppKit/CoreText测量输出，主线程未将其当作Ghostty实际字体证明。VT系统字体family为`.AppleSystemUIFontMonospaced`，13pt；2×格距17×35px。该family不在公开字体列表中，Ghostty是否接受/回退未验证。候选conf仅放在证据目录，未安装到生产配置或App。

`m2-resume-trace-capabilities.json`确认宿主xctrace提供Metal System Trace、Animation Hitches、System Trace等模板。沙箱首次调用因Instruments缓存权限失败；宿主重试仅证明模板可用。本轮没有产生可用的新GPU/帧时间/输入延迟trace测量，全部保留未判定。旧CPU/RSS数字不升级为验收结论。

### 现场保留与下一依赖

用户协助请求已发出：深色双栏右侧SPLIT_IME>输入中文、候选位置、组合中⌘L再回终端、Escape取消，并可用VoiceOver读输出/选区。只读检查显示仍在等输入，无人工回执。保持该窗口不动，以免破坏组合输入现场。系统外观原为“自动”，当前为本次验收切换的“深色”；人工现场完成后恢复“自动”。

后续顺序：收人工回执→精确尺寸亮色/单栏补图→资源生命周期→隔离legacy字体与实际surface度量对齐→规范化重复采样/trace→基于有效基线提出预算待确认。新构建的哈希见m2-frozen-binaries.json；当前GUI仍是旧目录Debug PID21524，不把构建通过写为新二进制GUI验收。

### 本轮待提交范围

- `Vendor/GhosttyVT/README.md` 与 `output/terminal-vt-migration/` 的状态、验收、回执、截图、工具/性能证据和handoffs。
- 既有未提交采样工具 `scripts/terminal-benchmark.py`、`scripts/test-terminal-benchmark.py`。
- 新增只读几何工具 `scripts/terminal-window-probe.swift`、`scripts/test-terminal-window-probe.sh`。

App源码、生产默认与旧依赖未改动；未执行commit/push/merge/deploy。快照2631e14后的原有未提交内容已保留。临时构建位于/private/tmp，不属于待提交范围。几何工具首轮崩溃的空输出/错误回执、首次revision_changed回归及被清理生成物影响的第一轮构建均保留为历史，不当当前门禁。

### 有效冻结回归结果

`m2-frozen-regression-v2.json`及三份`m2-frozen-*-build*-v2.json`全部passed，前后token一致：`patch:2631e149787c6cfd8d9b0903c89995e8cde96083:80ff04c868f1a2713ea79cb958beef06f9633e671efe7afb9978fc2da6901c54`。采样工具9项、几何有限值/JSON、host、Metal(1200+1200字形/光标像素)、C/Swift PTY、backend交互与ASan均通过。主线程读取原始stdout/stderr，NSLock异步上下文警告仍存在；构建CoreSimulator版本警告不影响本次macOS BUILD SUCCEEDED。

## 当前轮收尾（以此表覆盖历史待回执）

| 范围 | 判定 | 证据 |
|---|---|---|
| 扩展IME、普通VoiceOver朗读 | 人工passed | m2-followup-user-receipts.json；原字幕图缺失不伪造 |
| 精确尺寸亮暗单栏/亮色双栏、选区光标、外观恢复 | passed | m2-followup-gui-results.json |
| 普通焦点往返、隐藏恢复、关闭取消/确认及进程对照 | passed | m2-followup-gui-results.json |
| VO剩余导航/选区，语音输入 | undetermined | 安全现场保留；语音网络根因未验证 |
| 实际字体、格距、网格对齐 | passed | m2-followup-font-grid-main.json |
| 性能与预算 | 整体undetermined | performance-normalized-20260916/RESULTS.md；候选预算待确认 |
| 新工具受影响回归 | passed | m2-followup-probe-tests.json，token前后一致 |

待提交：六个scripts/terminal-performance-probe*及output/terminal-vt-migration下本轮变更；本轮无commit/push。最终现场/清理见m2-followup-final-*。
