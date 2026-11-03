import Foundation
import Network

public enum ProxyLogLevel: String, Codable, CaseIterable, Sendable {
  case trace
  case debug
  case information
  case warning
  case error
  case critical

  public init(dotNetValue: String?) {
    switch dotNetValue?.lowercased() {
    case "trace": self = .trace
    case "debug": self = .debug
    case "warning", "warn": self = .warning
    case "error": self = .error
    case "critical", "fatal": self = .critical
    default: self = .information
    }
  }
}

/// Mirrors the .NET `ProxyOptions` section so existing appsettings.json files
/// can be reused unchanged.
public struct ProxyConfiguration: Equatable, Sendable {
  public var listen: String
  public var port: Int
  public var upstreamProxy: String
  public var failoverProxy: String?
  public var noProxy: [String]
  public var bufferSize: Int
  public var connectionTimeout: Int
  public var logLevel: ProxyLogLevel

  public static let `default` = ProxyConfiguration(
    listen: "127.0.0.1",
    port: 3128,
    upstreamProxy: "",
    failoverProxy: nil,
    noProxy: ["localhost", "127.0.0.1", "::1"],
    bufferSize: 8192,
    connectionTimeout: 20,
    logLevel: .information
  )

  public init(
    listen: String = "127.0.0.1",
    port: Int = 3128,
    upstreamProxy: String = "",
    failoverProxy: String? = nil,
    noProxy: [String] = [],
    bufferSize: Int = 8192,
    connectionTimeout: Int = 20,
    logLevel: ProxyLogLevel = .information
  ) {
    self.listen = listen
    self.port = port
    self.upstreamProxy = upstreamProxy
    self.failoverProxy = failoverProxy
    self.noProxy = noProxy
    self.bufferSize = bufferSize
    self.connectionTimeout = connectionTimeout
    self.logLevel = logLevel
  }

  public var proxyEndpoints: [HostPort] {
    [upstreamProxy, failoverProxy ?? ""]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .compactMap { HostPort.parse($0, defaultPort: 8080) }
  }

  public var bufferLength: Int {
    min(max(bufferSize, 1024), 1_048_576)
  }

  public var timeoutInterval: TimeInterval {
    TimeInterval(min(max(connectionTimeout, 1), 300))
  }

  public func validate() throws {
    // Port 0 asks the OS for an ephemeral port; the menu bar UI only offers 1...65535.
    guard (0...65535).contains(port) else {
      throw ConfigurationError.invalidPort(port)
    }

    guard Self.isValidListenAddress(listen) else {
      throw ConfigurationError.invalidListenAddress(listen)
    }

    guard (1024...1_048_576).contains(bufferSize) else {
      throw ConfigurationError.invalidBufferSize(bufferSize)
    }

    guard (1...300).contains(connectionTimeout) else {
      throw ConfigurationError.invalidTimeout(connectionTimeout)
    }

    for endpoint in [upstreamProxy, failoverProxy ?? ""] where !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard HostPort.parse(endpoint, defaultPort: 8080) != nil else {
        throw ConfigurationError.invalidProxyEndpoint(endpoint)
      }
    }
  }

  public static func decode(from data: Data) throws -> ProxyConfiguration {
    let file = try JSONDecoder().decode(ConfigurationFile.self, from: data)
    let section = file.proxy ?? ProxySection()
    return ProxyConfiguration(
      listen: section.listen ?? "127.0.0.1",
      port: section.port ?? 3128,
      upstreamProxy: section.upstreamProxy ?? "",
      failoverProxy: section.failoverProxy,
      noProxy: section.noProxy ?? [],
      bufferSize: section.bufferSize ?? 8192,
      connectionTimeout: section.connectionTimeout ?? 20,
      logLevel: ProxyLogLevel(dotNetValue: file.logging?.logLevel?.defaultValue)
    )
  }

  public func encoded(prettyPrinted: Bool = true) throws -> Data {
    let file = ConfigurationFile(
      proxy: ProxySection(
        listen: listen,
        port: port,
        upstreamProxy: upstreamProxy,
        failoverProxy: failoverProxy,
        noProxy: noProxy,
        bufferSize: bufferSize,
        connectionTimeout: connectionTimeout
      ),
      logging: LoggingSection(
        logLevel: LogLevelSection(defaultValue: logLevel == .information ? "Information" : logLevel.rawValue.capitalized)
      )
    )
    let encoder = JSONEncoder()
    var options: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
    if prettyPrinted {
      options.insert(.prettyPrinted)
      options.insert(.sortedKeys)
    }
    encoder.outputFormatting = options
    return try encoder.encode(file)
  }

  private static func isValidListenAddress(_ value: String) -> Bool {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if address == "localhost" { return true }
    return IPv4Address(address) != nil || IPv6Address(address) != nil
  }
}

