import AppKit
import WebKit

// MARK: - What is sent

/// The text that goes into an assistant's message box.
struct AssistantPayload: Equatable {
    enum Kind: Equatable {
        case selection
        case page
    }

    var kind: Kind
    var text: String

    /// The selected text, quoted, after where it came from, with an empty line under it for the question.
    static func selection(_ text: String, title: String, url: URL?) -> AssistantPayload {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        let quoted = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        switch (name.isEmpty, url?.absoluteString) {
        case (false, let address?): source = "From \u{201C}\(name)\u{201D} (\(address)):"
        case (true, let address?): source = "From \(address):"
        case (false, nil): source = "From \u{201C}\(name)\u{201D}:"
        case (true, nil): source = "From a page I have open:"
        }
        return AssistantPayload(kind: .selection, text: source + "\n\n" + quoted + "\n\n")
    }
}

// MARK: - Reading the selection

/// The text selected on a page, in the page itself, a text field, or any of its frames.
@MainActor
enum PageSelection {
    static let world = WKContentWorld.world(name: "satellite.selection")

    private static let script = """
    const selection = window.getSelection();
    const text = selection ? String(selection) : '';
    if (text.trim()) return text;
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    if (active && (active.localName === 'textarea' || active.localName === 'input')) {
      try {
        if (active.selectionEnd > active.selectionStart) return active.value.substring(active.selectionStart, active.selectionEnd);
      } catch (error) {}
    }
    return '';
    """

    /// The first non-empty selection: the page's, then its frames' in document order. Empty if nothing is selected.
    static func text(in webView: WKWebView) async -> String {
        let frames: [(WKFrameInfo?, [Int])] = [(nil, [])]
            + FrameRegistry.shared.frames(of: webView).filter { !$0.path.isEmpty }.map { ($0.info, $0.path) }
        for (frame, path) in frames {
            do {
                if let text = try await webView.callAsyncJavaScript(script, arguments: [:], in: frame, contentWorld: world) as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            } catch {
                if !path.isEmpty { FrameRegistry.shared.forget(webView, path: path) }   // the frame went away
            }
        }
        return ""
    }
}

// MARK: - The assistant's message box

/// Finds an assistant's message box and puts text in it, the way pasting it would, without sending it.
///
/// It first offers the text as a paste, so the site does what it does with a real paste (claude.ai, for one, turns
/// long text into an attachment). If the site ignores that, it types the text in. The script runs in a private
/// content world, so the site's own scripts can't call it.
@MainActor
enum AssistantComposer {
    static let world = WKContentWorld.world(name: "satellite.assistant")

    /// Longer text is not typed in (a long insert can stall the page); it goes to the clipboard instead.
    nonisolated static let typedLimit = 100_000

    /// Where the message box is on sites known to Satellite, by host. Tried before the general search, which
    /// is what handles any other assistant (and these, if their pages change).
    nonisolated static let hints: [String: [String]] = [
        "claude.ai": ["div.ProseMirror[contenteditable=true]", "[contenteditable=true][role=textbox]"],
        "gemini.google.com": ["rich-textarea .ql-editor[contenteditable=true]", ".ql-editor[contenteditable=true]"],
        "slack.com": ["[data-qa=message_input] [contenteditable=true]", ".ql-editor[contenteditable=true]"],
    ]

    struct Result: Equatable {
        var found: Bool
        var inserted: Bool
        var method: String?
        var reason: String?
    }

    /// Whether the page shows a message box yet.
    static func hasComposer(_ webView: WKWebView, hints: [String: [String]] = hints) async -> Bool {
        await run(text: nil, in: webView, hints: hints).found
    }

    static func insert(_ text: String, into webView: WKWebView, hints: [String: [String]] = hints) async -> Result {
        await run(text: text, in: webView, hints: hints)
    }

