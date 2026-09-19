import WebKit

// Page-world compatibility bridge. Worker notifications and browser-wide audio
// controls are not exposed by WKWebView's public API.
@MainActor
final class PageControls: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: BrowserSession?
    var muted = false
    var notificationsAllowed: (() -> Bool)?
    var onNotification: ((String, String) -> Void)?
    private var lastNotification = Date.distantPast
    private var controllers: [WKUserContentController] = []

    func install(_ configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "relayPage")
        controllers.append(controller)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func refreshPermission() {
        session?.chromium?.command("resetNotificationPermissions")
        for view in session?.browserViews ?? [] {
            view.evaluateJavaScript("window.postMessage({relayPermission:true}, '*')", completionHandler: nil)
        }
    }

    func close() {
        for controller in controllers { controller.removeScriptMessageHandler(forName: "relayPage", contentWorld: .page) }
        controllers.removeAll()
        onNotification = nil
        notificationsAllowed = nil
    }

    func setMuted(_ value: Bool) {
        muted = value
        for controller in controllers {
            let others = controller.userScripts.filter { !$0.source.hasPrefix("// Relay page controls") }
            controller.removeAllUserScripts()
            others.forEach { controller.addUserScript($0) }
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        for view in session?.browserViews ?? [] {
            view.evaluateJavaScript("window.postMessage({relayAudio: \(value)}, '*')", completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let session, let view = message.webView,
              session.browserViews.contains(where: { $0 === view }),
              let page = view.url, session.service.contains(page),
              let origin = URL(string: "\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host)"),
              session.service.allowsMediaPermissionRequest(origin: origin, page: page),
              let data = message.body as? [String: Any] else { replyHandler(false, nil); return }
        let allowed = notificationsAllowed?() == true
        if data["kind"] as? String == "notify", allowed,
           let title = data["title"] as? String, let body = data["body"] as? String,
           Date().timeIntervalSince(lastNotification) >= 1 {
            lastNotification = Date()
            onNotification?(String(title.prefix(200)), String(body.prefix(1000)))
        }
        replyHandler(allowed, nil)
    }

    private var script: String { """
    // Relay page controls
    (() => {
      let muted = \(muted);
      const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
      const audioGates = new Set();
      const gates = new WeakMap();
      const connect = AudioNode.prototype.connect;
      AudioNode.prototype.connect = function(destination, ...ports) {
        if (destination === this.context.destination) {
          let gate = gates.get(this.context);
          if (!gate) {
            gate = this.context.createGain(); gate.gain.value = muted ? 0 : 1;
            connect.call(gate, destination); gates.set(this.context, gate); audioGates.add(gate);
          }
          connect.call(this, gate, ...ports); return destination;
        }
        return connect.call(this, destination, ...ports);
      };
      const disconnect = AudioNode.prototype.disconnect;
      AudioNode.prototype.disconnect = function(...args) {
        if (args[0] === this.context.destination && gates.has(this.context)) args[0] = gates.get(this.context);
        return disconnect.apply(this, args);
      };
      const desired = new WeakMap();
      const elements = new Set();
      function apply(el) {
        if (!desired.has(el)) desired.set(el, descriptor.get.call(el));
        elements.add(el); descriptor.set.call(el, muted || desired.get(el));
      }
      Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
        configurable: true, get() { return descriptor.get.call(this); },
        set(value) { desired.set(this, !!value); elements.add(this); descriptor.set.call(this, muted || !!value); }
      });
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(...args) { apply(this); return play.apply(this, args); };
      document.addEventListener('play', e => { if (e.target instanceof HTMLMediaElement) apply(e.target); }, true);
      const observer = new MutationObserver(() => {
        for (const el of elements) if (!el.isConnected && el.paused) elements.delete(el);
        document.querySelectorAll('audio,video').forEach(apply);
      });
      observer.observe(document, {childList:true, subtree:true});
      window.addEventListener('message', e => {
        if ((e.source !== window && e.source !== parent) || typeof e.data?.relayAudio !== 'boolean') return;
        muted = e.data.relayAudio;
        elements.forEach(apply);
        for (const gate of audioGates) {
          if (gate.context.state === 'closed') audioGates.delete(gate);
          else gate.gain.value = muted ? 0 : 1;
        }
        for (let i = 0; i < frames.length; i++) frames[i].postMessage({relayAudio:muted}, '*');
      });
      let permission = 'default';
      window.addEventListener('message', e => {
        if (e.source !== window && e.source !== parent) return;
        if (e.data?.relayPermission !== true) return;
        send({kind:'permission'}).then(ok => { permission = ok ? 'granted' : 'denied'; }).catch(() => {});
        for (let i = 0; i < frames.length; i++) frames[i].postMessage({relayPermission:true}, '*');
      });
      const send = data => window.webkit.messageHandlers.relayPage.postMessage(data);
      send({kind:'permission'}).then(ok => { permission = ok ? 'granted' : 'denied'; }).catch(() => {});
      class RelayNotification extends EventTarget {
        constructor(title, options = {}) {
          super(); this.title = String(title); this.body = String(options.body || '');
          if (permission !== 'granted') throw new DOMException('Notifications are disabled in Relay Settings', 'NotAllowedError');
          send({kind:'notify', title:this.title, body:this.body}).catch(() => {});
        }
        close() {}
        static get permission() { return permission; }
        static async requestPermission(callback) {
          permission = await send({kind:'permission'}) ? 'granted' : 'denied';
          callback?.(permission); return permission;
        }
      }
      window.Notification = RelayNotification;
    })();
    """ }
}
