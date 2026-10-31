# Contributing to Switchboard

Bug reports, documentation improvements, and focused pull requests are welcome. Keep discussions professional and respectful. For substantial features or changes to stored data, open an issue to discuss the approach before implementation.

## Development setup

Use macOS 14.4 or later with Xcode 16.4 or a newer compatible Xcode installation and a Swift 6 toolchain. The release workflow currently uses Xcode 16.4. Switchboard uses Apple's frameworks and has no third-party package dependencies.

Fork the repository, clone your fork, and create a branch for your change. From the repository root:

```sh
./scripts/build-app.sh
open dist/Switchboard.app
```

Alternatively, open `Package.swift` in Xcode and run the Switchboard scheme. Development builds use the same library and preferences as the installed app, so back up your library before testing changes to persistence or collection management. Its location is documented in the [README](README.md#saving-and-previews).

## Project layout

- `Sources/Switchboard/`: SwiftUI interface, AppKit integration, models, persistence, previews, and URL-title fetching.
- `Tests/SwitchboardTests/`: XCTest coverage for library behavior, compatibility, view settings, previews, and URL handling.
- `Resources/`: app icons and their source representations.
- `scripts/`: app packaging and icon generation.
- `.github/workflows/release.yml`: tested Apple silicon and Intel builds for version tags.

## Implementation guidelines

- Follow the surrounding Swift style and keep changes focused. Prefer native SwiftUI, AppKit, and other system frameworks; discuss new dependencies first.
- Preserve macOS 14.4 compatibility. Guard APIs that require a later system version.
- Keep original files and folders untouched when organizing or removing library entries.
- Keep existing libraries readable when adding stored fields. Add decoding defaults or optional fields where appropriate, and preserve protection against overwriting an unreadable library.
- Keep persistence local and network activity explicit. The Add URL dialog currently fetches clipboard URL titles without rendering pages, executing scripts, or using stored cookies and credentials.
- Keep file previews bounded and asynchronous. Preserve cancellation, icon fallbacks, accessibility labels, keyboard commands, and selection behavior where relevant.
- Use temporary files, isolated preferences, and mocked network responses in tests. Do not rely on a contributor's personal library or live websites.

## Validation

Run the test suite from the repository root:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build-cache/clang" \
SWIFT_MODULECACHE_PATH="$PWD/.build-cache/swift" \
swift test --disable-sandbox --cache-path .build-cache
```

Run `./scripts/build-app.sh` for changes affecting the app or packaging. Add or update meaningful tests for changed behavior, especially saved-data compatibility, collection hierarchy, filtering, and restoration. Documentation-only changes do not require rebuilding the app.

For interface changes, also run the app and check the affected display formats, window sizes, Light/Dark/System appearance, and Minimal mode. Check hover panels, context menus, selection, and opening behavior when your change touches those interactions. Use sanitized sample items for screenshots.

## Issues and pull requests

For a bug report, include the macOS version, app version or commit, steps to reproduce, expected behavior, and actual behavior. Attach a minimal sample file or screenshot when useful, after removing personal information.

A pull request should explain the problem, resulting behavior, and validation performed. Include screenshots for visible interface changes and update the README when commands or user-facing behavior change. Identify any compatibility limitations or checks you could not run.

Do not commit personal library exports, bookmarks, credentials, signing files, machine-specific settings, or build outputs. Keep sample URLs and file paths generic. For security issues, use GitHub's private vulnerability reporting option if enabled; do not publish credentials or private user data in an issue.

## Releases and licensing

Maintainers publish releases using version tags as described in the [release instructions](README.md#tagged-releases). Contributors should not create release tags as part of a normal pull request.

Switchboard is distributed under the [MIT License](LICENSE). Include appropriate attribution and compatible licenses for any third-party code or assets you propose adding. The app build includes the project's license in the application bundle.
