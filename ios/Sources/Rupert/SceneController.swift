import HotwireNative
import UIKit

/// The one window: a tab bar where each tab keeps its own navigation stack of Rupert pages, on the
/// instance the app is pointed at (Instance.current).
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

        tabBarController.load(HotwireTab.all(on: Instance.current))

        GoogleSignIn.shared.onSignedIn = { [weak self] landing in
            self?.show(instance: Instance.httpsOrigin(landing) ?? Instance.current, landing: landing)
        }
        WorkspaceHandoff.shared.onOpened = { [weak self] origin, landing in
            self?.show(instance: origin, landing: landing)
        }
    }

    /// Point every tab at `instance` (after a sign-in or a workspace handoff) and open `landing`
    /// on Home. Each tab starts over, since they all showed the sign-in page or the control plane.
    private func show(instance: URL, landing: URL) {
        Instance.setCurrent(instance)
        let tabs = HotwireTab.all(on: instance)
        tabBarController.load(tabs)
        tabBarController.selectedIndex = 0
        if landing.path != "/" || landing.query != nil, let home = tabs.first,
           let navigator = tabBarController.navigator(for: home) {
            navigator.route(landing, options: VisitOptions(action: .replace))
        }
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
