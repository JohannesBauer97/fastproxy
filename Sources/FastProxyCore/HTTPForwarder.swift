import Foundation

final class HTTPForwarder: @unchecked Sendable {
  private let configuration: ProxyConfiguration
  private let authenticator: ProxyAuthenticator
  private let logger: ProxyLogging

  private static let maximumBufferedRequestBytes = 64 * 1024 * 1024

  init(
    configuration: ProxyConfiguration,
    authenticator: ProxyAuthenticator,
    logger: ProxyLogging
  ) {
    self.configuration = configuration
    self.authenticator = authenticator
    self.logger = logger
  }

  func forward(
    request: ParsedHTTPRequest,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader,
    useProxy: Bool
  ) async {
    if useProxy {
      await forwardViaProxy(request: request, client: client, clientReader: clientReader)
    } else {
      await forwardDirect(request: request, client: client, clientReader: clientReader)
    }
  }

  private func forwardDirect(
    request: ParsedHTTPRequest,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader
  ) async {
    let target = HostPort(host: request.host, port: request.port)
    let upstream: NWConnectionIO
    do {
      upstream = try await NWConnectionIO.connect(
        to: target,
        timeout: configuration.timeoutInterval
      )
    } catch {
      logger.warning("HTTP direct connect failed for \(target): \(error.localizedDescription)")
      await ProxyResponses.badGateway(to: client)
      return
    }
    defer { upstream.cancel() }

    let head = RequestHeadBuilder.build(
      request,
      form: .origin,
      forceClose: !request.hasUpgrade,
      stripExpect: false
    )

    do {
      try await upstream.send(head)
    } catch {
      logger.warning("HTTP direct send failed for \(target): \(error.localizedDescription)")
      await ProxyResponses.badGateway(to: client)
      return
    }

    logger.debug("\(request.method) \(request.target) -> DIRECT")
    await TunnelHandler.relay(
      client: client,
      upstream: upstream,
      initialClientData: clientReader.takeBufferedData(),
      initialUpstreamData: Data(),
      bufferSize: configuration.bufferLength
    )
  }

  private func forwardViaProxy(
    request: ParsedHTTPRequest,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader
  ) async {
    if request.headers.firstValue(named: "Expect")?.lowercased().contains("100-continue") == true,
       request.contentLength ?? 0 > 0
    {
      try? await client.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
    }

    let body: Data
    do {
      body = try await readRequestBody(request: request, reader: clientReader)
    } catch {
      logger.warning("Could not read request body: \(error.localizedDescription)")
      await ProxyResponses.badGateway(to: client)
      return
    }

    for proxy in configuration.proxyEndpoints {
      if await exchangeViaProxy(
        proxy: proxy,
        request: request,
        body: body,
        client: client,
        clientReader: clientReader
      ) {
        return
      }
    }

    logger.warning("All upstream proxies failed for \(request.method) \(request.target)")
    await ProxyResponses.badGateway(to: client)
  }

  private func exchangeViaProxy(
    proxy: HostPort,
    request: ParsedHTTPRequest,
    body: Data,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader
  ) async -> Bool {
    let session: ProxyAuthenticationSession?
    do {
      session = try authenticator.makeSession(proxyHost: proxy.host)
    } catch {
      logger.debug("No Kerberos credentials for \(proxy): \(error.localizedDescription)")
      session = nil
    }
    defer { session?.close() }

    var token: String?
    var tokenAttempted = false

    for attempt in 0..<4 {
      let upstream: NWConnectionIO
      do {
        upstream = try await NWConnectionIO.connect(
          to: proxy,
          timeout: configuration.timeoutInterval
        )
      } catch {
        logger.debug("HTTP proxy connect failed for \(proxy): \(error.localizedDescription)")
        return false
      }

      if !tokenAttempted {
        tokenAttempted = true
        do {
          token = try session?.initialToken()
        } catch {
          logger.debug("Pre-emptive Negotiate token unavailable for \(proxy): \(error.localizedDescription)")
        }
      }

      let reader = BufferedConnectionReader(connection: upstream)
      let authorization = token.map { "Negotiate \($0)" }
      let head = RequestHeadBuilder.build(
        request,
        form: .absolute,
        proxyAuthorization: authorization,
        forceClose: true,
        stripExpect: true
      )

      do {
        try await upstream.send(head)
        if !body.isEmpty {
          try await upstream.send(body)
        }
      } catch {
        logger.debug("HTTP proxy send failed for \(proxy): \(error.localizedDescription)")
        upstream.cancel()
        return false
      }

      let response: HTTPResponseHead
      do {
        response = try await readFinalResponse(from: reader, upstream: upstream)
      } catch {
        logger.debug("HTTP proxy response failed for \(proxy): \(error.localizedDescription)")
        upstream.cancel()
        return false
      }

      if response.statusCode == 407, let challenge = TunnelHandler.negotiateChallenge(from: response.headers) {
        let next: String?
        do {
          next = try session?.nextToken(challenge: challenge)
        } catch {
          logger.warning("Negotiate authentication failed for \(proxy): \(error.localizedDescription)")
          next = nil
        }
        if let next, !next.isEmpty, attempt < 3 {
          token = next
          upstream.cancel()
          continue
        }
        logger.warning("Upstream proxy \(proxy) rejected Negotiate authentication")
        upstream.cancel()
        return false
      }

      logger.debug("\(request.method) \(request.target) -> \(proxy) [\(response.statusCode)]")
      await writeResponse(
        response,
        request: request,
        client: client,
        clientReader: clientReader,
        upstreamReader: reader,
        upstream: upstream
      )
      upstream.cancel()
      return true
    }

    return false
  }

