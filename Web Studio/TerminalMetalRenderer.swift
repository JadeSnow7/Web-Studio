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
    /// Atlas lookup key: the (font name, point size) identity of a renderer font id, the scale bits and the grapheme text.
    private struct GlyphKey: Hashable {
      var font: UInt32
      var scale: UInt64
      var text: String
    }
    private struct AtlasEntry {
      var page: Int
      var glyph: Glyph
    }
    private typealias GlyphRequest = (key: GlyphKey, text: String, font: NSFont, scale: CGFloat)
    private struct RasterItem {
      var key: GlyphKey
      var image: CGImage
      var bearing: CGPoint
      var advance: CGFloat
      var isColor: Bool
    }
    /// Process-wide identity of a rasterized glyph bitmap; independent of any renderer's font ids.
    private struct RasterKey: Hashable {
      var font: String
      var size: UInt64
      var scale: UInt64
      var text: String
    }
    private typealias Rasterized = (CGImage, CGSize, CGPoint, CGFloat, Bool)
    /// Thread-safe O(1) LRU: lookup (which refreshes recency), insert and eviction of the least recently used entry are all
    /// constant time (doubly linked list over a slot array plus a key index).
    final class GlyphLRU<Key: Hashable, Value> {
      private struct Node {
        var key: Key
        var value: Value
        var newer: Int32
        var older: Int32
      }
      let capacity: Int
      private let lock = NSLock()
      private var nodes: [Node] = []
      private var slots: [Key: Int32] = [:]
      private var free: [Int32] = []
      private var newest: Int32 = -1
      private var oldest: Int32 = -1
      init(capacity: Int) { self.capacity = max(1, capacity) }
      var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
      }
      private func unlink(_ i: Int32) {
        let node = nodes[Int(i)]
        if node.newer >= 0 { nodes[Int(node.newer)].older = node.older } else { newest = node.older }
        if node.older >= 0 { nodes[Int(node.older)].newer = node.newer } else { oldest = node.newer }
      }
      private func linkNewest(_ i: Int32) {
        nodes[Int(i)].newer = -1
        nodes[Int(i)].older = newest
        if newest >= 0 { nodes[Int(newest)].newer = i } else { oldest = i }
        newest = i
      }
      func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = slots[key] else { return nil }
        if i != newest {
          unlink(i)
          linkNewest(i)
        }
        return nodes[Int(i)].value
      }
      func insert(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let i = slots[key] {
          nodes[Int(i)].value = value
          if i != newest {
            unlink(i)
            linkNewest(i)
          }
          return
        }
        if slots.count >= capacity, oldest >= 0 {
          let victim = oldest
          unlink(victim)
          slots.removeValue(forKey: nodes[Int(victim)].key)
          free.append(victim)
        }
        let node = Node(key: key, value: value, newer: -1, older: -1)
        let i: Int32
        if let reused = free.popLast() {
          i = reused
          nodes[Int(i)] = node
        } else {
          i = Int32(nodes.count)
          nodes.append(node)
        }
        slots[key] = i
        linkNewest(i)
      }
    }
    /// One atlas page of a `PreparedAtlas` build: a power-of-two square texture and the glyph placements inside it.
    private struct PagePlan {
      var size: Int
      var placements: [(item: Int, x: Int, y: Int)]
      var byteCount: Int { size * size * 4 }
    }
    /// Shelf packer with a 1-px zero gutter on every side of every glyph (the origin gutter is the (1, 1) start).
    private struct ShelfCursor {
      var size: Int
      var x = 1, y = 1, rowHeight = 0
      init(size: Int) { self.size = size }
      mutating func place(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width + 2 <= size, height + 2 <= size else { return nil }
        var px = x, py = y, row = rowHeight
        if px + width + 1 > size {
          px = 1
          py += row + 1
          row = 0
        }
        guard py + height + 1 <= size else { return nil }
        x = px + width + 1
        y = py
        rowHeight = max(row, height)
        return (px, py)
      }
    }
    /// Append-only glyph atlas. Every texture is written exactly once, before any command buffer can reference it, and is
    /// never modified afterwards, so in-flight frames keep sampling stable pages while later misses append new ones.
    /// Table indices are stable for the life of the object; a replacement atlas (compaction) starts a new generation.
    private final class PreparedAtlas {
      static let minPageSize = 64
      static let maxPageSize = 2048
      private static let rasters = GlyphLRU<RasterKey, Rasterized>(capacity: 1024)
      private(set) var textures: [MTLTexture] = []
      private(set) var table: [AtlasEntry] = []
      private(set) var index: [GlyphKey: Int32] = [:]
      private(set) var byteCount = 0
      /// True once pages were appended to an atlas that already had pages. Such an atlas draws its glyphs in cell order
      /// (page changes split the draw), because its pages no longer reflect one frame's packing order.
      private(set) var isIncremental = false
      private let device: MTLDevice
      init(device: MTLDevice) {
        self.device = device
      }
      /// Rasterizes (or fetches from the shared LRU) the bitmaps of `requests`, skipping glyphs that cannot be rasterized.
      static func rasterize(_ requests: [GlyphRequest], reusing known: [GlyphKey: RasterItem]) -> [RasterItem] {
        var items: [RasterItem] = []
        items.reserveCapacity(requests.count)
        for request in requests {
          if let reused = known[request.key] {
            items.append(reused)
            continue
          }
          let rasterKey = RasterKey(
            font: request.font.fontName, size: Double(request.font.pointSize).bitPattern,
            scale: Double(request.scale).bitPattern, text: request.text)
          let cached = Self.rasters.value(for: rasterKey)
          let raster = cached ?? Self.rasterize(request.text, font: request.font, scale: request.scale)
          guard let raster else { continue }
          if cached == nil { Self.rasters.insert(raster, for: rasterKey) }
          items.append(
            RasterItem(key: request.key, image: raster.0, bearing: raster.2, advance: raster.3, isColor: raster.4))
        }
        return items
      }
      /// Packed glyph rows should stay in the texel-row range a single 2048 page gives the same glyphs: at 1x the glyph
      /// quads sit exactly on a bilinear rounding tie in v, so how large the sampled texel rows are decides the last bit
      /// of some edge pixels (a baseline page whose glyphs start lower down differs from the usual one in those bits).
      /// A page is therefore only accepted when its packed height stays below this; larger pages hold the same glyphs in
      /// fewer rows.
      static let packedHeightBudget = 256
      /// Splits `items` into pages: each page takes the following items in order and gets the smallest power-of-two size
      /// (at least `minPageSize`, at most `maxPageSize`) into which they all pack within `packedHeightBudget` rows (the
      /// largest size takes whatever fits); oversized glyphs are skipped.
      static func plan(_ items: [RasterItem]) -> [PagePlan] {
        let placeable = items.indices.filter {
          items[$0].image.width + 2 <= maxPageSize && items[$0].image.height + 2 <= maxPageSize
        }
        var plans: [PagePlan] = []
        var start = 0
        while start < placeable.count {
          let rest = placeable[start...]
          var area = 0, widest = 0, tallest = 0
          for i in rest {
            let w = items[i].image.width, h = items[i].image.height
            area += (w + 1) * (h + 1)
            widest = max(widest, w + 2)
            tallest = max(tallest, h + 2)
          }
          var size = minPageSize
          while size < maxPageSize && (size < widest || size < tallest || size * size < area) { size *= 2 }
          while true {
            var cursor = ShelfCursor(size: size)
            var placements: [(item: Int, x: Int, y: Int)] = []
            for i in rest {
              guard let spot = cursor.place(width: items[i].image.width, height: items[i].image.height) else { break }
              placements.append((i, spot.x, spot.y))
            }
            let complete = placements.count == rest.count
            let height = cursor.y + cursor.rowHeight + 1
            if size == maxPageSize || (complete && height <= packedHeightBudget) {
              plans.append(PagePlan(size: size, placements: placements))
              start += placements.count
              break
            }
            size *= 2
          }
        }
        return plans
      }
      /// Builds one new texture per planned page and publishes them together with their glyph entries. Nothing is
      /// published when any allocation fails.
      func append(_ items: [RasterItem], plan: [PagePlan]) throws {
        var newTextures: [MTLTexture] = []
        var newEntries: [(key: GlyphKey, entry: AtlasEntry)] = []
        newTextures.reserveCapacity(plan.count)
        for (offset, page) in plan.enumerated() {
          let size = page.size
          var pixels = [UInt8](repeating: 0, count: size * size * 4)
          Self.draw(items, page: page, into: &pixels)
          let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
          d.usage = [.shaderRead]
          guard let texture = device.makeTexture(descriptor: d) else {
            throw TerminalMetalRenderer.Error.shader("unable to allocate glyph atlas page")
          }
          pixels.withUnsafeBytes {
            texture.replace(
              region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
              withBytes: $0.baseAddress!, bytesPerRow: size * 4)
          }
          newTextures.append(texture)
          for placed in page.placements {
            let item = items[placed.item]
            newEntries.append(
              (
                item.key,
                AtlasEntry(
                  page: textures.count + offset,
                  glyph: Glyph(
                    uv: SIMD4(
                      Float(placed.x) / Float(size), Float(placed.y) / Float(size),
                      Float(item.image.width) / Float(size), Float(item.image.height) / Float(size)),
                    size: SIMD2(Float(item.image.width), Float(item.image.height)),
                    bearing: SIMD2(Float(item.bearing.x), Float(item.bearing.y)),
                    advance: Float(item.advance), isColor: item.isColor))
              ))
          }
        }
        if !textures.isEmpty && !newTextures.isEmpty { isIncremental = true }
        textures.append(contentsOf: newTextures)
        table.reserveCapacity(table.count + newEntries.count)
        for added in newEntries {
          index[added.key] = Int32(table.count)
          table.append(added.entry)
        }
        byteCount += plan.reduce(0) { $0 + $1.byteCount }
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
      /// One bitmap context over the whole new page; each glyph is drawn at its integer placement.
      private static func draw(_ items: [RasterItem], page: PagePlan, into pixels: inout [UInt8]) {
        let size = page.size
        pixels.withUnsafeMutableBytes { raw in
          guard let base = raw.baseAddress,
            let c = CGContext(
              data: base, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { return }
          c.interpolationQuality = .high
          for placed in page.placements {
            let image = items[placed.item].image
            c.draw(
              image,
              in: CGRect(x: placed.x, y: size - placed.y - image.height, width: image.width, height: image.height))
          }
        }
      }
    }
    /// Frame-independent lookup state: a direct table for single-byte ASCII cells and the per-cell atlas indices of the frame being rendered.
    private final class GlyphLookup {
      static let asciiSlots = 4 * 128
      /// Atlas table index per (font slot << 7 | ASCII byte); -2 means not resolved yet for the current atlas and scale.
      let ascii = UnsafeMutablePointer<Int32>.allocate(capacity: asciiSlots)
      var asciiScaleBits: UInt64 = 0
      /// Resident font id per font slot; UInt32.max means the slot has not been resolved yet.
      let fontIDs = UnsafeMutablePointer<UInt32>.allocate(capacity: 4)
      /// Atlas table index (or -1) per grid cell of the frame being rendered.
      var cells: UnsafeMutablePointer<Int32>?
      var cellCapacity = 0
      init() {
        ascii.initialize(repeating: -2, count: Self.asciiSlots)
        fontIDs.initialize(repeating: UInt32.max, count: 4)
      }
      deinit {
        ascii.deallocate()
        fontIDs.deallocate()
        cells?.deallocate()
      }
      func resetASCII() {
        ascii.update(repeating: -2, count: Self.asciiSlots)
      }
      func reserveCells(_ count: Int) -> UnsafeMutablePointer<Int32> {
        if let cells, cellCapacity >= count { return cells }
        cells?.deallocate()
        let capacity = max(count, 1024)
        let allocated = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
        cells = allocated
        cellCapacity = capacity
        return allocated
      }
    }
    private struct FontIdentity: Hashable {
      var name: String
      var size: UInt64
    }
    /// Shared-storage vertex buffers, one per in-flight slot (grow-only). A slot belongs to exactly one in-flight command
    /// buffer: it is released from that buffer's completed handler (or on the early-return paths of `render`), so the CPU never
    /// rewrites memory the GPU may still read.
    private final class VertexRing {
      static let slots = 3
      private let lock = NSLock()
      private var free: UInt8 = 0b111
      private var buffers: [MTLBuffer?] = [nil, nil, nil]
      func claim() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        for slot in 0..<Self.slots where free & (1 << UInt8(slot)) != 0 {
          free &= ~(1 << UInt8(slot))
          return slot
        }
        return nil
      }
      func release(_ slot: Int) {
        lock.lock()
        free |= 1 << UInt8(slot)
        lock.unlock()
      }
      /// Only the owner of a claimed slot may call this; the slot's buffer is replaced by a larger one when too small.
      func buffer(slot: Int, minimumLength: Int, device: MTLDevice) -> MTLBuffer? {
        if let buffer = buffers[slot], buffer.length >= minimumLength { return buffer }
        let previous = buffers[slot]?.length ?? 0
        let length = (max(minimumLength, previous + previous / 2, 1 << 16) + 0xFFFF) & ~0xFFFF
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffers[slot] = buffer
        return buffer
      }
    }
    /// Consecutive glyph quads (in cell order) that sample the same atlas page: `start`/`count` are vertex indices.
    private struct GlyphRun {
      var page: Int32
      var start: Int32
      var count: Int32
    }
    /// Per-frame vertex arrays kept between frames so steady-state rendering appends into existing capacity.
    private final class VertexScratch {
      var background: [Vertex] = []
      var underlay: [Vertex] = []
      var glyphs: [Vertex] = []
      var runs: [GlyphRun] = []
      var decorations: [Vertex] = []
      var overlay: [Vertex] = []
    }
    private static let unitFloats: [Float] = (0...255).map { Float($0) / 255 }
    private let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
      sampler: MTLSamplerState
    /// Appending misses mutates the current atlas in place (indices stay valid); only a replacement (compaction) is a new
    /// generation, and it must invalidate the ASCII table.
    private var atlas: PreparedAtlas? {
      didSet { lookup.resetASCII() }
    }
    /// Growth bounds: when appending a miss page would exceed either limit, the atlas is compacted (rebuilt once from the
    /// glyphs of the frame being rendered). 16 pages bound the per-frame glyph draw calls; 64 MiB is four full 2048x2048
    /// pages, enough for a dense full-screen CJK frame at 2x plus headroom for one round of misses.
    static let maxAtlasPages = 16
    static let maxAtlasBytes = 64 << 20
    /// An atlas that grew by appended pages may split the glyph pass into at most this many draws per frame.
    static let maxGlyphRuns = 48
    /// Number of compactions since creation (diagnostics).
    private(set) var atlasCompactions = 0
    private let lookup = GlyphLookup()
    /// Resident fonts by traits (bit 0 bold, bit 1 italic), resolved lazily once with the same construction as before.
    private var residentFonts: [NSFont?] = [nil, nil, nil, nil]
    private var fontIdentities: [FontIdentity: UInt32] = [:]
    private let inflightGate = DispatchSemaphore(value: 3)
    private let vertexRing = VertexRing()
    private let vertexScratch = VertexScratch()
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
      var slot = -1
      defer {
        if !permitHandedOff {
          if slot >= 0 { vertexRing.release(slot) }
          inflightGate.signal()
        }
      }
      let scale = max(CGFloat(1), geometry.backingScale)
      let scaleBits = Double(scale).bitPattern
      let gridCount = min(frame.cells.count, frame.columns * frame.rows)
      let cellGlyphs = lookup.reserveCells(gridCount)
      if atlas == nil
        || !resolveGlyphs(
          frame.cells, gridCount: gridCount, scaleBits: scaleBits, stopAtMiss: true, into: cellGlyphs)
      {
        do {
          try extendAtlas(
            missing: missingGlyphRequests(frame.cells, scale: scale, scaleBits: scaleBits),
            all: { self.glyphRequests(frame.cells, scale: scale, scaleBits: scaleBits) })
          lastError = nil
        } catch {
          lastError = error
          return nil
        }
        _ = resolveGlyphs(
          frame.cells, gridCount: gridCount, scaleBits: scaleBits, stopAtMiss: false, into: cellGlyphs)
      }
      // A grown atlas draws in cell order with one draw per page change; too fragmented for this frame means compact.
      if let grown = atlas, grown.isIncremental,
        glyphRunCount(gridCount: gridCount, into: cellGlyphs, atlas: grown) > Self.maxGlyphRuns
      {
        do {
          try compactAtlas(
            requests: glyphRequests(frame.cells, scale: scale, scaleBits: scaleBits), known: [:])
          lastError = nil
        } catch {
          lastError = error
          return nil
        }
        _ = resolveGlyphs(
          frame.cells, gridCount: gridCount, scaleBits: scaleBits, stopAtMiss: false, into: cellGlyphs)
      }
      let prepared = atlas
      // Every in-flight permit owns one vertex slot; release order (slot first, then permit) guarantees a free slot here.
      guard let claimed = vertexRing.claim() else { return nil }
      slot = claimed
      guard let command = queue.makeCommandBuffer(),
        let pass = MTLRenderPassDescriptor() as MTLRenderPassDescriptor?
      else { return nil }
      let gate = inflightGate
      let ring = vertexRing
      command.addCompletedHandler { completed in
        ring.release(claimed)
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
      let scratch = vertexScratch
      let pageCount = prepared?.textures.count ?? 0
      var backgroundVertices: [Vertex] = []
      var cursorUnderlayVertices: [Vertex] = []
      var glyphVertices: [Vertex] = []
      var glyphRuns: [GlyphRun] = []
      var decorationVertices: [Vertex] = []
      var overlayVertices: [Vertex] = []
      swap(&backgroundVertices, &scratch.background)
      swap(&cursorUnderlayVertices, &scratch.underlay)
      swap(&glyphVertices, &scratch.glyphs)
      swap(&glyphRuns, &scratch.runs)
      swap(&decorationVertices, &scratch.decorations)
      swap(&overlayVertices, &scratch.overlay)
      backgroundVertices.removeAll(keepingCapacity: true)
      cursorUnderlayVertices.removeAll(keepingCapacity: true)
      decorationVertices.removeAll(keepingCapacity: true)
      overlayVertices.removeAll(keepingCapacity: true)
      glyphVertices.removeAll(keepingCapacity: true)
      glyphRuns.removeAll(keepingCapacity: true)
      // Capacity up front from the cell counts: at most one background quad and one glyph quad per grid cell.
      backgroundVertices.reserveCapacity(gridCount * 6)
      var glyphQuads = 0
      for i in 0..<gridCount where cellGlyphs[i] >= 0 { glyphQuads += 1 }
      glyphVertices.reserveCapacity(glyphQuads * 6)
      var runPage: Int32 = -1
      var runStart = 0
      let unitFloats = Self.unitFloats
      func col(_ c: VTColor) -> SIMD4<Float> {
        SIMD4(unitFloats[Int(c.red)], unitFloats[Int(c.green)], unitFloats[Int(c.blue)], 1)
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
        vertices.append(Vertex(position: SIMD2(x0, y0), uv: SIMD2(a, b), color: c, textured: textured))
        vertices.append(Vertex(position: SIMD2(x1, y0), uv: SIMD2(aa, b), color: c, textured: textured))
        vertices.append(Vertex(position: SIMD2(x0, y1), uv: SIMD2(a, bb), color: c, textured: textured))
        vertices.append(Vertex(position: SIMD2(x1, y0), uv: SIMD2(aa, b), color: c, textured: textured))
        vertices.append(Vertex(position: SIMD2(x1, y1), uv: SIMD2(aa, bb), color: c, textured: textured))
        vertices.append(Vertex(position: SIMD2(x0, y1), uv: SIMD2(a, bb), color: c, textured: textured))
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
      let clearColor = frame.background
      var wideBackgroundDrawn = false
      for i in 0..<gridCount {
        let cell = frame.cells[i]
        let cx = i % frame.columns
        let ry = i / frame.columns
        let x = ix + Float(cx) * cw
        let y = iy + Float(ry) * ch
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
        // The pass already cleared to `clearColor`, so a cell background equal to it needs no quad. A quad is still drawn
        // when the previous cell's double-width quad reaches over this cell, so the overwrite order stays unchanged.
        let isWide = cell.wide.rawValue == 1
        if bg != clearColor || (cx > 0 && wideBackgroundDrawn) {
          quad(x, y, cw * (isWide ? 2 : 1), ch, col(bg), SIMD4(0, 0, 0, 0), 0, into: &backgroundVertices)
          wideBackgroundDrawn = isWide
        } else {
          wideBackgroundDrawn = false
        }
        if i == cursorCell { swap(&fg, &bg) }
        let baseline = iy + Float(ry) * ch + Float(geometry.baseline) * Float(scale)
        if !cell.hidden, cellGlyphs[i] >= 0, let atlas = prepared {
          let item = atlas.table[Int(cellGlyphs[i])]
          let g = item.glyph
          if Int32(item.page) != runPage {
            if runPage >= 0 {
              glyphRuns.append(
                GlyphRun(page: runPage, start: Int32(runStart), count: Int32(glyphVertices.count - runStart)))
            }
            runPage = Int32(item.page)
            runStart = glyphVertices.count
          }
          quad(
            x + g.bearing.x, baseline + g.bearing.y, g.size.x, g.size.y, col(fg), g.uv,
            g.isColor ? 2 : 1, into: &glyphVertices)
        }
        if cell.hidden { continue }
        let occupiedWidth = cell.wide.rawValue == 1 ? cw * 2 : cw
        let lineY = baseline + 1
        if cell.underlineStyle > 0 {
          let lineColor = col(cell.hasUnderline ? cell.underline : fg)
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
      if runPage >= 0 {
        glyphRuns.append(
          GlyphRun(page: runPage, start: Int32(runStart), count: Int32(glyphVertices.count - runStart)))
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
      // All draw groups of the frame live in this slot's buffer, each at an increasing 256-byte aligned offset.
      let stride = MemoryLayout<Vertex>.stride
      func span(_ count: Int) -> Int { (count * stride + 255) & ~255 }
      var totalLength = span(backgroundVertices.count) + span(cursorUnderlayVertices.count)
      totalLength += span(decorationVertices.count) + span(overlayVertices.count)
      // An atlas built in one piece keeps the page-grouped draw order (one draw per page); an atlas that grew by appended
      // pages draws in cell order, one draw per run of quads that share a page.
      let groupByPage = glyphRuns.count > 1 && !(prepared?.isIncremental ?? false)
      var pageVertexCounts: [Int] = []
      if groupByPage {
        pageVertexCounts = Array(repeating: 0, count: pageCount)
        for run in glyphRuns { pageVertexCounts[Int(run.page)] += Int(run.count) }
        for count in pageVertexCounts { totalLength += span(count) }
      } else {
        totalLength += span(glyphVertices.count)
      }
      let gpuBuffer =
        totalLength > 0 ? ring.buffer(slot: claimed, minimumLength: totalLength, device: device) : nil
      var bufferOffset = 0
      func draw(_ vertices: [Vertex], texture: MTLTexture?) {
        guard !vertices.isEmpty, let gpuBuffer else { return }
        vertices.withUnsafeBytes {
          gpuBuffer.contents().advanced(by: bufferOffset).copyMemory(
            from: $0.baseAddress!, byteCount: vertices.count * stride)
        }
        encoder.setVertexBuffer(gpuBuffer, offset: bufferOffset, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        bufferOffset += span(vertices.count)
      }
      draw(backgroundVertices, texture: nil)
      draw(cursorUnderlayVertices, texture: nil)
      if let atlas = prepared, let gpuBuffer, !glyphVertices.isEmpty {
        encoder.setFragmentSamplerState(sampler, index: 0)
        if !groupByPage {
          glyphVertices.withUnsafeBytes {
            gpuBuffer.contents().advanced(by: bufferOffset).copyMemory(
              from: $0.baseAddress!, byteCount: glyphVertices.count * stride)
          }
          encoder.setVertexBuffer(gpuBuffer, offset: bufferOffset, index: 0)
          for run in glyphRuns {
            encoder.setFragmentTexture(atlas.textures[Int(run.page)], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: Int(run.start), vertexCount: Int(run.count))
          }
          bufferOffset += span(glyphVertices.count)
        } else {
          for page in 0..<pageCount where pageVertexCounts[page] > 0 {
            var cursor = bufferOffset
            glyphVertices.withUnsafeBytes { source in
              for run in glyphRuns where Int(run.page) == page {
                gpuBuffer.contents().advanced(by: cursor).copyMemory(
                  from: source.baseAddress!.advanced(by: Int(run.start) * stride), byteCount: Int(run.count) * stride)
                cursor += Int(run.count) * stride
              }
            }
            encoder.setVertexBuffer(gpuBuffer, offset: bufferOffset, index: 0)
            encoder.setFragmentTexture(atlas.textures[page], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pageVertexCounts[page])
            bufferOffset += span(pageVertexCounts[page])
          }
        }
      }
      draw(decorationVertices, texture: nil)
      draw(overlayVertices, texture: nil)
      encoder.endEncoding()
      swap(&backgroundVertices, &scratch.background)
      swap(&cursorUnderlayVertices, &scratch.underlay)
      swap(&glyphVertices, &scratch.glyphs)
      swap(&glyphRuns, &scratch.runs)
      swap(&decorationVertices, &scratch.decorations)
      swap(&overlayVertices, &scratch.overlay)
      if let drawable { command.present(drawable) }
      command.commit()
      permitHandedOff = true
      return command
    }
    /// Same construction as the former per-cell `font(for:)`; resolved once per traits slot (bit 0 bold, bit 1 italic).
    private func resolveResidentFont(_ traits: Int) -> NSFont {
      if let resident = residentFonts[traits] { return resident }
      let base = NSFont.monospacedSystemFont(ofSize: 13, weight: traits & 1 != 0 ? .bold : .regular)
      let resolved = traits & 2 != 0 ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
      residentFonts[traits] = resolved
      lookup.fontIDs[traits] = fontID(for: resolved)
      return resolved
    }
    /// Fonts with the same name and point size share an id, matching the former "fontName|pointSize" key text.
    private func fontID(for font: NSFont) -> UInt32 {
      let identity = FontIdentity(name: font.fontName, size: Double(font.pointSize).bitPattern)
      if let known = fontIdentities[identity] { return known }
      let assigned = UInt32(fontIdentities.count)
      fontIdentities[identity] = assigned
      return assigned
    }
    /// Cheap steady-state pass: stores the atlas table index (or -1) of every grid cell and reports whether the current
    /// atlas holds every needed glyph (`stopAtMiss` returns at the first lacking glyph, leaving `out` incomplete).
    /// Performs no heap allocation when the atlas already holds every glyph.
    private func resolveGlyphs(
      _ cells: [VTCell], gridCount: Int, scaleBits: UInt64, stopAtMiss: Bool,
      into out: UnsafeMutablePointer<Int32>
    ) -> Bool {
      guard let atlas else { return false }
      var complete = true
      if lookup.asciiScaleBits != scaleBits {
        lookup.resetASCII()
        lookup.asciiScaleBits = scaleBits
      }
      let ascii = lookup.ascii
      let fontIDs = lookup.fontIDs
      for i in 0..<cells.count {
        let cell = cells[i]
        var found: Int32 = -1
        let wide = cell.wide.rawValue
        if wide != 2 && wide != 3 && !cell.text.isEmpty {
          let slot = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)
          var byte = -1
          var units = cell.text.utf8.makeIterator()
          if let first = units.next(), first < 128, units.next() == nil { byte = Int(first) }
          if byte >= 0, ascii[slot << 7 | byte] >= 0 {
            found = ascii[slot << 7 | byte]
          } else {
            if fontIDs[slot] == UInt32.max { _ = resolveResidentFont(slot) }
            let key = GlyphKey(font: fontIDs[slot], scale: scaleBits, text: cell.text)
            if let hit = atlas.index[key] {
              found = hit
              if byte >= 0 { ascii[slot << 7 | byte] = hit }
            } else {
              if stopAtMiss { return false }
              complete = false
            }
          }
        }
        if i < gridCount { out[i] = found }
      }
      return complete
    }
    /// Miss path only: makes the atlas hold every glyph of `requests`. Missing glyphs go into new immutable pages; when that
    /// would exceed the page or byte cap the atlas is instead rebuilt once from `requests` (the current frame's glyphs).
    /// `missing` are the requests the atlas lacks; `all` yields the whole glyph set of the frame and is only evaluated when
    /// the atlas has to be rebuilt.
    private func extendAtlas(missing misses: [GlyphRequest], all: () -> [GlyphRequest]) throws {
      guard let current = atlas else {
        let fresh = PreparedAtlas(device: device)
        let items = PreparedAtlas.rasterize(misses, reusing: [:])
        try fresh.append(items, plan: PreparedAtlas.plan(items))
        atlas = fresh
        return
      }
      if misses.isEmpty { return }
      let missItems = PreparedAtlas.rasterize(misses, reusing: [:])
      let plan = PreparedAtlas.plan(missItems)
      if plan.isEmpty { return }
      let newBytes = plan.reduce(0) { $0 + $1.byteCount }
      if current.textures.count + plan.count <= Self.maxAtlasPages,
        current.byteCount + newBytes <= Self.maxAtlasBytes
      {
        try current.append(missItems, plan: plan)
        return
      }
      var known: [GlyphKey: RasterItem] = [:]
      for item in missItems { known[item.key] = item }
      try compactAtlas(requests: all(), known: known)
    }
    /// Rebuilds the atlas once from `requests` (the current frame's glyph set), dropping everything else. The replacement
    /// is a new generation (`didSet` invalidates the ASCII table); the old pages stay alive for frames still in flight.
    private func compactAtlas(requests: [GlyphRequest], known: [GlyphKey: RasterItem]) throws {
      let items = PreparedAtlas.rasterize(requests, reusing: known)
      let compacted = PreparedAtlas(device: device)
      try compacted.append(items, plan: PreparedAtlas.plan(items))
      atlas = compacted
      atlasCompactions += 1
    }
    /// Number of draws the glyph pass of the frame would need in cell order (page changes between glyph cells).
    private func glyphRunCount(
      gridCount: Int, into cellGlyphs: UnsafeMutablePointer<Int32>, atlas: PreparedAtlas
    ) -> Int {
      var runs = 0
      var page = -1
      for i in 0..<gridCount where cellGlyphs[i] >= 0 {
        let p = atlas.table[Int(cellGlyphs[i])].page
        if p != page {
          runs += 1
          page = p
        }
      }
      return runs
    }
    /// The renderer's command queue, so tests can enqueue a blocker ahead of frames and keep them in flight.
    var commandQueueForTesting: MTLCommandQueue { queue }
    /// Page textures, entry count and byte size of the current atlas generation (diagnostics and tests).
    struct AtlasDiagnostics {
      var textures: [MTLTexture]
      var glyphCount: Int
      var byteCount: Int
      var compactions: Int
    }
    var atlasDiagnostics: AtlasDiagnostics {
      AtlasDiagnostics(
        textures: atlas?.textures ?? [], glyphCount: atlas?.table.count ?? 0, byteCount: atlas?.byteCount ?? 0,
        compactions: atlasCompactions)
    }
    /// Miss path only: the deduplicated requests of visible cell heads the current atlas lacks, in first-appearance order.
    /// Every needed glyph when there is no atlas yet.
    private func missingGlyphRequests(_ cells: [VTCell], scale: CGFloat, scaleBits: UInt64) -> [GlyphRequest] {
      guard let atlas else { return glyphRequests(cells, scale: scale, scaleBits: scaleBits) }
      var requests: [GlyphRequest] = []
      var seen = Set<GlyphKey>()
      for cell in cells where !cell.text.isEmpty && cell.wide.rawValue != 2 && cell.wide.rawValue != 3 {
        let slot = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)
        let f = resolveResidentFont(slot)
        let key = GlyphKey(font: lookup.fontIDs[slot], scale: scaleBits, text: cell.text)
        if atlas.index[key] == nil, seen.insert(key).inserted { requests.append((key, cell.text, f, scale)) }
      }
      return requests
    }
    /// Miss path only: the deduplicated glyph requests of every visible cell head, in first-appearance order.
    private func glyphRequests(_ cells: [VTCell], scale: CGFloat, scaleBits: UInt64) -> [GlyphRequest] {
      var requests: [GlyphRequest] = []
      var seen = Set<GlyphKey>()
      for cell in cells where !cell.text.isEmpty && cell.wide.rawValue != 2 && cell.wide.rawValue != 3 {
        let slot = (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)
        let f = resolveResidentFont(slot)
        let key = GlyphKey(font: lookup.fontIDs[slot], scale: scaleBits, text: cell.text)
        if seen.insert(key).inserted { requests.append((key, cell.text, f, scale)) }
      }
      return requests
    }
    public func prepareGlyphs(
      frame: VTFrame, font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      scale: CGFloat = 1
    ) {
      var requests: [GlyphKey: GlyphRequest] = [:]
      let id = fontID(for: font)
      for c in frame.cells where !c.text.isEmpty {
        let key = GlyphKey(font: id, scale: Double(scale).bitPattern, text: c.text)
        requests[key] = (key, c.text, font, scale)
      }
      if atlas == nil || !requests.keys.allSatisfy({ atlas?.index[$0] != nil }) {
        do {
          let all = Array(requests.values)
          try extendAtlas(missing: all.filter { atlas?.index[$0.key] == nil }, all: { all })
        } catch {
          lastError = error
        }
      }
    }
  }
#endif