    private static func run(text: String?, in webView: WKWebView, hints: [String: [String]]) async -> Result {
        let arguments: [String: Any] = ["text": text ?? NSNull(), "hints": hints, "typedLimit": typedLimit]
        guard let value = try? await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world) as? [String: Any] else {
            return Result(found: false, inserted: false, method: nil, reason: "the page didn\u{2019}t answer")
        }
        return Result(
            found: value["found"] as? Bool ?? false, inserted: value["inserted"] as? Bool ?? false,
            method: value["method"] as? String, reason: value["reason"] as? String)
    }

    private static let script = #"""
    const host = location.hostname;

    const roots = [];
    (function collect(root) {
      roots.push(root);
      for (const element of root.querySelectorAll('*')) if (element.shadowRoot) collect(element.shadowRoot);
    })(document);
    const queryAll = selector => roots.flatMap(root => { try { return [...root.querySelectorAll(selector)]; } catch (error) { return []; } });

    const isField = el => el && (el.localName === 'textarea' || (el.localName === 'input' && /^(text|search|)$/.test(el.type)));
    const isEditable = el => el && !el.disabled && !el.readOnly && (el.isContentEditable || isField(el));
    const isShown = el => {
      const rect = el.getBoundingClientRect();
      if (rect.width < 20 || rect.height < 8) return false;
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
    };
    const usable = el => isEditable(el) && isShown(el);

    function hinted() {
      for (const [suffix, selectors] of Object.entries(hints || {})) {
        if (host !== suffix && !host.endsWith('.' + suffix)) continue;
        for (const selector of selectors) {
          const found = queryAll(selector).find(usable);
          if (found) return found;
        }
      }
      return null;
    }

    // The editable area most likely to be where a message is written. The one with the keyboard counts for a lot,
    // but not everything: it may be a search field.
    function best() {
      let active = document.activeElement;
      while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
      const words = /message|prompt|ask|chat|reply|write|type|talk|question/i;
      let winner = null, top = -Infinity;
      for (const el of queryAll('textarea, input, [contenteditable]')) {
        if (!usable(el)) continue;
        if (el.isContentEditable && el.parentElement && el.parentElement.isContentEditable) continue;   // only the outermost
        const rect = el.getBoundingClientRect();
        const label = [el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('data-placeholder'), el.getAttribute('title'), el.getAttribute('name')].join(' ');
        let score = rect.width / Math.max(innerWidth, 1);
        if (el.getAttribute('role') === 'textbox' || el.getAttribute('aria-multiline') === 'true') score += 3;
        if (words.test(label)) score += 3;
        if (el.localName === 'textarea' || el.isContentEditable) score += 1;
        if (rect.top > innerHeight / 2) score += 2;
        if (el.localName === 'input') score -= 2;
        if (active && (el === active || el.contains(active))) score += 2;
        if (score > top) { top = score; winner = el; }
      }
      return winner;
    }

    const composer = hinted() || best();
    if (!composer) return { found: false, inserted: false };
    if (text === null) return { found: true, inserted: false };

    const contents = () => isField(composer) ? composer.value : composer.textContent;
    composer.focus();
    if (isField(composer)) {
      const end = composer.value.length;
      try { composer.setSelectionRange(end, end); } catch (error) {}
    } else if (composer.getRootNode() === document) {
      // The caret at the end, after anything already written.
      const range = document.createRange();
      range.selectNodeContents(composer);
      range.collapse(false);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    // (Inside a shadow root the page's selection can't point into the box; focusing it put the caret there.)
    const before = contents();

    // 1. A paste, as if the user pressed Cmd+V: the site decides what to do with it.
    const data = new DataTransfer();
    data.setData('text/plain', text);
    const paste = new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true });
    const notHandled = composer.dispatchEvent(paste);
    if (!notHandled && paste.clipboardData === data) return { found: true, inserted: true, method: 'paste' };

    if (text.length > typedLimit) return { found: true, inserted: false, reason: 'it is too long to type in' };

    // 2. Typed in, which sends the same input events typing does.
    if (document.execCommand('insertText', false, text) && contents() !== before) return { found: true, inserted: true, method: 'typed' };

    // 3. A plain text field: set its value the way frameworks notice.
    if (isField(composer)) {
      const prototype = composer.localName === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, 'value').set.call(composer, composer.value + text);
      composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertFromPaste', data: text }));
      if (contents() !== before) return { found: true, inserted: true, method: 'value' };
    }
    return { found: true, inserted: false, reason: 'its message box didn’t accept the text' };
    """#
}

// MARK: - Which assistants may receive pages

/// The assistants the user has said may receive page content without asking first. Off for every assistant
/// until the user turns it on, because pages often hold customer data and not every assistant is approved for it.
final class AssistantTrust: ObservableObject {
    static let shared = AssistantTrust()
    private static let key = "assistantsTrustedForPages"

    @Published private(set) var trusted: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        trusted = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isTrusted(_ id: String) -> Bool { trusted.contains(id) }

    func set(_ id: String, trusted value: Bool) {
        if value { trusted.insert(id) } else { trusted.remove(id) }
        defaults.set(trusted.sorted(), forKey: Self.key)
    }
}

// MARK: - Sending

/// Where sent text goes: an assistant's web page, or a terminal in the side panel.
enum AssistantDestination {
    case page(WebPane)
    case terminal(TerminalPane)
}

/// Sends what is on a page (the selection, or the whole page) to an assistant in the side panel: it asks first
/// unless the assistant is trusted, opens the assistant, waits for its message box and puts the text there. It
/// never sends the message; the user reads it and presses Return. If the text can't be put there, it goes to the
/// clipboard with a note saying so.
@MainActor
final class AssistantSender {
    enum Outcome: Equatable {
        case inserted(AssistantPayload.Kind)
        case copied(reason: String)
        case cancelled
        case nothingSelected
        case noPage
        case failed(String)
    }

    struct Answer {
        var send: Bool
        var remember: Bool
    }

    var pasteboard: NSPasteboard = .general
    var trust: AssistantTrust = .shared
    var hints = AssistantComposer.hints
    /// How long to wait for the assistant's page and its message box.
    var waitLimit: TimeInterval = 20
    var confirm: (_ kind: AssistantPayload.Kind, _ assistant: String, _ window: NSWindow?) async -> Answer = AssistantSender.askWithAlert
    var toast: (_ text: String, _ window: NSWindow?, _ duration: TimeInterval?) -> Void = { Toast.show($0, in: $1, duration: $2) }
    private(set) var isSending = false

    /// Sends from `source` to `assistant`, opening it with `open`. With `selectionOnly`, a page without a selection
    /// sends nothing (that is "Ask About This"); otherwise the whole page goes when nothing is selected.
    @discardableResult
    func send(from source: WebPane, to assistant: SidebarItem, selectionOnly: Bool, window: NSWindow?,
              open: (String) -> AssistantDestination?) async -> Outcome {
        guard !isSending else { return .cancelled }
        isSending = true
        defer { isSending = false }

        guard source.didCreateView, source.webView.url != nil else {
            toast("Open a page first", window, 2.5)
            return .noPage
        }
        let selected = await PageSelection.text(in: source.webView)
        let kind: AssistantPayload.Kind
        if !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .selection
        } else if selectionOnly {
            toast("Select some text first", window, 2.5)
            return .nothingSelected
        } else {
            kind = .page
        }

        if !trust.isTrusted(assistant.id) {
            let answer = await confirm(kind, assistant.name, window)
            guard answer.send else { return .cancelled }
            if answer.remember { trust.set(assistant.id, trusted: true) }
        }

        let payload: AssistantPayload
        switch kind {
        case .selection:
            payload = .selection(selected, title: source.webView.title ?? "", url: source.webView.url)
        case .page:
            toast("Capturing page\u{2026}", window, nil)
            do {
                payload = AssistantPayload(kind: .page, text: try await PageSnapshot.capture(source.webView, options: .init(forAssistant: true)))
            } catch {
                toast("Couldn\u{2019}t capture the page: \(error.localizedDescription)", window, 4)
                return .failed(error.localizedDescription)
            }
        }

        let what = kind == .page ? "the page (\(ByteCountFormatter.string(fromByteCount: Int64(payload.text.utf8.count), countStyle: .file)))" : "the selection"
        let target: WebPane
        switch open(assistant.id) {
        case nil:
            return copy(payload, assistant: assistant.name, reason: "it couldn\u{2019}t be opened", window: window)
        case .terminal(let terminal)?:
            terminal.view.window?.makeFirstResponder(terminal.view)
            switch terminal.paste(payload.text) {
            case .pasted:
                toast("Pasted \(what) into \(assistant.name). Check it, then press Return.", window, 4)
                return .inserted(kind)
            case .notRunning:
                return copy(payload, assistant: assistant.name, reason: "its session has ended (press Return there to start a new one)", window: window, toTerminal: true)
            case .unsafe:
                // Without bracketed paste every line break would act as Return and run the text as commands.
                return copy(payload, assistant: assistant.name, reason: "the program running in it doesn\u{2019}t accept a safe paste, so its lines could run as commands", window: window, toTerminal: true)
            }
        case .page(let pane)?:
            target = pane
        }
        toast("Opening \(assistant.name)\u{2026}", window, nil)
        let deadline = Date().addingTimeInterval(waitLimit)
        var ready = false
        while Date() < deadline {
            target.loadIfNeeded()
            if !target.webView.isLoading, await AssistantComposer.hasComposer(target.webView, hints: hints) {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard ready else {
            return copy(payload, assistant: assistant.name, reason: "Satellite couldn\u{2019}t find its message box (are you signed in?)", window: window)
        }

        target.webView.window?.makeFirstResponder(target.webView)
        let result = await AssistantComposer.insert(payload.text, into: target.webView, hints: hints)
        guard result.inserted else {
            return copy(payload, assistant: assistant.name, reason: result.reason ?? "its message box didn\u{2019}t accept the text", window: window)
        }
        toast("Added \(what) to \(assistant.name)\u{2019}s message box. Check it, then press Return to send.", window, 4)
        return .inserted(kind)
    }

    private func copy(_ payload: AssistantPayload, assistant: String, reason: String, window: NSWindow?, toTerminal: Bool = false) -> Outcome {
        pasteboard.clearContents()
        pasteboard.setString(payload.text, forType: .string)
        // Pasting it into that terminal by hand would hit the same problem, so a terminal gets no "press ⌘V" hint.
        let hint = toTerminal ? "It\u{2019}s on the clipboard." : "It\u{2019}s on the clipboard: click the message box and press \u{2318}V."
        toast("\(assistant): \(reason). \(hint)", window, 6)
        return .copied(reason: reason)
    }

    static func askWithAlert(kind: AssistantPayload.Kind, assistant: String, window: NSWindow?) async -> Answer {
        let alert = NSAlert()
        alert.messageText = kind == .page ? "Send this page to \(assistant)?" : "Send the selected text to \(assistant)?"
        var details = "Satellite puts it into \(assistant)\u{2019}s message box and doesn\u{2019}t send it: you press Return there. Pages can hold customer data, so only share with assistants approved for it."
        if kind == .page { details += "\n\nPage text: \(SnapshotTextMode.current.summary) (change this in Settings > General)." }
        alert.informativeText = details
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don\u{2019}t ask again for \(assistant)"
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        let send = response == .alertFirstButtonReturn
        return Answer(send: send, remember: send && alert.suppressionButton?.state == .on)
    }
}

// MARK: - The right-click menu

/// A web view that lets Satellite add to its right-click menu.
final class SatelliteWebView: WKWebView {
    weak var pane: WebPane?
    @MainActor static var menuExtender: ((SatelliteWebView, NSMenu) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        Self.menuExtender?(self, menu)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { handler() }
}

enum AssistantContextMenu {
    /// WebKit's Copy item, which it only shows when text is selected.
    static let copyIdentifier = "WKMenuItemIdentifierCopy"

    /// Puts "Ask <assistant> About This" (and the other assistants) at the top of a page's menu when text is selected.
    /// Pages of the assistants themselves don't get it.
    static func extend(_ menu: NSMenu, isAssistantPage: Bool, assistants: [SidebarItem], preferredID: String?, ask: @escaping (String) -> Void) {
        guard !isAssistantPage, menu.items.contains(where: { $0.identifier?.rawValue == copyIdentifier }),
              let primary = assistants.first(where: { $0.id == preferredID }) ?? assistants.first else { return }
        var entries: [NSMenuItem] = [ClosureMenuItem(title: "Ask \(primary.name) About This") { ask(primary.id) }]
        let others = assistants.filter { $0.id != primary.id }
        if !others.isEmpty {
            let submenu = NSMenu()
            for other in others { submenu.addItem(ClosureMenuItem(title: other.name) { ask(other.id) }) }
            let holder = NSMenuItem(title: "Ask Another Assistant", action: nil, keyEquivalent: "")
            holder.submenu = submenu
            entries.append(holder)
        }
        entries.append(.separator())
        for (index, entry) in entries.enumerated() { menu.insertItem(entry, at: index) }
    }
}
