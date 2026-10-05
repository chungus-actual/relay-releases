#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import socket, subprocess, sys, threading
payload = b'relay-resume-fixture\n' * 262144
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        requested = self.headers.get('Range')
        start = int(requested.split('=')[1].split('-')[0]) if requested else 0
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="resume.bin"')
        self.send_header('Content-Length', str(len(payload) - start))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('ETag', '"relay-fixture-v1"')
        self.send_header('Last-Modified', 'Mon, 14 Sep 2026 12:00:00 GMT')
        if requested: self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
        self.end_headers()
        try:
            self.wfile.write(payload[start:] if requested else payload[:262144])
            self.wfile.flush()
            if not requested:
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    result = subprocess.run(['bash', sys.argv[1] + '/scripts/Test-macOS-browser.sh', '--download-resume', f'http://127.0.0.1:{server.server_port}/fixture'], timeout=120)
    raise SystemExit(result.returncode)
finally:
    server.shutdown()
PY
