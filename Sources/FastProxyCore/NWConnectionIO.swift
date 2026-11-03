import Foundation
import Network

public enum ProxyIOError: LocalizedError, Equatable {
  case timeout
  case closed
  case cancelled
  case connectionFailed(String)
  case sendFailed(String)
  case protocolError(String)

  public var errorDescription: String? {
    switch self {
    case .timeout: return "Connection timed out."
    case .closed: return "Connection closed unexpectedly."
    case .cancelled: return "Connection was cancelled."
    case .connectionFailed(let message): return "Connection failed: \(message)"
    case .sendFailed(let message): return "Send failed: \(message)"
    case .protocolError(let message): return "Protocol error: \(message)"
    }
  }
}

/// Async wrapper around Network.framework's `NWConnection`.
final class NWConnectionIO: @unchecked Sendable {
  let connection: NWConnection
  let queue: DispatchQueue

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  static func connect(
    to endpoint: HostPort,
    timeout: TimeInterval,
    queue: DispatchQueue = DispatchQueue(label: "fastproxy.connection")
  ) async throws -> NWConnectionIO {
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    tcpOptions.connectionTimeout = max(1, Int(timeout.rounded(.up)))
    tcpOptions.enableKeepalive = true
    tcpOptions.keepaliveIdle = 30

    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.allowLocalEndpointReuse = true

    guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
      throw ProxyIOError.connectionFailed("invalid port \(endpoint.port)")
    }

    let connection = NWConnection(
      host: NWEndpoint.Host(endpoint.host),
      port: port,
      using: parameters
    )
    let io = NWConnectionIO(connection: connection, queue: queue)
    try await io.start(timeout: timeout)
    return io
  }

  func start(timeout: TimeInterval? = nil) async throws {
    if let timeout {
      try await withTimeout(timeout, onTimeout: { self.connection.cancel() }) {
        try await self.waitUntilReady()
      }
    } else {
      try await waitUntilReady()
    }
  }

  func send(_ data: Data, isComplete: Bool = false) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        contentContext: .defaultMessage,
        isComplete: isComplete,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: ProxyIOError.sendFailed(error.localizedDescription))
          } else {
            continuation.resume()
          }
        }
      )
    }
  }

  func sendEOF() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: ProxyIOError.sendFailed(error.localizedDescription))
          } else {
            continuation.resume()
          }
        }
      )
    }
  }

  func receive(maximumLength: Int) async throws -> Data? {
    let length = max(1, maximumLength)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: length) { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: ProxyIOError.connectionFailed(error.localizedDescription))
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  func cancel() {
    connection.cancel()
  }

  private func waitUntilReady() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let gate = ResumeGate()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume { continuation.resume() }
        case .failed(let error):
          gate.resume { continuation.resume(throwing: ProxyIOError.connectionFailed(error.localizedDescription)) }
        case .cancelled:
          gate.resume { continuation.resume(throwing: ProxyIOError.cancelled) }
        case .waiting(let error):
          // Network.framework retries waiting connections indefinitely. For a
          // forward proxy it is better to fail over or report 502 promptly.
          gate.resume { continuation.resume(throwing: ProxyIOError.connectionFailed(error.localizedDescription)) }
        case .setup, .preparing:
          break
        @unknown default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }
}

func withTimeout<T>(
  _ seconds: TimeInterval,
  onTimeout: @escaping @Sendable () -> Void,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  let nanoseconds = UInt64(max(seconds, 0.001) * 1_000_000_000)
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(nanoseconds: nanoseconds)
      onTimeout()
      throw ProxyIOError.timeout
    }

    do {
      let result = try await group.next()!
      group.cancelAll()
      return result
    } catch {
      group.cancelAll()
      throw error
    }
  }
}

final class ResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false

  func resume(_ body: () -> Void) {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    body()
  }
}
