import AppKit
import Combine
import Darwin
import SwiftUI

private struct StudioModelFocusedKey: FocusedValueKey { typealias Value = StudioModel }
extension FocusedValues {
  var studioModel: StudioModel? {
    get { self[StudioModelFocusedKey.self] }
    set { self[StudioModelFocusedKey.self] = newValue }
  }
}



struct ContentView: View {
  @ObservedObject var model: StudioModel
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sidebarDragStart: CGFloat?
  @State private var agentsDragStart: CGFloat?
  @State private var renderedPanel: PanelCoordinator.Panel?
  @State private var panelHostVisible = false
  @State private var panelPresentationID = 0
  @State private var panelHostGeneration = 0
  var body: some View {
    GeometryReader { proxy in
      let plan = StudioLayoutPlan.resolve(
        windowWidth: proxy.size.width,
        sidebarWidth: model.sidebarWidth,
        agentsWidth: model.agentsWidth,
        sidebarVisible: model.tabStripVisible,
        agentsVisible: model.questionPanelVisible
      )
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear { model.updateCompactMode(for: proxy.size.width) }
        .onChange(of: proxy.size.width) { _, width in model.updateCompactMode(for: width) }
      HStack(spacing: 0) {
        if !plan.isCompactMode, model.tabStripVisible {
          TabStrip(model: model, compact: plan.compactSidebar)
            .frame(width: plan.sidebarWidth)
          Divider().frame(width: 6).contentShape(Rectangle()).gesture(resizeSidebar)
            .help("调整空间栏宽度")
        }
        if plan.isCompactMode {
          ZStack(alignment: .top) {
            VStack(spacing: 0) { TabContent(model: model) }
              .opacity(plan.contentVisible ? 1 : 0)
              .allowsHitTesting(plan.contentVisible)
              .accessibilityHidden(!plan.contentVisible)
            AgentInspectorView(model: model).id(model.session.id)
              .opacity(plan.questionsVisible ? 1 : 0)
              .allowsHitTesting(plan.questionsVisible)
              .accessibilityHidden(!plan.questionsVisible)
          }.frame(minWidth: 0, maxWidth: .infinity)
        } else {
          VStack(spacing: 0) { TabContent(model: model) }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        if !plan.isCompactMode, model.questionPanelVisible {
          Divider().frame(width: 6).contentShape(Rectangle()).gesture(resizeAgents)
            .help("调整问答面板宽度")
          AgentInspectorView(model: model).id(model.session.id).frame(width: plan.agentsWidth)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .top) {
        if let runtime = model.activeWebRuntime {
          PageChromeBackdrop(runtime: runtime, topInset: proxy.safeAreaInsets.top)
            .id(runtime.resourceID)
        }
      }
    }.frame(minWidth: 900, minHeight: 560)
      .background {
        Group {
          if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
          } else {
            StudioBackdrop(reduceTransparency: false).allowsHitTesting(false)
          }
        }
        .ignoresSafeArea(.container, edges: .top)
      }
      .background(WindowLifecycle(model: model).frame(width: 0, height: 0))
      .background(WindowKeyRouter(model: model).frame(width: 0, height: 0))
      .disabled(model.session.isClosed || model.windowCoordinator.isClosing)
      .toolbar { StudioToolbar(model: model) }
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
      .toolbar(removing: .title)
      .overlay(alignment: .top) {
        ZStack(alignment: .top) {
          ZStack {
            if let panel = renderedPanel, panel != .commands {
              panelContent(panel)
                .id(panelViewIdentity(panel))
                .allowsHitTesting(model.panels.panel == panel)
                .disabled(!(model.panels.panel == panel))
                .accessibilityHidden(!(model.panels.panel == panel))
            }
          }
          .opacity(panelHostVisible ? 1 : 0)
          .offset(y: panelHostVisible || reduceMotion ? 0 : 6)
          .scaleEffect(panelHostVisible || reduceMotion ? 1 : 0.98)
          .animation(
            StudioDesign.Motion.animation(StudioDesign.Motion.panel, reduceMotion: reduceMotion),
            value: panelHostVisible)
          if model.panels.panel == .commands {
            StudioPanelSurface { CommandPalette(model: model) }
              .animation(
                StudioDesign.Motion.animation(StudioDesign.Motion.panel, reduceMotion: reduceMotion),
                value: model.panels.panel == .commands)
          }
        }
      }
      .overlay(alignment: .bottom) {
        if let notice = model.workspaceNotice {
          HStack {
            Text(notice)
            Button("知道了") { model.workspaceNotice = nil }
          }
          .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding()
        }
      }
      .onAppear { syncPanelHost(model.panels.panel) }
      .onChange(of: model.panels.panel) { _, panel in syncPanelHost(panel) }
  }

  @ViewBuilder private func panelContent(_ panel: PanelCoordinator.Panel) -> some View {
    if panel == .groupEditor { StudioPanelSurface { GroupEditor(model: model) } }
    if case .resourceEditor = panel { StudioPanelSurface { ResourceEditor(model: model) } }
    if panel == .providerSettings {
      StudioPanelSurface { ProviderSettingsView(settings: model.providerSettings, model: model) }
    }
    if panel == .startEntry { StudioPanelSurface { StartEntryView(model: model) } }
    if panel == .agentResources { StudioPanelSurface { AgentResourcesPanel(model: model) } }
    if panel == .agentPreview { StudioPanelSurface { AgentPreviewPanel(model: model) } }
    if case .agentRunDetails(let runID) = panel {
      StudioPanelSurface { AgentRunDetailsPanel(model: model, runID: runID) }
    }
  }

  private func syncPanelHost(_ panel: PanelCoordinator.Panel?) {
    panelHostGeneration &+= 1
    let generation = panelHostGeneration
    if let panel {
      if panel != .commands { panelPresentationID &+= 1 }
      renderedPanel = panel
      panelHostVisible = false
      DispatchQueue.main.async {
        guard generation == panelHostGeneration, model.panels.panel == panel else { return }
        panelHostVisible = true
      }
    } else {
      panelHostVisible = false
      DispatchQueue.main.asyncAfter(deadline: .now() + StudioDesign.Motion.panel) {
        guard generation == panelHostGeneration, model.panels.panel == nil else { return }
        renderedPanel = nil
      }
    }
  }

  private func panelIdentity(_ panel: PanelCoordinator.Panel?) -> String {
    switch panel {
    case .none: return "none"
    case .destination: return "destination"
    case .commands: return "commands"
    case .groupEditor: return "group-editor"
    case .resourceEditor(let id): return "resource-editor-\(id.uuidString)"
    case .providerSettings: return "provider-settings"
    case .startEntry: return "start-entry"
    case .agentResources: return "agent-resources"
    case .agentPreview: return "agent-preview"
    case .agentRunDetails(let id): return "agent-run-details-\(id.uuidString)"
    }
  }

  private func panelViewIdentity(_ panel: PanelCoordinator.Panel) -> String {
    return "\(panelIdentity(panel))-\(panelPresentationID)"
  }

  private var resizeSidebar: some Gesture {
    DragGesture().onChanged {
      value in
      if sidebarDragStart == nil {
        sidebarDragStart = model.sidebarWidth
      }
      model.sidebarWidth = max(
        180,
        min(320, (sidebarDragStart ?? model.sidebarWidth) + value.translation.width)
      )
    }.onEnded { _ in sidebarDragStart = nil }
  }

  private var resizeAgents: some Gesture {
    DragGesture().onChanged {
      value in
      if agentsDragStart == nil {
        agentsDragStart = model.agentsWidth
      }
      model.agentsWidth = max(
        220,
        min(360, (agentsDragStart ?? model.agentsWidth) - value.translation.width)
      )
    }.onEnded { _ in agentsDragStart = nil }
  }
}

/// AppKit's local monitor runs before WKWebView handles key events, which keeps
/// window-scoped shortcuts reliable even when the page owns first responder.
private struct WindowKeyRouter: NSViewRepresentable {
  let model: StudioModel
  func makeNSView(context: Context) -> NSView { KeyRouterView(model: model) }
  func updateNSView(_ nsView: NSView, context: Context) {}
  private final class KeyRouterView: NSView {
    let model: StudioModel
    var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    init(model: StudioModel) {
      self.model = model
      super.init(frame: .zero)
      model.workspaceFocusView = self
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window else { return event }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "l" {
          model.requestAddressFocus()
          return nil
        }
        if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
          model.openCommands()
          return nil
        }
        if event.keyCode == 53, model.panels.panel == .commands,
          let editor = model.commandSearchField?.currentEditor() as? NSTextView,
          editor.hasMarkedText()
        {
          return event
        }
        if event.keyCode == 53, model.panels.panel != nil {
          model.dismissPanel()
          return nil
        }
        if event.keyCode == 53, model.isAddressEditing {
          model.cancelAddressEditing()
          model.focusCurrentPaneContent()
          return nil
        }
        return event
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil, model.workspaceFocusView === self {
        model.workspaceFocusView = nil
      } else if window != nil {
        model.workspaceFocusView = self
      }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

struct StudioWindowRoot: View {
  @StateObject private var model: StudioModel
  @State private var restorationStarted = false
  init(registry: WorkspaceRegistry? = nil) {
    _model = StateObject(wrappedValue: StudioModel(registry: registry))
  }
  var body: some View {
    ContentView(model: model)
      .focusedSceneValue(\.studioModel, model)
      .task {
        guard !restorationStarted else { return }
        restorationStarted = true
        await model.restoreLastActiveWorkspace()
      }
  }
}

private struct StudioAddressField: View {
  @ObservedObject var model: StudioModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      NativeAddressField(model: model)
        .frame(
          minWidth: model.isCompactMode ? 120 : 220,
          idealWidth: model.isCompactMode ? 150 : 360,
          maxWidth: model.isCompactMode ? 220 : 520)
      if let error = model.addressError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .help(error)
          .accessibilityLabel(error)
      }
    }
    .padding(.horizontal, StudioDesign.Spacing.control).padding(.vertical, 7)
    .studioGlassCapsule()
    .overlay(
      Capsule().stroke(
        model.isAddressEditing ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .animation(
      StudioDesign.Motion.animation(StudioDesign.Motion.hover, reduceMotion: reduceMotion),
      value: model.isAddressEditing
    )
    .help("地址（⌘L）")
  }
}

private final class AddressTextField: NSTextField {
  var onEscape: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onEscape?()
      return
    }
    super.keyDown(with: event)
  }
}

