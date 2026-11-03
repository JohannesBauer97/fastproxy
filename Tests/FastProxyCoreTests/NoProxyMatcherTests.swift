import XCTest
@testable import FastProxyCore

final class NoProxyMatcherTests: XCTestCase {
  func testExactMatchesAreCaseInsensitive() {
    let matcher = NoProxyMatcher(patterns: ["LocalHost", "host.docker.internal"])
    XCTAssertTrue(matcher.matches(host: "localhost"))
    XCTAssertTrue(matcher.matches(host: "HOST.DOCKER.INTERNAL"))
    XCTAssertFalse(matcher.matches(host: "google.com"))
  }

  func testWildcardPatterns() {
    let matcher = NoProxyMatcher(patterns: ["10.*.*.*", "192.168.*.*"])
    XCTAssertTrue(matcher.matches(host: "10.0.0.1"))
    XCTAssertTrue(matcher.matches(host: "10.255.255.255"))
    XCTAssertTrue(matcher.matches(host: "192.168.1.1"))
    XCTAssertFalse(matcher.matches(host: "11.0.0.1"))
  }

  func testDomainSuffixPatterns() {
    let matcher = NoProxyMatcher(patterns: ["*.example.com"])
    XCTAssertTrue(matcher.matches(host: "sub.example.com"))
    XCTAssertTrue(matcher.matches(host: "deep.sub.example.com"))
    XCTAssertTrue(matcher.matches(host: "example.com"))
    XCTAssertFalse(matcher.matches(host: "notexample.com"))
  }

  func testCIDRPatterns() {
    let matcher = NoProxyMatcher(patterns: ["192.168.1.0/24", "2001:db8::/32"])
    XCTAssertTrue(matcher.matches(host: "192.168.1.1"))
    XCTAssertTrue(matcher.matches(host: "192.168.1.254"))
    XCTAssertFalse(matcher.matches(host: "192.168.2.1"))
    XCTAssertTrue(matcher.matches(host: "2001:db8::1"))
    XCTAssertFalse(matcher.matches(host: "2001:db9::1"))
  }

  func testEmptyPatternListMatchesNothing() {
    let matcher = NoProxyMatcher(patterns: [])
    XCTAssertFalse(matcher.matches(host: "anything.com"))
  }

  func testWhitespaceAndEmptyPatternsAreIgnored() {
    let matcher = NoProxyMatcher(patterns: ["", "  ", " localhost "])
    XCTAssertTrue(matcher.matches(host: "localhost"))
    XCTAssertFalse(matcher.matches(host: ""))
  }
}
