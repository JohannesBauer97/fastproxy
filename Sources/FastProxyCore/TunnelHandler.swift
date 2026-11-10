import Foundation

struct EstablishedTunnel {
  let connection: NWConnectionIO
  let reader: BufferedConnectionReader
  let route: String
}

final class TunnelHandler: @unchecked Sendable {
  private let configuration: ProxyConfiguration
  private let authenticator: ProxyAuthenticator
  private let logger: ProxyLogging

  init(
    configuration: ProxyConfiguration,
    authenticator: ProxyAuthenticator,
    logger: ProxyLogging
  ) {
    self.configuration = configuration
    self.authenticator = authenticator
    self.logger = logger
  }

  func connect(target: HostPort, useProxy: Bool) async -> EstablishedTunnel? {
    if useProxy {
      for (index, proxy) in configuration.proxyEndpoints.enumerated() {
        if let tunnel = await connectVia(proxy: proxy, target: target) {
          logger.debug("CONNECT \(target) via \(proxy) (\(index + 1)/\(configuration.proxyEndpoints.count))")
          return tunnel
        }
      }
      logger.warning("All upstream proxies failed for CONNECT \(target); falling back to DIRECT")
    }

    if let tunnel = await connectDirect(target: target) {
      logger.debug("CONNECT \(target) via DIRECT")
      return tunnel
    }
    return nil
  }

  private func connectDirect(target: HostPort) async -> EstablishedTunnel? {
    do {
      let connection = try await NWConnectionIO.connect(
        to: target,
        timeout: configuration.timeoutInterval
      )
      return EstablishedTunnel(
        connection: connection,
        reader: BufferedConnectionReader(connection: connection),
        route: "DIRECT"
      )
    } catch {
      logger.warning("Direct connect failed for \(target): \(error.localizedDescription)")
      return nil
    }
  }

  private func connectVia(proxy: HostPort, target: HostPort) async -> EstablishedTunnel? {
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
      guard let connection = try? await NWConnectionIO.connect(
        to: proxy,
        timeout: configuration.timeoutInterval
      ) else {
        return nil
      }

      if !tokenAttempted {
        tokenAttempted = true
        do {
          token = try session?.initialToken()
        } catch {
          logger.debug("Pre-emptive Negotiate token unavailable for \(proxy): \(error.localizedDescription)")
        }
      }

      let reader = BufferedConnectionReader(connection: connection)
      let authority = target.description
      var request = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: Keep-Alive\r\n"
      if let token, !token.isEmpty {
        request += "Proxy-Authorization: Negotiate \(token)\r\n"
      }
      request += "\r\n"

      do {
        try await connection.send(Data(request.utf8))
      } catch {
        connection.cancel()
        return nil
      }

      let responseData: Data
      do {
        responseData = try await withTimeout(
          configuration.timeoutInterval,
          onTimeout: { connection.cancel() }
        ) {
          try await reader.readHeaderBlock(maximumBytes: HTTPRequestParser.maximumHeaderBytes)
        }
      } catch {
        logger.debug("CONNECT handshake with \(proxy) failed: \(error.localizedDescription)")
        connection.cancel()
        return nil
      }

      guard let response = try? HTTPResponseHead.parse(responseData) else {
        connection.cancel()
        return nil
      }

      if response.statusCode == 200 {
        return EstablishedTunnel(connection: connection, reader: reader, route: "\(proxy)")
      }

      if response.statusCode == 407, let challenge = Self.negotiateChallenge(from: response.headers) {
        let next: String?
        do {
          next = try session?.nextToken(challenge: challenge)
        } catch {
          logger.warning("Negotiate authentication failed for \(proxy): \(error.localizedDescription)")
          next = nil
        }
        if let next, !next.isEmpty, attempt < 3 {
          token = next
          connection.cancel()
          continue
        }
        logger.warning("Upstream proxy \(proxy) rejected Negotiate authentication")
        connection.cancel()
        return nil
      }

      logger.warning("Upstream proxy \(proxy) returned HTTP \(response.statusCode) for CONNECT \(target)")
      connection.cancel()
      return nil
    }

    return nil
  }

  static func negotiateChallenge(from headers: HTTPHeaders) -> String? {
    for value in headers.values(named: "Proxy-Authenticate") {
      let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.first?.caseInsensitiveCompare("Negotiate") == .orderedSame else { continue }
      guard parts.count > 1 else { return nil }
      let challenge = String(parts[1]).trimmingCharacters(in: .whitespaces)
      return challenge.isEmpty ? nil : challenge
    }
    return nil
  }

  static func relay(
    client: NWConnectionIO,
    upstream: NWConnectionIO,
    initialClientData: Data,
    initialUpstreamData: Data,
    bufferSize: Int
  ) async {
    await withTaskCancellationHandler {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          await pump(
            from: client,
            to: upstream,
            initialData: initialClientData,
            bufferSize: bufferSize
          )
        }
        group.addTask {
          await pump(
            from: upstream,
            to: client,
            initialData: initialUpstreamData,
            bufferSize: bufferSize
          )
        }
      }
    } onCancel: {
      // Task cancellation alone does not resume Network.framework's receive callbacks.
      client.cancel()
      upstream.cancel()
    }
  }

  private static func pump(
    from source: NWConnectionIO,
    to destination: NWConnectionIO,
    initialData: Data,
    bufferSize: Int
  ) async {
    do {
      if !initialData.isEmpty {
        try await destination.send(initialData)
      }
      while let data = try await source.receive(maximumLength: bufferSize) {
        if data.isEmpty { continue }
        try await destination.send(data)
      }
      try await destination.sendEOF()
    } catch {
      // Unlike a normal EOF, an I/O failure makes the whole tunnel unusable.
      // Tear down both sides to unblock the other pump and release its resources.
      source.cancel()
      destination.cancel()
    }
  }
}
