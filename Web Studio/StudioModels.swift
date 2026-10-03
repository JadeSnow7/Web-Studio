import Foundation

enum StudioDestination: Equatable {
  case blank
  case terminal(directory: String)
  case web(URL)
  case ssh(host: String, user: String, port: Int)
  var title: String {
    switch self {
    case .blank: return "新标签页"
    case .terminal(let directory):
      return "终端 · \(URL(fileURLWithPath: directory).lastPathComponent)"
    case .web(let url):
      guard let host = url.host else { return url.absoluteString }
      let defaultPort =
        (url.scheme?.lowercased() == "http" && url.port == 80)
        || (url.scheme?.lowercased() == "https" && url.port == 443)
      return if let port = url.port, !defaultPort {
        "\(host):\(port)"
      } else {
        host
      }
    case .ssh(
      let
        host,
      let

        user,
      let

        port
    ):
      let id =
        user
          .isEmpty ? host : "\(user)@\(host)"
      return port == 22 ? id : "\(id):\(port)"
    }
  }

  var detail: String? {
    guard case .web(let url) = self else { return nil }
    return [
      url.path.isEmpty ? nil : url.path,
      url.query.map { "?\($0)" },
      url.fragment.map { "#\($0)" },
    ].compactMap { $0 }.joined()
  }

  var accessibilityTitle: String {
    if case .web(let url) = self {
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
  case selectWorkspaceResource(workspaceID: UUID, resourceID: UUID)
  case back(resourceID: UUID)
  case forward(resourceID: UUID)
  case reload(resourceID: UUID)
  case stop(resourceID: UUID)
  case toggleSidebar, toggleAgents
}
struct WorkspaceResourceSearchResult: Identifiable, Equatable {
  let workspaceID: UUID
  let resourceID: UUID
  let workspaceName: String
  let resourceTitle: String
  let kind: ResourceKind
  let destinationSummary: String
  var id: String { "\(workspaceID.uuidString):\(resourceID.uuidString)" }
}
struct StudioCommand: Identifiable {
  let title: String
  let shortcut: String
  let targetResourceID: UUID?
  let action: StudioCommandAction
  let subtitle: String?
  init(
    title: String, shortcut: String, targetResourceID: UUID? = nil, subtitle: String? = nil, action: StudioCommandAction
  ) {
    self.title = title
    self.shortcut = shortcut
    self.targetResourceID = targetResourceID
    self.subtitle = subtitle
    self.action = action
  }
  var id: String {
    if case .selectWorkspaceResource(let workspaceID, let resourceID) = action {
      return "resource:\(workspaceID.uuidString):\(resourceID.uuidString)"
    }
    return "\(title)|\(targetResourceID?.uuidString ?? "none")"
  }
  var searchText: String {
    [title, subtitle ?? ""].joined(separator: " ").localizedLowercase
  }
}

struct StudioLayoutPlan: Equatable {
  let sidebarWidth: CGFloat
  let agentsWidth: CGFloat
  let compactSidebar: Bool
  let adaptationMessage: String?
  let isCompactMode: Bool
  let contentVisible: Bool
  let questionsVisible: Bool

  static func resolve(
    windowWidth: CGFloat,
    sidebarWidth: CGFloat,
    agentsWidth: CGFloat,
    sidebarVisible: Bool,
    agentsVisible: Bool
  ) -> Self {
    let isCompactMode = windowWidth < 1100
    if isCompactMode {
      return .init(
        sidebarWidth: 0,
        agentsWidth: 0,
        compactSidebar: false,
        adaptationMessage: nil,
        isCompactMode: true,
        contentVisible: !agentsVisible,
        questionsVisible: agentsVisible)
    }
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
      message = "已缩窄问答面板以保留工作区。"
    } else if compact {
      message = "已缩窄空间栏以保留工作区。"
    }
    return .init(
      sidebarWidth: left,
      agentsWidth: right,
      compactSidebar: compact,
      adaptationMessage: message,
      isCompactMode: false,
      contentVisible: true,
      questionsVisible: agentsVisible
    )
  }
}
