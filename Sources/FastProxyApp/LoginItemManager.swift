import FastProxyCore
import Foundation

enum LoginItemError: LocalizedError {
  case notAppBundle

  var errorDescription: String? {
    switch self {
    case .notAppBundle:
      return "Launch at login requires the installed FastProxy.app bundle."
    }
  }
}

enum LoginItemManager {
  static var isEnabled: Bool {
    LaunchAgent.isInstalled()
  }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try install()
    } else {
      LaunchAgent.uninstall()
    }
  }

  static func refreshIfEnabled() {
    guard isEnabled, Bundle.main.bundleURL.pathExtension == "app" else { return }
    try? install()
  }

  static func install() throws {
    guard let executable = Bundle.main.executableURL,
          Bundle.main.bundleURL.pathExtension == "app"
    else {
      throw LoginItemError.notAppBundle
    }

    try LaunchAgent.install(
      executableURL: executable,
      logDirectory: ConfigurationStore().logDirectory
    )
  }
}
