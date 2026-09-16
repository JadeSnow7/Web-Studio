import Foundation
import Combine
import AppKit

enum ResourceKind: String, Codable, Equatable, Sendable { case web, localTerminal, sshTerminal }
enum ResourceLifecycle: String, Codable, Equatable, Sendable { case idle, starting, running, exited, failed, interrupted, closed }
struct ResourceReadCapabilities: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int
    static let address = Self(rawValue: 1 << 0)
    static let title = Self(rawValue: 1 << 1)
    static let text = Self(rawValue: 1 << 2)
    static let output = Self(rawValue: 1 << 3)
}
enum ResourceLocation: Equatable, Sendable {
    case web(URL?)
    case localTerminal(directory: String?)
    case ssh(host: String, user: String, port: Int)
}
struct ResourceRecord: Identifiable, Equatable, Sendable {
    let id: UUID; var kind: ResourceKind; var groupID: UUID; var title: String
    var location: ResourceLocation; var lifecycle: ResourceLifecycle; var errorMessage: String?
    var readCapabilities: ResourceReadCapabilities
    /// A user supplied title is distinct from a page title reported by WebKit.
    var customTitle: String? = nil
    init(id: UUID = UUID(), kind: ResourceKind, groupID: UUID, title: String, location: ResourceLocation,
         lifecycle: ResourceLifecycle = .idle, errorMessage: String? = nil,
         readCapabilities: ResourceReadCapabilities = [], customTitle: String? = nil) {
        self.id=id; self.kind=kind; self.groupID=groupID; self.title=title; self.location=location
        self.lifecycle=lifecycle; self.errorMessage=errorMessage; self.readCapabilities=readCapabilities; self.customTitle=customTitle
    }
}
struct ResourceSnapshot: Equatable, Sendable {
    let resourceID: UUID; let collectedAt: Date; let text: String?; let isTruncated: Bool
    let errorMessage: String?; let sourceURL: URL?; let title: String?; let range: Range<Int>?
    let knownDirectory: String?; let lifecycle: ResourceLifecycle?; let runtimeErrorMessage: String?
    init(resourceID: UUID, collectedAt: Date, text: String?, isTruncated: Bool, errorMessage: String?, sourceURL: URL?, title: String?, range: Range<Int>?, knownDirectory: String? = nil, lifecycle: ResourceLifecycle? = nil, runtimeErrorMessage: String? = nil) {
        self.resourceID = resourceID; self.collectedAt = collectedAt; self.text = text; self.isTruncated = isTruncated; self.errorMessage = errorMessage; self.sourceURL = sourceURL; self.title = title; self.range = range; self.knownDirectory = knownDirectory; self.lifecycle = lifecycle; self.runtimeErrorMessage = runtimeErrorMessage
    }
    static func failure(resourceID: UUID, message: String, url: URL? = nil) -> Self {
        Self(resourceID: resourceID, collectedAt: Date(), text: nil, isTruncated: false,
             errorMessage: message, sourceURL: url, title: nil, range: nil)
    }
}
struct PaneState: Identifiable, Equatable, Sendable {
    let id: UUID
    var resourceID: UUID?
    var isFocused: Bool = false
    init(id: UUID = UUID(), resourceID: UUID?, isFocused: Bool = false) { self.id = id; self.resourceID = resourceID; self.isFocused = isFocused }
}
struct WorkspaceLayout: Equatable, Sendable {
    var primary: PaneState; var secondary: PaneState?; var splitRatio: Double = 0.5
    var isSplit: Bool { secondary != nil }
    init(primary: PaneState, secondary: PaneState? = nil, splitRatio: Double = 0.5) {
        self.primary=primary; self.secondary=secondary; self.splitRatio=min(max(splitRatio, 0.2), 0.8)
    }
}
struct PinnedDestination: Identifiable, Equatable {
    let id: UUID
    var title: String
    var destination: StudioDestination
    init(id: UUID = UUID(), title: String, destination: StudioDestination) { self.id = id; self.title = title; self.destination = destination }
}

/// Owns the transient native panels and the resource they were opened against.
/// Keeping this separate from selection prevents a panel action from silently
/// retargeting when the user switches resources while the panel is open.
@MainActor final class PanelCoordinator: ObservableObject {
    enum Panel: Equatable { case destination, commands, groupEditor, resourceEditor(UUID), providerSettings, startEntry, agentResources, agentPreview, agentRunDetails(UUID) }
    @Published private(set) var panel: Panel?
    @Published private(set) var targetResourceID: UUID?
    @Published private(set) var targetPaneID: UUID?
    @Published private(set) var errorMessage: String?
    weak var originalResponder: NSResponder?
    weak var originalWindow: NSWindow?