private struct NativeAddressField: NSViewRepresentable {
  @ObservedObject var model: StudioModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> AddressTextField {
    let field = AddressTextField(string: model.addressText)
    field.placeholderString = "输入网址、SSH 主机或终端路径"
    field.isBordered = false
    field.drawsBackground = false
    (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
    field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submit)
    field.onEscape = { [weak coordinator = context.coordinator] in
      coordinator?.model.cancelAddressEditing()
      coordinator?.model.focusCurrentPaneContent()
    }
    field.setAccessibilityLabel("地址")
    field.setAccessibilityIdentifier("destination.address")
    model.addressInputField = field
    return field
  }

  func updateNSView(_ field: AddressTextField, context: Context) {
    context.coordinator.update(field)
  }

  static func dismantleNSView(_ field: AddressTextField, coordinator: Coordinator) {
    if coordinator.model.addressInputField === field { coordinator.model.addressInputField = nil }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    let model: StudioModel
    private var lastFocusToken: Int
    init(model: StudioModel) {
      self.model = model
      self.lastFocusToken = model.addressFocusToken
    }

    @objc func submit(_ sender: NSTextField) {
      guard (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      model.beginAddressEditing()
      model.addressText = sender.stringValue
      model.noteAddressEdit()
      model.submitAddress()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      model.beginAddressEditing()
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      model.beginAddressEditing()
      model.addressText = field.stringValue
      model.noteAddressEdit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      guard !textView.hasMarkedText() else { return false }
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        submit(control as! NSTextField)
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        model.cancelAddressEditing()
        model.focusCurrentPaneContent()
        return true
      }
      return false
    }

    func update(_ field: AddressTextField) {
      if field.stringValue != model.addressText,
        (field.currentEditor() as? NSTextView)?.hasMarkedText() != true
      {
        field.stringValue = model.addressText
      }
      guard lastFocusToken != model.addressFocusToken else { return }
      lastFocusToken = model.addressFocusToken
      DispatchQueue.main.async {
        guard let window = field.window else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
      }
    }
  }
}

