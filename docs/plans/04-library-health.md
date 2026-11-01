# 4. Library health check

## Outcome and scope

Show missing local references, temporarily unavailable volumes, duplicate references, and optionally broken web links in a reviewable report. Users repair or remove selected references; scans never remove entries automatically. Inspired by [Raindrop.io’s duplicate and broken-link finder](https://raindrop.io/pro/buy).

Version one detects duplicate standardized file references and exact normalized web addresses. Content hashing and aggressive URL rewriting are deferred; query parameters may be meaningful.

## Design and integration

Add an asynchronous `LibraryHealthScanner` with injected file/volume and HTTP clients. Capture entry IDs and relevant locations at scan start; discard stale findings when those values change. Keep findings transient, with scan time and a summary.

Separate bookmark resolution from `LibraryStore.resolve`’s current mutation behavior. Scanning must not rewrite the library. Distinguish missing, permission-denied, unavailable-volume, cloud-placeholder/unknown, and reachable states; do not force cloud downloads to establish health.

Remote checks require an explicit “Check Web Links” action. Use bounded concurrency, timeout, redirect limits, a temporary cookie-free session, cancellation, and HEAD followed by a bounded GET only when necessary. Treat authentication, rate limiting, and transient server failures separately from likely permanent failure. Do not persist response bodies or credentials.

## Implementation sequence

1. Implement local status classification and conservative duplicate grouping.
2. Build a health report sheet with filters, progress, cancellation, and last-check timestamps.
3. Add Locate Replacement and duplicate review. Replacement updates location/bookmark while preserving entry UUID and metadata; revalidate before committing.
4. Add opt-in web checks and staged repair/remove actions through the bulk Undo pipeline.

Duplicate merging must preview metadata conflicts. Prefer retaining all entries until the user chooses a survivor and confirms how notes, tags, favorites, and collection membership are handled.

## Acceptance and validation

- An unmounted external drive is reported unavailable, not as a batch of deleted files.
- Permission errors and cloud placeholders are not mislabeled permanently missing.
- Scans can be cancelled and do not block typing, previewing, or opening other entries.
- Mock redirects, TLS failures, timeouts, 404/410, 401/403, 429, and HEAD rejection.
- Repairs preserve metadata, recheck stale findings, and support Undo; no action deletes an original file.
- No web request occurs during a local-only scan or automatically at launch.

Deliver local scanning before remote checks. Reliable status classification is more valuable than a single simplistic broken/not-broken flag.
