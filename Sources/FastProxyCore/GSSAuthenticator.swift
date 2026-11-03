import CGSS
import Foundation

public protocol ProxyAuthenticationSession: AnyObject {
  /// Returns the first base64 Negotiate token, or nil when no credential is available.
  func initialToken() throws -> String?

  /// Consumes a base64 challenge token (possibly empty) and returns the next token.
  func nextToken(challenge: String?) throws -> String?

  func close()
}

public protocol ProxyAuthenticator: Sendable {
  func makeSession(proxyHost: String) throws -> ProxyAuthenticationSession
}

public struct GSSAuthenticationError: LocalizedError {
  public let message: String

  public var errorDescription: String? { message }
}

/// Kerberos/SPNEGO authentication through macOS' GSS.framework.
public final class GSSProxyAuthenticator: ProxyAuthenticator, @unchecked Sendable {
  public init() {}

  public func makeSession(proxyHost: String) throws -> ProxyAuthenticationSession {
    try GSSProxyAuthenticationSession(proxyHost: proxyHost)
  }
}

final class GSSProxyAuthenticationSession: ProxyAuthenticationSession {
  private var context: OpaquePointer?
  private let lock = NSLock()

  init(proxyHost: String) throws {
    var created: OpaquePointer?
    var errorBuffer = [CChar](repeating: 0, count: 512)
    let result = proxyHost.withCString { host in
      fp_gss_create(host, &created, &errorBuffer, errorBuffer.count)
    }
    if result != 0 {
      throw GSSAuthenticationError(message: String(cString: errorBuffer))
    }
    context = created
  }

  deinit {
    close()
  }

  func initialToken() throws -> String? {
    try step(token: nil)
  }

  func nextToken(challenge: String?) throws -> String? {
    try step(token: challenge)
  }

  private func step(token: String?) throws -> String? {
    lock.lock()
    defer { lock.unlock() }

    guard let context else {
      throw GSSAuthenticationError(message: "GSS context is closed.")
    }

    let challengeData = token.flatMap {
      Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters)
    }

    var output: UnsafeMutablePointer<UInt8>?
    var outputLength = 0
    var completed: Int32 = 0
    var errorBuffer = [CChar](repeating: 0, count: 512)

    let result: Int32 = challengeData.withUnsafeBytesOrNil { bytes in
      fp_gss_step(
        context,
        bytes?.bindMemory(to: UInt8.self).baseAddress,
        challengeData?.count ?? 0,
        &output,
        &outputLength,
        &completed,
        &errorBuffer,
        errorBuffer.count
      )
    }

    defer {
      if let output {
        fp_gss_buffer_free(output)
      }
    }

    if result != 0 {
      throw GSSAuthenticationError(message: String(cString: errorBuffer))
    }

    guard let output, outputLength > 0 else {
      return nil
    }
    return Data(bytes: output, count: outputLength).base64EncodedString()
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    if let context {
      fp_gss_destroy(context)
      self.context = nil
    }
  }
}

private extension Optional where Wrapped == Data {
  func withUnsafeBytesOrNil<Result>(_ body: (UnsafeRawBufferPointer?) throws -> Result) rethrows -> Result {
    guard let self else {
      return try body(nil)
    }
    return try self.withUnsafeBytes { try body($0) }
  }
}
