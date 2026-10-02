# Static path inventory; not hotspot attribution

- PTY: TerminalPTYTransport readAvailable -> backend.consume -> core.feed and takeQueryResponses -> scheduleFrame (16 ms).
- Snapshot: backend.publishFrame invokes core.snapshot before visibility check; StudioVTCore.c allocates cell array and text, TerminalVTCore.swift converts each visible cell Data -> String; VTFrameMailbox coalesces delivery after snapshot creation.
- Render: TerminalMetalRenderer.render builds per-cell font/string keys and required set. Any missing atlas key constructs PreparedAtlas for current requests. A static 1024-entry raster cache may avoid CTLine rasterization; atlas rebuild still packs pages and uploads whole 2048x2048 RGBA textures. Therefore cache miss, raster miss, atlas rebuild and upload must be measured separately.
- Shaping: CTLine uses ligature=0; color glyph detection inspects actual CTRun fonts. Matching the requested primary font does not prove equal fallback or equal shaping with legacy.
- No production changes or measured root-cause claims follow from this inventory.

## Primary references to consult alongside measured stacks
- Apple, Optimize CPU performance with Instruments (WWDC25): https://developer.apple.com/videos/play/wwdc2025/308/ . Time Profiler samples running threads; deferred recording reduces observer overhead. Sample weights are not exact function durations.
- Apple, MTLDrawable.presentedTime: https://developer.apple.com/documentation/metal/mtldrawable/presentedtime . Present request/command completion must not be substituted for presentation timestamp.
- Local macOS SDK sys/resource.h, rusage_info_v4: UUID is 16 bytes; user/system counters at uint64 offsets 2/3 (observed Mach ticks on this host; convert with mach_timebase_info, not assumed nanoseconds), resident at 8, physical footprint at 9, start abstime at 10. Validate against measured process identity and ps before adoption.

Local SDK confirms addPresentedHandler/presentedTime are available on this macOS; presentedTime=0 means unpresented or skipped. This makes isolated event instrumentation feasible, but no measured display latency is claimed.
