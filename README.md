# Satellite

A native macOS app (Swift, AppKit, WKWebView) that keeps your work web apps in one window.

- **Left rail:** OrgCS, BT1, Okta, Splunk and others (`Cmd+1..9` to switch).
- **Right panel:** Claude, Gemini, Slackbot and a Terminal (`Cmd+Opt+1..9`, toggle with `Cmd+Opt+0`).
- **Settings** (`Cmd+,`): extensions, the extension store, keyboard shortcuts, software updates, remembered client certificates, Slack sign-in, website data (clear one site, only the cache so you stay signed in, or everything).
- **Extensions:** JavaScript that runs on the pages you choose, installable from a store.

Sign-ins persist across launches, client certificates are chosen automatically when only one fits (otherwise you pick once and it is remembered), and USB security keys work for passkey (WebAuthn) sign-in.

## Build and run

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

    swift run              # dev run (no icon, notifications or updates)
    scripts/bundle.sh      # builds dist/Satellite.app
    open dist/Satellite.app

## Configuration

The apps and assistants start as the built-in ones (OrgCS, BT1, Okta, Splunk and others; Claude, Gemini, Slackbot and Terminal). **Settings > Apps** changes them: drag the grip at the left of a row to reorder, click the pencil to change the name, address or icon (and whether links open as tabs, below), add your own, remove any, and bring a removed one back from **Add**. **Reset to Defaults** restores the built-in ones. Changes apply right away and are saved to `~/Library/Application Support/Satellite/config.json`, which you can also edit by hand (relaunch to pick that up).

Each app has tabs. A link that asks for a new window (`target=_blank`, or `window.open`) opens as a tab inside that app, with a tab bar that appears once there is more than one (`Cmd+W` closes a tab, `Shift+Cmd+[` and `]` switch). Pop-ups that ask for a specific size, such as sign-in windows, keep their own window. Links to other sites normally go to your browser; turn on **Open links in new tabs** for an app (`"tabs": true` in config.json) to keep those as tabs too, which is how Okta launches each application:

    { "id": "okta", "name": "Okta", "symbol": "person.badge.key.fill", "url": "https://salesforce.okta.com/", "tabs": true }
config.json can also point the store at another repository:

    "store": { "repository": "kcontreras-csm/satellite-extensions", "branch": null, "directory": null }

Set `SATELLITE_HOME=/some/dir` to use a different data folder.

## Keyboard shortcuts

Every command is in the menus with its shortcut, and **Settings > Shortcuts** lists all of them: click one, press the keys you want (Delete removes it, Esc cancels), or reset it to the default. A shortcut needs `Cmd` or `Ctrl`, and two commands never share one; standard macOS shortcuts (`Cmd+Q`, `Cmd+C`...) are shown but locked. Your choices are saved per command.

| | |
|---|---|
| **Paste without formatting** | `Opt+Shift+Cmd+V` (Edit > Paste and Match Style) pastes only the text, without fonts, colors or links, in pages and text fields. `Shift+Cmd+V` is left to the page, since many web apps use it for their own plain paste; to have Satellite take it instead, assign it to Paste and Match Style in Settings > Shortcuts |
| **Find in page** | `Cmd+F` opens the find bar (starting with the selected text); `Cmd+G` / `Shift+Cmd+G` step to the next / previous match, `Return` / `Shift+Return` do the same in the bar, `Esc` closes it and leaves the match selected. See below for regular expressions |
| **Zoom** | `Cmd+=` (or `Cmd++`) in, `Cmd+-` out, `Cmd+0` actual size; remembered per website |
| **Navigation** | `Cmd+[` back, `Cmd+]` forward, `Cmd+R` reload, `Shift+Cmd+R` reload without cache, `Cmd+.` stop, `Shift+Cmd+H` start page of the app in front |
| **Tabs and apps** | `Shift+Cmd+[` / `]` previous / next tab, `Cmd+W` close tab, `Cmd+1..9` apps, `Opt+Cmd+1..9` assistants, `Opt+Cmd+0` toggle assistants |
| **Page** | `Shift+Cmd+E` send to the assistant, `Cmd+P` print, `Shift+Cmd+L` copy link, `Shift+Cmd+O` open in your default browser, `Shift+Cmd+C` / `S` copy / save page for AI |
| **Links** | **File > Copy Link** (`Shift+Cmd+L`) copies the address of the page in front: the app's current tab, or the assistant you're in. **Copy Link with Title** (no shortcut until you give it one) copies it with the page's title: rich editors such as Slack, Docs and Mail paste the title, linked; plain text gets "title — address". Right-click a tab, or an app in the left rail, for the same two plus **Open in Default Browser** for that tab (or the tab the app shows), and **Close Tab** on tabs that can close |

