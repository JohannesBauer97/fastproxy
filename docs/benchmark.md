# Benchmark

Date: 2026-11-03

Machine: Apple Silicon, 14 CPU cores, 48 GB RAM, macOS 27.2
Tools: `hey`, Swift 6.4.2 release build, .NET FastProxy from the reference build

The native app and the .NET version were run side by side on different ports, with
the same upstream configuration and the same target URLs. Each row shows three
independent runs.

## HTTPS through the corporate upstream proxy

Target: `https://example.com/`  
`hey -n 500 -c 50 -x http://127.0.0.1:<port> https://example.com/`

| Run | Native app | .NET FastProxy |
|---|---:|---:|
| 1 | 686.8 req/s (65.4 ms avg) | 602.0 req/s (70.5 ms avg) |
| 2 | 700.0 req/s (66.0 ms avg) | 516.3 req/s (89.2 ms avg) |
| 3 | 634.0 req/s (71.4 ms avg) | 646.5 req/s (68.7 ms avg) |

All 500 requests returned HTTP 200 in every run. This is the closest test to normal
browsing: CONNECT through the Kerberos-authenticated upstream proxy to a public HTTPS
site. Native performance is equal to or slightly better than the .NET version.

`httpbin.org` was also tested at `-n 200 -c 10`; both proxies produced the same
throughput within measurement noise, but httpbin rate-limited the runs with HTTP 429,
so those results are not included.

## HTTPS CONNECT to a local target

A local TLS server on loopback removes wide-area latency. The local test server could
not sustain more than about 10 concurrent TLS handshakes reliably, so this test uses
`-c 10`.

`hey -n 3000 -c 10 -x http://127.0.0.1:<port> https://127.0.0.1:18443/`

| Run | Native app | .NET FastProxy |
|---|---:|---:|
| 1 | 10,173.8 req/s (1.0 ms avg) | 13,737.7 req/s (0.7 ms avg) |
| 2 | 10,245.9 req/s (1.0 ms avg) | 13,348.0 req/s (0.7 ms avg) |
| 3 | 10,168.8 req/s (1.0 ms avg) | 13,283.9 req/s (0.7 ms avg) |

The native relay is about 24% slower on this synthetic loopback test. It uses
Network.framework instead of raw .NET sockets, and that overhead is visible when the
network round trip is effectively zero. With a real upstream proxy the difference
disappears because upstream RTT dominates.

## HTTP forwarding to a local origin

`hey -n 3000 -c 50 -x http://127.0.0.1:<port> http://127.0.0.1:18080/`

| Run | Native app | .NET FastProxy |
|---|---:|---:|
| 1 | 11,440.4 req/s (4.3 ms avg) | 8,308.2 req/s (6.0 ms avg) |
| 2 | 11,803.7 req/s (4.2 ms avg) | 12,228.4 req/s (4.0 ms avg) |
| 3 | 11,614.1 req/s (4.3 ms avg) | 13,027.3 req/s (3.7 ms avg) |

## How to reproduce

The native proxy can be built and started headlessly on the alternate port:

```bash
swift build -c release --product fastproxy-cli
.build/release/fastproxy-cli --config /path/to/appsettings.json
```

Then run the same `hey` commands against the native and .NET ports. Keep the two
proxies on separate ports (for example 3129 and 3130) and use the same upstream and
`NoProxy` settings.
