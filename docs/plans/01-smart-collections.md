# 1. Smart collections

Status: implemented in the `codex/smart-collections` worktree. Includes focused regression coverage and legacy behavior checks.

## Outcome and scope

Save a combination of filters as a named, automatically updating collection. For example, “Class PDFs” can match file entries ending in `.pdf`, tagged “Bible Class,” within a chosen collection and its descendants. Smart collections reference entries; they do not change physical collection membership.

Version one supports text query, kind, favorite status, tag IDs with any/all matching, optional physical collection scope, and added-date criteria. Exclude nested smart collections and arbitrary Boolean expression editors. Inspired by [Anybox Smart Lists](https://anybox.app/getting-started#smart-list).

## Design and integration

Add `SavedFilter` and a Codable `EntryPredicate` model in `Models.swift`, with UUID, name, criteria, optional icon/palette, and optional preferred sort. Add a default-empty saved-filter array to `LibraryData` decoding. Extract pure predicate evaluation from `LibraryLogic.scopedEntries` into a shared evaluator without changing current collection hierarchy behavior.

Extend `LibraryWindowState` with a validated smart collection selection, using a distinct scope representation rather than treating its UUID as a physical collection. `ContentView.collectionID` must return nil for smart scopes, so adding an entry never assigns a smart collection as its parent. Explicitly explain that adding from a smart view does not guarantee the new entry matches it.

Expose “Save Current Filters…” and a Smart Collections section/menu with edit, duplicate, and delete actions. Saved criteria define the base result; current search and tag filters narrow it further. Relative dates use the user’s calendar/time zone and refresh at day boundaries and app activation. New entries appear immediately when they match.

## Implementation sequence

1. Establish predicate fixtures covering existing scopes; extract the evaluator.
2. Add persistence, default decoding, store CRUD, and reference validation.
3. Build a compact filter editor showing a live match count and a criteria summary.
4. Add sidebar/menu selection, saved-scope restoration, and explicit filter reset behavior.

Deleting a referenced tag/collection marks affected criteria unavailable and returns no matches until repaired; never silently broaden results. Renames follow UUIDs. Removing a smart collection keeps its entries.

## Acceptance and validation

- Saved filters survive relaunch and update after tag, favorite, membership, and date changes.
- Relative dates behave across midnight, daylight-saving changes, and app sleep.
- Missing references are visible and repairable; invalid restored scopes fall back safely.
- Existing flat/hierarchical search tests pass unchanged; smart scopes never leak into entry collection IDs.
- Check empty results, live counts, duplicate names, keyboard selection, and Minimal-mode menu access.

Deliver after the backup foundation; the date evaluator and typed scope changes are the principal implementation risks.

## Implementation validation

The branch has 38 passing XCTest cases and builds a signed release app. Verified saving a tag condition, the live match count, selecting a saved collection, restoration on relaunch, and the corrected editor layout using an isolated sample library.
