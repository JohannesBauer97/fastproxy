import Foundation
import Network

public enum ProxyServerError: LocalizedError {
  case alreadyRunning
  case bindFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning: return "The proxy is already running."
    case .bindFailed(let message): return "Could not start proxy: \(message)"
    }
  }
}

public final class ProxyServer: @unchecked Sendable {
  public let configuration: ProxyConfiguration

  private let authenticator: ProxyAuthenticator
  private let logger: ProxyLogging
  private let queue = DispatchQueue(label: "fastproxy.server", attributes: .concurrent)
  private let matcher: NoProxyMatcher
  private let registry = ConnectionRegistry()
  private var listener: NWListener?
  private var tunnelHandler: TunnelHandler?
  private var httpForwarder: HTTPForwarder?
  private var boundPortValue: Int = 0

  public init(
    configuration: ProxyConfiguration,
    authenticator: ProxyAuthenticator = GSSProxyAuthenticator(),
    logger: ProxyLogging = NullProxyLogger()
  ) {
    self.configuration = configuration
    self.authenticator = authenticator
    self.logger = logger
    self.matcher = NoProxyMatcher(patterns: configuration.noProxy)
  }

  public var boundPort: Int {
    boundPortValue
  }

  public var isRunning: Bool {
    listener != nil
  }

  public func start() async throws -> Int {
    guard listener == nil else {
      return boundPortValue
    }

    try configuration.validate()

    let parameters = Self.listenerParameters(for: configuration)
    let listener: NWListener
    if configuration.listen == "0.0.0.0" || configuration.listen == "::" {
      guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
        throw ProxyServerError.bindFailed("invalid port \(configuration.port)")
      }
      listener = try NWListener(using: parameters, on: port)
    } else {
      listener = try NWListener(using: parameters)
    }

    self.listener = listener
    let tunnelHandler = TunnelHandler(
      configuration: configuration,
      authenticator: authenticator,
      logger: logger
    )
    let httpForwarder = HTTPForwarder(
      configuration: configuration,
      authenticator: authenticator,
      logger: logger
    )
    self.tunnelHandler = tunnelHandler
    self.httpForwarder = httpForwarder

    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }

    do {
      try await waitUntilReady(listener)
    } catch {
      listener.cancel()
      self.listener = nil
      throw ProxyServerError.bindFailed(error.localizedDescription)
    }

    guard let port = listener.port?.rawValue else {
      listener.cancel()
      self.listener = nil
      throw ProxyServerError.bindFailed("listener did not report a port")
    }

    boundPortValue = Int(port)
    logger.info("FastProxy listening on \(configuration.listen):\(boundPortValue)")
    return boundPortValue
  }

  public func stop() async {
    listener?.cancel()
    listener = nil
    tunnelHandler = nil
    httpForwarder = nil
    registry.cancelAll()
    boundPortValue = 0
    logger.info("FastProxy stopped")
  }

  private func accept(_ connection: NWConnection) {
    registry.register(connection)
    let connectionQueue = DispatchQueue(label: "fastproxy.client.\(UUID().uuidString)")
    Task { [weak self] in
      guard let self else {
        connection.cancel()
        return
      }
      await self.handle(connection, queue: connectionQueue)
      self.registry.unregister(connection)
    }
  }

  private func handle(_ connection: NWConnection, queue: DispatchQueue) async {
    let client = NWConnectionIO(connection: connection, queue: queue)
    defer { client.cancel() }

    do {
      try await client.start(timeout: configuration.timeoutInterval)

      let reader = BufferedConnectionReader(connection: client)
      let headerData: Data
      do {
        headerData = try await withTimeout(
          configuration.timeoutInterval,
          onTimeout: { client.cancel() }
        ) {
          try await reader.readHeaderBlock(maximumBytes: HTTPRequestParser.maximumHeaderBytes)
        }
      } catch {
        await ProxyResponses.badRequest(to: client)
        return
      }

      let request: ParsedHTTPRequest
      do {
        request = try HTTPRequestParser.parse(headerData)
      } catch {
        logger.debug("Invalid request: \(error.localizedDescription)")
        await ProxyResponses.badRequest(to: client)
        return
      }

      if request.isHealthCheck {
        await ProxyResponses.health(to: client)
        return
      }

      if request.isConnect {
        await handleConnect(request: request, client: client, clientReader: reader)
      } else {
        let useProxy = !configuration.proxyEndpoints.isEmpty && !matcher.matches(host: request.host)
        await httpForwarder?.forward(
          request: request,
          client: client,
          clientReader: reader,
          useProxy: useProxy
        )
      }
    } catch {
      logger.debug("Client connection ended: \(error.localizedDescription)")
    }
  }

  private func handleConnect(
    request: ParsedHTTPRequest,
    client: NWConnectionIO,
    clientReader: BufferedConnectionReader
  ) async {
    let target = HostPort(host: request.host, port: request.port)
    let useProxy = !configuration.proxyEndpoints.isEmpty && !matcher.matches(host: request.host)

    guard let tunnel = await tunnelHandler?.connect(target: target, useProxy: useProxy) else {
      logger.warning("CONNECT \(target) failed: no route")
      await ProxyResponses.badGateway(to: client)
      return
    }
    defer { tunnel.connection.cancel() }

    do {
      try await client.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
    } catch {
      return
    }

    logger.debug("CONNECT \(target) established via \(tunnel.route)")
    await TunnelHandler.relay(
      client: client,
      upstream: tunnel.connection,
      initialClientData: clientReader.takeBufferedData(),
      initialUpstreamData: tunnel.reader.takeBufferedData(),
      bufferSize: configuration.bufferLength
    )
  }

  private func waitUntilReady(_ listener: NWListener) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let gate = ResumeGate()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume { continuation.resume() }
        case .failed(let error):
          gate.resume { continuation.resume(throwing: error) }
        case .cancelled:
          gate.resume { continuation.resume(throwing: ProxyIOError.cancelled) }
        case .waiting(let error):
          gate.resume { continuation.resume(throwing: error) }
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }

  private static func listenerParameters(for configuration: ProxyConfiguration) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.allowLocalEndpointReuse = true

    guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
      return parameters
    }

    switch configuration.listen {
    case "0.0.0.0", "::":
      break
    case "localhost", "127.0.0.1":
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : port)
    default:
      parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.listen), port: port == 0 ? .any : port)
    }
    return parameters
  }
}

private final class ConnectionRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  func register(_ connection: NWConnection) {
    lock.lock()
    connections[ObjectIdentifier(connection)] = connection
    lock.unlock()
  }

  func unregister(_ connection: NWConnection) {
    lock.lock()
    connections.removeValue(forKey: ObjectIdentifier(connection))
    lock.unlock()
  }

  func cancelAll() {
    lock.lock()
    let all = connections.values
    connections.removeAll()
    lock.unlock()
    all.forEach { $0.cancel() }
  }
}
