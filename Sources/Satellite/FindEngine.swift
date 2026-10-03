import WebKit

/// The search behind the find bar. Every frame gets a small script (in a private content world, so pages can't see
/// it) that searches the text the way it is shown: whitespace collapsed, hidden elements left out, matches allowed to
/// run across inline tags like `Hello <b>wor</b>ld`, and open shadow roots searched in the order they are displayed.
/// It draws the matches as an overlay instead of changing the page, which single-page apps would fight.
enum FindEngine {
    static let world = WKContentWorld.world(name: "satellite.find")

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
    }

    static let script = #"""
    (function () {
      if (window.__satelliteFind) return;

      const MAX_MATCHES = 10000;
      const DRAWN_AROUND_CURRENT = 1500;
      const SKIP = new Set(['script', 'style', 'noscript', 'template', 'textarea', 'select', 'iframe', 'frame', 'object', 'embed', 'canvas', 'head']);
      const ALL = 'rgba(255, 213, 0, 0.38)';
      const CURRENT = 'rgba(255, 140, 0, 0.5)';

      let text = '';
      let pieces = [];
      let built = false;
      let builtAt = 0;
      let matches = [];
      let current = -1;
      let anchor = null;
      let last = null;
      let overlay = null;
      let scheduled = false;
      let listening = false;
      let styles = new Map();
      let shown = new Map();
      let blocks = new Map();

      const parentOf = node => node.parentElement || (node.parentNode && node.parentNode.host) || null;
      const isSpace = code => code === 32 || code === 9 || code === 10 || code === 12 || code === 13;

      // ---- what is on the page, as text ------------------------------------------------------------------------

      function style(element) {
        let s = styles.get(element);
        if (!s) {
          const computed = getComputedStyle(element);
          s = { display: computed.display, visibility: computed.visibility, whiteSpace: computed.whiteSpace };
          styles.set(element, s);
        }
        return s;
      }

      function isShown(element) {
        let result = shown.get(element);
        if (result === undefined) {
          const s = style(element);
          if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') result = false;
          else if (s.display === 'contents') { const up = parentOf(element); result = up ? isShown(up) : true; }
          else result = element.getClientRects().length > 0;
          shown.set(element, result);
        }
        return result;
      }

      function blockOf(element) {
        let block = blocks.get(element);
        if (block === undefined) {
          const display = style(element).display;
          if (display === 'inline' || display === 'contents' || display.startsWith('ruby')) {
            const up = parentOf(element);
            block = up ? blockOf(up) : document.documentElement;
          } else {
            block = element;
          }
          blocks.set(element, block);
        }
        return block;
      }

      // Builds `text` (what a reader sees, with a line break between blocks) and `pieces`, which say where each part
      // of it came from, so a match can be turned back into ranges of real text nodes.
      function build() {
        styles = new Map(); shown = new Map(); blocks = new Map();
        const parts = [];
        pieces = [];
        let length = 0;
        let block = null;
        let spaceBefore = true;
        const push = string => { parts.push(string); length += string.length; };

        const lineBreak = () => {
          block = null;
          if (length === 0 || parts[parts.length - 1] === '\n') { spaceBefore = true; return; }
          const lastPiece = pieces[pieces.length - 1];
          if (lastPiece && lastPiece.collapsed) { parts.pop(); pieces.pop(); length -= 1; }
          pieces.push({ out: length, node: null, orig: 0, len: 1, origLen: 0 });
          push('\n');
          spaceBefore = true;
        };

        const addText = node => {
          const data = node.data;
          if (!data) return;
          const parent = parentOf(node);
          if (!parent || !isShown(parent)) return;
          const b = blockOf(parent);
          if (block !== null && b !== block) lineBreak();
          block = b;

          if (/^(pre|pre-wrap|break-spaces)$/.test(style(parent).whiteSpace)) {
            const chunk = data.replace(/\u00a0/g, ' ');
            pieces.push({ out: length, node, orig: 0, len: chunk.length, origLen: chunk.length });
            push(chunk);
            spaceBefore = /\s$/.test(chunk);
            return;
          }
          let i = 0;
          const n = data.length;
          while (i < n) {
            const space = isSpace(data.charCodeAt(i));
            let j = i + 1;
            while (j < n && isSpace(data.charCodeAt(j)) === space) j++;
            if (space) {
              if (!spaceBefore) {
                pieces.push({ out: length, node, orig: i, len: 1, origLen: j - i, collapsed: true });
                push(' ');
                spaceBefore = true;
              }
            } else {
              const chunk = data.slice(i, j).replace(/\u00a0/g, ' ');
              pieces.push({ out: length, node, orig: i, len: chunk.length, origLen: chunk.length });
              push(chunk);
              spaceBefore = false;
            }
            i = j;
          }
        };

        const visit = parent => { for (let child = parent.firstChild; child; child = child.nextSibling) handle(child); };
        const handle = node => {
          if (node.nodeType === 3) return addText(node);
          if (node.nodeType !== 1) return;
          const tag = node.localName;
          if (SKIP.has(tag)) return;
          if (tag === 'br') return lineBreak();
          if (tag === 'slot') {
            const assigned = node.assignedNodes({ flatten: true });
            if (assigned.length) assigned.forEach(handle); else visit(node);
            return;
          }
          if (node.shadowRoot) return visit(node.shadowRoot);
          visit(node);
        };
        visit(document.body || document.documentElement);

        text = parts.join('');
        built = true;
        builtAt = Date.now();
      }

      function pieceAt(offset) {
        let lo = 0, hi = pieces.length - 1;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (pieces[mid].out <= offset) lo = mid; else hi = mid - 1;
        }
        return lo;
      }

      // The real text a match covers: one range per text node (a range can't cross from one tree into another).
      function rangesOf(match) {
        if (match.ranges) return match.ranges;
        const spans = [];
        for (let k = pieceAt(match.s); k < pieces.length && pieces[k].out < match.e; k++) {
          const p = pieces[k];
          if (!p.node) continue;
          const from = Math.max(match.s, p.out), to = Math.min(match.e, p.out + p.len);
          if (from >= to) continue;
          const start = p.collapsed ? p.orig : p.orig + (from - p.out);
          const end = p.collapsed ? p.orig + p.origLen : p.orig + (to - p.out);
          const previous = spans[spans.length - 1];
          if (previous && previous.node === p.node) previous.end = end; else spans.push({ node: p.node, start, end });
        }
        match.ranges = spans.map(({ node, start, end }) => {
          const range = document.createRange();
          try { range.setStart(node, start); range.setEnd(node, end); } catch (error) {}
          return range;
        });
        return match.ranges;
      }

      // ---- searching ------------------------------------------------------------------------------------------

      function compile(query, options) {
        let source = options.regex
          ? query
          : query.replace(/[.*+?^${}()|[\]\\\/]/g, '\\$&').replace(/\s+/g, '\\s+');
        let flags = 'gm' + (options.caseSensitive ? '' : 'i');
        if (options.wholeWord) {
          source = '(?<![\\p{L}\\p{N}_])(?:' + source + ')(?![\\p{L}\\p{N}_])';
          flags += 'u';
          return new RegExp(source, flags);
        }
        // \p{...} and \u{...} only mean something in unicode mode, where they are the only reading; without it they
        // would quietly match the literal text.
        if (options.regex && /\\[pPu]\{/.test(source)) flags += 'u';
        return new RegExp(source, flags);
      }

      function firstInView() {
        const limit = Math.min(matches.length, 2000);
        for (let i = 0; i < limit; i++) {
          const range = rangesOf(matches[i])[0];
          const rect = range && range.getBoundingClientRect();
          if (rect && (rect.width > 0 || rect.height > 0) && rect.top >= 0 && rect.top < innerHeight) return i;
        }
        return 0;
      }

      function search(query, options) {
        last = { query, options };
        let regex;
        try {
          regex = compile(query, options);
        } catch (error) {
          matches = []; current = -1; render();
          return { total: 0, error: String(error.message || error).replace(/^Invalid regular expression:\s*/, '') };
        }
        if (!built || Date.now() - builtAt > 2000) build();

        const found = [];
        let truncated = false;
        regex.lastIndex = 0;
        let m;
        while ((m = regex.exec(text)) !== null) {
          if (m[0].length === 0) { regex.lastIndex++; continue; }
          if (/^\n+$/.test(m[0])) continue;
          found.push({ s: m.index, e: m.index + m[0].length });
          if (found.length >= MAX_MATCHES) { truncated = true; break; }
        }
        matches = found;
        current = -1;

        let candidate = -1;
        if (found.length) {
          if (anchor !== null) { candidate = found.findIndex(x => x.s >= anchor); if (candidate < 0) candidate = 0; }
          else candidate = firstInView();
        }
        render();
        return { total: found.length, truncated, candidate };
      }

      // ---- drawing --------------------------------------------------------------------------------------------

      function ensureOverlay() {
        if (overlay && overlay.isConnected) return overlay;
        overlay = document.createElement('div');
        overlay.setAttribute('data-satellite-find', '');
        const s = overlay.style;
        s.position = 'fixed'; s.left = '0'; s.top = '0'; s.width = '100vw'; s.height = '100vh';
        s.pointerEvents = 'none'; s.zIndex = '2147483647'; s.margin = '0'; s.padding = '0'; s.border = '0';
        document.documentElement.appendChild(overlay);
        return overlay;
      }

      function listen(on) {
        if (on === listening) return;
        listening = on;
        const method = on ? 'addEventListener' : 'removeEventListener';
        window[method]('scroll', schedule, true);
        window[method]('resize', schedule);
      }

      function schedule() {
        if (scheduled) return;
        scheduled = true;
        requestAnimationFrame(() => { scheduled = false; render(); });
      }

      function clipOf(element, boxes, clips) {
        const known = clips.get(element);
        if (known) return known;
        let left = 0, top = 0, right = innerWidth, bottom = innerHeight;
        for (let cur = element; cur; cur = parentOf(cur)) {
          if (cur === document.documentElement || cur === document.body) continue;
          let box = boxes.get(cur);
          if (box === undefined) {
            const computed = getComputedStyle(cur);
            box = (computed.overflowX !== 'visible' || computed.overflowY !== 'visible') ? cur.getBoundingClientRect() : null;
            boxes.set(cur, box);
          }
          if (box) { left = Math.max(left, box.left); top = Math.max(top, box.top); right = Math.min(right, box.right); bottom = Math.min(bottom, box.bottom); }
        }
        const clip = { left, top, right, bottom };
        clips.set(element, clip);
        return clip;
      }

      function render() {
        scheduled = false;
        if (!matches.length) {
          if (overlay) overlay.replaceChildren();
          listen(false);
          return;
        }
        const container = ensureOverlay();
        listen(true);
        const fragment = document.createDocumentFragment();
        const boxes = new Map(), clips = new Map();
        const from = Math.max(0, Math.min(current < 0 ? 0 : current - DRAWN_AROUND_CURRENT, matches.length - 2 * DRAWN_AROUND_CURRENT));
        const to = Math.min(matches.length, from + 2 * DRAWN_AROUND_CURRENT);
        for (let i = Math.max(0, from); i < to; i++) {
          const isCurrent = i === current;
          for (const range of rangesOf(matches[i])) {
            if (!range.startContainer.isConnected) continue;
            const clip = clipOf(parentOf(range.startContainer), boxes, clips);
            for (const rect of range.getClientRects()) {
              const left = Math.max(rect.left, clip.left), top = Math.max(rect.top, clip.top);
              const right = Math.min(rect.right, clip.right), bottom = Math.min(rect.bottom, clip.bottom);
              if (right - left <= 0 || bottom - top <= 0) continue;
              const box = document.createElement('div');
              const s = box.style;
              s.position = 'absolute'; s.left = left + 'px'; s.top = top + 'px'; s.width = (right - left) + 'px'; s.height = (bottom - top) + 'px';
              s.background = isCurrent ? CURRENT : ALL; s.borderRadius = '2px';
              if (isCurrent) { s.outline = '2px solid rgba(255, 90, 0, 0.95)'; s.outlineOffset = '0'; }
              fragment.appendChild(box);
            }
          }
        }
        container.replaceChildren(fragment);
      }

      // Scrolls every scroll container around the match, the page last, until the match is in view.
      function scrollToRange(range) {
        for (let cur = parentOf(range.startContainer); cur; cur = parentOf(cur)) {
          const isPage = cur === document.documentElement;
          if (!isPage) {
            const computed = getComputedStyle(cur);
            const scrolls = /(auto|scroll|overlay)/.test(computed.overflowY + computed.overflowX);
            if (!scrolls || (cur.scrollHeight <= cur.clientHeight && cur.scrollWidth <= cur.clientWidth)) continue;
          }
          const rect = range.getBoundingClientRect();
          if (rect.width === 0 && rect.height === 0) return;
          const view = isPage ? { top: 0, bottom: innerHeight, left: 0, right: innerWidth } : cur.getBoundingClientRect();
          const scroller = isPage ? (document.scrollingElement || document.documentElement) : cur;
          let dy = 0, dx = 0;
          if (rect.top < view.top + 40 || rect.bottom > view.bottom - 24) dy = (rect.top + rect.bottom) / 2 - (view.top + view.bottom) / 2;
          if (rect.left < view.left || rect.right > view.right) dx = (rect.left + rect.right) / 2 - (view.left + view.right) / 2;
          if (dx || dy) scroller.scrollTo({ top: scroller.scrollTop + dy, left: scroller.scrollLeft + dx, behavior: 'instant' });
          if (isPage) break;
        }
      }

      // ---- the calls the app makes ----------------------------------------------------------------------------

      // A match is stale when its text was removed (the range then collapses onto the parent) or changed.
      function stale(match) {
        const ranges = rangesOf(match);
        if (!ranges.length) return true;
        let actual = '';
        for (const range of ranges) {
          if (range.collapsed || !range.startContainer.isConnected) return true;
          actual += range.toString();
        }
        const squash = string => string.replace(/[\s\u00a0]+/g, '');
        return squash(actual) !== squash(text.slice(match.s, match.e));
      }

      function goto(index, refreshed) {
        if (index < 0 || index >= matches.length) { current = -1; render(); return { total: matches.length, index: -1 }; }
        if (!refreshed && stale(matches[index])) {
          // The page changed under us: look again and keep the same position in the list.
          built = false;
          const again = last ? search(last.query, last.options) : { total: 0 };
          if (again.error || !matches.length) return { total: matches.length, index: -1 };
          return goto(Math.min(index, matches.length - 1), true);
        }
        current = index;
        anchor = matches[index].s;
        const range = rangesOf(matches[index])[0];
        if (range) scrollToRange(range);
        render();
        return { total: matches.length, index: current };
      }

      function texts() { return matches.map(m => text.slice(m.s, m.e)); }

      function selectCurrent() {
        if (current < 0) return false;
        const ranges = rangesOf(matches[current]);
        if (!ranges.length) return false;
        try {
          const selection = getSelection();
          const range = ranges[0].cloneRange();
          if (ranges.length > 1) { try { range.setEnd(ranges[ranges.length - 1].endContainer, ranges[ranges.length - 1].endOffset); } catch (error) {} }
          selection.removeAllRanges();
          selection.addRange(range);
          return true;
        } catch (error) { return false; }
      }

      function frameElements(root, found) {
        for (const element of root.querySelectorAll('*')) {
          if (element.localName === 'iframe' || element.localName === 'frame') found.push(element);
          if (element.shadowRoot) frameElements(element.shadowRoot, found);
        }
        return found;
      }

      // Brings the child frame at `index` into view, so a match inside it can be seen.
      function revealFrame(index) {
        const target = window.frames[index];
        const element = frameElements(document, []).find(e => e.contentWindow === target);
        if (!element) return false;
        element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        schedule();
        return true;
      }

      function clear() {
        matches = []; current = -1; anchor = null; last = null;
        text = ''; pieces = []; built = false;
        styles = new Map(); shown = new Map(); blocks = new Map();
        listen(false);
        if (overlay) { overlay.remove(); overlay = null; }
        return true;
      }

      Object.defineProperty(window, '__satelliteFind', {
        value: Object.freeze({
          search: (query, options) => search(String(query), options || {}),
          goto: index => goto(index, false),
          texts, select: selectCurrent, revealFrame, clear,
        }),
      });
    })();
    """#
}

// MARK: - Searching a whole page

/// Searches a page and its frames with the engine, and keeps track of which match is the current one. A page is
/// several documents (the main one and its iframes), each with its own engine, so counts are added up and stepping
/// moves on to the next frame when a frame runs out of matches.
@MainActor
final class PageFinder {
    enum Outcome: Equatable {
        case cleared
        case none
        case matches(index: Int, total: Int, truncated: Bool)
        case invalid(String)
        case unavailable
    }

    private struct Target {
        let frame: WKFrameInfo?
        let path: [Int]
    }

    private weak var webView: WKWebView?
    private var targets: [Target] = []
    private var counts: [Int] = []
    private var truncated = false
    private var currentTarget: Int?
    private var currentLocal = -1

    init(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: Operations

    func search(_ query: String, options: FindOptions) async -> Outcome {
        guard webView != nil, !query.isEmpty else { return await clear() }
        let previousPath = currentTarget.map { targets[$0].path }
        refreshTargets()

        var newCounts: [Int] = []
        var candidates: [Int] = []
        truncated = false
        for (position, target) in targets.enumerated() {
            guard let result = await call("search", [query, options.json], in: target) as? [String: Any] else {
                if position == 0 { return .unavailable }   // the main page can't be searched (a PDF, say)
                newCounts.append(0)
                candidates.append(-1)
                continue
            }
            if let message = result["error"] as? String {
                _ = await clear()
                return .invalid(message)
            }
            newCounts.append((result["total"] as? NSNumber)?.intValue ?? 0)
            candidates.append((result["candidate"] as? NSNumber)?.intValue ?? -1)
            if result["truncated"] as? Bool == true { truncated = true }
        }
        counts = newCounts
        currentTarget = nil
        currentLocal = -1
        guard counts.contains(where: { $0 > 0 }) else { return .none }

        // Stay in the frame that had the current match while typing, otherwise start with the first frame that has one.
        let keep = previousPath.flatMap { path in targets.firstIndex { $0.path == path } }.flatMap { counts[$0] > 0 ? $0 : nil }
        let chosen = keep ?? counts.firstIndex { $0 > 0 }!
        return await go(to: chosen, local: max(candidates[chosen], 0))
    }

    func step(forward: Bool) async -> Outcome {
        guard let from = currentTarget, counts.indices.contains(from) else { return .none }
        var target = from
        var local = currentLocal + (forward ? 1 : -1)
        if local < 0 || local >= counts[from] {
            let withMatches = counts.indices.filter { counts[$0] > 0 }
            guard let position = withMatches.firstIndex(of: from) else { return .none }
            let neighbour = withMatches[(position + (forward ? 1 : withMatches.count - 1)) % withMatches.count]
            target = neighbour
            local = forward ? 0 : counts[neighbour] - 1
        }
        return await go(to: target, local: local)
    }

    /// Puts the current match where the engine of `target` says it is, and brings it into view.
    private func go(to target: Int, local: Int) async -> Outcome {
        if let old = currentTarget, old != target { _ = await call("goto", [-1], in: targets[old]) }
        guard let result = await call("goto", [local], in: targets[target]) as? [String: Any] else { return .none }
        counts[target] = (result["total"] as? NSNumber)?.intValue ?? counts[target]
        let index = (result["index"] as? NSNumber)?.intValue ?? -1
        guard index >= 0 else {
            currentTarget = nil
            currentLocal = -1
            return .none
        }
        currentTarget = target
        currentLocal = index
        await reveal(targets[target].path)
        let before = counts[..<target].reduce(0, +)
        return .matches(index: before + index + 1, total: counts.reduce(0, +), truncated: truncated)
    }

    /// Scrolls each frame on the way down to `path` so the frame holding the match is visible.
    private func reveal(_ path: [Int]) async {
        for depth in 0..<path.count {
            let ancestor = Array(path.prefix(depth))
            guard let target = targets.first(where: { $0.path == ancestor }) else { continue }
            _ = await call("revealFrame", [path[depth]], in: target)
        }
    }

    /// Selects the current match on the page (so it can be copied) without clearing anything.
    func selectCurrent() async {
        guard let current = currentTarget else { return }
        _ = await call("select", [], in: targets[current])
    }

    func allMatches() async -> [String] {
        var result: [String] = []
        for target in targets {
            result += (await call("texts", [], in: target) as? [String]) ?? []
        }
        return result
    }

    func clear() async -> Outcome {
        for target in targets { _ = await call("clear", [], in: target) }
        targets = []
        counts = []
        currentTarget = nil
        currentLocal = -1
        truncated = false
        return .cleared
    }

    // MARK: Plumbing

    private func refreshTargets() {
        guard let webView else { return }
        targets = [Target(frame: nil, path: [])]
            + FrameRegistry.shared.frames(of: webView).filter { !$0.path.isEmpty }.map { Target(frame: $0.info, path: $0.path) }
    }

    private func call(_ function: String, _ arguments: [Any], in target: Target) async -> Any? {
        guard let webView else { return nil }
        let body = "return window.__satelliteFind ? window.__satelliteFind.\(function)(...args) : null"
        do {
            return try await webView.callAsyncJavaScript(body, arguments: ["args": arguments], in: target.frame, contentWorld: FindEngine.world)
        } catch {
            if !target.path.isEmpty { FrameRegistry.shared.forget(webView, path: target.path) }   // the frame went away
            return nil
        }
    }
}
