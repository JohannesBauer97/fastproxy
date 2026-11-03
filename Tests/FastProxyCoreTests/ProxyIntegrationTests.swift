import Foundation
import XCTest
@testable import FastProxyCore

final class ProxyIntegrationTests: XCTestCase {
  private var servers: [TestTCPServer] = []
  private var proxy: ProxyServer?

  override func tearDown() async throws {
    await proxy?.stop()
    proxy = nil
    servers.forEach { $0.stop() }
    servers.removeAll()
    try await super.tearDown()
  }

  func testDirectHTTPRequestIsForwarded() async throws {
    let origin = try await startServer { connection in
      let reader = BufferedConnectionReader(connection: connection, initialData: Data())
      _ = try? await reader.readHeaderBlock(maximumBytes: 65536)
      try? await connection.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8))
      try? await connection.sendEOF()
    }
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://127.0.0.1:\(origin.port)/test HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8))
    let response = try await client.readAll()
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("200 OK"), text)
    XCTAssertTrue(text.hasSuffix("hello"), text)
  }

  func testConnectDirectTunnelEchoes() async throws {
    let echo = try await startEchoServer()
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n".utf8))
    let handshake = try await client.readHeaderBlock()
    XCTAssertTrue(String(decoding: handshake, as: UTF8.self).contains("200 Connection Established"))

    let payload = Data("hello through the tunnel".utf8)
    try await client.send(payload)
    let echoed = try await readExactly(payload.count, from: client)
    XCTAssertEqual(echoed, payload)
  }

  func testHealthEndpointReturnsOK() async throws {
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: []))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
    let response = try await client.readAll()
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("200 OK"), text)
    XCTAssertTrue(text.hasSuffix("OK"), text)
  }

  func testInvalidRequestReturns400() async throws {
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: []))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GARBAGE\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("400 Bad Request"))
  }

  func testUnreachableHTTPUpstreamReturns502() async throws {
    let deadPort = try await unusedPort()
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://127.0.0.1:\(deadPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(deadPort)\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("502 Bad Gateway"))
  }

  func testUnreachableCONNECTTargetReturns502() async throws {
    let deadPort = try await unusedPort()
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT 127.0.0.1:\(deadPort) HTTP/1.1\r\nHost: 127.0.0.1:\(deadPort)\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("502 Bad Gateway"))
  }

  func testConcurrentHTTPRequests() async throws {
    let origin = try await startServer { connection in
      let reader = BufferedConnectionReader(connection: connection, initialData: Data())
      _ = try? await reader.readHeaderBlock(maximumBytes: 65536)
      try? await connection.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8))
      try? await connection.sendEOF()
    }
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))

    try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<12 {
        group.addTask {
          let client = try await NWConnectionIO.testClient(port: proxyPort)
          defer { client.cancel() }
          try await client.send(Data("GET http://127.0.0.1:\(origin.port)/ HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8))
          return String(decoding: try await client.readAll(), as: UTF8.self)
        }
      }
      for try await response in group {
        XCTAssertTrue(response.contains("200 OK"), response)
        XCTAssertTrue(response.hasSuffix("OK"), response)
      }
    }
  }

  func testDirectPOSTBodyIsForwarded() async throws {
    let origin = try await startServer { connection in
      do {
        let reader = BufferedConnectionReader(connection: connection, initialData: Data())
        _ = try await reader.readHeaderBlock(maximumBytes: 65536)
        let body = try await reader.readExactly(11)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        try await connection.send(response)
        try await connection.sendEOF()
      } catch {
        connection.cancel()
      }
    }
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("POST http://127.0.0.1:\(origin.port)/ HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nContent-Length: 11\r\n\r\nhello world".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix("hello world"))
  }

  func testDirectChunkedResponseIsRelayed() async throws {
    let chunkedBody = "5\r\nhello\r\n0\r\n\r\n"
    let origin = try await startServer { connection in
      let reader = BufferedConnectionReader(connection: connection, initialData: Data())
      _ = try? await reader.readHeaderBlock(maximumBytes: 65536)
      try? await connection.send(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(chunkedBody)".utf8))
      try? await connection.sendEOF()
    }
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://127.0.0.1:\(origin.port)/ HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix(chunkedBody))
  }

  func testLargeDirectDownloadStreamsAllBytes() async throws {
    let body = Data(repeating: 0x41, count: 512 * 1024)
    let origin = try await startServer { connection in
      let reader = BufferedConnectionReader(connection: connection, initialData: Data())
      _ = try? await reader.readHeaderBlock(maximumBytes: 65536)
      var response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
      response.append(body)
      try? await connection.send(response)
      try? await connection.sendEOF()
    }
    let proxyPort = try await startProxy(config: makeConfig(port: 0, noProxy: ["127.0.0.1"]))
    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://127.0.0.1:\(origin.port)/large HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n".utf8))
    let response = try await client.readAll(timeout: 10)
    XCTAssertTrue(response.count > body.count)
    XCTAssertTrue(response.suffix(body.count) == body)
  }

  // MARK: - Helpers

  private func makeConfig(port: Int, noProxy: [String]) -> ProxyConfiguration {
    ProxyConfiguration(
      listen: "127.0.0.1",
      port: port,
      upstreamProxy: "",
      failoverProxy: nil,
      noProxy: noProxy,
      bufferSize: 8192,
      connectionTimeout: 5
    )
  }

  private func startProxy(config: ProxyConfiguration) async throws -> Int {
    let server = ProxyServer(configuration: config)
    let port = try await server.start()
    proxy = server
    return port
  }

  private func startEchoServer() async throws -> TestTCPServer {
    let server = TestTCPServer { connection in
      do {
        while let data = try await connection.receive(maximumLength: 65536) {
          if data.isEmpty { continue }
          try await connection.send(data)
        }
        try await connection.sendEOF()
      } catch {
        connection.cancel()
      }
    }
    _ = try await server.start()
    servers.append(server)
    return server
  }

  private func startServer(handler: @escaping TestTCPServer.Handler) async throws -> TestTCPServer {
    let server = TestTCPServer(handler: handler)
    _ = try await server.start()
    servers.append(server)
    return server
  }

  private func readExactly(_ count: Int, from connection: NWConnectionIO) async throws -> Data {
    var result = Data()
    while result.count < count {
      guard let chunk = try await connection.receive(maximumLength: count - result.count) else {
        break
      }
      result.append(chunk)
    }
    return result
  }

  private func unusedPort() async throws -> Int {
    let server = TestTCPServer { connection in
      connection.cancel()
    }
    let port = try await server.start()
    server.stop()
    try await Task.sleep(nanoseconds: 100_000_000)
    return port
  }
}
