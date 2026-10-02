import AppKit
import Foundation
import GhosttyKit

func probeWake(_ userdata: UnsafeMutableRawPointer?) {}
func probeAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool { false }
func probeRead(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool { false }
func probeConfirm(_ userdata: UnsafeMutableRawPointer?, _ string: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {}
func probeWrite(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool) {}
func probeClose(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}

// Headless AppKit probe for the pinned GhosttyKit archive. It creates an
// off-screen NSView and asks the real Ghostty surface for its resolved font
// grid. No window is ordered, activated, or otherwise shown.
@main
struct TerminalPerformanceProbe {
  static func main() {
    let args = CommandLine.arguments
    if args.contains("--self-test") {
      guard positiveOption(["probe"], "--scale", default: 2, maximum: 8) == 2,
            positiveOption(["probe", "--scale", "8"], "--scale", default: 2, maximum: 8) == 8,
            positiveOption(["probe", "--width", "0"], "--width", default: 900, maximum: 16384) == nil,
            positiveOption(["probe", "--height", "nan"], "--height", default: 600, maximum: 16384) == nil else {
        fputs("probe self-test failed\n", stderr); exit(1)
      }
      print("terminal-performance-probe self-test passed")
      return
    }
    guard let configIndex = args.firstIndex(of: "--config"), configIndex + 1 < args.count else {
      fputs("usage: terminal-performance-probe --config PATH [--scale N] [--width N --height N]\n", stderr)
      exit(64)
    }
    let configPath = args[configIndex + 1]
    guard let scale = positiveOption(args, "--scale", default: 2, maximum: 8),
          let width = positiveOption(args, "--width", default: 900, maximum: 16384),
          let height = positiveOption(args, "--height", default: 600, maximum: 16384) else {
      fputs("scale, width, and height must be finite positive numbers within the supported bounds\n", stderr)
      exit(64)
    }
    let resources = option(args, "--resources") ?? URL(fileURLWithPath: configPath).deletingLastPathComponent().path
    setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      fputs("ghostty_init failed\n", stderr); exit(1)
    }
    let config = ghostty_config_new()
    ghostty_config_load_file(config, configPath)
    ghostty_config_finalize(config)
    var diagnostics: [String] = []
    for index in 0..<ghostty_config_diagnostics_count(config) {
      let diagnostic = ghostty_config_get_diagnostic(config, index)
      if let message = diagnostic.message { diagnostics.append(String(cString: message)) }
    }
    var runtime = ghostty_runtime_config_s(
      userdata: nil, supports_selection_clipboard: false,
      wakeup_cb: probeWake, action_cb: probeAction, read_clipboard_cb: probeRead,
      confirm_read_clipboard_cb: probeConfirm, write_clipboard_cb: probeWrite,
      close_surface_cb: probeClose)
    guard let app = ghostty_app_new(&runtime, config) else {
      fputs("ghostty_app_new failed\n", stderr); exit(1)
    }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    view.wantsLayer = true
    view.layerContentsRedrawPolicy = .duringViewResize
    let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: true)
    window.contentView = view
    window.orderOut(nil)
    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
    surfaceConfig.scale_factor = scale
    surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB
    let cwd = "/tmp"
    let command = "/bin/sh"
    let surface = cwd.withCString { cwdPtr in
      command.withCString { commandPtr in
        surfaceConfig.working_directory = cwdPtr
        surfaceConfig.command = commandPtr
        return ghostty_surface_new(app, &surfaceConfig)
      }
    }
    guard let surface else {
      fputs("ghostty_surface_new failed\n", stderr)
      ghostty_app_free(app); ghostty_config_free(config); exit(1)
    }
    ghostty_surface_set_size(surface, UInt32(width * scale), UInt32(height * scale))
    let size = ghostty_surface_size(surface)
    var resolvedFont: [String: Any] = ["status": "unavailable"]
    if let pointer = ghostty_surface_quicklook_font(surface) {
      let ctFont = unsafeBitCast(pointer, to: CTFont.self)
      resolvedFont = [
        "status": "observed",
        "postscript_name": CTFontCopyPostScriptName(ctFont) as String,
        "family_name": CTFontCopyFamilyName(ctFont) as String,
        "point_size": CTFontGetSize(ctFont),
      ]
    }
    let output: [String: Any] = [
      "schema": "web-studio.terminal-performance-probe.v1",
      "config": configPath,
      "resources": resources,
      "config_diagnostics": diagnostics,
      "resolved_font": resolvedFont,
      "scale": scale,
      "requested_points": ["width": width, "height": height],
      "surface": ["columns": size.columns, "rows": size.rows,
                   "width_px": size.width_px, "height_px": size.height_px,
                   "cell_width_px": size.cell_width_px,
                   "cell_height_px": size.cell_height_px],
      "target_vt_2x": ["cell_width_px": 17, "cell_height_px": 35,
                       "content_width_px": 1800, "content_height_px": 1120],
      "limitations": ["headless NSView; no on-screen window or screenshot",
                      "surface metrics are Ghostty resolved values, not proof of raster glyph appearance"]
    ]
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    ghostty_surface_request_close(surface)
    ghostty_surface_free(surface)
    ghostty_app_free(app)
    ghostty_config_free(config)
  }

  static func option(_ args: [String], _ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func positiveOption(_ args: [String], _ name: String, default fallback: Double, maximum: Double) -> Double? {
    guard let raw = option(args, name) else { return fallback }
    guard let value = Double(raw), value.isFinite, value > 0, value <= maximum else { return nil }
    return value
  }
}
