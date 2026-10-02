# Satellite

A native macOS app (Swift, AppKit, WKWebView) that hosts your work web apps in one window:

- **Left rail:** Lightning, BT2 and Knowledge (`Cmd+1..3`).
- **Right panel:** Claude, Gemini and Slackbot (`Cmd+Opt+1..3`, toggle with `Cmd+Opt+0`).
- **Settings** (`Cmd+,`): enable or disable extensions, reveal the config, clear website data.
- **JavaScript extensions:** folders with a `manifest.json` injected into matching pages.

The earlier Qt prototype lives in `legacy-qt/` for reference only.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

    swift run                   # quick dev run (no app bundle: no notifications, generic Dock icon)
    scripts/bundle.sh           # builds dist/Satellite.app (ad-hoc signed)
    open dist/Satellite.app

## Configuration

`~/Library/Application Support/Satellite/config.json` is created on first launch. Edit it to change URLs, names or SF Symbol icons, then relaunch. The Knowledge entry points at `help.salesforce.com` until you set the real URL.

Set `SATELLITE_HOME=/some/dir` to use a different data directory (handy for testing).

## Extensions

Each extension is a folder in `~/Library/Application Support/Satellite/Extensions/` (Settings > Extensions > Reveal Folder). Use **Install Sample** in Settings for a working example.

    my-extension/
      manifest.json
      content.js

    {
      "name": "My Extension",
      "version": "1.0",
      "description": "What it does",
      "matches": ["*://*.force.com/*", "*://*.salesforce.com/*"],
      "exclude_matches": [],
      "js": ["content.js"],
      "css": ["style.css"],
      "run_at": "document_end",
      "all_frames": false,
      "world": "isolated"
    }

- `matches` uses Chrome match-pattern syntax (`*://*.example.com/*`, `<all_urls>`). Ports and fragments are ignored.
- `run_at`: `document_start`, `document_end` (default) or `document_idle`.
- `world`:
  - `isolated` (default) gives you the DOM plus the `satellite` API below, but not the page's own JS objects.
  - `main` runs alongside the page's scripts (you can read its globals) but has no `satellite` API.
- Scripts run inside an `async` function, so top-level `await` works.
- Toggling an extension takes effect the next time a page loads (Settings > Reload Pages).

### `satellite` API (isolated world)

    await satellite.storage.get('key')          // persisted per extension
    await satellite.storage.set('key', value)   // any JSON value
    await satellite.storage.remove('key')
    await satellite.notify('Title', 'Body')     // needs the bundled .app
    await satellite.openExternal('https://...') // http(s) only, opens the default browser
    satellite.extensionId
