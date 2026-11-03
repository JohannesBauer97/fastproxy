import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  @State private var listen = "127.0.0.1"
  @State private var port = "3128"
  @State private var upstream = ""
  @State private var failover = ""
  @State private var noProxy = ""
  @State private var bufferSize = "8192"
  @State private var timeout = "20"
  @State private var launchAtLogin = false
  @State private var saveError: String?
  @State private var saved = false

  var body: some View {
    Form {
      Section("Status") {
        LabeledContent("Proxy") {
          HStack(spacing: 8) {
            Circle()
              .fill(statusColor)
              .frame(width: 9, height: 9)
            Text(model.statusText)
          }
        }
        if let error = saveError ?? model.errorMessage {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Listener") {
        TextField("Listen address", text: $listen)
        TextField("Port", text: $port)
        Text("The default port is 3128.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Upstream proxies") {
        TextField("Upstream proxy", text: $upstream, prompt: Text("proxy.example.com:8080"))
        TextField("Failover proxy", text: $failover, prompt: Text("optional"))
        Text("Kerberos/Negotiate authentication uses your existing macOS ticket (klist).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("No-proxy patterns") {
        TextEditor(text: $noProxy)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 110)
        Text("One pattern per line. Exact hosts, wildcards (*.example.com or 10.*.*.*), and CIDR ranges are supported.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Advanced") {
        TextField("Buffer size (bytes)", text: $bufferSize)
        TextField("Connection timeout (seconds)", text: $timeout)
      }

      Section("Startup") {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { newValue in
            model.setLaunchAtLogin(newValue)
          }
        Text("The menu bar app starts the proxy automatically when it launches.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Button("Save & Restart") {
            save()
          }
          .keyboardShortcut(.defaultAction)

          Button("Start") {
            model.start()
          }
          .disabled(model.isRunning || model.isStarting)

          Button("Stop") {
            model.stop()
          }
          .disabled(!model.isRunning && !model.isStarting)

          Spacer()

          Button("Open Config") {
            model.openConfig()
          }
          Button("Open Logs") {
            model.openLogs()
          }
        }
        if saved {
          Text("Saved.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding(20)
    .frame(minWidth: 600, minHeight: 680)
    .onAppear(perform: load)
    .onChange(of: model.launchAtLogin) { newValue in
      launchAtLogin = newValue
    }
  }

  private var statusColor: Color {
    switch model.status {
    case .running: return .green
    case .starting: return .orange
    case .stopped, .failed: return .red
    }
  }

  private func load() {
    let configuration = model.configuration
    listen = configuration.listen
    port = String(configuration.port)
    upstream = configuration.upstreamProxy
    failover = configuration.failoverProxy ?? ""
    noProxy = configuration.noProxy.joined(separator: "\n")
    bufferSize = String(configuration.bufferSize)
    timeout = String(configuration.connectionTimeout)
    launchAtLogin = model.launchAtLogin
  }

  private func save() {
    saveError = nil
    saved = false

    guard let parsedPort = Int(port) else {
      saveError = "Port must be a number."
      return
    }
    guard let parsedBuffer = Int(bufferSize), let parsedTimeout = Int(timeout) else {
      saveError = "Buffer size and timeout must be numbers."
      return
    }

    var configuration = model.configuration
    configuration.listen = listen.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.port = parsedPort
    configuration.upstreamProxy = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    let failoverValue = failover.trimmingCharacters(in: .whitespacesAndNewlines)
    configuration.failoverProxy = failoverValue.isEmpty ? nil : failoverValue
    configuration.noProxy = noProxy
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    configuration.bufferSize = parsedBuffer
    configuration.connectionTimeout = parsedTimeout

    Task {
      do {
        try await model.apply(configuration)
        saved = true
      } catch {
        saveError = error.localizedDescription
      }
    }
  }
}
