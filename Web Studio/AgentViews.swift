import SwiftUI

struct AgentMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let runID: UUID
    let role: Role
    let text: String
    init(id: UUID = UUID(), runID: UUID, role: Role, text: String) { self.id = id; self.runID = runID; self.role = role; self.text = text }
}

struct AgentSnapshotDisclosure: View {
    let snapshot: ResourceSnapshot
    var body: some View { DisclosureGroup { ScrollView { VStack(alignment: .leading, spacing: 5) { Text(snapshot.text ?? "（无内容）").font(.caption).textSelection(.enabled); if let directory = snapshot.knownDirectory { Text("目录：\(directory)").font(.caption2) }; if let lifecycle = snapshot.lifecycle { Text("状态：\(lifecycle.rawValue)").font(.caption2) }; if let error = snapshot.runtimeErrorMessage { Text("运行时错误：\(error)").font(.caption2).foregroundStyle(.red) }; if let error = snapshot.errorMessage { Text("读取错误：\(error)").font(.caption2).foregroundStyle(.red) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 190) } label: { VStack(alignment: .leading, spacing: 3) { Text(snapshot.title ?? snapshot.resourceID.uuidString); Text("ID：\(snapshot.resourceID.uuidString)").font(.caption2); Text("URL：\(snapshot.sourceURL?.absoluteString ?? "无")").font(.caption2); Text("时间：\(snapshot.collectedAt.formatted()) · 范围：\(snapshot.range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "无") · \(snapshot.isTruncated ? "已截断" : "完整")").font(.caption2) } }.accessibilityIdentifier("agents.snapshot.\(snapshot.resourceID.uuidString)") }
}

struct AgentInspectorView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var agent: AgentController
    @ObservedObject var settings: ProviderSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: StudioModel) {
        self.model = model
        self.agent = model.agentController
        self.settings = model.providerSettings
    }

    var body: some View {
        VStack(spacing: 0) { header; Divider(); transcript; composer }
        .studioShellScrim()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents.inspector")
    }


    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Agent").font(.headline); Spacer()
                Button { agent.newChat() } label: { Image(systemName: "plus.bubble") }.buttonStyle(.borderless).accessibilityLabel("新建对话").accessibilityIdentifier("agents.new-chat")
                Button { model.openProviderSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).accessibilityLabel("设置").accessibilityIdentifier("agents.provider-settings")
                Button { model.agentsVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("关闭 Agent")
            }
        }.padding(16)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in ZStack {
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(agent.messages) { message in
                HStack { if message.role == .assistant { bubble(message); Spacer(minLength: 24) } else { Spacer(minLength: 24); bubble(message) } }
                    .transition(StudioDesign.Motion.messageTransition(reduceMotion: reduceMotion))
                if message.role == .user { Button("查看此问题详情") { model.openAgentRunDetails(message.runID) }.buttonStyle(.borderless).font(.caption2).accessibilityIdentifier("agents.run-details.\(message.runID.uuidString)") }
            }
            if let run = agent.run, case .requesting = run.state { HStack { ProgressView().controlSize(.small); Text("正在思考…").font(.caption).foregroundStyle(.secondary); Spacer() } }
            if let run = agent.run { switch run.state { case .failed(let message): HStack { Text("失败：\(message)").font(.caption).foregroundStyle(.red); Spacer(); Button("重试") { agent.retry() }.buttonStyle(.borderless).accessibilityIdentifier("agents.retry") }; case .cancelled: HStack { Text("已取消").font(.caption).foregroundStyle(.secondary); Spacer(); Button("重试") { agent.retry() }.buttonStyle(.borderless).accessibilityIdentifier("agents.retry") }; default: EmptyView() } }
            Color.clear.frame(height: 1).id("agents.transcript.bottom")
            }.padding(16).frame(minHeight: 120).animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: agent.messages.count) }
            if agent.messages.isEmpty { VStack(spacing: 10) { Image(systemName: "bubble.left.and.bubble.right").font(.title2).foregroundStyle(.secondary); Text("开始对话").font(.callout).foregroundStyle(.secondary) }.transition(.opacity).allowsHitTesting(false) }
        }.animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: agent.messages.count).onChange(of: agent.messages.count) { _, _ in proxy.scrollTo("agents.transcript.bottom", anchor: .bottom) } }
    }
    private func bubble(_ message: AgentMessage) -> some View { Text(message.text).textSelection(.enabled).padding(10).background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
    private var sendHint: String? { if agent.configuration == nil { return "请先在设置中配置 Agent" }; if agent.selectedResourceIDs.isEmpty { return "请先选择资源" }; if agent.previewSnapshots.count != agent.selectedResourceIDs.count { return "请先读取预览" }; if agent.previewSnapshots.contains(where: { $0.errorMessage != nil }) { return "资源读取失败，无法发送" }; return nil }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint = sendHint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) { TextEditor(text: $agent.question).scrollContentBackground(.hidden); if agent.question.isEmpty { Text("输入消息…").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) } }.frame(minHeight: 76, maxHeight: 140).padding(8).accessibilityLabel("输入消息").accessibilityIdentifier("agents.question")
                Divider()
                HStack(spacing: 8) {
                Button { model.openAgentPanel(.agentResources) } label: { Label("资源", systemImage: "paperclip") }.buttonStyle(.borderless).accessibilityIdentifier("agents.resources")
                Button { model.openAgentPanel(.agentPreview) } label: { Label("预览", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.borderless).accessibilityIdentifier("agents.preview")
                Spacer()
                Button { isRequesting ? agent.cancel() : agent.send() } label: {
                    Image(systemName: isRequesting ? "stop.circle.fill" : "arrow.up.circle.fill").contentTransition(.opacity)
                }.buttonStyle(.borderless).frame(width: 28, height: 28).animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: isRequesting).disabled(!isRequesting && !agent.canSend).accessibilityLabel(isRequesting ? "停止" : "发送").accessibilityIdentifier("agents.send")
                }.padding(8)
            }.studioGlassSurface(cornerRadius: StudioDesign.Radius.panel).overlay(RoundedRectangle(cornerRadius: StudioDesign.Radius.panel).stroke(StudioDesign.Color.divider))
        }.padding(StudioDesign.Spacing.panel)
    }

    private var isRequesting: Bool { if case .requesting? = agent.run?.state { return true }; return false }

}