private struct StudioToolbar: ToolbarContent {
  @ObservedObject var model: StudioModel
  @ToolbarContentBuilder var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Menu {
        ForEach(model.groups) { group in
          Button(group.name) { model.selectWorkspace(group.id) }
        }
        Divider()
        Button("新建空间…") { model.addGroup() }
        Button("空间设置…") { model.beginRenameGroup(model.session.id) }
        if model.session.isTemporary {
          Button("命名并保存…") { model.beginRenameGroup(model.session.id) }
        } else {
          Button("保存空间") { model.retryWorkspaceSave() }
          Button(model.session.archived ? "恢复空间" : "归档空间") {
            if model.session.archived {
              model.restoreArchivedWorkspace(model.session.id)
            } else {
              model.archiveWorkspace(model.session.id)
            }
          }
        }
        if !model.windowCoordinator.registry.archivedEntries.isEmpty {
          Menu("恢复已归档空间") {
            ForEach(model.windowCoordinator.registry.archivedEntries) { entry in
              Button(entry.name) { model.restoreArchivedWorkspace(entry.id) }
            }
          }
        }
        Button("关闭当前空间…") { model.closeWorkspace(model.session.id) }
        if case .failed(_, let message) = model.workspaceSaveState {
          Divider()
          Text("保存错误：\(message)")
          Button("重试保存") { model.retrySave(for: model.session.id) }
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "square.stack")
          VStack(alignment: .leading, spacing: 0) {
            Text(model.session.name).lineLimit(1)
            Text(model.workspaceSelectorStatus)
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityIdentifier("workspace.selector")
      if !model.isCompactMode {
        Button {
          model.tabStripVisible.toggle()
        } label: {
          Image(systemName: "sidebar.leading")
        }.studioGlassButton().frame(minWidth: 28, minHeight: 28).help("切换侧栏（⌘⌥S）")
          .accessibilityLabel("切换侧栏")
          .accessibilityValue(model.tabStripVisible ? "已显示" : "已隐藏")
      }
      Button {
        model.webGoBack()
      } label: {
        Image(systemName: "chevron.left")
      }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
        .disabled(!model.activeWebState.canGoBack)
        .help("后退（⌘[）")
        .accessibilityLabel("后退")
        .accessibilityIdentifier("web.back")
      Button {
        model.webGoForward()
      } label: {
        Image(systemName: "chevron.right")
      }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
        .disabled(!model.activeWebState.canGoForward)
        .help("前进（⌘]）")
        .accessibilityLabel("前进")
        .accessibilityIdentifier("web.forward")
      Button {
        model.webReloadOrStop()
      } label: {
        Image(systemName: model.activeWebState.isLoading ? "xmark" : "arrow.clockwise")
      }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
        .disabled(!model.selectedTabIsWeb)
        .help(model.activeWebState.isLoading ? "停止加载" : "重新加载（⌘R）")
        .accessibilityLabel(model.activeWebState.isLoading ? "停止加载" : "重新加载")
        .accessibilityIdentifier("web.reloadOrStop")
    }
    ToolbarItem(placement: .principal) {
      StudioAddressField(model: model)
    }.sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .primaryAction) {
      Button {
        model.openCommands()
      } label: {
        Label(
          "命令",
          systemImage: "command"
        )
      }.studioGlassButton().frame(minHeight: 28).help("命令面板（⌘K）")
        .accessibilityIdentifier("commands.button")
    }
    if !model.windowCoordinator.registry.diagnosticEntries.isEmpty || model.isRescanningWorkspaceDirectory {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button(model.isRescanningWorkspaceDirectory ? "扫描中…" : "重新扫描") {
            model.rescanWorkspaceDirectory()
          }
          .disabled(model.isRescanningWorkspaceDirectory)
          ForEach(model.windowCoordinator.registry.diagnosticEntries) { diagnostic in
            if let fileURL = diagnostic.fileURL {
              Button("定位 \(diagnostic.detail)") { model.revealWorkspaceDiagnostic(diagnostic) }
              Text(fileURL.path).font(.caption)
            } else {
              Text(diagnostic.detail)
            }
          }
        } label: {
          Image(
            systemName: model.isRescanningWorkspaceDirectory
              ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
        }
        .help("配置诊断")
        .accessibilityLabel("配置诊断")
        .accessibilityIdentifier("workspace.diagnostics.toolbar")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button("分屏") { model.split() }.disabled(model.layout.isSplit)
        Button("聚焦另一窗格") { model.focusOtherPaneAndContent() }.disabled(
          !model.layout.isSplit)
        Button("关闭聚焦窗格") { model.closePane(model.focusedPane.id) }.disabled(
          !model.layout.isSplit)
        Button("单窗格") { model.returnToSinglePane() }.disabled(!model.layout.isSplit)
        Button("交换窗格") { model.swapPanes() }.disabled(!model.layout.isSplit)
        Divider()
        Button("缩窄左侧") { model.setSplitRatio(model.layout.splitRatio - 0.05) }.disabled(
          !model.layout.isSplit)
        Button("扩大左侧") { model.setSplitRatio(model.layout.splitRatio + 0.05) }.disabled(
          !model.layout.isSplit)
        Button("重置比例") { model.setSplitRatio(0.5) }.disabled(!model.layout.isSplit)
      } label: {
        Image(systemName: "rectangle.split.2x1").frame(minWidth: 28, minHeight: 28)
      }
      .menuStyle(.borderlessButton)
      .padding(.horizontal, 6).padding(.vertical, 4)
      .studioGlassCapsule()
      .accessibilityLabel("布局")
      .accessibilityIdentifier("layout.menu")
      .popover(isPresented: $model.splitPickerPresented) {
        SplitResourcePicker(model: model)
      }
    }.sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .primaryAction) {
      if !model.isCompactMode {
        Button {
          model.toggleQuestionPanel()
        } label: {
          HStack(spacing: 4) {
            if model.agentController.isRequesting { ProgressView().controlSize(.small) }
            Image(systemName: "person.2")
          }
        }.studioGlassButton().frame(minWidth: 28, minHeight: 28).help("切换问答（⌘⌥A）")
          .accessibilityLabel(model.agentController.isRequesting ? "AI 请求进行中，打开问答" : "切换问答")
          .accessibilityValue(model.agentController.isRequesting ? "有请求进行中" : (model.agentsVisible ? "已显示" : "已隐藏"))
          .accessibilityIdentifier("agents.button")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      if model.isCompactMode {
        HStack(spacing: 4) {
          Button("内容") { model.hideQuestionPanel() }
            .accessibilityIdentifier("workspace.showContent")
          Button {
            model.showQuestionPanel()
          } label: {
            HStack(spacing: 4) {
              if model.agentController.isRequesting { ProgressView().controlSize(.small) }
              Text(model.agentController.isRequesting ? "问答（请求中）" : "问答")
            }
          }
          .accessibilityIdentifier("workspace.showQuestions")
        }
        .controlSize(.small)
      }
    }
  }

  private func icon(for tab: StudioTab?) -> String {
    guard let tab else { return studioResourceSymbol(.web) }
    if let record = model.webRuntimes.records[tab.id] {
      return studioResourceSymbol(record.kind)
    }
    return studioResourceSymbol(tab.destination)
  }
}

