# Satellite extensions

The extension store for [Satellite](https://github.com/kcontreras-csm/satellite). **Settings > Store** lists the extensions named in [extensions.json](extensions.json) and installs them from their folders.

Satellite reads this repository as plain files (no GitHub API, no token), so a folder that isn't listed in `extensions.json` is simply ignored. Drafts can live here unpublished.

## Publishing an extension

1. Create a folder named after the extension id: lowercase letters, digits, `.`, `-`, `_` (for example `case-helper`).
2. Add a `manifest.json` and your files (see below).
3. Add it to `extensions.json`: `{ "id": "case-helper" }`.
4. Commit and push to the default branch. Satellite picks it up the next time someone opens the Store (or presses refresh).
5. **To release an update, bump `version`** in the extension's `manifest.json`. Satellite shows "Update" when the store's version is higher than the installed one.

## extensions.json

```json
{
  "version": 1,
  "extensions": [
    { "id": "case-helper" },
    { "id": "shared-utils" },
    { "id": "from-elsewhere", "repository": "someone/their-repo", "ref": "v1.2.0", "path": "extensions/from-elsewhere" }
  ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | The extension id. It must match the `id` in the manifest, if the manifest has one. |
| `path` | no | The folder that holds `manifest.json`. Defaults to the id. |
| `repository` | no | `owner/name` of another GitHub repository. Defaults to this one. |
| `ref` | no | Branch, tag or commit to read. Defaults to this repository's default branch. **Pin a tag or commit to install exactly that version:** a branch moves whenever someone pushes. |

Satellite downloads `manifest.json` and only the files it names (`js`, `css`, `background`, and the `icon` file). Anything else in the folder is not installed.

## manifest.json

```json
{
  "name": "Case Helper",
  "version": "1.2.0",
  "author": { "name": "Jane Doe", "email": "jane@example.com", "url": "https://example.com" },
  "description": "One or two sentences on what it does.",
  "icon": "icon.png",
  "category": "Productivity",
  "keywords": ["cases", "productivity"],
  "homepage": "https://example.com/case-helper",
  "license": "MIT",

  "dependencies": { "shared-utils": "^1.0.0" },
  "min_app_version": "0.1.0",
  "permissions": ["storage"],

  "matches": ["*://*.force.com/*"],
  "exclude_matches": [],
  "js": ["content.js"],
  "css": ["style.css"],
  "run_at": "document_idle",
  "all_frames": false,
  "world": "isolated"
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `name`, `version`, `author`, `description` | yes | `version` is `major.minor.patch`. `author` is a string or `{ name, email, url }`. |
| `icon` | no | A `.png`, `.jpg` or `.svg` file in the folder, or `symbol:<SF Symbol name>`. Without one, Satellite draws a colored tile with the first letter of the name. |
| `category`, `keywords`, `homepage`, `license` | no | Used for search and the detail page. |
| `type` | no | `content-script` (default) or `library`. A library has no `matches`; other extensions load it. |
| `dependencies` | no | `{ "<extension id>": "<range>" }` on **libraries**. Ranges: `1.2.3`, `^1.2.3`, `~1.2.3`, `>=1.2.0 <2.0.0`, `*`. Installing an extension installs its dependencies first. |
| `min_app_version` | no | Oldest Satellite that can run it. |
| `permissions` | no | What the `satellite` API may do: `storage`, `notifications`, `open-external`, `ui` (change the sidebar and assistants panel). Shown to the user before installing; calls that aren't declared are rejected. |
| `matches` | with `js`/`css` | Chrome match patterns, e.g. `*://*.salesforce.com/*`, `<all_urls>`. |
| `js`, `css` | with `matches` | Paths inside the folder. A content script needs `matches` and at least one of these, unless it has a `background` script. |
| `background` | no | A script that runs once when Satellite starts, with no page needed. Needs the isolated world. Listed on the install screen. |
| `settings` | no | Options the user can edit under Settings > Extensions: `{ key, type (string, number, boolean, choice), title, description, default, placeholder, options, min, max }`. Read them with `satellite.settings`. |
| `run_at` | no | `document_start`, `document_end` (default), `document_idle`. |
| `world` | no | `isolated` (default: DOM + `satellite` API) or `main` (page JavaScript, no API). |

### Libraries

A library's `index.js` is run as a module: assign to `module.exports`. A dependent extension calls `require('<library id>')`. A library runs with its dependents' `satellite` API and permissions.

See `shared-utils` (a library), `hello-badge` (an extension that uses it) and `quick-link` (a background script that adds a sidebar item and registers settings). The `satellite.ui` and `satellite.settings` APIs are documented in the Satellite README.

## Limits

At most 200 extensions in `extensions.json`, 2 MB per file and 10 MB per extension. Symlinks are not followed.
