import Foundation
import Network
import XCTest
@testable import FastProxyCore

final class ConnectionLifecycleTests: XCTestCase {
  private var servers: [TestTCPServer] = []
  private var connections: [NWConnectionIO] = []

  override func tearDown() async throws {
    connections.forEach { $0.cancel() }
    connections.removeAll()
    servers.forEach { $0.stop() }
    servers.removeAll()
    try await super.tearDown()
  }

  func testFailedStartCancelsWaitingConnection() async throws {
    // A non-local source address forces .waiting without changing the machine's network.
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "192.0.2.1", port: .any)
    let connection = NWConnection(host: "127.0.0.1", port: 9, using: parameters)
    let io = NWConnectionIO(connection: connection, queue: DispatchQueue(label: "fastproxy.tests.waiting"))
    connections.append(io)

    do {
      try await io.start(timeout: 1)
      XCTFail("Starting with an unavailable local endpoint must fail")
    } catch {
      XCTAssertNotEqual(error as? ProxyIOError, .timeout)
    }

    // Cancellation may already be queued for start()'s handler. Replacing that
    // handler here can miss the transition, so observe eventual state on its queue.
    for _ in 0..<100 {
      let state = await withCheckedContinuation { continuation in
        io.queue.async { continuation.resume(returning: connection.state) }
      }
      if case .cancelled = state { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Failed connection must be cancelled instead of retrying indefinitely; state: \(connection.state)")
  }

  func testRelayErrorClosesTheOtherDirection() async throws {
    let client = try await makeConnectionPair()
    let upstream = try await makeConnectionPair()
    let finished = expectation(description: "A failed relay must not leave the reverse receive suspended")
    let relay = Task {
      await TunnelHandler.relay(
        client: client.local,
        upstream: upstream.local,
        initialClientData: Data(),
        initialUpstreamData: Data(),
        bufferSize: 8192
      )
      finished.fulfill()
    }

    client.local.cancel()
    await fulfillment(of: [finished], timeout: 1)
    // Always release the unmodified implementation's hanging receive after the assertion.
    upstream.local.cancel()
    await relay.value
  }

  func testCancellingRelayClosesBothDirections() async throws {
    let client = try await makeConnectionPair()
    let upstream = try await makeConnectionPair()
    let finished = expectation(description: "Task cancellation releases both pending receives")
    let relay = Task {
      await TunnelHandler.relay(
        client: client.local,
        upstream: upstream.local,
        initialClientData: Data(),
        initialUpstreamData: Data(),
        bufferSize: 8192
      )
      finished.fulfill()
    }

    relay.cancel()
    await fulfillment(of: [finished], timeout: 1)
    client.local.cancel()
    upstream.local.cancel()
    await relay.value
  }

  func testHalfClosedClientStillReceivesCompleteResponse() async throws {
    let client = try await makeConnectionPair()
    let upstream = try await makeConnectionPair()
    let relay = Task {
      await TunnelHandler.relay(
        client: client.local,
        upstream: upstream.local,
        initialClientData: Data(),
        initialUpstreamData: Data(),
        bufferSize: 8192
      )
    }

    try await client.peer.send(Data("request".utf8))
    try await client.peer.sendEOF()
    let request = try await upstream.peer.readAll()
    XCTAssertEqual(request, Data("request".utf8))

    let body = Data(repeating: 0x41, count: 512 * 1024)
    try await upstream.peer.send(body)
    try await upstream.peer.sendEOF()
    let response = try await client.peer.readAll()
    XCTAssertEqual(response, body, "Normal EOF must not cancel the still-active response direction")
    await relay.value
  }

  private func makeConnectionPair() async throws -> (local: NWConnectionIO, peer: NWConnectionIO) {
    let accepted = expectation(description: "Loopback connection accepted")
    let box = AcceptedConnection()
    let server = TestTCPServer { connection in
      await box.set(connection)
      accepted.fulfill()
    }
    let port = try await server.start()
    servers.append(server)
    let peer = try await NWConnectionIO.testClient(port: port)
    connections.append(peer)
    await fulfillment(of: [accepted], timeout: 2)
    let stored = await box.get()
    let local = try XCTUnwrap(stored)
    connections.append(local)
    return (local, peer)
  }
}

private actor AcceptedConnection {
  private var connection: NWConnectionIO?

  func set(_ connection: NWConnectionIO) {
    self.connection = connection
  }

  func get() -> NWConnectionIO? {
    connection
  }
}
