# B1 验收协议

> 2026-09-26：本文件继续定义完整 B1 验收判据，不降低门槛。后续修复验收见 [review-fixes](review-fixes/ACCEPTANCE.md)，已执行结果与未满足项见 [STATUS](../../STATUS.md)。

当前处于阶段性验证：完整产品场景仍为 **undetermined**，最新模型、自动化界面及原生运行结果分别见 task-summary.md 和 B1-RESULTS.md。准备资料与源码保护已核验。每次运行绑定 task-state.json 的 Spec digest、源码 revision、方案输入、环境和原始输出；历史通过不能跨改动直接复用。

## 场景、观察与反例

| ID / 阶段 | 输入及操作 | 必须观察到的结果；能发现的错误 | 证据 |
| --- | --- | --- | --- |
| A01 / P0 | 从空临时空间开始，创建 A/B，网页与终端并排，选资料并提问，切换再关闭/重启 | 操作对象及后果可预测；流程包含失败和取消，不以已保存配置冒充仍运行的进程 | 原型、流程稿、走查逐项记录；用户可理解性须实际反馈 |
| A02 / P1 | A/B 各建网页、终端、不同 AI 草稿和布局，A 请求延迟完成期间切 B | 布局/比例/焦点/面板偏好及草稿各自返回；回答写 A，B 不出现 A 来源 | 模型状态 + 延迟 provider 调用日志 + 原生界面 |
| A03 / P1 | A 真 Shell 周期输出带唯一标记，切 B 再回 A；隐藏网页输入表单 | 相同运行实例和进程身份、启动计数不增加；输出/表单保留 | 真实 PTY/网页状态、实例/启动记录；单纯最终截图不足 |
| A04 / P1 | 第二窗口点开第一窗口承载的 A；再关闭第一窗口，重新打开 A | 激活既有窗口；运行时未复制；释放后才能新承载 | Registry 测试、两窗口屏幕记录、运行时计数 |
| A05 / P1 | A 有运行终端/AI，当前显示 B；关闭窗口；取消一次，再确认；同时重复关闭 | 汇总包含 A/B；取消无终止；确认等全部清理，每个资源释放一次 | 注入关闭计数、真实子进程退出、窗口记录 |
| A06 / P2 | 保存双视图、网页/终端/SSH描述、入口、面板偏好；退出重启；搜索未启动资源 | ID/顺序/布局恢复；Shell/SSH/AI 启动 0 次；网页只可见时创建；明确启动后仅一次 | 磁盘回读、启动工厂计数、进程记录、真实 UI |
| A07 / P2 | 注入 EACCES/磁盘写失败、截断主 JSON、有效/无效备份、未知新 schema | 未保存持久可见；原件 hash 不变；可恢复有效备份；无有效配置时隔离；不覆盖默认空空间 | fixture 前后 hash、异常输出、保存状态记录 |
| A08 / P2 | 重复 ID、失效 pane 引用、不支持目的地、失效目录；旧写入晚于新写入返回 | 冲突项拒绝并报告，有效项可用；不启动资源；旧回执不覆盖最新 revision/已保存反馈 | fixture 验证、可控调度、回读 revision 和状态 |
| A09 / P3 | 打开地址/SSH/编辑面板后切空间或关闭目标；未闭合引号和长路径输入 | 地址撤销/临时面板关闭；其他草稿保留或要求处理；不重定向新资源；校验明确 | 路由测试、键盘/IME 真实操作 |
| A10 / P3 | 显示同资源到另一侧；替换当前侧；收起终端视图后再打开；结束会话后重启 | 不重复挂载；另一侧不变；收起不终止；结束保留行；重启实例 ID 改变 | host 对象身份、启动/关闭计数和原生焦点 |
| A11 / P3 | 采集资料后改页面、关闭来源、重启终端；移除/添加选择；失败来源重读 | 旧快照不可变、重试不重读；选择失配阻止发送；新请求绑定新实例；失败需处理 | reader/provider spy、请求比较、快照详情 |
| A12 / P3 | 旧答案/草稿存在时新问题；切回；请求中编辑另题；取消后迟到回调 | 旧题/草稿可找回；每空间一个请求；迟到结果不得写新题；不自动发送历史 | 问题状态测试、调用计数、真实面板 |
| A13 / P3 | 复制终端/网页入口到 B，常用入口重复打开；⌘K 全空间同名搜索 | 只复制目的地；无运行时迁移；独立资源 ID；同名条目带空间/类型/摘要 | 配置比较、实例计数、命令测试 |
| A14 / P4 | 900×560、1440×900、1920×1080；长中英文标题、中文 IME、键盘、VoiceOver | 内容/AI 切换可达、布局/草稿保留、无误提交串焦点；状态有可读名称 | 各窗口尺寸截图、键盘/IME/VO 逐步记录；尺寸为测试样本非固定断点 |
| A15 / P4 | 临时空间含资源/AI，关闭/退出；已保存空间有脏配置并注入保存失败 | 明确保存配置或丢弃，说明 AI 不持久化；重试/取消/不保存关闭行为正确 | 磁盘扫描不含 AI 正文/密钥，真实关闭路径与状态 |
| A16 / P4 | 全程真实 Shell、可用 SSH 主机、配置后的真实 Provider 完成一次冻结问题 | 真实链路分别通过；SSH 启动不等于认证，CLI 成功不等于 GUI 闭环 | 目标身份（不含凭证）、运行记录/原始输出、取消测试 |

