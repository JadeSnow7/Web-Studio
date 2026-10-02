import Foundation

nonisolated struct WorkspaceConfiguration: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  var schemaVersion: Int = Self.currentSchemaVersion
  var workspaceID: UUID
  var revision: Int = 0
  var name: String
  var directory: String?
  var archived: Bool = false
  var resources: [WorkspaceResourceConfiguration] = []
  var pinnedDestinations: [WorkspacePinnedDestination] = []
  var layout: WorkspaceLayoutConfiguration
  var panelPreferences: WorkspacePanelPreferences = .init()
  var lastActivatedAt: Date?
}

nonisolated struct WorkspaceResourceConfiguration: Codable, Equatable, Sendable {
  var id: UUID
  var destination: WorkspaceDestinationConfiguration
  var customTitle: String?
  var order: Int
}

nonisolated enum WorkspaceDestinationConfiguration: Codable, Equatable, Sendable {
  case blank
  case web(url: String)
  case terminal(directory: String)
  case ssh(host: String, user: String, port: Int)

  private enum CodingKeys: String, CodingKey { case kind, url, directory, host, user, port }
  private enum Kind: String, Codable { case blank, web, terminal, ssh }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .blank: self = .blank
    case .web: self = .web(url: try values.decode(String.self, forKey: .url))
    case .terminal: self = .terminal(directory: try values.decode(String.self, forKey: .directory))
    case .ssh:
      self = .ssh(
        host: try values.decode(String.self, forKey: .host),
        user: try values.decode(String.self, forKey: .user),
        port: try values.decode(Int.self, forKey: .port))
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .blank: try values.encode(Kind.blank, forKey: .kind)
    case .web(let url):
      try values.encode(Kind.web, forKey: .kind)
      try values.encode(url, forKey: .url)
    case .terminal(let directory):
      try values.encode(Kind.terminal, forKey: .kind)
      try values.encode(directory, forKey: .directory)
    case .ssh(let host, let user, let port):
      try values.encode(Kind.ssh, forKey: .kind)
      try values.encode(host, forKey: .host)
      try values.encode(user, forKey: .user)
      try values.encode(port, forKey: .port)
    }
  }
}

nonisolated struct WorkspacePinnedDestination: Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var destination: WorkspaceDestinationConfiguration
}

nonisolated struct WorkspacePaneConfiguration: Codable, Equatable, Sendable {
  var id: UUID
  var resourceID: UUID?
  var isFocused: Bool
}

nonisolated struct WorkspaceLayoutConfiguration: Codable, Equatable, Sendable {
  var primary: WorkspacePaneConfiguration
  var secondary: WorkspacePaneConfiguration?
  var splitRatio: Double

  func normalized(resourceIDs: Set<UUID>) -> (
    WorkspaceLayoutConfiguration, [WorkspaceConfigurationDiagnostic]
  ) {
    var value = self
    var diagnostics: [WorkspaceConfigurationDiagnostic] = []
    value.splitRatio = min(max(value.splitRatio, 0.2), 0.8)
    if value.splitRatio != splitRatio { diagnostics.append(.layoutRepaired) }
    let ids = resourceIDs
    if let resourceID = value.primary.resourceID, !ids.contains(resourceID) {
      value.primary.resourceID = nil
      diagnostics.append(.invalidPaneReference)
    }
    if var secondary = value.secondary {
      if let resourceID = secondary.resourceID, !ids.contains(resourceID) {
        secondary.resourceID = nil
        diagnostics.append(.invalidPaneReference)
      }
      value.secondary = secondary
    }
    if value.primary.isFocused, value.secondary?.isFocused == true {
      value.secondary?.isFocused = false
      diagnostics.append(.focusRepaired)
    }
    if !value.primary.isFocused, value.secondary?.isFocused != true {
      value.primary.isFocused = true
      diagnostics.append(.focusRepaired)
    }
    return (value, diagnostics)
  }
}

nonisolated struct WorkspacePanelPreferences: Codable, Equatable, Sendable {
  var tabStripVisible: Bool = true
  var agentsVisible: Bool = true
}

nonisolated enum WorkspaceConfigurationDiagnostic: String, Codable, Equatable, Sendable {
  case duplicateResourceID
  case invalidResource
  case invalidPinnedDestination
  case duplicatePinnedDestination
  case workspaceIDMismatch
  case duplicatePaneID
  case duplicatePaneResource
  case invalidPaneReference
  case focusRepaired
  case layoutRepaired
}

nonisolated struct WorkspaceConfigurationEnvelope: Codable, Equatable, Sendable {
  var configuration: WorkspaceConfiguration
  var diagnostics: [WorkspaceConfigurationDiagnostic]
}
