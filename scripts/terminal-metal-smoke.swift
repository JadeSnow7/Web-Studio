import AppKit
import CoreText
import CryptoKit
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
    try runGlyphLRUCheck()
    try runIncrementalAtlasChecks(device: device)
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

  // MARK: Incremental atlas checks

  static func fail(_ code: Int, _ message: String) -> NSError {
    NSError(domain: "TerminalMetalSmoke", code: code, userInfo: [NSLocalizedDescriptionKey: message])
  }

  static func readBytes(_ texture: MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * texture.pixelFormat.bytesPerPixelForSmoke)
    texture.getBytes(
      &bytes, bytesPerRow: texture.width * texture.pixelFormat.bytesPerPixelForSmoke,
      from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return bytes
  }

  static func digest(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }

  /// Serial reference: a brand-new renderer builds a fresh single-generation atlas for exactly this frame.
  static func referenceBytes(
    device: MTLDevice, frame: VTFrame, geometry: TerminalGeometry, width: Int, height: Int
  ) throws -> [UInt8] {
    let reference = try TerminalMetalRenderer(device: device)
    guard let target = makeTexture(device, width: width, height: height),
      let command = reference.render(frame: frame, geometry: geometry, theme: .dark, target: target)
    else { throw fail(60, "reference render unavailable") }
    command.waitUntilCompleted()
    guard command.status == .completed else { throw fail(61, "reference command incomplete") }
    return readBytes(target)
  }

  /// Rows of a scrolling screen: line `j` carries six CJK code points that no other line has, plus ASCII and colour.
  static func churnText(_ first: Int, rows: Int, reversedAlphabet: Bool = false) -> Data {
    var text = ""
    for r in 0..<rows {
      let j = first + r
      text += String(format: "%03d:", j % 1000)
      for k in 0..<6 {
        text += "\u{1b}[\(31 + (j + k) % 6)m"
        text.unicodeScalars.append(UnicodeScalar(0x5000 + j * 6 + k)!)
      }
      text += "\u{1b}[0m-"
      let letters = Array("abcdefghijklmnopqrstuvwxyz")
      for k in 0..<20 { text.append(letters[reversedAlphabet ? 25 - (j + k) % 26 : (j + k) % 26]) }
      if r + 1 < rows { text += "\r\n" }
    }
    return Data(text.utf8)
  }

  static func frame(columns: Int, rows: Int, _ data: Data) throws -> VTFrame {
    let core = TerminalVTCore(columns: columns, rows: rows)
    core.feed(data)
    guard core.setTheme(.dark), let snapshot = core.snapshot() else { throw fail(62, "frame snapshot unavailable") }
    return snapshot
  }

  static func sizeFor(_ frame: VTFrame, _ geometry: TerminalGeometry) -> (Int, Int) {
    let scale = geometry.backingScale
    return (
      Int(32 * scale + ceil(geometry.cellSize.width * CGFloat(frame.columns) * scale)),
      Int(24 * scale + ceil(geometry.cellSize.height * CGFloat(frame.rows) * scale))
    )
  }

  /// Hard ceilings the check enforces regardless of what the renderer's own constants say.
  static let pageCeiling = 16
  static let byteCeiling = 64 << 20

  static func runGlyphLRUCheck() throws {
    let cache = TerminalMetalRenderer.GlyphLRU<Int, Int>(capacity: 4)
    for i in 0..<4 { cache.insert(i * 10, for: i) }
    guard cache.value(for: 0) == 0 else { throw fail(70, "LRU lost a resident key") }  // refreshes key 0
    cache.insert(40, for: 4)  // evicts the least recently used: key 1
    guard cache.value(for: 1) == nil, cache.value(for: 0) == 0, cache.value(for: 2) == 20, cache.value(for: 3) == 30,
      cache.value(for: 4) == 40, cache.count == 4
    else { throw fail(71, "LRU did not evict the least recently used key") }
    cache.insert(41, for: 4)  // update in place, no growth
    guard cache.value(for: 4) == 41, cache.count == 4 else { throw fail(72, "LRU update grew or lost the entry") }
    // Long churn: capacity stays bounded, the newest `capacity` keys are exactly the resident ones, slots are recycled.
    for i in 100..<20_000 { cache.insert(i, for: i) }
    guard cache.count == 4, (19_996..<20_000).allSatisfy({ cache.value(for: $0) == $0 }), cache.value(for: 0) == nil else {
      throw fail(73, "LRU residency wrong after long churn")
    }
    print("Glyph LRU check passed")
  }

  static func runIncrementalAtlasChecks(device: MTLDevice) throws {
    // SMOKE_ONLY=ascii,runcap,churn,inflight,bytecap restricts the run (used to attribute mutation failures to one check).
    let only = ProcessInfo.processInfo.environment["SMOKE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    func selected(_ name: String) -> Bool { only?.contains(name) ?? true }
    if selected("ascii") { try runASCIITableInvalidation(device: device) }
    if selected("runcap") { try runRunCapCompaction(device: device) }
    if selected("churn") {
      for scale in [CGFloat(1), CGFloat(2)] {
        try runLongChurn(device: device, scale: scale)
      }
    }
    if selected("inflight") {
      try runInFlightOverlap(device: device, scale: 1)
      try runInFlightOverlap(device: device, scale: 2)
    }
    if selected("bytecap") { try runByteCapPressure(device: device) }
  }

  /// Long churn of distinct glyphs: every frame appends a page until the cap forces compaction. Checks the caps, that
  /// compaction happens, that pages of one generation are never modified or replaced, and that every frame equals a serial
  /// reference (byte-identical at 1x and 2x).
  static func runLongChurn(device: MTLDevice, scale: CGFloat) throws {
    let columns = 60, rows = 12, frames = 72
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: scale)
    var previous: [(texture: MTLTexture, digest: String)] = []
    var previousCompactions = 0
    var maxPages = 0
    for k in 0..<frames {
      let f = try frame(columns: columns, rows: rows, churnText(k, rows: rows))
      let (w, h) = sizeFor(f, geometry)
      guard let target = makeTexture(device, width: w, height: h),
        let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
      else { throw fail(80, "churn render unavailable at frame \(k)") }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw fail(81, "churn command incomplete at frame \(k)") }
      let expected = try referenceBytes(device: device, frame: f, geometry: geometry, width: w, height: h)
      guard readBytes(target) == expected else {
        throw fail(82, "scale \(Int(scale))x churn frame \(k) differs from the serial reference")
      }
      let diag = renderer.atlasDiagnostics
      maxPages = max(maxPages, diag.textures.count)
      guard diag.textures.count <= pageCeiling, diag.textures.count <= TerminalMetalRenderer.maxAtlasPages,
        diag.byteCount <= byteCeiling, diag.byteCount <= TerminalMetalRenderer.maxAtlasBytes
      else { throw fail(83, "atlas exceeded its cap at frame \(k): \(diag.textures.count) pages, \(diag.byteCount) bytes") }
      if diag.compactions == previousCompactions {
        guard diag.textures.count >= previous.count else { throw fail(84, "atlas lost pages without compacting at frame \(k)") }
        for (i, old) in previous.enumerated() {
          guard diag.textures[i] === old.texture else { throw fail(85, "page \(i) was replaced without compaction at frame \(k)") }
          guard digest(readBytes(old.texture)) == old.digest else { throw fail(86, "page \(i) was modified after creation at frame \(k)") }
        }
      } else {
        for texture in diag.textures where previous.contains(where: { $0.texture === texture }) {
          throw fail(87, "compaction reused a page of the previous generation at frame \(k)")
        }
      }
      previous = diag.textures.map { ($0, digest(readBytes($0))) }
      previousCompactions = diag.compactions
    }
    guard maxPages >= 8 else { throw fail(88, "churn never grew the atlas by pages (max \(maxPages))") }
    guard previousCompactions >= 3 else { throw fail(89, "churn compacted only \(previousCompactions) times") }
    print("Long churn passed at \(Int(scale))x: \(frames) frames, max \(maxPages) pages, \(previousCompactions) compactions")
  }

  /// Compaction renumbers atlas indices; a stale ASCII table would then draw the wrong glyphs on that very frame.
  static func runASCIITableInvalidation(device: MTLDevice) throws {
    let columns = 60, rows = 12
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: 1)
    func render(_ data: Data, label: String) throws -> Int {
      let f = try frame(columns: columns, rows: rows, data)
      let (w, h) = sizeFor(f, geometry)
      guard let target = makeTexture(device, width: w, height: h),
        let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
      else { throw fail(90, "ascii check render unavailable: \(label)") }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw fail(91, "ascii check command incomplete: \(label)") }
      let expected = try referenceBytes(device: device, frame: f, geometry: geometry, width: w, height: h)
      guard readBytes(target) == expected else { throw fail(92, "ascii check frame differs from reference: \(label)") }
      return renderer.atlasCompactions
    }
    // Generation 0 sees the alphabet in ascending order, so ascending indices land in the ASCII table.
    var compactions = try render(Data(("abcdefghijklmnopqrstuvwxyz\r\n" + String(repeating: "abcdefghij", count: 5)).utf8), label: "seed")
    let seedCompactions = compactions
    var k = 0
    // Every later frame draws the alphabet reversed and adds new glyphs, until the atlas compacts (from this frame's set).
    while compactions == seedCompactions && k < 60 {
      var text = "zyxwvutsrqponmlkjihgfedcba\r\n" + String(repeating: "jihgfedcba", count: 5) + "\r\n"
      for j in 0..<6 { text.unicodeScalars.append(UnicodeScalar(0x6000 + k * 6 + j)!) }
      compactions = try render(Data(text.utf8), label: "reversed \(k)")
      k += 1
    }
    guard compactions > seedCompactions else { throw fail(93, "ascii check never reached a compaction") }
    // A pure-ASCII frame now resolves everything through the ASCII table of the new generation.
    _ = try render(Data(("abcdefghijklmnopqrstuvwxyz\r\nzyxwvutsrqponmlkjihgfedcba").utf8), label: "ascii only after compaction")
    print("ASCII table invalidation passed after \(k) frames (compactions=\(compactions))")
  }

  /// A frame that would split the glyph pass into more draws than the run cap forces a compaction back to one page.
  static func runRunCapCompaction(device: MTLDevice) throws {
    let columns = 100, rows = 4
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: 1)
    func render(_ data: Data, label: String) throws {
      let f = try frame(columns: columns, rows: rows, data)
      let (w, h) = sizeFor(f, geometry)
      guard let target = makeTexture(device, width: w, height: h),
        let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
      else { throw fail(100, "run cap render unavailable: \(label)") }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw fail(101, "run cap command incomplete: \(label)") }
      let expected = try referenceBytes(device: device, frame: f, geometry: geometry, width: w, height: h)
      guard readBytes(target) == expected else { throw fail(102, "run cap frame differs from reference: \(label)") }
    }
    try render(Data("abcdefghij".utf8), label: "seed")
    let before = renderer.atlasCompactions
    let beforePages = renderer.atlasDiagnostics.textures.count
    // Alternating ASCII (page 0) and a new CJK glyph (appended page): about 2 * 45 runs per row, far above the cap.
    var alternating = ""
    for row in 0..<rows {
      for i in 0..<45 {
        alternating += "a"
        alternating.unicodeScalars.append(UnicodeScalar(0x7000 + row * 45 + i)!)
      }
      if row + 1 < rows { alternating += "\r\n" }
    }
    try render(Data(alternating.utf8), label: "alternating")
    let diag = renderer.atlasDiagnostics
    guard beforePages == 1, renderer.atlasCompactions == before + 1, diag.textures.count <= 2 else {
      throw fail(103, "fragmented frame did not compact: pages \(beforePages)->\(diag.textures.count), compactions \(before)->\(renderer.atlasCompactions)")
    }
    print("Run-cap compaction passed (max \(TerminalMetalRenderer.maxGlyphRuns) draws), pages after: \(diag.textures.count)")
  }

  /// Three frames are stuck in flight (their command buffers wait behind a blocker on the renderer's own queue) while later
  /// frames append pages and compaction replaces the atlas: once released, every frame must equal a serially rendered
  /// reference, so pages of replaced generations were kept alive and never modified.
  static func runInFlightOverlap(device: MTLDevice, scale: CGFloat) throws {
    let columns = 120, rows = 30, rounds = 24
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: scale)
    guard let event = device.makeSharedEvent() else { throw fail(114, "shared event unavailable") }
    var mismatches = 0, frames = 0, stalled = 0, gateRefusals = 0, compactedWhileHeld = 0
    var next = 0
    for round in 0..<rounds {
      // 0-2 serial frames shift the page count so compaction lands on different in-flight slots over the rounds.
      for _ in 0..<(round % 3) {
        let f = try frame(columns: columns, rows: rows, churnText(next, rows: rows))
        next += 2
        let (w, h) = sizeFor(f, geometry)
        guard let target = makeTexture(device, width: w, height: h),
          let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
        else { throw fail(119, "serial shift frame unavailable") }
        command.waitUntilCompleted()
      }
      guard let blocker = renderer.commandQueueForTesting.makeCommandBuffer() else { throw fail(115, "blocker unavailable") }
      blocker.encodeWaitForEvent(event, value: UInt64(round + 1))
      blocker.commit()
      var inflight: [(command: MTLCommandBuffer, target: MTLTexture, frame: VTFrame)] = []
      for slot in 0..<3 {
        let f = try frame(columns: columns, rows: rows, churnText(next, rows: rows, reversedAlphabet: (round + slot) % 2 == 1))
        next += 4  // heavy overlap with the previous frame plus 4 new lines of new glyphs
        let (w, h) = sizeFor(f, geometry)
        let compactionsBefore = renderer.atlasCompactions
        guard let target = makeTexture(device, width: w, height: h),
          let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
        else { throw fail(110, "in-flight render unavailable (round \(round) slot \(slot))") }
        if slot > 0 && renderer.atlasCompactions != compactionsBefore { compactedWhileHeld += 1 }
        inflight.append((command, target, f))
      }
      // Give the GPU time to (wrongly) run ahead; a queue that honours the blocker leaves all three unfinished.
      Thread.sleep(forTimeInterval: 0.02)
      if inflight.allSatisfy({ $0.command.status != .completed }) { stalled += 1 }
      // With three permits outstanding a fourth frame must be refused without touching the atlas.
      let before = renderer.atlasDiagnostics
      let extra = try frame(columns: columns, rows: rows, churnText(next + 1000, rows: rows))
      let (ew, eh) = sizeFor(extra, geometry)
      guard let extraTarget = makeTexture(device, width: ew, height: eh) else { throw fail(116, "extra target unavailable") }
      if renderer.render(frame: extra, geometry: geometry, theme: .dark, target: extraTarget) == nil { gateRefusals += 1 }
      let after = renderer.atlasDiagnostics
      guard after.glyphCount == before.glyphCount, after.textures.count == before.textures.count else {
        throw fail(117, "a refused frame changed the atlas")
      }
      event.signaledValue = UInt64(round + 1)
      for item in inflight { item.command.waitUntilCompleted() }
      for item in inflight {
        guard item.command.status == .completed else { throw fail(111, "in-flight command incomplete") }
        let (w, h) = sizeFor(item.frame, geometry)
        let expected = try referenceBytes(device: device, frame: item.frame, geometry: geometry, width: w, height: h)
        frames += 1
        if readBytes(item.target) != expected { mismatches += 1 }
      }
    }
    guard stalled == rounds, gateRefusals == rounds else {
      throw fail(118, "in-flight setup did not hold three frames in flight: stalled \(stalled)/\(rounds), refused \(gateRefusals)/\(rounds)")
    }
    guard mismatches == 0 else { throw fail(112, "\(mismatches)/\(frames) in-flight frames differ from the serial reference at \(Int(scale))x") }
    guard compactedWhileHeld >= 1 else { throw fail(113, "no compaction happened while earlier frames were still in flight") }
    print("In-flight overlap passed at \(Int(scale))x: \(frames) frames, 0 mismatches, 3 frames held in flight in \(stalled)/\(rounds) rounds, compactions while earlier frames were held=\(compactedWhileHeld)")
  }

  /// Six full-screen frames of 1,200 new glyphs each at 2x: appended full-size pages hit the byte cap and compact.
  static func runByteCapPressure(device: MTLDevice) throws {
    let columns = 240, rows = 20
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: 2)
    var maxBytes = 0
    for round in 0..<6 {
      var text = ""
      for row in 0..<rows {
        for column in 0..<columns / 2 {
          text.unicodeScalars.append(UnicodeScalar(UInt32(0x4E00 + round * 0x0800 + row * (columns / 2) + column))!)
        }
        if row + 1 < rows { text += "\r\n" }
      }
      let f = try frame(columns: columns, rows: rows, Data(text.utf8))
      let (w, h) = sizeFor(f, geometry)
      guard let target = makeTexture(device, width: w, height: h),
        let command = renderer.render(frame: f, geometry: geometry, theme: .dark, target: target)
      else { throw fail(120, "byte cap render unavailable at round \(round)") }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw fail(121, "byte cap command incomplete") }
      let diag = renderer.atlasDiagnostics
      maxBytes = max(maxBytes, diag.byteCount)
      guard diag.byteCount <= byteCeiling, diag.textures.count <= pageCeiling else {
        throw fail(122, "byte cap exceeded at round \(round): \(diag.byteCount) bytes, \(diag.textures.count) pages")
      }
      if round == 5 {
        let expected = try referenceBytes(device: device, frame: f, geometry: geometry, width: w, height: h)
        guard readBytes(target) == expected else { throw fail(123, "frame after byte-cap compaction differs from reference") }
      }
    }
    guard renderer.atlasCompactions >= 1 else { throw fail(124, "byte cap pressure never compacted (max \(maxBytes) bytes)") }
    print("Byte cap pressure passed: max \(maxBytes >> 20) MiB, compactions=\(renderer.atlasCompactions)")
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

extension MTLPixelFormat {
  /// The formats these smoke tests read back (bgra8Unorm targets and rgba8Unorm pages).
  var bytesPerPixelForSmoke: Int { 4 }
}
