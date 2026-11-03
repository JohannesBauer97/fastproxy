import Foundation

/// Implements exact, suffix, wildcard, and CIDR matching rules.
public struct NoProxyMatcher: Sendable {
  private struct CIDRRange: Sendable {
    let network: [UInt8]
    let prefixLength: Int
  }

  private let exact: Set<String>
  private let domainSuffixes: [String]
  private let wildcards: [String]
  private let cidrRanges: [CIDRRange]

  public init(patterns: [String]) {
    var exact = Set<String>()
    var suffixes: [String] = []
    var wildcards: [String] = []
    var cidrs: [CIDRRange] = []

    for raw in patterns {
      let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !pattern.isEmpty else { continue }

      if pattern.contains("/"), let range = Self.parseCIDR(pattern) {
        cidrs.append(range)
      } else if pattern.hasPrefix("*.") {
        suffixes.append(String(pattern.dropFirst()))
      } else if pattern.contains("*") {
        wildcards.append(pattern)
      } else {
        exact.insert(pattern.lowercased())
      }
    }

    self.exact = exact
    self.domainSuffixes = suffixes
    self.wildcards = wildcards
    self.cidrRanges = cidrs
  }

  public func matches(host rawHost: String) -> Bool {
    var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    guard !host.isEmpty else { return false }

    if exact.contains(host.lowercased()) {
      return true
    }

    for suffix in domainSuffixes {
      if host.lowercased().hasSuffix(suffix.lowercased()) ||
        host.lowercased() == String(suffix.dropFirst()).lowercased()
      {
        return true
      }
    }

    for wildcard in wildcards where Self.wildcardMatch(host, pattern: wildcard) {
      return true
    }

    guard !cidrRanges.isEmpty, let address = Self.parseAddress(host) else {
      return false
    }

    return cidrRanges.contains { Self.isInSubnet(address, $0) }
  }

  private static func wildcardMatch(_ input: String, pattern: String) -> Bool {
    let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    var position = input.startIndex

    for (index, part) in parts.enumerated() {
      if part.isEmpty { continue }
      guard let range = input.range(of: part, options: .caseInsensitive, range: position..<input.endIndex) else {
        return false
      }
      if index == 0, range.lowerBound != input.startIndex {
        return false
      }
      position = range.upperBound
    }

    if let last = parts.last, !last.isEmpty {
      return input.lowercased().hasSuffix(last.lowercased())
    }
    return true
  }

  private static func parseCIDR(_ text: String) -> CIDRRange? {
    let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let address = parseAddress(String(parts[0])),
          let prefix = Int(parts[1]),
          prefix >= 0,
          prefix <= address.count * 8
    else {
      return nil
    }
    return CIDRRange(network: address, prefixLength: prefix)
  }

  private static func parseAddress(_ text: String) -> [UInt8]? {
    var ipv4 = in_addr()
    if inet_pton(AF_INET, text, &ipv4) == 1 {
      return withUnsafeBytes(of: &ipv4) { Array($0) }
    }

    var ipv6 = in6_addr()
    if inet_pton(AF_INET6, text, &ipv6) == 1 {
      return withUnsafeBytes(of: &ipv6) { Array($0) }
    }
    return nil
  }

  private static func isInSubnet(_ address: [UInt8], _ range: CIDRRange) -> Bool {
    guard address.count == range.network.count else { return false }
    let fullBytes = range.prefixLength / 8
    let remainingBits = range.prefixLength % 8

    for index in 0..<fullBytes where address[index] != range.network[index] {
      return false
    }

    if remainingBits > 0, fullBytes < address.count {
      let mask = UInt8(0xFF << (8 - remainingBits))
      if (address[fullBytes] & mask) != (range.network[fullBytes] & mask) {
        return false
      }
    }
    return true
  }
}