private struct TabStrip: View {
  @ObservedObject var model: StudioModel
  let compact: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var selectionNamespace
  @State private var collapsedWorkspaceIDs: Set<UUID> = []
  @State private var diagnosticsPresented = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if !compact {
          Text("工作空间").font(.headline)
        }
        Spacer()
        Button {
          model.addGroup()
        } label: {
          Image(systemName: "rectangle.stack.badge.plus").frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressButtonStyle()).help("新建工作空间")
        .accessibilityLabel("新建工作空间")
        .accessibilityIdentifier("groups.new")
      }
      HStack(spacing: 6) {
        Button("网页") { model.newTab() }.buttonStyle(.bordered)
        Button("终端") { model.newTerminal(directory: nil) }.buttonStyle(.bordered)
        Button("SSH") { model.openSSHDestination() }.buttonStyle(.bordered)
      }
      if !model.windowCoordinator.registry.diagnosticEntries.isEmpty || model.isRescanningWorkspaceDirectory {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Button(
            model.isRescanningWorkspaceDirectory
              ? "正在扫描配置…" : "配置诊断（\(model.windowCoordinator.registry.diagnosticEntries.count)）"
          ) {
            diagnosticsPresented = true
          }
          .buttonStyle(.borderless)
          .disabled(model.isRescanningWorkspaceDirectory)
          .accessibilityIdentifier("workspace.diagnostics")
          .help("查看配置读取诊断")
        }
      }
      if let error = model.windowCoordinator.registry.restorationError {
        Text("恢复失败：\(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      if !model.windowCoordinator.registry.loadDiagnostics.isEmpty {
        Text("部分空间读取失败（可重试）").font(.caption).foregroundStyle(.red)
      }
      if !model.windowCoordinator.registry.recoveryWorkspaceIDs.isEmpty {
        Text("已从备份恢复配置").font(.caption).foregroundStyle(.orange)
      }
      HStack(spacing: 6) {
        Circle().fill(saveColor).frame(width: 7, height: 7)
        Text(saveLabel).font(.caption).foregroundStyle(.secondary)
        if case .failed = model.workspaceSaveState {
          Button("重试保存") { model.retryWorkspaceSave() }.font(.caption)
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.groups) { group in
            VStack(
              alignment: .leading,
              spacing: 3
            ) {
              HStack(spacing: 2) {
                Button {
                  model.selectGroup(group.id)
                } label: {
                  if compact {
                    Image(systemName: "square.stack.3d.up")
                  } else {
                    HStack(spacing: 5) {
                      Label(group.name, systemImage: "square.stack.3d.up")
                      if let owner = model.windowCoordinator.registry.session(for: group.id) {
                        Text(
                          "\(owner.resourceStore.liveTerminalCount)终端 · \(owner.agentController.isRequesting ? 1 : 0)请求"
                        )
                        .font(.caption2).foregroundStyle(.secondary)
                      }
                    }
                  }
                }.buttonStyle(StudioPressButtonStyle()).help(group.name)
                  .accessibilityAddTraits(model.selectedGroupID == group.id ? .isSelected : [])
                  .accessibilityLabel("工作空间 \(group.name)")
                  .accessibilityIdentifier("group.\(group.id.uuidString)").frame(
                    maxWidth: .infinity,
                    alignment: .leading
                  ).lineLimit(1)
                Button {
                  model.newTab(in: group.id)
                } label: {
                  Image(systemName: studioResourceSymbol(.web)).frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressButtonStyle())
                .help("在\(group.name)中新建网页（⌘T）")
                .accessibilityLabel("在\(group.name)中新建网页")
                .accessibilityIdentifier("tabs.new.\(group.id.uuidString)")
                Button {
                  model.newTerminal(in: group.id)
                } label: {
                  Image(systemName: studioResourceSymbol(.localTerminal)).frame(
                    minWidth: 24, minHeight: 24
                  ).contentShape(Rectangle())
                }
                .buttonStyle(StudioPressButtonStyle())
                .help("在\(group.name)中新建终端（⌘⇧T）")
                .accessibilityLabel("在\(group.name)中新建终端")
                .accessibilityIdentifier("terminals.new.\(group.id.uuidString)")
                Button {
                  if collapsedWorkspaceIDs.contains(group.id) {
                    collapsedWorkspaceIDs.remove(group.id)
                  } else {
                    collapsedWorkspaceIDs.insert(group.id)
                  }
                } label: {
                  Image(systemName: collapsedWorkspaceIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(StudioPressButtonStyle())
                .accessibilityLabel("折叠空间 \(group.name)")
                .accessibilityIdentifier("workspace.fold.\(group.id.uuidString)")
              }
              .padding(.horizontal, compact ? 0 : 6)
              .background(
                model.selectedGroupID == group.id ? StudioDesign.Color.groupSelectedFill : .clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .animation(
                StudioDesign.Motion.animation(
                  StudioDesign.Motion.hover, reduceMotion: reduceMotion),
                value: model.selectedGroupID
              )
              .contextMenu {
                Button("重命名空间") { model.beginRenameGroup(group.id) }
                Button("关闭空间…") { model.closeWorkspace(group.id) }
                Button("归档空间") { model.archiveWorkspace(group.id) }
              }
              if model.selectedGroupID == group.id && !collapsedWorkspaceIDs.contains(group.id) {
                Text("常用入口").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                if model.pinnedDestinations.isEmpty {
                  Button("添加常用入口") { model.openStartEntryPanel() }
                    .buttonStyle(.plain).padding(.leading, 14)
                    .accessibilityIdentifier("pinned.add")
                }
                ForEach(model.pinnedDestinations) { pin in
                  Button(pin.title) { model.openPinnedDestinationInWorkspace(pin) }
                    .buttonStyle(.plain).padding(.leading, 14)
                    .accessibilityIdentifier("pinned.\(pin.id.uuidString)")
                }
                ForEach(model.visibleTabs) { tab in
                  ResourceRow(
                    model: model, tab: tab, compact: compact, selectionNamespace: selectionNamespace
                  )
                }
              }
            }
          }
        }
      }
      if !model.windowCoordinator.registry.archivedEntries.isEmpty {
        Divider()
        Text("已归档").font(.caption).foregroundStyle(.secondary)
        ForEach(model.windowCoordinator.registry.archivedEntries) { entry in
          Button(entry.name) { model.restoreArchivedWorkspace(entry.id) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityIdentifier("archived.\(entry.id.uuidString)")
        }
      }
      Spacer()
    }.padding(10)
      .studioShellScrim()
      .popover(isPresented: $diagnosticsPresented) {
        WorkspaceDiagnosticsView(model: model)
      }
  }

  private var saveLabel: String {
    if model.session.isTemporary { return "临时空间 · 配置仅在本次运行" }
    switch model.workspaceSaveState {
    case .saving: return "保存中…"
    case .failed: return "未保存"
    case .saved, .clean: return "已保存"
    case .dirty: return "未保存改动"
    case nil: return "保存状态未知"
    }
  }
  private var saveColor: Color {
    if model.session.isTemporary { return .orange }
    if case .failed = model.workspaceSaveState { return .red }
    return .secondary
  }

}

private struct SplitResourcePicker: View {
  @ObservedObject var model: StudioModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("选择并排资源").font(.headline)
      ForEach(model.visibleTabs) { tab in
        Button(tab.displayTitle) { model.chooseSplitResource(tab.id) }
          .buttonStyle(.plain)
          .accessibilityIdentifier("split.choose.\(tab.id.uuidString)")
      }
      Divider()
      Button("新建网页") { model.splitWithNewWeb() }
      Button("新建终端") { model.splitWithNewTerminal() }
    }
    .padding(12)
    .frame(minWidth: 220)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("split.resourcePicker")
  }
}

