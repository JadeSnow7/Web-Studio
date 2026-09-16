# 当前 M2 实测记录（2026-09-16）

源码基线 `2631e149787c6cfd8d9b0903c89995e8cde96083`。本轮未修改 App 源码或生产默认。构建、host、PTY/backend/ASan 的命令、时间和结果见 `evidence/m2-current-*.json`。

## 真实窗口已验证

- 微信输入法：用户反馈“使用微信输入法，输入一切正常”，本轮默认窗口中文输入手测记为通过（用户确认）。[用户截图](evidence/m2-wechat-ime-user.png)显示 `IME_RESULT=[中文]` 和底部拼音预编辑文本；截图不包含候选框或取消操作的完整时序，不将这些写为主线程独立观察。组合中切换焦点、精确尺寸及分栏仍单列待验。[人工回执](evidence/m2-wechat-ime-user.json)。

- 当前 VT Release 的 ⌘K 打开命令面板，Escape 返回；⌘L 选中地址；点击终端后输入生效，shell PID 49591 保持。尚非完整焦点矩阵。
- Unicode/组合字符/Emoji/真彩色：新旧各五次 10000 行，均出现 `FIVE_BURSTS_DONE`。每次生成器正文 767067 字节、含标记总计 767248 字节；这是脚本输出计数，不是 PTY 实传计数。
- VT 退出时显示运行中会话确认；确认后 App PID 49064 和 shell PID 49591 均消失。
- 专用 SSH 资源：地址栏 `ssh://huaodong@127.0.0.1:60013` 创建独立资源，首次提示指纹与夹具公钥一致；用完整指纹确认后登录。远端 shell PID 82164，隐藏 Agent 前后 `stty size` 为 `45 98` → `45 134`，PID 不变。`exit 7` 后 App 显示 `Exited (7)` 并保留 `SSH_FINAL_7`。完整 AX 在 [最终状态](evidence/m2-ssh-final.ax.txt)，真实画面见 [首次指纹](evidence/m2-ssh-first-use.png)、[最终画面](evidence/m2-ssh-final.png)。这不是用户真实远端验收。
- 临时 sshd/专用 agent 已停止；仅移除本次端口及精确公钥的 known_hosts 条目，未改变既有记录。对照 App 均已退出，Debug 人工 IME 窗口保留。清理操作见 [回执](evidence/m2-ssh-cleanup.json)。

## 探索性 CPU/RSS 数据

| 构建 | 5轮空闲区间 CPU 中位数 | Unicode 25秒包络 CPU时间增量 | 负载离散 RSS 范围 |
| --- | --- | --- | --- |
| legacy | 0.399% | 0.82 s | 90560–120592 KiB |
| vt | 0.200% | 1.67 s | 77696–144288 KiB |

五轮空闲各5秒、0.5秒采样间隔。负载为单次25秒包络内五次固定输出，不是五次独立精确计时。VT 网格45×98、legacy为47×108；VT终端亮色、legacy终端深色。其他用户进程继续运行，RSS 也受操作系统回收影响。包络包含UI下发与空闲尾部。这组数据不能归因于单独渲染器，不能宣称整体更快/更慢，不能作性能验收阈值。原始数据、二进制及脚本哈希、条件见 [conditions](evidence/performance-baseline/conditions.json)。

首轮 legacy 误采了 `/usr/bin/login`，已保留到 `rejected-login-pid/` 并从此表排除。修正后的全部样本命令明确指向实际 App。CPU是单PID累计时间差；RSS是离散范围，非峰值；帧时间、输入延迟、GPU尚未测得。仍需同网格/外观、ASCII、隐藏空闲、滚动/resize、独立重复与trace。

## 尚需完成

IME 在组合中切换焦点、900×560及分栏场景的专项复验、VoiceOver全流程、精确900×560内容区和其他显示缩放、完整鼠标/键盘/焦点/关闭矩阵、规范化性能对照。`--minimum-window` 启动参数没有独立尺寸测量，不算精确尺寸通过。截图由真实窗口采集，工具会缩放；JPEG转PNG只转换编码，不恢复原生显示尺寸。

本轮不切换生产默认，不把脚本/构建通过写为M2整体通过。流程改进候选见 [skill观察](SKILL-OBSERVATIONS.md)。

记录限制：上述构建/smoke原始执行结果为通过，记录包含源码哈希；主线程未传递任务版本绑定参数，缺少task revision token。结构状态中已标为stale，不能用于skill最终验收门禁。正式收尾应在冻结变更后按绑定版本重跑；没有事后补填执行token。

## 恢复执行记录入口

2026-09-16 后续窗口、人工回执、生命周期、性能可比性和冻结版本回归统一记录于 [恢复实测结果](evidence/m2-resume-results.md)。下文或上述旧结果保留各自版本边界；本轮最新判定以该记录和 task-state.json 为准。
