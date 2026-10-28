import WebKit

struct PageInteractionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Clicking and typing for Satellite's local MCP server (`MCPBridge`): the write counterpart to `PageSnapshot`.
/// Selectors use the same `>>` shadow-root convention `PageSnapshot` documents and lists in a snapshot's
/// "Interactive elements", so an agent can read a page, then act on exactly what it found there. Acts on the main
/// frame only; it doesn't reach into iframes. There is no confirmation at this layer — `MCPBridge` asks once per
/// agent before any of this runs, because clicking and typing can submit forms and change data.
@MainActor
enum PageInteraction {
    /// Clicks the element `selector` resolves to. Returns whether it was found.
    static func click(_ webView: WKWebView, selector: String) async throws -> Bool {
        let result = try await run(clickScript, in: webView, arguments: ["selector": selector])
        return result["found"] as? Bool ?? false
    }

    /// Replaces the content of the field (or contenteditable element) `selector` resolves to with `text`, then,
    /// with `pressEnter`, dispatches an Enter key and submits its form if it has one. Returns whether it was found.
    static func type(_ webView: WKWebView, selector: String, text: String, pressEnter: Bool) async throws -> Bool {
        let result = try await run(typeScript, in: webView, arguments: ["selector": selector, "text": text, "pressEnter": pressEnter])
        return result["found"] as? Bool ?? false
    }

    private static func run(_ script: String, in webView: WKWebView, arguments: [String: Any]) async throws -> [String: Any] {
        guard webView.url != nil else { throw PageInteractionError("There is no page to act on yet.") }
        let value: Any? = try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page) }
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

    private static let clickScript = resolver + #"""

    const el = __satelliteResolve(selector);
    if (!el) return { found: false };
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.click();
    return { found: true };
    """#

    private static let typeScript = resolver + #"""

    const el = __satelliteResolve(selector);
    if (!el) return { found: false };
    el.scrollIntoView({ block: 'center', inline: 'center' });
    el.focus();
    const isField = el.tagName === 'INPUT' || el.tagName === 'TEXTAREA';
    if (isField) el.select();
    let inserted = false;
    if (document.execCommand && document.execCommand('insertText', false, text)) {
      inserted = true;
    } else if (isField) {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
      inserted = true;
    } else if (el.isContentEditable) {
      el.textContent = text;
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
      inserted = true;
    }
    if (inserted && pressEnter) {
      for (const type of ['keydown', 'keypress', 'keyup']) {
        el.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
      }
      if (el.form && typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
    }
    return { found: true, inserted };
    """#
}
