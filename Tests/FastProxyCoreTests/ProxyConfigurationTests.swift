import XCTest
@testable import FastProxyCore

final class ProxyConfigurationTests: XCTestCase {
  func testDecodesDotNetAppSettingsShape() throws {
    let json = """
    {
      "Proxy": {
        "Listen": "127.0.0.1",
        "Port": 3129,
        "UpstreamProxy": "proxy.example.com:8080",
        "FailoverProxy": "fallback.example.com:8080",
        "NoProxy": ["localhost", "*.example.com"],
        "BufferSize": 16384,
        "ConnectionTimeout": 12
      },
      "Logging": { "LogLevel": { "Default": "Debug" } }
    }
    """
    let config = try ProxyConfiguration.decode(from: Data(json.utf8))
    XCTAssertEqual(config.listen, "127.0.0.1")
    XCTAssertEqual(config.port, 3129)
    XCTAssertEqual(config.upstreamProxy, "proxy.example.com:8080")
    XCTAssertEqual(config.failoverProxy, "fallback.example.com:8080")
    XCTAssertEqual(config.noProxy, ["localhost", "*.example.com"])
    XCTAssertEqual(config.bufferSize, 16384)
    XCTAssertEqual(config.connectionTimeout, 12)
    XCTAssertEqual(config.logLevel, .debug)
  }

  func testMissingOptionalValuesUseSafeDefaults() throws {
    let config = try ProxyConfiguration.decode(from: Data("{}".utf8))
    XCTAssertEqual(config.listen, "127.0.0.1")
    XCTAssertEqual(config.port, 3129)
    XCTAssertEqual(config.upstreamProxy, "")
    XCTAssertNil(config.failoverProxy)
    XCTAssertEqual(config.noProxy, [])
    XCTAssertEqual(config.bufferSize, 8192)
    XCTAssertEqual(config.connectionTimeout, 20)
    XCTAssertEqual(config.logLevel, .information)
  }

  func testValidationRejectsInvalidPort() {
    var config = ProxyConfiguration.default
    config.port = -1
    XCTAssertThrowsError(try config.validate())
    config.port = 65536
    XCTAssertThrowsError(try config.validate())
    config.port = 3129
    XCTAssertNoThrow(try config.validate())
  }

  func testValidationRejectsNonLoopbackListenWhenRequested() {
    var config = ProxyConfiguration.default
    config.listen = "example.com"
    XCTAssertThrowsError(try config.validate())
  }

  func testProxyListSkipsEmptyValues() {
    var config = ProxyConfiguration.default
    config.upstreamProxy = "one.example.com:8080"
    config.failoverProxy = ""
    XCTAssertEqual(config.proxyEndpoints.map(\.host), ["one.example.com"])

    config.failoverProxy = "two.example.com:8081"
    XCTAssertEqual(config.proxyEndpoints.map(\.host), ["one.example.com", "two.example.com"])
  }

  func testRoundTripsThroughJSON() throws {
    var config = ProxyConfiguration.default
    config.port = 4123
    config.upstreamProxy = "proxy.example.com:8080"
    config.noProxy = ["localhost"]
    let data = try config.encoded()
    let decoded = try ProxyConfiguration.decode(from: data)
    XCTAssertEqual(decoded.port, 4123)
    XCTAssertEqual(decoded.upstreamProxy, "proxy.example.com:8080")
    XCTAssertEqual(decoded.noProxy, ["localhost"])
  }
}