struct AgentResourcesPanel: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var agent: AgentController
    init(model: StudioModel) { self.model = model; self.agent = model.agentController }
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        HStack { Text("资源").font(.headline); Spacer(); Button("关闭") { model.dismissPanel() } }
        ScrollView { VStack(alignment: .leading, spacing: 8) {
            ForEach(model.webRuntimes.resources) { record in
                let selected = agent.selectedResourceIDs.contains(record.id)
                Button { selected ? agent.removeResource(record.id) : agent.addResource(record.id) } label: {
                    HStack { Image(systemName: selected ? "checkmark.circle.fill" : "circle"); Image(systemName: studioResourceSymbol(record.kind)); Text(record.customTitle ?? record.title); Spacer(); Text(record.kind.rawValue).font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("agents.resource.\(record.id.uuidString)").accessibilityValue(selected ? "已选择" : "未选择")
            }
            ForEach(agent.selectedResourceIDs.filter { model.webRuntimes.records[$0] == nil }, id: \.self) { id in
                HStack { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text("资源已关闭（\(id.uuidString.prefix(8))）"); Spacer(); Button("移除") { agent.removeResource(id) } }.font(.caption).accessibilityIdentifier("agents.closed-resource.\(id.uuidString)")
            }
            if agent.selectedResourceIDs.isEmpty { Text("选择要提供给 Agent 的资源").font(.caption).foregroundStyle(.secondary) }
        } }
    }.padding(20).frame(width: 440, height: 420).onExitCommand { model.dismissPanel() }.accessibilityElement(children: .contain).accessibilityIdentifier("agents.resources.panel") }
}

struct AgentPreviewPanel: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var agent: AgentController
    init(model: StudioModel) { self.model = model; self.agent = model.agentController }
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        HStack { Text("预览").font(.headline); Spacer(); Button("关闭") { model.dismissPanel() } }
        if agent.isReading { HStack { ProgressView(); Text("正在读取…"); Spacer(); Button("取消") { agent.cancelReading() } } }
        if let error = agent.previewError { StudioInlineFeedback(message: error, isError: true).accessibilityElement(children: .combine).accessibilityIdentifier("agents.preview.error") }
        ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(agent.previewSnapshots, id: \.resourceID) { snapshot in AgentSnapshotDisclosure(snapshot: snapshot) } } }
        if agent.previewSnapshots.isEmpty && !agent.isReading { Text("选择资源后读取预览").font(.caption).foregroundStyle(.secondary) }
        Button("读取预览") { agent.readPreview() }.studioGlassButton(prominent: true).disabled(agent.selectedResourceIDs.isEmpty || agent.isReading).accessibilityIdentifier("agents.preview.read")
    }.padding(20).frame(width: 520, height: 500).onExitCommand { model.dismissPanel() }.accessibilityElement(children: .contain).accessibilityIdentifier("agents.preview.panel") }
}

