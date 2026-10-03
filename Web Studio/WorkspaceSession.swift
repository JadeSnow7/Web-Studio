import Combine
import Foundation

@MainActor final class WorkspaceSession: ObservableObject, Identifiable {
  let id: UUID
  @Published var name: String
  @Published private(set) var isTemporary: Bool
  @Published var directory: String?
  @Published var archived: Bool
  @Published var lastActivatedAt: Date?
  let resourceStore: ResourceStore
  let agentController: AgentController
  let providerSettings: ProviderSettings
  @Published var layout: WorkspaceLayout
  @Published var pinnedDestinations: [PinnedDestination] = []
  @Published private(set) var recentResourceIDs: [UUID] = []
  @Published var tabStripVisible = true
  @Published var agentsVisible = true
  @Published private(set) var isClosed = false
  private var closingTask: Task<Void, Never>?
  var store: ResourceStore { resourceStore }
  var agent: AgentController { agentController }
  var isEmpty: Bool { resourceStore.resources.isEmpty }
  func markPersisted() { isTemporary = false }

  func exportConfiguration(revision: Int = 0) -> WorkspaceConfiguration {
    let resources = resourceStore.resources.enumerated().map { index, record in
      let destination: WorkspaceDestinationConfiguration
      switch record.location {
      case .web(let url):
        if let url {
          destination = .web(url: url.absoluteString)
        } else {
          destination = .blank
        }
      case .localTerminal(let directory):
        destination = .terminal(directory: directory ?? "")
      case .ssh(let host, let user, let port):
        destination = .ssh(host: host, user: user, port: port)
      }
      return WorkspaceResourceConfiguration(
        id: record.id, destination: destination,
        customTitle: record.customTitle, order: index)
    }
    let primary = WorkspacePaneConfiguration(
      id: layout.primary.id, resourceID: layout.primary.resourceID,
      isFocused: layout.primary.isFocused)
    let secondary = layout.secondary.map {
      WorkspacePaneConfiguration(
        id: $0.id, resourceID: $0.resourceID,
        isFocused: $0.isFocused)
    }
    let pins = pinnedDestinations.compactMap { pin -> WorkspacePinnedDestination? in
      guard let destination = Self.configurationDestination(pin.destination) else { return nil }
      return WorkspacePinnedDestination(id: pin.id, title: pin.title, destination: destination)
    }
    return WorkspaceConfiguration(
      workspaceID: id, revision: revision, name: name, directory: directory,
      archived: archived, resources: resources, pinnedDestinations: pins,
      layout: WorkspaceLayoutConfiguration(
        primary: primary, secondary: secondary, splitRatio: layout.splitRatio),
      panelPreferences: WorkspacePanelPreferences(
        tabStripVisible: tabStripVisible, agentsVisible: agentsVisible),
      lastActivatedAt: lastActivatedAt)
  }

  @discardableResult
  func restoreDescriptors(from configuration: WorkspaceConfiguration)
    -> [WorkspaceConfigurationDiagnostic]
  {
    guard configuration.workspaceID == id else { return [.workspaceIDMismatch] }
    guard resourceStore.resources.isEmpty else { return [.invalidResource] }
    name = configuration.name
    directory = configuration.directory
    archived = configuration.archived
    lastActivatedAt = configuration.lastActivatedAt
    isTemporary = false
    var records: [ResourceRecord] = []
    for resource in configuration.resources.sorted(by: { $0.order < $1.order }) {
      let record: ResourceRecord
      switch resource.destination {
      case .blank:
        record = ResourceRecord(
          id: resource.id, kind: .web,
          groupID: id, title: "空白网页", location: .web(nil),
          readCapabilities: [.address, .title, .text],
          customTitle: resource.customTitle)
      case .web(let url):
        record = ResourceRecord(
          id: resource.id, kind: .web, groupID: id,
          title: URL(string: url)?.host ?? "空白网页", location: .web(URL(string: url)),
          readCapabilities: [.address, .title, .text], customTitle: resource.customTitle)
      case .terminal(let directory):
        record = ResourceRecord(
          id: resource.id, kind: .localTerminal, groupID: id,
          title: "终端", location: .localTerminal(directory: directory),
          readCapabilities: [.output], customTitle: resource.customTitle)
      case .ssh(let host, let user, let port):
        record = ResourceRecord(
          id: resource.id, kind: .sshTerminal, groupID: id,
          title: user.isEmpty ? host : user + "@" + host,
          location: .ssh(host: host, user: user, port: port),
          readCapabilities: [.output], customTitle: resource.customTitle)
      }
      records.append(record)
    }
    resourceStore.restoreDescriptors(records)
    layout = WorkspaceLayout(
      primary: PaneState(
        id: configuration.layout.primary.id,
        resourceID: configuration.layout.primary.resourceID,
        isFocused: configuration.layout.primary.isFocused),
      secondary: configuration.layout.secondary.map {
        PaneState(id: $0.id, resourceID: $0.resourceID, isFocused: $0.isFocused)
      }, splitRatio: configuration.layout.splitRatio)
    tabStripVisible = configuration.panelPreferences.tabStripVisible
    agentsVisible = configuration.panelPreferences.agentsVisible
    pinnedDestinations = configuration.pinnedDestinations.compactMap {
      guard let destination = Self.studioDestination($0.destination) else { return nil }
      return PinnedDestination(id: $0.id, title: $0.title, destination: destination)
    }
    return []
  }

