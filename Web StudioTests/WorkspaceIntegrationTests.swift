import Foundation
import Testing

@testable import Web_Studio

@MainActor
struct WorkspaceIntegrationTests {
  @Test func cancellingNewWorkspaceDoesNotCreateGhost() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let before = model.groups.map(\.id)
    model.addGroup()
    model.dismissPanel()
    #expect(model.groups.map(\.id) == before)
  }

  @Test func submittedNewWorkspaceUsesNameAndOwnsSession() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    model.addGroup()
    model.renameSelectedGroup("命名空间")
    #expect(model.session.name == "命名空间")
    #expect(!model.session.isTemporary)
  }

  @Test func invalidDirectoryIsPreservedAndDoesNotFallback() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let invalid = "/definitely/missing/web-studio-directory-\(UUID().uuidString)"
    model.setWorkspaceDirectory(invalid)
    model.newTerminal(directory: nil)
    let terminal = try #require(model.webRuntimes.resources.last)
    if case .localTerminal(let directory) = terminal.location {
      #expect(directory == invalid)
    } else {
      Issue.record("expected local terminal resource")
    }
    #expect(terminal.lifecycle == .failed)
  }

  @Test func namedWorkspaceSavesToIsolatedRepository() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WebStudio-Integration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    model.addGroup()
    model.renameSelectedGroup("落盘空间")
    let controller = try #require(registry.saveController(for: model.session.id))
    #expect(await controller.saveNow())
    let loaded = try await repository.load(id: model.session.id)
    guard case .loaded(let envelope) = loaded else {
      Issue.record("expected saved configuration")
      return
    }
    #expect(envelope.configuration.name == "落盘空间")
  }

  @Test func cancellingNewWorkspaceThenRenamingExistingDoesNotCreateAnother() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let original = model.session.id
    model.addGroup()
    model.dismissPanel()
    model.beginRenameGroup(original)
    model.renameSelectedGroup("原空间改名")
    #expect(model.groups.count == 1)
    #expect(model.session.id == original)
    #expect(model.session.name == "原空间改名")
  }

  @Test func validDirectoryIsUsedAsTerminalDefault() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebStudio-Terminal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    model.setWorkspaceDirectory(url.path)
    model.newTerminal(directory: nil)
    let record = try #require(model.webRuntimes.resources.last)
    #expect(record.location == .localTerminal(directory: url.path))
  }

  @Test func saveFailureCancelLeavesSessionUsable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebStudio-Failure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(
      repository: repository,
      saveWriter: { configuration, _ in
        throw WorkspaceRepositoryError.permissionFailure(configuration.workspaceID)
      })
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    model.addGroup()
    model.renameSelectedGroup("失败空间")
    let id = model.session.id
    let controller = try #require(registry.saveController(for: id))
    #expect(await controller.saveNow() == false)
    let closed = await model.performCloseWorkspace(id, resolver: { _, _ in .cancel })
    #expect(closed == false)
    #expect(model.session.id == id)
    #expect(!model.session.isClosed)
    model.newTab()
    #expect(model.tabs.count == 1)
  }

  @Test func archivingLastWorkspaceCreatesUsableTemporaryFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WebStudio-Archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = WorkspaceRepository(rootURL: root)
    let registry = WorkspaceRegistry(repository: repository)
    let model = StudioModel(launchTerminalProcesses: false, registry: registry)
    model.beginRenameGroup(model.session.id)
    model.renameSelectedGroup("归档空间")
    let archivedID = model.session.id
    let controller = try #require(registry.saveController(for: archivedID))
    #expect(await controller.saveNow())
    #expect(await model.performArchiveWorkspace(archivedID))
    let loaded = try await repository.load(id: archivedID)
    guard case .loaded(let envelope) = loaded else {
      Issue.record("expected archived file")
      return
    }
    #expect(envelope.configuration.archived)
    #expect(model.session.id != archivedID)
    #expect(!model.session.isClosed)
    model.newTab()
    #expect(model.tabs.count == 1)
  }

  @Test func newWorkspaceEditorCommitsDirectoryOnlyOnSave() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let directory = FileManager.default.temporaryDirectory.path
    model.addGroup()
    #expect(model.commitWorkspaceEditor(name: "带目录空间", directory: directory, targetID: nil, creating: true))
    #expect(model.session.directory == directory)
    #expect(!model.session.isTemporary)
  }

  @Test func cancellingWorkspaceEditorRetainsOriginalDirectory() throws {
    let model = StudioModel(launchTerminalProcesses: false)
    let original = FileManager.default.temporaryDirectory.path
    model.setWorkspaceDirectory(original)
    model.beginRenameGroup(model.session.id)
    model.dismissPanel()
    #expect(model.session.directory == original)
  }
}
