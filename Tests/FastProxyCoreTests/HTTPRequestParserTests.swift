import XCTest
@testable import FastProxyCore

final class HTTPRequestParserTests: XCTestCase {
  func testParsesConnectRequest() throws {
    let request = try HTTPRequestParser.parse(
      Data("CONNECT example.com:8443 HTTP/1.1\r\nHost: example.com:8443\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.method, "CONNECT")
    XCTAssertTrue(request.isConnect)
    XCTAssertEqual(request.host, "example.com")
    XCTAssertEqual(request.port, 8443)
  }

  func testParsesAbsoluteHTTPURL() throws {
    let request = try HTTPRequestParser.parse(
      Data("GET http://example.com:8080/a/b?q=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.method, "GET")
    XCTAssertEqual(request.host, "example.com")
    XCTAssertEqual(request.port, 8080)
    XCTAssertEqual(request.originFormTarget, "/a/b?q=1")
    XCTAssertEqual(request.absoluteFormTarget, "http://example.com:8080/a/b?q=1")
  }

  func testParsesAbsoluteHTTPSURL() throws {
    let request = try HTTPRequestParser.parse(
      Data("GET https://example.com/secure HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.host, "example.com")
    XCTAssertEqual(request.port, 443)
    XCTAssertEqual(request.originFormTarget, "/secure")
  }

  func testParsesOriginFormRequestUsingHostHeader() throws {
    let request = try HTTPRequestParser.parse(
      Data("POST /submit HTTP/1.1\r\nHost: example.com:9000\r\nContent-Length: 0\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.host, "example.com")
    XCTAssertEqual(request.port, 9000)
    XCTAssertEqual(request.originFormTarget, "/submit")
    XCTAssertEqual(request.absoluteFormTarget, "http://example.com:9000/submit")
  }

  func testParsesIPv6ConnectAuthority() throws {
    let request = try HTTPRequestParser.parse(
      Data("CONNECT [2001:db8::1]:443 HTTP/1.1\r\nHost: [2001:db8::1]:443\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.host, "2001:db8::1")
    XCTAssertEqual(request.port, 443)
  }

  func testPreservesDuplicateHeadersAndOrder() throws {
    let request = try HTTPRequestParser.parse(
      Data("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nX-Test: one\r\nX-Test: two\r\n\r\n".utf8)
    )
    XCTAssertEqual(request.headers.values(named: "x-test"), ["one", "two"])
  }

  func testRemainingBodyBytesArePreserved() throws {
    let raw = Data("POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello".utf8)
    let request = try HTTPRequestParser.parse(raw)
    XCTAssertEqual(request.bodyPrefix, Data("hello".utf8))
  }

  func testRejectsMalformedRequestLine() {
    XCTAssertThrowsError(try HTTPRequestParser.parse(Data("GARBAGE\r\n\r\n".utf8)))
  }

  func testRejectsMissingHostForOriginFormRequest() {
    XCTAssertThrowsError(try HTTPRequestParser.parse(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
  }

  func testDetectsHealthCheck() throws {
    let request = try HTTPRequestParser.parse(
      Data("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    )
    XCTAssertTrue(request.isHealthCheck)
  }
}
