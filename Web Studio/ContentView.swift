import Combine
import SwiftUI
import AppKit
import Darwin

private struct StudioModelFocusedKey: FocusedValueKey { typealias Value = StudioModel }
extension FocusedValues {
    var studioModel: StudioModel? {
        get { self[StudioModelFocusedKey.self] }
        set { self[StudioModelFocusedKey.self] = newValue }
    }
}

enum StudioDestination: Equatable {
    case blank
    case terminal(directory: String)
    case web(URL)
    case ssh(host: String, user: String, port: Int)
    var title: String {
        switch self {
        case .blank: return "New Tab"
        case let .terminal(directory): return "Terminal · \(URL(fileURLWithPath: directory).lastPathComponent)"
        case let .web(url):
            guard let host = url.host else { return url.absoluteString }
            let defaultPort = (url.scheme?.lowercased() == "http" && url.port == 80) || (url.scheme?.lowercased() == "https" && url.port == 443)
            return if let port = url.port, !defaultPort {
                "\(host):\(port)"
            } else {
                host
            }
        case let .ssh(
            host,

            user,

            port
        ):
            let id =
                user
                    .isEmpty ? host : "\(user)@\(host)"
            return port == 22 ? id : "\(id):\(port)"
        }
    }

    var detail: String? {
        guard case let .web(url) = self else { return nil }
        return [
            url.path.isEmpty ? nil : url.path,
            url.query.map { "?\($0)" },
            url.fragment.map { "#\($0)" },
        ].compactMap { $0 }.joined()
    }

    var accessibilityTitle: String {
        if case let .web(url) = self {
            return url.absoluteString
        }
        return title
    }
}

struct StudioGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    init(
        id: UUID = UUID(),
        name: String
    ) {
        self.id = id
        self.name = name
    }
}

struct StudioTab: Identifiable,
    Equatable
{
    let id: UUID
    var groupID: UUID
    var destination: StudioDestination = .blank
    /// Live title reported by the tab's web runtime, when it has one.
    var pageTitle: String?

    /// What the tab row and task strip show: the page's own title when the runtime has
    /// reported one, otherwise the stored destination.
    var displayTitle: String { pageTitle ?? destination.title }

    init(
        id: UUID = UUID(),
        groupID: UUID,
        destination: StudioDestination = .blank,
        pageTitle: String? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.destination = destination
        self.pageTitle = pageTitle
    }
}

/// One shell action. The palette and the menu bar read the same list, so a command can
/// never appear in one surface and be missing from the other.
enum StudioCommandAction {
    case newTab(groupID: UUID)
    case newTerminal(groupID: UUID, directory: String?)
    case closeResource(resourceID: UUID)
    case openDestination(resourceID: UUID)
    case newGroup
    case selectResource(resourceID: UUID)
    case back(resourceID: UUID), forward(resourceID: UUID), reload(resourceID: UUID), stop(resourceID: UUID)
    case toggleSidebar, toggleAgents
}
struct StudioCommand: Identifiable {
    let title: String
    let shortcut: String
    let targetResourceID: UUID?
    let action: StudioCommandAction
    init(title: String, shortcut: String, targetResourceID: UUID? = nil, action: StudioCommandAction) {
        self.title = title; self.shortcut = shortcut; self.targetResourceID = targetResourceID; self.action = action
    }
    var id: String { "\(title)|\(targetResourceID?.uuidString ?? "none")" }
}

