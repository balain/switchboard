# Switchboard

A native macOS library for files, folders, and URLs. Built with SwiftUI and AppKit, without third-party dependencies. Requires macOS 14.4 or later.

## Run

```sh
./scripts/build-app.sh
open dist/Switchboard.app
```

You can also open `Package.swift` in Xcode and run the Switchboard scheme.

## Features

- Small, medium, and large cards; compact and comfortable lists; configurable table columns.
- Thumbnails displays file previews or icons without labels; names and details appear on hover. Configure Current View adjusts the saved size from 48–160 points (default 80). Minimal mode remains independent.
- Per-view visible fields, five accent palettes, installed font families, and 10–24 pt text for card/list/table displays; a separate size setting for thumbnails. Each view can be reset to its defaults.
- View → Appearance selects System, Light, or Dark; the choice is saved across launches.
- Files and folders through the native picker, and file/URL drag and drop.
- URL validation, duplicate prevention, collections, favorites, tags, and notes.
- Search names, locations, tags, and notes; sort by name, kind, or newest.
- Entry inspector, multiselection (Command-click cards), and context menus.
- Hover over cards, list rows, or table rows for item details; small cards size to their visible content.
- File hover popups include a text excerpt or a Quick Look content thumbnail for supported images and documents, with details retained when a preview is unavailable.
- View → Minimal hides the window toolbar, library heading and subtitle, and status bars; the setting is remembered.
- System menus provide display formats, filters, sorting, view configuration, sidebar/details visibility, and search (Command-F).
- File → Manage Collections opens a dialog for adding, renaming, nesting, coloring, and deleting collections and choosing icons.
- View → Hierarchical Collections browses collections as folders. Flat mode shows all items in the selected collection and its descendants together.
- Search filters immediately and offers matching items below the search field; choosing a suggestion opens the item directly.
- Add URL checks the clipboard for a web address, fetches its HTML title, and offers to fill the URL and display name before adding it.
- View → Open Items With selects single-click or double-click opening. Command-click and Shift-click retain selection without opening.
- Relaunch restores the active collection/filter, search text, selected items, and sidebar/details visibility alongside saved display settings. Deleted items and collections are discarded from restored selections.
- Open with the default app, reveal in Finder, and copy locations.
- Atomic local persistence at `~/Library/Application Support/Switchboard/library.json`.
- File bookmarks resolve references after moves when macOS can locate the original item.

This is a reference library: display names and collections do not rename or move original files. Removing entries never deletes original files. Opening Add URL fetches a clipboard web address to suggest its page title, using a temporary session without stored cookies or credentials. This lookup does not execute scripts or load page resources. The app sends no telemetry. Opening a saved URL launches your default browser.

## Menus and controls

The toolbar provides adding entries, choosing a display format, configuring the current view, toggling the details panel, and searching. Equivalent commands are available in the macOS menu bar, including when Minimal mode hides the toolbar.

| Menu | Commands |
| --- | --- |
| File | Add Files and Folders… (Command-O), Add URL…, Manage Collections… |
| View | Show/Hide Sidebar, Minimal, Show Details Panel, Display Format, Configure Current View…, Appearance, Filter, Sort By, Hierarchical Collections, Open Items With |
| Edit | Search Library… (Command-F), Clear Search |

**Filter** selects all entries, favorites, files, folders, URLs, or a specific collection. **Sort By** offers name, newest first, or kind. **Appearance** offers System, Light, or Dark.

**Configure Current View** saves changes immediately. For cards, lists, and tables, Name remains visible while Kind, Location, Tags, Notes, and Date added can be hidden. Thumbnails hide these labels and instead offer a size slider in 8-point steps. Table column widths can be adjusted by dragging their header boundaries. **Reset This View** resets the current display's configuration.

Single-click or double-click opening applies to entries in every display format. Command-click supports card/thumbnail multiselection; Command-click and Shift-click do not open entries. Right-click an item for opening, revealing in Finder, copying its location, changing favorite status, moving between collections, or removing it from the library. Hover panels dismiss when you click, scroll, type, or open a menu.

## Collections

Open **File → Manage Collections…** or **Manage collections…** in the sidebar to add, rename, delete, or choose a collection's icon, background color, and parent collection. Save edits with **Save Changes** or **Done**; changing the selected collection also saves the previous collection's edits. Nesting cycles are prevented.

With **Hierarchical Collections** enabled, All Entries shows top-level collections as folders alongside unassigned entries. Opening a collection shows its direct entries and subcollections; **Back** returns to its parent. With hierarchical display disabled, All Entries shows every item, and selecting a collection shows its entries and all descendant collections' entries together. Collections can also be selected through the sidebar or **View → Filter**.

