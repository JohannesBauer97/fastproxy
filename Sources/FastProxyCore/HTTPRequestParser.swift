import Foundation

public struct ParsedHTTPRequest: Sendable {
  public let method: String
  public let target: String
  public let version: String
  public let headers: HTTPHeaders
  public let host: String
  public let port: Int
  public let bodyPrefix: Data

  public var isConnect: Bool {
    method.caseInsensitiveCompare("CONNECT") == .orderedSame
  }

  public var isHealthCheck: Bool {
    method.caseInsensitiveCompare("GET") == .orderedSame && target == "/health"
  }

  public var originFormTarget: String {
    if isConnect { return target }
    if let absolute = Self.splitAbsoluteURL(target) {
      return absolute.path
    }
    return target.hasPrefix("/") ? target : "/"
  }

  public var absoluteFormTarget: String {
    if isConnect { return target }
    if Self.splitAbsoluteURL(target) != nil {
      return target
    }
    let authority = port == 80 ? formatHost(host) : formatHost(host) + ":\(port)"
    return "http://\(authority)\(originFormTarget)"
  }

  public var defaultPort: Int {
    if isConnect { return 443 }
    if let absolute = Self.splitAbsoluteURL(target), absolute.scheme.lowercased() == "https" {
      return 443
    }
    return 80
  }

  public var isChunkedRequest: Bool {
    headers.firstValue(named: "Transfer-Encoding")?
      .lowercased()
      .contains("chunked") == true
  }

  public var contentLength: Int? {
    guard let value = headers.firstValue(named: "Content-Length") else { return nil }
    return Int(value.trimmingCharacters(in: .whitespaces))
  }

  public var hasUpgrade: Bool {
    headers.contains("Upgrade") || headers.firstValue(named: "Connection")?
      .lowercased()
      .contains("upgrade") == true
  }

  public var requestedClose: Bool {
    headers.firstValue(named: "Connection")?.lowercased().contains("close") == true
  }

  private func formatHost(_ host: String) -> String {
    host.contains(":") ? "[\(host)]" : host
  }

  private struct AbsoluteURL {
    let scheme: String
    let host: String
    let port: Int
    let path: String
  }

  static func splitAbsoluteURL(_ target: String) -> (scheme: String, host: String, port: Int, path: String)? {
    guard let separator = target.range(of: "://") else { return nil }
    let scheme = String(target[..<separator.lowerBound])
    guard scheme.caseInsensitiveCompare("http") == .orderedSame ||
            scheme.caseInsensitiveCompare("https") == .orderedSame
    else {
      return nil
    }

    let remainder = target[separator.upperBound...]
    let pathStart = remainder.firstIndex(of: "/") ?? remainder.endIndex
    let authority = String(remainder[..<pathStart])
    let path = pathStart == remainder.endIndex ? "/" : String(remainder[pathStart...])
    guard !authority.isEmpty else { return nil }

    let defaultPort = scheme.caseInsensitiveCompare("https") == .orderedSame ? 443 : 80
    guard let endpoint = HostPort.parse(authority, defaultPort: defaultPort) else { return nil }
    return (scheme, endpoint.host, endpoint.port, path)
  }

  public static func headerEnd(in data: Data) -> Range<Data.Index>? {
    data.range(of: Data("\r\n\r\n".utf8))
  }
}

public enum HTTPRequestParser {
  public static let maximumHeaderBytes = 64 * 1024

  public static func parse(_ data: Data) throws -> ParsedHTTPRequest {
    guard let headerRange = ParsedHTTPRequest.headerEnd(in: data) else {
      throw HTTPParseError.incompleteHeaders
    }
    guard headerRange.lowerBound <= maximumHeaderBytes else {
      throw HTTPParseError.headersTooLarge
    }

    let headerData = data[..<headerRange.lowerBound]
    guard let text = String(data: headerData, encoding: .utf8) else {
      throw HTTPParseError.invalidEncoding
    }

    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw HTTPParseError.invalidRequestLine
    }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 3 else {
      throw HTTPParseError.invalidRequestLine
    }

    let method = String(parts[0])
    let target = String(parts[1])
    let version = String(parts[2])
    guard version.hasPrefix("HTTP/") else {
      throw HTTPParseError.invalidRequestLine
    }

    let rawHeaders = lines.dropFirst().joined(separator: "\r\n")
    let headers = HTTPHeaders.parse(rawHeaders)
    let bodyPrefix = Data(data[(headerRange.upperBound)...])

    let host: String
    let port: Int

    if method.caseInsensitiveCompare("CONNECT") == .orderedSame {
      guard let endpoint = HostPort.parse(target, defaultPort: 443) else {
        throw HTTPParseError.invalidAuthority(target)
      }
      host = endpoint.host
      port = endpoint.port
    } else if let absolute = ParsedHTTPRequest.splitAbsoluteURL(target) {
      host = absolute.host
      port = absolute.port
    } else {
      guard let hostHeader = headers.firstValue(named: "Host"),
            let endpoint = HostPort.parse(hostHeader, defaultPort: 80)
      else {
        throw HTTPParseError.missingHost
      }
      host = endpoint.host
      port = endpoint.port
    }

    return ParsedHTTPRequest(
      method: method,
      target: target,
      version: version,
      headers: headers,
      host: host,
      port: port,
      bodyPrefix: bodyPrefix
    )
  }
}

public enum HTTPParseError: LocalizedError, Equatable {
  case incompleteHeaders
  case headersTooLarge
  case invalidEncoding
  case invalidRequestLine
  case invalidAuthority(String)
  case missingHost

  public var errorDescription: String? {
    switch self {
    case .incompleteHeaders: return "Incomplete HTTP headers."
    case .headersTooLarge: return "HTTP headers exceed 64 KiB."
    case .invalidEncoding: return "HTTP headers are not valid UTF-8."
    case .invalidRequestLine: return "Invalid HTTP request line."
    case .invalidAuthority(let authority): return "Invalid authority: \(authority)."
    case .missingHost: return "Cannot determine target host from request."
    }
  }
}
