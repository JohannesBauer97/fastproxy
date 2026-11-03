import Foundation
import XCTest
@testable import FastProxyCore

final class UpstreamProxyTests: XCTestCase {
  private var servers: [TestTCPServer] = []
  private var proxy: ProxyServer?

  override func tearDown() async throws {
    await proxy?.stop()
    proxy = nil
    servers.forEach { $0.stop() }
    servers.removeAll()
    try await super.tearDown()
  }

  func testConnectViaUpstreamProxyUsesPreemptiveToken() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(recorder: recorder, acceptedToken: "initial-token")
    let authenticator = MockAuthenticator(initialToken: "initial-token", followUpToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
    let handshake = try await client.readHeaderBlock()
    XCTAssertTrue(String(decoding: handshake, as: UTF8.self).contains("200 Connection Established"))

    try await client.send(Data("ping".utf8))
    let echo = try await readExactly(4, from: client)
    XCTAssertEqual(String(decoding: echo, as: UTF8.self), "ping")

    let records = await recorder.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].method, "CONNECT")
    XCTAssertEqual(records[0].proxyAuthorization, "Negotiate initial-token")
  }

  func testUpstreamFailoverToSecondProxy() async throws {
    let deadPort = try await unusedPort()
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(recorder: recorder, acceptedToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(deadPort)",
      failover: "127.0.0.1:\(upstream.port)",
      noProxy: []
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
    let handshake = try await client.readHeaderBlock()
    XCTAssertTrue(String(decoding: handshake, as: UTF8.self).contains("200 Connection Established"))
    try await client.send(Data("failover".utf8))
    let echo = try await readExactly(8, from: client)
    XCTAssertEqual(String(decoding: echo, as: UTF8.self), "failover")
    let failoverRecords = await recorder.all()
    XCTAssertEqual(failoverRecords.count, 1)
  }

  func testUpstream407ChallengeIsAnswered() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(
      recorder: recorder,
      acceptedToken: "challenge-token",
      challenge: "server-challenge"
    )
    let authenticator = MockAuthenticator(initialToken: nil, followUpToken: "challenge-token")
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
    let handshake = try await client.readHeaderBlock()
    XCTAssertTrue(String(decoding: handshake, as: UTF8.self).contains("200 Connection Established"))
    try await client.send(Data("secured".utf8))
    let echo = try await readExactly(7, from: client)
    XCTAssertEqual(String(decoding: echo, as: UTF8.self), "secured")

    let records = await recorder.all()
    XCTAssertEqual(records.count, 2)
    XCTAssertNil(records[0].proxyAuthorization)
    XCTAssertEqual(records[1].proxyAuthorization, "Negotiate challenge-token")
    XCTAssertEqual(authenticator.lastChallenge, "server-challenge")
  }

  func testPlainHTTPViaUpstreamUsesAbsoluteFormAndAuth() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(recorder: recorder, acceptedToken: "initial-token")
    let authenticator = MockAuthenticator(initialToken: "initial-token", followUpToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://example.com/path?q=1 HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8))
    let response = try await client.readAll()
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("200 OK"), text)
    XCTAssertTrue(text.hasSuffix("proxied"), text)

    let records = await recorder.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].target, "http://example.com/path?q=1")
    XCTAssertEqual(records[0].proxyAuthorization, "Negotiate initial-token")
  }

  func testPlainHTTPPOSTViaUpstreamForwardsBody() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(recorder: recorder, acceptedToken: "initial-token")
    let authenticator = MockAuthenticator(initialToken: "initial-token", followUpToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("POST http://example.com/upload HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix("proxied"))

    let records = await recorder.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].bodyText, "hello")
  }

  func testPlainHTTPViaUpstreamHandles407() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(
      recorder: recorder,
      acceptedToken: "challenge-token",
      challenge: "server-challenge"
    )
    let authenticator = MockAuthenticator(initialToken: nil, followUpToken: "challenge-token")
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix("proxied"))

    let records = await recorder.all()
    XCTAssertEqual(records.count, 2)
    XCTAssertNil(records[0].proxyAuthorization)
    XCTAssertEqual(records[1].proxyAuthorization, "Negotiate challenge-token")
    XCTAssertEqual(authenticator.lastChallenge, "server-challenge")
  }

  func testPlainHTTPViaUpstreamRelaysChunkedResponse() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(
      recorder: recorder,
      acceptedToken: "initial-token",
      chunkedResponse: true
    )
    let authenticator = MockAuthenticator(initialToken: "initial-token", followUpToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8))
    let response = try await client.readAll()
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("Transfer-Encoding: chunked"), text)
    XCTAssertTrue(text.hasSuffix("7\r\nproxied\r\n0\r\n\r\n"), text)
  }

  func testNoProxyPatternBypassesUpstreamProxy() async throws {
    let recorder = RequestRecorder()
    let upstream = try await startFakeProxy(recorder: recorder, acceptedToken: nil)
    let echo = try await startEchoServer()
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: ["127.0.0.1"]
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n".utf8))
    let handshake = try await client.readHeaderBlock()
    XCTAssertTrue(String(decoding: handshake, as: UTF8.self).contains("200 Connection Established"))
    try await client.send(Data("direct".utf8))
    let echoed = try await readExactly(6, from: client)
    XCTAssertEqual(String(decoding: echoed, as: UTF8.self), "direct")
    let directRecords = await recorder.all()
    XCTAssertTrue(directRecords.isEmpty)
  }

  func testUnsupportedAuthChallengeReturns502() async throws {
    let upstream = try await startFakeProxy(recorder: RequestRecorder(), acceptedToken: "never")
    let deadPort = try await unusedPort()
    let authenticator = MockAuthenticator(initialToken: nil, followUpToken: nil)
    let proxyPort = try await startProxy(
      upstream: "127.0.0.1:\(upstream.port)",
      failover: nil,
      noProxy: [],
      authenticator: authenticator
    )

    let client = try await NWConnectionIO.testClient(port: proxyPort)
    defer { client.cancel() }
    try await client.send(Data("CONNECT 127.0.0.1:\(deadPort) HTTP/1.1\r\nHost: 127.0.0.1:\(deadPort)\r\n\r\n".utf8))
    let response = try await client.readAll()
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("502 Bad Gateway"))
  }

  // MARK: - Helpers

  private func startProxy(
    upstream: String,
    failover: String?,
    noProxy: [String],
    authenticator: ProxyAuthenticator = MockAuthenticator(initialToken: nil, followUpToken: nil)
  ) async throws -> Int {
    let config = ProxyConfiguration(
      listen: "127.0.0.1",
      port: 0,
      upstreamProxy: upstream,
      failoverProxy: failover,
      noProxy: noProxy,
      bufferSize: 8192,
      connectionTimeout: 3
    )
    let server = ProxyServer(configuration: config, authenticator: authenticator)
    let port = try await server.start()
    proxy = server
    return port
  }

  private func startFakeProxy(
    recorder: RequestRecorder,
    acceptedToken: String?,
    challenge: String = "challenge",
    chunkedResponse: Bool = false
  ) async throws -> TestTCPServer {
    let server = TestTCPServer { connection in
      let reader = BufferedConnectionReader(connection: connection, initialData: Data())
      guard let head = try? await reader.readHeaderBlock(maximumBytes: 65536),
            let request = try? HTTPRequestParser.parse(head)
      else {
        connection.cancel()
        return
      }

      var bodyText = ""
      if !request.isConnect {
        if request.isChunkedRequest {
          if let body = try? await reader.readChunkedBody(maximumBytes: 1024 * 1024) {
            bodyText = String(decoding: body, as: UTF8.self)
          }
        } else if let length = request.contentLength {
          if let body = try? await reader.readExactly(length) {
            bodyText = String(decoding: body, as: UTF8.self)
          }
        }
      }

      await recorder.append(
        ProxyRequestRecord(
          method: request.method,
          target: request.target,
          proxyAuthorization: request.headers.firstValue(named: "Proxy-Authorization"),
          bodyText: bodyText
        )
      )

      let authorization = request.headers.firstValue(named: "Proxy-Authorization")
      if let acceptedToken,
         authorization != "Negotiate \(acceptedToken)"
      {
        let challengeBase64 = Data(challenge.utf8).base64EncodedString()
        let response = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate \(challengeBase64)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        try? await connection.send(Data(response.utf8))
        try? await connection.sendEOF()
        return
      }

      if request.isConnect {
        try? await connection.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        do {
          while let data = try await connection.receive(maximumLength: 65536) {
            if data.isEmpty { continue }
            try await connection.send(data)
          }
          try await connection.sendEOF()
        } catch {
          connection.cancel()
        }
      } else if chunkedResponse {
        try? await connection.send(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n7\r\nproxied\r\n0\r\n\r\n".utf8))
        try? await connection.sendEOF()
      } else {
        try? await connection.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nproxied".utf8))
        try? await connection.sendEOF()
      }
    }
    _ = try await server.start()
    servers.append(server)
    return server
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

private struct ProxyRequestRecord: Sendable {
  let method: String
  let target: String
  let proxyAuthorization: String?
  let bodyText: String
}

private actor RequestRecorder {
  private var records: [ProxyRequestRecord] = []

  func append(_ record: ProxyRequestRecord) {
    records.append(record)
  }

  func all() -> [ProxyRequestRecord] {
    records
  }
}

private final class MockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
  private let initialToken: String?
  private let followUpToken: String?
  private let lock = NSLock()
  private var challenge: String?

  var lastChallenge: String? {
    lock.lock()
    defer { lock.unlock() }
    return challenge
  }

  init(initialToken: String?, followUpToken: String?) {
    self.initialToken = initialToken
    self.followUpToken = followUpToken
  }

  func makeSession(proxyHost: String) throws -> ProxyAuthenticationSession {
    MockSession(authenticator: self)
  }

  fileprivate func record(challenge: String?) -> String? {
    let decoded: String?
    if let challenge,
       let data = Data(base64Encoded: challenge),
       let text = String(data: data, encoding: .utf8)
    {
      decoded = text
    } else {
      decoded = challenge
    }

    lock.lock()
    self.challenge = decoded
    lock.unlock()
    return followUpToken
  }

  fileprivate func initial() -> String? {
    initialToken
  }
}

private final class MockSession: ProxyAuthenticationSession {
  private let authenticator: MockAuthenticator

  init(authenticator: MockAuthenticator) {
    self.authenticator = authenticator
  }

  func initialToken() throws -> String? {
    authenticator.initial()
  }

  func nextToken(challenge: String?) throws -> String? {
    authenticator.record(challenge: challenge)
  }

  func close() {}
}
