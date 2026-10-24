import Foundation

/// The Rupert instance this build talks to (`RupertBaseURL` in Info.plist).
enum Instance {
    static let baseURL: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "RupertBaseURL") as? String
        guard let configured, let url = URL(string: configured), url.scheme == "https" else {
            return URL(string: "https://herbalhealers.rupertpos.com")!
        }
        return url
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// A path on the instance, which may carry a query ("/platform?tab=x").
    static func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    static func isInstance(_ url: URL?) -> Bool {
        url?.host == baseURL.host && url?.scheme == baseURL.scheme
    }
}
