import AppKit
import CryptoKit
import Foundation
import Metal

@main struct FontFrameEquivalence {
  static func main() throws {
    let args = CommandLine.arguments
    guard let oi = args.firstIndex(of: "--output"), oi + 1 < args.count else { throw error("missing --output") }
    let out = URL(fileURLWithPath: args[oi + 1], isDirectory: true)
    let fm = FileManager.default
    if fm.fileExists(atPath: out.path) { throw error("output exists") }
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    guard let device = MTLCreateSystemDefaultDevice() else { throw error("no Metal device") }
    let traits = ["regular", "bold", "italic", "bold-italic"]
    let fixture = traits.enumerated().map { i, trait in
      let sgr = ["0", "1", "3", "1;3"][i]
      return "\u{1b}[0m\u{1b}[\(sgr)m\(trait) ASCII 中文 e\u{301} 👩‍💻\u{1b}[0m\r\n"
    }.joined()
    let core = TerminalVTCore(columns: 45, rows: 8)
    core.feed(Data(fixture.utf8))
    guard let traitFrame = core.snapshot() else { throw error("trait fixture missing") }
    for (row, trait) in traits.enumerated() {
      let cells = traitFrame.cells[(row * traitFrame.columns)..<min((row + 1) * traitFrame.columns, traitFrame.cells.count)]
      let text = cells.map(\.text).joined()
      guard text.contains(trait), text.contains("ASCII"), text.contains("中文"), text.contains("e\u{301}"), text.contains("👩‍💻") else {
        let scalars=text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
        let flags=cells.filter { !$0.text.isEmpty }.map { "\($0.text):b\($0.bold):i\($0.italic)" }.joined(separator: "|")
        throw error("trait text missing row=\(row) trait=\(trait) scalars=\(scalars) flags=\(flags)")
      }
      let nonEmpty = cells.filter { !$0.text.isEmpty && $0.wide.rawValue != 2 && $0.wide.rawValue != 3 }
      guard !nonEmpty.isEmpty, nonEmpty.allSatisfy({ ($0.bold, $0.italic) == (trait == "bold" || trait == "bold-italic", trait == "italic" || trait == "bold-italic") }) else { throw error("trait flags missing") }
    }
    let renderer = try TerminalMetalRenderer(device: device)
    for theme in [("dark", TerminalTheme.dark), ("light", TerminalTheme.light)] {
      for scale in [CGFloat(1), CGFloat(2)] {
        guard core.setTheme(theme.1), let frame = core.snapshot() else { throw error("missing themed frame") }
        let geometry=TerminalGeometry(backingScale: scale); let w=Int(32 * scale + ceil(geometry.cellSize.width * CGFloat(frame.columns) * scale)); let h=Int(24 * scale + ceil(geometry.cellSize.height * CGFloat(frame.rows) * scale))
        let secondCore=TerminalVTCore(columns:45,rows:8); secondCore.feed(Data((fixture+"EXTRA 新字\r\n").utf8)); guard secondCore.setTheme(theme.1), let frame2=secondCore.snapshot(), let texture=makeTexture(device,w,h), let texture2=makeTexture(device,w,h), let first=renderer.render(frame:frame,geometry:geometry,theme:theme.1,target:texture), let second=renderer.render(frame:frame2,geometry:geometry,theme:theme.1,target:texture2) else { throw error("render unavailable") }
        first.waitUntilCompleted(); second.waitUntilCompleted(); guard first.status == .completed, second.status == .completed else { throw error("command incomplete") }
        var bytes=[UInt8](repeating:0,count:w*h*4); texture.getBytes(&bytes,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0); try write(bytes,out.appendingPathComponent("\(theme.0)-\(Int(scale))x-combined.bgra"))
        var bytes2=[UInt8](repeating:0,count:w*h*4); texture2.getBytes(&bytes2,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0); try write(bytes2,out.appendingPathComponent("\(theme.0)-\(Int(scale))x-extra.bgra"))
      }
    }
    let history = (0..<40).map { "HIST-\($0 % 10)-\($0) 中文\r\n" }.joined()
    core.feed(Data(history.utf8)); guard core.setTheme(.dark), core.resize(columns: 30, rows: 6, cellWidthPixels: 17, cellHeightPixels: 35), let beforeScroll=core.snapshot(), beforeScroll.scrollbar.total > beforeScroll.scrollbar.length else { throw error("resize/history failed") }
    core.scroll(toOffset: 0)
    let resizeGeometry=TerminalGeometry(backingScale:1); let resizeWidth=Int(32 + ceil(resizeGeometry.cellSize.width * 30)); let resizeHeight=Int(24 + ceil(resizeGeometry.cellSize.height * 6))
    guard let changed=core.snapshot(), changed.visibleData != beforeScroll.visibleData, changed.scrollbar.offset != beforeScroll.scrollbar.offset, let tex=makeTexture(device,resizeWidth,resizeHeight), let command=renderer.render(frame:changed,geometry:resizeGeometry,theme:.dark,target:tex) else { throw error("resize/scroll render unavailable") }
    command.waitUntilCompleted(); guard command.status == .completed else { throw error("resize/scroll incomplete") }
    var changedBytes=[UInt8](repeating:0,count:resizeWidth*resizeHeight*4); tex.getBytes(&changedBytes,bytesPerRow:resizeWidth*4,from:MTLRegionMake2D(0,0,resizeWidth,resizeHeight),mipmapLevel:0); try write(changedBytes,out.appendingPathComponent("resize-scroll.bgra"))
    print("font frame equivalence smoke passed; traits=\(traits.count), themes=2, scales=2, resize-scroll=checked")
  }
  static func makeTexture(_ d: MTLDevice,_ w:Int,_ h:Int)->MTLTexture? { let x=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false); x.usage=[.renderTarget,.shaderRead]; return d.makeTexture(descriptor:x) }
  static func write(_ bytes:[UInt8],_ url:URL)throws { let data=Data(bytes); try data.write(to:url,options:.withoutOverwriting); let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(); try (digest+"\n").data(using:.utf8)!.write(to:url.appendingPathExtension("sha256"),options:.withoutOverwriting) }
  static func error(_ text:String)->NSError { NSError(domain:"FontFrameEquivalence",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
}