An entry belongs to at most one collection. Its **Move to Collection** context menu omits the current collection and offers **Remove from Collection** when assigned. Deleting a collection keeps its entries in the library and moves its subcollections up to the deleted collection's parent.

## Search and URL entry

Search filters names, locations, tags, and notes as you type within the active filter or collection. Searching a collection also includes its descendants, even in hierarchical mode. The dropdown shows up to 12 matching items; selecting one opens it directly. **Command-F** focuses search and leaves Minimal mode if necessary to reveal the search field. **Clear Search** removes the query.

Opening **Add URL** checks the clipboard for a single web address. If present, the app fetches its HTML title and offers **Use Clipboard Details** to fill the URL and display name. Fields remain editable, and nothing is added until you select **Add URL**. You can dismiss the suggestion; when a title cannot be retrieved, **Use Clipboard URL** and manual naming remain available.

## Saving and previews

In the details panel, **Save Details** saves the display name, URL, tags, and notes. The display name, URL, and tags fields also save on Return; changing collection or favorite status saves the current details. Tags are comma-separated and duplicates are removed.

Hover over a thumbnail, card, list row, or table row for its name, location, kind, collection, tags, notes, and date added. File popups additionally show a short text excerpt or a Quick Look thumbnail when supported. Thumbnail display uses file previews with file-icon fallbacks; folders and URLs use icons.

Library entries, collections, display format, sorting, appearance, and per-view configurations save locally in `~/Library/Application Support/Switchboard/library.json`. Active filters, search text, selection, panel visibility, Minimal mode, hierarchical display, and click behavior are restored using macOS preferences. Temporary dialogs do not reopen on launch. If the saved library cannot be read, the app reports the problem and disables saving to protect the existing file.

## Validation

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang" \
SWIFT_MODULECACHE_PATH="$PWD/.build-cache/swift" \
swift test --disable-sandbox --cache-path .build-cache
```

Tests cover URL validation and HTML-title fetching, response-size limits, text-file previews, bookmarks, search and sorting, deduplication, persistence and unreadable-library protection, thumbnail sizing, restored view state, legacy settings, flat/hierarchical filtering, nesting cycle prevention, and safe collection removal. Fetch tests use mocked responses rather than live websites.

The build script produces a locally ad-hoc-signed app; distribution to other Macs requires a Developer ID signing/notarization workflow. `.gitignore` covers common build outputs, machine-specific settings, signing files, and personal library exports.

## Tagged releases

`.github/workflows/release.yml` builds and tests the tagged source on Apple silicon and Intel macOS runners, then publishes a GitHub Release containing a ZIP of `Switchboard.app` for each architecture and SHA-256 checksums. Both builds must pass before publishing.

Commit and push the workflow and build-script changes before creating a tag. In the repository's **Settings → Actions → General**, ensure GitHub Actions and the official `actions/checkout`, `actions/upload-artifact`, and `actions/download-artifact` actions are allowed. The workflow grants release publishing permission to the built-in `GITHUB_TOKEN`; no personal access token or repository secrets are needed for these ad-hoc-signed builds.

Create and push a version tag on the commit you want to release:

```sh
git tag -a v1.0.1 -m "Switchboard 1.0.1"
git push gh v1.0.1
```

`gh` is this checkout's remote name; use your remote's name (commonly `origin`) if different. Follow progress in the repository's **Actions** tab; completed downloads appear under **Releases**. Tags use `vMAJOR.MINOR.PATCH`; tags such as `v1.0.1-beta.1` create prereleases. The numeric portion sets the app version, and the workflow run number sets the build number. For a local versioned build, run `APP_VERSION=1.0.1 APP_BUILD_NUMBER=2 ./scripts/build-app.sh`.

Downloads are named `Switchboard-v1.0.1-macOS-arm64.zip` for Apple silicon and `Switchboard-v1.0.1-macOS-x86_64.zip` for Intel. Extract the ZIP and move `Switchboard.app` to Applications. Releases retain the macOS 14.4 minimum requirement. These builds are ad-hoc signed, without Developer ID signing or Apple notarization, so downloaded apps may be blocked by Gatekeeper. Notarized public distribution requires a separate Apple Developer signing setup.

Re-running a failed workflow can replace assets on an existing mutable release; immutable releases require a new version tag for changed binaries. Tags pointing to commits without this workflow do not trigger these builds.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, implementation guidelines, validation, and pull request expectations.

## License

Switchboard is licensed under the [MIT License](LICENSE). The license is also included in built application bundles.