private struct ResourceRow: View {
  @ObservedObject var model: StudioModel
  let tab: StudioTab
  let compact: Bool
  let selectionNamespace: Namespace.ID
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var endCapture: StudioModel.TerminalActionCapture?
  var body: some View {
    let selected = model.selectedTabID == tab.id
    let record = model.webRuntimes.records[tab.id]
    let symbol =
      record.map { studioResourceSymbol($0.kind) } ?? studioResourceSymbol(tab.destination)
    return HStack(spacing: 3) {
      Button {
        model.selectedTabID = tab.id
      } label: {
        HStack(spacing: 7) {
          Image(systemName: symbol).accessibilityHidden(true)
          if !compact { Text(tab.displayTitle).lineLimit(1) }
          if model.layout.primary.resourceID == tab.id { Text("左").font(.caption2).foregroundStyle(.secondary) }
          if model.layout.secondary?.resourceID == tab.id { Text("右").font(.caption2).foregroundStyle(.secondary) }
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(StudioPressButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("资源 \(tab.displayTitle)").accessibilityIdentifier(
          "resource.\(tab.id.uuidString)")
      Button {
        model.close(tabID: tab.id)
      } label: {
        Image(systemName: "xmark").font(.caption2).frame(minWidth: 24, minHeight: 24).contentShape(
          Rectangle())
      }.buttonStyle(StudioPressButtonStyle()).accessibilityLabel(
        "关闭资源 \(tab.displayTitle)"
      ).accessibilityIdentifier("resource.close.\(tab.id.uuidString)").help("关闭资源")
    }.padding(.leading, compact ? 0 : 14).padding(.horizontal, 4).padding(.vertical, 3).frame(
      maxWidth: .infinity, alignment: .leading
    )
    .background(
      selected ? StudioDesign.Color.selectedFill : .clear,
      in: RoundedRectangle(cornerRadius: StudioDesign.Radius.row, style: .continuous)
    )
    .overlay(alignment: .leading) {
      if selected {
        Capsule().fill(Color.accentColor).frame(width: 3, height: 18)
          .matchedGeometryEffect(id: "resource-selection", in: selectionNamespace)
      }
    }
    .animation(
      StudioDesign.Motion.animation(StudioDesign.Motion.selection, reduceMotion: reduceMotion),
      value: selected
    )
    .contextMenu {
      Button("重命名资源") { model.openResourceEditor(tab.id) }
      if let record, record.kind != .web, record.lifecycle != .idle {
        Button("结束会话") {
          endCapture = model.captureTerminalEnd(resourceID: tab.id)
        }.disabled(model.pendingResourceIDs.contains(tab.id))
      }
      Button("在左侧显示") { model.showResource(tab.id, in: model.layout.primary) }
        .disabled(model.layout.primary.resourceID == tab.id)
      if let secondary = model.layout.secondary {
        Button("在右侧显示") { model.showResource(tab.id, in: secondary) }
          .disabled(secondary.resourceID == tab.id)
      } else {
        Button("在右侧显示") { model.showResourceOnRight(tab.id) }
      }
      Menu("复制入口到其他空间") {
        ForEach(model.groups.filter { $0.id != model.session.id }) { group in
          Button(group.name) { model.copyResourceToWorkspace(tab.id, targetID: group.id) }
        }
      }
      Button("添加到问答") {
        model.showQuestionPanel()
        model.agentController.addResource(tab.id)
      }

    }
    .confirmationDialog(
      "结束此终端会话？",
      isPresented: Binding(
        get: { endCapture != nil }, set: { if !$0 { endCapture = nil } })
    ) {
      Button("结束会话", role: .destructive) {
        guard let capture = endCapture else { return }
        endCapture = nil
        Task { @MainActor in
          _ = await model.endResourceSession(
            owner: capture.owner, resourceID: capture.resourceID,
            expectedInstanceID: capture.instanceID)
        }
      }
      Button("取消", role: .cancel) { endCapture = nil }
    } message: {
      Text("将停止 shell 和其子进程，资源与布局会保留。")
    }
  }

}

private struct GroupEditor: View {
  @ObservedObject var model: StudioModel
  @State private var name = ""
  @State private var directory = ""
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(model.creatingGroup ? "新建空间" : "重命名空间").font(.headline)
      StudioFieldLabel(title: "名称")
      TextField(
        "空间名称",
        text: $name
      ).textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit {
          _ = model.commitWorkspaceEditor(
            name: name, directory: directory.isEmpty ? nil : directory, targetID: targetID,
            creating: model.creatingGroup)
        }
      StudioFieldLabel(title: "关联目录")
      HStack {
        Text(directory.isEmpty ? "未设置（终端使用主目录）" : directory)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button("选择…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
          }
        }.buttonStyle(.bordered)
        Button("清除") {
          directory = ""
        }.buttonStyle(.bordered).disabled(directory.isEmpty)
      }
      Text("各工作空间使用共享 WebKit 网站数据；临时空间不隔离登录。")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Text(targetID.map { model.saveLabel(for: $0) } ?? "临时空间：命名后保存配置").font(.caption).foregroundStyle(.secondary)
        if targetArchived { Text("已归档").font(.caption).foregroundStyle(.orange) }
        Spacer()
        if let targetID, case .failed = model.saveState(for: targetID) {
          Button("重试保存") { model.retrySave(for: targetID) }.font(.caption)
        }
        if !model.creatingGroup {
          Button("归档") { if let targetID { model.archiveWorkspace(targetID) } }
            .buttonStyle(.bordered).disabled(model.creatingGroup || targetArchived || targetTemporary)
        }
      }
      HStack {
        Button("取消") {
          model.creatingGroup = false
          model.groupEditorPresented = false
        }.studioGlassButton()
        Spacer()
        Button("保存") {
          _ = model.commitWorkspaceEditor(
            name: name, directory: directory.isEmpty ? nil : directory,
            targetID: targetID, creating: model.creatingGroup)
        }.studioGlassButton(prominent: true).keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(StudioDesign.Spacing.inset).onAppear {
      name = targetID.flatMap { id in model.groups.first(where: { $0.id == id })?.name } ?? ""
      directory = targetID.flatMap { id in model.windowCoordinator.registry.session(for: id)?.directory } ?? ""
      DispatchQueue.main.async { if model.panels.panel == .groupEditor { focused = true } }
    }
    .frame(width: 300)
    .onExitCommand {
      model.creatingGroup = false
      model.groupEditorPresented = false
    }
  }
  private var targetID: UUID? { model.editingGroupID }
  private var targetArchived: Bool {
    targetID.flatMap { model.windowCoordinator.registry.session(for: $0)?.archived } ?? false
  }
  private var targetTemporary: Bool {
    targetID.flatMap { model.windowCoordinator.registry.session(for: $0)?.isTemporary } ?? true
  }
}

private struct ResourceEditor: View {
  @ObservedObject var model: StudioModel
  @State private var title = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("重命名资源").font(.headline)
      if let error { StudioInlineFeedback(message: error, isError: true) }
      StudioFieldLabel(title: "资源名称")
      TextField("资源名称", text: $title).textFieldStyle(.roundedBorder).focused($focused)
        .accessibilityIdentifier("resource.rename.field")
      HStack {
        Button("取消") { model.dismissPanel() }.studioGlassButton()
        Spacer()
        Button("保存") {
          guard let id = model.panelTargetResourceID, model.webRuntimes.records[id] != nil else {
            error = "资源已关闭。"
            return
          }
          model.renameResource(id, title: title)
          model.dismissPanel()
        }
        .studioGlassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(StudioDesign.Spacing.inset).frame(width: 320)
      .onAppear {
        if let id = model.panelTargetResourceID, let record = model.webRuntimes.records[id] {
          title = record.customTitle ?? record.title
          DispatchQueue.main.async {
            if model.panels.panel == .resourceEditor(id) { focused = true }
          }
        } else {
          error = "资源已关闭。"
        }
      }
      .onExitCommand { model.dismissPanel() }
  }
}

private struct TabContent: View {
  @ObservedObject var model: StudioModel
  var body: some View {
    WorkspaceSplitView(model: model)
  }
}

struct TerminalSessionView: View {
  @ObservedObject var model: StudioModel
  let resourceID: UUID
  @ObservedObject var session: TerminalSession
  @State private var confirmEnd = false
  @State private var ending = false
  @State private var endCapture: StudioModel.TerminalActionCapture?
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if case .failed(let message) = session.state {
        Text(message).foregroundStyle(.red).padding(.horizontal, 8)
      }
      if !statusText.isEmpty {
        Text(statusText).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
      }
      if isRestartable {
        Button("重新启动") {
          let capture = model.captureTerminalEnd(resourceID: resourceID)
          Task { @MainActor in
            guard let capture else { return }
            _ = await model.restartResourceSession(
              owner: capture.owner, resourceID: capture.resourceID,
              expectedInstanceID: capture.instanceID)
          }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("resource.restart.\(resourceID.uuidString)")
      }
      if session.state != .idle {
        Button(ending ? "正在结束…" : "结束会话") {
          endCapture = model.captureTerminalEnd(resourceID: resourceID)
          confirmEnd = endCapture != nil
        }
        .buttonStyle(.bordered)
        .disabled(ending || model.pendingResourceIDs.contains(resourceID))
        .confirmationDialog("结束此终端会话？", isPresented: $confirmEnd) {
          Button("结束会话", role: .destructive) {
            let capture = endCapture
            endCapture = nil
            ending = true
            Task { @MainActor in
              if let capture {
                _ = await model.endResourceSession(
                  owner: capture.owner, resourceID: capture.resourceID,
                  expectedInstanceID: capture.instanceID)
              }
              ending = false
            }
          }
          Button("取消", role: .cancel) {}
        } message: {
          Text("将停止 shell 和其子进程，资源与布局会保留。")
        }
        .accessibilityIdentifier("resource.end-session.\(resourceID.uuidString)")
      }
      TerminalNativeView(view: session.nativeView)
    }
  }
  private var statusText: String {
    switch session.state {
    case .starting: "终端启动中…"
    case .running: ""
    case .exited(let code): code.map { "已退出（\($0)）" } ?? "已退出（状态不可用）"
    case .interrupted: "已中断"
    case .failed: "终端失败"
    case .idle: "空闲"
    }
  }
  private var isRestartable: Bool {
    switch session.state {
    case .exited, .failed, .interrupted: true
    default: false
    }
  }
}

