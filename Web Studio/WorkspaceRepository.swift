import Darwin
import Foundation

nonisolated enum WorkspaceRepositoryFault: Hashable, Sendable {
  case beforeWrite
  case afterTempWrite
  case beforeReplace
}

nonisolated enum WorkspaceRepositoryError: Error, Equatable, Sendable {
  case notFound(UUID)
  case corrupt(UUID)
  case unknownSchema(UUID, Int)
  case revisionConflict(UUID, expected: Int?, actual: Int?)
  case permissionFailure(UUID)
  case injectedFault(WorkspaceRepositoryFault)
  case busy(UUID)
}

nonisolated enum WorkspaceLoadResult: Equatable, Sendable {
  case loaded(WorkspaceConfigurationEnvelope)
  case recoveredFromBackup(WorkspaceConfigurationEnvelope)
}

nonisolated struct WorkspaceDirectoryRecord: Equatable, Sendable {
  let workspaceID: UUID
  let name: String
  let archived: Bool
  let revision: Int
  let lastActivatedAt: Date?
}

nonisolated enum WorkspaceRepositoryEntry: Equatable, Sendable {
  case entry(WorkspaceDirectoryRecord)
  case diagnostic(UUID?, WorkspaceRepositoryError)
}

nonisolated enum WorkspaceSaveResult: Equatable, Sendable {
  case saved(WorkspaceConfigurationEnvelope)
}