@MainActor final class StudioModel: ObservableObject {
    @Published var groups: [StudioGroup]
    /// Compatibility projection; ResourceStore is the canonical ordered resource model.
    var tabs: [StudioTab] {
        webRuntimes.order.compactMap { id in
            guard let record = webRuntimes.records[id] else { return nil }
            let destination: StudioDestination
            switch record.location {
            case let .web(url): destination = url.map(StudioDestination.web) ?? .blank
            case let .ssh(host, user, port): destination = .ssh(host: host, user: user, port: port)
            case let .localTerminal(directory): destination = .terminal(directory: directory ?? "")
            }
            return StudioTab(id: id, groupID: record.groupID, destination: destination, pageTitle: record.customTitle ?? (record.title == destination.title ? nil : record.title))
        }
    }
    @Published var selectedGroupID: UUID
    @Published var layout: WorkspaceLayout
    var selectedTabID: UUID {
        get { layout.secondary?.isFocused == true ? (layout.secondary?.resourceID ?? layout.primary.resourceID ?? UUID()) : (layout.primary.resourceID ?? UUID()) }
        set { selectResource(newValue) }
    }
    /// Navigation state of the selected tab's web runtime, mirrored here so the toolbar
    /// re-renders without observing a runtime that may not exist yet.
    @Published var activeWebState = WebNavigationState()
    private var webStates: [UUID: WebNavigationState] = [:]
    /// One WKWebView per live web tab.
    let webRuntimes: WebRuntimeStore
    let agentController: AgentController
    let providerSettings: ProviderSettings
    let panels = PanelCoordinator()
    private var resourceChanges: AnyCancellable?
    private var panelChanges: AnyCancellable?
    @Published var tabStripVisible = true
    @Published var agentsVisible =
        true
    /// Session-only shortcuts and recency for the start page. Nothing is written to disk.
    @Published var pinnedDestinations: [PinnedDestination] = []
    @Published private(set) var recentResourceIDs: [UUID] = []
    /// The toolbar address field is a persistent control, so its edit target is
    /// captured independently of the current selection.
    @Published var addressText = ""
    @Published var addressError: String?
    @Published private(set) var addressFocusToken = 0
    @Published var commandQuery = ""
    @Published var commandSelectedIndex = 0
    weak var commandSearchField: NSTextField?
    private var addressTargetResourceID: UUID?
    private var addressTargetPaneID: UUID?
    private var addressOriginalText = ""
    private var addressIsEditing = false
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
        set { if !newValue { dismissPanel() } }
    }
    var resourceEditorPresented: Bool {
        if case .resourceEditor = panels.panel { return true }; return false
    }
    @Published var editingGroupID: UUID?
    /// Compatibility projections used by the existing native presentation modifiers.
    var panelTargetResourceID: UUID? { panels.targetResourceID }
    func dismissPanel(restoreFocus: Bool = true) {
        if panels.panel == .providerSettings { resetProviderDraft() }
        if panels.panel == .commands, let field = commandSearchField, let window = field.window,
           (window.firstResponder === field || field.currentEditor() === window.firstResponder), let fallback = workspaceFocusView, fallback.window === window {
            window.makeFirstResponder(fallback)
        }
        let fallbackView = workspaceFocusView
        let fallbackWindow = fallbackView?.window
        panels.close(window: NSApp.keyWindow, restoreFocus: restoreFocus, fallback: {
            guard let fallbackView, let fallbackWindow, fallbackView.window === fallbackWindow else { return }
            _ = fallbackWindow.makeFirstResponder(fallbackView)
        })
    }
    private func resetProviderDraft() {
        providerSettings.resetDraft()
    }
    func openProviderSettings() {
        resetProviderDraft()
        panels.open(.providerSettings, targetResourceID: nil, originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes)
    }
    var agentsScope: String {
        "\(selectedGroup?.name ?? "Current task") · \(selectedTab?.destination.title ?? "New Tab")"
    }

    @Published var sidebarWidth: CGFloat = 220
    @Published var agentsWidth: CGFloat = 300
    weak var workspaceFocusView: NSView?
    weak var addressInputField: NSTextField?
    init(launchTerminalProcesses: Bool = true) {
        webRuntimes = WebRuntimeStore(launchTerminalProcesses: launchTerminalProcesses)
        agentController = AgentController(store: webRuntimes)
        providerSettings = ProviderSettings(credentials: agentController.service.credentials)
        let group = StudioGroup(name: "Workspace")
        let tab = StudioTab(groupID: group.id)
        groups =
            [group]
        selectedGroupID = group.id
        layout = WorkspaceLayout(primary: PaneState(resourceID: tab.id, isFocused: true))
        webRuntimes.registerWeb(groupID: group.id, resourceID: tab.id)
        webRuntimes.onCommit = { [weak self] tabID, url in
            self?.updateWebDestination(tabID: tabID, url: url)
        }
        webRuntimes.onOpenInNewTab = { [weak self] sourceID, url in self?.openWebTab(url, sourceResourceID: sourceID) }
        webRuntimes.onStateChange = { [weak self] tabID, state in
            self?.recordWebState(tabID: tabID, state: state)
        }
        resourceChanges = webRuntimes.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        panelChanges = panels.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        providerSettings.onConfigurationChanged = { [weak agentController] configuration in
            agentController?.updateConfiguration(configuration)
        }
        providerSettings.loadPersisted()
        webRuntimes.onShutdown = { [weak agentController] in
            agentController?.shutdown()
        }
    }

    var selectedTab: StudioTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func selectResource(_ id: UUID) {
        guard webRuntimes.records[id] != nil else { return }
        let shouldFocusContent = panels.panel == nil
        if layout.primary.resourceID == id { layout.primary.isFocused = true; if var other = layout.secondary { other.isFocused = false; layout.secondary = other } }
        else if var secondary = layout.secondary, secondary.resourceID == id { layout.primary.isFocused = false; secondary.isFocused = true; layout.secondary = secondary }
        else if layout.primary.isFocused { layout.primary.resourceID = id }
        else if var secondary = layout.secondary { secondary.resourceID = id; secondary.isFocused = true; layout.secondary = secondary }
        else { layout.primary.resourceID = id; layout.primary.isFocused = true }
        if addressIsEditing { cancelAddressEditing() }
        if let record = webRuntimes.records[id] { selectedGroupID = record.groupID }
        let isBlankWeb = webRuntimes.records[id].map { record in
            if case .web(nil) = record.location { return true }
            return false
        } ?? false
        if !isBlankWeb {
            recentResourceIDs.removeAll { $0 == id }
            recentResourceIDs.insert(id, at: 0)
            recentResourceIDs = Array(recentResourceIDs.prefix(5))
        }
        addressText = addressValue(for: id)
        refreshActiveWebState()
        if shouldFocusContent { focusCurrentPaneContent() }
    }
    var focusedPane: PaneState { layout.primary.isFocused ? layout.primary : (layout.secondary ?? layout.primary) }

    func split(resourceID: UUID? = nil) {
        guard layout.secondary == nil, let primary = layout.primary.resourceID else { return }
        let candidate: UUID
        if let resourceID {
            guard webRuntimes.records[resourceID] != nil, resourceID != primary else { return }
            candidate = resourceID
        } else {
            candidate = webRuntimes.resources.first(where: { $0.id != primary && !isMounted($0.id) })?.id ?? webRuntimes.registerWeb(groupID: webRuntimes.records[primary]?.groupID ?? selectedGroupID)
        }
        layout.secondary = PaneState(resourceID: candidate, isFocused: false); layout.splitRatio = 0.5
    }
    func focusPane(_ paneID: UUID) {
        guard layout.primary.id == paneID || layout.secondary?.id == paneID else { return }
        layout.primary.isFocused = layout.primary.id == paneID
        if var secondary = layout.secondary { secondary.isFocused = secondary.id == paneID; layout.secondary = secondary }
        if let id = focusedPane.resourceID, let record = webRuntimes.records[id] { selectedGroupID = record.groupID }
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
            guard let self, self.focusedPane.id == paneID, self.focusedPane.resourceID == resourceID, self.panels.panel == nil, let window = targetWindow else { return }
            if let resourceID, let webView = self.webRuntimes.runtime(for: resourceID)?.webView,
               webView.window === window {
                window.makeFirstResponder(webView)
            } else if let resourceID, let terminalView = self.webRuntimes.terminalSession(for: resourceID)?.nativeView,
                      terminalView.window === window {
                window.makeFirstResponder(terminalView)
            } else {
                if let fallback = self.workspaceFocusView, fallback.window === window { window.makeFirstResponder(fallback) }
            }
        }
    }
    func closePane(_ paneID: UUID) {
        if layout.primary.id == paneID, let secondary = layout.secondary {
            layout = WorkspaceLayout(primary: PaneState(id: secondary.id, resourceID: secondary.resourceID, isFocused: true), splitRatio: layout.splitRatio)
        } else if layout.secondary?.id == paneID { layout.secondary = nil; layout.primary.isFocused = true }
        if let id = layout.primary.resourceID, let record = webRuntimes.records[id] { selectedGroupID = record.groupID }
        refreshActiveWebState()
    }
    func returnToSinglePane() { let focused = layout.primary.isFocused ? layout.primary : (layout.secondary ?? layout.primary); layout = WorkspaceLayout(primary: PaneState(id: focused.id, resourceID: focused.resourceID, isFocused: true)); if let id = focused.resourceID, let record = webRuntimes.records[id] { selectedGroupID = record.groupID }; refreshActiveWebState() }
    func swapPanes() { guard let secondary = layout.secondary else { return }; let primary = layout.primary; layout.primary = secondary; layout.secondary = primary; refreshActiveWebState() }
    func setSplitRatio(_ value: Double) { layout.splitRatio = min(max(value, 0.2), 0.8) }
    private func isMounted(_ id: UUID) -> Bool { layout.primary.resourceID == id || layout.secondary?.resourceID == id }

    var selectedGroup: StudioGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    var visibleTabs: [StudioTab] {
        tabs.filter { $0.groupID == selectedGroupID }
    }

    func newTab(in groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        selectedGroupID = groupID
        let tab = StudioTab(groupID: groupID)
        webRuntimes.registerWeb(groupID: groupID, resourceID: tab.id)
        selectedTabID =
            tab
                .id
    }
    func newTab() {
        newTab(in: selectedGroupID)
    }
    func pinDestination(for id: UUID) {
        guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record) else { return }
        guard !pinnedDestinations.contains(where: { $0.destination == destination }) else { return }
        pinnedDestinations.append(PinnedDestination(title: record.customTitle ?? record.title, destination: destination))
    }
    func isPinned(_ id: UUID) -> Bool {
        guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record) else { return false }
        return pinnedDestinations.contains { $0.destination == destination }
    }
    func unpinDestination(for id: UUID) {
        guard let record = webRuntimes.records[id], let destination = pinnedDestination(for: record) else { return }
        pinnedDestinations.removeAll { $0.destination == destination }
    }
    private func pinnedDestination(for record: ResourceRecord) -> StudioDestination? {
        switch record.location {
        case let .web(url): return url.map(StudioDestination.web)
        case let .localTerminal(directory): return directory.map(StudioDestination.terminal)
        case let .ssh(host, user, port): return .ssh(host: host, user: user, port: port)
        }
    }
    func openStartEntryPanel() { panels.open(.startEntry, targetResourceID: focusedPane.resourceID, paneID: focusedPane.id, originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes) }
    func openStartTerminal(from resourceID: UUID) {
        guard let source = webRuntimes.records[resourceID] else { return }
        let paneID = layout.primary.resourceID == resourceID ? layout.primary.id : (layout.secondary?.resourceID == resourceID ? layout.secondary?.id : nil)
        if let paneID { focusPane(paneID) }
        newTerminal(in: source.groupID, directory: nil)
    }
    func openAgentPanel(_ panel: PanelCoordinator.Panel) { panels.open(panel, targetResourceID: nil, originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes) }
    func openAgentRunDetails(_ runID: UUID) { panels.open(.agentRunDetails(runID), targetResourceID: nil, originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes) }
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
        let sourcePane = layout.primary.resourceID == resourceID ? layout.primary.id : (layout.secondary?.resourceID == resourceID ? layout.secondary?.id : nil)
        switch entry.destination {
        case let .web(url):
            if source.kind == .web, case .web(nil) = source.location {
                webRuntimes.updateWebLocation(resourceID: resourceID, url: url)
                selectedGroupID = groupID
                addressText = url.absoluteString
                recordRecentResource(resourceID)
                if let sourcePane { focusPane(sourcePane) }
            } else { openWebTab(url, sourceResourceID: resourceID) }
        case let .terminal(directory):
            let id = webRuntimes.registerLocalTerminal(groupID: groupID, directory: directory)
            if let sourcePane { focusPane(sourcePane) }
            selectedGroupID = groupID; selectResource(id)
        case let .ssh(host, user, port):
            let id = webRuntimes.registerSSH(groupID: groupID, host: host, user: user, port: port)
            if let sourcePane { focusPane(sourcePane) }
            selectResource(id)
        case .blank: break
        }
    }
    func newTerminal(in groupID: UUID, directory: String? = nil) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        selectedGroupID = groupID
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let id = webRuntimes.registerLocalTerminal(groupID: groupID, directory: cwd)
        selectedTabID = id
    }
    func newTerminal(directory: String? = nil) {
        newTerminal(in: selectedGroupID, directory: directory)
    }
    func newTerminal(directoryURL: URL? = nil) {
        let cwd = directoryURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let id = webRuntimes.registerLocalTerminal(groupID: selectedGroupID, directory: cwd, directoryURL: directoryURL)
        selectedTabID = id
    }
    func newTerminalInFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { newTerminal(directoryURL: url) }
    }

    func selectGroup(_ id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        selectedGroupID = id
        if let tab = tabs.first(where: { $0.groupID == id }) {
            selectedTabID = tab.id
        } else {
            let tab = StudioTab(groupID: id)
            webRuntimes.registerWeb(groupID: id, resourceID: tab.id)
            selectedTabID = tab.id
        }
    }

    func move(tabID: UUID, to groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }),
              webRuntimes.records[tabID] != nil
        else { return }
        webRuntimes.updateGroup(resourceID: tabID, groupID: groupID)
        if selectedTabID == tabID {
            selectedGroupID = groupID
        }
    }

    func addGroup() {
        let group = StudioGroup(name: "New Task")
        groups.append(group)
        selectedGroupID = group.id
        newTab()
        openGroupEditor(group.id)
    }

    func beginRenameGroup(_ id: UUID) {
        openGroupEditor(id)
    }

    func renameSelectedGroup(_ name: String) {
        guard let id = editingGroupID,
              let index = groups.firstIndex(where: { $0.id == id })
        else { return }
        let clean =
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            groups[index].name = clean
        }
        groupEditorPresented = false
    }

    func renameResource(_ id: UUID, title: String) {
        guard var record = webRuntimes.records[id] else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        record.title = clean; record.customTitle = clean
        webRuntimes.update(record)
    }

    func closeSelectedTab() {
        close(tabID: selectedTabID)
    }

    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        if let session = webRuntimes.terminalSession(for: tabID), session.state == .starting || session.state == .running {
            let alert = NSAlert(); alert.messageText = "Terminate terminal?"; alert.informativeText = "This stops the shell and any subprocesses running in this terminal."; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Terminate")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        performClose(tabID: tabID, index: index)
    }
    private func performClose(tabID: UUID, index: Int) {
        let mountedPrimary = layout.primary.resourceID == tabID
        let mountedSecondary = layout.secondary?.resourceID == tabID
        if tabs.count == 1 {
            let groupID = tabs[0].groupID
            webRuntimes.remove(resourceID: tabID)
            let replacement = StudioTab(groupID: groupID)
            webRuntimes.registerWeb(groupID: replacement.groupID, resourceID: replacement.id)
            selectedTabID = replacement.id
            layout = WorkspaceLayout(primary: PaneState(id: layout.primary.id, resourceID: replacement.id, isFocused: true))
            pruneWebRuntimes()
            refreshActiveWebState()
            return
        }
        let wasSelected = selectedTabID == tabID
        let groupID = tabs[index].groupID
        let remaining = tabs.filter { $0.id != tabID }
        let nextID = tabs.enumerated()
            .first(where: { $0.offset > index && $0.element.id != tabID && $0.element.groupID == groupID })?.element.id
            ?? tabs.enumerated().reversed()
                .first(where: { $0.offset < index && $0.element.groupID == groupID })?.element.id
            ?? remaining.first?.id
        webRuntimes.remove(resourceID: tabID)
        if mountedPrimary || mountedSecondary {
            if mountedPrimary, let secondary = layout.secondary, secondary.resourceID != tabID {
                layout = WorkspaceLayout(primary: PaneState(id: secondary.id, resourceID: secondary.resourceID, isFocused: true), splitRatio: layout.splitRatio)
            } else if mountedSecondary { layout.secondary = nil; layout.primary.isFocused = true }
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
        let targetID = targetResourceID ?? addressTargetResourceID ?? panels.targetResourceID ?? selectedTabID
        let capturedPane = addressTargetPaneID ?? panels.targetPaneID
        if let capturedPane, layout.primary.id != capturedPane && layout.secondary?.id != capturedPane {
            if panels.targetPaneID == capturedPane { panels.markTargetClosed() }
            addressError = "The pane used for this address is closed."
            return
        }
        guard let record = webRuntimes.records[targetID]
        else {
            if panels.targetResourceID == targetID { panels.markTargetClosed() }
            addressError = "The selected resource is closed."
            return
        }
        switch destination {
        case .blank:
            guard record.kind == .web else { break }
            webRuntimes.update(ResourceRecord(id: targetID, kind: .web, groupID: record.groupID,
                title: record.customTitle ?? destination.title, location: .web(nil), readCapabilities: [.address, .title, .text], customTitle: record.customTitle))
        case let .terminal(directory):
            // A live terminal owns its PTY and working directory. Opening a path
            // therefore creates a sibling resource even when the source is also a
            // terminal; existing sessions are never retargeted underneath the user.
            let id = webRuntimes.registerLocalTerminal(groupID: record.groupID, directory: directory)
            if let pane = capturedPane { focusPane(pane) }
            selectedGroupID = record.groupID; selectResource(id)
        case let .web(url):
            if record.kind == .web {
                webRuntimes.update(ResourceRecord(id: targetID, kind: .web, groupID: record.groupID,
                    title: record.customTitle ?? destination.title, location: .web(url), readCapabilities: [.address, .title, .text], customTitle: record.customTitle))
                recordRecentResource(targetID)
            } else {
                let id = webRuntimes.registerWeb(groupID: record.groupID, destination: url)
                if let pane = capturedPane { focusPane(pane) }
                selectedGroupID = record.groupID; selectResource(id)
            }
        case let .ssh(host, user, port):
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
        let target = targetResourceID ?? selectedTabID
        let paneID = layout.primary.resourceID == target ? layout.primary.id : (layout.secondary?.resourceID == target ? layout.secondary?.id : nil)
        requestAddressFocus(targetResourceID: target, paneID: paneID)
        addressText = "ssh://"
    }

    var isAddressEditing: Bool { addressIsEditing }

    func requestAddressFocus(targetResourceID: UUID? = nil, paneID: UUID? = nil) {
        if panels.panel != nil { dismissPanel(restoreFocus: false) }
        beginAddressEditing(targetResourceID: targetResourceID, paneID: paneID)
        addressFocusToken &+= 1
        let targetWindow = workspaceFocusView?.window ?? NSApp.keyWindow
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.addressInputField,
                  let targetWindow, field.window === targetWindow else { return }
            targetWindow.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    func beginAddressEditing(targetResourceID: UUID? = nil, paneID: UUID? = nil) {
        guard !addressIsEditing else { return }
        let pane = paneID.flatMap { id in
            [layout.primary, layout.secondary].compactMap { $0 }.first { $0.id == id }
        } ?? targetResourceID.flatMap { id in
            [layout.primary, layout.secondary].compactMap { $0 }.first { $0.resourceID == id }
        } ?? focusedPane
        addressTargetPaneID = pane.id
        addressTargetResourceID = targetResourceID ?? pane.resourceID ?? selectedTabID
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
        case let .web(url): return url?.absoluteString ?? ""
        case let .localTerminal(directory): return directory ?? "terminal"
        case let .ssh(host, user, port):
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
               let field = editor.delegate as? NSTextField { return field }
            return responder
        }()
        panels.open(.commands, targetResourceID: pane.resourceID ?? selectedTabID, paneID: pane.id, originalResponder: originalResponder, store: webRuntimes)
        if let field = commandSearchField, let window = field.window {
            field.isEnabled = true
            field.stringValue = commandQuery
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    func openGroupEditor(_ id: UUID? = nil) {
        editingGroupID = id ?? selectedGroupID
        panels.openGroupEditor(originalResponder: NSApp.keyWindow?.firstResponder)
    }
    func openResourceEditor(_ id: UUID) {
        guard webRuntimes.records[id] != nil else { panels.markTargetClosed(); return }
        panels.open(.resourceEditor(id), targetResourceID: id, originalResponder: NSApp.keyWindow?.firstResponder, store: webRuntimes)
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
        activeWebState = webStates[id] ?? activeWebRuntime?.state ?? WebNavigationState()
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
        recentResourceIDs.removeAll { $0 == id }
        recentResourceIDs.insert(id, at: 0)
        recentResourceIDs = Array(recentResourceIDs.prefix(5))
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
        webStates[tabID] = state
        if let title = state.pageTitle { webRuntimes.updateTitle(resourceID: tabID, title: title) }
        if tabID == selectedTabID {
            activeWebState = state
        }
    }

    // MARK: Shared commands

    /// Only the commands that can actually run right now, in menu order.
    var availableCommands: [StudioCommand] {
        let target = panels.targetResourceID ?? selectedTabID
        let targetGroup = webRuntimes.records[target]?.groupID ?? selectedGroupID
        let targetTabs = tabs.filter { $0.groupID == targetGroup }
        var list: [StudioCommand] = [
            StudioCommand(title: "New Web Page", shortcut: "⌘T", action: .newTab(groupID: targetGroup)),
            StudioCommand(title: "New Terminal", shortcut: "⌘⇧T", action: .newTerminal(groupID: targetGroup, directory: nil)),
            StudioCommand(title: "Close Tab", shortcut: "⌘W", targetResourceID: target, action: .closeResource(resourceID: target)),
            StudioCommand(title: "Open Destination…", shortcut: "⌘L", targetResourceID: target, action: .openDestination(resourceID: target)),
            StudioCommand(title: "New Task Group", shortcut: "", action: .newGroup),
        ]
        if targetTabs.count > 1, let index = targetTabs.firstIndex(where: { $0.id == target }) {
            list.append(StudioCommand(title: "Show Next Tab", shortcut: "⌃Tab", targetResourceID: target, action: .selectResource(resourceID: targetTabs[(index + 1) % targetTabs.count].id)))
            list.append(StudioCommand(title: "Show Previous Tab", shortcut: "⌃⇧Tab", targetResourceID: target, action: .selectResource(resourceID: targetTabs[(index - 1 + targetTabs.count) % targetTabs.count].id)))
        }
        let capturedRuntime = webRuntimes.existingRuntime(for: target)
        let capturedWeb: Bool = {
            guard let record = webRuntimes.records[target], case let .web(url) = record.location else { return false }
            return url != nil
        }()
        if (webStates[target]?.canGoBack ?? capturedRuntime?.state.canGoBack ?? false) {
            list.append(StudioCommand(title: "Back", shortcut: "⌘[", targetResourceID: target, action: .back(resourceID: target)))
        }
        if (webStates[target]?.canGoForward ?? capturedRuntime?.state.canGoForward ?? false) {
            list.append(StudioCommand(title: "Forward", shortcut: "⌘]", targetResourceID: target, action: .forward(resourceID: target)))
        }
        if capturedWeb {
            let loading = webStates[target]?.isLoading ?? capturedRuntime?.state.isLoading ?? false
            list.append(
                StudioCommand(title: loading ? "Stop Loading" : "Reload Page", shortcut: "⌘R", targetResourceID: target, action: loading ? .stop(resourceID: target) : .reload(resourceID: target))
            )
        }
        list.append(StudioCommand(title: "Toggle Tab Strip", shortcut: "⌘⌥S", action: .toggleSidebar))
        list.append(StudioCommand(title: "Toggle Agents", shortcut: "⌘⌥A", action: .toggleAgents))
        for record in webRuntimes.resources where record.id != target {
            list.append(StudioCommand(title: "Select \(record.customTitle ?? record.title)", shortcut: "", targetResourceID: record.id, action: .selectResource(resourceID: record.id)))
        }
        return list
    }

    var filteredCommandCount: Int {
        availableCommands.filter { commandQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(commandQuery) }.count
    }

    func executeSelectedCommand() {
        guard panels.panel == .commands else { return }
        let commands = availableCommands.filter { commandQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(commandQuery) }
        guard commands.indices.contains(commandSelectedIndex) else { return }
        let command = commands[commandSelectedIndex]
        let oldPanel = panels.panel
        if execute(command), panels.panel == oldPanel, oldPanel != nil {
            switch command.action {
            case .newTab, .newTerminal, .selectResource:
                dismissPanel(restoreFocus: false); focusCurrentPaneContent()
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
           layout.primary.id != paneID && layout.secondary?.id != paneID {
            panels.markTargetClosed()
            return false
        }
        if let id = command.targetResourceID, webRuntimes.records[id] == nil { panels.markTargetClosed(); return false }
        if panels.targetResourceID != nil,
           webRuntimes.records[panels.targetResourceID!] == nil {
            panels.markTargetClosed()
            return false
        }
        func focusCapturedPaneForViewChange() -> Bool {
            guard let paneID = panels.targetPaneID else { return true }
            guard layout.primary.id == paneID || layout.secondary?.id == paneID else {
                panels.markTargetClosed(); return false
            }
            focusPane(paneID)
            return true
        }
        switch command.action {
        case let .newTab(groupID):
            guard focusCapturedPaneForViewChange() else { return false }
            newTab(in: groupID); selectResource(selectedTabID)
        case let .newTerminal(groupID, directory):
            guard focusCapturedPaneForViewChange() else { return false }
            newTerminal(in: groupID, directory: directory); selectResource(selectedTabID)
        case let .closeResource(id): close(tabID: id)
        case let .openDestination(id): requestAddressFocus(targetResourceID: id, paneID: panels.targetPaneID)
        case .newGroup: addGroup()
        case let .selectResource(id):
            guard let record = webRuntimes.records[id] else { panels.markTargetClosed(); return false }
            guard focusCapturedPaneForViewChange() else { return false }
            selectedGroupID = record.groupID; selectResource(id)
        case let .back(id): webRuntimes.runtime(for: id)?.goBack()
        case let .forward(id): webRuntimes.runtime(for: id)?.goForward()
        case let .reload(id): webRuntimes.runtime(for: id)?.reload()
        case let .stop(id): webRuntimes.runtime(for: id)?.stop()
        case .toggleSidebar: tabStripVisible.toggle()
        case .toggleAgents: agentsVisible.toggle()
        }
        return true
    }

    static func normalizedWebURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty
        else { return nil }
        guard !value.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }) else { return nil }
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
            let authority = value.dropFirst("ssh://".count).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let components = URLComponents(string: value),
                  !authority.hasSuffix(":"),
                  let host = components.host,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  let destination = normalizedSSH(host: host, user: components.user ?? "", portText: components.port.map(String.init) ?? "22")
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
              !expanded.contains(where: { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } })
        else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func parseSSHHostPort(_ value: String, user: String) -> StudioDestination? {
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<end])
            let suffix = String(value[value.index(after: end)...])
            guard suffix.isEmpty || (suffix.hasPrefix(":") && !suffix.dropFirst().isEmpty && suffix.dropFirst().allSatisfy(\.isNumber)) else { return nil }
            let port = suffix.hasPrefix(":") ? String(suffix.dropFirst()) : "22"
            return normalizedSSH(host: host, user: user, portText: port)
        }
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        if pieces.count == 2, Int(pieces[1]) != nil {
            return normalizedSSH(host: String(pieces[0]), user: user, portText: String(pieces[1]))
        }
        if value.contains(":"), let destination = normalizedSSH(host: value, user: user, portText: "22") { return destination }
        return normalizedSSH(host: value, user: user, portText: "22")
    }

    static func addressError(for input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("ssh://") || value.contains("@") { return "Enter a valid SSH host, optional user, and port." }
        if value.hasPrefix("terminal") || value.hasPrefix("/") || value.hasPrefix("~/") { return "Enter an absolute or ~ local directory path." }
        if value.contains("://") && !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") { return "Unsupported address scheme." }
        return "Enter an HTTP(S) address, SSH host, or local directory path."
    }

    static func normalizedSSH(host: String, user: String, portText: String) -> StudioDestination? {
        let hasControl: (String) -> Bool = { value in
            value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
        guard !hasControl(host), !hasControl(user), !hasControl(portText) else { return nil }
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let cleanUser =
            user
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let hostLooksValid: Bool = {
            if cleanHost.contains(":") {
                let candidate = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                var address = in6_addr()
                return candidate.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
            }
            if cleanHost.withCString({ value in var address = in_addr(); return inet_pton(AF_INET, value, &address) == 1 }) { return true }
            let labels = cleanHost.split(separator: ".", omittingEmptySubsequences: false)
            if labels.count == 4 && labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
            return cleanHost.count <= 253 && !labels.isEmpty && labels.allSatisfy { label in
                label.count <= 63 && !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
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
        guard (1 ... 65535).contains(port)
        else { return nil }
        guard !cleanUser.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "@" }),
              !cleanHost.hasPrefix("-"), !cleanUser.hasPrefix("-") else { return nil }
        return .ssh(
            host: cleanHost,
            user: cleanUser,
            port: port
        )
    }
}

