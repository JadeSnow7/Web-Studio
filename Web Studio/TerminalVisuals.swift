#if WEB_STUDIO_VT
  import AppKit
  import CoreText
  public struct TerminalTheme: Equatable, Sendable {
    public let background, foreground, selection, cursor: VTColor
    public let ansi: [VTColor]
    public let palette: [VTColor]
    public static let dark = TerminalTheme(
      background: .init(rgb: 0x252A2E), foreground: .init(rgb: 0xD8DEE4),
      selection: .init(rgb: 0x46515B), cursor: .init(rgb: 0xD8DEE4), ansi: Self.ansi16)
    public static let light = TerminalTheme(
      background: .init(rgb: 0xF7F8FA), foreground: .init(rgb: 0x29323A),
      selection: .init(rgb: 0xC2D8EE), cursor: .init(rgb: 0x29323A), ansi: Self.lightANSI)
    public init(
      background: VTColor, foreground: VTColor, selection: VTColor, cursor: VTColor, ansi: [VTColor]
    ) {
      self.background = background
      self.foreground = foreground
      self.selection = selection
      self.cursor = cursor
      self.ansi = ansi
      var p = ansi
      let q = [0, 95, 135, 175, 215, 255]
      for r in q { for g in q { for b in q { p.append(VTColor(r, g, b)) } } }
      for i in 0..<24 {
        let v = 8 + i * 10
        p.append(VTColor(v, v, v))
      }
      palette = Array(p.prefix(256))
    }
    public func increasedContrast() -> TerminalTheme {
      TerminalTheme(
        background: background,
        foreground: background == TerminalTheme.dark.background ? .init(rgb: 0xFFFFFF) : .init(rgb: 0x111820),
        selection: selection,
        cursor: background == TerminalTheme.dark.background ? .init(rgb: 0xFFFFFF) : .init(rgb: 0x111820),
        ansi: ansi)
    }
    private static let ansi16 = (0..<16).map {
      VTColor(
        rgb: [
          0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5, 0x666666,
          0xE74856, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
        ][$0])
    }
    private static let lightANSI = (0..<16).map {
      VTColor(
        rgb: [
          0x29323A, 0xB03A3E, 0x356B3F, 0x806514, 0x245FA4, 0x8A458E, 0x277782, 0x64717D, 0x63717D,
          0xC13B42, 0x3C7D46, 0x91720B, 0x276CC2, 0x9A4A9E, 0x24818B, 0x111820,
        ][$0])
    }
  }
  public enum TerminalCursorBlinkPolicy {
    public static func isEligible(
      backendVisible: Bool, windowFocused: Bool, cursorVisible: Bool,
      cursorBlinking: Bool, sessionRunning: Bool, reducedMotion: Bool,
      prefersNonBlinkingTextInsertionIndicator: Bool = false
    ) -> Bool {
      backendVisible && windowFocused && cursorVisible && cursorBlinking && sessionRunning && !reducedMotion && !prefersNonBlinkingTextInsertionIndicator
    }
  }
  public struct TerminalGeometry {
    public let cellSize: CGSize
    public let baseline: CGFloat
    public let contentInset: NSEdgeInsets
    public let backingScale: CGFloat
    public let cellPixelSize: CGSize
    public init(
      font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular), backingScale: CGFloat
    ) {
      let ct = font as CTFont
      var g = CGGlyph()
      var c = UniChar(77)
      CTFontGetGlyphsForCharacters(ct, &c, &g, 1)
      var a = CGSize.zero
      CTFontGetAdvancesForGlyphs(ct, .horizontal, &g, &a, 1)
      let s = max(1, backingScale)
      cellSize = CGSize(
        width: ceil(a.width * s) / s,
        height: ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct) + 2) * s)
          / s)
      baseline = ceil((CTFontGetAscent(ct) + 1) * s) / s
      contentInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
      self.backingScale = s
      self.cellPixelSize = CGSize(width: cellSize.width * s, height: cellSize.height * s)
    }
    public func gridSize(for b: CGSize) -> (cols: Int, rows: Int) {
      (
        max(1, Int(floor((b.width - 32) / cellSize.width))),
        max(1, Int(floor((b.height - 24) / cellSize.height)))
      )
    }
    public func origin(for c: Int, row: Int) -> CGPoint {
      CGPoint(x: 16 + CGFloat(c) * cellSize.width, y: 12 + CGFloat(row) * cellSize.height)
    }
    public func cell(at p: CGPoint) -> (column: Int, row: Int) {
      (
        max(0, Int(floor((p.x - 16) / cellSize.width))),
        max(0, Int(floor((p.y - 12) / cellSize.height)))
      )
    }
  }
#endif
