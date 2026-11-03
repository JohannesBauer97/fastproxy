import AppKit

enum StatusIcon {
  static func image(for status: AppModel.Status) -> NSImage {
    let color: NSColor
    switch status {
    case .running:
      color = .systemGreen
    case .starting:
      color = .systemOrange
    case .stopped, .failed:
      color = .systemRed
    }

    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
      color.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 3.5, dy: 3.5)).fill()
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "FastProxy"
    return image
  }
}
