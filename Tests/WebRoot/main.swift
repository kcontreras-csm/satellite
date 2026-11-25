// Checks for extension pages (web_root served at satellite-ext://<id>/), run by scripts/test-webroot.sh: compiled with
// the whole app module and run as a background accessory process against a throwaway SATELLITE_HOME. No network.
import AppKit
import WebKit

let app = SatelliteApplication.shared
app.setActivationPolicy(.accessory)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS: \(what)" : "FAIL: \(what)"); if !ok { failures += 1 } }
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func manifest(_ json: String, folder: String = "pages-test") -> Result<ExtensionManifest, Error> {
    Result { try ExtensionManifest.parse(Data(json.utf8), folderName: folder) }
}

let base = #""name": "Pages", "version": "1.0.0", "author": "Test", "description": "d", "matches": ["https://example.invalid/*"], "js": ["noop.js"]"#

// MARK: Manifest

if case .success(let m) = manifest("{\(base), \"web_root\": \"www\"}") { check(m.webRoot == "www", "web_root is read") }
else { check(false, "web_root is read") }
check((try? manifest("{\(base)}").get())?.webRoot == nil, "web_root is optional")
for bad in ["../www", "/www", "www/../..", ""] {
    if case .failure = manifest("{\(base), \"web_root\": \"\(bad)\"}") { check(true, "web_root \u{201C}\(bad)\u{201D} is refused") }
    else { check(false, "web_root \u{201C}\(bad)\u{201D} is refused") }
}
if case .failure = manifest(#"{"name": "L", "version": "1.0.0", "author": "T", "description": "d", "type": "library", "js": ["index.js"], "web_root": "www"}"#) {
    check(true, "a library can't have a web_root")
} else { check(false, "a library can't have a web_root") }
if case .success(let m) = manifest("{\(base), \"web_root\": \"www\"}") {
    check((try? validateStoreEntryFiles(m, files: [StoreFile(path: "noop.js", sha: nil, size: 1)])) == nil,
          "the store refuses extensions with a web_root (their pages aren't listed file by file)")
}

// MARK: Ranges

check(WebRootSchemeHandler.parseRange("bytes=2-5", size: 10) == 2...5, "range a-b")
check(WebRootSchemeHandler.parseRange("bytes=7-", size: 10) == 7...9, "range a-")
check(WebRootSchemeHandler.parseRange("bytes=-3", size: 10) == 7...9, "range -n")
check(WebRootSchemeHandler.parseRange("bytes=5-100", size: 10) == 5...9, "range past the end is cut to the end")
check(WebRootSchemeHandler.parseRange("bytes=10-", size: 10) == nil && WebRootSchemeHandler.parseRange("bytes=0-1,3-4", size: 10) == nil
      && WebRootSchemeHandler.parseRange("items=0-1", size: 10) == nil && WebRootSchemeHandler.parseRange("bytes=5-2", size: 10) == nil,
      "unsatisfiable, multiple or malformed ranges are refused")

// MARK: Serving

let fm = FileManager.default
let ext = AppPaths.extensions.appendingPathComponent("pages-test")
let www = ext.appendingPathComponent("www")
try! fm.createDirectory(at: www.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! Data("{\(base), \"web_root\": \"www\"}".utf8).write(to: ext.appendingPathComponent("manifest.json"))
try! Data("// nothing".utf8).write(to: ext.appendingPathComponent("noop.js"))
try! Data("outside the web root".utf8).write(to: ext.appendingPathComponent("secret.txt"))
try! Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]).write(to: www.appendingPathComponent("app.wasm"))
try! Data("0123456789".utf8).write(to: www.appendingPathComponent("digits.bin"))
try! Data("<title>sub</title>".utf8).write(to: www.appendingPathComponent("sub/index.html"))
try! fm.createSymbolicLink(at: www.appendingPathComponent("escape.txt"), withDestinationURL: ext.appendingPathComponent("secret.txt"))
// A 1x1 PNG, for loading from a page of another origin.
try! Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    .write(to: www.appendingPathComponent("pixel.png"))
try! Data("""
<script>
(async () => {
  const out = {};
  const status = async (path, init) => { try { return (await fetch(path, init)).status; } catch (e) { return 'error'; } };
  out.secure = window.isSecureContext;
  try { out.wasm = !!(await WebAssembly.instantiateStreaming(fetch('app.wasm'))).instance; } catch (e) { out.wasm = String(e); }
  out.sub = await (await fetch('sub/')).text();
  out.missing = await status('nope.js');
  out.escape = await status('escape.txt');
  out.dotdot = await status('%2E%2E/secret.txt');
  const ranged = await fetch('digits.bin', { headers: { Range: 'bytes=2-5' } });
  out.range = ranged.status + ' ' + await ranged.text() + ' ' + ranged.headers.get('Content-Range');
  out.head = (await fetch('digits.bin', { method: 'HEAD' })).headers.get('Content-Length');
  out.type = (await fetch('app.wasm')).headers.get('Content-Type');
  try {
    await new Promise((res, rej) => { const r = indexedDB.open('t', 1); r.onupgradeneeded = () => r.result.createObjectStore('s'); r.onsuccess = res; r.onerror = () => rej(r.error); });
    out.idb = 'ok';
  } catch (e) { out.idb = String(e); }
  window.webkit.messageHandlers.result.postMessage(JSON.stringify(out));
})();
</script>
""".utf8).write(to: www.appendingPathComponent("index.html"))

