import SwiftUI

private func agentKindLabel(_ kind: ResourceKind) -> String { switch kind { case .web: return "网页"; case .localTerminal: return "终端"; case .sshTerminal: return "SSH" } }
private func agentLifecycleLabel(_ lifecycle: ResourceLifecycle) -> String { switch lifecycle { case .idle: return "待启动"; case .starting: return "启动中"; case .running: return "运行中"; case .exited: return "已结束"; case .failed: return "失败"; case .interrupted: return "已中断"; case .closed: return "已关闭" } }

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
    var body: some View { DisclosureGroup { ScrollView { VStack(alignment: .leading, spacing: 5) { Text(snapshot.text ?? "（无内容）").font(.caption).textSelection(.enabled); if let directory = snapshot.knownDirectory { Text("目录：\(directory)").font(.caption2) }; if let instanceID = snapshot.instanceID { Text("运行实例：\(instanceID.uuidString)").font(.caption2) }; if let lifecycle = snapshot.lifecycle { Text("状态：\(agentLifecycleLabel(lifecycle))").font(.caption2) }; if let error = snapshot.runtimeErrorMessage { Text("运行时错误：\(error)").font(.caption2).foregroundStyle(.red) }; if let error = snapshot.errorMessage { Text("读取错误：\(error)").font(.caption2).foregroundStyle(.red) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 190) } label: { VStack(alignment: .leading, spacing: 3) { Text(snapshot.title ?? snapshot.resourceID.uuidString); Text("ID：\(snapshot.resourceID.uuidString)").font(.caption2); Text("URL：\(snapshot.sourceURL?.absoluteString ?? "无")").font(.caption2); Text("时间：\(snapshot.collectedAt.formatted()) · 范围：\(snapshot.range.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "无") · \(snapshot.isTruncated ? "已截断" : "完整")").font(.caption2) } }.accessibilityIdentifier("agents.snapshot.\(snapshot.resourceID.uuidString)") }
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
        VStack(spacing: 0) { header; Text("问答仅保留至关闭空间或退出应用").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16); Divider(); transcript; composer }
        .studioShellScrim()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents.inspector")
    }


    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("问答").font(.headline)
                Menu {
                    ForEach(agent.questionOrder, id: \.self) { id in
                        Button(questionLabel(id)) { agent.selectQuestion(id) }.accessibilityIdentifier("agents.question.\(id.uuidString)")
                    }
                    Divider()
                    Button("新建问题") { _ = agent.newQuestion() }.accessibilityIdentifier("agents.menu.new-question")
                } label: { Label(questionLabel(agent.currentQuestionID), systemImage: "chevron.down") }.accessibilityIdentifier("agents.question-picker")
                Spacer()
                Button { _ = agent.newQuestion() } label: { Image(systemName: "plus.bubble") }.buttonStyle(.borderless).accessibilityLabel("新建问题").accessibilityIdentifier("agents.new-question")
                Button { model.openProviderSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).accessibilityLabel("设置").accessibilityIdentifier("agents.provider-settings")
                Button { model.hideQuestionPanel() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("收起问答")
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
            if let run = agent.run { switch run.state { case .failed(let message): HStack { Text("失败：\(message)").font(.caption).foregroundStyle(.red); Spacer(); Button("用原快照重试") { agent.retry() }.buttonStyle(.borderless).accessibilityIdentifier("agents.retry") }; case .cancelled: HStack { Text("已取消").font(.caption).foregroundStyle(.secondary); Spacer(); Button("用原快照重试") { agent.retry() }.buttonStyle(.borderless).accessibilityIdentifier("agents.retry") }; default: EmptyView() } }
            Color.clear.frame(height: 1).id("agents.transcript.bottom")
            }.padding(16).frame(minHeight: 120).animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: agent.messages.count) }
            if let active = agent.activeRequest, active.questionID != agent.currentQuestionID {
                HStack(spacing: 8) { Text("另一问题正在请求中").font(.caption); Button("查看原问题") { agent.selectQuestion(active.questionID) }.buttonStyle(.borderless); Button(agent.isCancellingRequest ? "正在停止…" : "停止") { agent.cancel(questionID: active.questionID) }.buttonStyle(.borderless) }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity, alignment: .top).accessibilityIdentifier("agents.background-request")
            } else if agent.messages.isEmpty { VStack(spacing: 10) { Image(systemName: "bubble.left.and.bubble.right").font(.title2).foregroundStyle(.secondary); Text("新问题").font(.callout).foregroundStyle(.secondary) }.transition(.opacity).allowsHitTesting(false) }
        }.animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: agent.messages.count).onChange(of: agent.messages.count) { _, _ in proxy.scrollTo("agents.transcript.bottom", anchor: .bottom) } }
    }
    private func bubble(_ message: AgentMessage) -> some View { Text(message.text).textSelection(.enabled).padding(10).background(message.role == .user ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
    private func questionLabel(_ id: UUID) -> String { guard let q = agent.questions[id] else { return "新问题" }; let text = q.messages.first(where: { $0.role == .user })?.text ?? q.draft; let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? "新问题" : String(trimmed.prefix(24)) }
    private var sendHint: String? { if agent.configuration == nil { return "请先在设置中配置 Agent" }; if agent.isCancellingRequest { return "正在停止上一条请求…" }; if let active = agent.activeRequest, active.questionID != agent.currentQuestionID { return "另一问题正在请求中，请等待完成或先停止原问题" }; if agent.selectedResourceIDs.isEmpty { return "请先选择资源" }; if agent.previewSnapshots.count != agent.selectedResourceIDs.count { return "请先读取预览" }; if agent.previewSnapshots.contains(where: { $0.errorMessage != nil }) { return "资源读取失败，请重新读取资料或移除失败来源" }; if agent.questions[agent.currentQuestionID]?.previewConfirmed != true { return "请先确认这些资料" }; return nil }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            selectedSources
            if let hint = sendHint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) { TextEditor(text: $agent.question).scrollContentBackground(.hidden); if agent.question.isEmpty { Text("输入问题…").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) } }.frame(minHeight: 76, maxHeight: 140).padding(8).accessibilityLabel("输入问题").accessibilityIdentifier("agents.question")
                Divider()
                HStack(spacing: 8) {
                Button { model.openAgentPanel(.agentResources) } label: { Label("资源", systemImage: "paperclip") }.buttonStyle(.borderless).accessibilityIdentifier("agents.resources")
                Button { model.openAgentPanel(.agentPreview) } label: { Label("预览", systemImage: "doc.text.magnifyingglass") }.buttonStyle(.borderless).accessibilityIdentifier("agents.preview")
                Spacer()
                Button { isRequesting ? agent.cancel() : agent.send() } label: {
                    Image(systemName: isRequesting ? "stop.circle.fill" : "arrow.up.circle.fill").contentTransition(.opacity)
                }.buttonStyle(.borderless).frame(width: 28, height: 28).animation(StudioDesign.Motion.animation(StudioDesign.Motion.message, reduceMotion: reduceMotion), value: isRequesting).disabled(agent.isCancellingRequest || (!isRequesting && !agent.canSend)).accessibilityLabel(agent.isCancellingRequest ? "正在停止" : (isRequesting ? "停止" : "发送")).accessibilityIdentifier("agents.send")
                }.padding(8)
            }.studioGlassSurface(cornerRadius: StudioDesign.Radius.panel).overlay(RoundedRectangle(cornerRadius: StudioDesign.Radius.panel).stroke(StudioDesign.Color.divider))
        }.padding(StudioDesign.Spacing.panel)
    }

    private var isRequesting: Bool { agent.activeRequest?.questionID == agent.currentQuestionID }

    private var selectedSources: some View {
        Group {
        if !agent.selectedResourceIDs.isEmpty { ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(agent.selectedResourceIDs, id: \.self) { id in
                    let snapshot = agent.previewSnapshots.first { $0.resourceID == id }
                    HStack(spacing: 6) {
                        Image(systemName: snapshot == nil ? "clock" : (snapshot?.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.webRuntimes.records[id]?.customTitle ?? snapshot?.title ?? model.webRuntimes.records[id]?.title ?? "资源已关闭")
                            Text("ID：\(id.uuidString.prefix(8)) · \(snapshot.map(sourceStatus) ?? "待读取")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if snapshot?.errorMessage != nil {
                            Button("重新读取资料") { agent.readPreview() }.buttonStyle(.borderless)
                                .accessibilityLabel("重新读取资料")
                        }
                        Button("移除") { agent.removeResource(id) }.buttonStyle(.borderless)
                            .accessibilityLabel("移除来源")
                    }
                    .font(.caption)
                    .accessibilityElement(children: .contain)
                    .help(snapshot.map(sourceStatus) ?? "待读取")
                    .accessibilityIdentifier("agents.selected-source.\(id.uuidString)")
                }
            }
        }
        .frame(maxHeight: 100) }
        }
    }

    private func sourceStatus(_ snapshot: ResourceSnapshot) -> String {
        var value = "采集于 \(snapshot.collectedAt.formatted(date: .omitted, time: .shortened))"
        if snapshot.isTruncated { value += " · 已截断" }
        if let error = snapshot.errorMessage { value += " · 读取失败：\(error)" }
        return value
    }

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
                    HStack { Image(systemName: selected ? "checkmark.circle.fill" : "circle"); Image(systemName: studioResourceSymbol(record.kind)); Text(record.customTitle ?? record.title); Spacer(); Text(agentKindLabel(record.kind)).font(.caption).foregroundStyle(.secondary) }
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
        ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(agent.previewSnapshots, id: \.resourceID) { snapshot in VStack(alignment: .leading, spacing: 4) { AgentSnapshotDisclosure(snapshot: snapshot); if snapshot.errorMessage != nil { HStack { Button("重新读取资料") { agent.readPreview() }.buttonStyle(.borderless).accessibilityIdentifier("agents.preview.retry.\(snapshot.resourceID.uuidString)"); Button("移除来源") { agent.removeResource(snapshot.resourceID) }.buttonStyle(.borderless).accessibilityIdentifier("agents.preview.remove.\(snapshot.resourceID.uuidString)") } } } } } }
        if agent.previewSnapshots.isEmpty && !agent.isReading { Text("选择资源后读取预览").font(.caption).foregroundStyle(.secondary) }
        if agent.questions[agent.currentQuestionID]?.previewConfirmed == true { Label("资料已确认，可发送", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) } else if !agent.previewSnapshots.isEmpty && !agent.isReading { Button("确认这些资料") { _ = agent.confirmPreview() }.studioGlassButton(prominent: true).disabled(agent.previewSnapshots.contains(where: { $0.errorMessage != nil })).accessibilityIdentifier("agents.preview.confirm") }
        Button(agent.previewSnapshots.isEmpty ? "读取预览" : "重新读取资料") { agent.readPreview() }.studioGlassButton(prominent: true).disabled(agent.selectedResourceIDs.isEmpty || agent.isReading).accessibilityIdentifier("agents.preview.read")
    }.padding(20).frame(width: 520, height: 500).onExitCommand { model.dismissPanel() }.accessibilityElement(children: .contain).accessibilityIdentifier("agents.preview.panel") }
}

