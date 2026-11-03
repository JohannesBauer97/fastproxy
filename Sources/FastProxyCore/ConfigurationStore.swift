import Foundation

public struct ConfigurationStore: Sendable {
  public let fileURL: URL
  public let logDirectory: URL

  public init(fileURL: URL? = nil) {
    let resolved = fileURL ?? Self.defaultDirectory().appendingPathComponent("appsettings.json")
    self.fileURL = resolved
    self.logDirectory = resolved.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
  }

  public static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("FastProxy", isDirectory: true)
  }

  public static func legacyConfigurationURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".fastproxy/appsettings.json")
  }

  public func loadOrCreate() throws -> ProxyConfiguration {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return try load()
    }

    var configuration = ProxyConfiguration.default
    let defaultFileURL = Self.defaultDirectory().appendingPathComponent("appsettings.json")
    let isDefaultLocation = fileURL.standardizedFileURL == defaultFileURL.standardizedFileURL

    if isDefaultLocation, let legacy = (try? importLegacyConfiguration()) ?? nil {
      configuration = legacy
      // The legacy service normally owns 3128. Avoid colliding with it on first run.
      if configuration.port == 3128 {
        configuration.port = 3129
      }
    }
    try save(configuration)
    return configuration
  }

  public func load() throws -> ProxyConfiguration {
    let data = try Data(contentsOf: fileURL)
    return try ProxyConfiguration.decode(from: data)
  }

  public func save(_ configuration: ProxyConfiguration) throws {
    try configuration.validate()
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try configuration.encoded()
    try data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func importLegacyConfiguration() throws -> ProxyConfiguration? {
    let legacyURL = Self.legacyConfigurationURL()
    guard FileManager.default.fileExists(atPath: legacyURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: legacyURL)
    return try ProxyConfiguration.decode(from: data)
  }
}
