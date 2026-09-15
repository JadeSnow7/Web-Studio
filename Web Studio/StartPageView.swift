import SwiftUI

struct StartEntryView: View {
    @ObservedObject var model: StudioModel
    @State private var title = ""
    @State private var destination = ""
    @State private var error: String?
    @FocusState private var destinationFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加固定入口").font(.headline)
            Text("名称").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("名称", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("start-entry.title")
            Text("地址").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("网址、SSH 地址或本地路径", text: $destination).textFieldStyle(.roundedBorder).focused($destinationFocused).accessibilityIdentifier("start-entry.destination")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("取消") { model.dismissPanel() }.studioGlassButton(); Spacer(); Button("添加") {
                guard let parsed = StudioModel.parseAddress(destination) else { error = "请输入有效的网址、SSH 地址或本地路径"; return }
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                model.addPinnedDestination(title: cleanTitle.isEmpty ? parsed.title : cleanTitle, destination: parsed)
            }.studioGlassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 360).onAppear { destinationFocused = true }.onExitCommand { model.dismissPanel() }
    }
}

/// The blank web resource is a quiet session entry point. It deliberately derives
/// every destination from the current ResourceStore; no sample URLs are presented.
struct StartPageView: View {
    @ObservedObject var model: StudioModel
    let resourceID: UUID

    private var pinned: [PinnedDestination] { model.pinnedDestinations }
    private var recent: [ResourceRecord] {
        model.recentResourceIDs.compactMap { model.webRuntimes.records[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("从这里开始").font(.system(size: 28, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 26).padding(.vertical, 16)
                    .background {
                        RadialGradient(colors: [Color.accentColor.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 150)
                            .frame(width: 300, height: 300)
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(spacing: 10) { actions }
                }
                .frame(maxWidth: .infinity)

                resourceSection("固定入口") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                        ForEach(pinned) { record in resourceCard(record) }
                        Button { model.openStartEntryPanel() } label: {
                            VStack(spacing: 9) { Image(systemName: "plus").font(.title2); Text("添加入口") }
                                .frame(maxWidth: .infinity, minHeight: 84)
                        }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12)).studioHoverLift().accessibilityIdentifier("start.add-pin")
                    }
                }

                if !recent.isEmpty {
                    resourceSection("最近使用") {
                        VStack(spacing: 0) {
                            ForEach(recent) { record in recentRow(record) }
                        }.studioGlassSurface(cornerRadius: StudioDesign.Radius.panel)
                    }
                }
                HStack(spacing: 20) {
                    Text("⌘L  输入地址")
                    Text("⌘K  查找与操作")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 650)
            .padding(.horizontal, 36).padding(.vertical, 70)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("start.page")
    }

    @ViewBuilder private var actions: some View {
        startAction("打开网页", systemImage: studioResourceSymbol(.web)) { model.requestAddressFocus(targetResourceID: resourceID) }
        startAction("本地终端", systemImage: studioResourceSymbol(.localTerminal)) {
            model.openStartTerminal(from: resourceID)
        }
        startAction("SSH 连接", systemImage: studioResourceSymbol(.sshTerminal)) { model.openSSHDestination(targetResourceID: resourceID) }
    }

    private func startAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage).frame(maxWidth: .infinity, minHeight: 54) }
            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12)).studioHoverLift().accessibilityIdentifier("start.action.\(title)")
    }

    @ViewBuilder private func resourceSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); content() }
    }

    private func resourceCard(_ record: PinnedDestination) -> some View {
        Button { model.openPinnedDestination(record, from: resourceID) } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol(for: record.destination)).font(.title2)
                Text(record.title).lineLimit(1)
            }.frame(maxWidth: .infinity, minHeight: 84)
        }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 12)).studioHoverLift().contextMenu { Button("取消固定") { model.pinnedDestinations.removeAll { $0.id == record.id } } }
    }

    private func symbol(for destination: StudioDestination) -> String {
        return studioResourceSymbol(destination)
    }

    private func recentRow(_ record: ResourceRecord) -> some View {
        Button { model.selectResource(record.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: studioResourceSymbol(record.kind)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.customTitle ?? record.title)
                    Text(detail(for: record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(StudioPressButtonStyle()).studioHoverLift()
            .contextMenu {
                if model.isPinned(record.id) {
                    Button("取消固定") { model.unpinDestination(for: record.id) }
                } else {
                    Button("固定入口") { model.pinDestination(for: record.id) }
                }
            }
    }

    private func detail(for record: ResourceRecord) -> String {
        switch record.location {
        case let .web(url): return url?.absoluteString ?? "New Tab"
        case let .localTerminal(directory): return directory ?? "本地终端"
        case let .ssh(host, user, port): return "\(user.isEmpty ? "" : user + "@")\(host):\(port)"
        }
    }
}
