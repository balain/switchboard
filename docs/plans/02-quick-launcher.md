# 2. Global quick launcher

Status: implemented in the `codex/quick-launcher` worktree. Includes focused regression coverage and legacy behavior checks.

## Outcome and scope

A configurable global shortcut opens a small search panel over the current application. Type a name, navigate with arrow keys, and press Return to open a file, folder, or URL. Escape dismisses the panel and returns focus to the previous app. Inspired by [Anybox Quick Find](https://anybox.app/getting-started#easy-out).

Version one searches entry names, tags, notes, and locations. It offers Open, Reveal in Finder, Copy Location, and Show in Switchboard. Document-content matching can be added after plan 5. No background clipboard monitoring or text-expansion feature is included.

## Design and integration

Add a launcher coordinator and AppKit `NSPanel` hosting a SwiftUI result list. Keep one panel per application, outside `WindowGroup`, observing the same `LibraryStore`. It must work when ordinary windows are closed while the application remains running.

Add a shortcut service with a replaceable backend. Prototype a public system hotkey registration API supported by the deployment target; verify shortcut conflicts, keyboard layouts, registration failure, and cleanup before choosing the final backend. Avoid global keyboard event interception. Provide a menu command when registration fails, with a clear user-facing explanation.

Reuse shared predicate/search evaluation. Search the whole library by default, independently of a window’s active scope. Rank exact names, name prefixes, name substrings, then other metadata; use stable name ordering as a tie-breaker. Cap visible results and preserve selection by entry UUID during updates.

## Implementation sequence

1. Extract and test ranked metadata search with bounded results.
2. Implement panel lifecycle, focus restoration, keyboard navigation, and result actions.
3. Add shortcut configuration, conflict/error reporting, and application lifecycle integration.
4. Integrate Show in Switchboard so it reveals the entry even when current filters exclude it.

Keep preferences local: enablement, shortcut, and optional panel position. Opening a file still uses `LibraryStore.resolve/open`; opening a URL retains the existing default-browser behavior. Closing a panel must not quit the app or discard a main-window draft.

## Acceptance and validation

- Repeated shortcut presses consistently show/toggle one panel without duplicate windows.
- Escape, Return, arrows, and action shortcuts work without opening an unintended entry.
- Check activation from other apps, multiple displays, full-screen Spaces, app hiding, and no main window.
- Test concurrent deletion/rename, missing files, empty results, and shortcut-registration failure with fakes.
- Measure metadata query latency on a synthetic 10,000-entry library; target visible results within 100 ms on documented test hardware.

API selection and panel activation behavior need an early prototype. Confirm current Apple documentation during implementation.

## Implementation validation

The branch has 40 passing XCTest cases and builds a signed release app. Verified the search panel, ranked results, Show in Switchboard, reopening a closed library window, shortcut settings, and successful system hotkey registration using an isolated sample library. Actual hardware hotkey dispatch from another app, full-screen Spaces, and multiple physical displays remain manual release checks; targeted UI automation did not trigger the system-wide hotkey.
