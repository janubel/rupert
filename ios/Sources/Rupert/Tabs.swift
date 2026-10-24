import HotwireNative
import UIKit

/// The native tab bar. These replace the web top bar's search, Ask Rupert, Team chat and
/// notification buttons, which Rupert hides inside the app (`.native-app` in application.css).
extension HotwireTab {
    static let all: [HotwireTab] = [.home, .chat, .ask, .inbox, .search]

    static let home = HotwireTab(id: "home", title: "Home", image: symbol("house"), url: Instance.url("/"))
    static let chat = HotwireTab(id: "chat", title: "Team Chat", image: symbol("bubble.left.and.bubble.right"),
                                 url: Instance.url("/chat"))
    static let ask = HotwireTab(id: "ask", title: "Ask Rupert", image: symbol("sparkles"),
                                url: Instance.url("/ask_rupert"))
    static let inbox = HotwireTab(id: "inbox", title: "Notifications", image: symbol("bell"),
                                  url: Instance.url("/notifications"))
    static let search = HotwireTab(id: "search", title: "Search", image: symbol("magnifyingglass"),
                                   url: Instance.url("/search"))

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name)
    }
}
