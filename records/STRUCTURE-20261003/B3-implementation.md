# B3 状态收敛实施与复验

基线提交：`0e134dec96136133e78d4268c24d9233d2aa7679`。本阶段仅修改 AgentController.swift，测试保持前置提交的全部断言与字节内容。

questions[id] 是问题内容的唯一来源，latestRunID 归入 AgentQuestion，当前字段为计算投影；删除 persist/load 和镜像字段。question 的 setter 关闭后拒绝直接写入，newChat 直接重建空字典且保持关闭，因此 shutdownAndWait 后清空仍有效。资源变化和重读显式取消确认；send 先冻结请求和用户消息再清空草稿。保留 ObservableObject，字典、当前 ID 与单一读取表的 Published 写回提供观察通知。

每问题读取表保留 generation 与 task，取消任务进入 retiredTasks 等待退出；后台结果仍受关闭、取消与代际检查约束。send/retry 共用请求执行闭包，retry 保留原请求快照和当前草稿；取消后请求槽仍等到底层任务退出才释放。主线程已审查实际 diff、原始日志与冻结测试哈希。

## 同基准复验

- 关闭编辑测试：前置旧实现 exit 65，1 方法的 2 个参数运行失败；本实现相同命令（仅结果包路径不同）exit 0，1 方法的 2 个参数运行全部通过。旧失败输出不覆盖。
- ./scripts/check.sh：exit 0；build 0、unit 0；291 passed、0 failed、0 skipped，27 suites。原有 283 项保留，新增 8 个方法（7 个特征测试加 1 个关闭编辑测试）。
- 测试源码哈希全部保持；仅本源码格式化，两遍字节相同；git diff --check 为 0。
- UI 未运行；此结果是单元回归和源码审查证据，不表示完整产品验收。B4 尚未包含于本提交；没有推送或开 PR。

## 原始证据

目录：`/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/b3-implementation`。包含前后源码、命令、focused 原始日志与 xcresult、完整 check 日志、哈希和主线程复核。

| 文件 | SHA-256 |
| --- | --- |
| `shutdown-edit-green.log` | `877ea5ba04c12f18c1a17a8077faf815835d61aca2d3d6e5f1f26856e570d070` |
| `shutdown-edit-green.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `check.log` | `7feef906c3e097e543163881fcfa94dbb0b640c742a0c71cad1570abcb3c6ea2` |
| `check.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `tests-after.sha256.json` | `8a25e19daa8adbb016af80b8eb74554033e621ca6c85d0e1199ae8a0d12cad40` |
| `primary-review.json` | `a9ed83332485cdf8419f46891da0ed8f64ec9f3d06c6ea09e23f5c9e97dfc424` |
