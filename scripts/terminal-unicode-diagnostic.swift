#if WEB_STUDIO_VT
import AppKit
import CoreText
import CryptoKit
import Darwin
import Foundation
import Metal

@main struct TerminalUnicodeDiagnostic {
  enum DiagnosticError: Error, CustomStringConvertible {
    case usage(String), failed(String)
    var description: String { switch self { case .usage(let s), .failed(let s): return s } }
  }

  struct Fixture {
    let name: String
    let rows: [String]
    let expectedHeads: Int
    let expectedWideTails: Int
    var data: Data { Data(rows.joined().utf8) }
  }

  struct RUsage {
    let user: Double
    let system: Double
  }

  static func main() throws {
    do { try run(arguments: CommandLine.arguments) }
    catch { fputs("terminal-unicode-diagnostic: \(error)\n", stderr); exit(1) }
  }

  static func run(arguments: [String]) throws {
    guard let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count else {
      throw DiagnosticError.usage("usage: terminal-unicode-diagnostic --output DIRECTORY")
    }
    let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
    let fm = FileManager.default
    guard !fm.fileExists(atPath: output.path) else { throw DiagnosticError.usage("output exists") }
    try fm.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fixtures = makeFixtures()
    let device = MTLCreateSystemDefaultDevice()
    guard let device else { throw DiagnosticError.failed("Metal device unavailable") }
    let sourceHash = try sourceHash()
    var records: [[String: Any]] = []
    var forward = true
    for round in 1...6 {
      let order = forward ? fixtures : fixtures.reversed()
      for fixture in order {
        records.append(try measure(fixture: fixture, round: round, order: forward ? "forward" : "reverse", device: device))
      }
      forward.toggle()
    }
    let report: [String: Any] = [
      "schema": "terminal-unicode-diagnostic.v1",
      "source_sha256": sourceHash,
      "grid": ["columns": 134, "rows": 45],
      "font": ["kind": "monospacedSystemFont", "point_size": 13],
      "theme": "dark",
      "backing_scale": 2,
      "rounds": 6,
      "order": "forward/reverse alternating",
      "warm_commands": 100,
      "completion": "MTLCommandBuffer.waitUntilCompleted status=completed; not presentation or GPU time",
      "sampling": "harness process getrusage user+system CPU and DispatchTime wall",
      "fixtures": fixtures.map { ["name": $0.name, "rows": 44, "expected_heads": $0.expectedHeads, "expected_wide_tails": $0.expectedWideTails] },
      "records": records
    ]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try bytes.write(to: output.appendingPathComponent("results.json"), options: .withoutOverwriting)
    let manifest: [String: Any] = ["source_sha256": sourceHash, "result_sha256": sha256(bytes), "records": records.count]
    let manifestBytes = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try manifestBytes.write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    print("terminal unicode diagnostic complete: \(records.count) records; output=\(output.path)")
  }

  static func makeFixtures() -> [Fixture] {
    let ascii = String(repeating: "A", count: 120)
    let repeated60 = String(repeating: "中", count: 60)
    let repeated40 = String(repeating: "中", count: 40)
    var distinctScalars = String.UnicodeScalarView()
    for offset in 0..<40 { distinctScalars.append(UnicodeScalar(0x4E00 + offset)!) }
    let distinct40 = String(distinctScalars)
    return [
      Fixture(name: "ASCII120", rows: Array(repeating: ascii + "\r\n", count: 44), expectedHeads: 44 * 120, expectedWideTails: 0),
      Fixture(name: "CJK60", rows: Array(repeating: repeated60 + "\r\n", count: 44), expectedHeads: 44 * 60, expectedWideTails: 44 * 60),
      Fixture(name: "CJK40", rows: Array(repeating: repeated40 + "\r\n", count: 44), expectedHeads: 44 * 40, expectedWideTails: 44 * 40),
      Fixture(name: "CJK40distinct", rows: Array(repeating: distinct40 + "\r\n", count: 44), expectedHeads: 44 * 40, expectedWideTails: 44 * 40)
    ]
  }

