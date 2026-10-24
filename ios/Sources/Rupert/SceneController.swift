import HotwireNative
import UIKit

/// The one window: a tab bar where each tab keeps its own navigation stack of Rupert pages.
final class SceneController: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private lazy var tabBarController = HotwireTabBarController(navigatorDelegate: self, lazyLoadTabs: true)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = UIColor(named: "AccentColor", in: .module, compatibleWith: nil)
        window.rootViewController = tabBarController
        window.makeKeyAndVisible()
        self.window = window

        tabBarController.load(HotwireTab.all)
        GoogleSignIn.shared.onSignedIn = { [weak self] landing in
            self?.reloadAfterSignIn(landing: landing)
        }
    }

    /// After a Google sign-in every tab still shows the sign-in page. Start each tab over on its
    /// own page and open the account's landing page on Home.
    private func reloadAfterSignIn(landing: URL) {
        for tab in HotwireTab.all {
            guard let navigator = tabBarController.navigator(for: tab) else { continue }
            navigator.clearAll(animated: false)
            let destination = tab == .home ? landing : tab.url
            navigator.route(destination, options: VisitOptions(action: .replace))
        }
        tabBarController.selectedIndex = 0
    }
}

extension SceneController: NavigatorDelegate {
    func visitableDidFailRequest(_ visitable: any Visitable, error: HotwireNativeError, retryHandler: RetryBlock?) {
        if let presenter = visitable as? ErrorPresenter {
            presenter.presentError(error) { retryHandler?() }
            return
        }
        let alert = UIAlertController(title: "Rupert could not load this page",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in retryHandler?() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        tabBarController.activeNavigator.present(alert, animated: true)
    }
}
