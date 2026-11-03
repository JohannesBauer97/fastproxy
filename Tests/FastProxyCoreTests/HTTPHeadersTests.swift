import XCTest
@testable import FastProxyCore

final class HTTPHeadersTests: XCTestCase {
  func testCaseInsensitiveLookup() {
    let headers = HTTPHeaders([
      ("Host", "example.com"),
      ("Content-Type", "text/plain"),
    ])
    XCTAssertEqual(headers.firstValue(named: "host"), "example.com")
    XCTAssertEqual(headers.firstValue(named: "CONTENT-TYPE"), "text/plain")
    XCTAssertEqual(headers.values(named: "content-type"), ["text/plain"])
  }

  func testRemovalIsCaseInsensitiveAndKeepsOtherHeaders() {
    var headers = HTTPHeaders([
      ("Host", "example.com"),
      ("Proxy-Connection", "keep-alive"),
      ("Accept", "*/*"),
    ])
    headers.removeAll(named: "host")
    headers.removeAll(named: "proxy-connection")
    XCTAssertEqual(headers.map(\.name), ["Accept"])
  }

  func testSetReplacesExistingValues() {
    var headers = HTTPHeaders([
      ("Host", "old.example.com"),
      ("X-Test", "one"),
      ("X-Test", "two"),
    ])
    headers.set("new.example.com", for: "host")
    headers.set("three", for: "X-Test")
    XCTAssertEqual(headers.values(named: "Host"), ["new.example.com"])
    XCTAssertEqual(headers.values(named: "X-Test"), ["three"])
  }

  func testSerializationPreservesDuplicates() {
    let headers = HTTPHeaders([
      ("Set-Cookie", "a=1"),
      ("Set-Cookie", "b=2"),
    ])
    XCTAssertEqual(headers.serialized, "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n")
  }
}
