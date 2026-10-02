# 静态UI审计解释

report模式命令退出0，但结果列出22条affordance.actionless-button，不代表UI审计零问题。检查器未识别本原型外置app.js中的动态事件绑定。index第14/15/17行由workspaceMenu/saveSpace/layoutBtn/aiToggle/simulateSaveFailure/restartBtn绑定；第21行由newSpace/addWeb/addTerminal/addSSH绑定；第22/23行由archiveBtn/closeBtn/closeWindowBtn和data-mode委托绑定。app.js第20–22行模板按钮由renderWorkspace/pane/sourceCard后的data-*绑定。主线程已实际走通对应核心入口，原始DOM/截图支持主要可达性。

此处保留审计原始发现并手工解释，不把report退出0冒充严格审计通过。所有功能仍为离线模拟，剩余原型简化见P0-FLOWS；原生UI须另验。
