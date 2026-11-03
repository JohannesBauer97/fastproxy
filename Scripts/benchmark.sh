#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v hey >/dev/null 2>&1; then
  echo "hey is required: brew install hey" >&2
  exit 1
fi

PORT="${PORT:-3128}"
ORIGIN_PORT="${ORIGIN_PORT:-18080}"
REQUESTS="${REQUESTS:-3000}"
CONCURRENCY="${CONCURRENCY:-50}"
TMP_DIR="$(mktemp -d)"
ORIGIN_PID=""
PROXY_PID=""

cleanup() {
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
  [[ -n "$ORIGIN_PID" ]] && kill "$ORIGIN_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$TMP_DIR/appsettings.json" <<JSON
{
  "Proxy": {
    "Listen": "127.0.0.1",
    "Port": $PORT,
    "UpstreamProxy": "127.0.0.1:1",
    "NoProxy": ["*"],
    "BufferSize": 8192,
    "ConnectionTimeout": 5
  }
}
JSON

python3 - "$ORIGIN_PORT" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        body = b"OK"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 256

Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
ORIGIN_PID=$!

swift build -c release --product fastproxy-cli >/dev/null
.build/release/fastproxy-cli \
  --config "$TMP_DIR/appsettings.json" \
  --log-dir "$TMP_DIR/logs" >/dev/null 2>&1 &
PROXY_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

echo "HTTP forwarding: $REQUESTS requests, $CONCURRENCY concurrent"
hey -n "$REQUESTS" -c "$CONCURRENCY" -x "http://127.0.0.1:$PORT" "http://127.0.0.1:$ORIGIN_PORT/" |
  grep -E 'Requests/sec|Average:|Total:|\[200\]'
