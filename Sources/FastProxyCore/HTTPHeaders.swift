import Foundation

public struct HTTPHeader: Equatable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public struct HTTPHeaders: Equatable, Sendable, Sequence {
  private var storage: [HTTPHeader]

  public init(_ headers: [(String, String)] = []) {
    self.storage = headers.map { HTTPHeader(name: $0.0, value: $0.1) }
  }

  public init(_ headers: [HTTPHeader]) {
    self.storage = headers
  }

  public var count: Int { storage.count }
  public var isEmpty: Bool { storage.isEmpty }

  public func makeIterator() -> IndexingIterator<[HTTPHeader]> {
    storage.makeIterator()
  }

  public func values(named name: String) -> [String] {
    storage.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
  }

  public func firstValue(named name: String) -> String? {
    values(named: name).first
  }

  public func contains(_ name: String) -> Bool {
    !values(named: name).isEmpty
  }

  public mutating func removeAll(named name: String) {
    storage.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  public mutating func set(_ value: String, for name: String) {
    removeAll(named: name)
    storage.append(HTTPHeader(name: name, value: value))
  }

  public mutating func append(_ value: String, for name: String) {
    storage.append(HTTPHeader(name: name, value: value))
  }

  public var serialized: String {
    storage.map { "\($0.name): \($0.value)\r\n" }.joined()
  }

  public static func parse(_ headerSection: String) -> HTTPHeaders {
    var headers = HTTPHeaders()
    var lastIndex: Int?

    for rawLine in headerSection.components(separatedBy: "\r\n") where !rawLine.isEmpty {
      if rawLine.first == " " || rawLine.first == "\t", let index = lastIndex {
        headers.storage[index].value += " " + rawLine.trimmingCharacters(in: .whitespaces)
        continue
      }

      guard let colon = rawLine.firstIndex(of: ":") else { continue }
      let name = String(rawLine[..<colon]).trimmingCharacters(in: .whitespaces)
      let value = String(rawLine[rawLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { continue }
      headers.storage.append(HTTPHeader(name: name, value: value))
      lastIndex = headers.storage.count - 1
    }

    return headers
  }
}
