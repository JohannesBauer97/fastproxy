import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}

@main
struct FastProxyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(model: model)
    } label: {
      Image(nsImage: StatusIcon.image(for: model.status))
        .accessibilityLabel("FastProxy \(model.statusText)")
    }
    .menuBarExtraStyle(.menu)

    Window("FastProxy Settings", id: "settings") {
      SettingsView(model: model)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 640, height: 720)
  }
}