struct TerminalStartPlaceholder: View {
  @ObservedObject var model: StudioModel
  let resourceID: UUID
  let record: ResourceRecord
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal").font(.system(size: 30)).foregroundStyle(.secondary)
      Text(
        record.lifecycle == .failed
          ? (record.errorMessage ?? "终端不可用") : (record.kind == .sshTerminal ? "尚未连接" : "终端尚未启动")
      )
      .foregroundStyle(record.lifecycle == .failed ? .red : .secondary)
      if record.lifecycle == .failed, case .localTerminal(let directory) = record.location,
        let directory, !directory.isEmpty
      {
        Text("原目录：\(directory)").font(.caption).foregroundStyle(.secondary)
          .lineLimit(2).textSelection(.enabled)
      }
      if record.lifecycle == .failed, record.kind == .localTerminal {
        Button("重新选择目录并启动…") { model.repairTerminalDirectory(resourceID: resourceID) }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("resource.repair-directory.\(resourceID.uuidString)")
      }
      Button(record.kind == .sshTerminal ? "连接" : "启动终端") {
        let owner = model.session
        let store = owner.resourceStore
        Task { @MainActor in
          guard !owner.isClosed, !model.windowCoordinator.isClosing,
            model.windowCoordinator.loadedSessions[owner.id] === owner,
            !model.pendingResourceIDs.contains(resourceID), store.records[resourceID] != nil
          else { return }
          _ = await store.startResource(resourceID: resourceID)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.pendingResourceIDs.contains(resourceID))
      .accessibilityIdentifier("resource.start.\(resourceID.uuidString)")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
private struct TerminalNativeView: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NativeResourceContainer {
    let container = NativeResourceContainer()
    container.mount(view)
    return container
  }
  func updateNSView(_ nsView: NativeResourceContainer, context: Context) { nsView.mount(view) }
  static func dismantleNSView(_ nsView: NativeResourceContainer, coordinator: ()) {
    nsView.unmount()
  }
}

private struct DisconnectedPlaceholder: View {
  let icon: String
  let title: String
  let detail: String
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
      Text(title)
        .font(.title3.weight(.semibold))
      Text(detail).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 380)
    }.padding(28)
      .accessibilityIdentifier("runtime.placeholder")
  }
}

