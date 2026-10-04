import AppKit
import SwiftUI

@MainActor
func makeWorkspaceSaveFailureResolver(action: String) -> WorkspaceCloseResolver {
  { session, message in
    let alert = NSAlert()
    alert.messageText = "保存“\(session.name)”失败"
    alert.informativeText = "\(message)\n请选择如何\(action)。"
    alert.addButton(withTitle: "重试并\(action)")
    alert.addButton(withTitle: "取消\(action)")
    alert.addButton(withTitle: "不保存并\(action)")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .retry
    case .alertThirdButtonReturn: return .discard
    default: return .cancel
    }
  }
}

@MainActor
func confirmTemporaryWorkspaceClose(_ session: WorkspaceSession, registry: WorkspaceRegistry) -> Bool {
  let hasContent =
    !session.isEmpty || session.agentController.questions.count > 1
    || session.agentController.questions.values.contains {
      !$0.draft.isEmpty || !$0.messages.isEmpty || !$0.snapshots.isEmpty
        || !$0.selectedResourceIDs.isEmpty
    }
  guard hasContent else { return true }
  let alert = NSAlert()
  alert.messageText = "关闭临时空间“\(session.name)”？"
  alert.informativeText = "问答和运行状态会清空；保存只保留资源、布局和目录配置。"
  alert.addButton(withTitle: "保存配置后关闭")
  alert.addButton(withTitle: "不保存关闭")
  alert.addButton(withTitle: "取消")
  let field = NSTextField(string: "")
  field.placeholderString = "保存时输入空间名称"
  field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
  alert.accessoryView = field
  switch alert.runModal() {
  case .alertFirstButtonReturn:
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && registry.rename(session.id, name: name)
  case .alertSecondButtonReturn: return true
  default: return false
  }
}

struct WindowLifecycle: NSViewRepresentable {
  @ObservedObject var model: StudioModel
  func makeNSView(context: Context) -> LifecycleView { LifecycleView(model: model) }
  func updateNSView(_ nsView: LifecycleView, context: Context) { nsView.model = model }
}

final class LifecycleView: NSView {
  var model: StudioModel
  private var proxy: WindowDelegateProxy?
  init(model: StudioModel) {
    self.model = model
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    model.windowCoordinator.window = window
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = .clear
    window.isOpaque = false
    if proxy == nil || window.delegate !== proxy {
      proxy = WindowDelegateProxy(original: window.delegate, model: model)
      window.delegate = proxy
    }
  }
  override func removeFromSuperview() {
    if let window, window.delegate === proxy { window.delegate = proxy?.original }
    proxy = nil
    super.removeFromSuperview()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil, let window, window.delegate === proxy { window.delegate = proxy?.original }
    super.viewWillMove(toWindow: newWindow)
  }
}

final class WindowDelegateProxy: NSObject, NSWindowDelegate {
  weak var original: NSWindowDelegate?
  let model: StudioModel
  private let confirmClose: (WorkspaceCloseSummary) -> Bool
  private let confirmTemporaryClose: (WorkspaceSession, WorkspaceRegistry) -> Bool
  private let resolveSaveFailure: WorkspaceCloseResolver?
  private var closing = false
  init(
    original: NSWindowDelegate?, model: StudioModel,
    confirmClose: ((WorkspaceCloseSummary) -> Bool)? = nil,
    saveFailureResolver: WorkspaceCloseResolver? = nil,
    temporaryCloseConfirmation: ((WorkspaceSession, WorkspaceRegistry) -> Bool)? = nil
  ) {
    self.original = original
    self.model = model
    self.confirmClose =
      confirmClose ?? { summary in
        let alert = NSAlert()
        alert.messageText = "关闭此窗口及其工作空间？"
        alert.informativeText =
          summary.entries.map { entry in
            "\(entry.name)：\(entry.runningTerminals) 个终端，\(entry.requestingAgents) 个请求"
          }.joined(separator: "\n") + "\n将清空这些空间的问答；关闭前会逐一处理配置保存。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "关闭窗口")
        return alert.runModal() == .alertSecondButtonReturn
      }
    self.resolveSaveFailure = saveFailureResolver
    self.confirmTemporaryClose = temporaryCloseConfirmation ?? confirmTemporaryWorkspaceClose
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
      original.windowShouldClose?(sender) == false
    {
      return false
    }
    guard !closing else { return false }
    let summary = model.windowCoordinator.closeSummary()
    if !summary.entries.isEmpty {
      guard confirmClose(summary) else { return false }
    }
    for session in model.windowCoordinator.loadedSessions.values where session.isTemporary {
      guard confirmTemporaryClose(session, model.windowCoordinator.registry) else { return false }
    }
    closing = true
    let injectedResolver = resolveSaveFailure
    Task { @MainActor [model, weak sender] in
      let resolver: WorkspaceCloseResolver
      if let injectedResolver {
        resolver = injectedResolver
      } else {
        resolver = makeWorkspaceSaveFailureResolver(action: "关闭窗口")
      }
      let closed = await model.windowCoordinator.closeAll(resolver: resolver)
      if closed {
        sender?.close()
      } else {
        closing = false
      }
    }
    return false
  }
  override func responds(to selector: Selector) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }
  override func forwardingTarget(for selector: Selector) -> Any? {
    original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
  }
}
