# P4 原生 UI 自动化更新（P3 入口稳定后）

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

由届时空闲 coder 独占 Web StudioUITests 两文件。保留已有实质场景，更新旧英文、新建对话、默认网页和自动split假设；不得因新行为删掉原有校验。主线程统一Xcode和CUA。

- 每次 launch 提供独立临时 `--workspace-config-root`，避免扫描用户目录；测试配置无需真实Provider/SSH。需重启场景在同一case复用root。避免共享用户标准偏好和覆盖API Key；不用账户凭证。
- 初始真正空临时空间，无假网页。显式新网页后才出现start page/resource行。
- 原来新建对话清空草稿改为新问题保留草稿，能通过问题菜单返回。Preview必须明确确认才能发送，未配置Provider时不可发送。
- 分屏快捷键先显示选择器，选择现有资源/新资源后才能并排；收起保留资源，两侧选择无重复mount。
- 命名/保存状态、目录管理、关闭失败取消路径走产品入口。快捷键/地址无效输入/面板Escape/输入焦点仍保留测试。
- 900×560验证内容与问答切换均可达、草稿和layout保持；1440/1920真实尺寸由主线程CUA补。
- 恢复case先等已保存状态，正常退出路径优先；若XCTest terminate不经过正常quit，报告这是保存后重新启动，不冒充退出保存事务验收。
- AX/粘贴中文字不证明IME候选流程或VoiceOver；后者单独记录。

禁止用 `try?` 吞测试关键步骤、点击失败后跳过或存在即算通过。使用当前观察的identifier/label和明确expectation；保持错误输出和截图附加证据。运行不通保留failed/undetermined，别改环境系统设置来虚构通过。

检查 test-host 与 explicit root 优先级：AppDelegate 当前 isXCTest 分支可能忽略 --workspace-config-root。测试在需要持久化时必须显式root生效；未提供root的unit host继续禁用用户磁盘。若原生UI注入也设置XCTest信号，需调整为显式root优先、否则testhost memory-only；与UI coder协调Web_StudioApp唯一写权。Provider偏好同样要隔离（独立bundle或测试专用UserDefaults suite），不能修改用户真实偏好。

## 当前稳定标识与更新要求

命令行资源采用 command.resource.<workspace UUID>.<resource UUID>；普通操作仍command.<中文操作名>。不能使用宽泛resource.前缀把start/close/restart按钮误计入资源行；精确过滤resource.<UUID>行。首屏0资源，command新建网页后才出现StartPage。主线程要求对旧9条UI测试保持实质覆盖并添加保存后重启、独立问题保留、窄窗切换。workspace.showContent / workspace.showQuestions 为本轮compact控件约定，Agent收起/快捷键也走统一show/hide/toggle方法。

显式 --workspace-config-root 将优先testhost信号，启动逻辑用独立suite/credential service。每test独立root，重启case同root。不要真实Provider/SSH、不要改系统偏好，真实IME/VoiceOver由人工另判。UI test runner无法运行时保留错误，不降低断言。
