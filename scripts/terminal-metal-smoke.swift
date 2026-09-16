import AppKit
import CoreText
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

@main struct Smoke {
  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw NSError(
        domain: "TerminalMetalSmoke", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Metal device or target unavailable"])
    }
    let core = TerminalVTCore(columns: 20, rows: 4)
    core.feed(Data("GPU 中文 é 👩‍💻 \u{1b}[4:1mS\u{1b}[4:2mD\u{1b}[4:3mC\u{1b}[4:4mP\u{1b}[4:5mH\u{1b}[9mX\u{1b}[53mO\u{1b}[0m \u{1b}[31mANSI\u{1b}[0m".utf8))
    let renderer = try TerminalMetalRenderer(device: device)
    let darkContrast = TerminalTheme.dark.increasedContrast()
    let lightContrast = TerminalTheme.light.increasedContrast()
    guard darkContrast.background == TerminalTheme.dark.background,
      darkContrast.selection == TerminalTheme.dark.selection,
      darkContrast.ansi == TerminalTheme.dark.ansi,
      darkContrast.foreground == VTColor(rgb: 0xFFFFFF),
      lightContrast.background == TerminalTheme.light.background,
      lightContrast.selection == TerminalTheme.light.selection,
      lightContrast.ansi == TerminalTheme.light.ansi,
      lightContrast.foreground == VTColor(rgb: 0x111820)
    else { throw NSError(domain: "TerminalMetalSmoke", code: 9, userInfo: [NSLocalizedDescriptionKey: "contrast theme changed background, selection, or ANSI palette"]) }
    guard TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: true, cursorBlinking: true, sessionRunning: true, reducedMotion: false),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: true, cursorBlinking: true, sessionRunning: true, reducedMotion: true),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: true, cursorBlinking: true, sessionRunning: true, reducedMotion: false, prefersNonBlinkingTextInsertionIndicator: true),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: false, windowFocused: true, cursorVisible: true, cursorBlinking: true, sessionRunning: true, reducedMotion: false),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: false, cursorVisible: true, cursorBlinking: true, sessionRunning: true, reducedMotion: false),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: true, cursorBlinking: true, sessionRunning: false, reducedMotion: false),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: false, cursorBlinking: true, sessionRunning: true, reducedMotion: false),
      !TerminalCursorBlinkPolicy.isEligible(backendVisible: true, windowFocused: true, cursorVisible: true, cursorBlinking: false, sessionRunning: true, reducedMotion: false)
    else { throw NSError(domain: "TerminalMetalSmoke", code: 10, userInfo: [NSLocalizedDescriptionKey: "cursor blink eligibility policy is not deterministic"]) }
    let out = URL(fileURLWithPath: "/private/tmp/web-studio-vt-renderer", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (name, theme) in [("dark", TerminalTheme.dark), ("light", TerminalTheme.light)] {
      for scale in [CGFloat(1), CGFloat(2)] {
      guard core.setTheme(theme), let frame = core.snapshot(),
        let target = makeTexture(device, width: Int(320 * scale), height: Int(160 * scale)) else {
        throw NSError(domain: "TerminalMetalSmoke", code: 2)
      }
      guard
        let command = renderer.render(
          frame: frame, geometry: TerminalGeometry(backingScale: scale), theme: theme, target: target),
        command.status != .error
      else { throw NSError(domain: "TerminalMetalSmoke", code: 3) }
      command.waitUntilCompleted()
      guard command.status == .completed else {
        throw NSError(
          domain: "TerminalMetalSmoke", code: 30,
          userInfo: [
            NSLocalizedDescriptionKey:
              "command status=\(command.status.rawValue) error=\(String(describing: command.error))"
          ])
      }
      var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
      target.getBytes(
        &bytes, bytesPerRow: target.width * 4,
        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
      let b = [frame.background.blue, frame.background.green, frame.background.red, 255]
      guard Array(bytes[0..<4]) == b else {
        throw NSError(
          domain: "TerminalMetalSmoke", code: 4,
          userInfo: [
            NSLocalizedDescriptionKey: "background mismatch \(Array(bytes[0..<4])) != \(b)"
          ])
      }
      let padX = Int(16 * scale)
      let padY = Int(12 * scale)
      let nonBackground = (padY..<min(target.height, padY + 138 * Int(scale))).contains { y in
        (padX..<min(target.width, padX + 284 * Int(scale))).contains { x in
          let i = (y * target.width + x) * 4
          return Array(bytes[i..<i + 4]) != b
        }
      }
      guard nonBackground else {
        throw NSError(
          domain: "TerminalMetalSmoke", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "no rendered glyph pixels for \(name)"])
      }
      let hasExpectedText = (padY..<min(target.height, padY + 88 * Int(scale))).contains { y in
        (padX..<min(target.width, padX + 284 * Int(scale))).contains { x in
          let i = (y * target.width + x) * 4
          let r = Int(bytes[i + 2])
          let g = Int(bytes[i + 1])
          let bl = Int(bytes[i])
          let expected = name == "dark" ? (216, 222, 228) : (41, 50, 58)
          return abs(r - expected.0) < 8 && abs(g - expected.1) < 8 && abs(bl - expected.2) < 8
        }
      }
      guard hasExpectedText else {
        throw NSError(
          domain: "TerminalMetalSmoke", code: 8,
          userInfo: [NSLocalizedDescriptionKey: "foreground color missing for \(name)"])
      }
      try writePNG(
        bytes: bytes, width: target.width, height: target.height,
        url: out.appendingPathComponent("\(name)-\(Int(scale))x.png"))
      }
    }
    try runPreparedAtlasStress(device: device, renderer: renderer)
    try runCursorPhasePixelCheck(device: device, renderer: renderer)
    print(
      "TerminalMetalRenderer smoke passed: /private/tmp/web-studio-vt-renderer/dark-1x.png /dark-2x.png /light-1x.png /light-2x.png"
    )
  }

  static func runCursorPhasePixelCheck(device: MTLDevice, renderer: TerminalMetalRenderer) throws {
    let core = TerminalVTCore(columns: 20, rows: 4)
    guard let frame = core.snapshot() else { throw NSError(domain: "TerminalMetalSmoke", code: 31) }
    let geometry = TerminalGeometry(backingScale: 1)
    let width = Int(32 + CGFloat(frame.columns) * geometry.cellSize.width)
    let height = Int(24 + CGFloat(frame.rows) * geometry.cellSize.height)
    guard let visible = makeTexture(device, width: width, height: height), let hidden = makeTexture(device, width: width, height: height),
      let visibleCommand = renderer.render(frame: frame, geometry: geometry, theme: .dark, target: visible, cursorPhaseVisible: true),
      let hiddenCommand = renderer.render(frame: frame, geometry: geometry, theme: .dark, target: hidden, cursorPhaseVisible: false)
    else { throw NSError(domain: "TerminalMetalSmoke", code: 32) }
    visibleCommand.waitUntilCompleted(); hiddenCommand.waitUntilCompleted()
    guard visibleCommand.status == .completed, hiddenCommand.status == .completed else { throw NSError(domain: "TerminalMetalSmoke", code: 33) }
    var a = [UInt8](repeating: 0, count: width * height * 4), b = a
    visible.getBytes(&a, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    hidden.getBytes(&b, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let x0 = Int(16), y0 = Int(12), x1 = min(width, x0 + Int(geometry.cellSize.width)), y1 = min(height, y0 + Int(geometry.cellSize.height))
    let changed = (y0..<y1).contains { y in (x0..<x1).contains { x in let i = (y * width + x) * 4; return a[i..<i + 4] != b[i..<i + 4] } }
    guard changed else { throw NSError(domain: "TerminalMetalSmoke", code: 34, userInfo: [NSLocalizedDescriptionKey: "hidden cursor phase still drew the empty-cell cursor"]) }
    print("Cursor phase pixel check passed")
  }

  static func runPreparedAtlasStress(device: MTLDevice, renderer: TerminalMetalRenderer) throws {
    let columns = 240
    let rows = 20
    let first = TerminalVTCore(columns: columns, rows: rows)
    let second = TerminalVTCore(columns: columns, rows: rows)
    func glyphFrame(_ base: UInt32) -> Data {
      var text = ""
      for row in 0..<rows {
        for column in 0..<columns / 2 {
          let scalar = UnicodeScalar(base + UInt32(row * (columns / 2) + column))!
          text.unicodeScalars.append(scalar)
        }
        if row + 1 < rows { text.append("\n") }
      }
      return Data(text.utf8)
    }
    first.feed(glyphFrame(0x4E00))
    second.feed(glyphFrame(0x7000))
    guard let firstFrame = first.snapshot(), let secondFrame = second.snapshot() else { throw NSError(domain: "TerminalMetalSmoke", code: 20) }
    let stressGeometry = TerminalGeometry(backingScale: 1)
    let stressWidth = Int(32 + CGFloat(columns) * stressGeometry.cellSize.width)
    let stressHeight = Int(24 + CGFloat(rows) * stressGeometry.cellSize.height)
    guard let firstTarget = makeTexture(device, width: stressWidth, height: stressHeight),
      let secondTarget = makeTexture(device, width: stressWidth, height: stressHeight),
      let firstCommand = renderer.render(frame: firstFrame, geometry: stressGeometry, theme: .dark, target: firstTarget),
      let secondCommand = renderer.render(frame: secondFrame, geometry: stressGeometry, theme: .dark, target: secondTarget)
    else { throw NSError(domain: "TerminalMetalSmoke", code: 20) }
    firstCommand.waitUntilCompleted()
    secondCommand.waitUntilCompleted()
    guard firstCommand.status == .completed, secondCommand.status == .completed else {
      throw NSError(domain: "TerminalMetalSmoke", code: 21)
    }
    try checkStressPixels(firstTarget, background: firstFrame.background)
    try checkStressPixels(secondTarget, background: secondFrame.background)
    let firstHeads = Set(firstFrame.cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }.map(\.text)).count
    let secondHeads = Set(secondFrame.cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }.map(\.text)).count
    guard firstHeads == 1_200 && secondHeads == 1_200 else { throw NSError(domain: "TerminalMetalSmoke", code: 23, userInfo: [NSLocalizedDescriptionKey: "visible grapheme heads \(firstHeads)+\(secondHeads)"]) }
    print("PreparedAtlas stress passed: \(firstHeads) + \(secondHeads) distinct visible grapheme heads")
  }

  static func checkStressPixels(_ target: MTLTexture, background: VTColor) throws {
    var bytes = [UInt8](repeating: 0, count: target.width * target.height * 4)
    target.getBytes(
      &bytes, bytesPerRow: target.width * 4,
      from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
    let bg = [background.blue, background.green, background.red, 255]
    guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else { throw NSError(domain: "TerminalMetalSmoke", code: 24, userInfo: [NSLocalizedDescriptionKey: "non-opaque rendered pixel"]) }
    let regions = [(16, max(17, target.width / 3)), (target.width / 2 - 50, target.width / 2 + 50), (min(target.width - 1, target.width * 2 / 3), target.width - 16)]
    for (lo, hi) in regions {
      let found = (12..<min(300, target.height)).contains { y in
        (max(0, lo)..<min(target.width, hi)).contains { x in
          let i = (y * target.width + x) * 4
          return Array(bytes[i..<i + 4]) != bg
        }
      }
      guard found else {
        throw NSError(domain: "TerminalMetalSmoke", code: 22,
          userInfo: [NSLocalizedDescriptionKey: "missing stress glyph pixels in x=\(lo)..<\(hi)"])
      }
    }
  }
  static func makeTexture(_ d: MTLDevice, width: Int = 320, height: Int = 160) -> MTLTexture? {
    let x = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    x.usage = [.renderTarget, .shaderRead]
    return d.makeTexture(descriptor: x)
  }
  static func writePNG(bytes: [UInt8], width: Int, height: Int, url: URL) throws {
    var copy = bytes
    let image: CGImage? = copy.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress,
        let ctx = CGContext(
          data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      return ctx.makeImage()
    }
    guard let image,
      let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "TerminalMetalSmoke", code: 6) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "TerminalMetalSmoke", code: 7)
    }
  }
}
