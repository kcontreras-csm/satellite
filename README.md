# Satellite

A native macOS app (Swift, AppKit, WKWebView) that hosts your work web apps in one window:

- **Left rail:** Lightning, BT2 and Knowledge (`Cmd+1..3`).
- **Right panel:** Claude, Gemini and Slackbot (`Cmd+Opt+1..3`, toggle with `Cmd+Opt+0`).
- **Settings** (`Cmd+,`): manage extensions, browse the extension store, reveal the config, clear website data, review or forget remembered client certificates.
- **JavaScript extensions:** folders with a `manifest.json` injected into matching pages, installable from a store.

The earlier Qt prototype lives in `legacy-qt/` for reference only.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

    swift run                   # quick dev run (no app bundle: no notifications, generic Dock icon)
    scripts/bundle.sh           # builds dist/Satellite.app (ad-hoc signed)
    open dist/Satellite.app

## Configuration

`~/Library/Application Support/Satellite/config.json` is created on first launch. Edit it to change URLs, names or SF Symbol icons, then relaunch. The Knowledge entry points at `help.salesforce.com` until you set the real URL.

    "store": { "repository": "kcontreras-csm/satellite-extensions", "branch": null, "directory": null }

`store` is optional. `branch` can be a branch, tag or commit (default: the repository's default branch) and `directory` is the folder that holds `extensions.json` (default: the repository root).

Set `SATELLITE_HOME=/some/dir` to use a different data directory (handy for testing).

## Extension store

**Settings > Store** lists the extensions named in the `extensions.json` at the root of the store repository. Each entry points at an extension's folder. Pick one to see who wrote it, what it is allowed to do, which pages it runs on and what it depends on, then install it.

- **No GitHub API and no token:** Satellite only downloads plain files from `raw.githubusercontent.com`: `extensions.json`, each extension's `manifest.json` (downloaded again only when it changed), and, when you install, the files that manifest names.
- **Checked before install:** files are size-limited, the manifest is validated, the downloaded version must match the listed one, and everything is swapped in at once, so a failed install leaves the existing version alone. An entry can pin `ref` to a tag or commit to install exactly that version.
- **Dependencies** are installed first, and an update that would break another installed extension is refused.
- **Updates:** when the store has a higher `version` than the installed copy, the Extensions tab shows **Update**.
- **Remove** moves the folder to the Trash and deletes its saved data. A library that another extension needs can't be removed.
- Offline, the last downloaded list is shown.

Publishing is pushing a folder to the [store repository](https://github.com/kcontreras-csm/satellite-extensions); a GitHub Action there validates it and regenerates `extensions.json`. Its `EXTENSIONS.md` explains how to publish, and it holds the example extensions (`hello-badge`, `shared-utils`, `quick-link`).

### Trying an extension before publishing

    SATELLITE_STORE_DIR=../satellite-extensions swift run    # a clone of the store repository, or any folder of extensions

makes the Store tab read every folder in that directory instead of GitHub (validation and dependency rules still apply).

## Writing an extension

Each extension is a folder in `~/Library/Application Support/Satellite/Extensions/` (Settings > Extensions > Reveal Folder), or installed from the store. **Create Sample** in Settings makes a working example.

    my-extension/
      manifest.json
      content.js

    {
      "name": "My Extension",
      "version": "1.0.0",
      "author": "Your Name",
      "description": "What it does",
      "icon": "icon.png",
      "dependencies": { "shared-utils": "^1.0.0" },
      "permissions": ["storage"],
      "matches": ["*://*.force.com/*", "*://*.salesforce.com/*"],
      "js": ["content.js"],
      "run_at": "document_idle",
      "world": "isolated"
    }

- **Required:** `name`, `version` (`1.2.3`), `author` (a string or `{ name, email, url }`), `description`. The folder name is the extension id (lowercase letters, digits, `.`, `-`, `_`).
- **Icon:** a `.png`, `.jpg` or `.svg` in the folder, or `symbol:<SF Symbol name>`. With none, Satellite draws a colored tile with the first letter of the name.
- **Also available:** `category`, `keywords`, `homepage`, `license`, `min_app_version`, `exclude_matches`, `css`, `all_frames`. The full field table is in the store repository's [EXTENSIONS.md](https://github.com/kcontreras-csm/satellite-extensions/blob/main/EXTENSIONS.md).
- `matches` uses Chrome match-pattern syntax (`*://*.example.com/*`, `<all_urls>`). Ports and fragments are ignored.
- `run_at`: `document_start`, `document_end` (default) or `document_idle`.
- `world`:
  - `isolated` (default) gives you the DOM plus the `satellite` API below, but not the page's own JS objects.
  - `main` runs alongside the page's scripts (you can read its globals) but has no `satellite` API.
- Scripts run inside an `async` function, so top-level `await` works.
- **Background script:** `"background": "background.js"` runs once when Satellite starts, in a hidden page, with no page needed (`matches` becomes optional). It has the same `satellite` API. It uses its own throwaway cookie store and ordinary web rules (cross-origin requests obey CORS), so to call a site's API with the user's session, do it from a content script on that site. Inspect it from Safari's Develop menu.
- Toggling an extension takes effect the next time a page loads (Settings > Reload Pages).

### Libraries and dependencies

An extension with `"type": "library"` has no `matches`; its `js` runs as a module (assign to `module.exports`). Extensions list libraries under `dependencies` (`{ "id": "<range>" }`, ranges like `^1.2.0`, `~1.2.0`, `>=1.0.0 <2.0.0`, `*`) and load them with `require('<library id>')`. Libraries run with the dependent's `satellite` API and permissions.

### `satellite` API (isolated world; content and background scripts)

Each call must be covered by a `permissions` entry in the manifest or it is rejected. `settings` needs no permission.

    satellite.extensionId

    await satellite.storage.get('key')          // "storage": saved per extension
    await satellite.storage.set('key', value)   // any JSON value
    await satellite.storage.remove('key')
    await satellite.notify('Title', 'Body')     // "notifications"; needs the bundled .app
    await satellite.openExternal('https://...') // "open-external"; http(s) only, opens the default browser

### Changing the sidebar and the assistants panel (`"ui"`)

`satellite.ui.apps` is the left rail and `satellite.ui.assistants` is the right panel. Both have the same methods:

    await satellite.ui.apps.list()
    // [{ id, name, url, symbol, badge, hidden, builtin, owner, readOnly }]

    await satellite.ui.apps.add({ id: 'queue', name: 'Queue', url: 'https://example.com/queue',
                                  symbol: 'tray.full', badge: '3', index: 1 })
    await satellite.ui.apps.update('queue', { badge: '4' })      // name, url, symbol, badge (null clears), hidden
    await satellite.ui.apps.update('orgcs', { name: 'Org' })      // built-in items can be changed too
    await satellite.ui.apps.remove('queue')                       // on a built-in item, this hides it
    await satellite.ui.apps.select('queue')                       // switch to it

- `symbol` is an SF Symbol name (unknown names show a globe). `url` must be http(s). `badge` is up to 8 characters. `index` is the position (default: the end).
- Adding an id you already added replaces that item, so running the same code again is safe.
- An extension can add up to 8 items per list and can change its own items and the built-in ones, but not another extension's.
- Changes to built-in items are overlays: they vanish when the extension is turned off or removed, and `config.json` is never touched. Items an extension adds are not saved either; a background script should add them at startup.

### Custom settings

Declare them in `manifest.json` and Satellite shows a form under the slider icon next to your extension in **Settings > Extensions**:

    "settings": [
      { "key": "enabled", "type": "boolean", "title": "Show the link", "default": true },
      { "key": "label", "type": "string", "title": "Label", "placeholder": "Queue", "default": "Queue" },
      { "key": "refresh", "type": "number", "title": "Refresh (minutes)", "min": 1, "max": 60, "default": 5 },
      { "key": "mode", "type": "choice", "title": "Mode", "default": "compact",
        "options": [{ "value": "compact", "label": "Compact" }, { "value": "full", "label": "Full" }] }
    ]

Types are `string`, `number`, `boolean` and `choice`; `description` is optional help text. In code:

    await satellite.settings.get('label')         // the current value (or the default)
    await satellite.settings.getAll()             // { enabled: true, label: 'Queue', ... }
    await satellite.settings.set('refresh', 10)   // validated against the definition
    satellite.settings.onChange((key, value) => { ... })   // the user (or set()) changed a setting
    await satellite.settings.register([...])      // same shape as "settings"; replaces the ones you registered before

`register` is for settings you can only know at runtime (for example a list of queues read from the page). It can't reuse a key declared in the manifest. `onChange` reaches the extension's background script and the main frame of pages it runs in. See `quick-link` in the [store repository](https://github.com/kcontreras-csm/satellite-extensions) for a complete example.
