# 02 配置持久化

核对日期：2026-09-27，依据当前工作区源码静态阅读，未运行构建或测试。返回[指南首页](README.md)。

涉及文件：[WorkspaceConfiguration.swift](../../Web%20Studio/WorkspaceConfiguration.swift)、[WorkspaceRepository.swift](../../Web%20Studio/WorkspaceRepository.swift)、[WorkspaceSaveController.swift](../../Web%20Studio/WorkspaceSaveController.swift)、[WorkspaceSession.swift](../../Web%20Studio/WorkspaceSession.swift)（`exportConfiguration`、`restoreDescriptors`）。

## 1. 保存什么、不保存什么

只保存命名工作空间的**配置**。临时空间在命名前不写盘。

| 保存 | 不保存 |
| --- | --- |
| 名称、默认目录、归档标记 | 终端进程、网页表单与页面状态 |
| 资源描述（目的地、自定义标题、顺序） | Agent 问题、草稿、快照、回答 |
| 常用入口（pins） | 最近资源（`recentResourceIDs`） |
| 布局（主/副面板、分栏比例、焦点） | 侧栏与 Agent 宽度、紧凑模式 |
| 面板偏好（侧栏、Agent 面板可见性）、`lastActivatedAt` | API Key（在 Keychain，见 [05](05-agent.md)） |

重启后网页按需懒加载；终端和 SSH 只恢复描述，需用户点击启动或连接。

## 2. Schema（版本 1）

`WorkspaceConfiguration` 的字段（所有配置类型均为 `nonisolated`、`Codable`、`Equatable`、`Sendable`）：

| 字段 | 类型 | 默认值 |
| --- | --- | --- |
| `schemaVersion` | Int | `currentSchemaVersion = 1` |
| `workspaceID` | UUID | — |
| `revision` | Int | 0 |
| `name` | String | — |
| `directory` | String? | — |
| `archived` | Bool | false |
| `resources` | `[WorkspaceResourceConfiguration]`：`id`、`destination`、`customTitle?`、`order` | [] |
| `pinnedDestinations` | `[WorkspacePinnedDestination]`：`id`、`title`、`destination` | [] |
| `layout` | `WorkspaceLayoutConfiguration`：`primary`、`secondary?`、`splitRatio`；面板为 `WorkspacePaneConfiguration`（`id`、`resourceID?`、`isFocused`） | — |
| `panelPreferences` | `WorkspacePanelPreferences`：`tabStripVisible`、`agentsVisible` | 均为 true |
| `lastActivatedAt` | Date? | — |

`WorkspaceDestinationConfiguration` 的 JSON 形式：

```json
{"kind": "blank"}
{"kind": "web", "url": "https://example.com"}
{"kind": "terminal", "directory": "/Users/me/project"}
{"kind": "ssh", "host": "example.com", "user": "me", "port": 22}
```

磁盘上写的是 `WorkspaceConfigurationEnvelope { configuration, diagnostics }`，写入时 `diagnostics` 总为空数组。诊断枚举 `WorkspaceConfigurationDiagnostic` 只在加载修复时产生：`duplicateResourceID`、`invalidResource`、`invalidPinnedDestination`、`duplicatePinnedDestination`、`workspaceIDMismatch`、`duplicatePaneID`、`duplicatePaneResource`、`invalidPaneReference`、`focusRepaired`、`layoutRepaired`。

会话映射：

- 导出 `WorkspaceSession.exportConfiguration(revision:)`：资源 `order` 取数组下标；无 URL 的网页导出为 `blank`。
- 导入 `WorkspaceSession(configuration:)` → `restoreDescriptors`：按 `order` 排序重建 `ResourceRecord`，分栏比例由 `WorkspaceLayout` 限制在 0.2–0.8，`isTemporary = false`。

新增 schema 版本时需要补迁移 fixture；当前没有旧版本迁移代码。

## 3. 磁盘布局

默认根目录 `~/Library/Application Support/Web Studio/Workspaces/`，或 `--workspace-config-root` 指定的目录。每个空间一组文件：

| 文件 | 作用 |
| --- | --- |
| `<UUID>.json` | 主配置 |
| `<UUID>.bak.json` | 上一份有效配置，每次保存时重写 |
| `<UUID>.lock` | `flock` 目标，不删除 |
| `<UUID>.tmp-<UUID>` | 写入用临时文件，结束后删除 |
| `<UUID>.corrupt-<UUID>.json` | 主文件损坏且从备份链路覆盖前保留的副本 |

