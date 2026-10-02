# P0 首轮主线程浏览器审查

2026-09-17，CUA Codex in-app browser，本任务独立 tab，http://127.0.0.1:8791/。此记录保留首轮缺陷，不支持后续版本通过。

1. 先在默认宽度载入原型。点击「＋空间」，将临时空间命名为「测试空间 A」，确认，再点击「归档空间」。实际：侧栏不再有 A，顶部切换器、内容标题和可操作按钮仍指向 A，状态显示「已归档·可恢复」。没有归档恢复入口。判定 failed，已交 coder 修复。
2. 设置 viewport 900×560。首版 AI 输入框及切换入口消失。coder 增加顶部「AI 面板」后重新 reload，点击该按钮。实际：出现「已切换 AI 面板」toast，但 .inspector.isVisible() 返回 false，AX 无输入框/发送按钮。判定 failed。原始截图与 AX 见 p0-review-narrow-before.png、p0-review-narrow-before.ax.txt。
3. 静态审查发现单个问题对象、全局 paneFocus、关闭/归档和模拟恢复语义不完整，以及常驻 overview/pane 标题偏离产品合同。coder 接到有界修复任务；尚未宣称 P0 通过。

MCP Playwright 因共享 browser profile 正在使用而无法启动；未结束他人浏览器，改用 CUA 独立 tab。localhost server 在沙箱内 bind 被拒，随后通过工具审批在 127.0.0.1:8791 启动。未访问外部网页、SSH、Provider 或用户真实空间配置。
