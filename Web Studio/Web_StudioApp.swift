import SwiftUI
import AppKit

@MainActor final class StudioApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        if ResourceStore.liveTerminalCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Terminal sessions are still running"
            alert.informativeText = "Quitting will terminate the running terminal sessions."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminationInProgress = true
        Task { @MainActor in
            await ResourceStore.shutdownAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct Web_StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { StudioWindowRoot().preferredColorScheme(forcedColorScheme) }
            .defaultSize(width: minimumWindow ? 900 : 1400, height: minimumWindow ? 560 : 860)
            .windowToolbarStyle(.unifiedCompact)
            .commands { StudioCommands() }
    }

    private var forcedColorScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--appearance-dark") { return .dark }
        if args.contains("--appearance-light") { return .light }
        return nil
    }
    private var minimumWindow: Bool { ProcessInfo.processInfo.arguments.contains("--minimum-window") }
}

private struct StudioCommands: Commands {
    @FocusedValue(\.studioModel) private var model
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button { model?.newTab() } label: { Label("New Web Page", systemImage: studioResourceSymbol(.web)) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model == nil)
            Button { model?.newTerminal(directoryURL: nil) } label: { Label("New Terminal", systemImage: studioResourceSymbol(.localTerminal)) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(model == nil)
            Button { model?.newTerminalInFolder() } label: { Label("New Terminal in Folder…", systemImage: studioResourceSymbol(.localTerminal)) }
                .disabled(model == nil)
            Button("Close Tab") {
                guard let model else { return }
                if model.panels.panel != nil {
                    model.dismissPanel()
                } else {
                    model.closeSelectedTab()
                }
            }.keyboardShortcut("w", modifiers: .command).disabled(model == nil)
            Button("Open Destination…") { model?.openDestination() }.keyboardShortcut(
                "l", modifiers: .command
            ).disabled(model == nil)
            Button("Command Palette…") {
                guard let model else { return }
                model.openCommands()
            }.keyboardShortcut("k", modifiers: .command).disabled(model == nil)
            Divider()
            Button("Show Next Tab") { model?.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((model?.visibleTabs.count ?? 0) < 2)
            Button("Show Previous Tab") { model?.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((model?.visibleTabs.count ?? 0) < 2)
            // ⌘1–⌘8 pick a position and ⌘9 picks the last tab, as Safari does. They live in
            // a submenu so nine shortcuts stay discoverable without flooding the menu.
            Menu("Select Tab") {
                ForEach(1 ... 9, id: \.self) { position in
                    Button("Tab \(position)") { model?.selectTab(at: position - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(position)")),
                            modifiers: .command
                        )
                }
            }.disabled(model == nil)
        }
        CommandMenu("Page") {
            Button("Back") { model?.webGoBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(model?.activeWebState.canGoBack ?? false))
            Button("Forward") { model?.webGoForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(model?.activeWebState.canGoForward ?? false))
            Divider()
            Button(model?.activeWebState.isLoading == true ? "Stop Loading" : "Reload Page") {
                model?.webReloadOrStop()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(model?.selectedTabIsWeb ?? false))
        }
        CommandMenu("Layout") {
            Button("Split") { model?.split() }.keyboardShortcut("\\", modifiers: [.command, .option]).disabled(model?.layout.isSplit ?? true)
            Button("Focus Other Pane") { model?.focusOtherPaneAndContent() }.keyboardShortcut("o", modifiers: [.command, .option]).disabled(!(model?.layout.isSplit ?? false))
            Button("Close Focused Pane") { if let model { model.closePane(model.focusedPane.id) } }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(!(model?.layout.isSplit ?? false))
            Button("Single Pane") { model?.returnToSinglePane() }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Swap Panes") { model?.swapPanes() }.keyboardShortcut("s", modifiers: [.command, .option, .shift]).disabled(!(model?.layout.isSplit ?? false))
            Divider()
            Button("Narrow Left") { model?.setSplitRatio((model?.layout.splitRatio ?? 0.5) - 0.05) }.keyboardShortcut("[", modifiers: [.command, .option])
            Button("Widen Left") { model?.setSplitRatio((model?.layout.splitRatio ?? 0.5) + 0.05) }.keyboardShortcut("]", modifiers: [.command, .option])
            Button("Reset Ratio") { model?.setSplitRatio(0.5) }.keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { model?.tabStripVisible.toggle() }.keyboardShortcut(
                "s", modifiers: [.command, .option]
            ).disabled(model == nil)
            Button("Toggle Agents") {
                model?.agentsVisible.toggle()
            }
            .keyboardShortcut(
                "a",
                modifiers: [.command, .option]
            ).disabled(model == nil)
        }
    }
}
