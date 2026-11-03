import XCTest
@testable import FastProxyCore

final class GSSAuthenticatorTests: XCTestCase {
  func testInitialTokenAgainstConfiguredKerberosEnvironment() throws {
    guard let proxyHost = ProcessInfo.processInfo.environment["FASTPROXY_GSS_TEST_HOST"],
          !proxyHost.isEmpty
    else {
      throw XCTSkip("Set FASTPROXY_GSS_TEST_HOST to a host with a Kerberos service ticket.")
    }

    let session = try GSSProxyAuthenticator().makeSession(proxyHost: proxyHost)
    defer { session.close() }

    let token = try session.initialToken()
    XCTAssertNotNil(token)
    XCTAssertFalse(token?.isEmpty ?? true)
    if let token {
      XCTAssertNotNil(Data(base64Encoded: token), "The token must be valid base64.")
    }
  }

  func testSessionReportsClosedContext() throws {
    guard let proxyHost = ProcessInfo.processInfo.environment["FASTPROXY_GSS_TEST_HOST"],
          !proxyHost.isEmpty
    else {
      throw XCTSkip("Set FASTPROXY_GSS_TEST_HOST to a host with a Kerberos service ticket.")
    }

    let session = try GSSProxyAuthenticator().makeSession(proxyHost: proxyHost)
    session.close()
    XCTAssertThrowsError(try session.initialToken())
  }
}
