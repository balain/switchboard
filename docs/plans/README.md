# Feature implementation plans

Status: plans 1–8 are implemented. See the individual plans for scope and validation.

These plans target the current SwiftUI/AppKit application on macOS 14.4+, using system frameworks and local storage. Suggested types and files are implementation targets, not existing interfaces.

| Original suggestion | Plan | Recommended order | Dependencies |
| --- | --- | --- | --- |
| 1 | [Smart collections](01-smart-collections.md) | 3 | Shared filter evaluation; backup checkpoint before schema changes |
| 2 | [Global quick launcher](02-quick-launcher.md) | 4 | Shared search evaluation; smart collection integration can follow |
| 3 | [Bulk organization and Undo](03-bulk-organization.md) | 2 | Transaction boundary established in plan 6 |
| 4 | [Library health check](04-library-health.md) | 5 | Bulk transaction/Undo for repairs |
| 5 | [Document content search](05-content-search.md) | 7 | Shared search evaluation and asynchronous result handling |
| 6 | [Import, export, and local backups](06-import-export-backups.md) | 1 | None; deliver backups before import |
| 7 | [Organization rules](07-organization-rules.md) | 6 | Shared predicates, bulk transaction/Undo, import event handling |
| 8 | [Minimal-mode icon bloom](08-minimal-icon-bloom.md) | Independent UI track | Thumbnail layout and hover behavior review |

## Shared implementation decisions

- Preserve existing `library.json` data. New fields need decoding defaults and legacy fixtures. Keep the current refusal to overwrite an unreadable library.
- Refactor `LibraryStore.save()` to report success before building operations that promise atomic application, restore, or Undo. Stage mutations in a candidate value, validate and persist it, then publish once. Failed writes must leave the prior in-memory and on-disk state intact.
- Keep bookmarks local. Export portable paths and URLs by default; exact local backups may retain bookmark data. Do not rename, move, or delete original files as part of organization.
- Share filter predicates across regular search, smart collections, the launcher, and rules. Keep pure evaluation separate from asynchronous document search and health scans.
- Keep transient scanning, animation, and launcher state out of the library file. Save user preferences separately, following `LibraryWindowState` and `@AppStorage` conventions.
- Network activity must be explicit. Remote URL checks are user initiated; local document search, rules, and backups operate locally.
- Use entry/tag/collection UUIDs for references. Define deletion and restoration behavior for every new persisted reference.
- Ship each feature separately. Complete a feature’s acceptance checks before moving to dependent features.

## Validation required for implementation

Run the existing XCTest suite plus focused behavior tests, then `./scripts/build-app.sh`. Use temporary libraries, isolated preferences, fake file services, and mocked HTTP responses. Visually check changed controls in Minimal and normal modes, supported display formats, small windows, and Light/Dark/System appearance. No build is required for these planning documents alone.

## Product references

- [Anybox: Smart Lists, Quick Find, capture, and export](https://anybox.app/getting-started)
- [DEVONthink: smart groups and rules](https://www.devontechnologies.com/products/devonthink/)
- [DEVONthink: batch processing](https://www.devontechnologies.com/apps/devonthink/editions)
- [Raindrop.io: import/export, backups, and duplicate/broken-link detection](https://raindrop.io/pro/buy)
- [HoudahSpot: content search and matching text previews](https://www.houdah.com/houdahSpot/index.html)

These products inform the proposed interactions; their storage and networking models are not requirements for Switchboard.

## Combined integration validation

Plans 1, 2, and 3 are merged into local main alongside plan 8. The combined XCTest suite passes 57 tests. Four integration tests verify that bulk Undo/Redo updates smart collection matches and launcher results, failed smart-collection saves preserve bulk history and persisted filters, launcher reveals leave smart scopes without losing selection, and deleting a referenced tag keeps saved criteria unavailable through unrelated Undo. Smart-collection writes use the shared transactional persistence path. Each feature’s documented manual release checks still apply.
