import Foundation

struct HTTPResponseHead: Sendable {
  enum BodyKind: Sendable {
    case none
    case contentLength(Int)
    case chunked
    case untilClose
  }

  let version: String
  let statusCode: Int
  let reason: String
  let headers: HTTPHeaders

  static func parse(_ data: Data) throws -> HTTPResponseHead {
    guard let headerRange = ParsedHTTPRequest.headerEnd(in: data) else {
      throw HTTPParseError.incompleteHeaders
    }
    let headerData = data[..<headerRange.lowerBound]
    guard let text = String(data: headerData, encoding: .utf8) else {
      throw HTTPParseError.invalidEncoding
    }

    let lines = text.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
      throw HTTPParseError.invalidRequestLine
    }
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2,
          parts[0].hasPrefix("HTTP/"),
          let statusCode = Int(parts[1])
    else {
      throw HTTPParseError.invalidRequestLine
    }

    return HTTPResponseHead(
      version: String(parts[0]),
      statusCode: statusCode,
      reason: parts.count > 2 ? String(parts[2]) : "",
      headers: HTTPHeaders.parse(lines.dropFirst().joined(separator: "\r\n"))
    )
  }

  var isInformational: Bool {
    (100...199).contains(statusCode) && statusCode != 101
  }

  var isUpgrade: Bool {
    statusCode == 101
  }

  func bodyKind(requestMethod: String) -> BodyKind {
    if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame {
      return .none
    }
    if (100...199).contains(statusCode) || statusCode == 204 || statusCode == 304 {
      return .none
    }
    if headers.values(named: "Transfer-Encoding").contains(where: { $0.lowercased().contains("chunked") }) {
      return .chunked
    }
    if let value = headers.firstValue(named: "Content-Length"),
       let length = Int(value.trimmingCharacters(in: .whitespaces)),
       length >= 0
    {
      return .contentLength(length)
    }
    return .untilClose
  }
}
