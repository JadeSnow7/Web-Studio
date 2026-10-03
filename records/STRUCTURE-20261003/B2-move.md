# B2 StudioModel 纯移动结果

本次仅移动完整声明块，生产函数体没有修改，访问级别变更为 0 项。

基线提交：`650689823f79274c1e0928ed82c53874dae47e79`。本说明与对应源码移动同一提交，提交哈希由 Git 记录确定。

| 文件 | 内容 |
| --- | --- |
| `Web Studio/StudioModel.swift` | StudioModel 完整类；新增 AppKit、Combine、Darwin、Foundation imports |
| `Web Studio/StudioModels.swift` | StudioDestination、StudioGroup、StudioTab、StudioCommandAction、WorkspaceResourceSearchResult、StudioCommand、StudioLayoutPlan；新增 Foundation import |
| `Web Studio/ContentView.swift` | 保留视图及 FocusedValues 声明，其余正文逐字节不变 |

没有拆分类内 extension，因此无须放宽 private；访问级别变更清单为空。文件系统同步分组已纳入新文件，`project.pbxproj` 未修改。

## 验证

| 命令或核验 | 退出码 | 结果 |
| --- | --- | --- |
| 初版与最终版 `./scripts/check.sh` | 各 0 | 每次 build 0，unit 0；27 suites、283/283，失败 0、跳过 0 |
| 全行排序比较（包括空行） | 0 | 原文与三个新文件合计的差异仅为新增 import 文件头及两个头部分隔空行；移除这些文件头后完全一致 |
| 主线程正文重建核查 | 0 | 类和类型正文逐字节相同；两个块尾分隔空行移回 ContentView 的移除块边界，正文未变 |
| 三文件分别 `git diff --check HEAD -- <path>` | 各 0 | 覆盖已跟踪文件及已暂存的新文件 |
| 全文件 `git diff --no-index --check /dev/null <path>` | 各 1 | 与空文件存在差异；空白诊断为 0 |
| UI | 未运行 | 无新增 UI 验收结论 |

初版暂存检查 exit 2，发现两个新文件 EOF 各有一个空行；普通未暂存 diff 未覆盖新文件。已仅把这两个分隔空行移回 ContentView 边界，保留初版结果并复跑比较和测试。最终记录在 `final/`，不覆盖初版。

相对 B1 与原基线，单元测试通过数均不变。未放宽、删除或跳过断言。B3 指定五类特征测试已随本次 283 项测试通过，覆盖对应关系见后续待确认设计。

## 本地原始证据

目录：`/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/b2/`。以下摘要绑定本机证据文件；原始文件未纳入 Git。

| 文件 | SHA-256 |
| --- | --- |
| `check.log` | `cdab7797fe6664d24fa85df1340c8fe1a7a5e1175ca86638396575303ec4015f` |
| `initial-staged-check.log` | `c93784a091a739e51418c28ec8a44f359465d30289930f2b12193cee0aeab0c2` |
| `initial-staged-check.exit` | `53c234e5e8472b6ac51c1ae1cab3fe06fad053beb8ebfd8977b010655bfdd3c3` |
| `final/check.log` | `a4776fdf57f8ada0ea411f5d5311c827f6b658a48da1a4a081241c6f3601c076` |
| `final/check.exit` | `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa` |
| `final/move-result.json` | `a71197fbe32b32e3f6785f386458f0f37bb9731a50c3e73e0d4bde62ad5964f6` |
| `final/primary-move-review.json` | `0547d03ff55d0675cc92631f797c6b7479cc7025bd9b67d83e2d13cd96d485a0` |
| `ContentView.before.swift` | `f680db57b4a2aaef66b08062533aabe1c21f8f7a7b1115be81dcf1f1b2d0c092` |
| `final/all-lines-before.sorted.txt` | `1b25c18a52971589910348ab7561e0f1e4f381e09c4420584fce3a9c91ab1d27` |
| `final/all-lines-after.sorted.txt` | `d9bf9d189233feee325e87dc010febcd76ecaf3172c82720765b06631b98d32b` |
| `final/all-lines-after-without-new-headers.sorted.txt` | `1b25c18a52971589910348ab7561e0f1e4f381e09c4420584fce3a9c91ab1d27` |
