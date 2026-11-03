# FastProxy for macOS

FastProxy is a native macOS menu bar forward proxy for HTTP and HTTPS (CONNECT).
It is a clean-room Swift reimplementation of the .NET FastProxy, with the same
`appsettings.json` shape and the same goals:

- a fast local proxy for applications that need a corporate upstream proxy,
- Kerberos/SPNEGO (`Negotiate`) authentication through macOS' GSS.framework,
- upstream failover and no-proxy rules,
- a native menu bar UI instead of a separate installer-managed daemon,
- launch at login as a first-class feature.

The app has no .NET runtime dependency and no third-party network stack. It uses
Swift, SwiftUI/AppKit, Network.framework, and the system GSS framework.

## Features

- HTTP/1.1 forwarding and HTTPS `CONNECT` tunneling
- Kerberos/SPNEGO authentication against the upstream proxy
- Pre-emptive `Proxy-Authorization: Negotiate …` tokens plus 407 challenge/response
- Primary and failover upstream proxies, with DIRECT fallback
- `NoProxy` matching for exact hosts, `*.example.com` suffixes, wildcards such as
  `10.*.*.*`, and IPv4/IPv6 CIDR ranges
- Native menu bar status, start/stop/restart, settings window, config and log shortcuts
- Launch at login through a per-user LaunchAgent
- `GET /health` readiness endpoint
- Rolling log file
- Same configuration file as the .NET version, so existing upstream settings can be
  imported without translation

## Requirements

- macOS 13 or later
- Apple Silicon for the prebuilt release; source builds target the host architecture
- Xcode 15+ or Xcode Command Line Tools for building
- For an authenticated upstream: a valid Kerberos ticket (`klist`) and network access
  to the Kerberos KDC. The proxy service principal is normally
  `HTTP/<upstream-host>@<REALM>`.

## Install

### Homebrew

```bash
brew install --cask JohannesBauer97/tap/fastproxy
```

This installs `FastProxy.app` into `/Applications` and links the bundled
`fastproxy-cli` into Homebrew's `bin` directory. The cask requires macOS 13 or
later on Apple Silicon.

Upgrade and uninstall:

```bash
brew upgrade --cask fastproxy
brew uninstall --cask fastproxy
```

Use `brew uninstall --zap --cask fastproxy` to remove configuration and logs as
well.

### Prebuilt release

