import Foundation

/// Buffered reader for request/response heads, fixed-length bodies, and chunked bodies.
final class BufferedConnectionReader {
  private let connection: NWConnectionIO
  private var buffer: Data
  private static let crlf = Data("\r\n".utf8)
  private static let headerTerminator = Data("\r\n\r\n".utf8)

  init(connection: NWConnectionIO, initialData: Data = Data()) {
    self.connection = connection
    self.buffer = initialData
  }

  var bufferedData: Data {
    buffer
  }

  func takeBufferedData() -> Data {
    let data = buffer
    buffer.removeAll(keepingCapacity: false)
    return data
  }

  func readHeaderBlock(maximumBytes: Int) async throws -> Data {
    while true {
      if let range = buffer.range(of: Self.headerTerminator) {
        guard range.upperBound - buffer.startIndex <= maximumBytes else {
          throw ProxyIOError.protocolError("HTTP headers exceed \(maximumBytes) bytes.")
        }
        let head = Data(buffer[..<range.upperBound])
        buffer.removeSubrange(..<range.upperBound)
        return head
      }

      if buffer.count >= maximumBytes {
        throw ProxyIOError.protocolError("HTTP headers exceed \(maximumBytes) bytes.")
      }

      let remaining = maximumBytes - buffer.count
      guard let chunk = try await connection.receive(maximumLength: max(1, remaining)) else {
        throw ProxyIOError.closed
      }
      if !chunk.isEmpty {
        buffer.append(chunk)
      }
    }
  }

  func readExactly(_ count: Int) async throws -> Data {
    guard count >= 0 else {
      throw ProxyIOError.protocolError("negative read length")
    }
    guard count > 0 else { return Data() }

    var result = Data()
    result.reserveCapacity(count)

    while result.count < count {
      if !buffer.isEmpty {
        let take = min(buffer.count, count - result.count)
        result.append(buffer.prefix(take))
        buffer.removeFirst(take)
        continue
      }

      let wanted = min(count - result.count, 256 * 1024)
      guard let chunk = try await connection.receive(maximumLength: wanted), !chunk.isEmpty else {
        throw ProxyIOError.closed
      }
      buffer.append(chunk)
    }
    return result
  }

  func readUpTo(_ count: Int) async throws -> Data? {
    guard count > 0 else { return Data() }
    if !buffer.isEmpty {
      let take = min(buffer.count, count)
      let result = Data(buffer.prefix(take))
      buffer.removeFirst(take)
      return result
    }
    guard let chunk = try await connection.receive(maximumLength: count) else {
      return nil
    }
    return chunk
  }

  func readLine(maximumBytes: Int = 8192) async throws -> Data {
    while true {
      if let range = buffer.range(of: Self.crlf) {
        let line = Data(buffer[..<range.upperBound])
        buffer.removeSubrange(..<range.upperBound)
        return line
      }
      if buffer.count >= maximumBytes {
        throw ProxyIOError.protocolError("line exceeds \(maximumBytes) bytes")
      }
      let remaining = maximumBytes - buffer.count
      guard let chunk = try await connection.receive(maximumLength: max(1, remaining)) else {
        throw ProxyIOError.closed
      }
      if !chunk.isEmpty {
        buffer.append(chunk)
      }
    }
  }

  /// Reads a complete chunked body verbatim, including chunk framing and trailers.
  func readChunkedBody(maximumBytes: Int) async throws -> Data {
    var result = Data()

    while true {
      let sizeLine = try await readLine()
      result.append(sizeLine)
      guard let text = String(data: sizeLine.dropLast(2), encoding: .ascii) else {
        throw ProxyIOError.protocolError("invalid chunk size line")
      }
      let sizeText = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
      guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
        throw ProxyIOError.protocolError("invalid chunk size")
      }
      if size == 0 {
        while true {
          let trailer = try await readLine()
          result.append(trailer)
          if trailer == Self.crlf { break }
        }
        break
      }

      guard result.count + size + 2 <= maximumBytes else {
        throw ProxyIOError.protocolError("chunked body exceeds \(maximumBytes) bytes")
      }
      result.append(try await readExactly(size))
      let terminator = try await readExactly(2)
      guard terminator == Self.crlf else {
        throw ProxyIOError.protocolError("invalid chunk terminator")
      }
      result.append(terminator)
    }

    return result
  }
}
