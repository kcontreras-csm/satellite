import AppKit
import Foundation

enum ExtensionTemplate: String, CaseIterable, Identifiable {
    case page
    case sidebar
    case style

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: return "Change a page"
        case .sidebar: return "Add a sidebar link"
        case .style: return "Restyle a page"
        }
    }

    var detail: String {
        switch self {
        case .page: return "A script that runs on pages you pick, with the satellite API. Good for adding buttons, reading values or automating clicks."
        case .sidebar: return "A background script that adds a link to the sidebar, with settings for its name and address."
        case .style: return "Only CSS, applied to pages you pick."
        }
    }

    var needsPages: Bool { self != .sidebar }
}

struct NewExtension {
    var name: String
    var id: String
    var summary: String
    var template: ExtensionTemplate
    /// A match pattern such as `*://example.com/*` (page and style templates).
    var pages: String
}

enum ExtensionScaffold {
    /// `My Cool Extension!` -> `my-cool-extension`
    static func slug(_ name: String) -> String {
        var result = ""
        for scalar in name.lowercased().unicodeScalars {
            let character = Character(scalar)
            if character.isASCII, character.isLetter || character.isNumber { result.append(character) }
            else if !result.hasSuffix("-") { result.append("-") }
        }
        return String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Writes a ready-to-edit extension into `parent/<id>` and returns its folder. The result is checked with the
    /// same validator Satellite uses, so what gets created always loads.
    static func create(_ spec: NewExtension, in parent: URL) throws -> URL {
        let fm = FileManager.default
        guard ExtensionManifest.isValidID(spec.id) else {
            throw ManifestError("The id must use lowercase letters, digits, \u{201C}.\u{201D}, \u{201C}-\u{201D} or \u{201C}_\u{201D}, and start with a letter or digit.")
        }
        let name = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ManifestError("Give the extension a name.") }
        var pattern = spec.pages.trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.template.needsPages {
            if pattern.isEmpty { pattern = "*://example.com/*" }
            _ = try MatchPattern.regexSource(pattern)
        }
        let folder = parent.appendingPathComponent(spec.id, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw ManifestError("There is already a folder named \u{201C}\(spec.id)\u{201D} there.") }

        let summary = spec.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = summary.isEmpty ? "Describe what \(name) does." : summary
        let author = NSFullUserName().isEmpty ? "Me" : NSFullUserName()

        var files: [String: String] = [
            "README.md": readme(name: name, id: spec.id, template: spec.template),
            "jsconfig.json": jsconfig,
            ".gitignore": ".DS_Store\n",
            ".satellite/satellite.d.ts": typings,
            ".satellite/manifest.schema.json": schema,
        ]
        switch spec.template {
        case .page:
            files["manifest.json"] = manifest(name: name, author: author, description: description, body: """
              "matches": [\(quoted(pattern))],
              "js": ["content.js"],
              "run_at": "document_idle",
              "world": "isolated",
              "permissions": ["storage"]
            """)
            files["content.js"] = contentScript(name: name, id: spec.id)
        case .sidebar:
            files["manifest.json"] = manifest(name: name, author: author, description: description, body: """
              "permissions": ["ui"],
              "background": "background.js",
              "settings": [
                { "key": "title", "type": "string", "title": "Label", "default": \(quoted(name)) },
                { "key": "url", "type": "string", "title": "Address", "description": "Must start with https://", "default": "https://example.com/" }
              ]
            """)
            files["background.js"] = backgroundScript(id: spec.id)
        case .style:
            files["manifest.json"] = manifest(name: name, author: author, description: description, body: """
              "matches": [\(quoted(pattern))],
              "css": ["style.css"],
              "run_at": "document_start"
            """)
            files["style.css"] = "/* \(name): applied to pages matching \(pattern). Saving this file reloads them. */\n\nbody {\n  /* outline: 1px dashed red; */\n}\n"
        }

        do {
            for (path, text) in files {
                let url = folder.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try ExtensionManifest.parse(try Data(contentsOf: folder.appendingPathComponent("manifest.json")), folderName: spec.id)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// `*://*.force.com/*` for a page address.
    static func pattern(for url: URL) -> String? {
        guard let host = url.host, url.scheme == "https" || url.scheme == "http" else { return nil }
        return "*://\(host)/*"
    }

    // MARK: Files

    private static func quoted(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func manifest(name: String, author: String, description: String, body: String) -> String {
        """
        {
          "$schema": ".satellite/manifest.schema.json",
          "name": \(quoted(name)),
          "version": "0.1.0",
          "author": \(quoted(author)),
          "description": \(quoted(description)),
        \(body)
        }

        """
    }

    private static func contentScript(name: String, id: String) -> String {
        """
        // \(name)
        // Runs on the pages listed under "matches" in manifest.json. Saving this file reloads the extension and
        // those pages. Errors and console output appear in Settings > Extensions > Logs.
        // The `satellite` API (storage, settings, ui, ...) is described in .satellite/satellite.d.ts.

        console.log('[\(id)] loaded on', location.href);

        // These apps re-render constantly, so wait for what you need instead of assuming it exists.
        function waitFor(selector, { root = document, timeout = 10000 } = {}) {
          return new Promise((resolve, reject) => {
            const found = root.querySelector(selector);
            if (found) return resolve(found);
            const timer = setTimeout(() => { observer.disconnect(); reject(new Error('Timed out waiting for ' + selector)); }, timeout);
            const observer = new MutationObserver(() => {
              const element = root.querySelector(selector);
              if (!element) return;
              clearTimeout(timer);
              observer.disconnect();
              resolve(element);
            });
            observer.observe(root === document ? document.documentElement : root, { childList: true, subtree: true });
          });
        }

        // Example: a small badge that counts your visits. Replace it with your own idea.
        if (window.top === window) {
          const visits = ((await satellite.storage.get('visits')) || 0) + 1;
          await satellite.storage.set('visits', visits);

          const badge = document.createElement('div');
          badge.textContent = '\(name) \\u00B7 visit ' + visits;
          badge.style.cssText =
            'position:fixed;left:8px;bottom:8px;z-index:2147483647;padding:4px 8px;border-radius:6px;' +
            'background:#4a4bdb;color:#fff;font:12px -apple-system,sans-serif;opacity:.9';
          document.body.appendChild(badge);
        }

        """
    }

    private static func backgroundScript(id: String) -> String {
        """
        // Runs once when Satellite starts (and again whenever you save this file or change a setting), with no page
        // open. "permissions": ["ui"] in manifest.json allows the sidebar calls below.
        // Errors and console output appear in Settings > Extensions > Logs.

        async function apply() {
          const { title, url } = await satellite.settings.getAll();
          try {
            // Adding the same id again replaces the item, so this is safe to repeat.
            await satellite.ui.apps.add({ id: 'link', name: title, url, symbol: 'link' });
            console.log('[\(id)] sidebar link now points to', url);
          } catch (error) {
            console.error('Could not add the sidebar link:', error.message);
          }
        }

        satellite.settings.onChange(apply);
        await apply();

        """
    }

    private static func readme(name: String, id: String, template: ExtensionTemplate) -> String {
        """
        # \(name)

        A Satellite extension (`\(id)`).

        - **Edit and save.** Satellite reloads the extension and the pages it runs on every time you save a file
          (switch this off under Settings > Extensions).
        - **See what happens.** `console.log` output and errors show up under Settings > Extensions > Logs.
          For deeper debugging, Safari > Develop > (your Mac) > Satellite opens the web inspector.
        - **Autocomplete.** `.satellite/` holds type definitions for the `satellite` API and a schema for
          `manifest.json`; VS Code uses them automatically.
        - **Share it.** Copy this folder into the store repository and push; its GitHub Action lists it. Delete the
          `.satellite` folder first if you like (it is only for your editor).

        Reference: `satellite.storage`, `satellite.settings`, `satellite.ui`, `satellite.notify`, `satellite.openExternal`.

        """
    }

    private static let jsconfig = """
    {
      "compilerOptions": { "target": "ES2022", "module": "ES2022", "lib": ["ES2022", "DOM", "DOM.Iterable"], "checkJs": false },
      "include": ["*.js", ".satellite/*.d.ts"]
    }

    """

    private static let typings = """
    // Types for the `satellite` API available to Satellite extensions (isolated world).
    // Generated by Satellite; VS Code picks this file up through jsconfig.json.

    interface SatelliteSidebarItem {
      id: string; name: string; url: string; symbol: string; badge: string | null;
      hidden: boolean; builtin: boolean; owner: string | null; readOnly: boolean;
    }
    interface SatelliteSidebarInput {
      id: string; name: string; url: string; symbol?: string; badge?: string | number | null; index?: number; hidden?: boolean;
    }
    interface SatelliteSidebarPatch {
      name?: string; url?: string; symbol?: string; badge?: string | number | null; hidden?: boolean;
    }
    /** The left rail (`ui.apps`) or the right panel (`ui.assistants`). Needs the "ui" permission. */
    interface SatelliteSidebarList {
      list(): Promise<SatelliteSidebarItem[]>;
      add(item: SatelliteSidebarInput): Promise<void>;
      update(id: string, patch: SatelliteSidebarPatch): Promise<void>;
      remove(id: string): Promise<void>;
      select(id: string): Promise<void>;
    }

    type SatelliteSettingValue = string | number | boolean;
    interface SatelliteSettingDefinition {
      key: string; type: 'string' | 'number' | 'boolean' | 'choice'; title: string; description?: string;
      default?: SatelliteSettingValue; placeholder?: string; options?: { value: string; label: string }[];
      min?: number; max?: number;
    }

    interface Satellite {
      readonly extensionId: string;
      /** Needs the "storage" permission. */
      storage: {
        get(key: string): Promise<any>;
        set(key: string, value: any): Promise<void>;
        remove(key: string): Promise<void>;
      };
      /** Needs the "notifications" permission (installed app only). */
      notify(title: string, body?: string): Promise<void>;
      /** Needs the "open-external" permission. http(s) only. */
      openExternal(url: string): Promise<void>;
      ui: { apps: SatelliteSidebarList; assistants: SatelliteSidebarList };
      /** Options declared in manifest.json under "settings" (or registered at runtime). No permission needed. */
      settings: {
        get(key: string): Promise<SatelliteSettingValue>;
        getAll(): Promise<Record<string, SatelliteSettingValue>>;
        set(key: string, value: SatelliteSettingValue): Promise<void>;
        register(definitions: SatelliteSettingDefinition | SatelliteSettingDefinition[]): Promise<void>;
        onChange(callback: (key: string, value: SatelliteSettingValue) => void): void;
      };
    }

    declare const satellite: Satellite;
    /** Loads a library extension you listed under "dependencies". */
    declare function require(id: string): any;
    declare const module: { exports: any };
    declare const exports: any;

    """

    private static let schema = #"""
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Satellite extension manifest",
      "type": "object",
      "required": ["name", "version", "author", "description"],
      "properties": {
        "$schema": { "type": "string" },
        "id": { "type": "string", "pattern": "^[a-z0-9][a-z0-9._-]{0,63}$", "description": "Optional. Must equal the folder name." },
        "name": { "type": "string", "minLength": 1, "description": "Shown in Settings and the store." },
        "version": { "type": "string", "pattern": "^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(-[0-9A-Za-z.-]+)?$", "description": "major.minor.patch. Raise it to publish an update." },
        "author": {
          "description": "A name, or an object with name, email and url.",
          "oneOf": [
            { "type": "string", "minLength": 1 },
            { "type": "object", "required": ["name"], "properties": { "name": { "type": "string" }, "email": { "type": "string" }, "url": { "type": "string" } } }
          ]
        },
        "description": { "type": "string", "minLength": 1 },
        "icon": { "type": "string", "description": "A .png, .jpg or .svg file in this folder, or symbol:<SF Symbol name>." },
        "homepage": { "type": "string" },
        "license": { "type": "string" },
        "category": { "type": "string" },
        "keywords": { "type": "array", "items": { "type": "string" } },
        "type": { "enum": ["content-script", "library"], "description": "A library has no matches; other extensions load it with require()." },
        "dependencies": { "type": "object", "additionalProperties": { "type": "string" }, "description": "Library ids and version ranges, e.g. { \"shared-utils\": \"^1.0.0\" }." },
        "min_app_version": { "type": "string" },
        "permissions": {
          "type": "array", "uniqueItems": true,
          "items": { "enum": ["storage", "notifications", "open-external", "ui"] },
          "description": "What the satellite API may do. storage, notifications, open-external, ui (change the sidebar)."
        },
        "matches": { "type": "array", "items": { "type": "string" }, "description": "Chrome match patterns, e.g. *://*.example.com/*" },
        "exclude_matches": { "type": "array", "items": { "type": "string" } },
        "js": { "type": "array", "items": { "type": "string" }, "description": "Scripts to run on matching pages." },
        "css": { "type": "array", "items": { "type": "string" }, "description": "Stylesheets to add to matching pages." },
        "run_at": { "enum": ["document_start", "document_end", "document_idle"] },
        "all_frames": { "type": "boolean" },
        "world": { "enum": ["isolated", "main"], "description": "isolated: DOM + the satellite API. main: the page's own JavaScript, no API." },
        "background": { "type": "string", "description": "A script that runs once at startup with no page open (world must be isolated)." },
        "settings": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["key", "type", "title"],
            "properties": {
              "key": { "type": "string", "pattern": "^[A-Za-z][A-Za-z0-9_.-]{0,39}$" },
              "type": { "enum": ["string", "number", "boolean", "choice"] },
              "title": { "type": "string" },
              "description": { "type": "string" },
              "default": {},
              "placeholder": { "type": "string" },
              "options": { "type": "array", "items": { "type": "object", "required": ["value", "label"], "properties": { "value": { "type": "string" }, "label": { "type": "string" } } } },
              "min": { "type": "number" },
              "max": { "type": "number" }
            }
          }
        }
      }
    }

    """#
}

// MARK: - Editors

/// Opens an extension's folder in a code editor.
enum CodeEditor {
    struct Editor: Identifiable, Hashable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    static let defaultsKey = "codeEditorBundleID"

    static let known = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "VSCodium", bundleID: "com.vscodium"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        Editor(name: "Nova", bundleID: "com.panic.Nova"),
    ]

    static var installed: [Editor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The editor chosen in Settings, else the first one found.
    static var preferred: Editor? {
        let chosen = UserDefaults.standard.string(forKey: defaultsKey)
        return installed.first { $0.bundleID == chosen } ?? installed.first
    }

    /// Opens `folder` in the preferred editor, or shows it in Finder if there is none. Returns the editor used.
    @discardableResult
    static func open(_ folder: URL) -> String? {
        if let editor = preferred, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return editor.name
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        return nil
    }
}