final class Collector: NSObject, WKScriptMessageHandler {
    var messages: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { messages.append(m.body as? String ?? "") }
}

MainActor.assumeIsolated {
    ExtensionManager.shared.reload()
    check(ExtensionManager.shared.info("pages-test")?.manifest?.webRoot == "www", "the test extension loads with its web_root")

    let collector = Collector()
    func makeView() -> WKWebView {
        let config = WebEnvironment.makeConfiguration()
        config.userContentController = WKUserContentController()
        config.userContentController.add(collector, name: "result")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        return view
    }
    func waitForMessage(_ seconds: Double = 10) -> [String: Any]? {
        let start = collector.messages.count
        let deadline = Date().addingTimeInterval(seconds)
        while collector.messages.count == start, Date() < deadline { pump(0.1) }
        guard collector.messages.count > start, let data = collector.messages.last?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func bodyText(_ view: WKWebView) -> String {
        var text = ""
        var done = false
        view.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in text = value as? String ?? ""; done = true }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { pump(0.05) }
        return text
    }

    let view = makeView()
    view.load(URLRequest(url: WebRootSchemeHandler.url(extensionID: "pages-test")!))
    if let r = waitForMessage() {
        check(r["secure"] as? Bool == true, "an extension page is a secure context")
        check(r["wasm"] as? Bool == true, "WebAssembly loads with instantiateStreaming: \(r["wasm"] ?? "nil")")
        check(r["type"] as? String == "application/wasm", ".wasm is served as application/wasm")
        check(r["sub"] as? String == "<title>sub</title>", "a folder serves its index.html")
        check(r["missing"] as? Int == 404, "a missing file is 404")
        check(r["escape"] as? Int == 404, "a symlink out of the web root is refused")
        check(r["dotdot"] as? Int == 404, "an encoded ../ can't leave the web root")
        check(r["range"] as? String == "206 2345 bytes 2-5/10", "byte ranges: \(r["range"] ?? "nil")")
        check(r["head"] as? String == "10", "HEAD gives the length")
        check(r["idb"] as? String == "ok", "the page has IndexedDB: \(r["idb"] ?? "nil")")
    } else {
        check(false, "the extension page ran")
    }

    // Another origin can't use an extension's files.
    let other = makeView()
    other.loadHTMLString("""
    <img src="satellite-ext://pages-test/pixel.png" onload="webkit.messageHandlers.result.postMessage('{&quot;img&quot;:&quot;loaded&quot;}')"
         onerror="webkit.messageHandlers.result.postMessage('{&quot;img&quot;:&quot;refused&quot;}')">
    """, baseURL: URL(string: "https://example.com/")!)
    check(waitForMessage()?["img"] as? String == "refused", "a website can't load an extension's files")

    // Another extension's page can't either.
    view.loadHTMLString("""
    <script>fetch('satellite-ext://pages-test/digits.bin').then(r => r.status, () => 'error')
      .then(s => webkit.messageHandlers.result.postMessage(JSON.stringify({ status: s })));</script>
    """, baseURL: URL(string: "satellite-ext://another-ext/")!)
    let crossStatus = waitForMessage()?["status"]
    check(crossStatus as? Int == 403 || crossStatus as? String == "error", "another extension's page can't load them (\(crossStatus ?? "nil"))")

    // Disabled: not served.
    ExtensionManager.shared.setEnabled("pages-test", false)
    let disabled = makeView()
    disabled.load(URLRequest(url: WebRootSchemeHandler.url(extensionID: "pages-test")!))
    pump(1.5)
    check(bodyText(disabled) == "Not found", "a disabled extension's pages aren't served")
    ExtensionManager.shared.setEnabled("pages-test", true)

    // Sidebar items may open the owner's own pages, and nobody else's.
    let own = Result { try UIRegistry.shared.add(.apps, owner: "pages-test", input: ["id": "game", "name": "Game", "url": "satellite-ext://pages-test/"]) }
    if case .failure(let error) = own { check(false, "an extension can add a sidebar item for its own page: \(error)") }
    else { check(true, "an extension can add a sidebar item for its own page") }
    let foreign = Result { try UIRegistry.shared.add(.apps, owner: "someone-else", input: ["id": "game", "name": "Game", "url": "satellite-ext://pages-test/"]) }
    if case .failure = foreign { check(true, "\u{2026}but not one for another extension\u{2019}s page") } else { check(false, "\u{2026}but not one for another extension\u{2019}s page") }
    let script = Result { try UIRegistry.shared.add(.apps, owner: "pages-test", input: ["id": "js", "name": "JS", "url": "javascript:alert(1)"]) }
    if case .failure = script { check(true, "other schemes are still refused") } else { check(false, "other schemes are still refused") }
}

print(failures == 0 ? "All web_root checks passed." : "\(failures) web_root check(s) failed.")
exit(failures == 0 ? 0 : 1)