private struct DestinationPopover: View {
  @ObservedObject var model: StudioModel
  @State private var mode =
    0
  @State private var webAddress = ""
  @State private var sshHost =
    ""
  @State private var sshUser = ""
  @State private var sshPort =
    "22"
  @State private var error: String?
  @FocusState private var focusedField: Field?
  private enum Field {
    case web, host, port
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("打开目的地")
        .font(.headline)
      Text("目标：\(targetTitle)").font(.caption).foregroundStyle(.secondary)
      if let panelError = model.panels.errorMessage {
        Text(panelError).font(.caption).foregroundStyle(.red)
      }
      Picker("模式", selection: $mode) {
        Text("网页").tag(0)
        Text("SSH").tag(1)
      }.pickerStyle(.segmented)
        .accessibilityIdentifier("destination.mode")
      if mode == 0 {
        StudioFieldLabel(title: "网页地址")
        TextField("https://example.com", text: $webAddress).textFieldStyle(.roundedBorder)
          .focused(
            $focusedField,
            equals: .web
          ).accessibilityIdentifier("web.address")
          .onSubmit { submitWeb() }
        Text(
          "请输入 URL 或域名。终端目标会打开关联网页并保持终端打开。"
        ).font(.caption)
          .foregroundStyle(.secondary)
      } else {
        StudioFieldLabel(title: "SSH 主机")
        TextField("主机", text: $sshHost).textFieldStyle(.roundedBorder).focused(
          $focusedField,
          equals: .host
        ).accessibilityIdentifier("ssh.host")
          .accessibilityLabel("SSH 主机")
        StudioFieldLabel(title: "用户（可选）")
        TextField("用户（可选）", text: $sshUser)
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("ssh.user")
        StudioFieldLabel(title: "端口")
        TextField(
          "端口",
          text: $sshPort
        ).textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("ssh.port")
          .focused($focusedField, equals: .port)
        Text(
          "Only connection settings are stored in memory."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Group {
        if let error {
          StudioInlineFeedback(message: error, isError: true)
        } else {
          Text(" ").font(.caption)
        }
      }
      .frame(height: 30, alignment: .top)
      HStack {
        Button("取消") { model.destinationPresented = false }.studioGlassButton()
        Spacer()
          .accessibilityIdentifier("destination.cancel")
        Button("打开") { submit() }
          .studioGlassButton(prominent: true).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("destination.open")
      }
    }.padding(StudioDesign.Spacing.inset).frame(width: 330)
      .onAppear {
        prefill()
        DispatchQueue.main.async {
          if model.panels.panel == .destination { focusedField = mode == 0 ? .web : .host }
        }
      }
      .onChange(of: mode) { _, newMode in
        error = nil
        focusedField = newMode == 0 ? .web : .host
      }
      .onExitCommand { model.destinationPresented = false }
  }

  private func submit() {
    if mode == 0 {
      submitWeb()
    } else if let destination = StudioModel.normalizedSSH(
      host: sshHost,
      user: sshUser,
      portText: sshPort
    ) {
      model.setDestination(destination)
    } else {
      error = "请输入有效的主机和端口（1–65535）。"
      focusedField = sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .host : .port
    }
  }

  private func submitWeb() {
    if let url = StudioModel.normalizedWebURL(webAddress) {
      model.setDestination(.web(url))
    } else {
      error = "请输入有效的 HTTP 或 HTTPS URL。"
      focusedField = .web
    }
  }

  private func prefill() {
    guard let id = model.panelTargetResourceID,
      let destination = model.tabs.first(where: { $0.id == id })?.destination
    else { return }
    switch destination {
    case .terminal:
      mode = 0
      webAddress = ""
    case .web(let url):
      mode = 0
      webAddress = url.absoluteString
    case .ssh(
      let
        host,
      let

        user,
      let

        port
    ):
      mode = 1
      sshHost = host
      sshUser = user
      sshPort = String(port)
    case .blank: break
    }
  }

  private var targetTitle: String {
    guard let id = model.panelTargetResourceID else { return "无" }
    return model.tabs.first(where: { $0.id == id })?.displayTitle ?? "资源已关闭"
  }
}

private struct CommandSearchField: NSViewRepresentable {
  @ObservedObject var model: StudioModel

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: model.commandQuery)
    field.placeholderString = "搜索命令"
    field.isBordered = true
    field.bezelStyle = .roundedBezel
    field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    field.delegate = context.coordinator
    field.setAccessibilityLabel("搜索命令")
    field.setAccessibilityIdentifier("command.search")
    model.commandSearchField = field
    return field
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    let active = model.panels.panel == .commands
    field.isEnabled = active
    if !active, let window = field.window,
      window.firstResponder === field || field.currentEditor() === window.firstResponder,
      let fallback = model.workspaceFocusView, fallback.window === window
    {
      window.makeFirstResponder(fallback)
    }
    if field.stringValue != model.commandQuery,
      (field.currentEditor() as? NSTextView)?.hasMarkedText() != true
    {
      field.stringValue = model.commandQuery
    }
  }
  static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
    if coordinator.model.commandSearchField === field { coordinator.model.commandSearchField = nil }
  }
  final class Coordinator: NSObject, NSTextFieldDelegate {
    let model: StudioModel
    init(model: StudioModel) { self.model = model }
    func controlTextDidChange(_ notification: Notification) {
      guard model.panels.panel == .commands else { return }
      guard let field = notification.object as? NSTextField else { return }
      guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      model.commandQuery = field.stringValue
      model.commandSelectedIndex = 0
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
      -> Bool
    {
      guard model.panels.panel == .commands, !textView.hasMarkedText() else { return false }
      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        model.commandSelectedIndex = max(0, model.commandSelectedIndex - 1)
        return true
      case #selector(NSResponder.moveDown(_:)):
        model.commandSelectedIndex = min(
          max(model.filteredCommandCount - 1, 0), model.commandSelectedIndex + 1)
        return true
      case #selector(NSResponder.insertNewline(_:)):
        model.executeSelectedCommand()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        model.dismissPanel()
        return true
      default: return false
      }
    }
  }
}

