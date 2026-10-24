import HotwireNative
import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAppearance()
        configureHotwire()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneController.self
        return configuration
    }

    private func configureAppearance() {
        // Opaque bars, like the rest of iOS, so page content never shows through the chrome.
        UINavigationBar.appearance().scrollEdgeAppearance = .init()
        UITabBar.appearance().scrollEdgeAppearance = .init()
    }

    private func configureHotwire() {
        // Rules ship with the app for the first launch and offline starts; the server copy wins once
        // it loads, so navigation rules change with a Rupert deploy, not an App Store release.
        var sources: [PathConfiguration.Source] = []
        if let bundled = Bundle.module.url(forResource: "path-configuration", withExtension: "json") {
            sources.append(.file(bundled))
        }
        sources.append(.server(Instance.url("/native/ios/path-configuration.json", on: Instance.controlPlane)))
        Hotwire.loadPathConfiguration(from: sources)

        // Rupert recognises the app by "Hotwire Native" in the user agent (turbo-rails'
        // hotwire_native_app?) and drops the web chrome the native tab bar replaces.
        Hotwire.config.applicationUserAgentPrefix = "Rupert iOS/\(Instance.appVersion);"
        Hotwire.config.backButtonDisplayMode = .minimal
        Hotwire.config.showDoneButtonOnModals = true
        Hotwire.config.animateReplaceActions = true
        // Page diagnostics and a late-Turbo connection (WebViewSupport), then Hotwire's defaults.
        Hotwire.config.makeCustomWebView = { configuration in
            WebViewSupport.install(in: configuration)
            let webView = WKWebView(frame: .zero, configuration: configuration)
            if #available(iOS 16.4, *) { webView.isInspectable = true }
            return webView
        }

        // Google refuses sign-in inside web views: sign-in and sign-up go to the system sheet.
        // rupert:// links are Rupert talking to the app (workspace handoff). Plain links on Rupert's
        // sites open in the app. The rest are Hotwire Native's defaults, in their order.
        Hotwire.registerWebViewPolicyDecisionHandlers([
            GoogleSignInPolicy(),
            RupertSchemePolicy(),
            ReloadWebViewPolicyDecisionHandler(),
            NewWindowWebViewPolicyDecisionHandler(),
            RupertPlainLinkPolicy(),
            ExternalNavigationWebViewPolicyDecisionHandler(),
            LinkActivatedWebViewPolicyDecisionHandler(),
        ])
        // Every Rupert site (control plane and workspaces) stays in the app; other sites open in an
        // in-app Safari view, and other schemes (mailto:, tel:) in their apps.
        Hotwire.registerRouteDecisionHandlers([
            GoogleSignInRoute(),
            RupertSitesRoute(),
            SafariViewControllerRouteDecisionHandler(),
            SystemNavigationRouteDecisionHandler(),
        ])
#if DEBUG
        Hotwire.config.debugLoggingEnabled = true
#endif
    }
}
