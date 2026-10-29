import AppKit
import WebKit

// MARK: - Settings

enum SnapshotDefaults {
    static let textMode = "snapshotTextMode"
    static let includeGuide = "snapshotIncludeGuide"
    /// What agents reading through the local MCP server get, separately from Copy Page for AI and Send to Assistant.
    static let agentTextMode = "agentSnapshotTextMode"
}

/// How much of the page's visible text goes into a snapshot.
enum SnapshotTextMode: String, CaseIterable {
    /// Every piece of text (trimmed to a sensible length).
    case full
    /// Text that labels the interface (buttons, links, headings, field labels); other text is replaced by its length.
    case labels
    /// No text at all, only structure.
    case none

    static var current: SnapshotTextMode {
        SnapshotTextMode(rawValue: UserDefaults.standard.string(forKey: SnapshotDefaults.textMode) ?? "") ?? .labels
    }

    /// For agents, all text unless the user chose otherwise: an agent is asked for by name and allowed explicitly,
    /// and searching what pages say is what it's for. (Copy Page for AI and Send to Assistant keep `current`.)
    static var forAgents: SnapshotTextMode {
        SnapshotTextMode(rawValue: UserDefaults.standard.string(forKey: SnapshotDefaults.agentTextMode) ?? "") ?? .full
    }

    var summary: String {
        switch self {
        case .full: return "all text kept"
        case .labels: return "interface labels kept, other text hidden"
        case .none: return "all text hidden"
        }
    }
}

// MARK: - Frames

/// Remembers every frame of every web view, so a snapshot can reach frames of other sites too.
///
/// A small script in each frame (in a private content world, so pages can't call it) tells us the frame exists.
/// WebKit gives the message's `WKFrameInfo`, which is what lets us run code inside that exact frame later.
@MainActor
final class FrameRegistry: NSObject, WKScriptMessageHandler {
    static let shared = FrameRegistry()
    static let handlerName = "satelliteFrame"
    static let world = WKContentWorld.world(name: "satellite.frames")

    struct Record {
        let info: WKFrameInfo
        let path: [Int]
        let url: String
    }

    private final class Table {
        var records: [String: Record] = [:]
    }

    private let tables = NSMapTable<WKWebView, Table>.weakToStrongObjects()

    func install(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let body = message.body as? [String: Any],
              let path = (body["path"] as? [NSNumber])?.map(\.intValue), let url = body["url"] as? String else { return }
        let table = tables.object(forKey: webView) ?? Table()
        table.records[path.map(String.init).joined(separator: ".")] = Record(info: message.frameInfo, path: path, url: url)
        tables.setObject(table, forKey: webView)
    }

