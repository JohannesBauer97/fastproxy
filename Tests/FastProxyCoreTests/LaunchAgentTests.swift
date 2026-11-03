import Foundation
import XCTest
@testable import FastProxyCore

final class LaunchAgentTests: XCTestCase {
  func testInstallWritesExpectedLaunchAgent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fastproxy-launchagent-\(UUID().uuidString)", isDirectory: true)
    let plistURL = root.appendingPathComponent("com.johannesbauer.fastproxy.plist")
    let logDirectory = root.appendingPathComponent("logs")
    let executable = URL(fileURLWithPath: "/Applications/FastProxy.app/Contents/MacOS/FastProxy")
    defer { try? FileManager.default.removeItem(at: root) }

    try LaunchAgent.install(
      executableURL: executable,
      logDirectory: logDirectory,
      plistURL: plistURL
    )

    XCTAssertTrue(LaunchAgent.isInstalled(plistURL: plistURL))
    let data = try Data(contentsOf: plistURL)
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    )
    XCTAssertEqual(plist["Label"] as? String, "com.johannesbauer.fastproxy")
    XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
    XCTAssertEqual(
      plist["ProgramArguments"] as? [String],
      [executable.path, "--background"]
    )
    XCTAssertEqual(
      plist["StandardErrorPath"] as? String,
      logDirectory.appendingPathComponent("launchd.stderr.log").path
    )
  }

  func testUninstallRemovesPlist() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fastproxy-launchagent-\(UUID().uuidString)", isDirectory: true)
    let plistURL = root.appendingPathComponent("agent.plist")
    defer { try? FileManager.default.removeItem(at: root) }

    try LaunchAgent.install(
      executableURL: URL(fileURLWithPath: "/tmp/FastProxy"),
      logDirectory: root.appendingPathComponent("logs"),
      plistURL: plistURL
    )
    XCTAssertTrue(LaunchAgent.isInstalled(plistURL: plistURL))

    LaunchAgent.uninstall(plistURL: plistURL, runLaunchctl: false)
    XCTAssertFalse(LaunchAgent.isInstalled(plistURL: plistURL))
  }
}