struct StudioLayoutPlan: Equatable {
    let sidebarWidth: CGFloat
    let agentsWidth: CGFloat
    let compactSidebar: Bool
    let adaptationMessage: String?

    static func resolve(
        windowWidth: CGFloat,
        sidebarWidth: CGFloat,
        agentsWidth: CGFloat,
        sidebarVisible: Bool,
        agentsVisible: Bool
    ) -> Self {
        let minimumMain: CGFloat = 440
        let dividerBudget: CGFloat = (sidebarVisible ? 6 : 0) + (agentsVisible ? 6 : 0)
        var left = sidebarVisible ? min(max(sidebarWidth, 96), 320) : 0
        var right = agentsVisible ? min(max(agentsWidth, 220), 360) : 0
        var compact = false
        var message: String?
        if sidebarVisible, windowWidth - left - right - dividerBudget < minimumMain {
            left = 96
            compact = true
        }
        if windowWidth - left - right - dividerBudget < minimumMain, agentsVisible {
            right = max(0, windowWidth - left - minimumMain - dividerBudget)
            message = "Agents panel narrowed to preserve the workspace."
        } else if compact {
            message = "Task strip compacted to preserve the workspace."
        }
        return .init(
            sidebarWidth: left,
            agentsWidth: right,
            compactSidebar: compact,
            adaptationMessage: message
        )
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
                agentsVisible: model.agentsVisible
            )
            HStack(spacing: 0) {
                if model.tabStripVisible {
                    TabStrip(model: model, compact: plan.compactSidebar)
                        .frame(width: plan.sidebarWidth)
                    Divider().frame(width: 6).contentShape(Rectangle()).gesture(resizeSidebar)
                        .help("Resize task strip")
                }
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        TabContent(model: model)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity)
                if model.agentsVisible {
                    Divider().frame(width: 6).contentShape(Rectangle()).gesture(resizeAgents)
                        .help("Resize Agents panel")
                    AgentInspectorView(model: model).frame(width: plan.agentsWidth)
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
                    .animation(StudioDesign.Motion.animation(StudioDesign.Motion.panel, reduceMotion: reduceMotion), value: panelHostVisible)
                    StudioPanelSurface { CommandPalette(model: model) }
                        .opacity(model.panels.panel == .commands ? 1 : 0)
                        .offset(y: model.panels.panel == .commands || reduceMotion ? 0 : 6)
                        .scaleEffect(model.panels.panel == .commands || reduceMotion ? 1 : 0.98)
                        .allowsHitTesting(model.panels.panel == .commands)
                        .disabled(model.panels.panel != .commands)
                        .accessibilityHidden(model.panels.panel != .commands)
                        .animation(StudioDesign.Motion.animation(StudioDesign.Motion.panel, reduceMotion: reduceMotion), value: model.panels.panel == .commands)
                }
            }
            .onAppear { syncPanelHost(model.panels.panel) }
            .onChange(of: model.panels.panel) { _, panel in syncPanelHost(panel) }
    }

    @ViewBuilder private func panelContent(_ panel: PanelCoordinator.Panel) -> some View {
        if panel == .groupEditor { StudioPanelSurface { GroupEditor(model: model) } }
        if case .resourceEditor = panel { StudioPanelSurface { ResourceEditor(model: model) } }
        if panel == .providerSettings { StudioPanelSurface { ProviderSettingsView(settings: model.providerSettings, model: model) } }
        if panel == .startEntry { StudioPanelSurface { StartEntryView(model: model) } }
        if panel == .agentResources { StudioPanelSurface { AgentResourcesPanel(model: model) } }
        if panel == .agentPreview { StudioPanelSurface { AgentPreviewPanel(model: model) } }
        if case let .agentRunDetails(runID) = panel { StudioPanelSurface { AgentRunDetailsPanel(model: model, runID: runID) } }
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
        case let .resourceEditor(id): return "resource-editor-\(id.uuidString)"
        case .providerSettings: return "provider-settings"
        case .startEntry: return "start-entry"
        case .agentResources: return "agent-resources"
        case .agentPreview: return "agent-preview"
        case let .agentRunDetails(id): return "agent-run-details-\(id.uuidString)"
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
                    model.requestAddressFocus(); return nil
                }
                if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
                    model.openCommands(); return nil
                }
                if event.keyCode == 53, model.panels.panel == .commands,
                   let editor = model.commandSearchField?.currentEditor() as? NSTextView, editor.hasMarkedText() {
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
            if window == nil, model.workspaceFocusView === self { model.workspaceFocusView = nil }
            else if window != nil { model.workspaceFocusView = self }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct StudioWindowRoot: View {
    @StateObject private var model = StudioModel()
    var body: some View {
        ContentView(model: model).focusedSceneValue(\.studioModel, model)
    }
}

private struct StudioAddressField: View {
    @ObservedObject var model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            NativeAddressField(model: model)
                .frame(minWidth: 220, idealWidth: 360, maxWidth: 520)
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
        .overlay(Capsule().stroke(model.isAddressEditing ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1))
        .animation(StudioDesign.Motion.animation(StudioDesign.Motion.hover, reduceMotion: reduceMotion), value: model.isAddressEditing)
        .help("Address (⌘L)")
    }
}

