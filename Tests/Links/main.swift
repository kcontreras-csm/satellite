// Checks for copying links (File > Copy Link, and the right-click menus of tabs and of apps in the rail), run by
// scripts/test-links.sh: compiled with the whole app module and run as a background accessory process. It copies
// to a private pasteboard, never the real clipboard.
import AppKit
import WebKit

let app = SatelliteApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS: \(what)" : "FAIL: \(what)"); if !ok { failures += 1 } }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    let board = NSPasteboard(name: NSPasteboard.Name("satellite-link-test-\(UUID().uuidString)"))   // never the real clipboard
    let caseURL = URL(string: "https://orgcs.lightning.force.com/lightning/r/Case/500Hx00000AbCdE/view")!

    // The copy itself.
    PageLink.copy(caseURL, title: "476159022 | Case | Salesforce", includeTitle: false, to: board)
    check(board.string(forType: .string) == caseURL.absoluteString && board.string(forType: .URL) == caseURL.absoluteString
          && board.string(forType: NSPasteboard.PasteboardType("public.url-name")) == "476159022 | Case | Salesforce" && board.string(forType: .html) == nil,
          "Copy Link: the address as text and as a URL (with its title as the URL\u{2019}s name), no HTML")
    PageLink.copy(caseURL, title: "Tom & Jerry <case>", includeTitle: true, to: board)
    check(board.string(forType: .string) == "Tom & Jerry <case> \u{2014} \(caseURL.absoluteString)", "Copy Link with Title: plain text is \u{201C}title \u{2014} address\u{201D}")
    check(board.string(forType: .html) == "<a href=\"\(caseURL.absoluteString)\">Tom &amp; Jerry &lt;case&gt;</a>", "\u{2026}and rich editors get the title linked, escaped: \(board.string(forType: .html) ?? "nil")")
    check(PageLink.isShareable(caseURL) && !PageLink.isShareable(URL(string: "about:blank")) && !PageLink.isShareable(nil), "only web addresses can be copied or opened")

    // The content area: an app, its own tab and a second tab, as the tab bar and the rail see them.
    let content = ContentViewController()
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = content
    window.orderFrontRegardless()
    let orgcs = WebApp(id: "orgcs", name: "OrgCS", url: URL(string: "https://orgcs.example.com/one/one.app")!, symbol: "cloud.fill")
    content.setItems([SidebarItem(orgcs)])
    let group = content.selectedGroup ?? { content.select("orgcs"); return content.selectedGroup! }()
    check(group.home.currentURL == orgcs.url, "before it loads, an app\u{2019}s link is its address")
    group.home.webView.loadHTMLString("<title>476159022 | Case | Salesforce</title>", baseURL: caseURL)
    pump(1.5)
    check(group.home.currentURL == caseURL && group.home.tabTitle == "476159022 | Case | Salesforce", "after it loads, the link is the page it shows, with its title")

    func perform(_ menu: NSMenu?, _ title: String) {
        guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else { return check(false, "no \u{201C}\(title)\u{201D}") }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    let appMenu = PageLink.menu(for: group.current, window: nil, pasteboard: board)
    check(appMenu.items.map(\.title) == ["Copy Link", "Copy Link with Title", "Open in Default Browser"] && appMenu.items.allSatisfy(\.isEnabled), "an app\u{2019}s menu: Copy Link, Copy Link with Title, Open in Default Browser")
    perform(appMenu, "Copy Link with Title")
    check(board.string(forType: .html) == "<a href=\"\(caseURL.absoluteString)\">476159022 | Case | Salesforce</a>", "choosing Copy Link with Title copies the case\u{2019}s title, linked")

    // A second tab opened by the page (window.open), shown in the tab bar.
    let second = group.openTab(configuration: WebEnvironment.makeConfiguration())
    let dashboard = URL(string: "https://splunk.example.com/app/search")!
    second.webView.loadHTMLString("<title>Search | Splunk</title>", baseURL: dashboard)
    pump(1.5)
    content.linkPasteboard = board
    perform(content.appMenu(for: "orgcs"), "Copy Link")
    check(board.string(forType: .string) == dashboard.absoluteString, "the rail\u{2019}s real menu copies the tab the app shows now (the second tab)")

    // The real tab bar of the content area: right-click its second tab.
    pump(0.3)
    let realTabs = content.view.subviews.compactMap { $0 as? TabBarView }.first.map { $0.subviews.flatMap(\.subviews).compactMap { $0 as? TabButton } } ?? []
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let firstTabMenu = realTabs.first?.menu(for: rightClick), secondTabMenu = realTabs.dropFirst().first?.menu(for: rightClick)
    check(realTabs.count == 2 && secondTabMenu?.items.contains { $0.title == "Close Tab" } == true && firstTabMenu?.items.contains { $0.title == "Close Tab" } == false,
          "the real tab bar: the second tab\u{2019}s menu has Close Tab, the app\u{2019}s own tab\u{2019}s doesn\u{2019}t")
    group.select(0)
    perform(secondTabMenu, "Copy Link")
    check(board.string(forType: .string) == dashboard.absoluteString, "Copy Link on a tab copies that tab, even when another tab is in front")
    perform(secondTabMenu, "Close Tab")
    check(group.tabs.count == 1, "Close Tab from the menu closes it")

    // Wiring: a right-click on a tab or a rail button asks for that menu.
    let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let bar = TabBarView(frame: .zero)
    var asked: [Int] = []
    bar.menuForTab = { index in asked.append(index); return NSMenu(title: "tab \(index)") }
    bar.show(titles: ["OrgCS", "Search | Splunk"], selected: 1)
    let tabButtons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? TabButton }
    check(tabButtons.count == 2 && tabButtons[1].menu(for: click)?.title == "tab 1" && asked == [1], "right-clicking a tab asks for that tab\u{2019}s menu")
    let rail = RailViewController()
    _ = rail.view
    var railAsked: [String] = []
    rail.menuForApp = { id in railAsked.append(id); return NSMenu(title: id) }
    rail.setItems([SidebarItem(orgcs)])
    let railButton = rail.view.subviews.flatMap { [$0] + $0.subviews }.compactMap { $0 as? RailButton }.first { $0.action != nil && $0.tag == 0 && $0.makeMenu != nil }
    check(railButton?.menu(for: click)?.title == "orgcs" && railAsked == ["orgcs"], "right-clicking an app in the rail asks for that app\u{2019}s menu")

    // The close item exists only for tabs that can close.

    // A tab that hasn't got a web address yet: nothing to copy.
    let blank = group.openTab(configuration: WebEnvironment.makeConfiguration())
    blank.webView.loadHTMLString("x", baseURL: URL(string: "about:blank"))
    pump(0.8)
    check(PageLink.menu(for: blank, window: nil, pasteboard: board).items.allSatisfy { !$0.isEnabled }, "a tab without a web address shows the items disabled")

    // The File menu: Copy Link keeps Cmd+Shift+L; Copy Link with Title is next to it.
    let controller = MainWindowController(openSettings: {})
    let registry = ShortcutRegistry.shared
    registry.setAppCommands(BuiltInCommands.make(window: controller, app: AppActions(openSettings: {}, checkForUpdates: {}, closeTabOrWindow: {}, closeTitle: { "Close" })))
    let copyItem = registry.menuItem(for: "page.copyAddress"), withTitle = registry.menuItem(for: "page.copyLinkWithTitle")
    check(copyItem?.title == "Copy Link" && copyItem?.keyEquivalent == "l" && copyItem?.keyEquivalentModifierMask == [.command, .shift], "File > Copy Link keeps \u{21E7}\u{2318}L")
    check(withTitle?.title == "Copy Link with Title" && withTitle?.keyEquivalent == "" && MenuLayout.file.contains("page.copyLinkWithTitle"), "File > Copy Link with Title, with no shortcut until you give it one")
}
print(failures == 0 ? "\nAll link checks passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