  private static func configurationDestination(_ destination: StudioDestination)
    -> WorkspaceDestinationConfiguration?
  {
    switch destination {
    case .blank: return .blank
    case .web(let url): return .web(url: url.absoluteString)
    case .terminal(let directory): return .terminal(directory: directory)
    case .ssh(let host, let user, let port): return .ssh(host: host, user: user, port: port)
    }
  }

  private static func studioDestination(_ destination: WorkspaceDestinationConfiguration)
    -> StudioDestination?
  {
    switch destination {
    case .blank: return .blank
    case .web(let url):
      guard let url = URL(string: url) else { return nil }
      return .web(url)
    case .terminal(let directory): return .terminal(directory: directory)
    case .ssh(let host, let user, let port): return .ssh(host: host, user: user, port: port)
    }
  }
  init(
    id: UUID = UUID(), name: String = "临时空间", isTemporary: Bool = true,
    launchTerminalProcesses: Bool = true, layout: WorkspaceLayout? = nil,
    resourceStore: ResourceStore? = nil, agentController: AgentController? = nil,
    providerSettings: ProviderSettings? = nil
  ) {
    self.id = id
    self.name = name
    self.isTemporary = isTemporary
    self.directory = nil
    self.archived = false
    self.lastActivatedAt = nil
    let store = resourceStore ?? ResourceStore(launchTerminalProcesses: launchTerminalProcesses)
    self.resourceStore = store
    if let agentController {
      self.agentController = agentController
      self.providerSettings = providerSettings ?? ProviderSettings(credentials: agentController.service.credentials)
    } else if let providerSettings {
      self.providerSettings = providerSettings
      self.agentController = AgentController(
        store: store, service: ConfiguredAgentService(credentials: providerSettings.credentials))
    } else {
      let service = ConfiguredAgentService()
      self.agentController = AgentController(store: store, service: service)
      self.providerSettings = ProviderSettings(credentials: service.credentials)
    }
    self.layout = layout ?? WorkspaceLayout(primary: PaneState(resourceID: nil, isFocused: true))
    self.agentController.updateConfiguration(self.providerSettings.committedConfiguration)
  }

  convenience init(
    configuration: WorkspaceConfiguration,
    launchTerminalProcesses: Bool = false,
    providerSettings: ProviderSettings? = nil
  ) {
    self.init(
      id: configuration.workspaceID, name: configuration.name,
      isTemporary: false,
      launchTerminalProcesses: launchTerminalProcesses,
      providerSettings: providerSettings)
    _ = restoreDescriptors(from: configuration)
  }
  func recordRecentResource(_ id: UUID) {
    guard !isClosed, resourceStore.records[id] != nil else { return }
    recentResourceIDs.removeAll { $0 == id }
    recentResourceIDs.insert(id, at: 0)
    recentResourceIDs = Array(recentResourceIDs.prefix(5))
  }
  func setFocus(paneID: UUID) {
    guard !isClosed, layout.primary.id == paneID || layout.secondary?.id == paneID else { return }
    layout.primary.isFocused = layout.primary.id == paneID
    if var s = layout.secondary {
      s.isFocused = s.id == paneID
      layout.secondary = s
    }
  }
  func close() async {
    if let t = closingTask {
      await t.value
      return
    }
    if isClosed { return }
    isClosed = true
    let t = Task { @MainActor [agentController, resourceStore] in
      await agentController.shutdownAndWait()
      agentController.newChat()
      await resourceStore.shutdown()
    }
    closingTask = t
    await t.value
    closingTask = nil
  }
}