Download the latest `FastProxy-*-macos-arm64.zip` from
[Releases](https://github.com/JohannesBauer97/fastproxy/releases), unzip it, and
move `FastProxy.app` to `~/Applications`:

```bash
open ~/Applications/FastProxy.app
```

Release builds are signed with a Developer ID and notarized by Apple. If macOS
still blocks the app, open **System Settings → Privacy & Security** and choose
**Open Anyway**.

Then enable **Launch at Login** from the menu bar.

### From source

```bash
# Build the native app bundle in dist/
make app

# Install to ~/Applications, enable launch at login, and start it
./Scripts/install.sh
```

The app is LSUIElement (menu bar only). Local builds are ad-hoc signed.

## Releasing

Pushing a version tag triggers the release workflow, which runs the tests, builds
the Apple Silicon app bundle, and publishes the zip as a GitHub release:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The tag must look like `v1.2.3` (a pre-release suffix such as `v1.2.3-rc.1` is
also accepted). You can republish an existing tag from the **Actions** tab via
**Release → Run workflow**.

Release builds are signed with a Developer ID Application certificate, use the
hardened runtime, and are notarized and stapled by Apple. The certificate must be
exported with its private key; the API key is an App Store Connect team key with
notarization access. The workflow expects these repository secrets:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_KEY_P8_BASE64`

The certificate must be a **Developer ID Application** certificate exported with
its private key. An **Apple Development** certificate cannot be used for
notarization. Creating a Developer ID Application certificate requires an active
Apple Developer Program membership.

Stable releases also update the Homebrew tap in
[JohannesBauer97/homebrew-tap](https://github.com/JohannesBauer97/homebrew-tap).
Pre-release tags do not update the tap. The Homebrew workflow expects this
repository secret:

- `HOMEBREW_TAP_TOKEN` – fine-grained PAT with `Contents: Read and write` on the
  `homebrew-tap` repository

Users install with `brew install --cask JohannesBauer97/tap/fastproxy`.

## Default port

The default listening port is **3128**, the same default as the .NET FastProxy.
Change `Proxy.Port` if another service already uses 3128.

## Configuration

The app reads and writes:

```text
~/Library/Application Support/FastProxy/appsettings.json
```

On first start, if that file does not exist and the legacy file
`~/.fastproxy/appsettings.json` is present, it is imported unchanged. The runtime
configuration may contain private corporate hostnames; it is stored with mode `0600`
and is not part of this repository.

The schema is the same as the .NET version:

```json
{
  "Proxy": {
    "Listen": "127.0.0.1",
    "Port": 3128,
    "UpstreamProxy": "proxy.example.com:8080",
    "FailoverProxy": "fallback.example.com:8080",
    "NoProxy": [
      "localhost",
      "127.0.0.1",
      "10.*.*.*",
      "192.168.*.*",
      "*.example.com"
    ],
    "BufferSize": 8192,
    "ConnectionTimeout": 20
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information"
    }
  }
}
```

| Setting | Default | Description |
|---|---|---|
| `Listen` | `127.0.0.1` | Listen address. Keep it on loopback unless you intend to expose the proxy. |
| `Port` | `3128` | Listen port. |
| `UpstreamProxy` | empty | Primary upstream `host:port`. Empty means DIRECT. |
| `FailoverProxy` | unset | Optional fallback upstream `host:port`. |
| `NoProxy` | `localhost`, loopback | Direct-connect patterns; exact, suffix, wildcard, and CIDR forms. |
| `BufferSize` | `8192` | Relay buffer size in bytes. |
| `ConnectionTimeout` | `20` | TCP connect and handshake timeout in seconds. |
| `Logging.LogLevel.Default` | `Information` | `Trace`, `Debug`, `Information`, `Warning`, `Error`, `Critical`. |

The menu bar **Settings…** window edits the same file. **Save & Restart** validates
the values and restarts the in-process proxy.

## Menu bar

- Green dot: proxy is running
- Orange dot: starting
- Red dot: stopped or failed

The menu provides Start, Stop, Restart, Settings, Copy Proxy Address, Open Config File,
Open Logs, Launch at Login, and Quit. The app starts the proxy automatically whenever
the app launches, including at login.

## Launch at login

`Scripts/install.sh` writes:

```text
~/Library/LaunchAgents/com.johannesbauer.fastproxy.plist
```

with `RunAtLoad = true`, pointing at the installed app. The same behavior is available
from the menu bar toggle or from the CLI:

```bash
fastproxy-cli --install-login-item /path/to/FastProxy.app
fastproxy-cli --uninstall-login-item
```

## Headless CLI

The app bundle and the Swift package both ship a small CLI that uses the same core:

```bash
fastproxy-cli --config ~/Library/Application\ Support/FastProxy/appsettings.json
fastproxy-cli --port 3128 --upstream proxy.example.com:8080 --no-proxy 'localhost,10.*.*.*'
```

Useful flags: `--config`, `--port`, `--listen`, `--upstream`, `--failover`,
`--no-proxy`, `--log-level`, `--log-dir`, `--install-login-item`,
`--uninstall-login-item`.

## Authentication

macOS does not have a public NTLM credential provider. FastProxy therefore uses
Kerberos/SPNEGO via `GSS.framework`; on a domain-joined Mac this is the normal
`Negotiate` path and requires no password in the configuration. Check the ticket cache:

```bash
klist
```

The upstream proxy host needs an `HTTP/<host>@<REALM>` service ticket. If your upstream
only accepts NTLM and no Kerberos service is available, the native proxy reports a 502
and logs the authentication failure; the .NET version remains the fallback for that
environment.

Authentication tokens are never written to the log.

## Logs

```text
~/Library/Application Support/FastProxy/logs/fastproxy.log
```

Logs rotate at 10 MiB and keep seven archives. The menu bar **Open Logs** item reveals
the folder.

## Benchmark

A repeatable benchmark and the latest results are in
[docs/benchmark.md](docs/benchmark.md). Summary from the development machine
(Apple Silicon, macOS 27.2, `hey`):

| Scenario | Native app | .NET FastProxy |
|---|---:|---:|
| HTTPS via corporate upstream, 500 requests, 50 concurrent | 687 / 700 / 634 req/s | 602 / 516 / 646 req/s |
| HTTPS CONNECT, local target, 3000 requests, 10 concurrent | 10,174 / 10,246 / 10,169 req/s | 13,738 / 13,348 / 13,284 req/s |
| HTTP forwarding, local target, 3000 requests, 50 concurrent | 11,440 / 11,804 / 11,614 req/s | 8,308 / 12,228 / 13,027 req/s |

In the real upstream scenario, the native app is equal to or slightly faster than the
.NET version. Local CONNECT throughput is lower but remains in the same order of
magnitude; remote upstream latency dominates normal browsing.

## Development

```bash
swift build
swift test
./Scripts/build-app.sh
```

The test suite covers configuration, header parsing, no-proxy matching, direct HTTP,
CONNECT tunnels, upstream failover, 407 challenge/response, chunked bodies, large
downloads, concurrency, and LaunchAgent generation. Kerberos tests are opt-in:

```bash
FASTPROXY_GSS_TEST_HOST=proxy.example.com swift test --filter GSSAuthenticatorTests
```

### Layout

```text
Sources/FastProxyCore/     proxy engine, config, GSS, logging
Sources/FastProxyApp/      SwiftUI menu bar app and settings
Sources/FastProxyCLI/      headless runner and login-item helper
Sources/CGSS/              small C bridge to GSS.framework
Tests/FastProxyCoreTests/  unit and integration tests
Scripts/                   build, install, uninstall
Resources/Info.plist       app bundle metadata
```

## Security

- The proxy binds to `127.0.0.1` by default and has no client authentication.
- Do not bind to a non-loopback address on an untrusted network.
- Runtime logs and configuration can contain private hostnames; both are outside the
  repository and the config is mode `0600`.
- This repository contains only example hostnames and no employer-specific internal
  information.

## License

MIT. See [LICENSE](LICENSE).
