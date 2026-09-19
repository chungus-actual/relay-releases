"""Local-only API proof; Python is a test harness, not a shipping dependency."""
import os, sys, tempfile, threading, json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
os.environ['QTWEBENGINE_CHROMIUM_FLAGS']='--disable-background-networking --disable-component-update --password-store=basic --use-mock-keychain'
from PySide6.QtWidgets import QApplication, QWidget, QHBoxLayout
from PySide6.QtCore import QUrl, QTimer, Qt
from PySide6.QtGui import QWindow
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile, QWebEnginePermission
from PySide6.QtWebEngineWidgets import QWebEngineView
page='''<!doctype html><title>Relay Qt Chromium fixture</title><h1>Chromium fixture</h1><script>
const account=location.pathname.slice(1);
console.log('STORAGE '+JSON.stringify({cookie:document.cookie,local:localStorage.getItem('relay')}));
localStorage.setItem('relay',account);document.cookie='relay='+account;
(async()=>{
 const permission=await Notification.requestPermission();
 if(permission!=='granted') throw new Error('permission denied');
 const n=new Notification('page-'+account,{body:'page body'});
 n.onclick=()=>console.log('CLICK page-'+account);
 await navigator.serviceWorker.register('/sw.js');const r=await navigator.serviceWorker.ready;
 await r.showNotification('worker-'+account,{body:'worker body'});
})();</script>'''.encode()
worker=b"self.addEventListener('install',()=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(clients.claim()));self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll().then(xs=>xs.forEach(c=>c.postMessage('clicked'))));});"
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  data=worker if self.path=='/sw.js' else page
  self.send_response(200);self.send_header('Content-Type','application/javascript' if self.path=='/sw.js' else 'text/html');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
native_mode='--native' in sys.argv
if native_mode:
 import AppKit, objc
 QApplication.setAttribute(Qt.ApplicationAttribute.AA_PluginApplication)
 native=AppKit.NSApplication.sharedApplication()
 native.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
app=QApplication([]);app.setApplicationName('Relay Chromium API Probe')
window=QWidget();layout=QHBoxLayout(window);window.resize(1000,650)
profiles=[];pages=[];views=[];notifications=[];messages=[];failures=[]
class Page(QWebEnginePage):
 def javaScriptConsoleMessage(self,level,message,line,source):
  messages.append(message);print('PAGE',message,flush=True)
def permission(request):
 if request.origin().host()=='127.0.0.1' and request.permissionType()==QWebEnginePermission.PermissionType.Notifications:request.grant()
 else:request.deny()
def present(index,notification):
 title=notification.title();notifications.append((index,title,notification))
 print('NOTIFICATION',index,title,notification.message(),notification.origin().toString(),flush=True)
 if not title.endswith(str(index)):failures.append('cross-account notification')
 notification.show();notification.click();notification.close()
for index in range(2):
 profile=QWebEngineProfile(app);profiles.append(profile)
 profile.setNotificationPresenter(lambda notification,i=index:present(i,notification))
 view=QWebEngineView();views.append(view);layout.addWidget(view)
 browser=Page(profile,view);pages.append(browser);view.setPage(browser)
 browser.permissionRequested.connect(permission)
 browser.setAudioMuted(index==0)
 view.setUrl(QUrl(f'http://127.0.0.1:{server.server_port}/{index}'))
if native_mode:
 native_window=AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(((0,0),(1040,700)),AppKit.NSWindowStyleMaskTitled|AppKit.NSWindowStyleMaskClosable|AppKit.NSWindowStyleMaskResizable,AppKit.NSBackingStoreBuffered,False)
 native_window.setTitle_("Relay native Chromium host")
 native_window.setReleasedWhenClosed_(False)
 host=AppKit.NSView.alloc().initWithFrame_(((20,20),(1000,650)))
 native_window.contentView().addSubview_(host)
 window.winId()
 foreign=QWindow.fromWinId(objc.pyobjc_id(host))
 window.windowHandle().setParent(foreign)
 window.show()
 native_window.center();native_window.makeKeyAndOrderFront_(None)
 native.activateIgnoringOtherApps_(True)
 assert window.windowHandle().parent() is foreign
 print('NATIVE: Qt browser views embedded in AppKit NSView',flush=True)
 pump=None if "--no-pump" in sys.argv else AppKit.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(0.01,True,lambda timer:app.processEvents())
else:window.show()
def finish():
 pids=[p.renderProcessPid() for p in pages]
 print('RENDERERS',pids,'MUTE',[p.isAudioMuted() for p in pages],flush=True)
 ok=(len(notifications)==4 and not failures and messages.count('STORAGE {"cookie":"","local":null}')==2 and all(pids) and len(set(pids))==2 and pages[0].isAudioMuted() and not pages[1].isAudioMuted())
 for n in notifications:n[2].close()
 for browser in pages:browser.deleteLater()
 def stop():
  global result
  result=0 if ok else 1
  if native_mode:
   if pump:pump.invalidate()
   native.stop_(None)
   event=AppKit.NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(AppKit.NSEventTypeApplicationDefined,(0,0),0,0,0,None,0,0,0)
   native.postEvent_atStart_(event,True)
  else:app.exit(result)
 QTimer.singleShot(200,stop)
QTimer.singleShot(10000,finish)
result=1
try:
 if native_mode:native.run()
 else:result=app.exec()
finally:server.shutdown()
print('PASS: isolated profiles, native page + worker notifications, renderer IDs, browser mute' if result==0 else 'FAIL: Qt Chromium probe',flush=True)
sys.exit(result)
