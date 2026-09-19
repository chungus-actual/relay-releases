"""Run the standalone probe against localhost with fresh, disposable storage."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import os, signal, subprocess, sys, tempfile, threading
page=b'''<!doctype html><title>Relay Chromium fixture</title><h1>Chromium fixture</h1><script>
console.log('STORAGE '+JSON.stringify({cookie:document.cookie, local:localStorage.getItem('relay')}));
document.cookie='relay=fixture; SameSite=Strict'; localStorage.setItem('relay','fixture');
console.log('CAPABILITIES '+JSON.stringify({notification:typeof Notification,permission:Notification.permission,audio:typeof AudioContext}));
navigator.serviceWorker.register('/sw.js').then(() => navigator.serviceWorker.ready).then(r => console.log('WORKER '+typeof r.showNotification)).catch(e => console.log('WORKER_ERROR '+e.message));
</script>'''
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        data=b"self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(clients.claim()));" if self.path=='/sw.js' else page
        self.send_response(200);self.send_header('Content-Type','application/javascript' if self.path=='/sw.js' else 'text/html');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 with tempfile.TemporaryDirectory(prefix='relay-cef-probe-') as directory:
    args=[sys.argv[1],'--use-native','--use-alloy-style','--cache-path='+directory,'--url=http://127.0.0.1:'+str(server.server_port)+'/','--disable-background-networking','--disable-component-update','--password-store=basic','--use-mock-keychain']
    process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
    try: output,_=process.communicate(timeout=35)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL);output,_=process.communicate();print(output[-10000:]);raise SystemExit('CEF probe timed out')
    print(output[-12000:])
    Path(__file__).parents[1].joinpath('.build/cef-investigation/probe-output.txt').write_text(output)
    if process.returncode or 'PASS: browser task attribution' not in output:raise SystemExit('CEF probe failed')
    if output.count('STORAGE {"cookie":"","local":null}') != 2:raise SystemExit('Profile storage isolation not proven')
    if output.count('WORKER function') != 2:raise SystemExit('Service worker support not proven')
    print('PASS: Chromium native host, storage isolation, mute, tasks, service-worker API')
finally:server.shutdown()
