import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func finite(_ value: CGFloat) -> Bool { value.isFinite }
func finite(_ rect: CGRect) -> Bool {
  finite(rect.origin.x) && finite(rect.origin.y) && finite(rect.width) && finite(rect.height)
}

// Read-only geometry evidence for the M2 terminal acceptance.  This deliberately
// does not move, resize, activate, or otherwise mutate the target application.
struct Probe {
  var errors: [String] = []

  mutating func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else {
      if result != .attributeUnsupported && result != .noValue {
        errors.append("AX \(attribute): \(result.rawValue)")
      }
      return nil
    }
    return value
  }

  func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = copyValue(element, attribute) else { return nil }
    return value as? String
  }

  func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
  }

  func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = copyValue(element, kAXPositionAttribute),
      let size = copyValue(element, kAXSizeAttribute),
      CFGetTypeID(position) == AXValueGetTypeID(),
      CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    let positionValue = position as! AXValue
    let sizeValue = size as! AXValue
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetType(positionValue) == .cgPoint,
      AXValueGetType(sizeValue) == .cgSize,
      AXValueGetValue(positionValue, .cgPoint, &point),
      AXValueGetValue(sizeValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: point, size: extent)
  }

  mutating func node(_ element: AXUIElement, depth: Int, seen: inout Int) -> [String: Any] {
    seen += 1
    var result: [String: Any] = ["depth": depth, "kind": depth == 0 ? "outer-window" : "descendant"]
    let role = axString(element, kAXRoleAttribute)
    if let role { result["role"] = role }
    if let subrole = axString(element, kAXSubroleAttribute) { result["subrole"] = subrole }
    if let title = axString(element, kAXTitleAttribute) { result["title"] = title }
    if let identifier = axString(element, kAXIdentifierAttribute) { result["identifier"] = identifier }
    if let frame = frame(element) {
      if finite(frame) {
        result["frame"] = ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
      } else {
        result["frame"] = NSNull()
        result["frameError"] = "AX frame contained a non-finite coordinate or extent"
      }
    } else {
      result["frame"] = NSNull()
      result["frameError"] = "AX position or size unavailable, or had an unexpected AXValue type"
    }
    if depth == 1, let role, ["AXGroup", "AXSplitGroup", "AXScrollArea"].contains(role) {
      result["contentRootCandidate"] = true
      result["candidateBasis"] = "first-level AX child role; heuristic only"
    }
    if depth < 4, seen < 200, let raw = copyValue(element, kAXChildrenAttribute), let children = raw as? [AXUIElement] {
      result["children"] = children.map { node($0, depth: depth + 1, seen: &seen) }
    }
    return result
  }
}

func displayEvidence() -> [[String: Any]] {
  var count: UInt32 = 0
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
  return ids.prefix(Int(count)).map { id in
    let logical = CGDisplayBounds(id)
    var item: [String: Any] = [
      "displayID": id,
      "logicalBounds": ["x": logical.origin.x, "y": logical.origin.y, "width": logical.width, "height": logical.height],
      "pixelWidth": CGDisplayPixelsWide(id),
      "pixelHeight": CGDisplayPixelsHigh(id),
      "isMain": id == CGMainDisplayID()
    ]
    if let mode = CGDisplayCopyDisplayMode(id) {
      item["modeLogicalWidth"] = mode.width
      item["modeLogicalHeight"] = mode.height
      item["modePixelWidth"] = mode.pixelWidth
      item["modePixelHeight"] = mode.pixelHeight
    } else {
      item["modeError"] = "CGDisplayCopyDisplayMode returned nil"
    }
    if let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
    }) {
      item["backingScale"] = screen.backingScaleFactor
      item["screenFrame"] = ["x": screen.frame.origin.x, "y": screen.frame.origin.y, "width": screen.frame.width, "height": screen.frame.height]
    } else {
      item["backingScale"] = NSNull()
      item["backingScaleError"] = "NSScreen not available for display"
    }
    return item
  }
}

func cgWindows(pid: pid_t) -> [[String: Any]] {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
  return list.compactMap { item in
    guard let owner = item[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid else { return nil }
    var out: [String: Any] = ["windowID": item[kCGWindowNumber as String] ?? NSNull(), "layer": item[kCGWindowLayer as String] ?? NSNull(), "ownerName": item[kCGWindowOwnerName as String] ?? NSNull()]
    if let bounds = item[kCGWindowBounds as String] as? NSDictionary { out["bounds"] = bounds }
    out["alpha"] = item[kCGWindowAlpha as String] ?? NSNull()
    return out
  }
}

@main struct TerminalWindowProbe {
  static func main() {
    let args = CommandLine.arguments
    if args.contains("--self-test") {
      let invalid = CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)
      guard !finite(invalid), finite(CGRect(x: 0, y: 0, width: 10, height: 10)) else {
        fputs("finite geometry self-test failed\n", stderr); exit(1)
      }
      print("finite geometry self-test passed")
      return
    }
    guard let index = args.firstIndex(of: "--pid"), index + 1 < args.count, let pid = pid_t(args[index + 1]) else {
      fputs("usage: terminal-window-probe --pid PID\n", stderr); exit(64)
    }
    var probe = Probe()
    let application = AXUIElementCreateApplication(pid)
    var windows: [[String: Any]] = []
    if let raw = probe.axValue(application, kAXWindowsAttribute), let elements = raw as? [AXUIElement] {
      var seen = 0
      windows = elements.map { probe.node($0, depth: 0, seen: &seen) }
    } else {
      probe.errors.append("AX windows unavailable; Accessibility permission or target state may prevent inspection")
    }
    let result: [String: Any] = [
      "schema": "web-studio.terminal-window-probe.v1",
      "pid": pid,
      "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "ax": ["application": "AXUIElementCreateApplication", "windows": windows],
      "cgWindows": cgWindows(pid: pid),
      "displays": displayEvidence(),
      "errors": probe.errors,
      "limitations": [
        "AX frames are screen-coordinate accessibility frames; CGWindow bounds are separate evidence.",
        "The probe reports descendant roles and frames but cannot prove which descendant is the NSWindow content view.",
        "Content-root candidates require application-specific interpretation; no UI state is changed."
      ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
      print(text)
    } else { fputs("failed to serialize probe result\n", stderr); exit(1) }
  }
}
