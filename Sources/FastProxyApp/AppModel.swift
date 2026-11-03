import AppKit
import Combine
import FastProxyCore
import Foundation

@MainActor
final class AppModel: ObservableObject {
  enum Status: Equatable {
    case stopped
    case starting
    case running(Int)
    case failed(String)
  }

  @Published private(set) var status: Status = .stopped
  @Published private(set) var configuration: ProxyConfiguration
  @Published private(set) var launchAtLogin: Bool
  @Published var errorMessage: String?

  let store: ConfigurationStore

  private var logger: FileProxyLogger
  private var server: ProxyServer?
  private var operation: Task<Void, Never>?

  init(store: ConfigurationStore = ConfigurationStore()) {
    self.store = store

    let initialConfiguration: ProxyConfiguration
    let initialError: String?
    if let loaded = try? store.loadOrCreate() {
      initialConfiguration = loaded
      initialError = nil
    } else {
      initialConfiguration = .default
      initialError = "Could not read configuration; using defaults."
    }

    self.configuration = initialConfiguration
    self.errorMessage = initialError
    self.logger = FileProxyLogger(
      directory: store.logDirectory,
      minimumLevel: initialConfiguration.logLevel
    )
    self.launchAtLogin = LoginItemManager.isEnabled
    LoginItemManager.refreshIfEnabled()
    start()
  }

  var isRunning: Bool {
    if case .running = status { return true }
    return false
  }

  var isStarting: Bool {
    status == .starting
  }

  var statusText: String {
    switch status {
    case .stopped: return "Stopped"
    case .starting: return "Starting…"
    case .running(let port): return "Running on \(configuration.listen):\(port)"
    case .failed(let message): return "Error: \(message)"
    }
  }

  var proxyAddress: String? {
    guard case .running(let port) = status else { return nil }
    return "http://\(configuration.listen):\(port)"
  }

  func start() {
    guard server == nil else { return }
    status = .starting
    errorMessage = nil

    let server = ProxyServer(configuration: configuration, logger: logger)
    self.server = server
    operation?.cancel()
    operation = Task { [weak self] in
      do {
        let port = try await server.start()
        guard let self else {
          await server.stop()
          return
        }
        if Task.isCancelled {
          await server.stop()
          return
        }
        self.status = .running(port)
        self.errorMessage = nil
        self.logger.info("Proxy started on \(self.configuration.listen):\(port)")
      } catch {
        guard let self else { return }
        self.server = nil
        self.status = .failed(error.localizedDescription)
        self.errorMessage = error.localizedDescription
        self.logger.error("Proxy start failed: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    operation?.cancel()
    operation = nil
    let runningServer = server
    server = nil
    status = .stopped
    Task {
      await runningServer?.stop()
    }
  }

  func restart() {
    operation?.cancel()
    operation = nil
    let oldServer = server
    server = nil
    status = .stopped
    Task {
      await oldServer?.stop()
      self.start()
    }
  }

  func apply(_ newConfiguration: ProxyConfiguration) async throws {
    try newConfiguration.validate()
    let wasRunning = isRunning || isStarting

    operation?.cancel()
    operation = nil
    let oldServer = server
    server = nil
    status = .stopped
    await oldServer?.stop()

    try store.save(newConfiguration)
    configuration = newConfiguration
    logger = FileProxyLogger(
      directory: store.logDirectory,
      minimumLevel: newConfiguration.logLevel
    )
    errorMessage = nil
    if wasRunning {
      start()
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try LoginItemManager.setEnabled(enabled)
      launchAtLogin = enabled
      errorMessage = nil
    } catch {
      launchAtLogin = LoginItemManager.isEnabled
      errorMessage = error.localizedDescription
    }
  }

  func copyProxyAddress() {
    guard let proxyAddress else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(proxyAddress, forType: .string)
  }

  func openConfig() {
    if !FileManager.default.fileExists(atPath: store.fileURL.path) {
      try? store.save(configuration)
    }
    NSWorkspace.shared.open(store.fileURL)
  }

  func openLogs() {
    try? FileManager.default.createDirectory(at: store.logDirectory, withIntermediateDirectories: true)
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.logDirectory.path)
  }

  func quit() {
    stop()
    NSApplication.shared.terminate(nil)
  }
}
