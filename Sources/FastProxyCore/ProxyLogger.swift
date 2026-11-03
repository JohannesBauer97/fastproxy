import Foundation

public protocol ProxyLogging: Sendable {
  func log(_ level: ProxyLogLevel, _ message: String)
}

public struct NullProxyLogger: ProxyLogging {
  public init() {}
  public func log(_ level: ProxyLogLevel, _ message: String) {}
}

public final class FileProxyLogger: ProxyLogging, @unchecked Sendable {
  private let queue = DispatchQueue(label: "fastproxy.logger")
  private let minimumLevel: ProxyLogLevel
  private let directory: URL
  private let fileURL: URL
  private let alsoPrint: Bool
  private let formatter: ISO8601DateFormatter
  private var fileHandle: FileHandle?
  private var bytesWritten: UInt64 = 0

  private static let maximumFileSize: UInt64 = 10 * 1024 * 1024
  private static let retainedFiles = 7

  public init(directory: URL, minimumLevel: ProxyLogLevel = .information, alsoPrint: Bool = false) {
    self.directory = directory
    self.fileURL = directory.appendingPathComponent("fastproxy.log")
    self.minimumLevel = minimumLevel
    self.alsoPrint = alsoPrint
    self.formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    openLogFile()
  }

  deinit {
    queue.sync {
      try? fileHandle?.close()
    }
  }

  public func log(_ level: ProxyLogLevel, _ message: String) {
    guard level.priority >= minimumLevel.priority else { return }
    let line = "\(formatter.string(from: Date())) [\(label(for: level))] \(message)\n"
    if alsoPrint {
      FileHandle.standardError.write(Data(line.utf8))
    }
    queue.async { [weak self] in
      self?.write(line)
    }
  }

  public func flush() {
    queue.sync {
      try? fileHandle?.synchronize()
    }
  }

  private func write(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    if bytesWritten + UInt64(data.count) > Self.maximumFileSize {
      rotate()
    }
    guard let fileHandle else { return }
    do {
      try fileHandle.write(contentsOf: data)
      bytesWritten += UInt64(data.count)
    } catch {
      // Logging must never break the proxy.
    }
  }

  private func openLogFile() {
    let manager = FileManager.default
    if !manager.fileExists(atPath: fileURL.path) {
      manager.createFile(atPath: fileURL.path, contents: nil)
    }
    fileHandle = try? FileHandle(forWritingTo: fileURL)
    bytesWritten = (try? fileHandle?.seekToEnd()) ?? 0
  }

  private func rotate() {
    try? fileHandle?.close()
    fileHandle = nil
    let stamp = Self.archiveFormatter.string(from: Date())
    let archive = directory.appendingPathComponent("fastproxy-\(stamp).log")
    try? FileManager.default.moveItem(at: fileURL, to: archive)
    openLogFile()
    pruneArchives()
  }

  private func pruneArchives() {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else {
      return
    }

    let archives = files
      .filter { $0.lastPathComponent.hasPrefix("fastproxy-") && $0.pathExtension == "log" }
      .sorted { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return left > right
      }

    for archive in archives.dropFirst(Self.retainedFiles) {
      try? FileManager.default.removeItem(at: archive)
    }
  }

  private func label(for level: ProxyLogLevel) -> String {
    switch level {
    case .trace: return "TRACE"
    case .debug: return "DEBUG"
    case .information: return "INFO"
    case .warning: return "WARN"
    case .error: return "ERROR"
    case .critical: return "CRIT"
    }
  }

  private static let archiveFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
  }()
}

extension ProxyLogLevel {
  var priority: Int {
    switch self {
    case .trace: return 0
    case .debug: return 1
    case .information: return 2
    case .warning: return 3
    case .error: return 4
    case .critical: return 5
    }
  }
}

public extension ProxyLogging {
  func trace(_ message: String) { log(.trace, message) }
  func debug(_ message: String) { log(.debug, message) }
  func info(_ message: String) { log(.information, message) }
  func warning(_ message: String) { log(.warning, message) }
  func error(_ message: String) { log(.error, message) }
  func critical(_ message: String) { log(.critical, message) }
}
