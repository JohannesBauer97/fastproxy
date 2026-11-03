import Foundation
import FastProxyCore

private struct CLIOptions {
  var configPath: URL?
  var port: Int?
  var listen: String?
  var upstream: String?
  var failover: String?
  var noProxy: [String]?
  var logLevel: ProxyLogLevel?
  var logDirectory: URL?
  var installLoginItem: URL?
  var uninstallLoginItem = false
  var help = false
}

private enum CLIParseError: LocalizedError {
  case missingValue(String)
  case invalidValue(String, String)
  case unknownOption(String)

  var errorDescription: String? {
    switch self {
    case .missingValue(let option):
      return "Missing value for \(option)."
    case .invalidValue(let option, let value):
      return "Invalid value for \(option): \(value)"
    case .unknownOption(let option):
      return "Unknown option: \(option)"
    }
  }
}

private func parseArguments(_ arguments: [String]) throws -> CLIOptions {
  var options = CLIOptions()
  var index = 0

  func value(for option: String) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw CLIParseError.missingValue(option)
    }
    return arguments[index]
  }

  while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--help", "-h":
      options.help = true
    case "--config":
      options.configPath = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
    case "--port":
      let text = try value(for: argument)
      guard let port = Int(text) else {
        throw CLIParseError.invalidValue(argument, text)
      }
      options.port = port
    case "--listen":
      options.listen = try value(for: argument)
    case "--upstream":
      options.upstream = try value(for: argument)
    case "--failover":
      options.failover = try value(for: argument)
    case "--no-proxy":
      let raw = try value(for: argument)
      options.noProxy = raw
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    case "--log-level":
      let raw = try value(for: argument)
      guard let level = ProxyLogLevel(rawValue: raw.lowercased()) else {
        throw CLIParseError.invalidValue(argument, raw)
      }
      options.logLevel = level
    case "--log-dir":
      options.logDirectory = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
    case "--install-login-item":
      options.installLoginItem = URL(fileURLWithPath: try value(for: argument)).standardizedFileURL
    case "--uninstall-login-item":
      options.uninstallLoginItem = true
    default:
      throw CLIParseError.unknownOption(argument)
    }
    index += 1
  }

  return options
}

private func printUsage() {
  print(
    """
    Usage: fastproxy-cli [options]

      --config PATH       appsettings.json path (default: Application Support)
      --port PORT         Listening port (default: 3128)
      --listen ADDRESS    Listening address (default: 127.0.0.1)
      --upstream HOST:PORT
                          Primary upstream proxy
      --failover HOST:PORT
                          Failover upstream proxy
      --no-proxy LIST     Comma-separated no-proxy patterns
      --log-level LEVEL   trace, debug, information, warning, error, critical
      --log-dir PATH      Log directory
      --install-login-item APP
                          Install a LaunchAgent that starts APP at login
      --uninstall-login-item
                          Remove the LaunchAgent
      --help              Show this help
    """
  )
}

private final class SignalWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "fastproxy.signals")
  private var continuation: CheckedContinuation<Void, Never>?
  private var sources: [DispatchSourceSignal] = []

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      self.continuation = continuation
      lock.unlock()

      for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler { [weak self] in
          self?.resume()
        }
        source.resume()
        sources.append(source)
      }
    }
  }

  private func resume() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }

  deinit {
    sources.forEach { $0.cancel() }
  }
}

do {
  let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
  if options.help {
    printUsage()
    exit(0)
  }

  if let appURL = options.installLoginItem {
    let executable: URL
    if appURL.pathExtension == "app" {
      executable = appURL.appendingPathComponent("Contents/MacOS/FastProxy")
    } else {
      executable = appURL
    }
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw CLIParseError.invalidValue("--install-login-item", appURL.path)
    }
    try LaunchAgent.install(
      executableURL: executable,
      logDirectory: ConfigurationStore().logDirectory
    )
    print("Installed \(LaunchAgent.defaultPlistURL.path)")
    exit(0)
  }

  if options.uninstallLoginItem {
    LaunchAgent.uninstall()
    print("Removed \(LaunchAgent.defaultPlistURL.path)")
    exit(0)
  }

  let store = ConfigurationStore(fileURL: options.configPath)
  var configuration = try store.loadOrCreate()

  if let port = options.port { configuration.port = port }
  if let listen = options.listen { configuration.listen = listen }
  if let upstream = options.upstream { configuration.upstreamProxy = upstream }
  if let failover = options.failover {
    configuration.failoverProxy = failover.isEmpty ? nil : failover
  }
  if let noProxy = options.noProxy { configuration.noProxy = noProxy }
  if let logLevel = options.logLevel { configuration.logLevel = logLevel }
  try configuration.validate()

  let logDirectory = options.logDirectory ?? store.logDirectory
  let logger = FileProxyLogger(
    directory: logDirectory,
    minimumLevel: configuration.logLevel,
    alsoPrint: true
  )
  let server = ProxyServer(configuration: configuration, logger: logger)

  let port = try await server.start()
  print("FASTPROXY_READY port=\(port) listen=\(configuration.listen)")
  fflush(stdout)
  logger.info("Configuration: \(store.fileURL.path)")

  let signalWaiter = SignalWaiter()
  await signalWaiter.wait()

  logger.info("Shutdown requested")
  await server.stop()
  logger.flush()
  exit(0)
} catch {
  FileHandle.standardError.write(Data("fastproxy-cli: \(error.localizedDescription)\n".utf8))
  exit(1)
}
