# 6. Import, export, and automatic local backups

Status: implemented on `codex/library-portability`. See README for behavior and limits.

## Outcome and scope

Move data into/out of Switchboard and recover from accidental edits without manually locating `library.json`. Provide portable JSON and bookmark HTML import/export, CSV export, exact local backup, and restore. CSV import is deferred until a column-mapping UI is justified. Inspired by [Raindrop.io import/export and backups](https://raindrop.io/pro/buy).

## Foundation and storage

Introduce a versioned portable envelope separate from the internal library schema. Portable exports include names, paths/URLs, tags, collections, favorites, notes, and dates; omit bookmark blobs and machine-specific preferences. Local file paths can still reveal private information, so explain what an export contains. Smart filters/rules join the format only when implemented, with versioned decoding.

Refactor `LibraryStore` persistence into a transactional write path: construct a candidate, validate references, encode/write atomically, then publish. Return errors rather than only setting an alert. Establish an injectable repository and clock so failed writes and backup timing can be tested. Preserve the existing unreadable-library guard.

Keep exact backups locally in a dedicated application-support directory. Proposed retention: one per day for 30 days plus a pre-import/pre-restore checkpoint. Rotate only after a new backup succeeds. Snapshot the previous valid persisted state before destructive replacement; never back up an unreadable file as a verified good library.

## Implementation sequence

1. Deliver transactional persistence, Backup Now, retention, and validated restore first.
2. Add portable JSON/HTML/CSV exporters using standard escaping and quoted fields.
3. Add JSON/bookmark HTML parsers with size limits and an import preview; imported markup is data, never executed.
4. Add conflict review and a single transactional merge; follow with automatic daily backup checks on app activity/save.

Normalize duplicate addresses conservatively. Remap colliding UUIDs; remap collection/tag references consistently; validate hierarchy cycles. Reacquire local-file bookmarks through user-selected locations when required. Imported names do not rename files. Future rules must not run during restore; import rules require explicit opt-in.

Restore validates the entire backup before replacing anything, creates a checkpoint, clears incompatible Undo history/caches, and revalidates window selections. Failed backup, import, or restore leaves the existing library intact. Unsupported future versions produce a clear error.

## Acceptance and validation

- Round-trip Unicode, nested collections, tag metadata, notes with commas/newlines, and missing paths.
- Legacy libraries still load; invalid or future-version imports do not modify data.
- Test interrupted/failed writes, malformed HTML/JSON, ID conflicts, cycles, backup rotation, and clock changes.
- Restore recovers a known checkpoint and never changes original files.
- Inspect exports to confirm bookmark blobs/preferences are absent; exact backups retain needed local state.

Ship this foundation before other plans introduce new persisted schemas or bulk mutations.

## Implementation validation

Implemented independently from main `f45f88e`. 66 tests pass; release app build and signature verification pass. Native UI created a manual backup, displayed a concrete JSON import preview, and applied it successfully. Tests cover round trips, malformed input, retention, restore recovery, collisions, and failed writes. The optional import-rule hook is ready for feature 7; its UI stays disabled on this independent branch until a processor is available.
