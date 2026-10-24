import HotwireNative
import UIKit
import WebKit

/// Opens a customer's isolated workspace from the control plane.
///
/// "Open my workspace" on pos.rupertpos.com/workspace answers the app with
/// rupert://workspace?origin=INSTANCE&handoff=ONE_TIME_CODE&control=CONTROL_PLANE
/// (web/app/controllers/workspaces_controller.rb). The browser version posts a form to
/// INSTANCE/instance/session; the app makes the same POST itself, keeps the instance's session
/// cookie for its web views and moves the tabs to that instance.
@MainActor
final class WorkspaceHandoff {
    static let shared = WorkspaceHandoff()

    /// Called with the instance origin and the page it opened on.
    var onOpened: ((URL, URL) -> Void)?

    private var inFlight = false
    private weak var anchor: UIViewController?

    func open(_ link: URL, from viewController: UIViewController) {
        guard !inFlight else { return }
        anchor = viewController
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        guard let origin = value("origin").flatMap(Instance.httpsOrigin),
              let control = value("control").flatMap(Instance.httpsOrigin),
              let handoff = value("handoff"), !handoff.isEmpty else {
            showProblem("Rupert sent an incomplete workspace link. Try Open my workspace again.")
            return
        }
        inFlight = true
        Task {
            defer { inFlight = false }
            do {
                let landing = try await exchange(handoff: handoff, origin: origin, control: control)
                Instance.setCurrent(origin)
                onOpened?(origin, landing)
            } catch {
                showProblem(error.localizedDescription)
            }
        }
    }

    private func exchange(handoff: String, origin: URL, control: URL) async throws -> URL {
        let endpoint = Instance.url("/instance/session", on: origin)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // The instance accepts the handoff only from its control plane, as the browser form sends it.
        request.setValue(control.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Hotwire.config.userAgent, forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "handoff", value: handoff)]
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)

        // A private cookie jar collects the instance's session cookie across its redirect;
        // only that cookie is copied to the web views.
        let configuration = URLSessionConfiguration.ephemeral
        let jar = configuration.httpCookieStorage ?? HTTPCookieStorage()
        configuration.httpCookieStorage = jar
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SignInProblem(text?.isEmpty == false && text!.count < 300 ? text!
                : "The workspace did not accept the sign-in. Go back and try again.")
        }
        let cookies = jar.cookies(for: Instance.url("/", on: origin)) ?? []
        guard !cookies.isEmpty else { throw SignInProblem("The workspace did not start a session. Try again.") }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        return http.url.flatMap { Instance.isRupert($0) || $0.host == origin.host ? $0 : nil }
            ?? Instance.url("/", on: origin)
    }

    private func showProblem(_ message: String) {
        guard let presenter = anchor?.view.window?.rootViewController else { return }
        let alert = UIAlertController(title: "Open workspace", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        (presenter.presentedViewController ?? presenter).present(alert, animated: true)
    }
}
