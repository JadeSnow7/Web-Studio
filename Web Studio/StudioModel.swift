import AppKit
import Combine
import Darwin
import Foundation

@MainActor final class StudioModel: ObservableObject {
  @Published private(set) var session: WorkspaceSession
  let windowCoordinator: WindowCoordinator
  var groups: [StudioGroup] {
    windowCoordinator.registry.entries.map { StudioGroup(id: $0.id, name: $0.name) }
      .sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name }
  }
  /// Compatibility projection; ResourceStore is the canonical ordered resource model.
  var tabs: [StudioTab] {
    webRuntimes.order.compactMap { id in
      guard let record = webRuntimes.records[id] else { return nil }
      let destination: StudioDestination
      switch record.location {
      case .web(let url): destination = url.map(StudioDestination.web) ?? .blank
      case .ssh(let host, let user, let port):
        destination = .ssh(host: host, user: user, port: port)
      case .localTerminal(let directory): destination = .terminal(directory: directory ?? "")
      }
      return StudioTab(
        id: id, groupID: record.groupID, destination: destination,
        pageTitle: record.customTitle ?? (record.title == destination.title ? nil : record.title))
    }
  }
  var selectedGroupID: UUID {
    get { session.id }
    set { if newValue != session.id { selectWorkspace(newValue) } }
  }
  var layout: WorkspaceLayout {
    get { session.layout }
    set { session.layout = newValue }
  }
  var selectedTabID: UUID {
    get {
      layout.secondary?.isFocused == true
        ? (layout.secondary?.resourceID ?? layout.primary.resourceID ?? layout.primary.id)
        : (layout.primary.resourceID ?? layout.primary.id)
    }
    set { selectResource(newValue) }
  }
  /// Navigation state of the selected tab's web runtime, mirrored here so the toolbar
  /// re-renders without observing a runtime that may not exist yet. Holds `toolbarMirror`
  /// (no load progress), so progress ticks don't invalidate every view observing the model.
  @Published var activeWebState = WebNavigationState()
  private var webStates: [UUID: WebNavigationState] = [:]
  /// One WKWebView per live web tab.
  var webRuntimes: WebRuntimeStore { session.resourceStore }
  var agentController: AgentController { session.agentController }
  var providerSettings: ProviderSettings { windowCoordinator.registry.providerSettings }
  var workspaceSaveState: WorkspaceSaveState? {
    windowCoordinator.registry.saveController(for: session.id)?.state
  }
  func saveState(for id: UUID) -> WorkspaceSaveState? {
    windowCoordinator.registry.saveController(for: id)?.state
  }
  var saveLabelForSettings: String {
    if session.isTemporary { return "临时空间：命名后保存配置" }
    switch workspaceSaveState {
    case .saving: return "保存中…"
    case .failed: return "未保存"
    case .dirty: return "有未保存改动"
    case .saved, .clean: return "已保存"
    case nil: return "保存状态未知"
    }
  }
  func retryWorkspaceSave() {
    retrySave(for: session.id)
  }

  func rescanWorkspaceDirectory() {
    Task { @MainActor [weak self] in
      guard let self, !self.isRescanningWorkspaceDirectory else { return }
      self.isRescanningWorkspaceDirectory = true
      await self.windowCoordinator.registry.rescanDirectory()
      self.isRescanningWorkspaceDirectory = false
    }
  }

  func revealWorkspaceDiagnostic(_ diagnostic: WorkspaceDiagnostic) {
    guard let fileURL = diagnostic.fileURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }
  func retrySave(for id: UUID) {
    guard let controller = windowCoordinator.registry.saveController(for: id) else { return }
    Task { @MainActor in _ = await controller.retry() }
  }
  func saveLabel(for id: UUID) -> String {
    guard let target = windowCoordinator.registry.session(for: id) else { return "空间已关闭" }
    if target.isTemporary { return "临时空间：命名后保存配置" }
    switch saveState(for: id) {
    case .saving: return "保存中…"
    case .failed: return "未保存"
    case .dirty: return "有未保存改动"
    case .saved, .clean: return "已保存"
    case nil: return "保存状态未知"
    }
  }
  var workspaceSelectorStatus: String {
    if session.isTemporary { return session.isEmpty ? "空临时空间 · 未保存" : "临时空间 · 未保存" }
    return saveLabel(for: session.id)
  }
  var panels: PanelCoordinator { windowCoordinator.panels }
  private var sessionChanges: AnyCancellable?
  private var resourceChanges: AnyCancellable?
  private var panelChanges: AnyCancellable?
  private var directoryChanges: AnyCancellable?
  private var coordinatorChanges: AnyCancellable?
  private final class WeakSessionBinding {
    weak var session: WorkspaceSession?
    init(_ session: WorkspaceSession) {
      self.session = session
    }
  }
  private var sessionBindings: [UUID: WeakSessionBinding] = [:]
  @Published var workspaceNotice: String?
  @Published private(set) var isRescanningWorkspaceDirectory = false
  @Published var splitPickerPresented = false
  @Published var splitPickerWorkspaceID: UUID?
  /// Compact mode is a window-local presentation choice. It never changes the
  /// persisted `agentsVisible` preference.
  @Published private(set) var isCompactMode = false
  @Published private(set) var compactQuestionPanelVisible = false
  var tabStripVisible: Bool {
    get { session.tabStripVisible }
    set { session.tabStripVisible = newValue }
  }
  var agentsVisible: Bool {
    get { session.agentsVisible }
    set { session.agentsVisible = newValue }
  }
  var questionPanelVisible: Bool {
    isCompactMode ? compactQuestionPanelVisible : agentsVisible
  }
  func updateCompactMode(for width: CGFloat) {
    let compact = width < 1100
    guard compact != isCompactMode else { return }
    isCompactMode = compact
    if compact { compactQuestionPanelVisible = false }
  }
  func showQuestionPanel() {
    if isCompactMode { compactQuestionPanelVisible = true } else { agentsVisible = true }
    if let active = agentController.activeRequest, active.questionID != agentController.currentQuestionID {
      agentController.selectQuestion(active.questionID)
    }
  }
  func hideQuestionPanel() {
    if isCompactMode { compactQuestionPanelVisible = false } else { agentsVisible = false }
  }
  func toggleQuestionPanel() {
    if questionPanelVisible { hideQuestionPanel() } else { showQuestionPanel() }
  }
  var pinnedDestinations: [PinnedDestination] {
    get { session.pinnedDestinations }
    set { session.pinnedDestinations = newValue }
  }
  var recentResourceIDs: [UUID] { session.recentResourceIDs }
  /// The toolbar address field is a persistent control, so its edit target is
  /// captured independently of the current selection.
  @Published var addressText = ""
  @Published var addressError: String?
  @Published private(set) var addressFocusToken = 0
  @Published var commandQuery = ""
  @Published var commandSelectedIndex = 0
  @Published private(set) var configurationSearchResults: [WorkspaceConfiguration] = []
  @Published private(set) var searchResults: [WorkspaceResourceSearchResult] = []
  @Published var searchAllWorkspaces = true
  private var configurationSearchGeneration = 0
  private var selectionGeneration = 0
  private var searchSelectionTask: Task<Void, Never>?
  weak var commandSearchField: NSTextField?
  private var addressTargetResourceID: UUID?
  private var addressTargetPaneID: UUID?
  private var addressOriginalText = ""
  private var addressIsEditing = false
  @Published private(set) var pendingResourceIDs: Set<UUID> = []
  @MainActor final class TerminalActionCapture {
    let owner: WorkspaceSession
    let resourceID: UUID
    let instanceID: UUID?
    init(owner: WorkspaceSession, resourceID: UUID, instanceID: UUID?) {
      self.owner = owner
      self.resourceID = resourceID
      self.instanceID = instanceID
    }
  }
  var destinationPresented: Bool {
    get { panels.isDestinationPresented }
    set { if !newValue { dismissPanel() } }
  }
  var commandPalettePresented: Bool {
    get { panels.isCommandsPresented }
    set { if !newValue { dismissPanel() } }
  }
  var groupEditorPresented: Bool {
    get { panels.isGroupEditorPresented }
    set {
      if !newValue {
        creatingGroup = false
        dismissPanel()
      }
    }
  }
  var resourceEditorPresented: Bool {
    if case .resourceEditor = panels.panel { return true }
    return false
  }
  @Published var editingGroupID: UUID?
  @Published var creatingGroup = false
  /// Compatibility projections used by the existing native presentation modifiers.
  var panelTargetResourceID: UUID? { panels.targetResourceID }
  func dismissPanel(restoreFocus: Bool = true) {
    if panels.panel == .commands {
      invalidateSearchQuery()
      cancelSelection()
    }
    if panels.panel == .groupEditor { creatingGroup = false }
    if panels.panel == .providerSettings { resetProviderDraft() }
    if panels.panel == .commands, let field = commandSearchField, let window = field.window,
      window.firstResponder === field || field.currentEditor() === window.firstResponder,
      let fallback = workspaceFocusView, fallback.window === window
    {
      window.makeFirstResponder(fallback)
    }
    let fallbackView = workspaceFocusView
    let fallbackWindow = fallbackView?.window
    panels.close(
      window: NSApp.keyWindow, restoreFocus: restoreFocus,
      fallback: {
        guard let fallbackView, let fallbackWindow, fallbackView.window === fallbackWindow else {
          return
        }
        _ = fallbackWindow.makeFirstResponder(fallbackView)
      })
  }
  private func resetProviderDraft() {
    providerSettings.resetDraft()
  }
  func openProviderSettings() {
    resetProviderDraft()
    panels.open(
      .providerSettings, targetResourceID: nil, originalResponder: NSApp.keyWindow?.firstResponder,
      store: webRuntimes)
  }
  var agentsScope: String {
    "\(selectedGroup?.name ?? "当前空间") · \(selectedTab?.destination.title ?? "新标签页")"
  }

  @Published var sidebarWidth: CGFloat = 220
  @Published var agentsWidth: CGFloat = 300
  weak var workspaceFocusView: NSView?
  weak var addressInputField: NSTextField?
  init(launchTerminalProcesses: Bool = true, registry: WorkspaceRegistry? = nil) {
    let registry = registry ?? WorkspaceRegistry()
    let coordinator = WindowCoordinator(registry: registry)
    let initial = registry.create(launchTerminalProcesses: launchTerminalProcesses)
    session = initial
    windowCoordinator = coordinator
    _ = coordinator.open(initial.id)
    coordinator.onActivateWindow = { window in
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    coordinator.shouldSelectWorkspace = { [weak self] id in
      self?.prepareWorkspaceSwitch(to: id) ?? true
    }
    coordinator.onActiveSessionChanged = { [weak self] next in
      guard let self else { return }
      if let next {
        self.adoptSession(next)
      } else if self.windowCoordinator.canAcceptWorkspace {
        self.reconcileActiveWorkspace(launch: self.session.resourceStore.launchTerminalProcesses)
      }
    }
    panelChanges = panels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    directoryChanges = registry.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    coordinatorChanges = coordinator.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    bindSession(initial)
  }

  private func prepareWorkspaceSwitch(to id: UUID) -> Bool {
    guard id != session.id else { return true }
    if let panel = panels.panel {
      switch panel {
      case .commands, .agentResources, .agentPreview, .agentRunDetails:
        dismissPanel(restoreFocus: false)
      default:
        workspaceNotice = "请先完成或取消当前表单，再切换空间。输入内容已保留。"
        return false
      }
    }
    cancelAddressEditing()
    workspaceNotice = nil
    return true
  }

  private func adoptSession(_ next: WorkspaceSession) {
    guard next !== session else { return }
    session = next
    bindSession(next)
    addressText = focusedPane.resourceID.map(addressValue(for:)) ?? ""
    refreshActiveWebState()
  }

  func switchWorkspace(_ id: UUID) { selectWorkspace(id) }

  @discardableResult
  func createWorkspace(name: String = "临时空间", isTemporary: Bool = true) -> UUID? {
    guard prepareWorkspaceSwitch(to: UUID()),
      let created = windowCoordinator.createWorkspace(
        name: name, isTemporary: isTemporary,
        launchTerminalProcesses: webRuntimes.launchTerminalProcesses)
    else { return nil }
    adoptSession(created)
    return created.id
  }

  func selectWorkspace(_ id: UUID) {
    invalidateSearchQuery()
    cancelSelection()
    splitPickerPresented = false
    splitPickerWorkspaceID = nil
    switch windowCoordinator.open(id) {
    case .opened(let owner): adoptSession(owner)
    case .locatedExistingWindow: break
    case .unavailable:
      let loadToken = windowCoordinator.issueWorkspaceLoadToken()
      let launch = session.resourceStore.launchTerminalProcesses
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.windowCoordinator.acceptsWorkspaceLoadToken(loadToken) else { return }
        let result = await self.windowCoordinator.registry.openSaved(
          id, in: self.windowCoordinator,
          launchTerminalProcesses: launch)
        if case .opened(let owner) = result { self.adoptSession(owner) }
      }
    }
  }

  /// Restores only the repository's last active named workspace. The temporary
  /// session remains visible while the asynchronous directory/configuration load runs.
  @MainActor
  func restoreLastActiveWorkspace() async {
    let result = await windowCoordinator.registry.restoreLastActive(
      in: windowCoordinator,
      launchTerminalProcesses: session.resourceStore.launchTerminalProcesses)
    if case .opened(let owner) = result {
      adoptSession(owner)
    }
  }

  private func bindSession(_ owner: WorkspaceSession) {
    sessionChanges = owner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    resourceChanges = owner.resourceStore.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    if sessionBindings[owner.id]?.session === owner {
      return
    }
    sessionBindings[owner.id] = WeakSessionBinding(owner)
    let store = owner.resourceStore
    store.onCommit = { [weak self, weak owner] id, url in
      guard let owner, !owner.isClosed, owner.resourceStore.records[id] != nil else { return }
      owner.resourceStore.updateWebLocation(resourceID: id, url: url)
      owner.recordRecentResource(id)
      if let self, self.session === owner, self.selectedTabID == id, !self.isAddressEditing {
        self.addressText = url.absoluteString
      }
    }
    store.onOpenInNewTab = { [weak self, weak owner] sourceID, url in
      guard let owner, !owner.isClosed, owner.resourceStore.records[sourceID] != nil else { return }
      let id = owner.resourceStore.registerWeb(groupID: owner.id, destination: url)
      owner.recordRecentResource(id)
      if let self, self.session === owner { self.selectResource(id) }
    }
    store.onStateChange = { [weak self, weak owner] id, state in
      guard let owner, !owner.isClosed, owner.resourceStore.records[id] != nil, let self else {
        return
      }
      if let title = state.pageTitle {
        owner.resourceStore.updateTitle(resourceID: id, title: title)
      }
      if self.webStates[id] != state { self.webStates[id] = state }
      let mirror = state.toolbarMirror
      if self.session === owner, self.selectedTabID == id, self.activeWebState != mirror {
        self.activeWebState = mirror
      }
    }
    // WorkspaceSession waits for Agent cleanup before shutting down its store.
    store.onShutdown = { [weak owner] in owner?.agentController.shutdown() }
  }

  func closeWorkspace(_ id: UUID) {
    guard let owner = windowCoordinator.loadedSessions[id] else {
      selectWorkspace(id)
      return
    }
    let alert = NSAlert()
    alert.messageText = "关闭“\(owner.name)”？"
    alert.informativeText =
      "将结束 \(owner.resourceStore.liveTerminalCount) 个终端会话、取消本空间请求并清空问答。保存配置后可关闭，或选择不保存关闭。"
    alert.addButton(withTitle: "取消")
    if owner.isTemporary {
      alert.addButton(withTitle: "保存配置后关闭")
      alert.addButton(withTitle: "不保存关闭")
      let nameField = NSTextField(string: owner.name == "临时空间" ? "" : owner.name)
      nameField.placeholderString = "输入空间名称"
      nameField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
      alert.accessoryView = nameField
      let response = alert.runModal()
      if response == .alertFirstButtonReturn { return }
      if response == .alertSecondButtonReturn {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, windowCoordinator.registry.rename(id, name: name) else {
          workspaceNotice = "请输入有效名称后再保存关闭。"
          return
        }
      }
    } else {
      alert.addButton(withTitle: "关闭空间")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    Task { _ = await performCloseWorkspace(id, resolver: makeWorkspaceSaveFailureResolver(action: "关闭空间")) }
  }

  func archiveWorkspace(_ id: UUID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      _ = await self.performArchiveWorkspace(id)
    }
  }
  @discardableResult
  func performArchiveWorkspace(_ id: UUID) async -> Bool {
    let launch = webRuntimes.launchTerminalProcesses
    guard await windowCoordinator.registry.archive(id) else {
      workspaceNotice = "归档未完成，配置仍保持打开。"
      return false
    }
    if session.id == id {
      dismissPanel(restoreFocus: false)
      cancelAddressEditing()
    }
    reconcileActiveWorkspace(launch: launch)
    return true
  }
  func restoreArchivedWorkspace(_ id: UUID) {
    Task { @MainActor [weak self] in
      guard let self, await self.windowCoordinator.registry.unarchive(id) else { return }
      self.selectWorkspace(id)
    }
  }

  @discardableResult
  func performCloseWorkspace(_ id: UUID, resolver: WorkspaceCloseResolver? = nil) async -> Bool {
    let launch = webRuntimes.launchTerminalProcesses
    if id == session.id {
      dismissPanel(restoreFocus: false)
      cancelAddressEditing()
    }
    let closed = await windowCoordinator.closeWorkspace(id, resolver: resolver)
    guard closed else { return false }
    reconcileActiveWorkspace(launch: launch)
    return true
  }

  private func reconcileActiveWorkspace(launch: Bool) {
    if let active = windowCoordinator.activeSession {
      adoptSession(active)
    } else if let fresh = windowCoordinator.createWorkspace(launchTerminalProcesses: launch) {
      adoptSession(fresh)
    }
  }

  var selectedTab: StudioTab? {
    tabs.first { $0.id == selectedTabID }
  }

  func selectResource(_ id: UUID) {
    guard !session.isClosed, !windowCoordinator.isClosing else { return }
    guard webRuntimes.records[id] != nil else { return }
    let shouldFocusContent = panels.panel == nil
    if layout.primary.resourceID == id {
      layout.primary.isFocused = true
      if var other = layout.secondary {
        other.isFocused = false
        layout.secondary = other
      }
    } else if var secondary = layout.secondary, secondary.resourceID == id {
      layout.primary.isFocused = false
      secondary.isFocused = true
      layout.secondary = secondary
    } else if layout.primary.isFocused {
      layout.primary.resourceID = id
    } else if var secondary = layout.secondary {
      secondary.resourceID = id
      secondary.isFocused = true
      layout.secondary = secondary
    } else {
      layout.primary.resourceID = id
      layout.primary.isFocused = true
    }
    if addressIsEditing { cancelAddressEditing() }
    if let record = webRuntimes.records[id] { selectedGroupID = record.groupID }
    let isBlankWeb =
      webRuntimes.records[id].map { record in
        if case .web(nil) = record.location { return true }
        return false
      } ?? false
    if !isBlankWeb {
      session.recordRecentResource(id)
    }
    addressText = addressValue(for: id)
    refreshActiveWebState()
    if shouldFocusContent { focusCurrentPaneContent() }
  }
  var focusedPane: PaneState {
    layout.primary.isFocused ? layout.primary : (layout.secondary ?? layout.primary)
  }

  func split(resourceID: UUID? = nil) {
    guard !session.isClosed, !windowCoordinator.isClosing else { return }
    if resourceID == nil {
      guard layout.secondary == nil, layout.primary.resourceID != nil else { return }
      splitPickerWorkspaceID = session.id
      splitPickerPresented = true
      return
    }
    if let resourceID, layout.primary.resourceID == resourceID {
      focusPane(layout.primary.id)
      return
    }
    if let resourceID, let secondary = layout.secondary, secondary.resourceID == resourceID {
      focusPane(secondary.id)
      return
    }
    guard layout.secondary == nil, let primary = layout.primary.resourceID else { return }
    guard let resourceID, webRuntimes.records[resourceID] != nil, resourceID != primary else { return }
    let candidate = resourceID
    layout.secondary = PaneState(resourceID: candidate, isFocused: false)
    layout.splitRatio = 0.5
  }
  func chooseSplitResource(_ resourceID: UUID) {
    guard splitPickerWorkspaceID == session.id, !session.isClosed else {
      splitPickerPresented = false
      return
    }
    splitPickerPresented = false
    split(resourceID: resourceID)
  }
  func showResource(_ resourceID: UUID, in pane: PaneState) {
    guard !session.isClosed, !windowCoordinator.isClosing, webRuntimes.records[resourceID] != nil else { return }
    if layout.primary.resourceID == resourceID {
      focusPane(layout.primary.id)
      return
    }
    if let secondary = layout.secondary, secondary.resourceID == resourceID {
      focusPane(secondary.id)
      return
    }
    if pane.id == layout.primary.id {
      layout.primary.resourceID = resourceID
    } else if var secondary = layout.secondary, secondary.id == pane.id {
      secondary.resourceID = resourceID
      layout.secondary = secondary
    }
    focusPane(pane.id)
    refreshActiveWebState()
  }
  func showResourceOnRight(_ resourceID: UUID) {
    guard !session.isClosed, !windowCoordinator.isClosing,
      layout.primary.resourceID != nil, webRuntimes.records[resourceID] != nil
    else { return }
    if layout.primary.resourceID == resourceID {
      focusPane(layout.primary.id)
      return
    }
    if let secondary = layout.secondary {
      showResource(resourceID, in: secondary)
      return
    }
    layout.secondary = PaneState(resourceID: resourceID, isFocused: false)
    layout.splitRatio = 0.5
  }
  func splitWithNewWeb() {
    guard splitPickerWorkspaceID == session.id, !session.isClosed, !windowCoordinator.isClosing else {
      splitPickerPresented = false
      return
    }
    guard layout.secondary == nil, let primary = layout.primary.resourceID else { return }
    let id = webRuntimes.registerWeb(groupID: session.id)
    layout.secondary = PaneState(resourceID: id, isFocused: false)
    layout.splitRatio = 0.5
    splitPickerPresented = false
    _ = primary
  }
  func splitWithNewTerminal() {
    guard splitPickerWorkspaceID == session.id, !session.isClosed, !windowCoordinator.isClosing else {
      splitPickerPresented = false
      return
    }
    guard layout.secondary == nil, layout.primary.resourceID != nil else { return }
    let cwd = session.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
    let id = webRuntimes.registerLocalTerminal(groupID: session.id, directory: cwd)
    layout.secondary = PaneState(resourceID: id, isFocused: false)
    layout.splitRatio = 0.5
    splitPickerPresented = false
  }
  func focusPane(_ paneID: UUID) {
    guard layout.primary.id == paneID || layout.secondary?.id == paneID else { return }
    layout.primary.isFocused = layout.primary.id == paneID
    if var secondary = layout.secondary {
      secondary.isFocused = secondary.id == paneID
      layout.secondary = secondary
    }
    if let id = focusedPane.resourceID, let record = webRuntimes.records[id] {
      selectedGroupID = record.groupID
    }
    refreshActiveWebState()
  }
  func focusOtherPaneAndContent() {
    guard let secondary = layout.secondary else { return }
    let other = focusedPane.id == layout.primary.id ? secondary.id : layout.primary.id
    focusPane(other)
    guard layout.primary.id == other || layout.secondary?.id == other else { return }
    focusCurrentPaneContent()
  }
  func focusCurrentPaneContent() {
    let paneID = focusedPane.id
    let resourceID = focusedPane.resourceID
    let targetWindow = workspaceFocusView?.window
    DispatchQueue.main.async { [weak self] in
      guard let self, self.focusedPane.id == paneID, self.focusedPane.resourceID == resourceID,
        self.panels.panel == nil, let window = targetWindow
      else { return }
      if let resourceID, let webView = self.webRuntimes.runtime(for: resourceID)?.webView,
        webView.window === window
      {
        window.makeFirstResponder(webView)
      } else if let resourceID,
        let terminalView = self.webRuntimes.terminalSession(for: resourceID)?.nativeView,
        terminalView.window === window
      {
        window.makeFirstResponder(terminalView)
      } else {
        if let fallback = self.workspaceFocusView, fallback.window === window {
          window.makeFirstResponder(fallback)
        }
      }
    }
  }
  func closePane(_ paneID: UUID) {
    if layout.primary.id == paneID, let secondary = layout.secondary {
      layout = WorkspaceLayout(
        primary: PaneState(id: secondary.id, resourceID: secondary.resourceID, isFocused: true),
        splitRatio: layout.splitRatio)
    } else if layout.secondary?.id == paneID {
      layout.secondary = nil
      layout.primary.isFocused = true
    }
    if let id = layout.primary.resourceID, let record = webRuntimes.records[id] {
      selectedGroupID = record.groupID
    }
    refreshActiveWebState()
  }
  func returnToSinglePane() {
    let focused = layout.primary.isFocused ? layout.primary : (layout.secondary ?? layout.primary)
    layout = WorkspaceLayout(
      primary: PaneState(id: focused.id, resourceID: focused.resourceID, isFocused: true))
    if let id = focused.resourceID, let record = webRuntimes.records[id] {
      selectedGroupID = record.groupID
    }
    refreshActiveWebState()
  }
  func swapPanes() {
    guard let secondary = layout.secondary else { return }
    let primary = layout.primary
    layout.primary = secondary
    layout.secondary = primary
    refreshActiveWebState()
  }
  func setSplitRatio(_ value: Double) { layout.splitRatio = min(max(value, 0.2), 0.8) }
  private func isMounted(_ id: UUID) -> Bool {
    layout.primary.resourceID == id || layout.secondary?.resourceID == id
  }

  var selectedGroup: StudioGroup? {
    groups.first { $0.id == selectedGroupID }
  }

  var visibleTabs: [StudioTab] {
    tabs.filter { $0.groupID == selectedGroupID }
  }

  func newTab(in groupID: UUID) {
    performWorkspaceAction(in: groupID) { owner in
      let tab = StudioTab(groupID: owner.id)
      owner.resourceStore.registerWeb(groupID: owner.id, resourceID: tab.id)
      if self.session === owner { self.selectedTabID = tab.id }
    }
  }
  func newTab() {
    newTab(in: selectedGroupID)
  }
  func pinDestination(for id: UUID) {
    guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record)
    else { return }
    guard !pinnedDestinations.contains(where: { $0.destination == destination }) else { return }
    pinnedDestinations.append(
      PinnedDestination(title: record.customTitle ?? record.title, destination: destination))
  }
  func isPinned(_ id: UUID) -> Bool {
    guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record)
    else { return false }
    return pinnedDestinations.contains { $0.destination == destination }
  }
  func unpinDestination(for id: UUID) {
    guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record)
    else { return }
    pinnedDestinations.removeAll { $0.destination == destination }
  }
  private func pinnedDestination(for record: ResourceRecord) -> StudioDestination? {
    switch record.location {
    case .web(let url): return url.map(StudioDestination.web)
    case .localTerminal(let directory): return directory.map(StudioDestination.terminal)
    case .ssh(let host, let user, let port): return .ssh(host: host, user: user, port: port)
    }
  }
  func openStartEntryPanel() {
    panels.open(
      .startEntry, targetResourceID: focusedPane.resourceID, paneID: focusedPane.id,
      originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes)
  }
  func openStartTerminal(from resourceID: UUID) {
    guard let source = webRuntimes.records[resourceID] else { return }
    let paneID =
      layout.primary.resourceID == resourceID
      ? layout.primary.id
      : (layout.secondary?.resourceID == resourceID ? layout.secondary?.id : nil)
    if let paneID { focusPane(paneID) }
    newTerminal(in: source.groupID, directory: nil)
  }
  func openAgentPanel(_ panel: PanelCoordinator.Panel) {
    panels.open(
      panel, targetResourceID: nil, originalResponder: NSApp.keyWindow?.firstResponder,
      store: webRuntimes)
  }
  func openAgentRunDetails(_ runID: UUID) {
    panels.open(
      .agentRunDetails(runID), targetResourceID: nil,
      originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes)
  }
  func addPinnedDestination(title: String, destination: StudioDestination) {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    if let index = pinnedDestinations.firstIndex(where: { $0.destination == destination }) {
      pinnedDestinations[index].title = clean
    } else {
      pinnedDestinations.append(PinnedDestination(title: clean, destination: destination))
    }
    dismissPanel()
  }
  func openPinnedDestination(_ entry: PinnedDestination, from resourceID: UUID) {
    guard let source = webRuntimes.records[resourceID] else { return }
    let groupID = source.groupID
    let sourcePane =
      layout.primary.resourceID == resourceID
      ? layout.primary.id
      : (layout.secondary?.resourceID == resourceID ? layout.secondary?.id : nil)
    switch entry.destination {
    case .web(let url):
      if source.kind == .web, case .web(nil) = source.location {
        webRuntimes.updateWebLocation(resourceID: resourceID, url: url)
        selectedGroupID = groupID
        addressText = url.absoluteString
        recordRecentResource(resourceID)
        if let sourcePane { focusPane(sourcePane) }
      } else {
        openWebTab(url, sourceResourceID: resourceID)
      }
    case .terminal(let directory):
      let id = webRuntimes.registerLocalTerminal(groupID: groupID, directory: directory)
      if let sourcePane { focusPane(sourcePane) }
      selectedGroupID = groupID
      selectResource(id)
    case .ssh(let host, let user, let port):
      let id = webRuntimes.registerSSH(groupID: groupID, host: host, user: user, port: port)
      if let sourcePane { focusPane(sourcePane) }
      selectResource(id)
    case .blank: break
    }
  }
  func openPinnedDestinationInWorkspace(_ entry: PinnedDestination) {
    guard !session.isClosed, !windowCoordinator.isClosing else { return }
    let groupID = session.id
    let id: UUID
    switch entry.destination {
    case .web(let url):
      id = webRuntimes.registerWeb(groupID: groupID, destination: url)
    case .terminal(let directory):
      id = webRuntimes.registerLocalTerminal(groupID: groupID, directory: directory)
    case .ssh(let host, let user, let port):
      id = webRuntimes.registerSSH(groupID: groupID, host: host, user: user, port: port)
    case .blank: return
    }
    selectResource(id)
  }
  func newTerminal(in groupID: UUID, directory: String? = nil) {
    performWorkspaceAction(in: groupID) { owner in
      let cwd = directory ?? owner.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
      let id = owner.resourceStore.registerLocalTerminal(groupID: owner.id, directory: cwd)
      if self.session === owner { self.selectedTabID = id }
    }
  }

  private func performWorkspaceAction(
    in groupID: UUID, action: @escaping @MainActor (WorkspaceSession) -> Void
  ) {
    guard !session.isClosed, !windowCoordinator.isClosing,
      groups.contains(where: { $0.id == groupID })
    else { return }
    guard prepareWorkspaceSwitch(to: groupID) else { return }
    if groupID == session.id {
      _ = windowCoordinator.issueWorkspaceLoadToken()
      action(session)
      return
    }
    switch windowCoordinator.open(groupID) {
    case .opened(let owner):
      adoptSession(owner)
      action(owner)
    case .locatedExistingWindow:
      break
    case .unavailable:
      let launch = session.resourceStore.launchTerminalProcesses
      let actionToken = windowCoordinator.issueWorkspaceLoadToken()
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard self.windowCoordinator.acceptsWorkspaceLoadToken(actionToken) else { return }
        let result = await self.windowCoordinator.registry.openSaved(
          groupID, in: self.windowCoordinator, launchTerminalProcesses: launch)
        guard case .opened(let owner) = result,
          self.windowCoordinator.activeWorkspaceID == groupID,
          self.windowCoordinator.activeSession === owner
        else { return }
        self.adoptSession(owner)
        action(owner)
      }
    }
  }
  func newTerminal(directory: String? = nil) {
    newTerminal(in: selectedGroupID, directory: directory)
  }
  func newTerminal(directoryURL: URL? = nil) {
    guard !session.isClosed, !windowCoordinator.isClosing else { return }
    let cwd = directoryURL?.path ?? session.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
    let id = webRuntimes.registerLocalTerminal(
      groupID: selectedGroupID, directory: cwd, directoryURL: directoryURL)
    selectedTabID = id
  }
  func newTerminalInFolder() {
    let owner = session
    let ownerID = owner.id
    let paneID = focusedPane.id
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url,
      !owner.isClosed, session === owner
    {
      let id = owner.resourceStore.registerLocalTerminal(
        groupID: ownerID, directory: url.path, directoryURL: url)
      selectedTabID = id
      focusPane(paneID)
    }
  }

  func captureTerminalEnd(resourceID: UUID) -> TerminalActionCapture? {
    let owner = session
    guard let record = owner.resourceStore.records[resourceID], record.kind != .web else { return nil }
    return TerminalActionCapture(owner: owner, resourceID: resourceID, instanceID: record.runtimeInstanceID)
  }

  @discardableResult
  func endResourceSession(owner: WorkspaceSession, resourceID: UUID, expectedInstanceID: UUID?) async -> Bool {
    guard windowCoordinator.loadedSessions[owner.id] === owner, !owner.isClosed,
      !windowCoordinator.isClosing, let record = owner.resourceStore.records[resourceID],
      record.kind != .web, record.groupID == owner.id,
      record.runtimeInstanceID == expectedInstanceID,
      !pendingResourceIDs.contains(resourceID)
    else { return false }
    pendingResourceIDs.insert(resourceID)
    defer { pendingResourceIDs.remove(resourceID) }
    await owner.resourceStore.endResourceSession(resourceID: resourceID)
    return windowCoordinator.loadedSessions[owner.id] === owner && !owner.isClosed
  }

  func endResourceSession(resourceID: UUID) async {
    guard let capture = captureTerminalEnd(resourceID: resourceID) else { return }
    _ = await endResourceSession(
      owner: capture.owner, resourceID: capture.resourceID, expectedInstanceID: capture.instanceID)
  }

  func restartResourceSession(resourceID: UUID) async {
    guard let capture = captureTerminalEnd(resourceID: resourceID) else { return }
    _ = await restartResourceSession(
      owner: capture.owner, resourceID: resourceID, expectedInstanceID: capture.instanceID)
  }

  @discardableResult
  func restartResourceSession(owner: WorkspaceSession, resourceID: UUID, expectedInstanceID: UUID?) async -> Bool {
    guard await endResourceSession(owner: owner, resourceID: resourceID, expectedInstanceID: expectedInstanceID),
      windowCoordinator.loadedSessions[owner.id] === owner, !owner.isClosed, !windowCoordinator.isClosing,
      owner.resourceStore.records[resourceID]?.runtimeInstanceID == expectedInstanceID
    else { return false }
    return await owner.resourceStore.startResource(resourceID: resourceID) != nil
  }

  func repairTerminalDirectory(resourceID: UUID) {
    let owner = session
    let ownerID = owner.id
    let store = owner.resourceStore
    guard let captured = store.records[resourceID], captured.kind == .localTerminal,
      captured.lifecycle == .failed
    else { return }
    let capturedInstance = captured.runtimeInstanceID
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
      !owner.isClosed, !windowCoordinator.isClosing,
      session.id == ownerID, session === owner,
      let current = store.records[resourceID], current.kind == .localTerminal,
      current.lifecycle == .failed, current.runtimeInstanceID == capturedInstance
    else { return }
    Task { @MainActor in
      _ = await self.repairTerminalDirectory(
        owner: owner, resourceID: resourceID,
        expectedInstanceID: capturedInstance, directoryURL: url)
    }
  }

  @discardableResult
  func repairTerminalDirectory(owner: WorkspaceSession, resourceID: UUID, expectedInstanceID: UUID?, directoryURL: URL)
    async -> Bool
  {
    guard windowCoordinator.loadedSessions[owner.id] === owner, !owner.isClosed, !windowCoordinator.isClosing,
      let record = owner.resourceStore.records[resourceID], record.kind == .localTerminal,
      record.groupID == owner.id, record.lifecycle == .failed, record.runtimeInstanceID == expectedInstanceID,
      !pendingResourceIDs.contains(resourceID)
    else { return false }
    pendingResourceIDs.insert(resourceID)
    defer { pendingResourceIDs.remove(resourceID) }
    let instance = await owner.resourceStore.startResource(resourceID: resourceID, directoryURL: directoryURL)
    return instance != nil && windowCoordinator.loadedSessions[owner.id] === owner
      && !owner.isClosed && !windowCoordinator.isClosing
      && owner.resourceStore.records[resourceID]?.runtimeInstanceID == instance
  }

  func selectGroup(_ id: UUID) { selectWorkspace(id) }

  /// Active resources never move between workspace stores.
  func move(tabID: UUID, to groupID: UUID) {}

  func addGroup() {
    creatingGroup = true
    openGroupEditor(nil)
  }

  func beginRenameGroup(_ id: UUID) {
    creatingGroup = false
    openGroupEditor(id)
  }

  func setWorkspaceDirectory(_ path: String?) {
    session.directory = path
  }

  func renameSelectedGroup(_ name: String) {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    if creatingGroup {
      creatingGroup = false
      // The editor is a switching guard; close the committed form before creating.
      groupEditorPresented = false
      guard createWorkspace(name: clean, isTemporary: false) != nil else { return }
      groupEditorPresented = false
      return
    }
    guard let id = editingGroupID else { return }
    guard windowCoordinator.registry.rename(id, name: clean) else {
      workspaceNotice = "该空间已关闭，无法重命名。"
      return
    }
    groupEditorPresented = false
  }

  func renameResource(_ id: UUID, title: String) {
    guard var record = webRuntimes.records[id] else { return }
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    record.title = clean
    record.customTitle = clean
    webRuntimes.update(record)
  }

  func closeSelectedTab() {
    close(tabID: selectedTabID)
  }

  func close(tabID: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    if let session = webRuntimes.terminalSession(for: tabID),
      session.state == .starting || session.state == .running
    {
      let alert = NSAlert()
      alert.messageText = "结束终端会话？"
      alert.informativeText = "这将停止此终端中的 Shell 和所有子进程。"
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "结束会话")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    performClose(tabID: tabID, index: index)
  }
  private func performClose(tabID: UUID, index: Int) {
    let mountedPrimary = layout.primary.resourceID == tabID
    let mountedSecondary = layout.secondary?.resourceID == tabID
    if tabs.count == 1 {
      webRuntimes.remove(resourceID: tabID)
      layout = WorkspaceLayout(
        primary: PaneState(id: layout.primary.id, resourceID: nil, isFocused: true))
      addressText = ""
      pruneWebRuntimes()
      refreshActiveWebState()
      return
    }
    let wasSelected = selectedTabID == tabID
    let groupID = tabs[index].groupID
    let remaining = tabs.filter { $0.id != tabID }
    let nextID =
      tabs.enumerated()
      .first(where: { $0.offset > index && $0.element.id != tabID && $0.element.groupID == groupID }
      )?.element.id
      ?? tabs.enumerated().reversed()
      .first(where: { $0.offset < index && $0.element.groupID == groupID })?.element.id
      ?? remaining.first?.id
    webRuntimes.remove(resourceID: tabID)
    if mountedPrimary || mountedSecondary {
      if mountedPrimary, let secondary = layout.secondary, secondary.resourceID != tabID {
        layout = WorkspaceLayout(
          primary: PaneState(id: secondary.id, resourceID: secondary.resourceID, isFocused: true),
          splitRatio: layout.splitRatio)
      } else if mountedSecondary {
        layout.secondary = nil
        layout.primary.isFocused = true
      }
    }
    if wasSelected {
      if let nextID, let next = remaining.first(where: { $0.id == nextID }) {
        selectedTabID = next.id
        selectedGroupID = next.groupID
      }
    }
    pruneWebRuntimes()
    refreshActiveWebState()
    focusCurrentPaneContent()
  }

  func setDestination(_ destination: StudioDestination, targetResourceID: UUID? = nil) {
    guard !session.isClosed, !windowCoordinator.isClosing else { return }
    let targetID =
      targetResourceID ?? addressTargetResourceID ?? panels.targetResourceID ?? selectedTabID
    let capturedPane = addressTargetPaneID ?? panels.targetPaneID
    if let capturedPane, layout.primary.id != capturedPane && layout.secondary?.id != capturedPane {
      if panels.targetPaneID == capturedPane { panels.markTargetClosed() }
      addressError = "此地址对应的窗格已关闭。"
      return
    }
    if focusedPane.resourceID == nil, targetResourceID == nil, addressTargetResourceID == nil,
      panels.targetResourceID == nil
    {
      let id: UUID
      switch destination {
      case .blank: id = webRuntimes.registerWeb(groupID: session.id)
      case .web(let url): id = webRuntimes.registerWeb(groupID: session.id, destination: url)
      case .terminal(let directory):
        id = webRuntimes.registerLocalTerminal(groupID: session.id, directory: directory)
      case .ssh(let host, let user, let port):
        id = webRuntimes.registerSSH(groupID: session.id, host: host, user: user, port: port)
      }
      cancelAddressEditing()
      selectResource(id)
      return
    }
    guard let record = webRuntimes.records[targetID]
    else {
      if panels.targetResourceID == targetID { panels.markTargetClosed() }
      addressError = "所选资源已关闭。"
      return
    }
    switch destination {
    case .blank:
      guard record.kind == .web else { break }
      webRuntimes.update(
        ResourceRecord(
          id: targetID, kind: .web, groupID: record.groupID,
          title: record.customTitle ?? destination.title, location: .web(nil),
          readCapabilities: [.address, .title, .text], customTitle: record.customTitle))
    case .terminal(let directory):
      // A live terminal owns its PTY and working directory. Opening a path
      // therefore creates a sibling resource even when the source is also a
      // terminal; existing sessions are never retargeted underneath the user.
      let id = webRuntimes.registerLocalTerminal(groupID: record.groupID, directory: directory)
      if let pane = capturedPane { focusPane(pane) }
      selectedGroupID = record.groupID
      selectResource(id)
    case .web(let url):
      if record.kind == .web {
        webRuntimes.update(
          ResourceRecord(
            id: targetID, kind: .web, groupID: record.groupID,
            title: record.customTitle ?? destination.title, location: .web(url),
            readCapabilities: [.address, .title, .text], customTitle: record.customTitle))
        recordRecentResource(targetID)
      } else {
        let id = webRuntimes.registerWeb(groupID: record.groupID, destination: url)
        if let pane = capturedPane { focusPane(pane) }
        selectedGroupID = record.groupID
        selectResource(id)
      }
    case .ssh(let host, let user, let port):
      // SSH sessions are independent resources, so opening one never destroys
      // the web runtime or retargets the captured tab.
      let id = webRuntimes.registerSSH(groupID: record.groupID, host: host, user: user, port: port)
      if let pane = capturedPane { focusPane(pane) }
      selectedGroupID = record.groupID
      selectResource(id)
    }
    panels.close(window: NSApp.keyWindow)
    addressError = nil
    addressIsEditing = false
    addressTargetResourceID = nil
    addressTargetPaneID = nil
    pruneWebRuntimes()
    refreshActiveWebState()
    focusCurrentPaneContent()
  }

  func openDestination() {
    requestAddressFocus()
  }
  func openSSHDestination(targetResourceID: UUID? = nil) {
    let target = targetResourceID ?? focusedPane.resourceID
    requestAddressFocus(targetResourceID: target, paneID: focusedPane.id)
    addressText = "ssh://"
  }

  var isAddressEditing: Bool { addressIsEditing }

  func requestAddressFocus(targetResourceID: UUID? = nil, paneID: UUID? = nil) {
    if panels.panel != nil { dismissPanel(restoreFocus: false) }
    beginAddressEditing(targetResourceID: targetResourceID, paneID: paneID)
    addressFocusToken &+= 1
    let targetWindow = workspaceFocusView?.window ?? windowCoordinator.window
    let ownerID = session.id
    DispatchQueue.main.async { [weak self] in
      guard let self, self.session.id == ownerID, let field = self.addressInputField,
        let targetWindow, field.window === targetWindow
      else { return }
      targetWindow.makeFirstResponder(field)
      field.selectText(nil)
    }
  }

  func beginAddressEditing(targetResourceID: UUID? = nil, paneID: UUID? = nil) {
    guard !addressIsEditing else { return }
    let panes: [PaneState] = [layout.primary, layout.secondary].compactMap { $0 }
    let paneByID = paneID.flatMap { id in panes.first { $0.id == id } }
    let paneByResource = targetResourceID.flatMap { id in panes.first { $0.resourceID == id } }
    let pane = paneByID ?? paneByResource ?? focusedPane
    addressTargetPaneID = pane.id
    addressTargetResourceID = targetResourceID ?? pane.resourceID
    addressOriginalText = addressValue(for: addressTargetResourceID)
    addressText = addressOriginalText
    addressError = nil
    addressIsEditing = true
  }

  func cancelAddressEditing() {
    addressText = addressOriginalText
    addressError = nil
    addressIsEditing = false
    addressTargetResourceID = nil
    addressTargetPaneID = nil
  }

  func submitAddress() {
    beginAddressEditing()
    guard let destination = Self.parseAddress(addressText) else {
      addressError = Self.addressError(for: addressText)
      return
    }
    setDestination(destination, targetResourceID: addressTargetResourceID)
  }

  func noteAddressEdit() {
    if addressText != addressOriginalText { addressIsEditing = true }
  }

  private func addressValue(for resourceID: UUID?) -> String {
    guard let resourceID, let record = webRuntimes.records[resourceID] else { return "" }
    switch record.location {
    case .web(let url): return url?.absoluteString ?? ""
    case .localTerminal(let directory): return directory ?? "terminal"
    case .ssh(let host, let user, let port):
      let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
      let displayIdentity = user.isEmpty ? displayHost : "\(user)@\(displayHost)"
      return "ssh://\(displayIdentity)\(port == 22 ? "" : ":\(port)")"
    }
  }

  func openCommands() {
    let pane = focusedPane
    if panels.panel != .commands {
      commandQuery = ""
      commandSelectedIndex = 0
    }
    let originalResponder: NSResponder? = {
      let responder = commandSearchField?.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
      if let editor = responder as? NSTextView, editor.isFieldEditor,
        let field = editor.delegate as? NSTextField
      {
        return field
      }
      return responder
    }()
    panels.open(
      .commands, targetResourceID: pane.resourceID, paneID: pane.id,
      originalResponder: originalResponder, store: webRuntimes)
    searchConfigurations(commandQuery)
    if let field = commandSearchField, let window = field.window {
      field.isEnabled = true
      field.stringValue = commandQuery
      window.makeFirstResponder(field)
      field.selectText(nil)
    }
  }
  private func invalidateSearchQuery() {
    configurationSearchGeneration += 1
  }
  private func cancelSelection() {
    selectionGeneration += 1
  }

  func searchConfigurations(_ query: String) {
    configurationSearchGeneration += 1
    let generation = configurationSearchGeneration
    Task { @MainActor [weak self] in
      await self?.refreshSearchResults(query, generation: generation)
    }
  }
  /// Refreshes the pure configuration index and is awaitable by acceptance tests.
  /// It never creates a runtime or reads source content.
  @MainActor
  func refreshSearchResults(_ query: String) async {
    configurationSearchGeneration += 1
    await refreshSearchResults(query, generation: configurationSearchGeneration)
  }
  private func refreshSearchResults(_ query: String, generation: Int) async {
    let values = await windowCoordinator.registry.configurationsForSearch()
    guard generation == configurationSearchGeneration else { return }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    let currentID = session.id
    var flattened: [WorkspaceResourceSearchResult] = []
    for configuration in values {
      for resource in configuration.resources {
        let kind: ResourceKind
        switch resource.destination {
        case .web, .blank: kind = .web
        case .terminal: kind = .localTerminal
        case .ssh: kind = .sshTerminal
        }
        let result = WorkspaceResourceSearchResult(
          workspaceID: configuration.workspaceID, resourceID: resource.id,
          workspaceName: configuration.name,
          resourceTitle: resource.customTitle ?? Self.destinationTitle(resource.destination),
          kind: kind, destinationSummary: Self.destinationSummary(resource.destination))
        let kindText = Self.kindTitle(kind).localizedLowercase
        let matches =
          needle.isEmpty
          || [
            result.workspaceName, result.resourceTitle,
            kindText, kind.rawValue, result.destinationSummary,
          ].joined(separator: " ").localizedLowercase.contains(needle)
        if (searchAllWorkspaces || result.workspaceID == currentID) && matches {
          flattened.append(result)
        }
      }
    }
    // `values` may originate from a dictionary-backed registry. Preserve that stable
    // source order for ties while always placing the current workspace first.
    searchResults = flattened.enumerated().sorted { lhs, rhs in
      let a = lhs.element
      let b = rhs.element
      let aCurrent = a.workspaceID == currentID
      let bCurrent = b.workspaceID == currentID
      if aCurrent != bCurrent { return aCurrent }
      let titleOrder = a.resourceTitle.localizedCaseInsensitiveCompare(b.resourceTitle)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      return a.id < b.id
    }.map(\.element)
    commandSelectedIndex = min(commandSelectedIndex, max(paletteCommands.count - 1, 0))
    configurationSearchResults = values.filter { configuration in
      searchAllWorkspaces || configuration.workspaceID == currentID
    }
  }
  private static func kindTitle(_ kind: ResourceKind) -> String {
    switch kind {
    case .web: return "网页"
    case .localTerminal: return "本地终端"
    case .sshTerminal: return "SSH 终端"
    }
  }
  private static func destinationTitle(_ destination: WorkspaceDestinationConfiguration) -> String {
    switch destination {
    case .web(let url): return URL(string: url)?.host ?? "网页"
    case .terminal: return "终端"
    case .ssh(let host, _, _): return host
    case .blank: return "空网页"
    }
  }
  private static func destinationSummary(_ destination: WorkspaceDestinationConfiguration) -> String {
    switch destination {
    case .web(let url): return url
    case .terminal(let path): return path
    case .ssh(let host, let user, let port):
      return user.isEmpty ? "ssh://\(host):\(port)" : "ssh://\(user)@\(host):\(port)"
    case .blank: return "空网页"
    }
  }
  var paletteCommands: [StudioCommand] {
    let resources = searchResults.map { result in
      StudioCommand(
        title: result.resourceTitle, shortcut: "",
        subtitle: "\(result.workspaceName) · \(Self.kindTitle(result.kind)) · \(result.destinationSummary)",
        action: .selectWorkspaceResource(workspaceID: result.workspaceID, resourceID: result.resourceID))
    }
    return resources + availableCommands
  }
  func openSearchResult(_ result: WorkspaceResourceSearchResult) {
    selectionGeneration += 1
    let token = selectionGeneration
    searchSelectionTask = Task { @MainActor [weak self] in await self?.openSearchResultAsync(result, token: token) }
  }
  @MainActor
  func waitForSearchSelection() async { await searchSelectionTask?.value }
  @MainActor
  func openSearchResultAsync(_ result: WorkspaceResourceSearchResult) async {
    selectionGeneration += 1
    await openSearchResultAsync(result, token: selectionGeneration)
  }
  private func openSearchResultAsync(_ result: WorkspaceResourceSearchResult, token: Int) async {
    guard token == selectionGeneration else { return }
    let registry = self.windowCoordinator.registry
    let openResult: WorkspaceOpenResult
    if registry.session(for: result.workspaceID) != nil {
      openResult = self.windowCoordinator.open(result.workspaceID)
    } else {
      openResult = await registry.openSaved(
        result.workspaceID, in: self.windowCoordinator,
        launchTerminalProcesses: self.session.resourceStore.launchTerminalProcesses)
    }
    guard token == self.selectionGeneration else { return }
    switch openResult {
    case .opened(let owner):
      self.adoptSession(owner)
      guard owner.resourceStore.records[result.resourceID] != nil else {
        self.workspaceNotice = "资源已关闭或不可用。"
        return
      }
      self.selectResource(result.resourceID)
    case .locatedExistingWindow(let workspaceID):
      guard let owner = registry.session(for: workspaceID),
        let ownerCoordinator = registry.coordinator(for: workspaceID),
        ownerCoordinator.canAcceptWorkspace,
        ownerCoordinator.activeWorkspaceID == workspaceID,
        owner.resourceStore.records[result.resourceID] != nil
      else {
        self.workspaceNotice = "目标窗口或资源不可用。"
        return
      }
      if owner.layout.primary.resourceID == result.resourceID {
        owner.setFocus(paneID: owner.layout.primary.id)
      } else if let secondary = owner.layout.secondary,
        secondary.resourceID == result.resourceID
      {
        owner.setFocus(paneID: secondary.id)
      } else {
        let pane =
          owner.layout.primary.isFocused ? owner.layout.primary : (owner.layout.secondary ?? owner.layout.primary)
        if pane.id == owner.layout.primary.id {
          owner.layout.primary.resourceID = result.resourceID
        } else if var secondary = owner.layout.secondary {
          secondary.resourceID = result.resourceID
          owner.layout.secondary = secondary
        }
        owner.setFocus(paneID: pane.id)
      }
      owner.recordRecentResource(result.resourceID)
    case .unavailable:
      self.workspaceNotice = "目标空间或资源不可用。"
      return
    }
    self.dismissPanel(restoreFocus: false)
  }
  func copyResourceToWorkspace(_ resourceID: UUID, targetID: UUID) {
    let sourceID = session.id
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await self.windowCoordinator.registry.copyResource(
          sourceWorkspaceID: sourceID, resourceID: resourceID, toWorkspaceID: targetID)
        self.workspaceNotice = "入口已复制到目标空间。"
      } catch {
        self.workspaceNotice = "复制失败：\(error.localizedDescription)"
      }
    }
  }

  func openGroupEditor(_ id: UUID? = nil) {
    editingGroupID = id
    panels.openGroupEditor(originalResponder: NSApp.keyWindow?.firstResponder)
  }

  @discardableResult
  func commitWorkspaceEditor(name: String, directory: String?, targetID: UUID?, creating: Bool) -> Bool {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return false }
    if creating {
      creatingGroup = false
      groupEditorPresented = false
      guard let id = createWorkspace(name: clean, isTemporary: false),
        let target = windowCoordinator.registry.session(for: id)
      else { return false }
      target.directory = directory
      return true
    }
    guard let targetID, let target = windowCoordinator.registry.session(for: targetID) else {
      workspaceNotice = "该空间已关闭，无法保存设置。"
      return false
    }
    guard windowCoordinator.registry.rename(targetID, name: clean) else { return false }
    target.directory = directory
    groupEditorPresented = false
    return true
  }
  func openResourceEditor(_ id: UUID) {
    guard webRuntimes.records[id] != nil else {
      panels.markTargetClosed()
      return
    }
    panels.open(
      .resourceEditor(id), targetResourceID: id, originalResponder: NSApp.keyWindow?.firstResponder,
      store: webRuntimes)
  }

  // MARK: Web runtime

  var webTabIDs: Set<UUID> {
    Set(
      tabs.filter {
        if case .web = $0.destination { return true } else { return false }
      }.map(\.id)
    )
  }

  var selectedTabIsWeb: Bool {
    if case .some(.web) = selectedTab?.destination { return true }
    return false
  }

  /// Non-creating: the toolbar must not start a web process for a tab never displayed.
  var activeWebRuntime: WebTabRuntime? {
    guard selectedTabIsWeb else { return nil }
    return webRuntimes.existingRuntime(for: selectedTabID)
  }

  func refreshActiveWebState() {
    let id = selectedTabID
    let next = (webStates[id] ?? activeWebRuntime?.state ?? WebNavigationState()).toolbarMirror
    if activeWebState != next { activeWebState = next }
    if !addressIsEditing { addressText = addressValue(for: id) }
  }

  /// Releases runtimes for tabs that closed or stopped being web destinations.
  func pruneWebRuntimes() {
    webRuntimes.retain(webTabIDs: webTabIDs)
  }

  /// Follows an in-page navigation so the toolbar and tab title describe the live page.
  func updateWebDestination(tabID: UUID, url: URL) {
    guard let record = webRuntimes.records[tabID], record.kind == .web
    else { return }
    webRuntimes.updateWebLocation(resourceID: tabID, url: url, title: record.title)
    recordRecentResource(tabID)
    if !addressIsEditing, tabID == selectedTabID { addressText = url.absoluteString }
  }

  private func recordRecentResource(_ id: UUID) {
    session.recordRecentResource(id)
  }

  /// Target=_blank and window.open land in a sibling tab of the same task.
  func openWebTab(_ url: URL, sourceResourceID: UUID? = nil) {
    if let sourceResourceID, webRuntimes.records[sourceResourceID] == nil { return }
    let groupID = sourceResourceID.flatMap { webRuntimes.records[$0]?.groupID } ?? selectedGroupID
    let tab = StudioTab(
      groupID: groupID,
      destination: .web(url)
    )
    webRuntimes.registerWeb(groupID: groupID, destination: url, resourceID: tab.id)
    selectedTabID = tab.id
  }

  /// Mirrors the tab row for the keyboard: ⌘1–⌘8 pick a position, ⌘9 picks the last
  /// tab, matching Safari.
  func selectTab(at index: Int) {
    let tabs = visibleTabs
    guard !tabs.isEmpty else { return }
    let target = index >= 8 ? tabs.count - 1 : index
    guard tabs.indices.contains(target) else { return }
    selectedTabID = tabs[target].id
  }

  func selectNextTab() { cycleTab(by: 1) }

  func selectPreviousTab() { cycleTab(by: -1) }

  private func cycleTab(by offset: Int) {
    let tabs = visibleTabs
    guard tabs.count > 1,
      let current = tabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
  }

  /// Mirrors the live page title onto the tab, and the selected tab's state onto the
  /// toolbar.
  func recordWebState(tabID: UUID, state: WebNavigationState) {
    if webStates[tabID] != state { webStates[tabID] = state }
    if let title = state.pageTitle { webRuntimes.updateTitle(resourceID: tabID, title: title) }
    if tabID == selectedTabID, activeWebState != state.toolbarMirror {
      activeWebState = state.toolbarMirror
    }
  }

  // MARK: Shared commands

  /// Only the commands that can actually run right now, in menu order.
  var availableCommands: [StudioCommand] {
    let target = panels.targetResourceID ?? selectedTabID
    let targetGroup = webRuntimes.records[target]?.groupID ?? selectedGroupID
    let targetTabs = tabs.filter { $0.groupID == targetGroup }
    var list: [StudioCommand] = [
      StudioCommand(title: "新建网页", shortcut: "⌘T", action: .newTab(groupID: targetGroup)),
      StudioCommand(
        title: "新建终端", shortcut: "⌘⇧T",
        action: .newTerminal(groupID: targetGroup, directory: nil)),
      StudioCommand(title: "新建空间", shortcut: "", action: .newGroup),
    ]
    if webRuntimes.records[target] != nil {
      list.append(
        StudioCommand(
          title: "关闭资源", shortcut: "⌘W", targetResourceID: target,
          action: .closeResource(resourceID: target)))
      list.append(
        StudioCommand(
          title: "打开目的地…", shortcut: "⌘L", targetResourceID: target,
          action: .openDestination(resourceID: target)))
    }
    if targetTabs.count > 1, let index = targetTabs.firstIndex(where: { $0.id == target }) {
      list.append(
        StudioCommand(
          title: "下一个资源", shortcut: "⌃Tab", targetResourceID: target,
          action: .selectResource(resourceID: targetTabs[(index + 1) % targetTabs.count].id)))
      list.append(
        StudioCommand(
          title: "上一个资源", shortcut: "⌃⇧Tab", targetResourceID: target,
          action: .selectResource(
            resourceID: targetTabs[(index - 1 + targetTabs.count) % targetTabs.count].id)))
    }
    let capturedRuntime = webRuntimes.existingRuntime(for: target)
    let capturedWeb: Bool = {
      guard let record = webRuntimes.records[target], case .web(let url) = record.location else {
        return false
      }
      return url != nil
    }()
    if webStates[target]?.canGoBack ?? capturedRuntime?.state.canGoBack ?? false {
      list.append(
        StudioCommand(
          title: "后退", shortcut: "⌘[", targetResourceID: target, action: .back(resourceID: target)
        ))
    }
    if webStates[target]?.canGoForward ?? capturedRuntime?.state.canGoForward ?? false {
      list.append(
        StudioCommand(
          title: "前进", shortcut: "⌘]", targetResourceID: target,
          action: .forward(resourceID: target)))
    }
    if capturedWeb {
      let loading = webStates[target]?.isLoading ?? capturedRuntime?.state.isLoading ?? false
      list.append(
        StudioCommand(
          title: loading ? "停止加载" : "重新加载页面", shortcut: "⌘R", targetResourceID: target,
          action: loading ? .stop(resourceID: target) : .reload(resourceID: target))
      )
    }
    list.append(StudioCommand(title: "切换侧栏", shortcut: "⌘⌥S", action: .toggleSidebar))
    list.append(StudioCommand(title: "切换问答", shortcut: "⌘⌥A", action: .toggleAgents))
    return list
  }

  var filteredCommandCount: Int {
    paletteCommands.filter {
      commandQuery.isEmpty || $0.searchText.localizedCaseInsensitiveContains(commandQuery)
    }.count
  }

  func executeSelectedCommand() {
    guard panels.panel == .commands else { return }
    let commands = paletteCommands.filter {
      commandQuery.isEmpty || $0.searchText.localizedCaseInsensitiveContains(commandQuery)
    }
    guard commands.indices.contains(commandSelectedIndex) else { return }
    let command = commands[commandSelectedIndex]
    let oldPanel = panels.panel
    if execute(command), panels.panel == oldPanel, oldPanel != nil {
      switch command.action {
      case .newTab, .newTerminal, .selectResource:
        dismissPanel(restoreFocus: false)
        focusCurrentPaneContent()
      case .selectWorkspaceResource:
        break
      default:
        dismissPanel()
      }
    }
  }

  func webGoBack() { activeWebRuntime?.goBack() }

  func webGoForward() { activeWebRuntime?.goForward() }

  func webReloadOrStop() {
    guard let runtime = activeWebRuntime else { return }
    if runtime.state.isLoading {
      runtime.stop()
    } else {
      runtime.reload()
    }
  }

  @discardableResult func execute(_ command: StudioCommand) -> Bool {
    if let paneID = panels.targetPaneID,
      layout.primary.id != paneID && layout.secondary?.id != paneID
    {
      panels.markTargetClosed()
      return false
    }
    if let id = command.targetResourceID, webRuntimes.records[id] == nil {
      panels.markTargetClosed()
      return false
    }
    if panels.targetResourceID != nil,
      webRuntimes.records[panels.targetResourceID!] == nil
    {
      panels.markTargetClosed()
      return false
    }
    func focusCapturedPaneForViewChange() -> Bool {
      guard let paneID = panels.targetPaneID else { return true }
      guard layout.primary.id == paneID || layout.secondary?.id == paneID else {
        panels.markTargetClosed()
        return false
      }
      focusPane(paneID)
      return true
    }
    switch command.action {
    case .newTab(let groupID):
      guard focusCapturedPaneForViewChange() else { return false }
      newTab(in: groupID)
      selectResource(selectedTabID)
    case .newTerminal(let groupID, let directory):
      guard focusCapturedPaneForViewChange() else { return false }
      newTerminal(in: groupID, directory: directory)
      selectResource(selectedTabID)
    case .closeResource(let id): close(tabID: id)
    case .openDestination(let id):
      requestAddressFocus(targetResourceID: id, paneID: panels.targetPaneID)
    case .newGroup: addGroup()
    case .selectResource(let id):
      guard let record = webRuntimes.records[id] else {
        panels.markTargetClosed()
        return false
      }
      guard focusCapturedPaneForViewChange() else { return false }
      selectedGroupID = record.groupID
      selectResource(id)
    case .selectWorkspaceResource(let workspaceID, let resourceID):
      openSearchResult(
        .init(
          workspaceID: workspaceID, resourceID: resourceID,
          workspaceName: "", resourceTitle: "", kind: .web, destinationSummary: ""))
    case .back(let id): webRuntimes.runtime(for: id)?.goBack()
    case .forward(let id): webRuntimes.runtime(for: id)?.goForward()
    case .reload(let id): webRuntimes.runtime(for: id)?.reload()
    case .stop(let id): webRuntimes.runtime(for: id)?.stop()
    case .toggleSidebar: tabStripVisible.toggle()
    case .toggleAgents: toggleQuestionPanel()
    }
    return true
  }

  static func normalizedWebURL(_ input: String) -> URL? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty
    else { return nil }
    guard
      !value.contains(where: {
        $0.isWhitespace || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
      })
    else { return nil }
    let candidate =
      value
        .contains("://") ? value : "https://\(value)"
    guard let url = URL(string: candidate),
      let scheme = url.scheme?.lowercased(),
      [
        "http",
        "https",
      ].contains(scheme), url.host != nil
    else { return nil }
    return url
  }

  static func parseAddress(_ input: String) -> StudioDestination? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value == "terminal" || value == "terminal://" {
      return .terminal(directory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
    if value.hasPrefix("terminal://") {
      let rawPath = String(value.dropFirst("terminal://".count))
      let path = rawPath.hasPrefix("/") || rawPath.hasPrefix("~/") ? rawPath : "~/\(rawPath)"
      return normalizedTerminalPath(path).map(StudioDestination.terminal)
    }
    if value == "~" || value.hasPrefix("/") || value.hasPrefix("~/") {
      return normalizedTerminalPath(value).map(StudioDestination.terminal)
    }
    if value.lowercased().hasPrefix("ssh://") {
      let authority =
        value.dropFirst("ssh://".count).split(
          separator: "/", maxSplits: 1, omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
      guard let components = URLComponents(string: value),
        !authority.hasSuffix(":"),
        let host = components.host,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        components.path.isEmpty || components.path == "/",
        let destination = normalizedSSH(
          host: host, user: components.user ?? "",
          portText: components.port.map(String.init) ?? "22")
      else { return nil }
      return destination
    }
    if value.contains("@"), !value.contains("://") {
      let parts = value.split(separator: "@", omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      let (user, hostPort) = (String(parts[0]), String(parts[1]))
      return parseSSHHostPort(hostPort, user: user)
    }
    return normalizedWebURL(value).map(StudioDestination.web)
  }

  private static func normalizedTerminalPath(_ input: String) -> String? {
    let expanded = (input as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/"),
      !expanded.contains("\0"),
      !expanded.contains(where: {
        $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
      })
    else { return nil }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }

  private static func parseSSHHostPort(_ value: String, user: String) -> StudioDestination? {
    if value.hasPrefix("[") {
      guard let end = value.firstIndex(of: "]") else { return nil }
      let host = String(value[value.index(after: value.startIndex)..<end])
      let suffix = String(value[value.index(after: end)...])
      guard
        suffix.isEmpty
          || (suffix.hasPrefix(":") && !suffix.dropFirst().isEmpty
            && suffix.dropFirst().allSatisfy(\.isNumber))
      else { return nil }
      let port = suffix.hasPrefix(":") ? String(suffix.dropFirst()) : "22"
      return normalizedSSH(host: host, user: user, portText: port)
    }
    let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
    if pieces.count == 2, Int(pieces[1]) != nil {
      return normalizedSSH(host: String(pieces[0]), user: user, portText: String(pieces[1]))
    }
    if value.contains(":"), let destination = normalizedSSH(host: value, user: user, portText: "22") {
      return destination
    }
    return normalizedSSH(host: value, user: user, portText: "22")
  }

  static func addressError(for input: String) -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("ssh://") || value.contains("@") {
      return "请输入有效的 SSH 主机、可选用户和端口。"
    }
    if value.hasPrefix("terminal") || value.hasPrefix("/") || value.hasPrefix("~/") {
      return "请输入绝对路径或以 ~ 开头的本地目录路径。"
    }
    if value.contains("://") && !value.lowercased().hasPrefix("http://")
      && !value.lowercased().hasPrefix("https://")
    {
      return "不支持的地址协议。"
    }
    return "请输入 HTTP(S) 地址、SSH 主机或本地目录路径。"
  }

  static func normalizedSSH(host: String, user: String, portText: String) -> StudioDestination? {
    let hasControl: (String) -> Bool = { value in
      value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
    guard !hasControl(host), !hasControl(user), !hasControl(portText) else { return nil }
    let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanHost =
      rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
      ? String(rawHost.dropFirst().dropLast()) : rawHost
    let cleanUser =
      user
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let hostLooksValid: Bool = {
      if cleanHost.contains(":") {
        let candidate = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var address = in6_addr()
        return candidate.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
      }
      if cleanHost.withCString({ value in
        var address = in_addr()
        return inet_pton(AF_INET, value, &address) == 1
      }) {
        return true
      }
      let labels = cleanHost.split(separator: ".", omittingEmptySubsequences: false)
      if labels.count == 4 && labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
        return false
      }
      return cleanHost.count <= 253 && !labels.isEmpty
        && labels.allSatisfy { label in
          label.count <= 63 && !label.isEmpty && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }()
    guard !cleanHost.isEmpty,
      !cleanHost.contains(where: { $0.isWhitespace || $0 == "/" }),
      !cleanHost.contains("\\") && !cleanHost.contains("@") && hostLooksValid,
      !hasControl(cleanHost), !hasControl(cleanUser)
    else { return nil }
    let cleanPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
    let port =
      cleanPort
        .isEmpty ? 22 : (Int(cleanPort) ?? 0)
    guard (1...65535).contains(port)
    else { return nil }
    guard !cleanUser.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "@" }),
      !cleanHost.hasPrefix("-"), !cleanUser.hasPrefix("-")
    else { return nil }
    return .ssh(
      host: cleanHost,
      user: cleanUser,
      port: port
    )
  }
}