    /// The frames known for `webView`, main frame first, in document order.
    func frames(of webView: WKWebView) -> [Record] {
        (tables.object(forKey: webView)?.records.values.filter { $0.info.webView === webView } ?? [])
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    func forget(_ webView: WKWebView, path: [Int]) {
        tables.object(forKey: webView)?.records[path.map(String.init).joined(separator: ".")] = nil
    }

    private static let script = #"""
    (function () {
      try {
        const path = () => {
          const parts = [];
          let current = window;
          while (current !== current.parent) {
            const parent = current.parent;
            let index = -1;
            for (let i = 0; i < parent.frames.length; i++) { if (parent.frames[i] === current) { index = i; break; } }
            parts.unshift(index);
            current = parent;
          }
          return parts;
        };
        window.webkit.messageHandlers.satelliteFrame.postMessage({ path: path(), url: location.href });
      } catch (error) {}
    })();
    """#
}

// MARK: - Capture

struct PageSnapshotError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
enum PageSnapshot {
    struct Options {
        var text: SnapshotTextMode = .current
        var includeGuide = UserDefaults.standard.object(forKey: SnapshotDefaults.includeGuide) as? Bool ?? true
        /// For an assistant to help with the page, rather than to write an extension: no extension guide, no task
        /// to fill in, and none of the scripts, stylesheets and globals only an extension author needs.
        var forAssistant = false
        /// Roughly how many characters of HTML the main page and each frame may take. A page with more is shown in
        /// less detail (shortened attributes and text, then only useful attributes, then an outline) until it
        /// fits, and cut as a last resort.
        var mainBudget = 400_000
        var frameBudget = 120_000
        /// At most this many clickable elements are listed (each with a selector), per page or frame.
        var interactiveLimit = 300
        /// For an agent acting on the page (Satellite's MCP server), rather than a person writing an extension:
        /// visible controls first, in the order they're shown, each with the shortest selector that finds it and a
        /// link's address; and the page's visible text, a table row per line. Selectors are for using now, not for
        /// keeping, so short beats stable.
        var forAgent = false
        /// With `forAgent`: about how many characters the list of controls and the visible text may take.
        var interactiveChars = 25_000
        var visibleText = 30_000
        /// The Settings > General option that decides `text`, named when text is left out.
        var textSetting = "Page text in snapshots"
    }

    /// Captures the page shown in `webView`, including its frames, as a Markdown document.
    static func capture(_ webView: WKWebView, options: Options = Options()) async throws -> String {
        guard webView.url != nil else { throw PageSnapshotError("There is no page to capture yet.") }

        let main = try await collect(in: webView, frame: nil, options: options, budget: options.mainBudget)
        var children: [Captured] = []
        for record in FrameRegistry.shared.frames(of: webView) where !record.path.isEmpty {
            do {
                children.append(try await collect(in: webView, frame: record.info, options: options, budget: options.frameBudget))
            } catch {
                FrameRegistry.shared.forget(webView, path: record.path)   // the frame went away
            }
        }
        return compose(main: main, frames: children, options: options)
    }

    private static func collect(in webView: WKWebView, frame: WKFrameInfo?, options: Options, budget: Int) async throws -> Captured {
        let arguments: [String: Any] = ["options": [
            "text": options.text.rawValue, "budget": budget, "interactiveLimit": options.interactiveLimit,
            "agent": options.forAgent, "interactiveChars": options.interactiveChars,
            "visibleText": frame == nil ? options.visibleText : min(options.visibleText, budget),
        ] as [String: Any]]
        let value: Any? = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                try await webView.callAsyncJavaScript(collectorScript, arguments: arguments, in: frame, contentWorld: .page)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw PageSnapshotError("The page took too long to answer.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let dictionary = value as? [String: Any] else { throw PageSnapshotError("The page returned nothing to capture.") }
        return Captured(dictionary)
    }

    // MARK: Model

    struct Captured {
        var path: [Int]
        var url: String
        var title: String
        var language: String
        var viewport: String
        var html: String
        var detail: String
        var stats: [String: Int]
        var interactive: [[String: Any]]
        /// How many more controls there were than are listed (an agent's list has a size budget).
        var interactiveOmitted: Int
        /// With `forAgent`: the page's visible text, a line per block and a `|`-joined line per table row.
        var visibleText: String
        var globals: [[String: Any]]
        var hints: [String]
        var scripts: [String]
        var styles: [String]
        var meta: [String]

        init(_ d: [String: Any]) {
            path = (d["path"] as? [NSNumber])?.map(\.intValue) ?? []
            url = d["url"] as? String ?? ""
            title = d["title"] as? String ?? ""
            language = d["language"] as? String ?? ""
            viewport = d["viewport"] as? String ?? ""
            html = d["html"] as? String ?? ""
            detail = d["detail"] as? String ?? "full"
            stats = (d["stats"] as? [String: NSNumber])?.mapValues(\.intValue) ?? [:]
            interactive = d["interactive"] as? [[String: Any]] ?? []
            interactiveOmitted = (d["interactiveOmitted"] as? NSNumber)?.intValue ?? 0
            visibleText = d["visibleText"] as? String ?? ""
            globals = d["globals"] as? [[String: Any]] ?? []
            hints = d["hints"] as? [String] ?? []
            scripts = d["scripts"] as? [String] ?? []
            styles = d["styles"] as? [String] ?? []
            meta = d["meta"] as? [String] ?? []
        }

        var pathLabel: String { path.isEmpty ? "main page" : "frame " + path.map(String.init).joined(separator: ".") }
    }

    // MARK: Markdown

    private static func compose(main: Captured, frames: [Captured], options: Options) -> String {
        var out: String
        if options.forAssistant {
            out = "# Web page shared from Satellite\n\n"
            out += "The page the user has open in Satellite (a browser), shared so you can help with it.\n\n"
        } else {
            out = "# Satellite page snapshot\n\n"
            out += "A snapshot of a web page, captured so you can write a Satellite browser extension for it.\n\n"
        }
        out += "- **URL:** \(main.url)\n"
        out += "- **Title:** \(main.title)\n"
        out += "- **Captured:** \(ISO8601DateFormatter().string(from: Date())) with Satellite \(AppInfo.version)\n"
        if !main.viewport.isEmpty { out += "- **Window:** \(main.viewport)\(main.language.isEmpty ? "" : ", language \(main.language)")\n" }
        out += "- **Text:** \(options.text.summary)"
        // Whoever reads this (an assistant, an agent) can then tell the user why page text is missing, and where.
        if options.forAssistant, options.text != .full { out += " (the user can include all of it in Satellite\u{2019}s Settings > General > \(options.textSetting))" }
        out += "\n"
        if !main.hints.isEmpty { out += "- **Looks like:** \(main.hints.joined(separator: "; "))\n" }
        out += "- **Frames:** \(frames.isEmpty ? "none besides the main page" : frames.map { "\($0.pathLabel) (\($0.url))" }.joined(separator: ", "))\n"
        out += "\n"

        if !options.forAssistant {
            if options.includeGuide { out += guide + "\n" }
            out += "## Task\n\n_Describe here what the extension should do (and on which part of the page)._\n\n"
        }

        for page in [main] + frames {
            let heading = page.path.isEmpty ? "Page" : "Frame \(page.path.map(String.init).joined(separator: "."))"
            out += "## \(heading)\n\n"
            if !page.path.isEmpty { out += "- **URL:** \(page.url)\n- **Title:** \(page.title)\n" }
            var facts = ["\(page.stats["elements"] ?? 0) elements", "\(page.stats["shadowRoots"] ?? 0) shadow roots", "\(page.stats["iframes"] ?? 0) iframes"]
            if (page.stats["omitted"] ?? 0) > 0 { facts.append("\(page.stats["omitted"] ?? 0) repeated siblings omitted") }
            out += "- **Size:** \(facts.joined(separator: ", ")). Detail level: \(page.detail)\(detailNote(page.detail))\n\n"

            if page.path.isEmpty, !options.forAssistant {
                if !page.globals.isEmpty {
                    out += "### JavaScript globals the page defines\n\n"
                    out += "Only visible to extensions with `\"world\": \"main\"`.\n\n"
                    out += page.globals.map { "`\($0["name"] as? String ?? "?")` (\($0["type"] as? String ?? "?"))" }.joined(separator: ", ") + "\n\n"
                }
                if !page.scripts.isEmpty { out += "### Scripts\n\n" + page.scripts.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
                if !page.styles.isEmpty { out += "### Stylesheets\n\n" + page.styles.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
                if !page.meta.isEmpty { out += "### Meta tags\n\n" + page.meta.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
            }

            if !page.interactive.isEmpty {
                out += "### Interactive elements\n\n"
                if options.forAgent {
                    out += "Visible ones first, in the order they're shown. Pass a selector as it is to click_element or type_text (`>>` is where it enters a shadow root).\n\n"
                } else {
                    out += "Selectors use `>>` where the path enters a shadow root (`document.querySelector` cannot cross it; query the host's `shadowRoot` next).\n\n"
                }
                for item in page.interactive {
                    var line = "- `\(item["selector"] as? String ?? "?")`"
                    if let role = item["role"] as? String, !role.isEmpty { line += " \(role)" }
                    if let text = item["text"] as? String, !text.isEmpty { line += " \u{201C}\(text)\u{201D}" }
                    if let href = item["href"] as? String, !href.isEmpty { line += " \u{2192} \(href)" }
                    if item["hidden"] as? Bool == true { line += " (hidden)" }
                    out += line + "\n"
                }
                if page.interactiveOmitted > 0 { out += "- \u{2026}and \(page.interactiveOmitted) more, not listed (to keep the answer within an agent\u{2019}s limit)\n" }
                out += "\n"
            }

            if !page.visibleText.isEmpty {
                out += "### Visible text\n\nWhat the page shows, in order: a line per block, and a line per table row with its cells separated by `|`.\n\n"
                out += "````text\n\(page.visibleText)\n````\n\n"
            }

            out += "### HTML\n\n````html\n\(page.html)\n````\n\n"
        }
        return out
    }

    private static func detailNote(_ detail: String) -> String {
        switch detail {
        case "trimmed": return " (long attributes and text shortened, long runs of similar siblings cut)"
        case "compact": return " (page was large: only useful attributes kept, hidden elements and graphics dropped)"
        case "outline": return " (page was very large: outline only)"
        default: return ""
        }
    }

    private static let guide = """
    ## How to write a Satellite extension

    Satellite is a macOS app that shows web apps in one window and runs user extensions in them. An extension is a folder with a `manifest.json` and scripts. Reply with the files in separate code blocks, each headed by its file name.

    ```json
    {
      "name": "My Extension", "version": "1.0.0", "author": "Me", "description": "What it does",
      "matches": ["*://*.lightning.force.com/*"],
      "js": ["content.js"], "css": ["style.css"],
      "run_at": "document_idle",
      "world": "isolated",
      "permissions": ["storage"],
      "dependencies": { "shared-utils": "^1.0.0" }
    }
    ```

    - `matches` are Chrome match patterns (`*://host/path*`, `<all_urls>`); derive them from the URL above. `exclude_matches` is optional. Fields are required: `name`, `version`, `author`, `description`.
    - `run_at`: `document_start`, `document_end` (default) or `document_idle`. Scripts run inside an `async` function, so top-level `await` works.
    - `world`: `isolated` (default) sees the DOM and the `satellite` API but not the page's own JavaScript variables. `main` shares the page's JavaScript globals but has no `satellite` API.
    - Pages here are single-page apps that re-render constantly: wait for elements (MutationObserver), don't assume they exist at load, and prefer stable hooks (`id`, `data-*`, `aria-label`, `role`, tag names of custom elements) over generated class names. Open shadow roots are reachable through `element.shadowRoot`; `querySelector` does not cross them.
    - Permissions in `permissions` (only what is used): `storage`, `notifications`, `open-external`, `ui`, `shortcuts`, `salesforce`.
    - `satellite` API: `storage.get/set/remove(key)`, `notify(title, body)`, `openExternal(url)`, `settings.get/getAll/set/register/onChange` (options declared in the manifest under `settings`: `{ key, type: string|number|boolean|choice, title, default, options }`), and with `ui`: `ui.apps` / `ui.assistants` with `list/add/update/remove/select` to change the sidebar (`{ id, name, url, symbol, badge }`), and with `shortcuts`: `shortcuts.register({ id, title, shortcut: 'Cmd+Shift+K' }, handler)` adds a keyboard shortcut and a command in the Extensions menu (also `unregister(id)`, `list()`, `onTrigger(callback)`); the shortcut needs Cmd or Ctrl, is not granted if already in use, and the user can change it in Settings > Shortcuts. The handler runs in the page in front and in the background script. With `salesforce`: `await salesforce.query(soql)` returns `{ totalSize, done, records }` from the REST API, read-only and signed in as the user, on Salesforce Lightning or My Domain pages.
    - `"background": "background.js"` runs once at startup with no page open (then `matches` is optional).
    - Libraries: `"type": "library"` extensions export with `module.exports`; dependents call `require('<id>')`. `shared-utils` provides `waitFor(selector, { root, timeout })`, `h(tag, props, ...children)` and `toast(text)`.
    - To try an extension, put its folder in `~/Library/Application Support/Satellite/Extensions/`, then Settings > Extensions > Reload Pages.

    """

    // MARK: Collector

    /// Runs inside a page (or frame) and returns everything the Markdown is built from.
    private static let collectorScript = #"""
    const mode = (options && options.text) || 'labels';
    const budget = (options && options.budget) || 400000;
    const interactiveLimit = (options && options.interactiveLimit) || 300;

    const VOID = new Set(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr']);
    const LABEL_TAGS = new Set(['button','a','label','th','h1','h2','h3','h4','h5','h6','option','legend','summary','caption','title','figcaption','dt','nav','optgroup']);
    const LABEL_ROLES = new Set(['button','tab','menuitem','menuitemcheckbox','menuitemradio','option','columnheader','rowheader','heading','link','treeitem','switch','checkbox','radio','tooltip']);
    const LABEL_CLASS = /label|title|header|heading|button|btn|tab|menu|nav|breadcrumb|toolbar|action|legend|caption|tooltip/i;
    const SENSITIVE_PARAM = /sid|token|session|secret|passw|auth|key|code|ticket|jwt|signature|csrf|nonce/i;
    const URL_ATTRS = new Set(['href', 'src', 'action', 'poster', 'data', 'formaction', 'cite']);
    const SKIP_ATTRS = new Set(['nonce', 'integrity', 'crossorigin', 'srcset', 'sizes', 'autocomplete']);
    const USEFUL = /^(id|class|name|type|role|slot|for|href|src|action|target|placeholder|alt|title|lang|disabled|checked|selected|readonly|required|hidden|tabindex|is|part|data-.*|aria-.*|lwc:.*|c-.*)$/;
    const CORE = /^(id|role|name|type|for|href|slot|aria-label|aria-labelledby|placeholder|data-(id|name|key|label|target.*|component.*|field.*|item.*|value))$/;
    const LEVELS = [
      { name: 'full',    attrs: 'all',    textMax: 240, repeat: 40, classMax: 99, skipHidden: false },
      { name: 'trimmed', attrs: 'useful', textMax: 100, repeat: 12, classMax: 8,  skipHidden: false },
      { name: 'compact', attrs: 'useful', textMax: 50,  repeat: 5,  classMax: 4,  skipHidden: true },
      { name: 'outline', attrs: 'core',   textMax: 24,  repeat: 3,  classMax: 2,  skipHidden: true },
    ];

    const trunc = (s, n) => (s.length > n ? s.slice(0, n) + '…' : s);
    const escAttr = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
    const escText = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

    const safeUrl = (value) => {
      if (/^data:/i.test(value)) return value.slice(0, Math.max(value.indexOf(',') + 1, 6)) + '…(' + value.length + ' chars)';
      if (/^javascript:/i.test(value)) return 'javascript:…';
      try {
        const url = new URL(value, location.href);
        let changed = false;
        for (const key of Array.from(url.searchParams.keys())) {
          if (SENSITIVE_PARAM.test(key)) { url.searchParams.set(key, 'REDACTED'); changed = true; }
        }
        if (/token|sid|access|session/i.test(url.hash)) { url.hash = '#REDACTED'; changed = true; }
        const relative = !/^[a-z][a-z0-9+.-]*:/i.test(value) && !value.startsWith('//');
        return trunc(relative ? (changed ? url.pathname + url.search + url.hash : value) : url.href, 300);
      } catch (e) { return trunc(value, 200); }
    };

    const isLabelish = (el) => {
      const role = el.getAttribute('role');
      return LABEL_TAGS.has(el.localName) || (role && LABEL_ROLES.has(role)) || LABEL_CLASS.test(el.getAttribute('class') || '');
    };

    // Every root (the document and each open shadow root), so nothing hides inside a component.
    const roots = [document];
    for (let i = 0; i < roots.length && roots.length < 4000; i++) {
      for (const el of roots[i].querySelectorAll('*')) {
        if (el.shadowRoot) roots.push(el.shadowRoot);
      }
    }

    const framePath = (() => {
      const parts = [];
      let current = window;
      while (current !== current.parent) {
        const parent = current.parent;
        let index = -1;
        for (let i = 0; i < parent.frames.length; i++) { if (parent.frames[i] === current) { index = i; break; } }
        parts.unshift(index);
        current = parent;
      }
      return parts;
    })();

    function render(level) {
      const out = [];
      const stats = { elements: 0, shadowRoots: 0, iframes: 0, omitted: 0 };
      const pad = (depth) => ' '.repeat(Math.min(depth, 24));

      const text = (value, inLabel) => {
        const t = value.replace(/\s+/g, ' ').trim();
        if (!t) return '';
        if (mode === 'none' || (mode === 'labels' && !inLabel)) return '[text:' + t.length + ']';
        return escText(trunc(t, level.textMax));
      };

      const attributes = (el, labelish) => {
        const parts = [];
        for (const attr of Array.from(el.attributes)) {
          const name = attr.name;
          let value = attr.value;
          if (SKIP_ATTRS.has(name)) continue;
          if (level.attrs === 'useful' && !USEFUL.test(name)) continue;
          if (level.attrs === 'core' && !CORE.test(name)) continue;
          if (name === 'style' && level.attrs !== 'all') continue;
          if (name === 'value' && el.localName === 'input' && !/^(button|submit|reset|radio|checkbox|image)$/i.test(el.getAttribute('type') || '')) continue;
          if (mode !== 'full' && (name === 'title' || name === 'alt') && !labelish) continue;
          if (mode === 'none' && (name === 'aria-label' || name === 'placeholder' || name === 'title' || name === 'alt' || name === 'value')) continue;
          if (URL_ATTRS.has(name)) value = safeUrl(value);
          else if (name === 'class') value = value.split(/\s+/).filter(Boolean).slice(0, level.classMax).join(' ');
          else value = trunc(value, level.attrs === 'all' ? 300 : 160);
          parts.push(value === '' ? name : name + '="' + escAttr(value) + '"');
        }
        return parts.length ? ' ' + parts.join(' ') : '';
      };

      const signature = (el) => el.localName + '|' + (el.getAttribute('class') || '').split(/\s+/).slice(0, 3).join('.');

      function children(nodes, inLabel, depth) {
        const list = Array.from(nodes).filter((n) => n.nodeType === 1 || (n.nodeType === 3 && n.nodeValue.trim()));
        let i = 0;
        while (i < list.length) {
          const node = list[i];
          if (node.nodeType === 3) {
            const t = text(node.nodeValue, inLabel);
            if (t) out.push(pad(depth) + t);
            i++;
            continue;
          }
          const sig = signature(node);
          let j = i;
          while (j < list.length && list[j].nodeType === 1 && signature(list[j]) === sig) j++;
          const show = Math.min(j - i, level.repeat);
          for (let k = i; k < i + show; k++) element(list[k], inLabel, depth);
          if (j - i > show) {
            stats.omitted += j - i - show;
            out.push(pad(depth) + '<!-- ' + (j - i - show) + ' more <' + node.localName + '> like the one above omitted -->');
          }
          i = j;
        }
      }

      function element(el, inLabel, depth) {
        const tag = el.localName;
        if (depth > 150) { out.push(pad(depth) + '<!-- nested too deeply -->'); return; }
        if (level.skipHidden && (el.hasAttribute('hidden') || el.getAttribute('aria-hidden') === 'true') ) return;
        if (tag === 'noscript') return;
        stats.elements++;
        const labelish = inLabel || isLabelish(el);
        const open = '<' + tag + attributes(el, labelish) + '>';

        if (tag === 'script') {
          const src = el.getAttribute('src');
          out.push(pad(depth) + (src ? '<script src="' + escAttr(safeUrl(src)) + '"></script>' : '<script><!-- inline, ' + (el.textContent || '').length + ' chars --></script>'));
          return;
        }
        if (tag === 'style') { out.push(pad(depth) + '<style><!-- ' + (el.textContent || '').length + ' chars of CSS --></style>'); return; }
        if (tag === 'svg') { if (level.skipHidden) return; out.push(pad(depth) + open + '<!-- graphic --></svg>'); return; }
        if (tag === 'template') { out.push(pad(depth) + open + '<!-- template --></template>'); return; }
        if (tag === 'iframe' || tag === 'frame') {
          stats.iframes++;
          let index = -1;
          try { for (let i = 0; i < window.frames.length; i++) { if (window.frames[i] === el.contentWindow) { index = i; break; } } } catch (e) {}
          const where = index < 0 ? '' : ' (its content is under Frame ' + framePath.concat(index).join('.') + ')';
          out.push(pad(depth) + open + '</' + tag + '><!--' + where + ' -->');
          return;
        }
        if (VOID.has(tag)) { out.push(pad(depth) + open); return; }

        const shadow = el.shadowRoot;
        const kids = Array.from(el.childNodes).filter((n) => n.nodeType === 1 || (n.nodeType === 3 && n.nodeValue.trim()));
        if (!shadow && kids.length === 1 && kids[0].nodeType === 3) {
          out.push(pad(depth) + open + text(kids[0].nodeValue, labelish) + '</' + tag + '>');
          return;
        }
        if (!shadow && kids.length === 0) { out.push(pad(depth) + open + '</' + tag + '>'); return; }
        out.push(pad(depth) + open);
        if (shadow) {
          stats.shadowRoots++;
          out.push(pad(depth + 1) + '<template shadowrootmode="open">');
          children(shadow.childNodes, labelish, depth + 2);
          out.push(pad(depth + 1) + '</template>');
        }
        children(el.childNodes, labelish, depth + 1);
        out.push(pad(depth) + '</' + tag + '>');
      }

      const root = document.documentElement;
      if (root) element(root, false, 0);
      return { html: out.join('\n'), stats };
    }

    let html = '', stats = {}, detail = 'full';
    for (const level of LEVELS) {
      const result = render(level);
      html = result.html; stats = result.stats; detail = level.name;
      if (html.length <= budget) break;
    }
    if (html.length > budget) html = html.slice(0, budget) + '\n<!-- truncated: the page is larger than the snapshot limit -->';

    // Clickable things, with selectors an extension can use.
    const cssEscape = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^\w-]/g, '\\$&'));
    // Within each root (the document, or a shadow root) it walks up a few levels, or to an id, which is unique
    // in that root; inside a shadow root it then carries on from the host after `>>`. So every selector starts at
    // the document, which is where something resolving it (an extension, PageInteraction) starts too.
    const selectorFor = (el) => {
      const segments = [];
      let node = el;
      while (node && node.nodeType === 1) {
        for (let depth = 0; node && node.nodeType === 1 && depth < 7; depth++) {
          if (node.id && !/\d{3,}|[0-9a-f]{8}-/i.test(node.id)) { segments.unshift('#' + cssEscape(node.id)); break; }
          let part = node.localName;
          const classes = Array.from(node.classList || []).filter((c) => !/\d{3,}/.test(c)).slice(0, 2);
          if (classes.length) part += '.' + classes.map(cssEscape).join('.');
          const parent = node.parentElement;
          if (parent) {
            const same = Array.from(parent.children).filter((c) => c.localName === node.localName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
          }
          segments.unshift(part);
          if (!parent) break;
          node = parent;
        }
        const host = node && node.getRootNode && node.getRootNode().host;
        if (!host) break;
        segments.unshift('>>');
        node = host;
      }
      return segments.join(' ');
    };
    const INTERACTIVE = 'a[href],button,input,select,textarea,summary,[role=button],[role=tab],[role=menuitem],[role=link],[role=checkbox],[role=switch],[role=combobox],[role=option],[contenteditable=true],[tabindex]:not([tabindex="-1"]),lightning-button,lightning-button-icon,lightning-input,lightning-combobox,lightning-menu-item';
    const agent = !!(options && options.agent);
    const interactiveChars = agent ? ((options && options.interactiveChars) || 25000) : Infinity;
    const textBudget = agent && mode === 'full' ? ((options && options.visibleText) || 0) : 0;

    // Elements in the order they're shown: each element, then its shadow tree, then its children.
    function* composed(node) {
      for (let child = node.firstElementChild; child; child = child.nextElementSibling) {
        yield child;
        if (child.shadowRoot) yield* composed(child.shadowRoot);
        yield* composed(child);
      }
    }
    const visible = (el) => {
      try { if (el.checkVisibility) return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }); } catch (e) {}
      return el.getClientRects().length > 0;
    };
    // A composed tree's text (into shadow roots too), for a control whose label is drawn by its component.
    const composedText = (el) => {
      let out = '';
      const walk = (node) => {
        for (let child = node.firstChild; child && out.length < 200; child = child.nextSibling) {
          if (child.nodeType === 3) out += child.nodeValue + ' ';
          else if (child.nodeType === 1 && !/^(script|style|template)$/.test(child.localName)) {
            if (child.shadowRoot) walk(child.shadowRoot);
            walk(child);
          }
        }
      };
      if (el.shadowRoot) walk(el.shadowRoot);
      walk(el);
      return out;
    };

    // For an agent: the shortest selector that finds `el`. Within each root it climbs only until what it has is
    // unique there, then goes on from the host after `>>`. (An extension wants the longer, steadier `selectorFor`.)
    const uniqueIn = (root, selector) => { try { return root.querySelectorAll(selector).length === 1; } catch (e) { return false; } };
    const shortSelectorFor = (el) => {
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1) {
        const root = node.getRootNode();
        const segments = [];
        let n = node;
        for (let depth = 0; n && n.nodeType === 1 && depth < 8; depth++) {
          if (n.id && !/\d{3,}|[0-9a-f]{8}-/i.test(n.id)) {
            segments.unshift('#' + cssEscape(n.id));
          } else {
            let part = n.localName;
            const classes = Array.from(n.classList || []).filter((c) => !/\d{3,}/.test(c)).slice(0, 2);
            if (classes.length) part += '.' + classes.map(cssEscape).join('.');
            const parent = n.parentElement;
            if (parent) {
              const same = Array.from(parent.children).filter((c) => c.localName === n.localName);
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(n) + 1) + ')';
            }
            segments.unshift(part);
          }
          if (uniqueIn(root, segments.join(' '))) break;
          n = n.parentElement;
        }
        parts.unshift(segments.join(' '));
        const host = root && root.host;
        if (!host) break;
        node = host;
      }
      return parts.join(' >> ');
    };

    const interactive = [];
    let interactiveOmitted = 0;
    const describe = (el, hidden) => {
      const labelText = mode === 'none' ? '' : (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('label') || (agent ? composedText(el) : el.textContent) || '');
      const item = {
        selector: agent ? shortSelectorFor(el) : selectorFor(el),
        role: el.getAttribute('role') || (el.localName === 'input' ? 'input:' + (el.getAttribute('type') || 'text') : el.localName),
        text: isLabelish(el) || el.localName === 'input' || mode === 'full' ? trunc(labelText.replace(/\s+/g, ' ').trim(), 60) : '',
      };
      if (agent && el.localName === 'a' && el.getAttribute('href')) item.href = safeUrl(el.getAttribute('href'));
      if (hidden) item.hidden = true;
      return item;
    };
    if (agent) {
      // Visible controls first, in the order they're shown, then hidden ones (other console tabs, closed menus),
      // until the count or the size budget runs out; then just how many more there were.
      const shown = [], hiddenOnes = [];
      for (const el of composed(document)) {
        if (el.matches(INTERACTIVE)) (visible(el) ? shown : hiddenOnes).push(el);
      }
      let size = 0;
      for (const [el, hidden] of shown.map((el) => [el, false]).concat(hiddenOnes.map((el) => [el, true]))) {
        if (interactive.length >= interactiveLimit || size >= interactiveChars) { interactiveOmitted++; continue; }
        const item = describe(el, hidden);
        size += item.selector.length + item.text.length + (item.href || '').length + 16;
        interactive.push(item);
      }
    } else {
      const seenControls = new Set();
      for (const root of roots) {
        for (const el of root.querySelectorAll(INTERACTIVE)) {
          if (interactive.length >= interactiveLimit || seenControls.has(el)) continue;
          seenControls.add(el);
          interactive.push(describe(el, false));
        }
      }
    }

    // For an agent: what the page shows, as text. A table row is one line, its cells joined by `|`, so a list
    // of cases reads as one line per case, however large the page (the HTML above drops repeated rows when
    // it has to shrink).
    let visibleText = '';
    if (textBudget > 0) {
      const BLOCK = new Set(['address','article','aside','blockquote','dd','details','dialog','div','dl','dt','fieldset','figcaption','figure',
        'footer','form','h1','h2','h3','h4','h5','h6','header','hr','li','main','nav','ol','p','pre','section','summary','table','ul','br','label','option']);
      const SKIP = new Set(['script','style','noscript','template','svg','head','iframe','frame','select']);
      const lines = [];
      let size = 0, line = '';
      const flush = () => {
        const t = line.replace(/\s+/g, ' ').trim();
        line = '';
        if (t && t !== lines[lines.length - 1]) { lines.push(t); size += t.length + 1; }
      };
      const isRow = (el) => el.localName === 'tr' || el.getAttribute('role') === 'row';
      const cellsOf = (row) => Array.from(row.children).filter((c) => /^(td|th)$/.test(c.localName) || /^(cell|gridcell|columnheader|rowheader)$/.test(c.getAttribute('role') || ''));
      const walk = (node) => {
        for (let child = node.firstChild; child && size < textBudget; child = child.nextSibling) {
          if (child.nodeType === 3) { line += child.nodeValue + ' '; continue; }
          if (child.nodeType !== 1 || SKIP.has(child.localName) || !visible(child)) continue;
          if (isRow(child)) {
            flush();
            line = cellsOf(child).map((cell) => composedText(cell).replace(/\s+/g, ' ').trim()).filter(Boolean).join(' | ');
            flush();
            continue;
          }
          const block = BLOCK.has(child.localName);
          if (block) flush();
          if (child.shadowRoot) walk(child.shadowRoot);
          walk(child);
          if (block) flush();
        }
      };
      if (document.body) walk(document.body);
      flush();
      visibleText = lines.join('\n');
      if (visibleText.length > textBudget) visibleText = visibleText.slice(0, textBudget) + '\n…(the rest of the page’s text didn’t fit)';
    }

    // Page-level details only come from the main page.
    let globals = [], hints = [], scripts = [], styles = [], meta = [];
    if (window === window.top) {
      try {
        const probe = document.createElement('iframe');
        probe.style.display = 'none';
        document.documentElement.appendChild(probe);
        const baseline = new Set(Object.getOwnPropertyNames(probe.contentWindow));
        probe.remove();
        globals = Object.getOwnPropertyNames(window)
          .filter((k) => !baseline.has(k) && !/^(webkit|__satellite|\d+$)/.test(k))
          .slice(0, 150)
          .map((k) => { let type = 'unknown'; try { type = typeof window[k]; } catch (e) {} return { name: k, type }; });
      } catch (e) {}

      const prefixes = {};
      for (const root of roots) {
        for (const el of root.querySelectorAll('*')) {
          const dash = el.localName.indexOf('-');
          if (dash > 0) { const p = el.localName.slice(0, dash + 1); prefixes[p] = (prefixes[p] || 0) + 1; }
        }
      }
      if (window.$A || document.querySelector('[data-aura-rendered-by]')) hints.push('Salesforce Aura/Lightning (window.$A)');
      if (prefixes['lightning-'] || prefixes['force-'] || prefixes['one-']) hints.push('Salesforce Lightning Web Components');
      if (roots.length > 1) hints.push(String(roots.length - 1) + ' open shadow roots');
      const topPrefixes = Object.entries(prefixes).sort((a, b) => b[1] - a[1]).slice(0, 6).map(([p, n]) => p + '* ×' + n);
      if (topPrefixes.length) hints.push('custom elements: ' + topPrefixes.join(', '));

      scripts = Array.from(new Set(Array.from(document.scripts).map((s) => s.src).filter(Boolean).map(safeUrl))).slice(0, 60);
      styles = Array.from(new Set(Array.from(document.querySelectorAll('link[rel~=stylesheet]')).map((l) => l.href).filter(Boolean).map(safeUrl))).slice(0, 40);
      meta = Array.from(document.querySelectorAll('meta[name],meta[property]')).slice(0, 30).map((m) => {
        const key = m.getAttribute('name') || m.getAttribute('property');
        const value = /csrf|token|nonce|session/i.test(key) ? 'REDACTED' : trunc(m.getAttribute('content') || '', 120);
        return key + ': ' + value;
      });
    }

    return {
      path: framePath,
      url: safeUrl(location.href),
      title: document.title || '',
      language: document.documentElement.lang || '',
      viewport: window.innerWidth + '×' + window.innerHeight,
      html, detail, stats, interactive, interactiveOmitted, visibleText, globals, hints, scripts, styles, meta,
    };
    """#
}
