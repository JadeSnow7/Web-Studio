# VT 补充验证与位置对照

同一提交 a184f45c079e361817fe7cfde4a6eb2e97fd70db 的 VT Debug 构建通过；PERF-20260930-R2 的 11 项门槛累计全部通过，字体金标 9/9 一致。第一次在 Documents 下运行，第 6 项失败后立即停止；用户明确授权只更换 worktree 位置，从第 6 项继续完成第 11 项。两次结果均保留，没有删除失败证据或将其写成通过。

## 隔离与受控条件

- 首次工作树：/Users/huaodong/Documents/Codex/2026-10-03/files-pasted-by-the-user-rein/work/web-structure/vt-validation-20261003/checkout。
- 本次工作树：/private/tmp/web-studio-structure-20261003-vt-recheck。
- 两个 detached worktree 均指向 a184f45，结束时均干净；124 个源码、测试、脚本文件逐字节一致。旧 worktree 和旧证据保留。
- 本轮主动改变的唯一执行条件是 worktree 位置（cwd 及对应 --source-root）。源码、脚本、工具版本、SDKROOT、TMPDIR、金标和其余命令参数保持一致；未调整编译选项、缓存策略或测试断言。
- 原目录的 7 个构建目录脚本改动来自独立会话“查找空间清理方法”。其哈希保持不变，不暂存、不修改、不还原，也不复制进验证 worktree。本轮未使用原目录已修改的 check.sh。

## 两轮结果

| 检查 | 首轮 exit / 秒 | 本轮 exit / 秒 |
| --- | --- | --- |
| VT Debug | 0 / 22.425 | 按授权不重跑 |
| metal | 0 / 24.399 | 按授权不重跑 |
| vt-core | 0 / 4.831 | 按授权不重跑 |
| vt-core-asan | 0 / 0.837 | 按授权不重跑 |
| vt-backend | 0 / 25.818 | 按授权不重跑 |
| vt-host | 0 / 11.717 | 按授权不重跑 |
| vt-visuals | 1 / 44.858 | 0 / 25.599 |
| pty-transport | 未运行 | 0 / 0.690 |
| pty-transport-swift | 未运行 | 0 / 8.862 |
| font-equiv | 未运行 | 0 / 15.583 |
| golden-font | 未运行 | 0 / 0.087 |
| unicode-diag | 未运行 | 0 / 19.904 |

首轮 vt-visuals 前半段 pure smoke 通过，后半段编译两次报 TerminalMetalRenderer.swift was modified during the build，脚本 exit 1。驱动随即停止，后五项未运行；未自行修复或重试。本轮 vt-visuals 两段均通过，后续五项也均 exit 0；原金标 9 张图全部一致，主线程另对实际 BGRA 文件计算 SHA-256，全部匹配。Unicode 脚本输出 24 条诊断记录。

VT Debug 原始日志含相关源码的 SwiftCompile 和实际 WEB_STUDIO_VT 编译条件。ASan 门槛首轮 exit 0；本轮没有重跑 Debug 或前五项，因此 11 项是同一源码版本、两次授权执行的累计结果，并非同一轮全部重跑。

## 时间戳与失败原因边界

每项及整轮前后均记录 TerminalMetalRenderer.swift 的 mtime_ns、ISO 时间、size 和 SHA-256，详见 attempt-2/results.json 及 whole-before/after.source-stat.json。所有观测完全一致：

- mtime_ns：1791034604491878916；UTC：2026-10-03T13:36:44.491879+00:00。
- 大小：47907 字节；SHA-256：a917dc7cc234b8238ff8441f6e90c28cb11398c5297b563761fd963f4cf67e64。

换到 /private/tmp 后同一检查通过，且新位置的观测时间戳与内容稳定，支持环境因素的判断。Documents/iCloud 同步引起元数据变化是用户提出的推断；本轮没有直接观测到同步进程改动源文件，不能将其写成已证实根因。第一次没有采集运行前后 mtime，不能补造该证据。

## UI 与默认方案

UI target 已编译、UI 测试未运行：B1 原始日志含两个 UI 测试文件的 SwiftCompile；B4 日志含 UI target 链接。摘录和日志哈希见 vt-validation/ui-target-build-evidence.json。VT scheme TestAction 为空，故使用独立的 VT 构建及 11 项 headless 门槛。

默认方案的既有证据仍为 B3/B4 各 291 passed、0 failed、0 skipped（原 283 + 新增 8）；本轮没有修改产品或测试，也没有再运行主目录那份已被另一会话修改的 check.sh。UI 运行验收、A、C 均不在本轮范围。

## 审查与证据

主线程已审查两轮原始日志、退出码、受控参数、时间戳及内容哈希，独立核对金标；提交仅追加本记录及 vt-validation/ 文本证据。所有旧 B1–B4 记录和第一次失败交付保持不变。

vt-validation/ 保存两轮命令清单、原始日志、退出码、环境、结果与源码摘要；SHA256SUMS 覆盖本报告和本次证据文件。二进制 xcresult 与图像原始产物留在日志记载的本机位置，不加入 Git。原始取证文件摘要 first-attempt-preserved.sha256.json 也涵盖仍保存在本机、未重复纳入 Git 的首轮辅助文件。

全部门槛通过后已获准推送 refactor/structure-20261003 并向 main 创建 PR，不合并。推送与 PR 的最终回执由本次交付报告记录，不能以本记录的存在推断远端动作已完成。

暂存审查：完整暂存文件敏感信息扫描无发现。原始日志按字节保留，故全量 git diff --check 返回 2，89 条诊断均仅为原始 .log 的空白；其余 43 个文档与数据文件的 diff --check 返回 0。没有为通过样式检查删改原始输出。
