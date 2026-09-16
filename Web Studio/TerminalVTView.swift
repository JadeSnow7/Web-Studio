#if WEB_STUDIO_VT
import AppKit
import Accessibility
import CoreGraphics
import CoreText
import Metal
import MetalKit
import QuartzCore
import StudioVTCoreC

@MainActor
final class TerminalVTView: MTKView, NSTextInputClient, MTKViewDelegate {
    weak var session: TerminalSession?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var renderer: TerminalMetalRenderer?
    private(set) var rendererError: String?
    private var terminalFrame: VTFrame?
    var geometry = TerminalGeometry(backingScale: 1)
    private var theme = TerminalTheme.dark
    private var marked = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private let markedField = NSTextField(labelWithString: "")
    private let scroller = NSScroller()
    var isScrollbackEnabled: Bool { scroller.isEnabled }
    private var occluded = false
    private var dragStart: (Int, Int)?
    private var scrollRemainder: CGFloat = 0
    private var windowObservers: [NSObjectProtocol] = []
    private var trackedMouse = false
    private var trackingArea: NSTrackingArea?
    private var mouseButton: Int?
    private var mouseShiftRoute = false
    private var retryScheduled = false
    private var retryBudget = 3
    private var displayCallbackCount = 0
    private var commandInFlight = 0
    private var redrawWhenAvailable = false
    private var lastAccessibilityGeneration: UInt64?
    private var lastAccessibilityFingerprint: String?
    private var lastAccessibilitySelection: NSRange?
    private var pendingNativeEvent: NSEvent?
    private var forwardedKeys: [UInt16: NSEvent] = [:]
    private var modifierFlags = NSEvent.ModifierFlags()
    private var accessibilityObserver: NSObjectProtocol?
    private var accessibilitySettingsObserver: NSObjectProtocol?
    private var cursorTimer: Timer?
    private var cursorTimerGeneration: UInt64 = 0
    private var cursorPhaseVisible = true
    private var increaseContrast = false
    private var reduceMotion = false
    private var prefersNonBlinkingTextInsertionIndicator = false

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(session: TerminalSession? = nil) {
        self.session = session
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        autoResizeDrawable = false
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        do { renderer = try TerminalMetalRenderer(device: metalLayer.device) }
        catch { rendererError = "Terminal renderer unavailable: \(error)" }
        markedField.isBezeled = false; markedField.isEditable = false; markedField.isSelectable = false; markedField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        markedField.drawsBackground = true; markedField.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.28)
        markedField.textColor = .labelColor; markedField.isHidden = true; addSubview(markedField)
        setAccessibilityElement(true); setAccessibilityRole(.textArea); setAccessibilityLabel("Terminal")
        scroller.target = self; scroller.action = #selector(scrollbarChanged(_:)); scroller.knobStyle = .default; addSubview(scroller)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateAccessibilityDisplayOptions() } }
        accessibilitySettingsObserver = NotificationCenter.default.addObserver(
            forName: AccessibilitySettings.prefersNonBlinkingTextInsertionIndicatorDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateAccessibilityDisplayOptions() } }
        updateAccessibilityDisplayOptions()
        updateAppearance()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frame: VTFrame) {
        let oldCursor = terminalFrame?.cursor
        let resetCursorBlink = terminalFrame?.generation != frame.generation || oldCursor?.x != frame.cursor.x || oldCursor?.y != frame.cursor.y || oldCursor?.visible != frame.cursor.visible || oldCursor?.blinking != frame.cursor.blinking || oldCursor?.visualStyle != frame.cursor.visualStyle
        self.terminalFrame = frame
        retryBudget = 3
        let axModel = accessibilityModel()
        let bar = frame.scrollbar
        let axFingerprint = "\(frame.generation)|\(frame.columns)x\(frame.rows)|\(bar.offset):\(bar.length):\(bar.total)|\(axModel.text.utf16.count)|\(axModel.selection.location):\(axModel.selection.length)"
        if lastAccessibilityFingerprint != axFingerprint {
            lastAccessibilityFingerprint = axFingerprint
            lastAccessibilityGeneration = frame.generation
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        if lastAccessibilitySelection != axModel.selection { lastAccessibilitySelection = axModel.selection; NSAccessibility.post(element: self, notification: .selectedTextChanged) }
        if resetCursorBlink { stopCursorBlinkTimer() }
        updateCursorBlinkTimer()
        let hasHistory = bar.total > bar.length
        scroller.isEnabled = hasHistory
        scroller.isHidden = !hasHistory
        if hasHistory {
            scroller.knobProportion = min(1, max(0.05, Double(bar.length) / Double(bar.total)))
            scroller.doubleValue = min(1, max(0, Double(bar.offset) / Double(bar.total - bar.length)))
        } else { scroller.doubleValue = 0; scroller.knobProportion = 1 }
        needsDisplay = true
    }
    func updateTheme(_ theme: TerminalTheme) {
        self.theme = theme
        _ = session?.setTheme(theme)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; windowObservers.removeAll()
        if let trackingArea { removeTrackingArea(trackingArea); self.trackingArea = nil }
        if let window {
            let nc = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeBackingPropertiesNotification] {
                windowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshWindowState() } })
            }
            trackedMouse = true; trackingArea = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self); addTrackingArea(trackingArea!)
        }
        updateAppearance()
        refreshWindowState()
    }
    deinit { windowObservers.forEach { NotificationCenter.default.removeObserver($0) }; if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }; if let accessibilitySettingsObserver { NotificationCenter.default.removeObserver(accessibilitySettingsObserver) }; cursorTimer?.invalidate() }
    private var backendVisible: Bool { window != nil && !occluded && !isHiddenOrHasHiddenAncestor }
    private var windowFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    private var shouldBlinkCursor: Bool {
        TerminalCursorBlinkPolicy.isEligible(
            backendVisible: backendVisible, windowFocused: windowFocused,
            cursorVisible: (terminalFrame?.cursor.viewportHasValue == true) && (terminalFrame?.cursor.visible == true),
            cursorBlinking: terminalFrame?.cursor.blinking ?? false,
            sessionRunning: session?.state == .running, reducedMotion: reduceMotion,
            prefersNonBlinkingTextInsertionIndicator: prefersNonBlinkingTextInsertionIndicator)
    }
    private func refreshWindowState() { occluded = !(window?.occlusionState.contains(.visible) ?? false); let focused = windowFocused; if !focused { for event in forwardedKeys.values { _ = session?.encode(event: event, action: GHOSTTY_KEY_ACTION_RELEASE, forceText: true) }; forwardedKeys.removeAll(); modifierFlags = [] }; session?.setVisible(backendVisible); session?.focus(focused); updateCursorBlinkTimer(); needsLayout = true; if backendVisible { needsDisplay = true } }
    override func viewDidHide() { super.viewDidHide(); refreshWindowState() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshWindowState() }
    override func viewDidChangeEffectiveAppearance() { updateAppearance() }
    private func updateAccessibilityDisplayOptions() {
        let workspace = NSWorkspace.shared
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        prefersNonBlinkingTextInsertionIndicator = AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator
        updateAppearance()
        updateCursorBlinkTimer()
        needsDisplay = true
    }
    private func updateAppearance() {
        let best = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let baseTheme = best == .darkAqua ? TerminalTheme.dark : TerminalTheme.light
        let nextTheme = increaseContrast ? baseTheme.increasedContrast() : baseTheme
        updateTheme(nextTheme)
        metalLayer.backgroundColor = NSColor(
            calibratedRed: CGFloat(nextTheme.background.red) / 255,
            green: CGFloat(nextTheme.background.green) / 255,
            blue: CGFloat(nextTheme.background.blue) / 255,
            alpha: 1
        ).cgColor
    }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        geometry = TerminalGeometry(backingScale: scale)
        drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        updateMarkedFieldFrame()
        scroller.frame = NSRect(x: max(0, bounds.maxX - 14), y: 0, width: 14, height: bounds.height)
        let grid = geometry.gridSize(for: bounds.size)
        session?.resize(columns: grid.cols, rows: grid.rows, geometry: geometry)
        needsDisplay = true
    }
    func draw(in view: MTKView) { renderMetalFrame() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }
    private func renderMetalFrame() {
        displayCallbackCount += 1
        if let window { occluded = !window.occlusionState.contains(.visible) }
        guard backendVisible, let frame = terminalFrame, let renderer else {
            displayDebug("callback=\(displayCallbackCount) occluded=\(occluded) frame=\(terminalFrame != nil) drawable=false")
            return
        }
        guard let drawable = currentDrawable else {
            displayDebug("callback=\(displayCallbackCount) occluded=false frame=true drawable=false")
            return
        }
        guard let command = renderer.render(frame: frame, geometry: geometry, theme: theme,
                                            target: drawable.texture, drawable: drawable, cursorPhaseVisible: cursorPhaseVisible,
                                            completion: { [weak self] completed in
                                                Task { @MainActor in
                                                    guard let self else { return }
                                                    self.commandInFlight = max(0, self.commandInFlight - 1)
                                                    let error = completed.error.map { String(describing: $0) } ?? "none"
                                                    self.displayDebug("command-completed status=\(completed.status.rawValue) error=\(error)")
                                                    if self.redrawWhenAvailable {
                                                        self.redrawWhenAvailable = false
                                                        self.needsDisplay = true
                                                    }
                                                }
                                            })
        else {
            if let error = renderer.lastError { session?.reportRenderError(String(describing: error)) }
            if renderer.lastError == nil, commandInFlight > 0 {
                redrawWhenAvailable = true
            } else if !occluded, renderer.lastError == nil, retryBudget > 0, !retryScheduled {
                retryBudget -= 1
                retryScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.retryScheduled = false
                    self.needsDisplay = true
                }
            }
            displayDebug("callback=\(displayCallbackCount) occluded=false frame=true drawable=true render=nil busy=\(commandInFlight)")
            return
        }
        commandInFlight += 1
        displayDebug("callback=\(displayCallbackCount) occluded=false frame=true drawable=true")
        displayDebug("render-command-created status=\(command.status.rawValue)")
    }
    private func updateCursorBlinkTimer() {
        guard shouldBlinkCursor else { stopCursorBlinkTimer(); return }
        guard cursorTimer == nil else { return }
        cursorTimerGeneration &+= 1
        let generation = cursorTimerGeneration
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.cursorTimerGeneration == generation, self.cursorTimer != nil else { return }
                guard self.shouldBlinkCursor else { self.stopCursorBlinkTimer(); return }
                self.cursorPhaseVisible.toggle()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(cursorTimer!, forMode: .common)
    }
    private func stopCursorBlinkTimer() {
        cursorTimerGeneration &+= 1
        cursorTimer?.invalidate()
        cursorTimer = nil
        if !cursorPhaseVisible {
            cursorPhaseVisible = true
            if backendVisible { needsDisplay = true }
        }
    }
    private func displayDebug(_ line: String) {
#if DEBUG
        let url = URL(fileURLWithPath: "/private/tmp/web-studio-vt-display-debug.log")
        if displayCallbackCount > 100 { return }
        if let data = (line + "\n").data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? (line + "\n").write(to: url, atomically: true, encoding: .utf8) }
