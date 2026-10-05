import Foundation

enum BrowserRules {
    // Messenger serves attachments outside facebook.com. These hosts may remain
    // in the browser for response/download handling, without inheriting service permissions.
    static func providerAttachment(_ url: URL, service: String) -> Bool {
        guard service == "messenger", url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["fbcdn.net", "fbsbx.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func webLink(_ url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme ?? "") else { return nil }
        let host = url.host?.lowercased() ?? ""
        let wrapper = (["l.facebook.com", "lm.facebook.com", "www.facebook.com"].contains(host) && url.path == "/l.php") ||
            (["google.com", "www.google.com"].contains(host) && url.path == "/url") ||
            (["youtube.com", "www.youtube.com"].contains(host) && url.path == "/redirect")
        if wrapper, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for query in parts.queryItems ?? [] where ["u", "q", "url"].contains(query.name) {
                if let value = query.value, let target = URL(string: value), ["https", "http"].contains(target.scheme ?? "") { return target }
            }
        }
        return url
    }

    static func googleHome(_ service: String) -> URL? {
        let homes = ["gmail": "https://mail.google.com/mail/", "calendar": "https://calendar.google.com/calendar/",
                     "googlemessages": "https://messages.google.com/web/", "googlekeep": "https://keep.google.com/",
                     "youtubemusic": "https://music.youtube.com/", "youtube": "https://www.youtube.com/"]
        return homes[service].flatMap(URL.init(string:))
    }
    static func googleSignIn(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https" else { return false }
        // Google can establish its YouTube session before returning to the requested app.
        let host = url.host?.lowercased() ?? ""
        return ["accounts.google.com", "accounts.youtube.com"].contains(host) ||
            (["www.youtube.com", "youtube.com"].contains(host) && ["/signin", "/signin/", "/accounts/SetSID"].contains(url.path))
    }
    static func googleApp(_ url: URL?, service: String) -> Bool {
        guard let url, let home = googleHome(service), url.scheme == "https", url.host == home.host else { return false }
        return home.path.isEmpty || home.path == "/" || url.path == home.path || url.path.hasPrefix(home.path + "/")
    }
    static func googleLanding(_ url: URL?, service: String) -> Bool {
        guard let url, let home = googleHome(service), url.scheme == "https" else { return false }
        return googleSignIn(url) || (url.host == home.host && !googleApp(url, service: service)) ||
            (["workspace.google.com", "www.google.com", "google.com"].contains(url.host ?? "") &&
                url.path.contains("/" + (service == "googlemessages" ? "messages" : service)))
    }
}