    var isDestinationPresented: Bool { panel == .destination }
    var isCommandsPresented: Bool { panel == .commands }
    var isGroupEditorPresented: Bool { panel == .groupEditor }

    func openDestination(targetResourceID: UUID, paneID: UUID? = nil, originalResponder: NSResponder?, store: ResourceStore) {
        open(.destination, targetResourceID: targetResourceID, paneID: paneID, originalResponder: originalResponder, store: store)
    }

    func openCommands(targetResourceID: UUID, paneID: UUID? = nil, originalResponder: NSResponder?, store: ResourceStore) {
        open(.commands, targetResourceID: targetResourceID, paneID: paneID, originalResponder: originalResponder, store: store)
    }

    func openGroupEditor(originalResponder: NSResponder?) {
        if panel == nil { self.originalResponder = originalResponder; self.originalWindow = (originalResponder as? NSView)?.window ?? NSApp.keyWindow }
        panel = .groupEditor; targetResourceID = nil; errorMessage = nil
    }

    func open(_ panel: Panel, targetResourceID: UUID?, paneID: UUID? = nil, originalResponder: NSResponder?, store: ResourceStore) {
        let resourcePanel: Bool = { if case .resourceEditor = panel { return true }; return false }()
        let contextPanel = panel == .startEntry || panel == .agentResources || panel == .agentPreview || { if case .agentRunDetails = panel { return true }; return false }()
        guard panel == .groupEditor || panel == .providerSettings || resourcePanel || contextPanel || (targetResourceID != nil && store.records[targetResourceID!] != nil) else {
            self.panel = nil
            self.targetResourceID = nil
            self.originalResponder = nil
            errorMessage = "The selected resource is closed."
            return
        }
        if self.panel == nil {
            self.originalResponder = originalResponder
            self.originalWindow = (originalResponder as? NSView)?.window ?? NSApp.keyWindow
        }
        self.panel = panel
        self.targetResourceID = targetResourceID
        self.targetPaneID = paneID
        errorMessage = nil
    }

    func close(window: NSWindow? = nil, restoreFocus: Bool = true, fallback: (() -> Void)? = nil) {
        panel = nil
        targetResourceID = nil
        targetPaneID = nil
        errorMessage = nil
        let responder = originalResponder
        let restoreWindow = originalWindow ?? window
        originalResponder = nil
        if restoreFocus, let responder, let restoreWindow, (responder as? NSView)?.window === restoreWindow {
            if !restoreWindow.makeFirstResponder(responder) { fallback?() }
        } else if restoreFocus {
            fallback?()
        }
        originalWindow = nil
    }

    func markTargetClosed() {
        errorMessage = "The resource this panel was opened for is closed."
    }
}

