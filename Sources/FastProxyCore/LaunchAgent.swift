import Foundation

/// Writes the per-user LaunchAgent used for "Launch at login".
public enum LaunchAgent {
  public static let defaultLabel = "com.johannesbauer.fastproxy"

  public static var defaultPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(defaultLabel).plist")
  }

  public static func isInstalled(plistURL: URL = defaultPlistURL) -> Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
  }

  public static func plist(
    executableURL: URL,
    logDirectory: URL,
    label: String = defaultLabel
  ) -> [String: Any] {
    [
      "Label": label,
      "ProgramArguments": [executableURL.path, "--background"],
      "RunAtLoad": true,
      "KeepAlive": false,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
      "StandardOutPath": logDirectory.appendingPathComponent("launchd.stdout.log").path,
      "StandardErrorPath": logDirectory.appendingPathComponent("launchd.stderr.log").path,
    ]
  }

  public static func install(
    executableURL: URL,
    logDirectory: URL,
    plistURL: URL = defaultPlistURL,
    label: String = defaultLabel
  ) throws {
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let data = try PropertyListSerialization.data(
      fromPropertyList: plist(executableURL: executableURL, logDirectory: logDirectory, label: label),
      format: .xml,
      options: 0
    )
    try data.write(to: plistURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
  }

  public static func uninstall(
    plistURL: URL = defaultPlistURL,
    label: String = defaultLabel,
    runLaunchctl: Bool = true
  ) {
    if runLaunchctl {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try? process.run()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: plistURL)
  }
}