### Find with regular expressions

The find bar highlights every match on the page and counts them ("3 of 17"), in the page and in its frames (iframes), and reaches into shadow DOM, so it works on Lightning pages. It searches the text as it is shown: hidden elements are skipped, runs of spaces count as one, and a match can run across tags like `Hello <b>wor</b>ld`. Three switches sit under the field (they are remembered, and also in the Edit menu):

| | | |
|---|---|---|
| `.*` | Use Regular Expression (`Opt+Cmd+R`) | JavaScript syntax. The field turns red and says what is wrong while the pattern is invalid. |
| `Aa` | Match Case (`Opt+Cmd+C`) | |
| `ab` | Match Whole Word (`Opt+Cmd+W`) | Also applies to a pattern. |

Without the regex switch what you type is plain text, so `(` or `.` just match themselves and a space matches any run of white space, including the break between two blocks. With it, `^` and `$` match at the start and end of a block (a paragraph, a table cell), `.` stays inside a block while `\s` can cross from one block to the next (`Case Number\s+\d+` finds a label and the value next to it), and `\p{L}`-style classes work. The `...` button copies every match (one per line) to the clipboard. At most 10,000 matches are counted, and a pattern that backtracks badly, like `(a+)+$`, can make the page unresponsive until it finishes, as in any browser.

Extensions can add their own with `satellite.shortcuts` (see below). They show up under an **Extensions** menu and in Settings > Shortcuts, and they never take a shortcut that is already in use.

## Tab groups

A tab group keeps pages from any apps or addresses together under a name and a color — a case's OrgCS record, its Splunk search and a doc, say. Groups belong to Satellite, not to one app, and are saved in config.json (`"groups"`), so they're still there after a relaunch whether or not they were open.

**Groups** in the rail (above Settings) shows every group in the main window: its color, name and pages, and whether it's **Loaded** (green), partly loaded ("2 of 3 loaded", orange) or **Not loaded**. For each:

- **Load** opens its pages in the background, without switching to them, so they're ready when you look, and an agent can read them through the MCP server (below) without you ever opening the group. **Unload** closes them; the group stays.
- **Open** shows the group in the main window like an app, loading it first if needed: its pages are tabs, behind a chip with the group's name (click the chip to go back to the list). The address bar shows each page's address, read-only.
- The **•••** menu (or right-click) adds an app's page or an address, renames, recolors, or deletes the group. Expand a group (the arrow) to see its pages, each marked loaded or not, with a button to take it out.

**New Group** (top right) makes one **From App** (that app's page), **From Address…**, or empty. Right-click any app's tab, an app in the rail, or the address bar and choose **Add to Group** to copy the page it shows into a group, or into a new one; the page stays in its app.

Closing one of a group's tabs only closes it for now — the page stays in the group, and **Load** reopens it; **Remove from Group** (right-click the tab) takes it out. Closing a group's last tab unloads the group. A link one of its pages opens in a new tab becomes a tab of the group for the session but isn't saved unless you right-click it and choose **Keep in Group**. Pages are saved at the address they were added with, not wherever you navigate them to, since sign-in redirects can put tokens in an address.

**Importing from Chrome.** The Groups view's **Import from Chrome…** scans Chrome's own session files on disk for URLs that look like open tabs, lets you check off which ones to bring in, and saves the checked ones as a new group ("From Chrome"), not loaded until you Load or Open it. This is best-effort, not exact: Chrome's session format is internal, undocumented and unversioned for outside tools, so the scan reads raw bytes for recognizable `http(s)://` strings rather than parsing it structurally. That means it can surface pages you've since navigated away from (a tab's history, not just what's currently open), and it never recovers Chrome's own tab groups — Chrome doesn't expose group names or colors here at all, only Chrome itself knows them. Review the list before importing; nothing is opened until you do.

## Address bar

The toolbar shows a Safari-like address field for the page in front (the app's current tab, not whatever the assistants panel shows), centered over the page and sized to fit between the buttons on either side; the window title is hidden to make room, as in Safari (the rail shows which app is in front). By default it's read-only: click it to select the whole address, then `Cmd+C` to copy, same as Safari's. It can't be typed into — Satellite's apps are configured destinations, not a general browser — unless the app in front allows it: turn on **Allow editing the address bar** when you edit that app in **Settings > Apps** (`"editableAddress": true` in config.json; off by default). While that app is in front, type an address and press Return to go there, or Esc to back out without navigating; switching to an app without it makes the bar read-only again. The field always reflects the real page, including while you're mid-edit elsewhere — it won't get overwritten until you commit or cancel.

The toolbar's **+** button opens a new, blank tab in the app shown now (there was previously no way to open one by hand — only a page's own links and `window.open` could). Since a blank tab has nowhere to go yet, the address field becomes editable just for that one address, even in an app that doesn't allow editing it; type a destination and press Return, and it locks again afterward for such an app.

## Terminal

An assistant can be a terminal instead of a web page: a native one ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) in the right panel, so a command-line agent such as Claude Code runs next to your work with its full-screen interface, colors and mouse support. It starts with the other assistants and keeps running while you switch between them. **Settings > Apps > Add > New Terminal...** adds one; leave **Command** empty for your login shell, or give one to run (`claude`), and optionally a folder to **Start in**. In config.json:

    { "id": "terminal", "name": "Terminal", "symbol": "terminal", "terminal": {} }
    { "id": "claude-code", "name": "Claude Code", "symbol": "sparkle", "terminal": { "command": "claude", "directory": "~/dot", "theme": "Dracula", "padding": 1.5 } }