每行在实际执行时拆成可判定检查；模型通过而真实 UI 未测时，模型部分 passed、整行 undetermined。模拟故障仅支持注入路径；不推断断电零损失。性能只核查功能保持，不套用现有性能基线做改善结论。

## 执行方法

模型基线使用 README 的默认 `Web Studio` scheme 和单进程 XCTest；构建产物置于 `/private/tmp/web-studio-b1-*`，不复用已安装应用或改写性能测试产物。P1 优先现有 Web_StudioTests、AgentControllerTests、ResourceReadTests 与新增 WorkspaceOwnershipTests、WorkspaceModelTests、WorkspaceResourceLifecycleTests；P2 加 WorkspacePersistenceTests；P3 加问题/目标/命令用例；P4 扩到完整受影响测试和原生 GUI。

默认构建（进入原生产品实现时运行；结果在执行记录中判定）：

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-b1-build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

L2 执行命令经 `record_execution.py --repo . --state records/WORKSPACE-B1-20260917/task-state.json --output <新的证据路径> -- <命令>` 保存。记录 stdout/stderr、退出码、fixture、开始/结束指纹；新证据不覆盖旧记录。真实运行使用独立测试配置目录，测试目录隔离通过 `--workspace-config-root PATH` 提供；该入口已用于固定P2构建的隔离原生走查，最终P3构建仍须重验。

手动证据写明二进制 hash、源码/Spec 指纹、scheme、窗口尺寸、动作顺序、预期与实际、截图路径及操作者。SSH/Provider 尚无可用测试环境时只标 undetermined；不为获得通过而自动使用账户、购买额度或读取私钥。

## 通过判定

MET-PREP 只覆盖输入冻结、合同完整、代码与既有修改保护；记录门槛通过不能支持 MET-P0–MET-P4。P0 用户能否理解需用户走查或具体反馈，不能由机器截图替代。后续实现和内测可在未完成最终用户验收时持续迭代，但不得把产品完整验收标为 passed。

本任务门槛可复跑：

```sh
python3 /Users/huaodong/Documents/evidence-driven-development/skill/veriflow/scripts/validate_task.py \
  records/WORKSPACE-B1-20260917/task-state.json --repo . --gate implementation
```

此命令只做结构与就绪检查。执行产品验收需改用 `--gate acceptance` 并满足全部强制指标；当前必然不满足，不能用 implementation 的退出码替代。
