import AppKit
import SwiftUI

nonisolated struct StudioLaunchOptions: Equatable {
  let isXCTest: Bool
  let workspaceConfigRoot: URL?
  let providerDefaultsSuite: String?

  nonisolated static func scopedProviderDefaultsSuite(root: URL, explicitSuite: String? = nil) -> String {
    explicitSuite ?? "com.huaodong.web-studio.provider.\(scopedToken(for: root))"
  }

  nonisolated static func scopedKeychainService(root: URL) -> String {
    "com.huaodong.web-studio.provider.\(scopedToken(for: root))"
  }

  nonisolated static func resolve(arguments: [String], environment: [String: String], xctestClassPresent: Bool = false)
    -> Self
  {
    let isXCTest =
      environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
      || xctestClassPresent
    func value(after flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
      let value = arguments[index + 1]
      return value.isEmpty || value.hasPrefix("--") ? nil : value
    }
    let root = value(after: "--workspace-config-root").map { URL(fileURLWithPath: $0, isDirectory: true) }
    return Self(
      isXCTest: isXCTest, workspaceConfigRoot: root, providerDefaultsSuite: value(after: "--provider-defaults-suite"))
  }
}

nonisolated private func scopedToken(for root: URL) -> String {
  var hash: UInt64 = 14_695_981_039_346_656_037
  // Keep the scope tied to the lexical launch argument. Foundation's
  // standardizedFileURL can resolve an existing path through a symlink
  // (for example, an existing /private/tmp child to /tmp), while leaving a
  // not-yet-created path untouched. That would change the suite and
  // Keychain service between launches.
  for byte in root.path.utf8 {
    hash ^= UInt64(byte)
    hash &*= 1_099_511_628_211
  }
  return String(hash, radix: 16)
}

@MainActor final class StudioApplicationDelegate: NSObject, NSApplicationDelegate {
  let workspaceRegistry: WorkspaceRegistry
  private var terminationInProgress = false
  override init() {
    let arguments = ProcessInfo.processInfo.arguments
    let environment = ProcessInfo.processInfo.environment
    let options = StudioLaunchOptions.resolve(
      arguments: arguments, environment: environment,
      xctestClassPresent: NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil)
    if let root = options.workspaceConfigRoot {
      let suite = StudioLaunchOptions.scopedProviderDefaultsSuite(
        root: root, explicitSuite: options.providerDefaultsSuite)
      let defaults = UserDefaults(suiteName: suite)!
      let credentials = KeychainCredentialStore(service: StudioLaunchOptions.scopedKeychainService(root: root))
      let provider = ProviderSettings(credentials: credentials, defaults: defaults)
      let repository = WorkspaceRepository(rootURL: root)
      workspaceRegistry = WorkspaceRegistry(
        providerSettings: provider, repository: repository,
        configurationLoader: { id in try await repository.load(id: id) },
        directoryLoader: { try await repository.list() })
    } else if options.isXCTest {
      let suite = options.providerDefaultsSuite ?? "com.huaodong.web-studio.xctest.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      let credentials = KeychainCredentialStore(service: "com.huaodong.web-studio.xctest.\(UUID().uuidString)")
      let provider = ProviderSettings(credentials: credentials, defaults: defaults)
      workspaceRegistry = WorkspaceRegistry(providerSettings: provider)
    } else {
      let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Web Studio", isDirectory: true)
        .appendingPathComponent("Workspaces", isDirectory: true)
      let repository = WorkspaceRepository(rootURL: root)
      workspaceRegistry = WorkspaceRegistry(
        repository: repository,
        configurationLoader: { id in try await repository.load(id: id) },
        directoryLoader: { try await repository.list() })
    }
    super.init()
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress else { return .terminateLater }
    let sessions = workspaceRegistry.liveSessions.sorted { $0.name < $1.name }
    if !sessions.isEmpty {
      let alert = NSAlert()
      alert.messageText = "退出 Web Studio？"
      alert.informativeText =
        sessions.map { session in
          let requests = session.agentController.isRequesting ? 1 : 0
          return "\(session.name)：\(session.resourceStore.liveTerminalCount) 个终端，\(requests) 个请求"
        }.joined(separator: "\n") + "\n将关闭所有窗口的会话并清空问答；退出前会逐一处理配置保存。"
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "退出")
      guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    }
    for session in sessions where session.isTemporary {
      guard confirmTemporaryWorkspaceClose(session, registry: workspaceRegistry) else {
        return .terminateCancel
      }
    }
    terminationInProgress = true
    Task { @MainActor in
      let resolver = makeWorkspaceSaveFailureResolver(action: "退出应用")
      let closed = await workspaceRegistry.closeAll(resolver: resolver)
      terminationInProgress = false
      sender.reply(toApplicationShouldTerminate: closed)
    }
    return .terminateLater
  }
}

