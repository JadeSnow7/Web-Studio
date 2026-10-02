# VT离屏Unicode成本拆解

Release swiftc -O/clang -O2，真实134×45 snapshot、2× dark、13pt，四负载各6轮，正反顺序交替。每轮fresh core和renderer，首帧后连续100次同frame提交并逐次等待command完成。主线程独立绑定v3执行通过，逐行内容、占用cell、输入hash、glyph非零及font run均复核。

|负载|bytes|占用cells / 非空head|unique cluster|feed+snapshot CPU ms|首帧atlas冷 CPU ms [范围]|100次热提交CPU秒 [范围]|
|---|---:|---|---:|---:|---|---|
|ASCII120|5368|5280 / 5280|1|0.242|25.071 [24.144, 29.808]|1.928825 [1.899315, 1.975945]|
|CJK60|8008|5280 / 2640|1|0.260|20.908 [20.103, 24.926]|1.562835 [1.554484, 1.585732]|
|CJK40|5368|3520 / 1760|1|0.250|18.446 [18.114, 19.611]|1.374676 [1.368624, 1.386817]|
|CJK40distinct|5368|3520 / 1760|40|0.245|19.688 [18.211, 37.231]|1.396290 [1.389265, 1.409033]|

## 事实与推断

ASCII120/CJK60占用cells同为5280，但非空head分别5280/2640，bytes不同。100次热提交CPU中位1.928825/1.562835秒：该匹配cell诊断没有出现CJK更慢。它不控制非空head数，也不是等字节实验。

ASCII120/CJK40 bytes同为5368，但占用cells5280/3520、head5280/1760；CPU差异不能单独归于编码或shaping。feed+snapshot均约0.24–0.26ms，量级很小，不能从微小差值提出解析器优化。

CJK40重复/不同字形同bytes/cells/head，uniquecluster为1/40。热100提交中位1.374676/1.396290秒（约1.6%差异）；首帧中位18.446/19.688ms，但40字形首两轮为37.231/34.184ms，后续18.211–20.673ms。所有重复值保留：fresh renderer只保证atlas冷，不保证进程/系统字体或驱动缓存冷，不能把首两轮差异推广为稳定收益。

CoreText逐snapshot cluster、同renderer .ligature=0获取实际runs：ASCII为.AppleSystemUIFontMonospaced-Regular，三种CJK均.PingFangUITextSC-Regular；全部glyph ID非0。只证明本VT单元输入路径的字体run，不证明旧后端fallback/连字一致。

推断：字形数量、宽字符head/tail处理与帧重复次数是必须控制的变量。结合两次App字体调用栈及单因素缓存实验，重复系统字体获取是可信通用成本；初始Unicode相对差距不能缩成“Unicode慢”或atlas唯一根因。

## 限制与证据

这是VT-only离屏diagnostic，非新旧App基线。CPU为harness整个进程getrusage，wall为DispatchTime，包含driver/等待但不等于GPU执行/屏幕帧时间。无PTY、AX、实际presentation；固定100次提交的工作量与App的合并刷新不同。freshrenderer不代表系统cold cache；无独立frame阶段计数、总分配生命周期或GPU利用率。

逐轮CPU/wall/hash/cells与font runs见unicode-diagnostic-results.json，汇总unicode-diagnostic-summary.json，build-manifest和v3绑定执行保留。v1编译失败、v2 CRLF预期构造失败均保留，修复均限于新工具。未修改生产renderer，也未新增第二个优化实验。
