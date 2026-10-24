import HotwireNative
import UIKit

/// The native tab bar, on whichever instance the app is pointed at. These replace the web top
/// bar's search, Ask Rupert, Team chat and notification buttons, which Rupert hides inside the app
/// (`.native-app` in application.css). Signed out, every tab shows Rupert's sign-in page.
extension HotwireTab {
    static func all(on base: URL) -> [HotwireTab] {
        [
            // /login sends a signed-in person to their start page, so Home never opens on a page
            // the app cannot show (the signed-out marketing page at / has no Turbo).
            HotwireTab(id: "home", title: "Home", image: UIImage(systemName: "house"),
                       url: Instance.url("/login", on: base)),
            HotwireTab(id: "chat", title: "Team Chat", image: UIImage(systemName: "bubble.left.and.bubble.right"),
                       url: Instance.url("/chat", on: base)),
            HotwireTab(id: "ask", title: "Ask Rupert", image: UIImage(systemName: "sparkles"),
                       url: Instance.url("/ask_rupert", on: base)),
            HotwireTab(id: "inbox", title: "Notifications", image: UIImage(systemName: "bell"),
                       url: Instance.url("/notifications", on: base)),
            HotwireTab(id: "search", title: "Search", image: UIImage(systemName: "magnifyingglass"),
                       url: Instance.url("/search", on: base)),
        ]
    }
}