struct AgentRunDetailsPanel: View {
    @ObservedObject var model: StudioModel; @ObservedObject var agent: AgentController; let runID: UUID
    init(model: StudioModel, runID: UUID) { self.model = model; self.agent = model.agentController; self.runID = runID }
    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Text("运行详情").font(.headline); Spacer(); Button("关闭") { model.dismissPanel() } }; if let run = agent.run(for: runID) { Text("问题 ID：\(run.questionID.uuidString)").font(.caption2); Text("问题").font(.subheadline.bold()); Text(run.request.question).textSelection(.enabled); Text("后端：\(run.request.configuration.backend == .codexCLI ? "Codex CLI" : "Responses API")"); Text("模型：\(run.request.configuration.model.isEmpty ? "CLI 默认" : run.request.configuration.model)"); if let endpoint = run.request.configuration.endpoint { Text("端点：\(endpoint.absoluteString)") } else if let path = run.request.configuration.cliPath { Text("CLI：\(path)") }; Text("快照：\(run.request.snapshots.count) 个"); ScrollView { ForEach(run.request.snapshots, id: \.resourceID) { AgentSnapshotDisclosure(snapshot: $0) } }.frame(maxHeight: 300) } else { Text("该运行已不可用").foregroundStyle(.secondary) } }.padding(20).frame(width: 520, height: 500).onExitCommand { model.dismissPanel() }.accessibilityElement(children: .contain).accessibilityIdentifier("agents.run-details.panel.\(runID.uuidString)") }
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
                Text("模型服务设置").font(.headline)
                Text(settings.backend == .codexCLI ? "使用已安装的 Codex CLI 和现有终端登录状态。" : "配置 Agent 请求使用的端点和模型。API 密钥保存在 macOS 钥匙串中。")
                    .font(.caption).foregroundStyle(.secondary)
                StudioFieldLabel(title: "后端")
                Picker("后端", selection: Binding(get: { settings.backend }, set: { settings.selectBackend($0) })) {
                    Text("Responses API").tag(AgentBackend.responses)
                    Text("Codex CLI").tag(AgentBackend.codexCLI)
                }.pickerStyle(.segmented).disabled(settings.isBusy).accessibilityIdentifier("provider.backend")
                if settings.backend == .codexCLI {
                    Text("使用现有 Codex CLI 登录状态。如需登录，请在终端中运行 `codex login`；本应用不会读取或复制令牌。").font(.caption).foregroundStyle(.secondary)
                    StudioFieldLabel(title: "Codex CLI 路径")
                    TextField("/opt/homebrew/bin/codex", text: Binding(get: { settings.cliPathText }, set: { settings.cliPathText = $0; settings.invalidateCheck() })).textFieldStyle(.roundedBorder).disabled(settings.isBusy).accessibilityIdentifier("provider.cli-path")
                } else {
                StudioFieldLabel(title: "HTTPS 端点")
                TextField("HTTPS 端点", text: $settings.endpointText)
                    .textFieldStyle(.roundedBorder)
                    .focused($endpointFocused)
                    .disabled(settings.isBusy)
                    .accessibilityIdentifier("provider.endpoint")
                }
                StudioFieldLabel(title: "模型")
                TextField("模型（Codex CLI 可选）", text: Binding(get: { settings.modelText }, set: { settings.modelText = $0; settings.invalidateCheck() }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider.model").disabled(settings.isBusy)
                if settings.backend == .codexCLI {
                    HStack { Button("检查 CLI 登录") { Task { await settings.checkCLILogin() } }.studioGlassButton().disabled(settings.isBusy).accessibilityIdentifier("provider.cli-check"); Text("模型留空时使用 CLI 默认值").font(.caption2).foregroundStyle(.secondary) }
                } else {
                    StudioFieldLabel(title: "API 密钥")
                    SecureField("API 密钥（留空以保留当前值）", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy || settings.isBusy)
                        .accessibilityIdentifier("provider.key")
                }
                Text(settings.status.studioLabel + (settings.cliVersion.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(settings.status.studioIsError ? StudioDesign.Color.error : .secondary).accessibilityIdentifier("provider.cli-status")
                if let errorMessage = settings.errorMessage {
                    StudioInlineFeedback(message: errorMessage, isError: true)
                }
                HStack {
                    Button("取消") { settings.resetDraft(); model.dismissPanel() }.studioGlassButton()
                    Spacer()
                    if settings.backend == .responses { Button("删除 API 密钥") {
                        busy = true
                        Task { await settings.deleteKey(); key = ""; busy = false }
                    }.studioGlassButton().disabled(busy || settings.isBusy).accessibilityIdentifier("provider.delete-key") }
                    Button("保存") {
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
