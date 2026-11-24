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
            "AGENTS.md": agents(name: name, id: spec.id),
            "CLAUDE.md": "@AGENTS.md\n",
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
        - **Coding agents.** `AGENTS.md` describes the manifest, the whole `satellite` API and the rules for this
          extension; `CLAUDE.md` points Claude Code at it.
        - **Share it.** Copy this folder into the store repository and push; its GitHub Action lists it. Delete the
          `.satellite` folder first if you like (it is only for your editor).

        Reference: `satellite.storage`, `satellite.settings`, `satellite.ui`, `satellite.shortcuts`, `satellite.notify`, `satellite.openExternal`, `satellite.salesforce`, `satellite.relay`.

        """
    }

    /// Context for a coding agent working in the new project. Keep it in step with `typings`, `schema`,
    /// `ExtensionPermission` and the limits in RelayManager, UIRegistry, Shortcuts and Store.
    private static func agents(name: String, id: String) -> String {
        #"""
        # \#(name): context for coding agents

        This folder is a Satellite extension, id `\#(id)`. Satellite is a macOS app (WebKit) for Salesforce OrgCS,
        Slack and other work sites. Extensions add scripts, styles, sidebar items and shortcuts to it. Read this whole
        file before writing code. `.satellite/satellite.d.ts` (the API types) and `.satellite/manifest.schema.json`
        (the manifest schema) are generated by Satellite and are the source of truth; when they and this file disagree,
        they win. Don't edit anything in `.satellite/`.

        ## 1. Project layout

        | File | What it is |
        | --- | --- |
        | `manifest.json` | Name, version, permissions, and what runs where. Section 2. |
        | `content.js` / `background.js` / `style.css` | The code the manifest names. Only files the manifest lists are installed. |
        | `.satellite/satellite.d.ts` | Types for the `satellite` object. `jsconfig.json` makes editors use them. |
        | `.satellite/manifest.schema.json` | Schema for `manifest.json` (its `$schema` points here). |
        | `README.md` | Notes for people. |

        **Development loop.** Satellite watches this folder: saving a file reloads the extension and every page it runs
        on. `console.log` output and errors (the last 300) are under Settings > Extensions, in the list icon next to
        the extension; there's no need for a web inspector. **View > Copy Page for AI** in Satellite copies a page's DOM,
        shadow DOM, frames and selectors, so ask the user for it instead of guessing selectors.

        **Code runs inside an async function**: top-level `await` and `return` work. Don't run `node --check` on these
        scripts (it reports those as errors), and don't try to run them in Node: `satellite` only exists inside
        Satellite. Plain JavaScript, no build step, no npm packages; anything you need goes in a file the manifest lists
        or in a library extension.

        ## 2. manifest.json

        ```json
        {
          "$schema": ".satellite/manifest.schema.json",
          "name": \#(quoted(name)),
          "version": "0.1.0",
          "author": "Your Name",
          "description": "One or two sentences on what it does, and what it sends online, if anything.",
          "icon": "symbol:sparkles",
          "permissions": ["storage"],
          "matches": ["*://*.lightning.force.com/*"],
          "exclude_matches": [],
          "js": ["content.js"],
          "css": ["style.css"],
          "run_at": "document_idle",
          "all_frames": false,
          "world": "isolated",
          "background": "background.js",
          "settings": [{ "key": "enabled", "type": "boolean", "title": "Enabled", "default": true }]
        }
        ```

        - **Required:** `name`, `version` (`major.minor.patch`; raise it to ship an update), `author` (a string or
          `{ name, email, url }`), `description`. An `id`, if present, must equal the folder name (`\#(id)`).
        - **`icon`**: a `.png`, `.jpg` or `.svg` in the folder, or `symbol:<SF Symbol name>`. Also optional:
          `category`, `keywords`, `homepage`, `license`, `min_app_version`.
        - **`matches`** and **`exclude_matches`**: Chrome match patterns (`*://*.force.com/*`, `<all_urls>`). A page
          script needs `matches` plus at least one of `js`/`css`, unless the extension only has a `background` script.
        - **`run_at`**: `document_start`, `document_end` (default) or `document_idle`. **`all_frames`** also runs in
          frames.
        - **`world`**: `isolated` (default) gets the DOM and the `satellite` API. `main` runs in the page's own
          JavaScript and gets **no API at all**. Use `isolated` unless you must touch the page's globals.
        - **`background`**: a script that runs when Satellite starts (and again on save or a settings change), with no
          page open. Same API as page scripts. Use it for anything that must keep going while no matching page is open:
          relay listeners, timers, sidebar items, shortcuts.
        - **`type: "library"`**: a library has no `matches`; its `index.js` assigns to `module.exports`. Other
          extensions list it under **`dependencies`** (`{ "shared-utils": "^1.0.0" }`; ranges `1.2.3`, `^`, `~`,
          `>=1.2.0 <2.0.0`, `*`) and call `require('<id>')`. A library runs with its dependents' permissions.
        - **`settings`**: up to 40 options the user edits under Settings > Extensions. Each is `{ key, type, title }`
          plus optional `description`, `default`, `placeholder`, `options` (for `choice`: `[{ value, label }]`), `min`,
          `max`. Types: `string` (up to 2000 characters), `number`, `boolean`, `choice`. Keys match
          `^[A-Za-z][A-Za-z0-9_.-]{0,39}$`.
        - **`permissions`**: section 3. The user sees them before installing, so ask only for what you use.

        ## 3. Permissions

        A call whose permission isn't declared rejects with
        `Permission denied: add "<permission>" to "permissions" in manifest.json`.

        | Permission | Allows |
        | --- | --- |
        | (none) | `satellite.extensionId`, `satellite.settings`, `satellite.appearance` |
        | `storage` | `satellite.storage` |
        | `notifications` | `satellite.notify` (macOS notifications) |
        | `open-external` | `satellite.openExternal` |
        | `ui` | `satellite.ui.apps` and `satellite.ui.assistants` (the sidebar and the assistants panel) |
        | `shortcuts` | `satellite.shortcuts` |
        | `salesforce` | `satellite.salesforce.query` (read-only SOQL) |
        | `case-assistant` | `satellite.caseAssistant` (don't use it for new work without asking; section 6) |
        | `relay` | `satellite.relay` channels |
        | `relay-rooms` | `satellite.relay.rooms` |
        | `relay-stores` | `satellite.relay.stores` |
        | `relay-notifications` | `satellite.relay.notifications` |

        `satellite.relay.identity()` works with any of the four relay permissions.

        ## 4. The `satellite` API

        Every method returns a Promise and rejects with a readable message. Wrap calls in `try`/`catch` and log the
        error; uncaught rejections show up in the extension's log.

        ### Basics

        ```js
        satellite.extensionId;                                // '\#(id)'

        // "storage": JSON values on this Mac, per extension, shared by all its pages and its background script.
        await satellite.storage.set('state', { count: 1 });
        const state = await satellite.storage.get('state');   // undefined/null when unset
        await satellite.storage.remove('state');

        // No permission. The manifest's settings, plus any registered at runtime.
        const { enabled } = await satellite.settings.getAll();
        await satellite.settings.get('enabled');
        await satellite.settings.set('enabled', false);
        await satellite.settings.register({ key: 'color', type: 'choice', title: 'Color', default: 'blue',
          options: [{ value: 'blue', label: 'Blue' }, { value: 'red', label: 'Red' }] });
        satellite.settings.onChange((key, value) => {});      // fires in every page and the background script

        // No permission. 'light' or 'dark'. `app` is Satellite's appearance; `page` is how this page looks now
        // (claude.ai and Slack have their own theme, Salesforce stays light). Style anything you add by `page`.
        satellite.appearance.app;
        satellite.appearance.page;
        satellite.appearance.onChange(({ app, page }) => {});

        await satellite.notify('Title', 'Body');              // "notifications"; only in the installed app
        await satellite.openExternal('https://example.com');  // "open-external"; http(s) only, default browser
        ```

        ### Salesforce: `satellite.salesforce.query(soql)` (`salesforce`)

        Runs a **read-only** SOQL query through the REST API as the signed-in user, in the org of the current page
        (`*.lightning.force.com` or `*.my.salesforce.com`, https only). The session never reaches the page. Resolves to
        `{ totalSize, done, nextRecordsUrl?, records }`. There is no way to write records, and there must not be.

        ```js
        const { records } = await satellite.salesforce.query(
          "SELECT Id, CaseNumber, Status FROM Case WHERE OwnerId = '005...' LIMIT 20");
        ```

        ### Sidebar: `satellite.ui.apps` / `satellite.ui.assistants` (`ui`)

        The apps rail (left) and the assistants panel (right). Up to 8 items per list per extension. Adding an id that
        exists replaces it, so calling `add` on every start is safe. You can also hide, rename or badge built-in items.
        Changes last only while the extension is on.

        ```js
        await satellite.ui.apps.add({ id: 'docs', name: 'Docs', url: 'https://example.com/', symbol: 'book', badge: 3, index: 0 });
        await satellite.ui.apps.update('docs', { badge: null, hidden: false });
        await satellite.ui.apps.list();     // [{ id, name, url, symbol, badge, hidden, builtin, owner, readOnly }]
        await satellite.ui.apps.select('docs');
        await satellite.ui.apps.remove('docs');
        ```

        ### Shortcuts: `satellite.shortcuts` (`shortcuts`)

        Commands listed in the Extensions menu and in Settings > Shortcuts, where the user can change them. Up to 12 per
        extension. A shortcut needs Cmd or Ctrl. If it's already taken, `shortcut` comes back `null` and `conflict`
        names the other command. The handler runs in the front page (if this extension runs there) and in the
        background script, so pick one place to act (section 5).

        ```js
        const s = await satellite.shortcuts.register({ id: 'copy-case', title: 'Copy Case Number', shortcut: 'Cmd+Shift+K' },
          () => { /* ... */ });
        // s = { id, title, shortcut, requested, conflict, customized }
        satellite.shortcuts.onTrigger(id => {});
        await satellite.shortcuts.list();
        await satellite.shortcuts.unregister('copy-case');
        ```

        ### Relay channels: `satellite.relay` (`relay`)

        Satella is a shared, live publish/subscribe relay: what you send on a channel reaches everyone subscribed to it
        at that moment. Satellite keeps the connection natively, one per extension, so page CSPs can't block it.
        **Never open your own WebSocket or bundle a relay client.**

        ```js
        const me = await satellite.relay.identity();   // this extension's public key: 64 hex, stable across restarts
        satellite.relay.onMessage(({ channel, sender, text }) => {
          if (sender === me) return;                    // the relay echoes your own messages
          const message = JSON.parse(text);
        });
        await satellite.relay.subscribe('\#(id).lobby');
        await satellite.relay.send('\#(id).lobby', JSON.stringify({ v: 1, id: crypto.randomUUID(), text: 'hi' }));
        await satellite.relay.unsubscribe('\#(id).lobby');
        ```

        - **Channels** match `^[A-Za-z0-9._-]{1,128}$`. Prefix them with `\#(id).`. Never use `satadm` (device
          management).
        - **Messages** are text up to 100 KB. Send JSON with a version field and a unique `id`, so receivers can skip
          what they don't understand and drop duplicates.
        - **`sender`** is the sending connection's key, checked by the relay; it can't be forged. It's `''` when the
          sender proved no key. Trust peers by key (keep an allow-list in `storage`).
        - **Channels are public.** Anyone who guesses the name can read and write, and the relay operator sees all
          traffic. Use random channel names for private conversations and encrypt anything that isn't public.
        - **Live only.** No history; anything sent while you're offline is lost. Keep what you need in `storage`.
        - **Reconnects are automatic** (backoff 2 s doubling to 60 s) and you're re-subscribed. Only the first
          `subscribe` can reject ("can't reach the relay"); retry it a few seconds later. **`send` while disconnected
          drops the message silently**: if delivery matters, have the receiver acknowledge and resend until it does.
        - Disabling or uninstalling the extension closes its connection.

        ### Rooms: `satellite.relay.rooms` (`relay-rooms`)

        Rooms know who's in them. The user is asked once per room group the first time you join it.

        ```js
        satellite.relay.rooms.onMessage(({ group, room, sender, text, direct }) => {});
        satellite.relay.rooms.onJoin(({ group, room, member }) => {});
        satellite.relay.rooms.onLeave(({ group, room, member }) => {});
        const { members } = await satellite.relay.rooms.join('\#(id).lobby', 'main'); // others' keys, never yours
        await satellite.relay.rooms.send('\#(id).lobby', 'main', 'hi');               // everyone else in the room
        await satellite.relay.rooms.send('\#(id).lobby', 'main', 'psst', members[0]); // one member (direct)
        await satellite.relay.rooms.members('\#(id).lobby', 'main');
        await satellite.relay.rooms.leave('\#(id).lobby', 'main');
        ```

        Groups are 1–64 and rooms 1–48 characters of `[A-Za-z0-9._-]`, up to 64 members. Join before sending. Messages
        are text up to 64 KB, 60 a second per room. After a reconnect you get `onLeave` for every member, then `onJoin`
        for whoever is still there, and you're back in the room without calling `join` again.

        **`join` can fail; retry it.** While the relay is down or still connecting, `join` (like the store methods)
        waits up to 15 seconds, then rejects with "Can't reach the relay right now." It also rejects if the user chose
        Don't Allow. Catch it, show that you're offline, and try again a few seconds later while your UI still wants
        the room. Never leave a "connecting…" state up after a single failed attempt:

        ```js
        async function joinWithRetry(group, room, isWanted) {
          while (isWanted()) {
            try { return await satellite.relay.rooms.join(group, room); }
            catch (error) { showOffline(error.message); await new Promise(r => setTimeout(r, 5000)); }
          }
        }
        ```

        ### Stores: `satellite.relay.stores` (`relay-stores`)

        Small values kept on the relay. The user is asked once per store channel. Satellite signs every write with this
        extension's key; the private key never reaches JavaScript.

        ```js
        // Channel store: one value per channel and key, shared by everyone who uses the channel.
        await satellite.relay.stores.channel.set('\#(id).board', 'motd', 'hello');
        await satellite.relay.stores.channel.get('\#(id).board', 'motd');     // string or null
        await satellite.relay.stores.channel.remove('\#(id).board', 'motd');

        // Player store: this extension's own values. 'private' (default) only it can read; 'public' anyone can.
        await satellite.relay.stores.player.set('\#(id).prefs', 'status', 'away', { scope: 'public' });
        await satellite.relay.stores.player.get('\#(id).prefs', 'status', { scope: 'public', player: someKey });
        await satellite.relay.stores.player.remove('\#(id).prefs', 'status', { scope: 'public' });
        ```

        Channels and keys are 1–128 characters of `[A-Za-z0-9._@-]`, with no leading, trailing or doubled dots. Values
        are text, 1 byte to 4 KB (store JSON as a string). **Store reads haven't been verified against the live relay
        yet**: treat `get` as best effort and keep a local copy in `satellite.storage`. Like `join`, every store call
        rejects with "Can't reach the relay right now." if the relay stays unreachable for 15 seconds.

        ### Relay notifications: `satellite.relay.notifications` (`relay-notifications`)

        Messages the relay itself pushes to everyone (maintenance notices and the like). Nothing is sent, so there's no
        prompt.

        ```js
        satellite.relay.notifications.onNotification(({ prefix, message, suffix, duration }) => {}); // duration may be null
        await satellite.relay.notifications.subscribe();
        await satellite.relay.notifications.unsubscribe();
        ```

        ### Case assistant: `satellite.caseAssistant` (`case-assistant`)

        The ChatGPT case-brief bridge (`status`, `signIn`, `connectSlack`, `start`, `poll`, `cancel`; see the types).
        Works only in the main OrgCS frame. It's the broadest AI data path in Satellite: don't use it in a new
        extension unless the user asks for it explicitly.

        ### Libraries

        ```js
        const utils = require('shared-utils');   // listed under "dependencies"
        // in a library's index.js:
        module.exports = { greet: name => `Hello, ${name}` };
        ```

        ## 5. Writing scripts that hold up

        - **Pages re-render constantly** (Salesforce Lightning, Slack). Wait for elements with a `MutationObserver`
          instead of assuming they exist (`content.js` from the "Change a page" template has a `waitFor` helper), and
          expect them to be replaced: re-attach what you add when it disappears. Salesforce uses shadow DOM; reach in
          with `element.shadowRoot`.
        - **Many copies run at once.** Each matching tab, each frame (with `all_frames`) and the background script run
          their own copy. Listeners such as `relay.onMessage`, `settings.onChange` and shortcut handlers fire in all of
          them. When something should happen once (a notification, a reply, a write), do it in the background script,
          or check `window.top === window`, or dedupe through `storage`.
        - **Don't add UI twice.** Saving reloads the script; give elements you add an id and remove or reuse an existing
          one.
        - **Style for the page.** Use `satellite.appearance.page` and `onChange` for colors, and a very high `z-index`
          for floating UI.
        - **Fail quietly.** A missing element or a rejected call should log and carry on, not break the page.

        ## 6. Rules

        - **Company data policy (Salesforce).** This runs in a customer-support environment. **Never send case data,
          customer data, personal information or internal content to the relay, to any outside service, or to any AI
          tool that isn't approved.** The relay is a third-party service with no governance review, and its operator
          can read plain-text traffic. Fine on the relay: presence, statuses, non-sensitive chat, encrypted payloads.
          `satellite.salesforce.query` is read-only and stays that way; don't look for ways to write.
        - **Say what goes online.** If the extension uses any `relay*` permission or `openExternal`, the manifest's
          `description` must say what it sends and where.
        - **Don't get around Satellite's controls.** Admins can block extension ids and lock the MCP server. Don't run code in
          the `main` world to reach tokens, sessions or cookies, don't scrape credentials, and don't reach the network
          other than through the `satellite` API.
        - **Permissions are the user's consent.** Ask only for what you use.

        ## 7. Publishing

        1. Copy this folder into the `kcontreras-csm/satellite-extensions` repository (the folder name is the id). You
           can drop `.satellite/`, `jsconfig.json`, `AGENTS.md` and `CLAUDE.md`; only files the manifest names are
           installed.
        2. Run `python3 scripts/generate_extensions.py --check` there. It validates every manifest.
        3. Push to `main`. The Extensions Action regenerates `extensions.json`, and the Store lists the extension.
        4. To ship an update, raise `version`.

        Limits: 2 MB per file, 10 MB and 200 files per extension. Symlinks aren't followed.

        """#
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
      /** An http(s) URL, or one of this extension's own pages: satellite-ext://<extension id>/<path in web_root>. */
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

    interface SatelliteShortcutInput {
      id: string; title: string;
      /** Like "Cmd+Shift+K" or "Ctrl+Alt+Left". Needs Cmd or Ctrl. Leave it out for a menu-only command. */
      shortcut?: string;
    }
    interface SatelliteShortcut {
      id: string; title: string;
      /** The shortcut it has now (the user may have changed it); null when it has none. */
      shortcut: string | null;
      /** The shortcut you asked for. */
      requested: string | null;
      /** The command that already had the shortcut you asked for, when that is why `shortcut` is null. */
      conflict: string | null;
      /** The user picked a different shortcut, or removed it, in Settings > Shortcuts. */
      customized: boolean;
    }

    type SatelliteSettingValue = string | number | boolean;
    interface SatelliteSettingDefinition {
      key: string; type: 'string' | 'number' | 'boolean' | 'choice'; title: string; description?: string;
      default?: SatelliteSettingValue; placeholder?: string; options?: { value: string; label: string }[];
      min?: number; max?: number;
    }

    type SatelliteShade = 'light' | 'dark';

    interface Satellite {
      readonly extensionId: string;
      /** Light or dark. No permission needed. */
      appearance: {
        /** Satellite's appearance (Settings > General > Appearance), which pages see as prefers-color-scheme. */
        readonly app: SatelliteShade;
        /** How the page this script runs on looks now. Its own theme can differ from Satellite's (claude.ai and Slack
         *  have their own setting; Salesforce stays light), so style UI you add to the page from this. */
        readonly page: SatelliteShade;
        /** Called with both whenever either changes. */
        onChange(callback: (appearance: { app: SatelliteShade; page: SatelliteShade }) => void): void;
      };
      /** Needs the "case-assistant" permission and the main OrgCS frame. No tokens are exposed. */
      caseAssistant: {
        status(): Promise<{ chatgpt: boolean; slack: boolean; salesforce: boolean; drive: boolean; sources: string[]; inference?: string; inferenceMessage?: string }>;
        signIn(): Promise<{ opened: boolean }>;
        connectSlack(): Promise<{ opened: boolean }>;
        start(input: { caseId: string; caseNumber: string; prompt: string }): Promise<{ jobId: string; caseId: string; caseNumber: string }>;
        poll(jobId: string): Promise<{ jobId: string; caseId: string; caseNumber: string; status: string; progress: string; errorCode?: string; httpStatus?: number; research?: Record<string, unknown> }>;
        cancel(jobId: string): Promise<{ jobId: string; caseId: string; caseNumber: string; status: string; progress: string }>;
      };
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
      /**
       * Needs the "salesforce" permission. Runs a read-only SOQL query through the REST API, signed in as the user,
       * in the org of the page (*.lightning.force.com or *.my.salesforce.com). The session never reaches the page.
       */
      salesforce: {
        query<T = Record<string, any>>(soql: string): Promise<{ totalSize: number; done: boolean; nextRecordsUrl?: string; records: T[] }>;
      };
      /**
       * Needs the "relay" permission. Send and receive messages on Satellite's shared relay (Satella) — a live
       * pub/sub channel other Satellites can also listen on. Satellite keeps the connection natively, so there's
       * no socket in the page (the page's CSP can't block it) and no key to manage: this extension has its own
       * stable sender identity. `identity()` returns that sender key (hex), so you can tell your own messages
       * apart; `onMessage` fires for every message on a channel you've subscribed to. Channels are 1–128 chars of
       * letters, digits, ".", "_" or "-"; messages are up to 100 KB of text. The relay is a third-party service.
       * `rooms`, `stores` and `notifications` use the same connection and identity, each with its own permission.
       */
      relay: {
        /** This extension's public sender key (64 hex). Needs "relay", "relay-rooms", "relay-stores" or "relay-notifications". */
        identity(): Promise<string>;
        subscribe(channel: string): Promise<void>;
        unsubscribe(channel: string): Promise<void>;
        send(channel: string, text: string): Promise<void>;
        onMessage(callback: (message: { channel: string; sender: string; text: string }) => void): void;
        /**
         * Needs the "relay-rooms" permission. The user is asked once per room group. Groups are 1–64 and rooms 1–48
         * characters of letters, digits, ".", "_" or "-"; messages are up to 64 KB of text, 60 a second per room.
         * Members are other players' sender keys (never your own). After a reconnect you get onLeave for everyone,
         * then onJoin for whoever is still there.
         */
        rooms: {
          join(group: string, room: string): Promise<{ group: string; room: string; members: string[] }>;
          leave(group: string, room: string): Promise<void>;
          /** To everyone else in the room, or to one member when `to` is their key. Join first. */
          send(group: string, room: string, text: string, to?: string): Promise<void>;
          members(group: string, room: string): Promise<string[]>;
          onMessage(callback: (message: { group: string; room: string; sender: string; text: string; direct: boolean }) => void): void;
          onJoin(callback: (event: { group: string; room: string; member: string }) => void): void;
          onLeave(callback: (event: { group: string; room: string; member: string }) => void): void;
        };
        /**
         * Needs the "relay-stores" permission. The user is asked once per store channel. Channels and keys are 1–128
         * characters of letters, digits, ".", "_", "-" or "@" (no leading, trailing or doubled dots); values are
         * 1 byte to 4 KB of text. Satellite signs every write with this extension's key. `get` resolves to null
         * when there is no value.
         */
        stores: {
          /** One value per channel and key, shared by everyone who uses the channel. */
          channel: {
            get(channel: string, key: string): Promise<string | null>;
            set(channel: string, key: string, value: string): Promise<void>;
            remove(channel: string, key: string): Promise<void>;
          };
          /** This extension's own values. `private` (the default) only it can read; `public` anyone can, by passing `player`. */
          player: {
            get(channel: string, key: string, options?: { scope?: 'private' | 'public'; player?: string }): Promise<string | null>;
            set(channel: string, key: string, value: string, options?: { scope?: 'private' | 'public' }): Promise<void>;
            remove(channel: string, key: string, options?: { scope?: 'private' | 'public' }): Promise<void>;
          };
        };
        /** Needs the "relay-notifications" permission. Notifications the relay itself pushes; nothing is sent. */
        notifications: {
          subscribe(): Promise<void>;
          unsubscribe(): Promise<void>;
          onNotification(callback: (notification: { prefix: string; message: string; suffix: string; duration: number | null }) => void): void;
        };
      };
      ui: { apps: SatelliteSidebarList; assistants: SatelliteSidebarList };
      /**
       * Needs the "shortcuts" permission. Commands are listed in the Extensions menu and in Settings > Shortcuts,
       * where the user can change them. A shortcut that is already in use is not granted (see `conflict`).
       * The handler runs in the page in front, if this extension runs on it, and in the background script.
       */
      shortcuts: {
        register(definition: SatelliteShortcutInput, handler?: () => void): Promise<SatelliteShortcut>;
        unregister(id: string): Promise<void>;
        list(): Promise<SatelliteShortcut[]>;
        onTrigger(callback: (id: string) => void): void;
      };
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
          "items": { "enum": ["storage", "notifications", "open-external", "ui", "shortcuts", "case-assistant", "salesforce", "relay", "relay-rooms", "relay-stores", "relay-notifications"] },
          "description": "What the satellite API may do. storage, notifications, open-external, ui (change the sidebar), shortcuts (add keyboard shortcuts), salesforce (read-only SOQL as the signed-in user), relay (send/receive on Satellite's shared relay), relay-rooms, relay-stores and relay-notifications (rooms, stores and server notifications on the same relay)."
        },
        "matches": { "type": "array", "items": { "type": "string" }, "description": "Chrome match patterns, e.g. *://*.example.com/*" },
        "exclude_matches": { "type": "array", "items": { "type": "string" } },
        "js": { "type": "array", "items": { "type": "string" }, "description": "Scripts to run on matching pages." },
        "css": { "type": "array", "items": { "type": "string" }, "description": "Stylesheets to add to matching pages." },
        "run_at": { "enum": ["document_start", "document_end", "document_idle"] },
        "all_frames": { "type": "boolean" },
        "world": { "enum": ["isolated", "main"], "description": "isolated: DOM + the satellite API. main: the page's own JavaScript, no API." },
        "background": { "type": "string", "description": "A script that runs once at startup with no page open (world must be isolated)." },
        "web_root": { "type": "string", "description": "A folder served as web pages at satellite-ext://<id>/ (index.html by default), which sidebar items can open. Development folders only for now." },
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
