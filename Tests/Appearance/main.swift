// Checks for dark mode and satellite.appearance, run by scripts/test-appearance.sh: compiled with the whole app module
// and run as a background accessory process with a throwaway SATELLITE_HOME. It changes the appearance of this test
// process only, not of Satellite or the system.
import AppKit
import WebKit

let app = SatelliteApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS: \(what)" : "FAIL: \(what)"); if !ok { failures += 1 } }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    let world = WKContentWorld.world(name: "satellite.ext.appearance-test")   // isolated, like an extension
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = webView
    window.orderFrontRegardless()

    @MainActor func run(_ code: String, in target: WKContentWorld? = world) -> String {
        var out = "?"; var done = false
        webView.evaluateJavaScript(code, in: nil, in: target ?? .page) { result in
            switch result {
            case .success(let value): out = "\(value)"
            case .failure(let error): out = "error: \(error)"
            }
            done = true
        }
        while !done { pump(0.05) }
        return out
    }
    @MainActor func load(_ html: String) {
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/")!)
        pump(1.2)
        _ = run("window.__appearance = \(ExtensionAppearance.script(tag: "\"test\"")); window.__changes = []; 'ok'")
    }
    @MainActor func state() -> String { run("__appearance.app + '/' + __appearance.page") }
    @MainActor func set(_ appearance: AppAppearance) { AppAppearance.apply(appearance); pump(0.6) }

    // The setting itself.
    UserDefaults.standard.removeObject(forKey: AppAppearance.defaultsKey)
    check(AppAppearance.current == .system, "the default is System")
    UserDefaults.standard.set("dark", forKey: AppAppearance.defaultsKey)
    AppAppearance.apply()
    check(AppAppearance.current == .dark && NSApp.appearance?.name == .darkAqua, "Dark makes the whole app dark")
    UserDefaults.standard.set("light", forKey: AppAppearance.defaultsKey)
    AppAppearance.apply()
    check(NSApp.appearance?.name == .aqua, "Light makes it light whatever the system is")
    UserDefaults.standard.removeObject(forKey: AppAppearance.defaultsKey)
    AppAppearance.apply()
    check(NSApp.appearance == nil, "System follows the system again")

    // satellite.appearance on different kinds of page.
    set(.light)
    load("<p>plain page</p>")
    check(state() == "light/light", "a plain page in a light Satellite: light/light (\(state()))")
    set(.dark)
    check(state() == "dark/light", "the same page in a dark Satellite: app dark, but the page still looks light, like Salesforce (\(state()))")
    check(run("matchMedia('(prefers-color-scheme: dark)').matches", in: nil) == "1", "the page itself sees prefers-color-scheme: dark")

    load(#"<meta name="color-scheme" content="light dark"><p>follows the system</p>"#)
    check(state() == "dark/dark", "a page that allows dark, in a dark Satellite: dark/dark (\(state()))")
    set(.light)
    check(state() == "light/light", "\u{2026}and light/light when Satellite is light (\(state()))")
    load(#"<style>:root{color-scheme:light dark}</style><p>the CSS property</p>"#)
    set(.dark)
    check(state() == "dark/dark", "the same with the color-scheme CSS property instead of the meta tag (\(state()))")
    load(#"<meta name="color-scheme" content="dark"><p>always dark</p>"#)
    set(.light)
    check(state() == "light/dark", "a page that only allows dark is dark even in a light Satellite (\(state()))")

    load(#"<style>body{background:#1f1e1d;color:#eee}</style><p>dark by its own setting</p>"#)
    check(state() == "light/dark", "a page dark by its own theme (like claude.ai set to dark) in a light Satellite: light/dark (\(state()))")
    load(#"<style>body{background:#b0c4df}</style><p>Lightning-like</p>"#)
    set(.dark)
    check(state() == "dark/light", "a light-blue Lightning-style page stays light in a dark Satellite (\(state()))")

    // onChange: the site switches its theme with a class, and Satellite changes appearance.
    set(.light)
    load(#"<style>html.dark body{background:#111}</style><p>toggles</p>"#)
    _ = run("__appearance.onChange(a => __changes.push(a.app + '/' + a.page)); 'ok'")
    _ = run("document.documentElement.classList.add('dark'); 'ok'", in: nil)
    pump(0.8)
    check(run("__changes.join(',')") == "light/dark", "onChange fires when the site switches to its dark theme (\(run("__changes.join(',')")))")
    set(.dark)
    pump(0.5)
    check(run("__changes.join(',')") == "light/dark,dark/dark", "onChange fires when Satellite turns dark (\(run("__changes.join(',')")))")
    _ = run("document.documentElement.classList.add('dark'); 'ok'", in: nil)
    pump(0.6)
    check(run("__changes.length") == "2", "no callback when nothing changed")
    check(run("Object.isFrozen(__appearance) && (() => { try { __appearance.app = 'x'; } catch (e) {} return __appearance.app; })()") == "dark", "the object can't be changed by the extension")

    // The real bootstrap: an installed extension reads satellite.appearance from its own script.
    let folder = AppPaths.extensions.appendingPathComponent("appearance-probe")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! #"{"name":"Appearance Probe","version":"1.0.0","author":"Test","description":"Reads satellite.appearance.","matches":["https://example.com/*"],"js":["content.js"],"run_at":"document_end"}"#
        .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try! #"""
    document.documentElement.dataset.probe = satellite.appearance.app + '/' + satellite.appearance.page;
    satellite.appearance.onChange(a => { document.documentElement.dataset.probeChanged = a.app + '/' + a.page; });
    """#.write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
    ExtensionManager.shared.reload()
    check(ExtensionManager.shared.info("appearance-probe")?.error == nil, "the probe extension loads (\(ExtensionManager.shared.info("appearance-probe")?.error ?? "ok"))")
    let probeView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebEnvironment.makeConfiguration())
    window.contentView = probeView
    set(.dark)
    probeView.loadHTMLString("<style>body{background:#fff}</style><p>probe</p>", baseURL: URL(string: "https://example.com/case")!)
    pump(2)
    @MainActor func attribute(_ name: String) -> String {
        var out = "?"; var done = false
        probeView.evaluateJavaScript("document.documentElement.dataset.\(name) || 'none'") { r, _ in out = (r as? String) ?? "nil"; done = true }
        while !done { pump(0.05) }
        return out
    }
    check(attribute("probe") == "dark/light", "an extension\u{2019}s own script sees satellite.appearance: dark Satellite, light page (\(attribute("probe")))")
    set(.light)
    pump(0.6)
    check(attribute("probeChanged") == "light/light", "\u{2026}and its onChange hears Satellite turning light (\(attribute("probeChanged")))")
    try? FileManager.default.removeItem(at: folder)
    AppAppearance.apply(.system)
}
print(failures == 0 ? "\nAll appearance checks passed." : "\n\(failures) failed.")
exit(failures == 0 ? 0 : 1)