  private func readFinalResponse(
    from reader: BufferedConnectionReader,
    upstream: NWConnectionIO
  ) async throws -> HTTPResponseHead {
    for _ in 0..<8 {
      let data = try await withTimeout(
        configuration.timeoutInterval,
        onTimeout: { upstream.cancel() }
      ) {
        try await reader.readHeaderBlock(maximumBytes: HTTPRequestParser.maximumHeaderBytes)
      }
      let response = try HTTPResponseHead.parse(data)
      if response.isInformational {
        continue
      }
      return response
    }
    throw ProxyIOError.protocolError("too many informational responses")
  }

  private func readRequestBody(
    request: ParsedHTTPRequest,
    reader: BufferedConnectionReader
  ) async throws -> Data {
    if request.isChunkedRequest {
      return try await reader.readChunkedBody(maximumBytes: Self.maximumBufferedRequestBytes)
    }
    if let length = request.contentLength {
      guard length <= Self.maximumBufferedRequestBytes else {
        throw ProxyIOError.protocolError("request body exceeds 64 MiB")
      }
      return try await reader.readExactly(length)
    }
    return reader.takeBufferedData()
  }

  private func writeResponse(
    _ response: HTTPResponseHead,
    request: ParsedHTTPRequest,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader,
    upstreamReader: BufferedConnectionReader,
    upstream: NWConnectionIO
  ) async {
    var headers = response.headers
    headers.removeAll(named: "Proxy-Authenticate")
    headers.removeAll(named: "Proxy-Connection")
    headers.removeAll(named: "Connection")
    headers.removeAll(named: "Keep-Alive")

    if response.isUpgrade {
      headers.set("Upgrade", for: "Connection")
    } else {
      headers.set("close", for: "Connection")
    }

    var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
    head += headers.serialized
    head += "\r\n"

    do {
      try await client.send(Data(head.utf8))
    } catch {
      return
    }

    if response.isUpgrade {
      await TunnelHandler.relay(
        client: client,
        upstream: upstream,
        initialClientData: clientReader.takeBufferedData(),
        initialUpstreamData: upstreamReader.takeBufferedData(),
        bufferSize: configuration.bufferLength
      )
      return
    }

    do {
      try await streamBody(
        response.bodyKind(requestMethod: request.method),
        requestMethod: request.method,
        from: upstreamReader,
        to: client
      )
      try await client.sendEOF()
    } catch {
      logger.debug("Response stream ended: \(error.localizedDescription)")
    }
  }

  private func streamBody(
    _ kind: HTTPResponseHead.BodyKind,
    requestMethod: String,
    from reader: BufferedConnectionReader,
    to client: NWConnectionIO
  ) async throws {
    switch kind {
    case .none:
      return

    case .contentLength(let length):
      var remaining = length
      while remaining > 0 {
        guard let chunk = try await reader.readUpTo(min(remaining, configuration.bufferLength)) else {
          return
        }
        if chunk.isEmpty { continue }
        remaining -= chunk.count
        try await client.send(chunk)
      }

    case .chunked:
      while true {
        let sizeLine = try await reader.readLine()
        try await client.send(sizeLine)
        guard let text = String(data: sizeLine.dropLast(2), encoding: .ascii) else {
          throw ProxyIOError.protocolError("invalid chunk size line")
        }
        let sizeText = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
          throw ProxyIOError.protocolError("invalid chunk size")
        }
        if size == 0 {
          while true {
            let trailer = try await reader.readLine()
            try await client.send(trailer)
            if trailer == Data("\r\n".utf8) { return }
          }
        }
        let chunk = try await reader.readExactly(size)
        try await client.send(chunk)
        let terminator = try await reader.readExactly(2)
        try await client.send(terminator)
      }

    case .untilClose:
      while let chunk = try await reader.readUpTo(configuration.bufferLength) {
        if chunk.isEmpty { continue }
        try await client.send(chunk)
      }
    }
  }
}
