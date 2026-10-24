import WebKit

/// Scripts the app adds to every Rupert web view, ahead of Hotwire's own.
enum WebViewSupport {
    /// Records what went wrong while a page loaded (a module that failed to load, a script error),
    /// so the app's error screen can say why Rupert's JavaScript did not start.
    static let diagnostics = """
    (() => {
      const problems = [];
      addEventListener("error", (event) => {
        const target = event.target;
        if (target && target !== window && (target.src || target.href)) {
          problems.push("could not load " + (target.src || target.href));
        } else {
          problems.push(String(event.message) + " (" + (event.filename || "?") + ":" + event.lineno + ")");
        }
      }, true);
      addEventListener("unhandledrejection", (event) => {
        problems.push("unhandled: " + String(event.reason && (event.reason.message || event.reason)));
      });
      window.__rupertDiagnostics = () => JSON.stringify({
        turbo: typeof window.Turbo,
        hotwire: typeof window.turboNative,
        ready: document.readyState,
        importmap: !!document.querySelector("script[type=importmap]"),
        modules: document.querySelectorAll("script[type=module]").length,
        problems: problems.slice(0, 12),
        page: location.pathname,
        agent: navigator.userAgent
      });
    })();
    """

    /// Hotwire connects to Turbo when Turbo fires `turbo:load`. If Rupert's Turbo starts before
    /// Hotwire's listener is attached (fast cached modules), that event is missed and the page
    /// spins forever. Connect it afterwards in that case.
    static let connectLateTurbo = """
    (() => {
      const connect = () => {
        const native = window.turboNative;
        if (!native || !window.Turbo || !window.Turbo.session) return;
        if (document.readyState !== "complete") return;
        if (window.Turbo.session.adapter === native) return;
        try { native.registerAdapter(); native.pageLoaded(); } catch (_) {}
      };
      setTimeout(connect, 1500);
      setTimeout(connect, 5000);
    })();
    """

    static func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: diagnostics, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: connectLateTurbo, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// The diagnostics of the page in `webView`, as readable lines.
    @MainActor
    static func report(from webView: WKWebView) async -> String {
        let value = try? await webView.evaluateJavaScript("window.__rupertDiagnostics ? window.__rupertDiagnostics() : null")
        guard let json = value as? String, let data = json.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No page details (the page did not run any script)."
        }
        var lines = [
            "Page: \(info["page"] ?? "?")",
            "Turbo: \(info["turbo"] ?? "?") · Hotwire: \(info["hotwire"] ?? "?") · \(info["ready"] ?? "?")",
            "Import map: \(info["importmap"] ?? "?") · modules: \(info["modules"] ?? "?")",
        ]
        let problems = info["problems"] as? [String] ?? []
        lines += problems.isEmpty ? ["No script errors recorded."] : problems
        if let agent = info["agent"] as? String { lines.append(agent) }
        return lines.joined(separator: "\n")
    }
}
