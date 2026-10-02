# Satellite

A native macOS app (Swift, AppKit, WKWebView) that keeps your work web apps in one window.

- **Left rail:** OrgCS, BT1 and Okta (`Cmd+1..9` to switch).
- **Right panel:** Claude, Gemini and Slackbot (`Cmd+Opt+1..9`, toggle with `Cmd+Opt+0`).
- **Settings** (`Cmd+,`): extensions, the extension store, software updates, remembered client certificates, clearing website data.
- **Extensions:** JavaScript that runs on the pages you choose, installable from a store.

Sign-ins persist across launches, client certificates are chosen automatically when only one fits (otherwise you pick once and it is remembered), and USB security keys work for passkey (WebAuthn) sign-in.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

    swift run              # dev run (no icon, notifications or updates)
    scripts/bundle.sh      # builds dist/Satellite.app
    open dist/Satellite.app

## Configuration

`~/Library/Application Support/Satellite/config.json` is created on first launch. Edit it to add or change apps and assistants (name, URL, SF Symbol icon) and relaunch.

Each app has tabs. A link that asks for a new window (`target=_blank`, or `window.open`) opens as a tab inside that app, with a tab bar that appears once there is more than one (`Cmd+W` closes a tab, `Shift+Cmd+[` and `]` switch). Pop-ups that ask for a specific size, such as sign-in windows, keep their own window. Links to other sites normally go to your browser; give an app `"tabs": true` to keep those as tabs too, which is how Okta launches each application:

    { "id": "okta", "name": "Okta", "symbol": "person.badge.key.fill", "url": "https://salesforce.okta.com/", "tabs": true }
 It can also point the store at another repository:

    "store": { "repository": "kcontreras-csm/satellite-extensions", "branch": null, "directory": null }

Set `SATELLITE_HOME=/some/dir` to use a different data folder.

## Security keys

Sites that ask for a hardware security key (FIDO2 / WebAuthn, such as a YubiKey) work for both sign-in and registration, including PIN entry and older U2F-only keys. macOS only allows WebAuthn in a web view for apps holding an Apple-issued browser entitlement, so Satellite talks to USB keys itself. Touch ID, iCloud Keychain and phone passkeys aren't available, and keys are used over USB only. **Settings > General** shows the keys it detects.

## Releases and updates

    scripts/release.sh 1.2.0

Run from a clean `main`, this pushes the tag `v1.2.0`. The **Release** workflow builds the app with that version and publishes a GitHub Release containing `Satellite-1.2.0.zip` and `appcast.json`.

The installed app reads `https://github.com/kcontreras-csm/satellite/releases/latest/download/appcast.json` after launch and every 24 hours (switch off under **Settings > General**), and from **Satellite > Check for Updates...**. If there is a newer version it offers to install: it downloads the zip, verifies the checksum, bundle identifier and signature, replaces itself and relaunches. Only an installed app updates itself, never a `swift run` build. Builds are ad-hoc signed, so macOS may ask again for camera, microphone or Keychain access after an update.

## Extensions

The [store repository](https://github.com/kcontreras-csm/satellite-extensions) lists extensions in an `extensions.json` that a GitHub Action regenerates from its folders. **Settings > Store** shows each one's author, permissions, pages and dependencies before you install it; dependencies install first, and installs are validated before they replace anything. See its `EXTENSIONS.md` for publishing and the full manifest reference. To try extensions from a local folder: `SATELLITE_STORE_DIR=../satellite-extensions swift run`.

To write an extension with an AI, open the page you want to change and use **View > Copy Page for AI** (`Shift+Cmd+C`, or the toolbar button; **Save Page for AI...** writes a file). The snapshot holds the page's HTML including shadow DOM and every frame, a list of clickable elements with selectors, the page's custom JavaScript globals, and a short guide to Satellite's extension format, so you can paste it into an AI together with what you want built. Pages often contain customer data, so by default only interface labels are kept and tokens in links are hidden; change this under **Settings > General**, and check the result before you share it.

**Developing an extension** is built in. **Settings > Extensions > New Extension...** creates a working project from a template (change a page, add a sidebar link, or restyle a page), can fill in the pages from the one you are looking at, and opens the folder in VS Code (or Cursor, Zed and others; pick one under Settings > General). The project comes with type definitions for the `satellite` API and a schema for `manifest.json`, so the editor autocompletes both. From then on:

- **Hot reload:** saving a file reloads the extension and the open pages it runs on (extensions installed from the store never reload your pages). Switch it off at the bottom of the Extensions tab.
- **Logs:** the list icon on each extension shows its `console.log` output and errors (the icon turns into a red warning when there are new errors), so there is no need to open a web inspector.
- **Your own folders:** **Folders...** adds a folder (say, a git repository of extensions) that Satellite loads extensions from alongside its own.

An extension is a folder with a `manifest.json` (and its scripts), in `~/Library/Application Support/Satellite/Extensions/` or installed from the store:

    {
      "name": "My Extension", "version": "1.0.0", "author": "Your Name", "description": "What it does",
      "matches": ["*://*.force.com/*"], "js": ["content.js"],
      "permissions": ["storage"],
      "settings": [{ "key": "label", "type": "string", "title": "Label", "default": "Queue" }]
    }

Scripts run in an isolated world with top-level `await` and a `satellite` API. Each call needs its permission in the manifest (`settings` needs none). A `"background"` script runs at startup with no page open, and `"type": "library"` extensions are loaded by others with `require('<id>')`.

    satellite.storage.get / set / remove            // "storage"
    satellite.notify(title, body)                   // "notifications" (bundled app only)
    satellite.openExternal(url)                     // "open-external"

    satellite.ui.apps / satellite.ui.assistants     // "ui": the left rail and the right panel
      .list() .add({ id, name, url, symbol, badge, index }) .update(id, patch) .remove(id) .select(id)

    satellite.settings.get / getAll / set / register / onChange

`ui` can add up to 8 items per list and change built-in ones (hide, rename, badge). Those changes last only while the extension is on. `settings` are declared in the manifest, shown under the slider icon in **Settings > Extensions**, and typed as `string`, `number`, `boolean` or `choice`. Toggling an extension takes effect on the next page load.
