import AuthenticationServices
import CryptoKit
import HotwireNative
import UIKit
import WebKit

/// Sends "Sign in with Google" on Rupert's login page to the system sign-in sheet.
/// Google blocks sign-in inside embedded web views, so the link cannot open in the page itself.
struct GoogleSignInPolicy: WebViewPolicyDecisionHandler {
    let name = "rupert-google-sign-in"

    func matches(navigationAction: WKNavigationAction, configuration: Navigator.Configuration) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else { return false }
        return Instance.isInstance(url) && url.path == "/auth/google"
    }

    func handle(navigationAction: WKNavigationAction, configuration: Navigator.Configuration,
                navigator: Navigating) -> WebViewPolicyManager.Decision {
        let anchor = navigator.activeNavigationController
        Task { @MainActor in GoogleSignIn.shared.start(from: anchor) }
        return .cancel
    }
}

/// Google sign-in for the app. Rupert's side is web/app/services/native_sign_in.rb:
///
/// 1. A random verifier stays in memory here; its SHA-256 (the challenge) goes to /auth/google.
/// 2. Google signs the person in inside ASWebAuthenticationSession. Rupert answers with
///    rupert://auth/google?code=CODE (or ?error=MESSAGE) instead of a browser session.
/// 3. POST /native/session {code, verifier} returns Rupert's session cookie, which is copied into
///    the web views' cookie store. A code is useless without the verifier and works once.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignIn()
    static let callbackScheme = "rupert"

    /// Called with the account's landing page after a successful sign-in.
    var onSignedIn: ((URL) -> Void)?

    private var session: ASWebAuthenticationSession?
    private weak var anchor: UIViewController?

    func start(from viewController: UIViewController) {
        guard session == nil else { return }
        anchor = viewController
        let verifier = Self.randomVerifier()
        var components = URLComponents(url: Instance.url("/auth/google"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "native_challenge", value: Self.challenge(for: verifier))]

        let authSession = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.callbackScheme) { [weak self] callback, error in
            Task { @MainActor in self?.finish(callback: callback, error: error, verifier: verifier) }
        }
        authSession.presentationContextProvider = self
        // Keep the person's Google sign-in in Safari between app sign-ins, as other apps do.
        authSession.prefersEphemeralWebBrowserSession = false
        session = authSession
        if !authSession.start() {
            session = nil
            showProblem("The sign-in sheet could not open. Try again.")
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor?.view.window ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func finish(callback: URL?, error: Error?, verifier: String) {
        session = nil
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
        guard let callback, let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            showProblem("Google sign-in did not finish. Try again.")
            return
        }
        if let message = items.first(where: { $0.name == "error" })?.value {
            showProblem(message)
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            showProblem("Google sign-in did not finish. Try again.")
            return
        }
        Task {
            do {
                let landing = try await redeem(code: code, verifier: verifier)
                onSignedIn?(landing)
            } catch {
                showProblem(error.localizedDescription)
            }
        }
    }

    private func redeem(code: String, verifier: String) async throws -> URL {
        let endpoint = Instance.url("/native/session")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Hotwire.config.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(["code": code, "verifier": verifier])

        // Ephemeral: the cookie goes to the web views' store below, nowhere else.
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SignInProblem(body?["error"] as? String ?? "Rupert did not accept the sign-in. Try again.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: endpoint)
        guard !cookies.isEmpty else { throw SignInProblem("Rupert did not start a session. Try again.") }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        return Instance.url(body?["location"] as? String ?? "/")
    }

    private func showProblem(_ message: String) {
        guard let presenter = anchor?.view.window?.rootViewController else { return }
        let alert = UIAlertController(title: "Sign in with Google", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (presenter.presentedViewController ?? presenter).present(alert, animated: true)
    }

    // MARK: PKCE (RFC 7636)

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct SignInProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