  static func measure(fixture: Fixture, round: Int, order: String, device: MTLDevice) throws -> [String: Any] {
    let input = fixture.data
    let inputHash = sha256(input)
    let core = TerminalVTCore(columns: 134, rows: 45)
    guard core.setTheme(.dark) else { throw DiagnosticError.failed("theme setup failed") }
    let feedUsageBefore = try usage()
    let feedStart = DispatchTime.now().uptimeNanoseconds
    core.feed(input)
    guard let frame = core.snapshot() else { throw DiagnosticError.failed("snapshot missing for \(fixture.name)") }
    let feedEnd = DispatchTime.now().uptimeNanoseconds
    let feedUsageAfter = try usage()
    let stats = try validate(frame: frame, fixture: fixture, inputBytes: input.count)
    let renderer = try TerminalMetalRenderer(device: device)
    let geometry = TerminalGeometry(backingScale: 2)
    let width = Int(32 * 2 + ceil(geometry.cellSize.width * 134 * 2))
    let height = Int(24 * 2 + ceil(geometry.cellSize.height * 45 * 2))
    guard let target = makeTexture(device, width: width, height: height) else { throw DiagnosticError.failed("texture unavailable") }
    let coldUsageBefore = try usage()
    let coldStart = DispatchTime.now().uptimeNanoseconds
    guard let cold = renderer.render(frame: frame, geometry: geometry, theme: .dark, target: target) else { throw DiagnosticError.failed("cold render unavailable") }
    cold.waitUntilCompleted()
    guard cold.status == .completed else { throw DiagnosticError.failed("cold command incomplete") }
    let coldEnd = DispatchTime.now().uptimeNanoseconds
    let coldUsageAfter = try usage()
    let warmUsageBefore = try usage()
    let warmStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<100 {
      guard let command = renderer.render(frame: frame, geometry: geometry, theme: .dark, target: target) else { throw DiagnosticError.failed("warm render unavailable") }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw DiagnosticError.failed("warm command incomplete") }
    }
    let warmEnd = DispatchTime.now().uptimeNanoseconds
    let warmUsageAfter = try usage()
    let clusters = Set(frame.cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }.map(\.text))
    let runs = try coreTextRuns(for: clusters)
    return [
      "round": round, "order": order, "fixture": fixture.name,
      "input_bytes": input.count, "input_sha256": inputHash,
      "feed_snapshot_cpu_seconds": cpuSeconds(feedUsageBefore, feedUsageAfter),
      "feed_snapshot_wall_seconds": seconds(feedEnd - feedStart),
      "atlas_cold_cpu_seconds": cpuSeconds(coldUsageBefore, coldUsageAfter),
      "atlas_cold_wall_seconds": seconds(coldEnd - coldStart),
      "warm_100_cpu_seconds": cpuSeconds(warmUsageBefore, warmUsageAfter),
      "warm_100_wall_seconds": seconds(warmEnd - warmStart),
      "actual": stats, "coretext": runs
    ]
  }

  static func validate(frame: VTFrame, fixture: Fixture, inputBytes: Int) throws -> [String: Any] {
    guard frame.columns == 134, frame.rows == 45 else { throw DiagnosticError.failed("grid mismatch \(fixture.name)") }
    let heads = frame.cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }
    let tails = frame.cells.filter { $0.wide.rawValue == 2 || $0.wide.rawValue == 3 }
    guard heads.count == fixture.expectedHeads, tails.count == fixture.expectedWideTails else {
      throw DiagnosticError.failed("cell invariant mismatch \(fixture.name) heads=\(heads.count) tails=\(tails.count)")
    }
    let clusters = Set(heads.map(\.text))
    let bytes = fixture.data.count
    guard bytes == inputBytes else { throw DiagnosticError.failed("byte mismatch \(fixture.name)") }
    for row in 0..<frame.rows {
      let start = row * frame.columns
      let end = start + frame.columns
      let actual = frame.cells[start..<end].filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }.map(\.text).joined()
      let expected: String
      if row < fixture.rows.count {
        let scalars = fixture.rows[row].unicodeScalars
        expected = scalars.count >= 2 ? String(scalars.dropLast(2)) : String(scalars)
      } else {
        expected = ""
      }
      guard actual == expected else { throw DiagnosticError.failed("content mismatch \(fixture.name) row=\(row)") }
    }
    return ["nonempty_heads": heads.count, "wide_tails": tails.count, "unique_clusters": clusters.count, "visible_cells": heads.count + tails.count, "input_bytes": bytes]
  }

  static func coreTextRuns(for clusters: Set<String>) throws -> [[String: Any]] {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
    let attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTLigatureAttributeName as String): 0
    ]
    var result: [[String: Any]] = []
    for cluster in clusters.sorted() {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: cluster, attributes: attrs))
      var glyphs = 0
      var ids: [UInt16] = []
      var names: [String] = []
      for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
        let count = CTRunGetGlyphCount(run)
        glyphs += count
        var runGlyphs = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRangeMake(0, count), &runGlyphs)
        ids.append(contentsOf: runGlyphs)
        let runAttrs = CTRunGetAttributes(run) as NSDictionary
        guard let value = runAttrs[kCTFontAttributeName as NSAttributedString.Key] else { throw DiagnosticError.failed("CoreText run has no font") }
        let runFont = value as! CTFont
        names.append(CTFontCopyPostScriptName(runFont) as String)
      }
      guard !names.isEmpty else { throw DiagnosticError.failed("CoreText returned no font for cluster") }
      guard glyphs > 0 else { throw DiagnosticError.failed("CoreText returned zero glyphs for cluster") }
      guard !ids.contains(0) else { throw DiagnosticError.failed("CoreText returned zero glyph ID for cluster") }
      result.append(["cluster": cluster, "glyph_count": glyphs, "glyph_ids": ids, "zero_glyph": ids.contains(0), "font_names": Array(Set(names)).sorted(), "ligatures": 0])
    }
    return result
  }

  static func usage() throws -> RUsage {
    var r = rusage()
    guard getrusage(RUSAGE_SELF, &r) == 0 else { throw DiagnosticError.failed("getrusage failed") }
    return RUsage(user: Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1e6, system: Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1e6)
  }
  static func cpuSeconds(_ before: RUsage, _ after: RUsage) -> Double {
    let delta = (after.user - before.user) + (after.system - before.system)
    precondition(delta >= 0, "rusage counter decreased")
    return delta
  }
  static func seconds(_ n: UInt64) -> Double { Double(n) / 1_000_000_000 }
  static func makeTexture(_ d: MTLDevice, width: Int, height: Int) -> MTLTexture? { let x = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false); x.usage = [.renderTarget, .shaderRead]; return d.makeTexture(descriptor: x) }
  static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func sourceHash() throws -> String { let url = URL(fileURLWithPath: #filePath); return sha256(try Data(contentsOf: url)) }
}
#else
import Foundation
@main struct TerminalUnicodeDiagnostic { static func main() { print("WEB_STUDIO_VT required") } }
#endif
