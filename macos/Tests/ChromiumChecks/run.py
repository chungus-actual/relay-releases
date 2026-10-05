"""Exercise the compiled Swift/C++ bridge against disposable localhost pages."""
import os
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = b'''<!doctype html><title>Relay Chromium fixture</title><h1>Chromium fixture</h1><script>
window.initial={cookie:document.cookie,local:localStorage.getItem('relay')};
const account=location.pathname.slice(1);localStorage.setItem('relay',account);document.cookie='relay='+account;
window.clicks=[];navigator.serviceWorker.addEventListener('message',e=>window.clicks.push(e.data));
(async()=>{await Notification.requestPermission();
const n=new Notification('page-'+account,{body:'fixture body'});n.onclick=()=>window.clicks.push('page');
await navigator.serviceWorker.register('/sw.js');const r=await navigator.serviceWorker.ready;
await r.showNotification('worker-'+account,{body:'fixture body'});})();</script>'''
WORKER = b"self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(clients.claim()));self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll().then(xs=>xs.forEach(c=>c.postMessage('worker'))));});"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        data, mime = (WORKER, 'application/javascript') if self.path == '/sw.js' else (PAGE, 'text/html')
        if self.path == '/download':
            data, mime = bytes([42]) * 65536, 'application/octet-stream'
        if self.path == '/headers':
            data, mime = json.dumps(dict(self.headers)).encode(), 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
environment = os.environ.copy()
# Test-only flags avoid touching a developer's browser/keychain state. Sandbox stays enabled.
environment['QTWEBENGINE_CHROMIUM_FLAGS'] = '--disable-background-networking --disable-component-update --password-store=basic --use-mock-keychain'
with tempfile.TemporaryDirectory(prefix='relay-chromium-check-') as temporary:
    interactive = '--interactive' in sys.argv[2:]
    arguments = [sys.argv[1], f'http://127.0.0.1:{server.server_port}', str(Path(temporary) / 'fixture.bin')]
    if interactive:
        arguments.append('--interactive')
    child = subprocess.Popen(arguments, env=environment, start_new_session=True)
    try:
        result = child.wait(timeout=None if interactive else 35)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        result = 1
        print('FAIL: Chromium check watchdog expired', flush=True)
    finally:
        server.shutdown()
sys.exit(result)