#endif
    }
    override func becomeFirstResponder() -> Bool { modifierFlags = NSApp.currentEvent?.modifierFlags ?? []; session?.focus(true); Task { @MainActor [weak self] in self?.updateCursorBlinkTimer() }; return true }
    override func resignFirstResponder() -> Bool { for event in forwardedKeys.values { _ = session?.encode(event: event, action: GHOSTTY_KEY_ACTION_RELEASE, forceText: true) }; forwardedKeys.removeAll(); modifierFlags = []; session?.focus(false); stopCursorBlinkTimer(); return true }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { pendingNativeEvent = event; interpretKeyEvents([event]); pendingNativeEvent = nil; return }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v" { confirmPaste(); return }
            if event.charactersIgnoringModifiers == "c" { copySelection(); return }
            if event.charactersIgnoringModifiers == "a" { session?.selectAll(); return }
            return
        }
        if session?.encode(event: event, action: event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS) == true {
            forwardedKeys[event.keyCode] = event
            session?.scrollToBottom()
            return
        }
        pendingNativeEvent = event
        interpretKeyEvents([event])
        pendingNativeEvent = nil
    }
    override func keyUp(with event: NSEvent) {
        guard forwardedKeys.removeValue(forKey: event.keyCode) != nil else { return }
        session?.encodeKeyUp(event: event)
    }
    override func flagsChanged(with event: NSEvent) {
        let mask: NSEvent.ModifierFlags = { switch event.keyCode { case 54,55: return .command; case 56,60: return .shift; case 58,61: return .option; case 59,62: return .control; case 57: return .capsLock; default: return [] } }()
        if !mask.isEmpty {
            let aggregateDown = event.modifierFlags.contains(mask)
            let wasForwarded = forwardedKeys[event.keyCode] != nil
            // AppKit reports aggregate modifier state, so a side-specific
            // transition must use its physical key code while both sides are
            // held. Aggregate absence still identifies the final release.
            let sideSpecific = [54, 55, 56, 60, 58, 61, 59, 62].contains(event.keyCode)
            let isDown = wasForwarded ? false : aggregateDown
            let shouldRelease = wasForwarded && (!aggregateDown || sideSpecific)
            let shouldPress = !wasForwarded && isDown
            if shouldRelease { _ = session?.encode(event: event, action: GHOSTTY_KEY_ACTION_RELEASE, forceText: true); forwardedKeys.removeValue(forKey: event.keyCode) }
            else if shouldPress { _ = session?.encode(event: event, action: GHOSTTY_KEY_ACTION_PRESS, forceText: true); forwardedKeys[event.keyCode] = event }
            modifierFlags = event.modifierFlags
        }
        session?.focus(window?.isKeyWindow == true && window?.firstResponder === self)
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !value.isEmpty else { return }
        let native = pendingNativeEvent
        let wasMarked = hasMarkedText()
        marked = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0); markedField.isHidden = true
        if let native, !wasMarked, value.utf16.count == 1, session?.encode(event: native, action: native.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS, textOverride: value, forceText: true) == true { forwardedKeys[native.keyCode] = native; session?.scrollToBottom() }
        else { session?.sendRaw(Data(value.utf8)) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        if let attributed = string as? NSAttributedString {
            let normalized = NSMutableAttributedString(attributedString: attributed)
            let fullRange = NSRange(location: 0, length: normalized.length)
            if fullRange.length > 0 { normalized.addAttribute(.font, value: font, range: fullRange) }
            marked = normalized
        } else {
            marked = NSAttributedString(string: (string as? String) ?? "", attributes: [.font: font])
        }
        let length = marked.length; let location = max(0, min(selectedRange.location, length)); let available = max(0, length - location)
        markedSelection = NSRange(location: location, length: min(max(0, selectedRange.length), available)); markedField.attributedStringValue = marked; markedField.isHidden = marked.length == 0; updateMarkedFieldFrame()
    }
    func unmarkText() { marked = NSAttributedString(); markedSelection = NSRange(location: 0, length: 0); markedField.isHidden = true }
    func selectedRange() -> NSRange { marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : markedSelection }
    func markedRange() -> NSRange { marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { guard range.location >= 0, range.length >= 0, range.location <= marked.length, range.length <= marked.length - range.location else { actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil }; actualRange?.pointee = range; return range.length == 0 ? nil : marked.attributedSubstring(from: range) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.font, .foregroundColor, .backgroundColor] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let length = marked.length
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else { actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return .zero }
        let safe = range; actualRange?.pointee = safe
        let origin = geometry.origin(for: terminalFrame?.cursor.x ?? 0, row: terminalFrame?.cursor.y ?? 0)
        let prefix = marked.attributedSubstring(from: NSRange(location: 0, length: safe.location))
        let advance = (prefix.string as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        let local = NSRect(x: origin.x + advance, y: bounds.height - origin.y - geometry.cellSize.height,
                           width: max(1, geometry.cellSize.width), height: geometry.cellSize.height)
        return window?.convertToScreen(convert(local, to: nil)) ?? convert(local, to: nil)
    }
    @objc private func scrollbarChanged(_ sender: NSScroller) {
        guard let bar = terminalFrame?.scrollbar, bar.total > bar.length else { return }
        switch sender.hitPart {
        case .decrementLine: session?.scroll(rows: -1)
        case .incrementLine: session?.scroll(rows: 1)
        case .decrementPage: session?.scroll(rows: -Int(bar.length))
        case .incrementPage: session?.scroll(rows: Int(bar.length))
        case .knob, .knobSlot: session?.scroll(toOffset: UInt64(sender.doubleValue * Double(bar.total - bar.length)))
        default: break
        }
    }
    private func confirmPaste() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Paste into terminal?"; alert.informativeText = "The clipboard contents will be sent to the active shell."; alert.addButton(withTitle: "Paste"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, session?.paste(value, allowUnsafe: true) == false {
            let failure = NSAlert(); failure.messageText = "Terminal input queue is full or session has ended"; failure.informativeText = "The paste was not sent to the terminal."; failure.addButton(withTitle: "OK"); failure.runModal()
        }
    }
    private func copySelection() { guard let text = session?.selectedText(), !text.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func cell(at point: NSPoint) -> (Int, Int) { let c = geometry.cell(at: NSPoint(x: point.x, y: bounds.height - point.y)); let cols = max(1, terminalFrame?.columns ?? geometry.gridSize(for: bounds.size).cols); let rows = max(1, terminalFrame?.rows ?? geometry.gridSize(for: bounds.size).rows); return (min(cols - 1, max(0, c.column)), min(rows - 1, max(0, c.row))) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil); let (c, r) = cell(at: p); mouseShiftRoute = event.modifierFlags.contains(.shift)
        if session?.mouseReporting() == true && !mouseShiftRoute { mouseButton = terminalButton(event.buttonNumber); sendTerminalMouse(action: 0, button: mouseButton!, event: event, point: p); return }
        let count = event.clickCount; dragStart = (c, r); _ = session?.selectionBegin(column: c, row: r, clickCount: count)
    }
    override func mouseDragged(with event: NSEvent) { let p = convert(event.locationInWindow, from: nil); if mouseButton != nil && !mouseShiftRoute { sendTerminalMouse(action: 2, button: mouseButton!, event: event, point: p); return }; guard dragStart != nil else { return }; let (c,r) = cell(at: p); _ = session?.selectionUpdate(column: c, row: r) }
    override func mouseUp(with event: NSEvent) { if let button = mouseButton { let p = convert(event.locationInWindow, from: nil); sendTerminalMouse(action: 1, button: button, event: event, point: p); mouseButton = nil } else if dragStart != nil { _ = session?.selectionEnd() }; dragStart = nil; NSAccessibility.post(element: self, notification: .selectedTextChanged) }
    override func mouseMoved(with event: NSEvent) { guard session?.mouseReporting() == true, !event.modifierFlags.contains(.shift) else { return }; let p = convert(event.locationInWindow, from: nil); sendTerminalMouse(action: 2, button: 0, event: event, point: p) }
    override func scrollWheel(with event: NSEvent) {
        if session?.mouseReporting() == true && !event.modifierFlags.contains(.shift) { guard event.scrollingDeltaY != 0 else { return }; let button = event.scrollingDeltaY > 0 ? 4 : 5; sendTerminalMouse(action: 0, button: button, event: event, point: convert(event.locationInWindow, from: nil)); return }
        if event.hasPreciseScrollingDeltas { scrollRemainder += event.scrollingDeltaY / max(1, geometry.cellSize.height) }
        else { scrollRemainder += event.scrollingDeltaY }
        let rows = Int(scrollRemainder.rounded(.towardZero)); if rows != 0 { scrollRemainder -= CGFloat(rows); session?.scroll(rows: -rows) }
    }
    private func mouseModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= 1 << 0 }
        if flags.contains(.control) { value |= 1 << 1 }
        if flags.contains(.option) { value |= 1 << 2 }
        if flags.contains(.command) { value |= 1 << 3 }
        return value
    }
    private func mouseGeometry() -> VTMouseGeometry { VTMouseGeometry(screenWidth: Int(bounds.width * geometry.backingScale), screenHeight: Int(bounds.height * geometry.backingScale), cellWidth: Int(geometry.cellPixelSize.width), cellHeight: Int(geometry.cellPixelSize.height), paddingTop: Int(geometry.origin(for: 0, row: 0).y * geometry.backingScale), paddingLeft: Int(geometry.origin(for: 0, row: 0).x * geometry.backingScale)) }
    private func sendTerminalMouse(action: Int, button: Int, event: NSEvent, point: NSPoint) { session?.sendMouse(action: action, button: button, modifiers: mouseModifiers(event.modifierFlags), point: CGPoint(x: point.x * geometry.backingScale, y: (bounds.height - point.y) * geometry.backingScale), geometry: mouseGeometry()) }
    private func terminalButton(_ value: Int) -> Int { value == 0 ? 1 : value == 1 ? 2 : value == 2 ? 3 : value }
    private func beginAdditionalMouse(_ event: NSEvent, button: Int) { let p = convert(event.locationInWindow, from: nil); let (c, r) = cell(at: p); mouseShiftRoute = event.modifierFlags.contains(.shift); if session?.mouseReporting() == true && !mouseShiftRoute { mouseButton = button; sendTerminalMouse(action: 0, button: button, event: event, point: p) } else { mouseButton = nil; dragStart = (c, r); _ = session?.selectionBegin(column: c, row: r, clickCount: event.clickCount) } }
    private func dragAdditionalMouse(_ event: NSEvent, button: Int) { let p = convert(event.locationInWindow, from: nil); if mouseButton != nil && !mouseShiftRoute { sendTerminalMouse(action: 2, button: button, event: event, point: p); return }; guard dragStart != nil else { return }; let (c, r) = cell(at: p); _ = session?.selectionUpdate(column: c, row: r) }
    private func endAdditionalMouse(_ event: NSEvent, button: Int) { let p = convert(event.locationInWindow, from: nil); if mouseButton != nil { sendTerminalMouse(action: 1, button: button, event: event, point: p) } else if dragStart != nil { _ = session?.selectionEnd() }; mouseButton = nil; dragStart = nil; mouseShiftRoute = false; NSAccessibility.post(element: self, notification: .selectedTextChanged) }
    override func rightMouseDown(with event: NSEvent) { beginAdditionalMouse(event, button: 2) }
    override func rightMouseDragged(with event: NSEvent) { dragAdditionalMouse(event, button: 2) }
    override func rightMouseUp(with event: NSEvent) { endAdditionalMouse(event, button: 2) }
    override func otherMouseDown(with event: NSEvent) { beginAdditionalMouse(event, button: terminalButton(event.buttonNumber)) }
    override func otherMouseDragged(with event: NSEvent) { dragAdditionalMouse(event, button: mouseButton ?? terminalButton(event.buttonNumber)) }
    override func otherMouseUp(with event: NSEvent) { endAdditionalMouse(event, button: mouseButton ?? terminalButton(event.buttonNumber)) }
    private func localPoint(fromScreen point: NSPoint) -> NSPoint {
        guard let window else { return point }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }
    func characterIndex(for point: NSPoint) -> Int {
        let point = localPoint(fromScreen: point)
        guard marked.length > 0 else { return NSNotFound }
        let origin = geometry.origin(for: terminalFrame?.cursor.x ?? 0, row: terminalFrame?.cursor.y ?? 0)
        let markedWidth = max(geometry.cellSize.width, marked.size().width)
        let markedFrame = NSRect(x: origin.x, y: bounds.height - origin.y - geometry.cellSize.height, width: markedWidth, height: geometry.cellSize.height)
        guard markedFrame.contains(point) else { return NSNotFound }
        let line = CTLineCreateWithAttributedString(marked)
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: point.x - markedFrame.minX, y: 0))
        guard index != kCFNotFound else { return NSNotFound }
        return min(marked.length - 1, max(0, index))
    }
    private func updateMarkedFieldFrame() { guard marked.length > 0 else { return }; let origin = geometry.origin(for: terminalFrame?.cursor.x ?? 0, row: terminalFrame?.cursor.y ?? 0); markedField.sizeToFit(); markedField.frame = NSRect(x: origin.x, y: bounds.height - origin.y - geometry.cellSize.height, width: max(geometry.cellSize.width, markedField.frame.width), height: geometry.cellSize.height) }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    private struct AXCell { let range: NSRange; let row: Int; let frame: NSRect }
    private struct AXTextModel { let text: String; let cells: [AXCell]; let selection: NSRange; let visible: NSRange }
    private func accessibilityModel() -> AXTextModel {
        guard let frame = terminalFrame else { let text = session?.renderedText() ?? ""; return AXTextModel(text: text, cells: [], selection: NSRange(location: NSNotFound, length: 0), visible: NSRange(location: 0, length: text.utf16.count)) }
        var text = "", cells: [AXCell] = [], selectedStart: Int?, selectedEnd: Int?, utf16Offset = 0
        text.reserveCapacity(frame.rows * (frame.columns + 1))
        for row in 0..<frame.rows {
            for column in 0..<frame.columns {
                let cell = frame.cells[row * frame.columns + column]
                if cell.wide.rawValue == 2 || cell.wide.rawValue == 3 { continue }
                let value = cell.text.isEmpty ? " " : cell.text; let start = utf16Offset; let length = value.utf16.count; text += value; utf16Offset += length
                let width = cell.wide.rawValue == 1 ? geometry.cellSize.width * 2 : geometry.cellSize.width
                let origin = geometry.origin(for: column, row: row)
                let localFrame = NSRect(x: origin.x, y: bounds.height - origin.y - geometry.cellSize.height, width: width, height: geometry.cellSize.height)
                cells.append(AXCell(range: NSRange(location: start, length: length), row: row, frame: localFrame))
                if cell.selected { selectedStart = min(selectedStart ?? start, start); selectedEnd = utf16Offset }
            }
            if row + 1 < frame.rows { text += "\n"; utf16Offset += 1 }
        }
        let selection = selectedStart.flatMap { s in selectedEnd.map { NSRange(location: s, length: max(0, $0 - s)) } } ?? NSRange(location: NSNotFound, length: 0)
        return AXTextModel(text: text, cells: cells, selection: selection, visible: NSRange(location: 0, length: text.utf16.count))
    }
    override func accessibilityValue() -> Any? { accessibilityModel().text }
    override func accessibilityNumberOfCharacters() -> Int { accessibilityModel().text.utf16.count }
    override func accessibilitySelectedText() -> String? { let m = accessibilityModel(); guard m.selection.location != NSNotFound else { return "" }; return (m.text as NSString).substring(with: m.selection) }
    override func accessibilitySelectedTextRange() -> NSRange { accessibilityModel().selection }
    override func accessibilitySelectedTextRanges() -> [NSValue]? { let range = accessibilityModel().selection; return range.location == NSNotFound ? [] : [NSValue(range: range)] }
    override func accessibilityVisibleCharacterRange() -> NSRange { accessibilityModel().visible }
    override func accessibilityString(for range: NSRange) -> String? { let m = accessibilityModel(); guard range.location >= 0, range.length >= 0, range.location <= m.text.utf16.count, range.length <= m.text.utf16.count - range.location else { return nil }; return (m.text as NSString).substring(with: range) }
    override func accessibilityRange(forLine line: Int) -> NSRange { let m = accessibilityModel(); guard line >= 0, let first = m.cells.first(where: { $0.row == line }) else { return NSRange(location: NSNotFound, length: 0) }; let end = m.cells.last(where: { $0.row == line })?.range; return NSRange(location: first.range.location, length: end.map { NSMaxRange($0) - first.range.location } ?? 0) }
    override func accessibilityLine(for index: Int) -> Int { let m = accessibilityModel(); guard index >= 0, index < m.text.utf16.count else { return NSNotFound }; return m.cells.last(where: { $0.range.location <= index })?.row ?? NSNotFound }
    override func accessibilityRange(for index: Int) -> NSRange { let m = accessibilityModel(); guard index >= 0, index < m.text.utf16.count else { return NSRange(location: NSNotFound, length: 0) }; if (m.text as NSString).character(at: index) == 10 { return NSRange(location: index, length: 1) }; return m.cells.first(where: { NSLocationInRange(index, $0.range) })?.range ?? NSRange(location: NSNotFound, length: 0) }
    override func accessibilityFrame(for range: NSRange) -> NSRect { let m = accessibilityModel(); guard range.location >= 0, range.length >= 0, range.location <= m.text.utf16.count, range.length <= m.text.utf16.count - range.location else { return .zero }; if range.length == 0 { let next = m.cells.first(where: { $0.range.location >= range.location }); let prev = m.cells.last(where: { NSMaxRange($0.range) <= range.location }); let x = next?.frame.minX ?? prev.map { $0.frame.maxX } ?? 0; let caret = NSRect(x: x, y: next?.frame.minY ?? prev?.frame.minY ?? 0, width: 1, height: next?.frame.height ?? prev?.frame.height ?? geometry.cellSize.height); return window?.convertToScreen(convert(caret, to: nil)) ?? caret }; let hits = m.cells.filter { NSIntersectionRange($0.range, range).length > 0 }; guard let first = hits.first else { return .zero }; let union = hits.dropFirst().reduce(first.frame) { $0.union($1.frame) }; return window?.convertToScreen(convert(union, to: nil)) ?? union }
    override func accessibilityRange(for point: NSPoint) -> NSRange { let point = localPoint(fromScreen: point); let m = accessibilityModel(); guard let cell = m.cells.first(where: { $0.frame.contains(point) }) else { return NSRange(location: NSNotFound, length: 0) }; return cell.range }
}
#endif
