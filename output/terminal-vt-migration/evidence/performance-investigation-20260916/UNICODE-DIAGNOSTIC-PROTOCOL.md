# VT离屏Unicode成本诊断

四种44行CRLF负载，134×45网格：ASCII A×120；中×60；中×40；U+4E00起40个不同CJK。前两者占用cells相等但字节不同；ASCII120与CJK40字节相等但cells不同；两种CJK40字节/cells相等但字形多样性不同。固定2×、dark、13pt、同traits。

每负载6轮，正反顺序交替，每轮fresh core和renderer。CPU=getrusage当前harness进程user+system差值，wall=单调时钟，分别feed+snapshot、首个renderer-atlas-cold提交、100个sameframe warm提交。每次Metal command完成检查；wait wall不是GPU execution或presentation时间。fresh renderer不等于全系统字体缓存冷启动。

输入hash、实际snapshot文字/cell宽度/uniquecluster、CoreText同cluster/ligature0 glyph runs和字体名必须记录。字体run仅为当前VT路径单元旁证，不证明legacy fallback相同。此项是成本拆解工具，不改renderer，不是第二个优化实验。
