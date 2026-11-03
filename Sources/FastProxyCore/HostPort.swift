import Foundation

/// A host and TCP port pair. IPv6 literals are stored without brackets.
public struct HostPort: Equatable, Sendable, CustomStringConvertible {
  public let host: String
  public let port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }

  public var description: String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }

  /// Parses `host`, `host:port`, `[v6]`, or `[v6]:port`.
  public static func parse(_ value: String, defaultPort: Int) -> HostPort? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("[") {
      guard let closing = text.firstIndex(of: "]") else { return nil }
      let host = String(text[text.index(after: text.startIndex)..<closing])
      guard !host.isEmpty else { return nil }
      let remainder = text[text.index(after: closing)...]
      if remainder.isEmpty {
        return HostPort(host: host, port: defaultPort)
      }
      guard remainder.first == ":" else { return nil }
      let portText = String(remainder.dropFirst())
      guard let port = Int(portText), (1...65535).contains(port) else { return nil }
      return HostPort(host: host, port: port)
    }

    let colonCount = text.reduce(into: 0) { count, character in
      if character == ":" { count += 1 }
    }

    if colonCount == 1, let colon = text.lastIndex(of: ":") {
      let host = String(text[..<colon])
      let portText = String(text[text.index(after: colon)...])
      if !host.isEmpty, let port = Int(portText), (1...65535).contains(port) {
        return HostPort(host: host, port: port)
      }
    }

    // No explicit port, or an unbracketed IPv6 literal.
    guard !text.isEmpty else { return nil }
    return HostPort(host: text, port: defaultPort)
  }
}
