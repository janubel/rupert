import Foundation

/// Where the app is pointed.
///
/// Everyone starts on the control plane (`RupertControlPlaneURL`, pos.rupertpos.com): sign in, sign
/// up and pick a workspace there. A customer with an isolated workspace moves to that instance
/// after the handoff (WorkspaceHandoff), and the tabs follow. Herbal Healers and other tenants
/// served by the control plane itself stay on it.
enum Instance {
    static let controlPlane: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "RupertControlPlaneURL") as? String
        return configured.flatMap(httpsOrigin) ?? URL(string: "https://pos.rupertpos.com")!
    }()

    private static let currentKey = "rupert.currentInstanceOrigin"

    /// The instance the tabs show. The control plane until a workspace handoff moves the app.
    static var current: URL {
        UserDefaults.standard.string(forKey: currentKey).flatMap(httpsOrigin) ?? controlPlane
    }

    static func setCurrent(_ origin: URL) {
        if origin.host == controlPlane.host {
            UserDefaults.standard.removeObject(forKey: currentKey)
        } else {
            UserDefaults.standard.set(origin.absoluteString, forKey: currentKey)
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// A path on an instance (default: the current one), which may carry a query.
    static func url(_ path: String, on base: URL = current) -> URL {
        URL(string: path, relativeTo: base)?.absoluteURL ?? base
    }

    /// Rupert's own sites stay inside the app: rupertpos.com, its subdomains, the control plane and
    /// the current instance (an isolated workspace may live on its own domain).
    static func isRupert(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "rupertpos.com" || host.hasSuffix(".rupertpos.com")
            || host == controlPlane.host?.lowercased() || host == current.host?.lowercased()
    }

    /// https://host[:port] of a URL or string, or nil when it is not an https URL.
    static func httpsOrigin(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return httpsOrigin(url)
    }

    static func httpsOrigin(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        return components.url
    }
}
