import Foundation

enum RequestTargetForm {
  case origin
  case absolute
}

enum RequestHeadBuilder {
  static func build(
    _ request: ParsedHTTPRequest,
    form: RequestTargetForm,
    proxyAuthorization: String? = nil,
    forceClose: Bool,
    stripExpect: Bool
  ) -> Data {
    var headers = request.headers
    headers.removeAll(named: "Host")
    headers.removeAll(named: "Proxy-Connection")
    headers.removeAll(named: "Proxy-Authorization")
    headers.removeAll(named: "Proxy-Authenticate")
    headers.removeAll(named: "Connection")
    headers.removeAll(named: "Keep-Alive")
    if stripExpect {
      headers.removeAll(named: "Expect")
    }

    let isHTTPS = request.target.lowercased().hasPrefix("https://")
    let defaultPort = isHTTPS ? 443 : 80
    let host = request.host.contains(":") ? "[\(request.host)]" : request.host
    let hostHeader = request.port == defaultPort ? host : "\(host):\(request.port)"
    headers.set(hostHeader, for: "Host")

    if request.hasUpgrade {
      headers.set("Upgrade", for: "Connection")
    } else if forceClose {
      headers.set("close", for: "Connection")
    }

    if let proxyAuthorization {
      headers.set(proxyAuthorization, for: "Proxy-Authorization")
    }

    let target = form == .origin ? request.originFormTarget : request.absoluteFormTarget
    var head = "\(request.method) \(target) HTTP/1.1\r\n"
    head += headers.serialized
    head += "\r\n"
    return Data(head.utf8)
  }
}
