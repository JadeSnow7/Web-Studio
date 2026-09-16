#if WEB_STUDIO_VT
  import AppKit
  import CoreText
  import Foundation
  import Metal
  import MetalKit

  public final class TerminalMetalRenderer {
    public enum Error: Swift.Error, CustomStringConvertible {
      case noDevice, noCommandQueue
      case shader(String)
      case pipeline(String)
      public var description: String {
        switch self {
        case .noDevice: return "Metal device unavailable"
        case .noCommandQueue: return "Metal command queue unavailable"
        case .shader(let s): return "Metal shader error: \(s)"
        case .pipeline(let s): return "Metal pipeline error: \(s)"
        }
      }
    }
    private struct Vertex {
      var position: SIMD2<Float>
      var uv: SIMD2<Float>
      var color: SIMD4<Float>
      var textured: UInt32
    }
    private struct Glyph {
      var uv: SIMD4<Float>
      var size: SIMD2<Float>
      var bearing: SIMD2<Float>
      var advance: Float
      var isColor: Bool
    }
    private final class PreparedAtlas {
      private typealias Rasterized = (CGImage, CGSize, CGPoint, CGFloat, Bool)
      private static var rasterCache: [String: Rasterized] = [:]
      private static var rasterOrder: [String] = []
      private static let rasterLock = NSLock()
      let size = 2048
      let textures: [MTLTexture]
      let entries: [String: (page: Int, glyph: Glyph)]
      private let device: MTLDevice
      init(
        device: MTLDevice, requests: [(key: String, text: String, font: NSFont, scale: CGFloat)]
      ) throws {
        self.device = device
        let pageSize = 2048
        var images: [(key: String, image: CGImage, bearing: CGPoint, advance: CGFloat, isColor: Bool)] = []
        images.reserveCapacity(requests.count)
        for request in requests {
          let item: Rasterized?
          Self.rasterLock.lock()
          item = Self.rasterCache[request.key]
          Self.rasterLock.unlock()
          let raster = item ?? Self.rasterize(request.text, font: request.font, scale: request.scale)
          guard let raster else {
            continue
          }
          if item == nil {
            Self.rasterLock.lock()
            Self.rasterCache[request.key] = raster
            Self.rasterOrder.removeAll { $0 == request.key }
            Self.rasterOrder.append(request.key)
            if Self.rasterOrder.count > 1024 {
              let evicted = Self.rasterOrder.removeFirst()
              Self.rasterCache.removeValue(forKey: evicted)
            }
            Self.rasterLock.unlock()
          }
          images.append((request.key, raster.0, raster.2, raster.3, raster.4))
        }
        var pagePixels: [[UInt8]] = []
        var nextX = 1, nextY = 1, rowHeight = 0
        var page = -1
        var builtEntries: [String: (page: Int, glyph: Glyph)] = [:]
        for item in images {
          if page < 0 || !Self.fits(item.image.width, item.image.height, x: nextX, y: nextY, rowHeight: rowHeight) {
            pagePixels.append(Array(repeating: 0, count: pageSize * pageSize * 4))
            page += 1
            nextX = 1
            nextY = 1
            rowHeight = 0
          }
          if item.image.width + 2 > pageSize || item.image.height + 2 > pageSize { continue }
          if nextX + item.image.width + 1 > pageSize {
            nextX = 1
            nextY += rowHeight + 1
            rowHeight = 0
          }
          if nextY + item.image.height + 1 > pageSize { continue }
          Self.copy(item.image, into: &pagePixels[page], size: pageSize, x: nextX, y: nextY)
          builtEntries[item.key] = (
            page: page,
            glyph: Glyph(
              uv: SIMD4(
                Float(nextX) / Float(pageSize), Float(nextY) / Float(pageSize),
                Float(item.image.width) / Float(pageSize), Float(item.image.height) / Float(pageSize)),
              size: SIMD2(Float(item.image.width), Float(item.image.height)),
              bearing: SIMD2(Float(item.bearing.x), Float(item.bearing.y)),
              advance: Float(item.advance), isColor: item.isColor))
          nextX += item.image.width + 1
          rowHeight = max(rowHeight, item.image.height)
        }
        var builtTextures: [MTLTexture] = []
        builtTextures.reserveCapacity(pagePixels.count)
        for pixels in pagePixels {
          let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: pageSize, height: pageSize, mipmapped: false)
          d.usage = [.shaderRead]
          guard let texture = device.makeTexture(descriptor: d) else {
            throw TerminalMetalRenderer.Error.shader("unable to allocate glyph atlas page")
          }
          pixels.withUnsafeBytes {
            texture.replace(
              region: MTLRegionMake2D(0, 0, pageSize, pageSize), mipmapLevel: 0,
              withBytes: $0.baseAddress!, bytesPerRow: pageSize * 4)
          }
          builtTextures.append(texture)
        }
        textures = builtTextures
        entries = builtEntries
      }
      private static func fits(_ width: Int, _ height: Int, x: Int, y: Int, rowHeight: Int) -> Bool {
        let pageSize = 2048
        guard width + 2 <= pageSize, height + 2 <= pageSize else { return false }
        if x + width + 1 > pageSize { return y + rowHeight + height + 2 <= pageSize }
        return y + height + 1 <= pageSize
      }
      private static func rasterize(_ text: String, font: NSFont, scale: CGFloat) -> (
        CGImage, CGSize, CGPoint, CGFloat, Bool
      )? {
        let line = CTLineCreateWithAttributedString(
          NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .ligature: 0]))
        var a: CGFloat = 0
        var d: CGFloat = 0
        var l: CGFloat = 0
        let adv = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        let pad: CGFloat = 2
        let w = max(1, Int(ceil((adv + pad * 2) * scale)))
        let h = max(1, Int(ceil((a + d + pad * 2) * scale)))
        guard
          let c = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setAllowsAntialiasing(true)
        c.scaleBy(x: scale, y: scale)
        c.setFillColor(NSColor.white.cgColor)
        c.textPosition = CGPoint(x: pad, y: pad + d)
        CTLineDraw(line, c)
        guard let image = c.makeImage() else { return nil }
        return (
          image, CGSize(width: w, height: h), CGPoint(x: -pad * scale, y: -(a + pad) * scale),
          adv * scale, Self.hasColorGlyphs(line)
        )
      }
      private static func hasColorGlyphs(_ line: CTLine) -> Bool {
        let runs = CTLineGetGlyphRuns(line) as NSArray
        for case let run as CTRun in runs {
          let attrs = CTRunGetAttributes(run) as NSDictionary
          guard let value = attrs[kCTFontAttributeName as NSAttributedString.Key] else { continue }
          let font = value as! CTFont
          if CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait) { return true }
        }
        return false
      }
      private static func copy(_ image: CGImage, into pixels: inout [UInt8], size: Int, x: Int, y: Int) {
        pixels.withUnsafeMutableBytes { raw in
          guard let base = raw.baseAddress,
            let c = CGContext(
              data: base, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { return }
          c.interpolationQuality = .high
          c.draw(
            image,
            in: CGRect(x: x, y: size - y - image.height, width: image.width, height: image.height))
        }
      }
    }
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
      sampler: MTLSamplerState
    private var atlas: PreparedAtlas?
    private let inflightGate = DispatchSemaphore(value: 3)
    public private(set) var lastError: Swift.Error?
    public init(device supplied: MTLDevice? = nil) throws {
      guard let d = supplied ?? MTLCreateSystemDefaultDevice() else { throw Error.noDevice }
      device = d
      guard let q = d.makeCommandQueue() else { throw Error.noCommandQueue }
      queue = q
      let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V{float2 p;float2 uv;float4 c;uint textured;}; struct O{float4 p[[position]];float2 uv;float4 c;uint textured;};
        vertex O vertex_main(const device V* v[[buffer(0)]],uint id[[vertex_id]]){O o;o.p=float4(v[id].p,0,1);o.uv=v[id].uv;o.c=v[id].c;o.textured=v[id].textured;return o;}
        fragment float4 fragment_main(O i[[stage_in]],texture2d<float>a[[texture(0)]],sampler s[[sampler(0)]]){float4 glyph=i.textured?a.sample(s,i.uv):float4(1);float3 rgb=i.textured==2?glyph.rgb*i.c.a:glyph.a*i.c.rgb*i.c.a;return float4(rgb,i.c.a*glyph.a);}
        """
      let lib: MTLLibrary
      do {
        lib = try d.makeLibrary(source: source, options: nil)
      } catch {
        throw Error.shader("failed to compile Metal shader: \(error)")
      }
      guard let vf = lib.makeFunction(name: "vertex_main"),
        let ff = lib.makeFunction(name: "fragment_main")
      else { throw Error.shader("failed to find vertex_main/fragment_main") }
      let x = MTLRenderPipelineDescriptor()
      x.vertexFunction = vf
      x.fragmentFunction = ff
      x.colorAttachments[0].pixelFormat = .bgra8Unorm
      x.colorAttachments[0].isBlendingEnabled = true
      x.colorAttachments[0].rgbBlendOperation = .add
      x.colorAttachments[0].alphaBlendOperation = .add
      x.colorAttachments[0].sourceRGBBlendFactor = .one
      x.colorAttachments[0].sourceAlphaBlendFactor = .one
      x.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      x.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      do { pipeline = try d.makeRenderPipelineState(descriptor: x) } catch {
        throw Error.pipeline(String(describing: error))
      }
      let sd = MTLSamplerDescriptor()
      sd.minFilter = .linear
      sd.magFilter = .linear
      sd.sAddressMode = .clampToEdge
      sd.tAddressMode = .clampToEdge
      guard let sampler = d.makeSamplerState(descriptor: sd) else {
        throw Error.shader("unable to allocate glyph sampler")
      }
      self.sampler = sampler
    }
    @discardableResult public func render(
      frame: VTFrame, geometry: TerminalGeometry, theme: TerminalTheme, target: MTLTexture,
      selection: CGRect? = nil, drawable: MTLDrawable? = nil,
      cursorPhaseVisible: Bool = true,
      completion: ((MTLCommandBuffer) -> Void)? = nil
    ) -> MTLCommandBuffer? {
      guard inflightGate.wait(timeout: .now()) == .success else { return nil }
      var permitHandedOff = false
      defer {
        if !permitHandedOff { inflightGate.signal() }
      }
      let scale = max(CGFloat(1), geometry.backingScale)
      var requests: [String: (key: String, text: String, font: NSFont, scale: CGFloat)] = [:]
      for cell in frame.cells where !cell.text.isEmpty && cell.wide.rawValue != 2 && cell.wide.rawValue != 3 {
        let f = font(for: cell)
        let key = "\(f.fontName)|\(f.pointSize)|\(scale)|\(cell.text)"
        requests[key] = (key, cell.text, f, scale)
      }
      let requiredKeys = Set(requests.keys)
      if atlas == nil || !requiredKeys.allSatisfy({ atlas?.entries[$0] != nil }) {
        do {
          atlas = try PreparedAtlas(device: device, requests: Array(requests.values))
          lastError = nil
        } catch {
          lastError = error
          return nil
        }
      }
      let prepared = atlas
      guard let command = queue.makeCommandBuffer(),
        let pass = MTLRenderPassDescriptor() as MTLRenderPassDescriptor?
      else { return nil }
      let gate = inflightGate
      command.addCompletedHandler { completed in
        gate.signal()
        completion?(completed)
      }
      let bg = frame.background
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      pass.colorAttachments[0].clearColor = MTLClearColor(
        red: Double(bg.red) / 255, green: Double(bg.green) / 255, blue: Double(bg.blue) / 255,
        alpha: 1)
      guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
      encoder.setRenderPipelineState(pipeline)
      let cw = Float(geometry.cellPixelSize.width)
      let ch = Float(geometry.cellPixelSize.height)
      let ix = Float(geometry.contentInset.left) * Float(scale)
      let iy = Float(geometry.contentInset.top) * Float(scale)
      let tw = Float(target.width)
      let th = Float(target.height)
      var backgroundVertices = [Vertex]()
      var glyphVertices: [Int: [Vertex]] = [:]
      var cursorUnderlayVertices = [Vertex]()
      var overlayVertices = [Vertex]()
      var decorationVertices = [Vertex]()
      func col(_ c: VTColor) -> SIMD4<Float> {
        SIMD4(Float(c.red) / 255, Float(c.green) / 255, Float(c.blue) / 255, 1)
      }
      func quad(
        _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: SIMD4<Float>, _ u: SIMD4<Float>,
        _ textured: UInt32, into vertices: inout [Vertex]
      ) {
        let x0 = x / tw * 2 - 1
        let x1 = (x + w) / tw * 2 - 1
        let y0 = 1 - y / th * 2
        let y1 = 1 - (y + h) / th * 2
        let a = u.x
        let b = u.y
        let aa = u.x + u.z
        let bb = u.y + u.w
        vertices += [
          Vertex(position: SIMD2(x0, y0), uv: SIMD2(a, b), color: c, textured: textured),
          Vertex(position: SIMD2(x1, y0), uv: SIMD2(aa, b), color: c, textured: textured),
          Vertex(position: SIMD2(x0, y1), uv: SIMD2(a, bb), color: c, textured: textured),
          Vertex(position: SIMD2(x1, y0), uv: SIMD2(aa, b), color: c, textured: textured),
          Vertex(position: SIMD2(x1, y1), uv: SIMD2(aa, bb), color: c, textured: textured),
          Vertex(position: SIMD2(x0, y1), uv: SIMD2(a, bb), color: c, textured: textured),
        ]
      }
      for i in 0..<min(frame.cells.count, frame.columns * frame.rows) {
        let cell = frame.cells[i]
        let cx = i % frame.columns
        let ry = i / frame.columns
        let x = ix + Float(cx) * cw
        let y = iy + Float(ry) * ch
        var bg = cell.background
        if cell.inverse { bg = cell.foreground }
        if cell.selected { bg = theme.selection }
        quad(x, y, cw * (cell.wide.rawValue == 1 ? 2 : 1), ch, col(bg), SIMD4(0, 0, 0, 0), 0, into: &backgroundVertices)
      }
      if let s = selection {
        quad(
          Float(s.minX) * Float(scale), Float(s.minY) * Float(scale), Float(s.width) * Float(scale),
          Float(s.height) * Float(scale), col(theme.selection), SIMD4(0, 0, 0, 0), 0,
          into: &cursorUnderlayVertices)
      }
      let cursorColumn = frame.cursor.wideTail ? max(0, frame.cursor.x - 1) : frame.cursor.x
      let cursorCell = cursorPhaseVisible && frame.cursor.viewportHasValue && frame.cursor.visible && frame.cursor.visualStyle == 1
        ? frame.cursor.y * frame.columns + cursorColumn : -1
      if cursorCell >= 0, cursorCell < frame.cells.count {
        let cx = ix + Float(cursorColumn) * cw
        let cy = iy + Float(frame.cursor.y) * ch
        let width = cw * (frame.cursor.wideTail ? 2 : 1)
        quad(cx, cy, width, ch, col(frame.cursorColor ?? theme.cursor), SIMD4(0, 0, 0, 0), 0, into: &cursorUnderlayVertices)
      }
      for i in 0..<min(frame.cells.count, frame.columns * frame.rows) {
        let cell = frame.cells[i]
        let cx = i % frame.columns
        let ry = i / frame.columns
        let x = ix + Float(cx) * cw
        var fg = cell.foreground
        var bg = cell.background
        if cell.inverse { swap(&fg, &bg) }
        if cell.faint {
          fg = VTColor(
            (Int(fg.red) + Int(bg.red)) / 2, (Int(fg.green) + Int(bg.green)) / 2,
            (Int(fg.blue) + Int(bg.blue)) / 2)
        }
        if cell.hidden { fg = bg }
        if cell.selected { bg = theme.selection }
        if i == cursorCell { swap(&fg, &bg) }
        let f = font(for: cell)
        let key = "\(f.fontName)|\(f.pointSize)|\(scale)|\(cell.text)"
        let baseline = iy + Float(ry) * ch + Float(geometry.baseline) * Float(scale)
        if !cell.hidden && cell.wide.rawValue != 2 && cell.wide.rawValue != 3,
          !cell.text.isEmpty, let item = prepared?.entries[key]
        {
          let g = item.glyph
          quad(
            x + g.bearing.x, baseline + g.bearing.y, g.size.x, g.size.y, col(fg), g.uv,
            g.isColor ? 2 : 1, into: &glyphVertices[item.page, default: []])
        }
        if cell.hidden { continue }
        let occupiedWidth = cell.wide.rawValue == 1 ? cw * 2 : cw
        let lineColor = col(cell.hasUnderline ? cell.underline : fg)
        let lineY = baseline + 1
        if cell.underlineStyle > 0 {
          let thickness = max(1, Float(scale))
          switch cell.underlineStyle {
          case 2:
            quad(x, lineY, occupiedWidth, thickness, lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
            quad(x, lineY + thickness * 2, occupiedWidth, thickness, lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
          case 3:
            let wavelength = max(4, occupiedWidth / 3)
            for segment in stride(from: 0 as Float, to: occupiedWidth, by: thickness) {
              let phase = Double(segment / wavelength) * Double.pi * 2
              let waveY = lineY + Float(sin(phase)) * thickness
              quad(x + segment, waveY, min(thickness, occupiedWidth - segment), thickness,
                lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
            }
          case 4:
            for segment in stride(from: 0 as Float, to: occupiedWidth, by: max(2, thickness * 3)) {
              quad(x + segment, lineY, min(thickness, occupiedWidth - segment), thickness, lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
            }
          case 5:
            for segment in stride(from: 0 as Float, to: occupiedWidth, by: max(4, thickness * 6)) {
              quad(x + segment, lineY, min(max(2, thickness * 4), occupiedWidth - segment), thickness, lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
            }
          default:
            quad(x, lineY, occupiedWidth, thickness, lineColor, SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
          }
        }
        if cell.strikethrough {
          quad(x, baseline - ch * 0.42, occupiedWidth, max(1, Float(scale)), col(fg), SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
        }
        if cell.overline {
          quad(x, iy + Float(ry) * ch + max(1, Float(scale)), occupiedWidth, max(1, Float(scale)), col(fg), SIMD4(0, 0, 0, 0), 0, into: &decorationVertices)
        }
      }
      if cursorPhaseVisible && frame.cursor.viewportHasValue && frame.cursor.visible {
        let x = ix + Float(cursorColumn) * cw
        let y = iy + Float(frame.cursor.y) * ch
        let cursorWidth = cw * (frame.cursor.wideTail ? 2 : 1)
        let cursorColor = col(frame.cursorColor ?? theme.cursor)
        switch frame.cursor.visualStyle {
        case 0: quad(x, y, max(2, min(3, cw * 0.12)), ch, cursorColor, SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
        case 1: break
        case 2:
          quad(
            x, y + ch - max(2, ch * 0.12), cursorWidth, max(2, ch * 0.12), cursorColor,
            SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
        case 3:
          let t = max(2, min(3, cw * 0.12))
          quad(x, y, cursorWidth, t, cursorColor, SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
          quad(x, y + ch - t, cursorWidth, t, cursorColor, SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
          quad(x, y, t, ch, cursorColor, SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
          quad(x + cursorWidth - t, y, t, ch, cursorColor, SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
        default:
          quad(
            x, y, cursorWidth, ch, SIMD4(cursorColor.x, cursorColor.y, cursorColor.z, 0.42),
            SIMD4(0, 0, 0, 0), 0, into: &overlayVertices)
        }
      }
      func draw(_ vertices: [Vertex], texture: MTLTexture?) {
        guard !vertices.isEmpty,
          let buffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride,
            options: .storageModeShared)
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
      }
      draw(backgroundVertices, texture: nil)
      draw(cursorUnderlayVertices, texture: nil)
      for page in glyphVertices.keys.sorted() {
        guard let atlas = prepared, page >= 0, page < atlas.textures.count,
          let vertices = glyphVertices[page] else { continue }
        let texture = atlas.textures[page]
        draw(vertices, texture: texture)
      }
      draw(decorationVertices, texture: nil)
      draw(overlayVertices, texture: nil)
      encoder.endEncoding()
      if let drawable { command.present(drawable) }
      command.commit()
      permitHandedOff = true
      return command
    }
    private func font(for cell: VTCell) -> NSFont {
      let base = NSFont.monospacedSystemFont(ofSize: 13, weight: cell.bold ? .bold : .regular)
      if cell.italic { return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) }
      return base
    }
    public func prepareGlyphs(
      frame: VTFrame, font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      scale: CGFloat = 1
    ) {
      var requests: [String: (key: String, text: String, font: NSFont, scale: CGFloat)] = [:]
      for c in frame.cells where !c.text.isEmpty {
        let key = "\(font.fontName)|\(font.pointSize)|\(scale)|\(c.text)"
        requests[key] = (key, c.text, font, scale)
      }
      if atlas == nil || !requests.keys.allSatisfy({ atlas?.entries[$0] != nil }) {
        do {
          atlas = try PreparedAtlas(device: device, requests: Array(requests.values))
        } catch {
          lastError = error
        }
      }
    }
  }
#endif