private final class AddressTextField: NSTextField {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}

private struct NativeAddressField: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField(string: model.addressText)
        field.placeholderString = "Enter website, SSH host, or terminal path"
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
        field.setAccessibilityLabel("Address")
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
        init(model: StudioModel) { self.model = model; self.lastFocusToken = model.addressFocusToken }

        @objc func submit(_ sender: NSTextField) {
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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
            if field.stringValue != model.addressText, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
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
            Button {
                model.tabStripVisible.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }.studioGlassButton().frame(minWidth: 28, minHeight: 28).help("Toggle task strip (⌘⌥S)")
                .accessibilityLabel("Toggle tab strip")
                .accessibilityValue(model.tabStripVisible ? "Shown" : "Hidden")
            Button {
                model.webGoBack()
            } label: {
                Image(systemName: "chevron.left")
            }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
                .disabled(!model.activeWebState.canGoBack)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
                .accessibilityIdentifier("web.back")
            Button {
                model.webGoForward()
            } label: {
                Image(systemName: "chevron.right")
            }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
                .disabled(!model.activeWebState.canGoForward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
                .accessibilityIdentifier("web.forward")
            Button {
                model.webReloadOrStop()
            } label: {
                Image(systemName: model.activeWebState.isLoading ? "xmark" : "arrow.clockwise")
            }.studioGlassButton().frame(minWidth: 28, minHeight: 28)
                .disabled(!model.selectedTabIsWeb)
                .help(model.activeWebState.isLoading ? "Stop loading" : "Reload (⌘R)")
                .accessibilityLabel(model.activeWebState.isLoading ? "Stop loading" : "Reload")
                .accessibilityIdentifier("web.reloadOrStop")
        }
        ToolbarItem(placement: .principal) {
            StudioAddressField(model: model)
        }.sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(model.visibleTabs) { tab in
                    Button {
                        model.selectResource(tab.id)
                    } label: {
                        HStack {
                            Label(tab.displayTitle, systemImage: icon(for: tab))
                            Spacer()
                            if tab.id == model.selectedTabID { Image(systemName: "checkmark") }
                        }
                    }
                }
                Divider()
                Button {
                    model.newTab(in: model.selectedGroupID)
                } label: {
                    Label("New Web Page", systemImage: studioResourceSymbol(.web))
                }
                .accessibilityIdentifier("workspace.tabs.newWebPage")
                Button {
                    model.newTerminal(in: model.selectedGroupID)
                } label: {
                    Label("New Terminal", systemImage: studioResourceSymbol(.localTerminal))
                }
                .accessibilityIdentifier("workspace.tabs.newTerminal")
            } label: {
                Label(model.selectedTab?.displayTitle ?? "New Tab", systemImage: icon(for: model.selectedTab))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: 220)
            .padding(.horizontal, StudioDesign.Spacing.control).padding(.vertical, 7)
            .studioGlassCapsule()
            .accessibilityLabel("Tabs in \(model.selectedGroup?.name ?? "workspace")")
            .accessibilityIdentifier("workspace.tabs.menu")
        }.sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.openCommands()
            } label: {
                Label(
                    "Commands",
                    systemImage: "command"
                )
            }.studioGlassButton().frame(minHeight: 28).help("Command palette (⌘K)")
                .accessibilityIdentifier("commands.button")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Split") { model.split() }.disabled(model.layout.isSplit)
                Button("Focus Other Pane") { model.focusOtherPaneAndContent() }.disabled(!model.layout.isSplit)
                Button("Close Focused Pane") { model.closePane(model.focusedPane.id) }.disabled(!model.layout.isSplit)
                Button("Single Pane") { model.returnToSinglePane() }.disabled(!model.layout.isSplit)
                Button("Swap Panes") { model.swapPanes() }.disabled(!model.layout.isSplit)
                Divider()
                Button("Narrow Left") { model.setSplitRatio(model.layout.splitRatio - 0.05) }.disabled(!model.layout.isSplit)
                Button("Widen Left") { model.setSplitRatio(model.layout.splitRatio + 0.05) }.disabled(!model.layout.isSplit)
                Button("Reset Ratio") { model.setSplitRatio(0.5) }.disabled(!model.layout.isSplit)
            } label: { Image(systemName: "rectangle.split.2x1").frame(minWidth: 28, minHeight: 28) }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .studioGlassCapsule()
                .accessibilityLabel("Layout")
                .accessibilityIdentifier("layout.menu")
        }.sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.agentsVisible.toggle()
            } label: {
                Image(systemName: "person.2")
            }.studioGlassButton().frame(minWidth: 28, minHeight: 28).help("Toggle Agents (⌘⌥A)")
                .accessibilityLabel("Toggle Agents")
                .accessibilityValue(model.agentsVisible ? "Shown" : "Hidden")
                .accessibilityIdentifier("agents.button")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !compact {
                    Text("Tasks").font(.headline)
                }
                Spacer()
                Button {
                    model.addGroup()
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus").frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(StudioPressButtonStyle()).help("New task group")
                .accessibilityLabel("New task group")
                .accessibilityIdentifier("groups.new")
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
                                        Label(group.name, systemImage: "square.stack.3d.up")
                                    }
                                }.buttonStyle(StudioPressButtonStyle()).help(group.name)
                                    .accessibilityAddTraits(model.selectedGroupID == group.id ? .isSelected : [])
                                    .accessibilityLabel("Task group \(group.name)")
                                    .accessibilityIdentifier("group.\(group.id.uuidString)").frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    ).lineLimit(1)
                                Button {
                                    model.newTab(in: group.id)
                                } label: {
                                    Image(systemName: studioResourceSymbol(.web)).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                                }
                                .buttonStyle(StudioPressButtonStyle())
                                .help("New Web Page in \(group.name) (⌘T)")
                                .accessibilityLabel("New Web Page in \(group.name)")
                                .accessibilityIdentifier("tabs.new.\(group.id.uuidString)")
                                Button {
                                    model.newTerminal(in: group.id)
                                } label: {
                                    Image(systemName: studioResourceSymbol(.localTerminal)).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                                }
                                .buttonStyle(StudioPressButtonStyle())
                                .help("New Terminal in \(group.name) (⌘⇧T)")
                                .accessibilityLabel("New Terminal in \(group.name)")
                                .accessibilityIdentifier("terminals.new.\(group.id.uuidString)")
                            }
                            .padding(.horizontal, compact ? 0 : 6)
                            .background(
                                model.selectedGroupID == group.id ? StudioDesign.Color.groupSelectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .animation(StudioDesign.Motion.animation(StudioDesign.Motion.hover, reduceMotion: reduceMotion), value: model.selectedGroupID)
                            .contextMenu { Button("Rename Task") { model.beginRenameGroup(group.id) } }
                            if model.selectedGroupID == group.id {
                                ForEach(model.visibleTabs) { tab in
                                        ResourceRow(model: model, tab: tab, compact: compact, selectionNamespace: selectionNamespace)
                                }
                            }
                        }
                    }
                }
            }
            Spacer()
        }.padding(10)
            .studioShellScrim()
    }

}

