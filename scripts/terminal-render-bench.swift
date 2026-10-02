#if WEB_STUDIO_VT
import AppKit
import CoreText
import CryptoKit
import Darwin
import Foundation
import Metal

// Headless render / terminal-core benchmark. One invocation == one repetition (one process).
// Only public API that exists at HEAD is used:
//   TerminalVTCore(columns:rows:), feed, snapshot, resize, setTheme, scroll
//   TerminalMetalRenderer(device:).render(frame:geometry:theme:target:cursorPhaseVisible:)
//   TerminalGeometry(backingScale:)
// Release-only: build with swiftc -O (see scripts/test-terminal-render-bench.sh).
@main struct TerminalRenderBench {
  enum BenchError: Error, CustomStringConvertible {
    case usage(String), failed(String)
    var description: String { switch self { case .usage(let s), .failed(let s): return s } }
  }

  struct RUsage { let user: Double; let system: Double }
  struct Sample { var cpu: Double; var wall: Double }

  struct Fixture {
    let name: String
    let feed: Data
    let rows: [String]  // expected visible text (cluster heads joined) for rows 0..<rows.count; remaining rows empty
    let expectedHeads: Int
    let expectedWideTails: Int
  }

  static let columns = 134
  static let rowCount = 45
  static let hotCount = 100
  static let churnFrames = 60
  static let churnNewPerFrame = 8
  static let fixtureRows = 44

  // MARK: entry

  static func main() throws {
    do { try run(arguments: CommandLine.arguments) }
    catch { fputs("terminal-render-bench: \(error)\n", stderr); exit(1) }
  }

  static func run(arguments: [String]) throws {
    func value(_ flag: String) -> String? {
      guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
      return arguments[i + 1]
    }
    guard let outputPath = value("--output") else {
      throw BenchError.usage("usage: terminal-render-bench --output FILE.json [--repetition N] [--label NAME] [--source-digest HEX]")
    }
    let repetition = Int(value("--repetition") ?? "1") ?? 1
    let label = value("--label") ?? "unlabeled"
    let sourceDigest = value("--source-digest") ?? ""
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw BenchError.usage("output exists; refusing overwrite") }

    var scalars: [String: Double] = [:]
    var hashes: [String: String] = [:]
    var details: [String: Any] = [:]
    var validation: [String: Any] = [:]
    let loadBefore = loadAverages()

    // ---- Metal device and renderer/geometry init (must run before any other renderer exists in this process)
    var device: MTLDevice?
    let deviceSample = try time { device = MTLCreateSystemDefaultDevice() }
    guard let device else { throw BenchError.failed("Metal device unavailable") }
    scalars["renderer_init/device_create/wall_s"] = deviceSample.wall
    scalars["renderer_init/device_create/cpu_s"] = deviceSample.cpu

    var firstRenderer: TerminalMetalRenderer?
    let firstInit = try time { firstRenderer = try TerminalMetalRenderer(device: device) }
    guard firstRenderer != nil else { throw BenchError.failed("first renderer init failed") }
    firstRenderer = nil
    var repeatedWall: [Double] = [], repeatedCPU: [Double] = []
    for _ in 0..<9 {
      var r: TerminalMetalRenderer?
      let s = try time { r = try TerminalMetalRenderer(device: device) }
      guard r != nil else { throw BenchError.failed("repeated renderer init failed") }
      repeatedWall.append(s.wall); repeatedCPU.append(s.cpu)
    }
    scalars["renderer_init/first_in_process/wall_s"] = firstInit.wall
    scalars["renderer_init/first_in_process/cpu_s"] = firstInit.cpu
    scalars["renderer_init/repeated_median/wall_s"] = median(repeatedWall)
    scalars["renderer_init/repeated_median/cpu_s"] = median(repeatedCPU)
    details["renderer_init"] = [
      "first_in_process": ["wall_s": firstInit.wall, "cpu_s": firstInit.cpu],
      "repeated_2nd_to_10th": ["wall_s": repeatedWall, "cpu_s": repeatedCPU],
      "note": "TerminalMetalRenderer(device:) construction only (queue + MSL compile + pipeline + sampler); device creation reported separately",
    ]