actor WorkspaceRepository {
  let rootURL: URL
  private let faults: Set<WorkspaceRepositoryFault>
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(rootURL: URL, faults: Set<WorkspaceRepositoryFault> = []) {
    self.rootURL = rootURL
    self.faults = faults
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var container = encoder.singleValueContainer()
      try container.encode(formatter.string(from: date))
    }
    decoder.dateDecodingStrategy = .custom { decoder in
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standard = ISO8601DateFormatter()
      standard.formatOptions = [.withInternetDateTime]
      let value = try decoder.singleValueContainer().decode(String.self)
      if let date = fractional.date(from: value) { return date }
      if let date = standard.date(from: value) { return date }
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO8601 date")
    }
  }

  nonisolated func configurationURL(for id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString + ".json")
  }

  func list() throws -> [WorkspaceRepositoryEntry] {
    try prepareDirectory()
    let files = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil
    ).filter {
      $0.pathExtension == "json"
        && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
    }
    return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
      do {
        let result = try read(url: url)
        switch result {
        case .loaded(let envelope), .recoveredFromBackup(let envelope):
          let c = envelope.configuration
          return .entry(
            WorkspaceDirectoryRecord(
              workspaceID: c.workspaceID, name: c.name,
              archived: c.archived, revision: c.revision, lastActivatedAt: c.lastActivatedAt))
        }
      } catch let error as WorkspaceRepositoryError {
        return .diagnostic(UUID(uuidString: url.deletingPathExtension().lastPathComponent), error)
      }
    }
  }

  func load(id: UUID) throws -> WorkspaceLoadResult {
    try prepareDirectory()
    let url = fileURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw WorkspaceRepositoryError.notFound(id)
    }
    return try read(url: url)
  }

  func save(
    _ configuration: WorkspaceConfiguration,
    expectedRevision: Int? = nil
  ) throws -> WorkspaceSaveResult {
    try prepareDirectory()
    let id = configuration.workspaceID
    let lock = try Lock(url: lockURL(id))
    defer { lock.unlock() }
    var current: WorkspaceConfiguration?
    var preserveCorruptPrimary = false
    do {
      current = try currentConfiguration(id: id)
    } catch let error as WorkspaceRepositoryError {
      if case .notFound = error {
        current = nil
      } else if case .corrupt = error,
        FileManager.default.fileExists(atPath: backupURL(id).path)
      {
        let backup = try readBackup(id: id).configuration
        preserveCorruptPrimary = true
        current = backup
      } else {
        throw error
      }
    }
    let actual = current?.revision
    if expectedRevision != actual {
      throw WorkspaceRepositoryError.revisionConflict(
        id, expected: expectedRevision, actual: actual)
    }
    if preserveCorruptPrimary {
      let corruptURL = rootURL.appendingPathComponent(
        id.uuidString + ".corrupt-" + UUID().uuidString + ".json")
      try FileManager.default.copyItem(at: fileURL(id), to: corruptURL)
    }
    if faults.contains(.beforeWrite) { throw WorkspaceRepositoryError.injectedFault(.beforeWrite) }
    let nextRevision = max(configuration.revision, actual ?? 0) + 1
    var value = configuration
    value.schemaVersion = WorkspaceConfiguration.currentSchemaVersion
    value.revision = nextRevision
    let envelope = WorkspaceConfigurationEnvelope(configuration: value, diagnostics: [])
    let data = try encoder.encode(envelope)
    guard (try? decoder.decode(WorkspaceConfigurationEnvelope.self, from: data)) != nil else {
      throw WorkspaceRepositoryError.corrupt(id)
    }
    let tempURL = rootURL.appendingPathComponent(
      id.uuidString + ".tmp-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    do {
      try data.write(to: tempURL, options: .atomic)
      if faults.contains(.afterTempWrite) {
        throw WorkspaceRepositoryError.injectedFault(.afterTempWrite)
      }
      if let current {
        try encoder.encode(WorkspaceConfigurationEnvelope(configuration: current, diagnostics: []))
          .write(to: backupURL(id), options: .atomic)
      }
      if faults.contains(.beforeReplace) {
        throw WorkspaceRepositoryError.injectedFault(.beforeReplace)
      }
      if FileManager.default.fileExists(atPath: fileURL(id).path) {
        try FileManager.default.replaceItemAt(fileURL(id), withItemAt: tempURL)
      } else {
        try FileManager.default.moveItem(at: tempURL, to: fileURL(id))
      }
    } catch let error as WorkspaceRepositoryError {
      throw error
    } catch {
      throw WorkspaceRepositoryError.permissionFailure(id)
    }
    return .saved(envelope)
  }

  private func currentConfiguration(id: UUID) throws -> WorkspaceConfiguration {
    let url = fileURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw WorkspaceRepositoryError.notFound(id)
    }
    do {
      let data = try Data(contentsOf: url)
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let version =
        (object?["configuration"] as? [String: Any])?["schemaVersion"] as? Int
        ?? (object?["schemaVersion"] as? Int)
      if let version, version > WorkspaceConfiguration.currentSchemaVersion {
        throw WorkspaceRepositoryError.unknownSchema(id, version)
      }
      let envelope = try decodeEnvelope(data: data, fileID: id)
      guard envelope.configuration.workspaceID == id else {
        throw WorkspaceRepositoryError.corrupt(id)
      }
      return envelope.configuration
    } catch let error as WorkspaceRepositoryError {
      throw error
    } catch {
      throw WorkspaceRepositoryError.corrupt(id)
    }
  }

  private func read(url: URL) throws -> WorkspaceLoadResult {
    do {
      let data = try Data(contentsOf: url)
      let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let version =
        (schema?["configuration"] as? [String: Any])?["schemaVersion"] as? Int
        ?? (schema?["schemaVersion"] as? Int)
      if let version, version > WorkspaceConfiguration.currentSchemaVersion {
        throw WorkspaceRepositoryError.unknownSchema(
          UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(), version)
      }
      let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
      let envelope = try decodeEnvelope(data: data, fileID: fileID)
      return .loaded(envelope)
    } catch let error as WorkspaceRepositoryError {
      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
      if case .unknownSchema = error { throw error }
      if url.pathExtension == "json", FileManager.default.fileExists(atPath: backupURL(id).path) {
        do {
          return .recoveredFromBackup(try readBackup(id: id))
        } catch {
          throw WorkspaceRepositoryError.corrupt(id)
        }
      }
      throw error == .corrupt(id) ? error : WorkspaceRepositoryError.corrupt(id)
    } catch {
      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
      if FileManager.default.fileExists(atPath: backupURL(id).path) {
        do {
          return .recoveredFromBackup(try readBackup(id: id))
        } catch {
          throw WorkspaceRepositoryError.corrupt(id)
        }
      }
      throw WorkspaceRepositoryError.corrupt(id)
    }
  }

  private func readBackup(id: UUID) throws -> WorkspaceConfigurationEnvelope {
    let data = try Data(contentsOf: backupURL(id))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let version =
      (object?["configuration"] as? [String: Any])?["schemaVersion"] as? Int
      ?? (object?["schemaVersion"] as? Int)
    if let version, version > WorkspaceConfiguration.currentSchemaVersion {
      throw WorkspaceRepositoryError.unknownSchema(id, version)
    }
    let envelope = try decodeEnvelope(data: data, fileID: id)
    guard envelope.configuration.workspaceID == id else {
      throw WorkspaceRepositoryError.corrupt(id)
    }
    let normalized = normalize(envelope.configuration)
    return WorkspaceConfigurationEnvelope(
      configuration: normalized.0,
      diagnostics: envelope.diagnostics + normalized.1)
  }

  private func decodeEnvelope(data: Data, fileID: UUID?) throws -> WorkspaceConfigurationEnvelope {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var configuration = root["configuration"] as? [String: Any]
    else {
      throw WorkspaceRepositoryError.corrupt(fileID ?? UUID())
    }
    var diagnostics: [WorkspaceConfigurationDiagnostic] = []
    if let rawResources = configuration["resources"] as? [Any] {
      var resources: [[String: Any]] = []
      var seen = Set<UUID>()
      for raw in rawResources {
        guard let dictionary = raw as? [String: Any],
          let itemData = try? JSONSerialization.data(withJSONObject: dictionary),
          let item = try? decoder.decode(WorkspaceResourceConfiguration.self, from: itemData)
        else {
          diagnostics.append(.invalidResource)
          continue
        }
        guard seen.insert(item.id).inserted else {
          diagnostics.append(.duplicateResourceID)
          continue
        }
        resources.append(dictionary)
      }
      configuration["resources"] = resources
    }
    if let rawPins = configuration["pinnedDestinations"] as? [Any] {
      var pins: [[String: Any]] = []
      for raw in rawPins {
        guard let dictionary = raw as? [String: Any],
          let itemData = try? JSONSerialization.data(withJSONObject: dictionary),
          (try? decoder.decode(WorkspacePinnedDestination.self, from: itemData)) != nil
        else {
          diagnostics.append(.invalidPinnedDestination)
          continue
        }
        pins.append(dictionary)
      }
      configuration["pinnedDestinations"] = pins
    }
    root["configuration"] = configuration
    let repairedData = try JSONSerialization.data(withJSONObject: root)
    let envelope = try decoder.decode(WorkspaceConfigurationEnvelope.self, from: repairedData)
    if let fileID, envelope.configuration.workspaceID != fileID {
      throw WorkspaceRepositoryError.corrupt(fileID)
    }
    let normalized = normalize(envelope.configuration)
    return WorkspaceConfigurationEnvelope(
      configuration: normalized.0,
      diagnostics: envelope.diagnostics + diagnostics + normalized.1)
  }

  private func normalize(_ value: WorkspaceConfiguration)
    -> (WorkspaceConfiguration, [WorkspaceConfigurationDiagnostic])
  {
    var value = value
    var diagnostics: [WorkspaceConfigurationDiagnostic] = []
    var seen = Set<UUID>()
    value.resources = value.resources.filter {
      guard seen.insert($0.id).inserted else {
        diagnostics.append(.duplicateResourceID)
        return false
      }
      guard validDestination($0.destination) else {
        diagnostics.append(.invalidResource)
        return false
      }
      return true
    }
    var seenPins = Set<UUID>()
    value.pinnedDestinations = value.pinnedDestinations.filter {
      guard seenPins.insert($0.id).inserted else {
        diagnostics.append(.duplicatePinnedDestination)
        return false
      }
      guard validDestination($0.destination) else {
        diagnostics.append(.invalidPinnedDestination)
        return false
      }
      return true
    }
    let normalized = value.layout.normalized(resourceIDs: Set(value.resources.map(\.id)))
    value.layout = normalized.0
    diagnostics.append(contentsOf: normalized.1)
    if var secondary = value.layout.secondary {
      if secondary.id == value.layout.primary.id {
        diagnostics.append(.duplicatePaneID)
        secondary.id = UUID()
        value.layout.secondary = secondary
      }
      if let primaryResource = value.layout.primary.resourceID,
        primaryResource == secondary.resourceID
      {
        diagnostics.append(.duplicatePaneResource)
        value.layout.secondary?.resourceID = nil
      }
    }
    return (value, diagnostics)
  }

  private func validDestination(_ destination: WorkspaceDestinationConfiguration) -> Bool {
    switch destination {
    case .blank:
      return true
    case .terminal(let directory):
      return directory.hasPrefix("/") && !directory.isEmpty
        && !directory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    case .web(let raw):
      guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = url.host, !host.isEmpty
      else { return false }
      return !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    case .ssh(let host, let user, let port):
      guard (1...65535).contains(port) else { return false }
      let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasControl: (String) -> Bool = { value in
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
      }
      guard !cleanHost.isEmpty, !hasControl(host), !hasControl(user), !host.contains(where: { $0.isWhitespace }),
        !user.contains(where: { $0.isWhitespace }),
        !cleanHost.contains(where: { $0 == "/" || $0 == "\\" || $0 == "@" }),
        !cleanUser.contains(where: { $0 == "/" || $0 == "\\" || $0 == "@" }), !cleanHost.hasPrefix("-"),
        !cleanUser.hasPrefix("-")
      else { return false }
      if cleanHost.contains(":") {
        var address = in6_addr()
        return cleanHost.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
      }
      var address = in_addr()
      if cleanHost.withCString({ inet_pton(AF_INET, $0, &address) == 1 }) { return true }
      let labels = cleanHost.split(separator: ".", omittingEmptySubsequences: false)
      if labels.count == 4 && labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
      return cleanHost.count <= 253 && !labels.isEmpty
        && labels.allSatisfy { label in
          label.count <= 63 && !label.isEmpty && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }
  private func fileURL(_ id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString + ".json")
  }
  private func backupURL(_ id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString + ".bak.json")
  }
  private func lockURL(_ id: UUID) -> URL {
    rootURL.appendingPathComponent(id.uuidString + ".lock")
  }

  private final class Lock {
    let descriptor: Int32
    let url: URL
    init(url: URL) throws {
      self.url = url
      descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      if descriptor < 0 { throw WorkspaceRepositoryError.permissionFailure(UUID()) }
      if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        _ = Darwin.close(descriptor)
        throw WorkspaceRepositoryError.busy(
          UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID())
      }
    }
    func unlock() {
      _ = flock(descriptor, LOCK_UN)
      _ = Darwin.close(descriptor)
    }
  }
}