private struct ResourceRow: View {
    @ObservedObject var model: StudioModel
    let tab: StudioTab
    let compact: Bool
    let selectionNamespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let selected = model.selectedTabID == tab.id
        let record = model.webRuntimes.records[tab.id]
        let symbol = record.map { studioResourceSymbol($0.kind) } ?? studioResourceSymbol(tab.destination)
        return HStack(spacing: 3) {
            Button { model.selectedTabID = tab.id } label: {
                HStack(spacing: 7) {
                    Image(systemName: symbol).accessibilityHidden(true)
                    if !compact { Text(tab.displayTitle).lineLimit(1) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(StudioPressButtonStyle()).accessibilityAddTraits(selected ? .isSelected : []).accessibilityLabel("Resource \(tab.displayTitle)").accessibilityIdentifier("resource.\(tab.id.uuidString)")
            Button { model.close(tabID: tab.id) } label: { Image(systemName: "xmark").font(.caption2).frame(minWidth: 24, minHeight: 24).contentShape(Rectangle()) }.buttonStyle(StudioPressButtonStyle()).accessibilityLabel("Close resource \(tab.displayTitle)").accessibilityIdentifier("resource.close.\(tab.id.uuidString)").help("Close resource")
        }.padding(.leading, compact ? 0 : 14).padding(.horizontal, 4).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? StudioDesign.Color.selectedFill : .clear, in: RoundedRectangle(cornerRadius: StudioDesign.Radius.row, style: .continuous))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 18)
                        .matchedGeometryEffect(id: "resource-selection", in: selectionNamespace)
                }
            }
            .animation(StudioDesign.Motion.animation(StudioDesign.Motion.selection, reduceMotion: reduceMotion), value: selected)
            .contextMenu {
                Button("Rename Resource") { model.openResourceEditor(tab.id) }
                Button("Add to Agent") { model.agentsVisible = true; model.agentController.addResource(tab.id) }
                Menu("Move to") { ForEach(model.groups.filter { $0.id != tab.groupID }) { target in Button(target.name) { model.move(tabID: tab.id, to: target.id) } } }
            }
    }

}