    var geometryWall: [Double] = []
    geometryWall.reserveCapacity(100)
    let geometryTotal = try time {
      for _ in 0..<100 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let g = TerminalGeometry(backingScale: 2)
        let t1 = DispatchTime.now().uptimeNanoseconds
        if g.cellSize.width <= 0 { fatalError("geometry invalid") }
        geometryWall.append(Double(t1 - t0) / 1e9)
      }
    }
    scalars["geometry_init/median_wall_s"] = median(geometryWall)
    scalars["geometry_init/total_100_cpu_s"] = geometryTotal.cpu
    details["geometry_init"] = ["constructions": 100, "per_construction_wall_s": geometryWall, "total_cpu_s": geometryTotal.cpu]

    // ---- shared render rig
    let rig = try Rig(device: device)
    validation["target_pixels"] = ["width": rig.width, "height": rig.height]

    // ---- fixtures
    let render: [Fixture] = [makeASCII120(), makeCJK60(), makeSGRMixed()]
    var frames: [String: VTFrame] = [:]
    for fx in render {
      let core = TerminalVTCore(columns: columns, rows: rowCount)
      guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
      core.feed(fx.feed)
      guard let frame = core.snapshot() else { throw BenchError.failed("snapshot missing for \(fx.name)") }
      validation["fixture/\(fx.name)"] = try validate(frame: frame, fixture: fx)
      frames[fx.name] = frame
    }
    if let sgr = frames["SGR_MIXED"] { validation["fixture/SGR_MIXED/attributes"] = try validateSGRAttributes(sgr) }

    // ---- metrics 1+2: cold first render then 100 hot renders, fresh renderer per fixture
    var hotDetails: [String: Any] = [:]
    for fx in render {
      guard let frame = frames[fx.name] else { continue }
      let renderer = try TerminalMetalRenderer(device: device)
      let target = try rig.makeTarget()
      let cold = try time { try rig.render(renderer, frame, target: target) }
      let coldHash = try rig.pixelHash(target, frame: frame, requireInk: true)
      var perRenderWall: [Double] = []
      perRenderWall.reserveCapacity(hotCount)
      let hot = try time {
        for _ in 0..<hotCount {
          let t0 = DispatchTime.now().uptimeNanoseconds
          try rig.render(renderer, frame, target: target)
          perRenderWall.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
      }
      let finalHash = try rig.pixelHash(target, frame: frame, requireInk: true)
      scalars["render_cold_first/\(fx.name)/cpu_s"] = cold.cpu
      scalars["render_cold_first/\(fx.name)/wall_s"] = cold.wall
      scalars["render_hot_100/\(fx.name)/cpu_s"] = hot.cpu
      scalars["render_hot_100/\(fx.name)/wall_s"] = hot.wall
      hashes["render_hot_100/\(fx.name)/pixel_sha256"] = finalHash.sha
      hashes["render_cold_first/\(fx.name)/pixel_sha256"] = coldHash.sha
      hotDetails[fx.name] = [
        "cold_cpu_s": cold.cpu, "cold_wall_s": cold.wall, "hot_100_cpu_s": hot.cpu, "hot_100_wall_s": hot.wall,
        "hot_per_render_wall_s": perRenderWall, "inked_pixels": finalHash.inked, "target_pixels": rig.width * rig.height,
      ]
    }
    details["render_hot_100"] = hotDetails

    // ---- metric 4: blink (block cursor on a glyph, cursorPhaseVisible alternating)
    let blinkFixture = makeBlinkFixture()
    do {
      let core = TerminalVTCore(columns: columns, rows: rowCount)
      guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
      core.feed(blinkFixture.feed)
      guard let frame = core.snapshot() else { throw BenchError.failed("snapshot missing for blink") }
      validation["fixture/\(blinkFixture.name)"] = try validate(frame: frame, fixture: blinkFixture)
      let c = frame.cursor
      guard c.visible, c.viewportHasValue, c.blinking, c.visualStyle == 1, c.x == 9, c.y == 9 else {
        throw BenchError.failed("blink fixture cursor invalid: visible=\(c.visible) viewport=\(c.viewportHasValue) blinking=\(c.blinking) style=\(c.visualStyle) x=\(c.x) y=\(c.y)")
      }
      validation["fixture/\(blinkFixture.name)/cursor"] = ["visible": c.visible, "blinking": c.blinking, "visual_style": c.visualStyle, "x": c.x, "y": c.y]
      let renderer = try TerminalMetalRenderer(device: device)
      let target = try rig.makeTarget()
      let cold = try time { try rig.render(renderer, frame, target: target) }
      var perRenderWall: [Double] = []
      let blink = try time {
        for i in 0..<hotCount {
          let t0 = DispatchTime.now().uptimeNanoseconds
          try rig.render(renderer, frame, target: target, cursorPhaseVisible: i % 2 == 0)
          perRenderWall.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
      }
      let finalHash = try rig.pixelHash(target, frame: frame, requireInk: true)
      try rig.render(renderer, frame, target: target, cursorPhaseVisible: true)
      let visibleHash = try rig.pixelHash(target, frame: frame, requireInk: true)
      try rig.render(renderer, frame, target: target, cursorPhaseVisible: false)
      let hiddenHash = try rig.pixelHash(target, frame: frame, requireInk: true)
      guard visibleHash.sha != hiddenHash.sha else { throw BenchError.failed("cursor phase visible/hidden renders are identical; blink fixture is not exercising the cursor") }
      scalars["render_blink_100/cpu_s"] = blink.cpu
      scalars["render_blink_100/wall_s"] = blink.wall
      hashes["render_blink_100/pixel_sha256_final"] = finalHash.sha
      hashes["render_blink_100/pixel_sha256_phase_visible"] = visibleHash.sha
      hashes["render_blink_100/pixel_sha256_phase_hidden"] = hiddenHash.sha
      details["render_blink_100"] = [
        "fixture": blinkFixture.name, "cold_cpu_s": cold.cpu, "cold_wall_s": cold.wall, "cpu_s": blink.cpu, "wall_s": blink.wall,
        "per_render_wall_s": perRenderWall, "note": "cold first render on the fresh renderer is timed separately (cold_*); the 100 alternating renders follow immediately",
      ]
    }

    // ---- metric 3: churn (60 different frames, each introducing new glyphs)
    do {
      let (churn, churnValidation) = try makeChurnFrames()
      validation["fixture/churn"] = churnValidation
      let renderer = try TerminalMetalRenderer(device: device)
      let target = try rig.makeTarget()
      var perFrameCPU: [Double] = [], perFrameWall: [Double] = []
      var frameHashes: [String: String] = [:]
      var lastHash = ""
      for (index, frame) in churn.enumerated() {
        let s = try time { try rig.render(renderer, frame, target: target) }
        perFrameCPU.append(s.cpu); perFrameWall.append(s.wall)
        let number = index + 1
        if number % 10 == 0 || number == churn.count {
          let h = try rig.pixelHash(target, frame: frame, requireInk: true)
          if number % 10 == 0 { frameHashes[String(number)] = h.sha }
          lastHash = h.sha
        }
      }
      let totalCPU = perFrameCPU.reduce(0, +), totalWall = perFrameWall.reduce(0, +)
      scalars["render_churn/cpu_s"] = totalCPU
      scalars["render_churn/wall_s"] = totalWall
      scalars["render_churn/cpu_s_excl_first_frame"] = totalCPU - perFrameCPU[0]
      scalars["render_churn/first_frame_cpu_s"] = perFrameCPU[0]
      hashes["render_churn/pixel_sha256_last"] = lastHash
      for (k, v) in frameHashes { hashes["render_churn/pixel_sha256_frame_\(k)"] = v }
      details["render_churn"] = [
        "frames": churn.count, "new_glyphs_per_frame": churnNewPerFrame,
        "per_frame_cpu_s": perFrameCPU, "per_frame_wall_s": perFrameWall, "cpu_s": totalCPU, "wall_s": totalWall,
        "note": "frame 0 is a full cold screen (44 lines x 8 new glyphs); frames 1..59 each scroll one line and add 8 unseen CJK code points. Per-frame timing excludes pixel readback/hashing.",
      ]
    }

    // ---- metric 5: snapshot_100 on the full ASCII120 screen
    do {
      let ascii = makeASCII120()
      let core = TerminalVTCore(columns: columns, rows: rowCount)
      guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
      core.feed(ascii.feed)
      var perSnapshotWall: [Double] = []
      var last: VTFrame?
      let s = try time {
        for _ in 0..<100 {
          let t0 = DispatchTime.now().uptimeNanoseconds
          last = core.snapshot()
          perSnapshotWall.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
      }
      guard let last else { throw BenchError.failed("snapshot_100 produced no frame") }
      validation["snapshot_100"] = try validate(frame: last, fixture: ascii)
      scalars["snapshot_100/cpu_s"] = s.cpu
      scalars["snapshot_100/wall_s"] = s.wall
      details["snapshot_100"] = ["cpu_s": s.cpu, "wall_s": s.wall, "per_snapshot_wall_s": perSnapshotWall]
    }

    // ---- metric 6: feed throughput
    do {
      var feedDetails: [String: Any] = [:]
      for (variant, lines) in [("ascii", makeFeedLines(mixed: false)), ("mixed", makeFeedLines(mixed: true))] {
        let data = Data(lines.joined(separator: "\r\n").utf8) + Data("\r\n".utf8)
        for (chunkName, chunkSize) in [("4k", 4096), ("32k", 32768)] {
          var chunks: [Data] = []
          var offset = 0
          while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunks.append(Data(data[offset..<end]))
            offset = end
          }
          let core = TerminalVTCore(columns: columns, rows: rowCount)
          guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
          let s = try time { for chunk in chunks { core.feed(chunk) } }
          guard let frame = core.snapshot() else { throw BenchError.failed("feed snapshot missing") }
          // rows 0..<44 hold the last 44 lines, row 44 is the empty cursor row
          for r in 0..<44 {
            let expected = lines[lines.count - 44 + r]
            let actual = rowText(frame, r)
            guard actual == expected else { throw BenchError.failed("feed content mismatch \(variant)/\(chunkName) row=\(r): \(actual.prefix(40)) != \(expected.prefix(40))") }
          }
          let mib = Double(data.count) / 1_048_576
          let key = "\(variant)_\(chunkName)"
          scalars["feed_throughput/\(key)/cpu_s_per_mib"] = s.cpu / mib
          scalars["feed_throughput/\(key)/wall_s_per_mib"] = s.wall / mib
          feedDetails[key] = ["lines": lines.count, "bytes": data.count, "chunks": chunks.count, "cpu_s": s.cpu, "wall_s": s.wall, "cpu_s_per_mib": s.cpu / mib]
        }
      }
      details["feed_throughput"] = feedDetails
    }

    // ---- metric 7: resize sequence after 10000 lines of history
    do {
      let lines = makeFeedLines(mixed: false)
      let data = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
      let core = TerminalVTCore(columns: columns, rows: rowCount)
      guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
      var offset = 0
      while offset < data.count { let end = min(offset + 32768, data.count); core.feed(Data(data[offset..<end])); offset = end }
      guard let filled = core.snapshot() else { throw BenchError.failed("resize fixture snapshot missing") }
      var perStepCPU: [Double] = [], perStepWall: [Double] = [], resizeCPU: [Double] = [], snapshotCPU: [Double] = []
      var stepColumns: [Int] = []
      var scrollbarTotals: [UInt64] = []
      for step in 0..<12 {
        let cols = step % 2 == 0 ? 108 : 134
        var ok = false
        var frame: VTFrame?
        let r = try time { ok = core.resize(columns: cols, rows: rowCount, cellWidthPixels: 17, cellHeightPixels: 35) }
        let s = try time { frame = core.snapshot() }
        guard ok, let frame, frame.columns == cols, frame.rows == rowCount, frame.cells.count == cols * rowCount else {
          throw BenchError.failed("resize step \(step) to \(cols) columns failed")
        }
        perStepCPU.append(r.cpu + s.cpu); perStepWall.append(r.wall + s.wall)
        resizeCPU.append(r.cpu); snapshotCPU.append(s.cpu)
        stepColumns.append(cols); scrollbarTotals.append(frame.scrollbar.total)
      }
      scalars["resize_seq/cpu_s"] = perStepCPU.reduce(0, +)
      scalars["resize_seq/wall_s"] = perStepWall.reduce(0, +)
      scalars["resize_seq/resize_only_cpu_s"] = resizeCPU.reduce(0, +)
      scalars["resize_seq/snapshot_only_cpu_s"] = snapshotCPU.reduce(0, +)
      validation["resize_seq"] = ["history_scrollbar_total_before": filled.scrollbar.total, "scrollbar_total_per_step": scrollbarTotals.map { Int($0) }, "columns_per_step": stepColumns]
      details["resize_seq"] = [
        "lines_fed": lines.count, "bytes": data.count, "steps": 12, "columns_per_step": stepColumns, "cell_px": [17, 35],
        "per_step_cpu_s": perStepCPU, "per_step_wall_s": perStepWall, "per_step_resize_cpu_s": resizeCPU, "per_step_snapshot_cpu_s": snapshotCPU,
        "note": "step 0 also changes the cell pixel size from the core default 8x16 to 17x35",
      ]
    }

    let loadAfter = loadAverages()
    let info = ProcessInfo.processInfo
    let report: [String: Any] = [
      "schema": "terminal-render-bench.v1",
      "label": label, "repetition": repetition,
      "harness_sha256": try harnessHash(), "source_digest": sourceDigest,
      "config": [
        "grid": ["columns": columns, "rows": rowCount], "font": ["kind": "monospacedSystemFont", "point_size": 13], "theme": "dark", "backing_scale": 2,
        "target_pixels": ["width": rig.width, "height": rig.height], "hot_renders": hotCount, "churn_frames": churnFrames, "churn_new_glyphs_per_frame": churnNewPerFrame,
        "fixture_order": render.map(\.name), "completion": "MTLCommandBuffer.waitUntilCompleted status=completed; not presentation or GPU time",
        "sampling": "harness process getrusage(RUSAGE_SELF) user+system CPU and DispatchTime wall; all values in seconds",
        "render_gate_retries": rig.retries, "one_repetition_per_process": true,
      ],
      "environment": [
        "thermal_state": info.thermalState.rawValue, "low_power_mode": info.isLowPowerModeEnabled, "active_processors": info.activeProcessorCount,
        "os": info.operatingSystemVersionString, "loadavg_before": loadBefore, "loadavg_after": loadAfter,
      ],
      "scalars": scalars, "hashes": hashes, "details": details, "validation": validation,
    ]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: outputURL, options: .withoutOverwriting)
    print("terminal render bench repetition \(repetition) complete: \(scalars.count) scalars, \(hashes.count) hashes; output=\(outputURL.path)")
  }

  // MARK: render rig

  final class Rig {
    let device: MTLDevice
    let geometry: TerminalGeometry
    let width: Int
    let height: Int
    var retries = 0
    init(device: MTLDevice) throws {
      self.device = device
      geometry = TerminalGeometry(backingScale: 2)
      width = Int(32 * 2 + ceil(geometry.cellSize.width * CGFloat(TerminalRenderBench.columns) * 2))
      height = Int(24 * 2 + ceil(geometry.cellSize.height * CGFloat(TerminalRenderBench.rowCount) * 2))
    }
    func makeTarget() throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      d.usage = [.renderTarget, .shaderRead]
      guard let t = device.makeTexture(descriptor: d) else { throw BenchError.failed("target texture unavailable") }
      return t
    }
    // The renderer's in-flight gate has 3 non-blocking slots released from the completion handler, which can run just
    // after waitUntilCompleted returns; a nil result is therefore retried (and counted) instead of treated as a failure.
    func render(_ renderer: TerminalMetalRenderer, _ frame: VTFrame, target: MTLTexture, cursorPhaseVisible: Bool = true) throws {
      var attempts = 0
      while true {
        if let command = renderer.render(frame: frame, geometry: geometry, theme: .dark, target: target, cursorPhaseVisible: cursorPhaseVisible) {
          command.waitUntilCompleted()
          guard command.status == .completed else { throw BenchError.failed("command incomplete status=\(command.status.rawValue) error=\(String(describing: command.error))") }
          return
        }
        attempts += 1; retries += 1
        guard attempts < 2000 else { throw BenchError.failed("render returned nil \(attempts) times; lastError=\(String(describing: renderer.lastError))") }
        usleep(200)
      }
    }
    /// SHA-256 of the raw BGRA target bytes; also verifies the target really contains rendered ink.
    func pixelHash(_ t: MTLTexture, frame: VTFrame, requireInk: Bool) throws -> (sha: String, inked: Int) {
      var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
      t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
      let bg: UInt32 = UInt32(frame.background.blue) | UInt32(frame.background.green) << 8 | UInt32(frame.background.red) << 16 | 0xFF << 24
      var inked = 0
      bytes.withUnsafeBytes { raw in
        let px = raw.bindMemory(to: UInt32.self)
        for p in px where p != bg { inked += 1 }
      }
      if requireInk && inked < 1000 { throw BenchError.failed("target has only \(inked) non-background pixels; render produced no content") }
      let digest = bytes.withUnsafeBytes { SHA256.hash(data: $0) }
      return (digest.map { String(format: "%02x", $0) }.joined(), inked)
    }
  }

  // MARK: fixtures

  static func makeASCII120() -> Fixture {
    let row = String(repeating: "A", count: 120)
    let rows = Array(repeating: row, count: fixtureRows)
    return Fixture(name: "ASCII120", feed: Data(rows.map { $0 + "\r\n" }.joined().utf8), rows: rows, expectedHeads: fixtureRows * 120, expectedWideTails: 0)
  }

  static func makeCJK60() -> Fixture {
    let row = String(repeating: "中", count: 60)
    let rows = Array(repeating: row, count: fixtureRows)
    return Fixture(name: "CJK60", feed: Data(rows.map { $0 + "\r\n" }.joined().utf8), rows: rows, expectedHeads: fixtureRows * 60, expectedWideTails: fixtureRows * 60)
  }

  /// ASCII120 content with a blinking block cursor parked on the glyph at column 10, row 10 (1-based CUP 10;10).
  static func makeBlinkFixture() -> Fixture {
    let base = makeASCII120()
    let control = "\u{1b}[1 q\u{1b}[?25h\u{1b}[10;10H"
    return Fixture(name: "ASCII120_BLINK_CURSOR", feed: base.feed + Data(control.utf8), rows: base.rows, expectedHeads: base.expectedHeads, expectedWideTails: 0)
  }

  /// Deterministic (no randomness) SGR-heavy screen: 256-colour fg/bg, bold, italic, bold+italic, underline 4:1..4:3,
  /// strikethrough, plus occasional inverse/faint, ASCII with a few CJK and emoji.
  static func makeSGRMixed() -> Fixture {
    let cjk = Array("中文终端渲染测试字体图集缓存").map { String($0) }
    let emoji = ["😀", "🚀", "🎉"]
    let esc = "\u{1b}"
    var rows: [String] = []
    var feed = ""
    var heads = 0, tails = 0
    for r in 0..<fixtureRows {
      var visible = ""
      var width = 0
      for s in 0..<14 {
        var seq = "\(esc)[0m\(esc)[38;5;\((r * 7 + s * 13 + 16) % 256)m"
        if s % 4 != 0 { seq += "\(esc)[48;5;\((r * 11 + s * 29 + 3) % 256)m" }
        switch (r + s) % 8 {
        case 1: seq += "\(esc)[1m"
        case 2: seq += "\(esc)[3m"
        case 3: seq += "\(esc)[1m\(esc)[3m"
        case 4: seq += "\(esc)[4:1m"
        case 5: seq += "\(esc)[4:2m"
        case 6: seq += "\(esc)[3m\(esc)[4:3m"
        case 7: seq += "\(esc)[1m\(esc)[9m"
        default: break
        }
        if (r * 5 + s) % 9 == 4 { seq += "\(esc)[7m" }
        if (r * 3 + s) % 13 == 6 { seq += "\(esc)[2m" }
        var text = ""
        for k in 0..<8 { text.unicodeScalars.append(UnicodeScalar(UInt8(33 + (r * 31 + s * 17 + k * 7) % 94))) }
        heads += 8; width += 8
        if (r + s) % 6 == 5 {
          text += cjk[(r * 3 + s) % cjk.count] + cjk[(r + s * 5 + 1) % cjk.count]
          heads += 2; tails += 2; width += 4
        }
        if (r * 3 + s) % 17 == 0 {
          text += emoji[(r + s) % emoji.count]
          heads += 1; tails += 1; width += 2
        }
        visible += text
        feed += seq + text
      }
      precondition(width <= 130, "SGR_MIXED row too wide")
      feed += "\(esc)[0m\r\n"
      rows.append(visible)
    }
    return Fixture(name: "SGR_MIXED", feed: Data(feed.utf8), rows: rows, expectedHeads: heads, expectedWideTails: tails)
  }

  static func pad3(_ n: Int) -> String { n < 10 ? "00\(n)" : (n < 100 ? "0\(n)" : "\(n)") }

  static func churnLine(_ j: Int) -> String {
    var s = pad3(j) + ":"
    for k in 0..<churnNewPerFrame { s.unicodeScalars.append(UnicodeScalar(0x5000 + j * churnNewPerFrame + k)!) }
    s += "-"
    for k in 0..<30 { s.unicodeScalars.append(UnicodeScalar(UInt8(97 + (j + k) % 26))) }
    return s
  }

  /// 60 snapshots of a scrolling screen; frame f shows lines f..f+43 and introduces the 8 never-seen glyphs of line f+43.
  static func makeChurnFrames() throws -> ([VTFrame], [String: Any]) {
    let core = TerminalVTCore(columns: columns, rows: rowCount)
    guard core.setTheme(.dark) else { throw BenchError.failed("theme setup failed") }
    var frames: [VTFrame] = []
    var seen = Set<String>()
    var newPerFrame: [Int] = []
    for j in 0..<(fixtureRows + churnFrames - 1) {
      core.feed(Data((churnLine(j) + "\r\n").utf8))
      guard j >= fixtureRows - 1 else { continue }
      guard let frame = core.snapshot() else { throw BenchError.failed("churn snapshot missing") }
      let f = frames.count
      guard frame.columns == columns, frame.rows == rowCount, frame.cells.count == columns * rowCount else { throw BenchError.failed("churn grid mismatch frame \(f)") }
      for r in 0..<fixtureRows {
        let expected = churnLine(f + r)
        guard rowText(frame, r) == expected else { throw BenchError.failed("churn content mismatch frame \(f) row \(r)") }
      }
      guard rowText(frame, fixtureRows).isEmpty else { throw BenchError.failed("churn frame \(f) cursor row not empty") }
      let heads = Set(frame.cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }.map(\.text))
      newPerFrame.append(f == 0 ? heads.count : heads.subtracting(seen).count)
      seen.formUnion(heads)
      frames.append(frame)
    }
    guard frames.count == churnFrames else { throw BenchError.failed("churn frame count \(frames.count)") }
    guard newPerFrame.dropFirst().allSatisfy({ $0 == churnNewPerFrame }) else { throw BenchError.failed("churn frames did not each introduce \(churnNewPerFrame) new glyphs: \(newPerFrame)") }
    return (frames, ["frames": frames.count, "new_distinct_clusters_per_frame": newPerFrame, "total_distinct_clusters": seen.count])
  }

  static func makeFeedLines(mixed: Bool) -> [String] {
    let cjk = Array("中文终端渲染测试字体图集缓存滚动输出").map { String($0) }
    var lines: [String] = []
    lines.reserveCapacity(10_000)
    for i in 0..<10_000 {
      var s = "line\(i):"
      if mixed && i % 2 == 1 {
        for k in 0..<20 { s += cjk[(i + k) % cjk.count] }
        for k in 0..<40 { s.unicodeScalars.append(UnicodeScalar(UInt8(33 + (i * 7 + k * 3) % 94))) }
      } else {
        for k in 0..<(72 + i % 13) { s.unicodeScalars.append(UnicodeScalar(UInt8(33 + (i * 7 + k * 3) % 94))) }
      }
      lines.append(s)
    }
    return lines
  }

  // MARK: validation

  static func isHead(_ c: VTCell) -> Bool { !c.text.isEmpty && c.wide.rawValue != 2 && c.wide.rawValue != 3 }
  static func isTail(_ c: VTCell) -> Bool { c.wide.rawValue == 2 || c.wide.rawValue == 3 }

  static func rowText(_ frame: VTFrame, _ row: Int) -> String {
    let start = row * frame.columns
    return frame.cells[start..<(start + frame.columns)].filter(isHead).map(\.text).joined()
  }

  static func validate(frame: VTFrame, fixture: Fixture) throws -> [String: Any] {
    guard frame.columns == columns, frame.rows == rowCount, frame.cells.count == columns * rowCount else {
      throw BenchError.failed("grid mismatch \(fixture.name): \(frame.columns)x\(frame.rows) cells=\(frame.cells.count)")
    }
    let heads = frame.cells.filter(isHead)
    let tails = frame.cells.filter(isTail)
    guard heads.count == fixture.expectedHeads, tails.count == fixture.expectedWideTails else {
      throw BenchError.failed("cell invariant mismatch \(fixture.name) heads=\(heads.count)/\(fixture.expectedHeads) tails=\(tails.count)/\(fixture.expectedWideTails)")
    }
    for row in 0..<frame.rows {
      let expected = row < fixture.rows.count ? fixture.rows[row] : ""
      guard rowText(frame, row) == expected else { throw BenchError.failed("content mismatch \(fixture.name) row=\(row)") }
    }
    return ["nonempty_heads": heads.count, "wide_tails": tails.count, "unique_clusters": Set(heads.map(\.text)).count, "input_bytes": fixture.feed.count]
  }

  static func validateSGRAttributes(_ frame: VTFrame) throws -> [String: Any] {
    let cells = frame.cells.filter(isHead)
    let stats: [String: Int] = [
      "bold": cells.filter { $0.bold && !$0.italic }.count,
      "italic": cells.filter { $0.italic && !$0.bold }.count,
      "bold_italic": cells.filter { $0.bold && $0.italic }.count,
      "underline_single": cells.filter { $0.underlineStyle == 1 }.count,
      "underline_double": cells.filter { $0.underlineStyle == 2 }.count,
      "underline_curly": cells.filter { $0.underlineStyle == 3 }.count,
      "strikethrough": cells.filter { $0.strikethrough }.count,
      "inverse": cells.filter { $0.inverse }.count,
      "faint": cells.filter { $0.faint }.count,
      "non_default_background": cells.filter { $0.background != frame.background }.count,
      "distinct_foregrounds": Set(cells.map { [$0.foreground.red, $0.foreground.green, $0.foreground.blue] }).count,
      "wide_heads": cells.filter { $0.wide.rawValue == 1 }.count,
    ]
    for key in ["bold", "italic", "bold_italic", "underline_single", "underline_double", "underline_curly", "strikethrough", "inverse", "faint", "non_default_background", "wide_heads"] {
      guard (stats[key] ?? 0) > 0 else { throw BenchError.failed("SGR_MIXED frame is missing attribute \(key): \(stats)") }
    }
    guard (stats["distinct_foregrounds"] ?? 0) >= 20 else { throw BenchError.failed("SGR_MIXED frame has too few distinct foregrounds: \(stats)") }
    return stats
  }

  // MARK: timing helpers

  static func usage() throws -> RUsage {
    var r = rusage()
    guard getrusage(RUSAGE_SELF, &r) == 0 else { throw BenchError.failed("getrusage failed") }
    return RUsage(
      user: Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6,
      system: Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6)
  }

  static func time(_ body: () throws -> Void) throws -> Sample {
    let u0 = try usage()
    let t0 = DispatchTime.now().uptimeNanoseconds
    try body()
    let t1 = DispatchTime.now().uptimeNanoseconds
    let u1 = try usage()
    let cpu = (u1.user - u0.user) + (u1.system - u0.system)
    return Sample(cpu: max(0, cpu), wall: Double(t1 - t0) / 1e9)
  }

  static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }

  static func loadAverages() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    return getloadavg(&l, 3) == 3 ? l : []
  }

  static func harnessHash() throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: #filePath))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
#else
import Foundation
@main struct TerminalRenderBench { static func main() { print("WEB_STUDIO_VT required") } }
#endif