`list()` 只接受文件名主干是 UUID 的 `*.json`，因此 `.bak`、`.corrupt` 文件不会被当成空间。编码使用 pretty-printed、sorted keys、带小数秒的 ISO8601；解码兼容有无小数秒。

## 4. `WorkspaceRepository`（actor）

| 方法 | 行为 |
| --- | --- |
| `list()` | 逐文件返回 `.entry(WorkspaceDirectoryRecord)` 或 `.diagnostic(id, error)`。Registry 将诊断放入 `directoryDiagnostics`，界面可“在 Finder 中显示”和“重新扫描”（`rescanDirectory`） |
| `load(id:)` | 文件不存在抛 `notFound`。先读原始 `schemaVersion`：高于当前版本抛 `unknownSchema`，**不回退备份**，避免被“加载失败→空配置→自动保存”覆盖。再 `decodeEnvelope`（丢弃解码失败或重复 ID 的资源/入口，文件名与 `workspaceID` 不一致视为损坏）和 `normalize`（校验目的地、修复布局）。其他失败回退 `.bak.json`，返回 `.recoveredFromBackup` |
| `save(_:expectedRevision:)` | 见下 |

目的地校验（`validDestination`）：终端路径必须是绝对路径且无控制字符；网页必须是带主机的 http(s)；SSH 端口 1…65535，主机为合法 IPv4、IPv6 或主机名且不以 `-` 开头。

`save` 的步骤：

1. 创建目录，对 `<id>.lock` 取**非阻塞独占 `flock`**；被占用抛 `busy`，打不开抛 `permissionFailure`。
2. 严格读取当前文件。主文件损坏但有备份时，以备份为当前版本，并把损坏文件另存为 `.corrupt-*`。
3. **乐观并发**：`expectedRevision` 必须等于当前 revision（`nil` 表示文件尚不存在），否则抛 `revisionConflict`。
4. `revision = max(传入, 当前) + 1`，`schemaVersion` 强制为当前版本。
5. 编码后立即解码回验。
6. 写临时文件 → 把**旧**配置写入 `.bak.json` → `replaceItemAt`（新文件用 `moveItem`）。

`WorkspaceRepositoryFault`（`beforeWrite`、`afterTempWrite`、`beforeReplace`）是测试用故障注入点。`WorkspaceRepositoryError` 列出全部错误：`notFound`、`corrupt`、`unknownSchema`、`revisionConflict`、`permissionFailure`、`injectedFault`、`busy`。

flock 与 revision 只防止旧写入覆盖新版本，不代表多个 App 实例可以共享同一空间的实时运行状态。

## 5. `WorkspaceSaveController`

每个会话一个，由 Registry 创建和持有，弱引用会话。

```text
session / resourceStore 的 objectWillChange
  → scheduleObservation（Task.yield 等改动落地）
  → markConfigurationChanged：比较去掉 revision 的配置投影
      变化 → generation += 1，状态 dirty → scheduleDebounce（默认 500ms）
  → flush：等待进行中的写入 → 快照 → saving(gen) → writer（默认 repository.save(expectedRevision: revision)）
      成功 → 更新 revision / lastSavedGeneration，session.markPersisted()
             若期间又有改动 → dirty 并继续循环；否则 saved
      失败 → lastError，failed
```

状态 `WorkspaceSaveState`：`clean`、`dirty`、`saving`、`saved`、`failed`。

| 方法 | 用途 |
| --- | --- |
| `saveNow()` | 取消防抖并立即 flush；关闭准备时使用 |
| `retry()` | 清除错误，强制重写 |
| `discardPendingChanges()` | 暂停、等待进行中写入，返回最后一次保存的配置 |
| `stopObserving()` | 暂停并取消订阅，关闭清理前调用 |
| `hasUnsavedConfiguration` | 当前投影与最后保存的配置是否不同 |

注意：

- 失败后防抖**不会**自动重试，需要 `retry()` 或 `saveNow()`。界面在侧栏状态点、工具栏“保存空间”和错误菜单中提供重试。
- 临时、已关闭或已暂停的会话 `flush()` 直接返回成功。
- `lastActivatedAt` 属于配置，所以每次切换到命名空间都会触发一次保存。