private struct GroupEditor: View {
    @ObservedObject var model: StudioModel
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename task group").font(.headline)
            StudioFieldLabel(title: "Name")
            TextField(
                "Name",
                text: $name
            ).textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    model.renameSelectedGroup(name)
                }
            HStack {
                Button("Cancel") { model.groupEditorPresented = false }.studioGlassButton()
                Spacer()
                Button("Save") {
                    model.renameSelectedGroup(name)
                }.studioGlassButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(StudioDesign.Spacing.inset).onAppear {
                name = model.groups.first(where: { $0.id == model.editingGroupID })?.name ?? ""
                DispatchQueue.main.async { if model.panels.panel == .groupEditor { focused = true } }
            }
            .frame(width: 300)
            .onExitCommand { model.groupEditorPresented = false }
    }
}

private struct ResourceEditor: View {
    @ObservedObject var model: StudioModel
    @State private var title = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename resource").font(.headline)
            if let error { StudioInlineFeedback(message: error, isError: true) }
            StudioFieldLabel(title: "Resource name")
            TextField("Resource name", text: $title).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("resource.rename.field")
            HStack {
                Button("Cancel") { model.dismissPanel() }.studioGlassButton()
                Spacer()
                Button("Save") { guard let id = model.panelTargetResourceID, model.webRuntimes.records[id] != nil else { error = "The resource was closed."; return }; model.renameResource(id, title: title); model.dismissPanel() }
                    .studioGlassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(StudioDesign.Spacing.inset).frame(width: 320)
            .onAppear { if let id = model.panelTargetResourceID, let record = model.webRuntimes.records[id] { title = record.customTitle ?? record.title; DispatchQueue.main.async { if model.panels.panel == .resourceEditor(id) { focused = true } } } else { error = "The resource was closed." } }
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
    @ObservedObject var session: TerminalSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case let .failed(message) = session.state { Text(message).foregroundStyle(.red).padding(.horizontal, 8) }
            Text(statusText).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            TerminalNativeView(view: session.nativeView)
        }
    }
    private var statusText: String { switch session.state { case .starting: "Starting terminal…"; case .running: "Terminal running"; case .exited(let code): code.map { "Exited (\($0))" } ?? "Exited (status unavailable)"; case .interrupted: "Interrupted"; case .failed: "Terminal failed"; case .idle: "Idle" } }
}
private struct TerminalNativeView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NativeResourceContainer {
        let container = NativeResourceContainer(); container.mount(view); return container
    }
    func updateNSView(_ nsView: NativeResourceContainer, context: Context) { nsView.mount(view) }
    static func dismantleNSView(_ nsView: NativeResourceContainer, coordinator: ()) { nsView.unmount() }
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
            Text("Open destination")
                .font(.headline)
            Text("Target: \(targetTitle)").font(.caption).foregroundStyle(.secondary)
            if let panelError = model.panels.errorMessage {
                Text(panelError).font(.caption).foregroundStyle(.red)
            }
            Picker("Mode", selection: $mode) {
                Text("Web").tag(0)
                Text("SSH").tag(1)
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("destination.mode")
            if mode == 0 {
                StudioFieldLabel(title: "Web address")
                TextField("https://example.com", text: $webAddress).textFieldStyle(.roundedBorder)
                    .focused(
                        $focusedField,
                        equals: .web
                    ).accessibilityIdentifier("web.address")
                    .onSubmit { submitWeb() }
                Text("Enter a URL or bare domain. A terminal target opens a related web resource and stays open.").font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                StudioFieldLabel(title: "SSH host")
                TextField("Host", text: $sshHost).textFieldStyle(.roundedBorder).focused(
                    $focusedField,
                    equals: .host
                ).accessibilityIdentifier("ssh.host")
                    .accessibilityLabel("SSH host")
                StudioFieldLabel(title: "User (optional)")
                TextField("User (optional)", text: $sshUser)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("ssh.user")
                StudioFieldLabel(title: "Port")
                TextField(
                    "Port",
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
                Button("Cancel") { model.destinationPresented = false }.studioGlassButton()
                Spacer()
                    .accessibilityIdentifier("destination.cancel")
                Button("Open") { submit() }
                    .studioGlassButton(prominent: true).keyboardShortcut(.defaultAction).accessibilityIdentifier("destination.open")
            }
        }.padding(StudioDesign.Spacing.inset).frame(width: 330)
            .onAppear {
                prefill()
                DispatchQueue.main.async { if model.panels.panel == .destination { focusedField = mode == 0 ? .web : .host } }
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
            error = "Enter a valid host and port (1–65535)."
            focusedField = sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .host : .port
        }
    }

    private func submitWeb() {
        if let url = StudioModel.normalizedWebURL(webAddress) {
            model.setDestination(.web(url))
        } else {
            error = "Enter a valid HTTP or HTTPS URL."
            focusedField = .web
        }
    }

    private func prefill() {
        guard let id = model.panelTargetResourceID,
              let destination = model.tabs.first(where: { $0.id == id })?.destination
        else { return }
        switch destination {
        case .terminal:
            mode = 0; webAddress = ""
        case let .web(url):
            mode = 0
            webAddress = url.absoluteString
        case let .ssh(
            host,

            user,

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
        guard let id = model.panelTargetResourceID else { return "None" }
        return model.tabs.first(where: { $0.id == id })?.displayTitle ?? "Closed resource"
    }
}

private struct CommandSearchField: NSViewRepresentable {
    @ObservedObject var model: StudioModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: model.commandQuery)
        field.placeholderString = "Search commands"
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search commands")
        field.setAccessibilityIdentifier("command.search")
        model.commandSearchField = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let active = model.panels.panel == .commands
        field.isEnabled = active
        if !active, let window = field.window,
           (window.firstResponder === field || field.currentEditor() === window.firstResponder),
           let fallback = model.workspaceFocusView, fallback.window === window {
            window.makeFirstResponder(fallback)
        }
        if field.stringValue != model.commandQuery,
           (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
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
            model.commandQuery = field.stringValue
            model.commandSelectedIndex = 0
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard model.panels.panel == .commands, !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                model.commandSelectedIndex = max(0, model.commandSelectedIndex - 1); return true
            case #selector(NSResponder.moveDown(_:)):
                model.commandSelectedIndex = min(max(model.filteredCommandCount - 1, 0), model.commandSelectedIndex + 1); return true
            case #selector(NSResponder.insertNewline(_:)):
                model.executeSelectedCommand(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.dismissPanel(); return true
            default: return false
            }
        }
    }
}