@MainActor final class ResourceStore: ObservableObject {
    private static var liveStores: [WeakStore] = []
    private final class WeakStore { weak var value: ResourceStore?; init(_ value: ResourceStore) { self.value = value } }
    let launchTerminalProcesses: Bool
    @Published private(set) var records: [UUID: ResourceRecord] = [:]
    private(set) var order: [UUID] = []
    private var runtimes: [UUID: WebTabRuntime] = [:]
    private var terminalSessions: [UUID: TerminalSession] = [:]
    private var terminalChanges: [UUID: AnyCancellable] = [:]
    private var terminalDirectoryChanges: [UUID: AnyCancellable] = [:]
    private var closingTasks: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    var onCommit: ((UUID, URL) -> Void)?; var onOpenInNewTab: ((UUID, URL) -> Void)?
    var onStateChange: ((UUID, WebNavigationState) -> Void)?
    var onShutdown: (() -> Void)?
    var resources: [ResourceRecord] { order.compactMap { records[$0] } }; var activeRuntimeCount: Int { runtimes.count }
    var liveTerminalCount: Int { terminalSessions.values.filter { $0.state == .starting || $0.state == .running }.count }
    init(launchTerminalProcesses: Bool = true) { self.launchTerminalProcesses = launchTerminalProcesses; Self.liveStores.append(WeakStore(self)) }
    struct TerminalStateMapping { let lifecycle: ResourceLifecycle; let errorMessage: String? }
    static func terminalStateMapping(kind: ResourceKind, state: TerminalSession.State) -> TerminalStateMapping? {
        switch state {
        case .idle: return nil
        case .starting: return .init(lifecycle: .starting, errorMessage: nil)
        case .running: return .init(lifecycle: .running, errorMessage: nil)
        case let .exited(code):
            if kind == .sshTerminal, code == 255 { return .init(lifecycle: .interrupted, errorMessage: "SSH connection failed or was interrupted (exit 255).") }
            return .init(lifecycle: .exited, errorMessage: nil)
        case let .failed(error): return .init(lifecycle: .failed, errorMessage: error)
        case .interrupted: return .init(lifecycle: .interrupted, errorMessage: nil)
        }
    }
    func recordTerminalState(resourceID: UUID, state: TerminalSession.State) {
        guard let existing = records[resourceID] else { return }
        guard let mapping = Self.terminalStateMapping(kind: existing.kind, state: state) else { return }
        var record = existing; record.lifecycle = mapping.lifecycle; record.errorMessage = mapping.errorMessage
        records[resourceID] = record
    }
    func registerLocalTerminal(groupID: UUID, directory: String, directoryURL: URL? = nil) -> UUID {
        guard !shuttingDown else { return order.first ?? UUID() }
        let id = UUID(); records[id] = ResourceRecord(id: id, kind: .localTerminal, groupID: groupID, title: "Terminal", location: .localTerminal(directory: directory), lifecycle: .starting, readCapabilities: [.output]); order.append(id)
        let session = TerminalSession(resourceID: id); session.setKnownDirectory(directory); terminalSessions[id] = session
        terminalChanges[id] = session.$state.sink { [weak self] state in self?.recordTerminalState(resourceID: id, state: state) }
        terminalDirectoryChanges[id] = session.$knownDirectory.sink { [weak self] directory in
            guard let self, let directory, var record = self.records[id] else { return }
            record.location = .localTerminal(directory: directory); self.records[id] = record
        }
        if let directoryURL { session.retainSecurityScope(directoryURL) }
        if launchTerminalProcesses { session.startLocal(directory: directory) }; return id
    }
    func registerSSH(groupID: UUID, host: String, user: String, port: Int, resourceID: UUID = UUID()) -> UUID {
        guard !shuttingDown else { return order.first ?? resourceID }
        let id = resourceID; guard records[id] == nil else { return id }
        let title = user.isEmpty ? host : "\(user)@\(host)"; records[id] = ResourceRecord(id: id, kind: .sshTerminal, groupID: groupID, title: port == 22 ? title : "\(title):\(port)", location: .ssh(host: host, user: user, port: port), lifecycle: .starting, readCapabilities: [.output]); order.append(id)
        let session = TerminalSession(resourceID: id); terminalSessions[id] = session
        terminalChanges[id] = session.$state.sink { [weak self] state in self?.recordTerminalState(resourceID: id, state: state) }
        if launchTerminalProcesses { session.startSSH(host: host, user: user, port: port, knownHosts: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".web-studio-known_hosts").path) }; return id
    }
    func terminalSession(for id: UUID) -> TerminalSession? { terminalSessions[id] }
    @discardableResult func registerWeb(groupID: UUID, destination: URL? = nil, resourceID: UUID = UUID()) -> UUID {
        guard !shuttingDown else { return order.first ?? resourceID }
        if records[resourceID] != nil { return resourceID }
        records[resourceID] = ResourceRecord(id: resourceID, kind: .web, groupID: groupID,
            title: destination?.host ?? destination?.absoluteString ?? "New Tab", location: .web(destination),
            readCapabilities: [.address, .title, .text]); order.append(resourceID); return resourceID
    }
    func update(_ record: ResourceRecord) { guard records[record.id] != nil else { return }; records[record.id] = record }
    func updateGroup(resourceID: UUID, groupID: UUID) { records[resourceID]?.groupID = groupID }
    func updateWebLocation(resourceID: UUID, url: URL, title: String? = nil) {
        guard var record=records[resourceID], record.kind == .web else { return }; record.location = .web(url)
        if let title, !title.isEmpty { record.title=title }; records[resourceID]=record
    }
    func updateTitle(resourceID: UUID, title: String) { records[resourceID]?.title = title }
    func remove(resourceID: UUID) {
        runtimes[resourceID]?.teardown(); runtimes[resourceID] = nil
        if let session = terminalSessions.removeValue(forKey: resourceID) {
            session.close()
            closingTasks[resourceID] = Task { [weak self, session] in
                await session.closeAndWait()
                await MainActor.run { self?.closingTasks[resourceID] = nil }
            }
        }
        terminalChanges[resourceID] = nil; terminalDirectoryChanges[resourceID] = nil; records[resourceID] = nil; order.removeAll { $0 == resourceID }
    }
    func shutdown() async {
        if let task = shutdownTask { await task.value; return }
        shuttingDown = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }
    private func performShutdown() async {
        onShutdown?()
        onShutdown = nil
        let sessions = Array(terminalSessions.values)
        for session in sessions { session.close(interrupted: true) }
        let tasks = Array(closingTasks.values) + sessions.map { session in Task { await session.closeAndWait() } }
        for task in tasks { await task.value }
        terminalSessions.removeAll(); terminalChanges.removeAll(); terminalDirectoryChanges.removeAll(); closingTasks.removeAll()
        for runtime in runtimes.values { runtime.teardown() }; runtimes.removeAll(); records.removeAll(); order.removeAll()
    }
    static func shutdownAll() async {
        let stores = liveStores.compactMap(\.value); for store in stores { await store.shutdown() }
        liveStores.removeAll { $0.value == nil }
    }
    static var liveTerminalCount: Int {
        liveStores.compactMap(\.value).reduce(0) { total, store in
            total + store.terminalSessions.values.filter { $0.state == .starting || $0.state == .running }.count
        }
    }
    func runtime(for resourceID: UUID) -> WebTabRuntime? {
        if let existing=runtimes[resourceID] { return existing }
        guard records[resourceID]?.kind == .web else { return nil }
        let runtime=WebTabRuntime(resourceID: resourceID); runtime.onCommit={ [weak self] url in self?.onCommit?(resourceID,url) }
        runtime.onOpenInNewTab={ [weak self] url in self?.onOpenInNewTab?(resourceID,url) }
        runtime.onStateChange={ [weak self] state in
            guard let self else { return }
            if var record = self.records[resourceID] {
                record.lifecycle = state.failure == nil ? (state.isLoading ? .starting : .running) : .failed
                record.errorMessage = state.failure?.message
                self.records[resourceID] = record
            }
            self.onStateChange?(resourceID,state)
        }; runtimes[resourceID]=runtime; return runtime
    }
    func existingRuntime(for resourceID: UUID) -> WebTabRuntime? { runtimes[resourceID] }
    func retain(webResourceIDs: Set<UUID>) {
        for id in runtimes.keys where !webResourceIDs.contains(id) {
            runtimes[id]?.teardown()
            runtimes[id] = nil
        }
    }
    func retain(webTabIDs: Set<UUID>) { retain(webResourceIDs:webTabIDs) }
    func read(resourceID: UUID, maxCharacters: Int = 12_000) async -> ResourceSnapshot {
        guard let record=records[resourceID] else { return .failure(resourceID:resourceID,message:"Resource is closed.") }
        if let session = terminalSessions[resourceID] {
            let full = session.renderedText().replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let limit = min(max(0, maxCharacters), 12_000)
            let start = max(0, full.count - limit); let text = String(full.dropFirst(start))
            let error = record.errorMessage
            let sourceURL: URL? = { if case let .ssh(host, user, port) = record.location { var components = URLComponents(); components.scheme = "ssh"; components.host = host; components.port = port; components.user = user.isEmpty ? nil : user; return components.url }; return nil }()
            return ResourceSnapshot(resourceID: resourceID, collectedAt: Date(), text: text, isTruncated: start > 0 || session.snapshotWasTruncated, errorMessage: nil, sourceURL: sourceURL, title: record.customTitle ?? record.title, range: start..<(start + text.count), knownDirectory: session.knownDirectory, lifecycle: record.lifecycle, runtimeErrorMessage: error)
        }
        guard record.kind == .web, let runtime=runtimes[resourceID] else { return .failure(resourceID:resourceID,message:"Resource is not readable yet.") }
        let snapshot=await runtime.readSnapshot(resourceID:resourceID,maxCharacters:maxCharacters)
        guard records[resourceID] != nil else { return .failure(resourceID:resourceID,message:"Resource was closed while it was being read.") }
        return snapshot
    }
}
typealias WebRuntimeStore = ResourceStore
