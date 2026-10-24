import HotwireNative
import WebKit

/// Rupert's own sites (control plane and instances) open inside the app; Hotwire's default only
/// keeps the starting host, so the control plane → workspace hop would have opened in Safari.
struct RupertSitesRoute: RouteDecisionHandler {
    let name = "rupert-sites"

    func matches(proposal: VisitProposal, configuration: Navigator.Configuration) -> Bool {
        Instance.isRupert(proposal.url)
    }

    func handle(proposal: VisitProposal, configuration: Navigator.Configuration,
                navigator: Navigating) -> Router.Decision {
        .navigate
    }
}

/// A link Rupert marks `data-turbo="false"` (or one Turbo does not handle) reaches the web view as
/// a plain link tap. Hotwire's default drops those silently; on Rupert's sites, open them as a
/// normal visit instead.
struct RupertPlainLinkPolicy: WebViewPolicyDecisionHandler {
    let name = "rupert-plain-link"

    func matches(navigationAction: WKNavigationAction, configuration: Navigator.Configuration) -> Bool {
        navigationAction.navigationType == .linkActivated
            && (navigationAction.targetFrame?.isMainFrame ?? false)
            && Instance.isRupert(navigationAction.request.url)
            && navigationAction.request.url?.path != "/auth/google"
    }

    func handle(navigationAction: WKNavigationAction, configuration: Navigator.Configuration,
                navigator: Navigating) -> WebViewPolicyManager.Decision {
        if let url = navigationAction.request.url {
            navigator.route(url)
        }
        return .cancel
    }
}

/// rupert:// links Rupert hands to the app (never opened outside it).
struct RupertSchemePolicy: WebViewPolicyDecisionHandler {
    let name = "rupert-scheme"

    func matches(navigationAction: WKNavigationAction, configuration: Navigator.Configuration) -> Bool {
        navigationAction.request.url?.scheme == "rupert"
    }

    func handle(navigationAction: WKNavigationAction, configuration: Navigator.Configuration,
                navigator: Navigating) -> WebViewPolicyManager.Decision {
        guard let url = navigationAction.request.url else { return .cancel }
        let anchor = navigator.activeNavigationController
        Task { @MainActor in
            if url.host == "workspace" {
                WorkspaceHandoff.shared.open(url, from: anchor)
            }
        }
        return .cancel
    }
}
