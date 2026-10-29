import WebKit

struct PageInteractionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Clicking and typing for Satellite's local MCP server (`MCPBridge`): the write counterpart to `PageSnapshot`.
/// Selectors use the same `>>` shadow-root convention `PageSnapshot` documents and lists in a snapshot's
/// "Interactive elements", so an agent can read a page, then act on exactly what it found there. One that starts
/// with `frame:<path> >> ` acts in that iframe (`FrameRegistry` knows each frame, other sites' included). There is
/// no confirmation at this layer — `MCPBridge` asks once per agent before any of this runs, because clicking and
/// typing can submit forms and change data.
@MainActor
enum PageInteraction {
    /// How a snapshot names a frame at the start of its selectors: `frame:0 >> `, `frame:0.1 >> ` for a frame
    /// inside it.
    nonisolated static func framePrefix(_ path: [Int]) -> String {
        "frame:" + path.map(String.init).joined(separator: ".") + " >> "
    }

    /// Where a selector acts: the frame it names (nil for the page itself), and the selector within it.
    struct Target {
        let frame: FrameRegistry.Record?
        let selector: String
    }

    struct FrameGone: LocalizedError {
        let path: String
        var errorDescription: String? { "Frame \(path) isn\u{2019}t on the page any more (it may have reloaded). Read the page again for current selectors." }
    }

    static func target(_ selector: String, in webView: WKWebView) throws -> Target {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("frame:"), let split = trimmed.range(of: ">>") else { return Target(frame: nil, selector: trimmed) }
        let pathText = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<split.lowerBound].trimmingCharacters(in: .whitespaces)
        let path = pathText.split(separator: ".").compactMap { Int($0) }
        guard !path.isEmpty, path.count == pathText.split(separator: ".").count,
              let record = FrameRegistry.shared.frames(of: webView).first(where: { $0.path == path }) else { throw FrameGone(path: pathText) }
        return Target(frame: record, selector: String(trimmed[split.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
    struct Clicked {
        /// What was clicked when `selector` named something that isn't itself a control (a table cell, say) and
        /// held one: that control, like "the link “475961231”"; nil when the element itself was clicked.
        let inside: String?
    }

    /// Clicks the element `selector` resolves to, or, if that isn't a control, the first control inside it (as
    /// clicking a cell clicks its link). Nil if nothing matched.
    static func click(_ webView: WKWebView, selector: String) async throws -> Clicked? {
        let target = try target(selector, in: webView)
        let result = try await run(clickScript, in: webView, frame: target.frame, arguments: ["selector": target.selector])
        guard result["found"] as? Bool == true else { return nil }
        return Clicked(inside: result["inside"] as? String)
    }

    /// Replaces the content of the field (or contenteditable element) `selector` resolves to with `text`, then,
    /// with `pressEnter`, dispatches an Enter key and submits its form if it has one. Returns whether it was found.
    static func type(_ webView: WKWebView, selector: String, text: String, pressEnter: Bool) async throws -> Bool {
        let target = try target(selector, in: webView)
        let result = try await run(typeScript, in: webView, frame: target.frame, arguments: ["selector": target.selector, "text": text, "pressEnter": pressEnter])
        return result["found"] as? Bool ?? false
    }

    private static func run(_ script: String, in webView: WKWebView, frame: FrameRegistry.Record?, arguments: [String: Any]) async throws -> [String: Any] {
        guard webView.url != nil else { throw PageInteractionError("There is no page to act on yet.") }
        let value: Any? = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in try await webView.callAsyncJavaScript(script, arguments: arguments, in: frame?.info, contentWorld: .page) }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw PageInteractionError("The page took too long to answer.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let dictionary = value as? [String: Any] else { throw PageInteractionError("The page returned nothing.") }
        return dictionary
    }

    // MARK: - Scripts

    /// Resolves a `PageSnapshot` selector: plain CSS within a root, `>>` to cross into a shadow root.
    private static let resolver = #"""
    function __satelliteResolve(full) {
      const parts = full.split(/\s*>>\s*/).filter(Boolean);
      let root = document, el = null;
      for (let i = 0; i < parts.length; i++) {
        el = root.querySelector(parts[i]);
        if (!el) return null;
        if (i < parts.length - 1) {
          if (!el.shadowRoot) return null;
          root = el.shadowRoot;
        }
      }
      return el;
    }
    """#

    /// What counts as a control to click, and the first one inside an element (into shadow roots too).
    private static let controls = #"""
    const CONTROL = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=switch],[role=option],[contenteditable=true]';
    function __satelliteFirstControl(el) {
      const search = (node) => {
        for (let child = node.firstElementChild; child; child = child.nextElementSibling) {
          if (child.matches(CONTROL)) return child;
          const found = (child.shadowRoot && search(child.shadowRoot)) || search(child);
          if (found) return found;
        }
        return null;
      };
      return (el.shadowRoot && search(el.shadowRoot)) || search(el);
    }
    """#

    private static let clickScript = resolver + controls + #"""

    const el = __satelliteResolve(selector);
    if (!el) return { found: false };
    // A cell or a wrapper holds the link or button; clicking it the way a person would means clicking that.
    const target = el.matches(CONTROL) ? el : (__satelliteFirstControl(el) || el);
    target.scrollIntoView({ block: 'center', inline: 'center' });
    target.click();
    if (target === el) return { found: true };
    const name = (target.getAttribute('aria-label') || target.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60);
    const kind = target.localName === 'a' ? 'link' : (target.getAttribute('role') || target.localName);
    return { found: true, inside: 'the ' + kind + (name ? ' “' + name + '”' : '') + ' inside it' };
    """#

    private static let typeScript = resolver + #"""

    const el = __satelliteResolve(selector);
    if (!el) return { found: false };
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus();
    // A component (lightning-input, say) passes focus to a field in its own shadow root: type where focus went.
    let field = el;
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    if (active && active !== el && (el.contains(active) || (el.shadowRoot && active.getRootNode() !== document))) field = active;
    const isField = field.tagName === 'INPUT' || field.tagName === 'TEXTAREA';
    if (isField) {
      field.select();
    } else if (field.isContentEditable) {
      // Select what's there, so the text typed below replaces it (as in a field) instead of going in at the caret.
      const range = document.createRange();
      range.selectNodeContents(field);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    let inserted = false;
    if (document.execCommand && document.execCommand('insertText', false, text)) {
      inserted = true;
    } else if (isField) {
      const proto = field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(field, text);
      field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: text }));
      inserted = true;
    } else if (field.isContentEditable) {
      field.textContent = text;
      field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: text }));
      inserted = true;
    }
    if (inserted && pressEnter) {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        const event = new KeyboardEvent(type, { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true, composed: true });
        // The constructor leaves the legacy codes at 0, and Lightning (like many pages) checks keyCode === 13.
        for (const legacy of ['keyCode', 'which', 'charCode']) Object.defineProperty(event, legacy, { get: () => 13 });
        field.dispatchEvent(event);
      }
      if (field.form && typeof field.form.requestSubmit === 'function') field.form.requestSubmit();
    }
    return { found: true, inserted };
    """#
}
