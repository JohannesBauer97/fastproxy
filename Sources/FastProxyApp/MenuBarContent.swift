import AppKit
import SwiftUI

struct MenuBarContent: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("About FastProxy") {
      NSApp.orderFrontStandardAboutPanel(nil)
    }

    Text(model.statusText)
      .font(.caption)
      .foregroundStyle(.secondary)

    if let error = model.errorMessage, !error.isEmpty, !model.isRunning {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    }

    Divider()

    Button("Start") {
      model.start()
    }
    .disabled(model.isRunning || model.isStarting)

    Button("Stop") {
      model.stop()
    }
    .disabled(!model.isRunning && !model.isStarting)

    Button("Restart") {
      model.restart()
    }
    .disabled(!model.isRunning && !model.isStarting)

    Divider()

    Button("Settings…") {
      openWindow(id: "settings")
      NSApp.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Button("Copy Proxy Address") {
      model.copyProxyAddress()
    }
    .disabled(model.proxyAddress == nil)

    Button("Open Config File") {
      model.openConfig()
    }

    Button("Open Logs") {
      model.openLogs()
    }

    Divider()

    Toggle("Launch at Login", isOn: Binding(
      get: { model.launchAtLogin },
      set: { model.setLaunchAtLogin($0) }
    ))

    Divider()

    Button("Quit FastProxy") {
      model.quit()
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}
