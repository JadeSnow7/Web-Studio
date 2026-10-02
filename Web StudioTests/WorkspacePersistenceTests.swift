import Darwin
import Foundation
import Testing

@testable import Web_Studio

struct WorkspacePersistenceTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebStudio-P2-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func configuration(id: UUID = UUID()) -> WorkspaceConfiguration {
    let resourceID = UUID()
    let pane = WorkspacePaneConfiguration(id: UUID(), resourceID: resourceID, isFocused: true)
    return WorkspaceConfiguration(
      workspaceID: id, name: "Project", directory: "/tmp/project",
      archived: false,
      resources: [
        WorkspaceResourceConfiguration(
          id: resourceID,
          destination: .web(url: "https://example.com"), customTitle: "Docs", order: 0)
      ],
      pinnedDestinations: [
        WorkspacePinnedDestination(
          id: UUID(), title: "Home",
          destination: .web(url: "https://example.com"))
      ],
      layout: WorkspaceLayoutConfiguration(primary: pane, secondary: nil, splitRatio: 0.4),
      panelPreferences: WorkspacePanelPreferences(tabStripVisible: false, agentsVisible: true),
      lastActivatedAt: Date(timeIntervalSince1970: 123)
    )
  }

  @Test func allConfigurationFieldsRoundTrip() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let input = configuration()
    let saved = try await repository.save(input)
    guard case .saved(let envelope) = saved else {
      Issue.record("save did not succeed")
      return
    }
    let loaded = try await repository.load(id: input.workspaceID)
    guard case .loaded(let result) = loaded else {
      Issue.record("unexpected recovery")
      return
    }
    #expect(result.configuration == envelope.configuration)
    #expect(result.configuration.name == "Project")
    #expect(result.configuration.resources.count == 1)
    #expect(result.configuration.pinnedDestinations.count == 1)
    #expect(result.configuration.panelPreferences.tabStripVisible == false)
  }

  @Test func sameSecondActivityRetainsFractionalOrderingAcrossSaveLoadAndList() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = UUID(); let secondID = UUID()
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000.125)
    let secondDate = Date(timeIntervalSince1970: 1_700_000_000.875)
    var first = configuration(id: firstID); first.name = "First"; first.lastActivatedAt = firstDate
    var second = configuration(id: secondID); second.name = "Second"; second.lastActivatedAt = secondDate
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(first)
    _ = try await repository.save(second)
    let firstLoaded = try await repository.load(id: firstID)
    let secondLoaded = try await repository.load(id: secondID)
    guard case .loaded(let firstEnvelope) = firstLoaded, case .loaded(let secondEnvelope) = secondLoaded else {
      Issue.record("expected loaded configurations")
      return
    }
    #expect(firstEnvelope.configuration.lastActivatedAt == firstDate)
    #expect(secondEnvelope.configuration.lastActivatedAt == secondDate)
    #expect(secondEnvelope.configuration.lastActivatedAt! > firstEnvelope.configuration.lastActivatedAt!)
    let entries = try await repository.list()
    let listed = entries.compactMap { entry -> WorkspaceDirectoryRecord? in if case .entry(let record) = entry { return record }; return nil }
    #expect(listed.contains { $0.workspaceID == firstID && $0.lastActivatedAt == firstDate })
    #expect(listed.contains { $0.workspaceID == secondID && $0.lastActivatedAt == secondDate })
  }

  @Test func injectedFailurePreservesOriginalBytes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let url = root.appendingPathComponent(id.uuidString + ".json")
    let before = try Data(contentsOf: url)
    let failing = WorkspaceRepository(rootURL: root, faults: [.beforeReplace])
    await #expect(throws: WorkspaceRepositoryError.injectedFault(.beforeReplace)) {
      try await failing.save(configuration(id: id), expectedRevision: 1)
    }
    #expect(try Data(contentsOf: url) == before)
  }

  @Test func unknownSchemaCannotBeLoadedOrOverwritten() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let url = root.appendingPathComponent(id.uuidString + ".json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var nested = object["configuration"] as! [String: Any]
    nested["schemaVersion"] = 99
    object["configuration"] = nested
    let unknown = try JSONSerialization.data(withJSONObject: object)
    try unknown.write(to: url)
    await #expect(throws: WorkspaceRepositoryError.unknownSchema(id, 99)) {
      try await repository.save(configuration(id: id), expectedRevision: 1)
    }
    #expect(try Data(contentsOf: url) == unknown)
  }

  @Test func duplicateResourcesAndInvalidPaneReferencesAreReportedAndRepaired() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    var input = configuration(id: id)
    let valid = input.resources[0]
    input.resources.append(valid)
    input.layout.primary.resourceID = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(input)
    guard case .loaded(let envelope) = try await repository.load(id: id) else {
      Issue.record("expected loaded configuration")
      return
    }
    #expect(envelope.configuration.resources.count == 1)
    #expect(envelope.diagnostics.contains(.duplicateResourceID))
    #expect(envelope.diagnostics.contains(.invalidPaneReference))
  }

  @Test func unsupportedResourceKeepsOtherValidItems() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let url = root.appendingPathComponent(id.uuidString + ".json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var nested = object["configuration"] as! [String: Any]
    var resources = nested["resources"] as! [[String: Any]]
    resources.append(["id": UUID().uuidString, "destination": ["kind": "future"]])
    nested["resources"] = resources
    object["configuration"] = nested
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    guard case .loaded(let envelope) = try await repository.load(id: id) else {
      Issue.record("expected partial load")
      return
    }
    #expect(envelope.configuration.resources.count == 1)
    #expect(envelope.diagnostics.contains(.invalidResource))
  }

  @Test func partiallyLoadedConfigurationCanBeSaved() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let url = root.appendingPathComponent(id.uuidString + ".json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    var nested = object["configuration"] as! [String: Any]
    nested["resources"] = (nested["resources"] as! [[String: Any]]) + [["id": UUID().uuidString]]
    object["configuration"] = nested
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    guard case .loaded(let envelope) = try await repository.load(id: id) else {
      Issue.record("expected partial load")
      return
    }
    var updated = envelope.configuration
    updated.name = "Updated"
    _ = try await repository.save(updated, expectedRevision: 1)
    guard case .loaded(let saved) = try await repository.load(id: id) else {
      Issue.record("expected saved configuration")
      return
    }
    #expect(saved.configuration.name == "Updated")
  }

  @Test func corruptCopiesAreExcludedFromDirectoryAndNilRevisionCannotOverwrite() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let url = root.appendingPathComponent(id.uuidString + ".json")
    let before = try Data(contentsOf: url)
    let backup = root.appendingPathComponent(id.uuidString + ".bak.json")
    try before.write(to: backup)
    try Data(#"{"broken":true}"#.utf8).write(to: url)
    var replacement = configuration(id: id)
    replacement.name = "Should Fail"
    await #expect(throws: WorkspaceRepositoryError.revisionConflict(id, expected: nil, actual: 1)) {
      try await repository.save(replacement)
    }
    #expect(try Data(contentsOf: url) != before)
    let entries = try await repository.list()
    #expect(entries.count == 1)
  }

  @Test func truncatedPrimaryRecoversFromValidBackupAndKeepsDirectory() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    var changed = configuration(id: id)
    changed.name = "Second"
    _ = try await repository.save(changed, expectedRevision: 1)
    let primary = root.appendingPathComponent("\(id.uuidString).json")
    try Data(#"{"configuration":"#.utf8).write(to: primary)
    guard case .recoveredFromBackup(let envelope) = try await repository.load(id: id) else {
      Issue.record("expected backup recovery")
      return
    }
    #expect(envelope.configuration.name == "Project")
    let entries = try await repository.list()
    #expect(
      entries.contains { entry in
        if case .entry(let record) = entry { return record.workspaceID == id }
        return false
      })
  }

  @Test func invalidBackupDoesNotBecomeSuccessfulLoad() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let primary = root.appendingPathComponent("\(id.uuidString).json")
    let backup = root.appendingPathComponent("\(id.uuidString).bak.json")
    try Data(#"{"broken":true}"#.utf8).write(to: primary)
    try Data(#"{"broken":true}"#.utf8).write(to: backup)
    await #expect(throws: WorkspaceRepositoryError.corrupt(id)) {
      try await repository.load(id: id)
    }
  }

  @Test func recoveredBackupCanBeSavedWhileCorruptPrimaryIsPreserved() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let second = configuration(id: id)
    _ = try await repository.save(second, expectedRevision: 1)
    let primary = root.appendingPathComponent(id.uuidString + ".json")
    let corruptBytes = Data(#"{"broken":true}"#.utf8)
    try corruptBytes.write(to: primary)
    var replacement = configuration(id: id)
    replacement.name = "Recovered Save"
    _ = try await repository.save(replacement, expectedRevision: 1)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.contains(".corrupt-") }
    #expect(preserved.contains { (try? Data(contentsOf: $0)) == corruptBytes })
    #expect(
      try await repository.load(id: id)
        == .loaded(
          WorkspaceConfigurationEnvelope(
            configuration: WorkspaceConfiguration(
              schemaVersion: 1, workspaceID: id, revision: 2, name: "Recovered Save",
              directory: "/tmp/project", archived: false, resources: replacement.resources,
              pinnedDestinations: replacement.pinnedDestinations, layout: replacement.layout,
              panelPreferences: replacement.panelPreferences,
              lastActivatedAt: replacement.lastActivatedAt),
            diagnostics: [])))
  }

  @Test func expectedRevisionRejectsStaleRepository() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let first = WorkspaceRepository(rootURL: root)
    let second = WorkspaceRepository(rootURL: root)
    _ = try await first.save(configuration(id: id))
    await #expect(throws: WorkspaceRepositoryError.revisionConflict(id, expected: 0, actual: 1)) {
      try await second.save(configuration(id: id), expectedRevision: 0)
    }
  }

  @Test func invalidDestinationsAndDuplicatePinsAreDiagnosedWithoutDroppingValidItems() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    var input = configuration(id: id)
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "dev.example.com", user: "alice", port: 2222), customTitle: nil, order: 1))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .terminal(directory: "/path/that/does/not/exist"), customTitle: nil, order: 2))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "2001:db8::1", user: "alice", port: 22), customTitle: nil, order: 3))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .web(url: "ftp://unsupported.example"), customTitle: nil, order: 1))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "bad..host", user: "dev", port: 22), customTitle: nil, order: 3))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "good.example.com", user: "-bad", port: 0), customTitle: nil, order: 4))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "good.example.com", user: "dev", port: 65536), customTitle: nil, order: 5))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "999.1.1.1", user: "dev", port: 22), customTitle: nil, order: 6))
    input.resources.append(WorkspaceResourceConfiguration(id: UUID(), destination: .ssh(host: "good.example.com\n", user: "dev", port: 22), customTitle: nil, order: 7))
    let pinID = input.pinnedDestinations[0].id
    input.pinnedDestinations.append(WorkspacePinnedDestination(id: pinID, title: "Duplicate", destination: .web(url: "https://example.com")))
    input.pinnedDestinations.append(WorkspacePinnedDestination(id: UUID(), title: "Bad", destination: .web(url: "file:///tmp/local")))
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(input)
    let beforeLoad = try Data(contentsOf: root.appendingPathComponent("\(id.uuidString).json"))
    guard case .loaded(let envelope) = try await repository.load(id: id) else {
      Issue.record("expected loaded configuration")
      return
    }
    #expect(envelope.configuration.resources.count == 4)
    #expect(envelope.configuration.resources[0].destination == .web(url: "https://example.com"))
    #expect(envelope.configuration.resources.contains { $0.destination == .ssh(host: "dev.example.com", user: "alice", port: 2222) })
    #expect(envelope.configuration.resources.contains { $0.destination == .terminal(directory: "/path/that/does/not/exist") })
    #expect(envelope.configuration.resources.contains { $0.destination == .ssh(host: "2001:db8::1", user: "alice", port: 22) })
    #expect(envelope.configuration.pinnedDestinations.count == 1)
    #expect(envelope.diagnostics.contains(.invalidResource))
    #expect(envelope.diagnostics.contains(.duplicatePinnedDestination))
    #expect(envelope.diagnostics.contains(.invalidPinnedDestination))
    #expect(try Data(contentsOf: root.appendingPathComponent("\(id.uuidString).json")) == beforeLoad)
  }

  @Test func occupiedAdvisoryLockRejectsSaveWithoutChangingPrimary() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let repository = WorkspaceRepository(rootURL: root)
    _ = try await repository.save(configuration(id: id))
    let primary = root.appendingPathComponent("\(id.uuidString).json")
    let before = try Data(contentsOf: primary)
    let descriptor = open(root.appendingPathComponent("\(id.uuidString).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(descriptor >= 0)
    guard descriptor >= 0 else { return }
    defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    var changed = configuration(id: id)
    changed.name = "Blocked"
    await #expect(throws: WorkspaceRepositoryError.busy(id)) {
      try await repository.save(changed, expectedRevision: 1)
    }
    #expect(try Data(contentsOf: primary) == before)
    _ = flock(descriptor, LOCK_UN)
    _ = try await repository.save(changed, expectedRevision: 1)
    guard case .loaded(let loaded) = try await repository.load(id: id) else {
      Issue.record("expected saved configuration")
      return
    }
    #expect(loaded.configuration.name == "Blocked")
  }
}
