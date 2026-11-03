import Foundation
import XCTest
@testable import FastProxyCore

final class ConfigurationStoreTests: XCTestCase {
  func testLoadOrCreateWritesDefaultConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fastproxy-config-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("appsettings.json")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ConfigurationStore(fileURL: fileURL)
    let configuration = try store.loadOrCreate()

    XCTAssertEqual(configuration.port, 3128)
    XCTAssertEqual(configuration.upstreamProxy, "")
    XCTAssertEqual(configuration.noProxy, ProxyConfiguration.default.noProxy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(store.logDirectory.lastPathComponent, "logs")
  }

  func testSaveAndLoadRoundTrip() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fastproxy-config-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("appsettings.json")
    defer { try? FileManager.default.removeItem(at: root) }

    var configuration = ProxyConfiguration.default
    configuration.port = 4123
    configuration.upstreamProxy = "proxy.example.com:8080"
    configuration.noProxy = ["localhost", "10.*.*.*"]

    let store = ConfigurationStore(fileURL: fileURL)
    try store.save(configuration)
    let loaded = try store.load()
    XCTAssertEqual(loaded, configuration)

    let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }
}