**Padding** puts room around the text, counted in characters (the width of one, in the terminal's font): 0 (the default) to 10, in halves, set with **Padding** when you edit the terminal in Settings > Apps, or `"padding"` in config.json. It is filled with the terminal's background, grows and shrinks with the text size (`Cmd+=` / `Cmd+-`), and a click in it goes to the terminal.

**Themes.** Right-click in a terminal and choose **Theme > Choose Theme...** (or **View > Terminal Theme...**, which also works while a program in the terminal takes the mouse for itself) to pick one of 1,251 color themes from [Gogh](https://github.com/Gogh-Co/Gogh): search by name, filter dark or light, and each one shows in the terminal as you select it. Whatever is shown when the list closes is kept for that terminal (`"theme"` in config.json); **Revert** goes back to the one it had. The same list is under **Theme > Choose...** when you edit the terminal in **Settings > Apps**; there the theme is part of the form, so it applies when you save and Cancel leaves it as it was. **System**, the default, uses the system's text colors and follows light and dark mode. The themes are part of Satellite, so nothing is downloaded: `scripts/update-gogh-themes.py <commit>` regenerates them from a given Gogh commit, for review like any other change.

It always starts through your login shell, interactive, so your PATH and profile apply (an app opened from the Dock otherwise gets a bare PATH, where `claude` and Homebrew tools aren't found); after a command exits, the shell stays open. When the session ends, press Return to start a new one. While it has focus it keeps every key without `Cmd` (Ctrl+R, Ctrl+A... belong to the program in it); `Cmd+C`, `Cmd+V` and `Cmd+A` copy, paste and select, `Cmd+=` / `Cmd+-` / `Cmd+0` change its text size, and page commands such as Reload and Find don't reach past it to the app page.

**Send to Assistant** and **Ask About This** work with it: the selection (or page) is pasted at the prompt and Return is not pressed. Satellite only pastes there when the program running has turned on bracketed paste (zsh and Claude Code do), so the text arrives as text; otherwise each line break would act as Return and run the lines as commands, so it goes to the clipboard instead. Nothing on a web page or in an extension can read from or type into a terminal: only config.json and Settings make one, extensions can't add one or change what it runs (like any built-in item they can only rename, hide or badge it), and there is no bridge from pages to it. Case data sent into a terminal that runs an AI tool goes to that tool, so the same rules apply as for the other assistants.

**Letting an agent read and act on a page.** Satellite always runs a small local MCP (Model Context Protocol) server, so a command-line agent in a terminal — Claude Code, say — can read any page open in Satellite, and optionally click and type on the one in front, instead of you using Send to Assistant each time. It's on whenever Satellite is running; there's nothing to turn on. Six tools:

- `list_open_pages` — every page open in Satellite: each tab of each app (in rail order), each tab group (with whether it's loaded, and its tabs if so), and the web assistants, each page with a short id, its title and address, and which one is shown now. Apps you haven't opened yet are listed as not opened; listing or reading never loads them.
- `read_page` — reads any of those pages by its id: a background tab, another app's tab, or a web assistant, without switching to it (background pages keep running, so they read the same as the one in front). It returns the same Markdown snapshot Send to Assistant sends (URL, title, visible content following the **Text** setting in Settings > General).
- `read_active_page` — the same for the page shown now, plus a list of clickable elements with selectors for the two tools below; pass `app` for another app's current tab.
- `read_tab_group` — the same, for every page of a tab group at once (see Tab groups, above), so an agent can search across related pages. The group has to be loaded; `list_open_pages` lists every group with whether it is, and an agent asking for one that isn't is told to have you press **Load**.
- `click_element` / `type_text` — click an element, or replace a field's content and optionally press Enter, by a selector from `read_active_page`. Main frame only, and always the app shown now — unlike reading, acting on a page always needs you looking at it, so these don't take `app`.

Reading (`list_open_pages`, `read_page`, `read_active_page`, `read_tab_group`) and writing (`click_element`, `type_text`) are confirmed separately — allowing one never allows the other. The first time a given terminal's agent calls either kind, Satellite asks you to allow or deny it, with "Don't ask again for \<name\>": for reading, the same reasoning as sending a page to an assistant (pages can hold customer data, and not every agent is approved for it), and it says plainly that the agent can read every open page, not only the one in front; for writing, a stronger one, since once allowed an agent can click and type anywhere on the page without asking again, which can submit forms and change data, including in Salesforce. Allowing is remembered per terminal entry; add a new terminal (so it needs its own allow) rather than reusing one that's already trusted if you want to keep agents apart.

To connect Claude Code to it, point its MCP config at Satellite with `--mcp-stdio`:

    claude mcp add satellite -- /Applications/Satellite.app/Contents/MacOS/Satellite --mcp-stdio

or, in `.mcp.json`:

    { "mcpServers": { "satellite": { "command": "/Applications/Satellite.app/Contents/MacOS/Satellite", "args": ["--mcp-stdio"] } } }

`--mcp-stdio` only works while Satellite itself is already running (it relays to it over a Unix socket at `~/Library/Application Support/Satellite/mcp.sock`) and only answers with a real page from inside a Satellite terminal, which sets `SATELLITE_MCP_PANE_ID` for whatever it runs so the allow/deny above is asked per terminal entry, not once for every agent anywhere. Run from a `swift run` checkout, use `.build/debug/Satellite --mcp-stdio` instead of the path above.

`scripts/test-terminal.sh` checks all of this against your real login shell (without touching your clipboard). SwiftTerm's license is in `THIRD_PARTY_NOTICES.md`, which the bundled app includes.

## Security keys

Sites that ask for a hardware security key (FIDO2 / WebAuthn, such as a YubiKey) work for both sign-in and registration, including PIN entry and older U2F-only keys. macOS only allows WebAuthn in a web view for apps holding an Apple-issued browser entitlement, so Satellite talks to USB keys itself. Touch ID, iCloud Keychain and phone passkeys aren't available, and keys are used over USB only. **Settings > General** shows the keys it detects.

## Releases and updates

    scripts/release.sh 1.2.0

Run from a clean `main`, this pushes the tag `v1.2.0`. The **Release** workflow builds the app with that version and publishes a GitHub Release containing `Satellite-1.2.0.zip` and `appcast.json`.

The installed app reads `https://github.com/kcontreras-csm/satellite/releases/latest/download/appcast.json` after launch and every 24 hours (switch off under **Settings > General**), and from **Satellite > Check for Updates...**. If there is a newer version it offers to install: it downloads the zip, verifies the checksum, bundle identifier and signature, replaces itself and relaunches. Only an installed app updates itself, never a `swift run` build. Builds are ad-hoc signed, so macOS may ask again for camera, microphone or Keychain access after an update.

## Extensions

The [store repository](https://github.com/kcontreras-csm/satellite-extensions) lists extensions in an `extensions.json` that a GitHub Action regenerates from its folders. **Settings > Store** shows each one's author, permissions, pages and dependencies before you install it; dependencies install first, and installs are validated before they replace anything. See its `EXTENSIONS.md` for publishing and the full manifest reference. To try extensions from a local folder: `SATELLITE_STORE_DIR=../satellite-extensions swift run`.

**Installing from GitHub.** An extension that isn't in the store can be installed straight from a public github.com repository: **Install from GitHub...** in Settings > Extensions or Settings > Store. Paste a link to a repository, a folder in one (`https://github.com/owner/name/tree/main/my-extension`), a file in that folder, a release or a commit, or type `owner/name`, `owner/name/folder` or `owner/name/folder@branch`. Satellite reads which commit the branch or tag points at (from the refs git itself publishes, not the rate-limited GitHub API) and pins everything to it, so what you review is exactly what is installed even if someone pushes in between. A folder with a `manifest.json` is one extension; a folder with an `extensions.json` is a collection laid out like the store, and you pick one. Libraries an extension needs come from the same repository at the same commit (its collection's `extensions.json`, or a sibling folder named after the dependency), else from the store. The review shows the same permissions and pages as the store, where each piece comes from, and a warning that the code wasn't vetted; Install stays disabled until you confirm you've reviewed it or trust its source. The id is the manifest's `id`, or else the folder (or repository) name in lowercase. These extensions are tagged **GitHub**, record the repository, folder, commit and the branch you asked for, and get **Check for Update**, which looks that branch up again; the store never offers to replace them silently. Private repositories and GitHub Enterprise aren't supported. `scripts/test-github-install.sh` checks all of this against a local stand-in for GitHub.

To write an extension with an AI, open the page you want to change and use **View > Copy Page for AI** (`Shift+Cmd+C`, or the toolbar button; **Save Page for AI...** writes a file). The snapshot holds the page's HTML including shadow DOM and every frame, a list of clickable elements with selectors, the page's custom JavaScript globals, and a short guide to Satellite's extension format, so you can paste it into an AI together with what you want built. Pages often contain customer data, so by default only interface labels are kept and tokens in links are hidden; change this under **Settings > General**, and check the result before you share it.

**Sending to an assistant.** **View > Send to Assistant** (`Shift+Cmd+E`, also in the toolbar's Page for AI menu) puts the selected text, or the whole page when nothing is selected, into the message box of the assistant shown in the side panel. Right-clicking selected text offers **Ask Claude About This** (or whichever assistant is in the panel, with the others under **Ask Another Assistant**). Satellite never presses send: you read what it added and press Return. A selection goes in quoted, with the page's title and address; a page goes in as a snapshot written for an assistant (no extension guide), using the same text setting as Copy Page for AI, so by default only interface labels are kept. Satellite asks before sending to an assistant until you tick **Don't ask again** (or allow it under **Settings > General**), because pages can hold customer data and not every assistant is approved for it. If it can't find the assistant's message box (signed out, or the site changed), the text goes to the clipboard and Satellite says so.

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
    satellite.salesforce.query(soql)                // "salesforce": read-only SOQL as you, in the page's org

    satellite.ui.apps / satellite.ui.assistants     // "ui": the left rail and the right panel
      .list() .add({ id, name, url, symbol, badge, index }) .update(id, patch) .remove(id) .select(id)

    satellite.shortcuts                             // "shortcuts": keyboard shortcuts and menu commands
      .register({ id, title, shortcut: 'Cmd+Shift+K' }, handler) .unregister(id) .list() .onTrigger(callback)

    satellite.settings.get / getAll / set / register / onChange

    satellite.appearance.app / .page / .onChange(callback)   // light or dark (no permission needed)

`shortcuts.register` adds a command (up to 12 per extension) to the Extensions menu and to Settings > Shortcuts, and resolves with `{ id, title, shortcut, requested, conflict, customized }`: `shortcut` is what it has now and is `null` when another command already has the one it asked for (`conflict` names that command) or the user removed it. Registering again with the same id updates it and keeps the user's choice. When the shortcut is pressed the handler runs in the page in front (if the extension runs on it) and in the extension's background script, so register from the script that should react. `ui` can add up to 8 items per list and change built-in ones (hide, rename, badge). Those changes last only while the extension is on. `settings` are declared in the manifest, shown under the slider icon in **Settings > Extensions**, and typed as `string`, `number`, `boolean` or `choice`. Toggling an extension takes effect on the next page load. `appearance.app` is `'light'` or `'dark'`: Satellite's appearance (**Settings > General > Appearance**: System, Light or Dark), which pages also see as `prefers-color-scheme`, so `@media (prefers-color-scheme: dark)` in an extension's CSS follows it too. `appearance.page` is how the page itself looks, which can differ: claude.ai and Slack have their own theme setting, and a site without a dark mode, like Salesforce, stays light in a dark Satellite. It is read from the page's background and declared color scheme, so UI an extension adds to a page should follow `page`. `onChange` is called with `{ app, page }` whenever either changes. `salesforce.query(soql)` resolves with the REST API's `{ totalSize, done, records }` for the org of the page (`orgcs.lightning.force.com` queries `orgcs.my.salesforce.com`), signed in with your Salesforce session inside Satellite; the session itself never reaches the page, and only read-only queries are offered.
