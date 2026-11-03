import Foundation
import Network
@testable import FastProxyCore

/// A small loopback TCP server used by integration tests.
final class TestTCPServer: @unchecked Sendable {
  typealias Handler = @Sendable (NWConnectionIO) async -> Void

  private let queue = DispatchQueue(label: "fastproxy.tests.server")
  private let handler: Handler
  private var listener: NWListener?
  private let lock = NSLock()
  private(set) var port: Int = 0

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func start() async throws -> Int {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener

    listener.newConnectionHandler = { [handler, queue] connection in
      let io = NWConnectionIO(connection: connection, queue: queue)
      Task {
        do {
          try await io.start()
          await handler(io)
        } catch {
          io.cancel()
        }
      }
    }

    try await waitUntilReady(listener)
    guard let assignedPort = listener.port?.rawValue else {
      throw TestServerError.missingPort
    }
    lock.lock()
    port = Int(assignedPort)
    lock.unlock()
    return Int(assignedPort)
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func waitUntilReady(_ listener: NWListener) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let gate = ContinuationGate()
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume { continuation.resume() }
        case .failed(let error):
          gate.resume { continuation.resume(throwing: error) }
        case .cancelled:
          gate.resume { continuation.resume(throwing: TestServerError.cancelled) }
        default:
          break
        }
      }
      listener.start(queue: queue)
    }
  }
}

enum TestServerError: Error {
  case missingPort
  case cancelled
}

extension NWConnectionIO {
  static func testClient(port: Int) async throws -> NWConnectionIO {
    try await connect(
      to: HostPort(host: "127.0.0.1", port: port),
      timeout: 5,
      queue: DispatchQueue(label: "fastproxy.tests.client")
    )
  }

  func readAll(timeout: TimeInterval = 5) async throws -> Data {
    var result = Data()
    try await withTimeout(timeout, onTimeout: { self.cancel() }) {
      while let chunk = try await self.receive(maximumLength: 65536) {
        result.append(chunk)
      }
    }
    return result
  }

  func readHeaderBlock(timeout: TimeInterval = 5) async throws -> Data {
    let reader = BufferedConnectionReader(connection: self, initialData: Data())
    return try await withTimeout(timeout, onTimeout: { self.cancel() }) {
      try await reader.readHeaderBlock(maximumBytes: 65536)
    }
  }
}

final class ContinuationGate: @unchecked Sendable {
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