private struct CommandPalette: View {
    @ObservedObject var model: StudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command palette").font(.headline)
            Text("Target: \(targetTitle)").font(.caption).foregroundStyle(.secondary)
            if let panelError = model.panels.errorMessage {
                Text(panelError).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                CommandSearchField(model: model).frame(maxWidth: .infinity, minHeight: 22)
                if !model.commandQuery.isEmpty {
                    Button {
                        model.commandQuery = ""
                        model.commandSelectedIndex = 0
                        if let field = model.commandSearchField, let window = field.window { window.makeFirstResponder(field) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("command.search.clear")
                }
            }
            if filtered.isEmpty {
                Text("No available commands").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(filtered.enumerated()),
                                id: \.element.id
                            ) { index, item in
                                Button {
                                    run(item.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: icon(for: item))
                                            .frame(width: 20)
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        Text(item.title)
                                            .lineLimit(1)
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
                                    index == model.commandSelectedIndex ? Color(nsColor: .controlBackgroundColor) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .id(item.id)
                                .accessibilityIdentifier("command.\(item.title)")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: commandListHeight)
                    .accessibilityIdentifier("command.results")
                    .onChange(of: model.commandSelectedIndex) { _, index in
                        guard filtered.indices.contains(index) else { return }
                        withAnimation(StudioDesign.Motion.animation(StudioDesign.Motion.selection, reduceMotion: reduceMotion)) { proxy.scrollTo(filtered[index].id, anchor: .center) }
                    }
                }
            }
        }
        .padding(StudioDesign.Spacing.inset)
        .frame(width: 320)
            .onExitCommand { model.commandPalettePresented = false }
    }

    private var filtered: [StudioCommand] {
        model.availableCommands
            .filter { model.commandQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(model.commandQuery) }
    }

    private var commandListHeight: CGFloat {
        min(max(CGFloat(filtered.count) * 34 + 4, 40), 360)
    }

    private var targetTitle: String {
        guard let id = model.panelTargetResourceID else { return "None" }
        return model.tabs.first(where: { $0.id == id })?.displayTitle ?? "Closed resource"
    }

    private func icon(for command: StudioCommand) -> String {
        switch command.action {
        case .newTab: return studioResourceSymbol(.web)
        case .newTerminal: return studioResourceSymbol(.localTerminal)
        case .newGroup: return "rectangle.stack.badge.plus"
        case .closeResource: return "xmark"
        case .openDestination: return "arrow.up.forward"
        case let .selectResource(resourceID):
            guard let record = model.webRuntimes.records[resourceID] else { return studioResourceSymbol(.web) }
            return studioResourceSymbol(record.kind)
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
