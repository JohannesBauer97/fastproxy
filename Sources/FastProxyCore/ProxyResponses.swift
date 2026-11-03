import Foundation

enum ProxyResponses {
  static func send(
    status: Int,
    reason: String,
    body: Data = Data(),
    to connection: NWConnectionIO
  ) async {
    var response = "HTTP/1.1 \(status) \(reason)\r\n"
    response += "Content-Length: \(body.count)\r\n"
    response += "Connection: close\r\n\r\n"
    var data = Data(response.utf8)
    data.append(body)
    try? await connection.send(data)
    try? await connection.sendEOF()
  }

  static func badRequest(to connection: NWConnectionIO) async {
    await send(status: 400, reason: "Bad Request", to: connection)
  }

  static func badGateway(to connection: NWConnectionIO) async {
    await send(status: 502, reason: "Bad Gateway", to: connection)
  }

  static func payloadTooLarge(to connection: NWConnectionIO) async {
    await send(status: 413, reason: "Payload Too Large", to: connection)
  }

  static func health(to connection: NWConnectionIO) async {
    await send(status: 200, reason: "OK", body: Data("OK".utf8), to: connection)
  }
}