@main
struct Web_StudioApp: App {
  @NSApplicationDelegateAdaptor(StudioApplicationDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup { StudioWindowRoot(registry: appDelegate.workspaceRegistry).preferredColorScheme(forcedColorScheme) }
      .defaultSize(width: minimumWindow ? 900 : 1400, height: minimumWindow ? 560 : 860)
      .windowToolbarStyle(.unifiedCompact)
      .commands { StudioCommands() }
  }

  private var forcedColorScheme: ColorScheme? {
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--appearance-dark") { return .dark }
    if args.contains("--appearance-light") { return .light }
    return nil
  }
  private var minimumWindow: Bool { ProcessInfo.processInfo.arguments.contains("--minimum-window") }
}

private struct StudioCommands: Commands {
  @FocusedValue(\.studioModel) private var model
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button {
        model?.newTab()
      } label: {
        Label("新建网页", systemImage: studioResourceSymbol(.web))
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(model == nil)
      Button {
        model?.newTerminal(directoryURL: nil)
      } label: {
        Label("新建终端", systemImage: studioResourceSymbol(.localTerminal))
      }
      .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(model == nil)
      Button {
        model?.newTerminalInFolder()
      } label: {
        Label("在文件夹中新建终端…", systemImage: studioResourceSymbol(.localTerminal))
      }
      .disabled(model == nil)
      Button("关闭资源") {
        guard let model else { return }
        if model.panels.panel != nil {
          model.dismissPanel()
        } else {
          model.closeSelectedTab()
        }
      }.keyboardShortcut("w", modifiers: .command).disabled(model == nil)
      Button("打开目标…") { model?.openDestination() }.keyboardShortcut(
        "l", modifiers: .command
      ).disabled(model == nil)
      Button("命令面板…") {
        guard let model else { return }
        model.openCommands()
      }.keyboardShortcut("k", modifiers: .command).disabled(model == nil)
      Divider()
      Button("下一个资源") { model?.selectNextTab() }
        .keyboardShortcut(.tab, modifiers: .control)
        .disabled((model?.visibleTabs.count ?? 0) < 2)
      Button("上一个资源") { model?.selectPreviousTab() }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled((model?.visibleTabs.count ?? 0) < 2)
      // ⌘1–⌘8 pick a position and ⌘9 picks the last tab, as Safari does. They live in
      // a submenu so nine shortcuts stay discoverable without flooding the menu.
      Menu("选择资源") {
        ForEach(1...9, id: \.self) { position in
          Button("资源 \(position)") { model?.selectTab(at: position - 1) }
            .keyboardShortcut(
              KeyEquivalent(Character("\(position)")),
              modifiers: .command
            )
        }
      }.disabled(model == nil)
    }
    CommandMenu("网页") {
      Button("后退") { model?.webGoBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!(model?.activeWebState.canGoBack ?? false))
      Button("前进") { model?.webGoForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!(model?.activeWebState.canGoForward ?? false))
      Divider()
      Button(model?.activeWebState.isLoading == true ? "停止加载" : "重新加载网页") {
        model?.webReloadOrStop()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(!(model?.selectedTabIsWeb ?? false))
    }
    CommandMenu("布局") {
      Button("分屏") { model?.split() }.keyboardShortcut("\\", modifiers: [.command, .option]).disabled(
        model?.layout.isSplit ?? true)
      Button("聚焦另一面板") { model?.focusOtherPaneAndContent() }.keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(!(model?.layout.isSplit ?? false))
      Button("关闭聚焦面板") { if let model { model.closePane(model.focusedPane.id) } }.keyboardShortcut(
        "w", modifiers: [.command, .option]
      ).disabled(!(model?.layout.isSplit ?? false))
      Button("单面板") { model?.returnToSinglePane() }.keyboardShortcut("1", modifiers: [.command, .option])
      Button("交换面板") { model?.swapPanes() }.keyboardShortcut("s", modifiers: [.command, .option, .shift]).disabled(
        !(model?.layout.isSplit ?? false))
      Divider()
      Button("缩小左侧") { model?.setSplitRatio((model?.layout.splitRatio ?? 0.5) - 0.05) }.keyboardShortcut(
        "[", modifiers: [.command, .option])
      Button("放大左侧") { model?.setSplitRatio((model?.layout.splitRatio ?? 0.5) + 0.05) }.keyboardShortcut(
        "]", modifiers: [.command, .option])
      Button("重置比例") { model?.setSplitRatio(0.5) }.keyboardShortcut("0", modifiers: [.command, .option])
    }
    CommandGroup(after: .sidebar) {
      Button("切换侧边栏") { model?.tabStripVisible.toggle() }.keyboardShortcut(
        "s", modifiers: [.command, .option]
      ).disabled(model == nil)
      Button("切换问答") {
        model?.toggleQuestionPanel()
      }
      .keyboardShortcut(
        "a",
        modifiers: [.command, .option]
      ).disabled(model == nil)
    }
  }
}