private struct WorkspaceDiagnosticsView: View {
  @ObservedObject var model: StudioModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("配置诊断").font(.headline)
        Spacer()
        Button(model.isRescanningWorkspaceDirectory ? "扫描中…" : "重新扫描") {
          model.rescanWorkspaceDirectory()
        }
        .buttonStyle(.bordered)
        .disabled(model.isRescanningWorkspaceDirectory)
        .accessibilityIdentifier("workspace.diagnostics.rescan")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.windowCoordinator.registry.diagnosticEntries) { diagnostic in
            VStack(alignment: .leading, spacing: 4) {
              Text(diagnostic.detail).font(.subheadline)
              if let fileURL = diagnostic.fileURL {
                Text(fileURL.path).font(.caption).foregroundStyle(.secondary)
                  .textSelection(.enabled)
                Button("定位配置文件") { model.revealWorkspaceDiagnostic(diagnostic) }
                  .buttonStyle(.borderless)
                  .accessibilityIdentifier("workspace.diagnostics.locate.\(diagnostic.id)")
              }
            }
            if diagnostic.id != model.windowCoordinator.registry.diagnosticEntries.last?.id {
              Divider()
            }
          }
        }
      }
      .frame(minWidth: 360, minHeight: 120, maxHeight: 300)
      if model.windowCoordinator.registry.diagnosticEntries.isEmpty {
        Text("未发现配置诊断").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
  }
}

private struct CommandPalette: View {
  @ObservedObject var model: StudioModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("命令面板").font(.headline)
      Text("目标：\(targetTitle)").font(.caption).foregroundStyle(.secondary)
      if let panelError = model.panels.errorMessage {
        Text(panelError).font(.caption).foregroundStyle(.red)
      }
      HStack(spacing: 6) {
        CommandSearchField(model: model).frame(maxWidth: .infinity, minHeight: 22)
        if !model.commandQuery.isEmpty {
          Button {
            model.commandQuery = ""
            model.commandSelectedIndex = 0
            if let field = model.commandSearchField, let window = field.window {
              window.makeFirstResponder(field)
            }
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("清除搜索")
          .accessibilityIdentifier("command.search.clear")
        }
      }
      Picker("搜索范围", selection: $model.searchAllWorkspaces) {
        Text("当前空间").tag(false)
        Text("全部空间").tag(true)
      }.pickerStyle(.segmented).onChange(of: model.searchAllWorkspaces) { _, _ in
        model.searchConfigurations(model.commandQuery)
      }
      if filtered.isEmpty {
        Text("没有可用命令").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(
                Array(filtered.enumerated()),
                id: \.element.id
              ) { index, item in
                if index == 0 || isResource(item) != isResource(filtered[index - 1]) {
                  Text(isResource(item) ? "资源" : "操作")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 4)
                }
                Button {
                  run(item.id)
                } label: {
                  HStack(spacing: 8) {
                    Image(systemName: icon(for: item))
                      .frame(width: 20)
                      .foregroundStyle(.secondary)
                      .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                      Text(item.title).lineLimit(1)
                      if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                      }
                    }
                    Spacer(minLength: 8)
                    Text(item.shortcut)
                      .foregroundStyle(.secondary)
                      .font(.caption)
                  }
                  .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .background(
                  index == model.commandSelectedIndex
                    ? Color(nsColor: .controlBackgroundColor) : .clear,
                  in: RoundedRectangle(cornerRadius: 5)
                )
                .id(item.id)
                .accessibilityIdentifier(accessibilityIdentifier(for: item))
              }
            }
            .padding(.vertical, 2)
          }
          .frame(height: commandListHeight)
          .accessibilityIdentifier("command.results")
          .onChange(of: model.commandSelectedIndex) { _, index in
            guard filtered.indices.contains(index) else { return }
            withAnimation(
              StudioDesign.Motion.animation(
                StudioDesign.Motion.selection, reduceMotion: reduceMotion)
            ) { proxy.scrollTo(filtered[index].id, anchor: .center) }
          }
        }
      }
    }
    .padding(StudioDesign.Spacing.inset)
    .frame(width: 320)
    .onExitCommand { model.commandPalettePresented = false }
    .onChange(of: model.commandQuery) { _, query in model.searchConfigurations(query) }
  }

  private var filtered: [StudioCommand] {
    model.paletteCommands
      .filter {
        model.commandQuery.isEmpty || $0.searchText.localizedCaseInsensitiveContains(model.commandQuery)
      }
  }

  private var commandListHeight: CGFloat {
    min(max(CGFloat(filtered.count) * 34 + 28, 40), 360)
  }

  private func isResource(_ command: StudioCommand) -> Bool {
    if case .selectWorkspaceResource = command.action { return true }
    return false
  }

  private func accessibilityIdentifier(for command: StudioCommand) -> String {
    if case .selectWorkspaceResource(let workspaceID, let resourceID) = command.action {
      return "command.resource.\(workspaceID.uuidString).\(resourceID.uuidString)"
    }
    return "command.\(command.title)"
  }

  private var targetTitle: String {
    guard let id = model.panelTargetResourceID else { return "无" }
    return model.tabs.first(where: { $0.id == id })?.displayTitle ?? "资源已关闭"
  }

  private func icon(for command: StudioCommand) -> String {
    switch command.action {
    case .newTab: return studioResourceSymbol(.web)
    case .newTerminal: return studioResourceSymbol(.localTerminal)
    case .newGroup: return "rectangle.stack.badge.plus"
    case .closeResource: return "xmark"
    case .openDestination: return "arrow.up.forward"
    case .selectResource(let resourceID):
      guard let record = model.webRuntimes.records[resourceID] else {
        return studioResourceSymbol(.web)
      }
      return studioResourceSymbol(record.kind)
    case .selectWorkspaceResource: return "arrow.down.right.and.arrow.up.left"
    case .back: return "chevron.left"
    case .forward: return "chevron.right"
    case .reload: return "arrow.clockwise"
    case .stop: return "xmark"
    case .toggleSidebar: return "sidebar.leading"
    case .toggleAgents: return "person.2"
    }
  }

  private func run(_ commandID: String) {
    guard let index = filtered.firstIndex(where: { $0.id == commandID }) else { return }
    model.commandSelectedIndex = index
    model.executeSelectedCommand()
  }
}
