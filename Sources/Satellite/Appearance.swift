import AppKit

/// Satellite's light or dark appearance: the system's, or always light, or always dark. It covers the whole app, and
/// web pages see it as `prefers-color-scheme`, so sites with a dark mode of their own follow it (live, no reload).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor static func apply(_ choice: AppAppearance = current) {
        NSApp.appearance = choice.nsAppearance
    }
}

/// `satellite.appearance`, which tells an extension whether things are light or dark. Computed in the page, so it
/// needs no permission and no round trip to the app:
///
/// - `app`: Satellite's appearance, which is what the page sees as `prefers-color-scheme`.
/// - `page`: how the page itself looks, which can differ. claude.ai and Slack have their own theme setting, and a
///   site without a dark mode (Salesforce) stays light in a dark Satellite. UI drawn inside a page should follow this.
/// - `onChange(callback)`: called with `{ app, page }` when either changes.
enum ExtensionAppearance {
    /// A JavaScript expression that makes the frozen `satellite.appearance` object. `tag` (a JSON string) names the
    /// extension in errors its callbacks throw.
    static func script(tag: String) -> String {
        #"""
        (() => {
            const callbacks = [];
            const darkQuery = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
            const app = () => (darkQuery && darkQuery.matches) ? 'dark' : 'light';
            // How light a CSS color is (0 black ... 1 white), or null when it is (nearly) see-through.
            const lightness = color => {
              const match = /rgba?\(([^)]+)\)/.exec(color || '');
              if (!match) return null;
              const [r, g, b, a = 1] = match[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
              if (!(a >= 0.5)) return null;
              return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
            };
            // The first opaque background of body or html decides. Without one the page shows the canvas, which is dark
            // only when the page allows a dark scheme and that scheme is in use.
            const page = () => {
              const root = document.documentElement;
              if (!root) return app();
              for (const element of [document.body, root]) {
                if (!element) continue;
                const value = lightness(getComputedStyle(element).backgroundColor);
                if (value !== null) return value < 0.5 ? 'dark' : 'light';
              }
              // A page picks its scheme with the color-scheme property or, without it showing in computed style, a meta tag.
              const property = getComputedStyle(root).colorScheme || '';
              const meta = document.querySelector('meta[name="color-scheme"]');
              const scheme = property && property !== 'normal' ? property : ((meta && meta.content) || '');
              if (/\bdark\b/.test(scheme)) return /\blight\b/.test(scheme) ? app() : 'dark';
              return 'light';
            };
            let last = null;
            const check = () => {
              const now = { app: app(), page: page() };
              if (last && now.app === last.app && now.page === last.page) return;
              last = now;
              for (const callback of callbacks) {
                try { callback({ app: now.app, page: now.page }); } catch (error) { console.error('[satellite:' + \#(tag) + ']', error); }
              }
            };
            let watching = false;
            const watch = () => {
              if (watching) return;
              watching = true;
              last = { app: app(), page: page() };
              if (darkQuery) darkQuery.addEventListener('change', check);
              // Sites switch themes with a class or attribute on html or body; a stylesheet arriving late changes colors
              // without either, which the slow check catches.
              const observer = new MutationObserver(check);
              const observe = () => {
                if (document.documentElement) observer.observe(document.documentElement, { attributes: true });
                if (document.body) observer.observe(document.body, { attributes: true });
              };
              observe();
              document.addEventListener('DOMContentLoaded', () => { observe(); check(); }, { once: true });
              window.addEventListener('load', check, { once: true });
              setInterval(check, 2000);
            };
            return Object.freeze({
              get app() { return app(); },
              get page() { return page(); },
              onChange: callback => { if (typeof callback === 'function') { callbacks.push(callback); watch(); } },
            });
          })()
        """#
    }
}