struct AgentRunDetailsPanel: View {
    @ObservedObject var model: StudioModel; @ObservedObject var agent: AgentController; let runID: UUID
    init(model: StudioModel, runID: UUID) { self.model = model; self.agent = model.agentController; self.runID = runID }
    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Text("运行详情").font(.headline); Spacer(); Button("关闭") { model.dismissPanel() } }; if let run = agent.run(for: runID) { Text("问题").font(.subheadline.bold()); Text(run.request.question).textSelection(.enabled); Text("后端：\(run.request.configuration.backend == .codexCLI ? "Codex CLI" : "Responses API")"); Text("模型：\(run.request.configuration.model.isEmpty ? "CLI 默认" : run.request.configuration.model)"); if let endpoint = run.request.configuration.endpoint { Text("端点：\(endpoint.absoluteString)") } else if let path = run.request.configuration.cliPath { Text("CLI：\(path)") }; Text("快照：\(run.request.snapshots.count) 个"); ScrollView { ForEach(run.request.snapshots, id: \.resourceID) { AgentSnapshotDisclosure(snapshot: $0) } }.frame(maxHeight: 300) } else { Text("该运行已不可用").foregroundStyle(.secondary) } }.padding(20).frame(width: 520, height: 500).onExitCommand { model.dismissPanel() }.accessibilityElement(children: .contain).accessibilityIdentifier("agents.run-details.panel.\(runID.uuidString)") }
}

struct ProviderSettingsView: View {
    @ObservedObject var settings: ProviderSettings
    @ObservedObject var model: StudioModel
    @State private var key = ""
    @State private var busy = false
    @FocusState private var endpointFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudioDesign.Spacing.control) {
                Text("Provider settings").font(.headline)
                Text(settings.backend == .codexCLI ? "Use the installed Codex CLI with your existing Terminal login." : "Configure the endpoint and model used for Agent requests. The API key is stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                StudioFieldLabel(title: "Backend")
                Picker("Backend", selection: Binding(get: { settings.backend }, set: { settings.selectBackend($0) })) {
                    Text("Responses API").tag(AgentBackend.responses)
                    Text("Codex CLI").tag(AgentBackend.codexCLI)
                }.pickerStyle(.segmented).disabled(settings.isBusy).accessibilityIdentifier("provider.backend")
                if settings.backend == .codexCLI {
                    Text("Uses your existing Codex CLI login. Run `codex login` in Terminal if needed; this app never reads or copies tokens.").font(.caption).foregroundStyle(.secondary)
                    StudioFieldLabel(title: "Codex CLI path")
                    TextField("/opt/homebrew/bin/codex", text: Binding(get: { settings.cliPathText }, set: { settings.cliPathText = $0; settings.invalidateCheck() })).textFieldStyle(.roundedBorder).disabled(settings.isBusy).accessibilityIdentifier("provider.cli-path")
                } else {
                StudioFieldLabel(title: "HTTPS endpoint")
                TextField("HTTPS endpoint", text: $settings.endpointText)
                    .textFieldStyle(.roundedBorder)
                    .focused($endpointFocused)
                    .disabled(settings.isBusy)
                    .accessibilityIdentifier("provider.endpoint")
                }
                StudioFieldLabel(title: "Model")
                TextField("Model (optional for Codex CLI)", text: Binding(get: { settings.modelText }, set: { settings.modelText = $0; settings.invalidateCheck() }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider.model").disabled(settings.isBusy)
                if settings.backend == .codexCLI {
                    HStack { Button("Check CLI login") { Task { await settings.checkCLILogin() } }.studioGlassButton().disabled(settings.isBusy).accessibilityIdentifier("provider.cli-check"); Text("Model blank uses the CLI default").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    StudioFieldLabel(title: "API key")
                    SecureField("API key (leave blank to keep current)", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy || settings.isBusy)
                        .accessibilityIdentifier("provider.key")
                }
                Text(settings.status.studioLabel + (settings.cliVersion.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(settings.status.studioIsError ? StudioDesign.Color.error : .secondary).accessibilityIdentifier("provider.cli-status")
                if let errorMessage = settings.errorMessage {
                    StudioInlineFeedback(message: errorMessage, isError: true)
                }
                HStack {
                    Button("Cancel") { settings.resetDraft(); model.dismissPanel() }.studioGlassButton()
                    Spacer()
                    if settings.backend == .responses { Button("Delete Key") {
                        busy = true
                        Task { await settings.deleteKey(); key = ""; busy = false }
                    }.studioGlassButton().disabled(busy || settings.isBusy).accessibilityIdentifier("provider.delete-key") }
                    Button("Save") {
                        let submitted = key
                        key = ""
                        busy = true
                        Task { await settings.save(key: submitted.isEmpty ? nil : submitted); busy = false }
                    }.studioGlassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(busy || settings.isBusy).accessibilityIdentifier("provider.save")
                }
            }
            .padding(StudioDesign.Spacing.inset)
        }
        .frame(width: 460, height: 420)
        .accessibilityIdentifier("provider.settings")
        .onAppear {
            settings.refreshStatus()
            DispatchQueue.main.async { endpointFocused = true }
        }
        .onExitCommand { settings.resetDraft(); model.dismissPanel() }
    }

}