public enum ConfigurationError: LocalizedError, Equatable {
  case invalidPort(Int)
  case invalidListenAddress(String)
  case invalidBufferSize(Int)
  case invalidTimeout(Int)
  case invalidProxyEndpoint(String)

  public var errorDescription: String? {
    switch self {
    case .invalidPort(let port):
      return "Port must be between 1 and 65535 (got \(port))."
    case .invalidListenAddress(let address):
      return "Listen address must be localhost or an IPv4/IPv6 address (got \(address))."
    case .invalidBufferSize(let size):
      return "Buffer size must be between 1024 and 1048576 bytes (got \(size))."
    case .invalidTimeout(let seconds):
      return "Connection timeout must be between 1 and 300 seconds (got \(seconds))."
    case .invalidProxyEndpoint(let endpoint):
      return "Upstream proxy must be host:port (got \(endpoint))."
    }
  }
}

private struct ConfigurationFile: Codable {
  var proxy: ProxySection?
  var logging: LoggingSection?

  enum CodingKeys: String, CodingKey {
    case proxy = "Proxy"
    case logging = "Logging"
  }
}

private struct ProxySection: Codable {
  var listen: String?
  var port: Int?
  var upstreamProxy: String?
  var failoverProxy: String?
  var noProxy: [String]?
  var bufferSize: Int?
  var connectionTimeout: Int?

  enum CodingKeys: String, CodingKey {
    case listen = "Listen"
    case port = "Port"
    case upstreamProxy = "UpstreamProxy"
    case failoverProxy = "FailoverProxy"
    case noProxy = "NoProxy"
    case bufferSize = "BufferSize"
    case connectionTimeout = "ConnectionTimeout"
  }

  init(
    listen: String? = nil,
    port: Int? = nil,
    upstreamProxy: String? = nil,
    failoverProxy: String? = nil,
    noProxy: [String]? = nil,
    bufferSize: Int? = nil,
    connectionTimeout: Int? = nil
  ) {
    self.listen = listen
    self.port = port
    self.upstreamProxy = upstreamProxy
    self.failoverProxy = failoverProxy
    self.noProxy = noProxy
    self.bufferSize = bufferSize
    self.connectionTimeout = connectionTimeout
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.listen = try container.decodeIfPresent(String.self, forKey: .listen)
    self.port = try container.decodeIfPresent(Int.self, forKey: .port)
    self.upstreamProxy = try container.decodeIfPresent(String.self, forKey: .upstreamProxy)
    self.failoverProxy = try container.decodeIfPresent(String.self, forKey: .failoverProxy)
    self.noProxy = try container.decodeIfPresent([String].self, forKey: .noProxy)
    self.bufferSize = try container.decodeIfPresent(Int.self, forKey: .bufferSize)
    self.connectionTimeout = try container.decodeIfPresent(Int.self, forKey: .connectionTimeout)
  }
}

private struct LoggingSection: Codable {
  var logLevel: LogLevelSection?

  enum CodingKeys: String, CodingKey {
    case logLevel = "LogLevel"
  }
}

private struct LogLevelSection: Codable {
  var defaultValue: String?

  enum CodingKeys: String, CodingKey {
    case defaultValue = "Default"
  }
}
