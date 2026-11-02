# 5. Search inside documents

Status: implemented on `codex/content-search`. See README for behavior and limits.

## Outcome and scope

Find library files by their contents and show a short matching excerpt. Version one supports text and searchable PDFs; scanned-PDF OCR and remote web-page indexing are deferred. Inspired by [HoudahSpot’s content search and matching text previews](https://www.houdah.com/houdahSpot/index.html).

Add a search mode: Metadata, Document Contents, or Both. The default remains Metadata. Results must remain restricted to entries already in the library and the current collection/tag/smart scope.

## Design and integration

Introduce an asynchronous `ContentSearchService` returning entry IDs, match state, and optional excerpts. Prototype Spotlight via [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) against candidate library files. Never expose unrelated disk results. Account for excluded volumes, disabled indexing, stale paths, and Spotlight results arriving after cancellation.

Use bounded direct extraction for supported text/PDF files when Spotlight cannot provide sufficient coverage or snippets. Prototype PDFKit extraction before committing to thresholds. Run extraction off the UI thread with bounded concurrency, byte/page limits, cancellation, and a clear “not searched” status for skipped or inaccessible files.

Cache extracted text locally by stable file identity and modification metadata, under an application cache directory rather than `library.json`. Cap cache size; invalidate on changes and reference removal. Provide Clear Search Cache. Do not force cloud-file downloads or persist extracted content in portable exports.

## Implementation sequence

1. Prototype Spotlight coverage, latency, and supported extraction on sanitized fixtures.
2. Define result states: searching, matched, no match, unavailable, and skipped.
3. Add cancellation/debouncing, generation IDs, bounded extraction/cache, and search-mode controls.
4. Combine document matches with metadata filters and expose readable matching excerpts.

Metadata and document matching use OR in Both mode; scope and tag predicates still use AND against that combined result. Retain stable result ordering while asynchronous matches arrive. Smart collection content predicates are a later extension, not a hidden expansion of plan 1.

## Acceptance and validation

- A phrase found only inside a supported PDF/text file locates the correct entry.
- Rapid queries, edits, and scope changes never publish stale results.
- Unindexed or partially searched libraries show coverage limitations instead of claiming complete results.
- Test Unicode, encoding failures, binary files, huge PDFs, cancellation, changed files, and inaccessible volumes.
- Verify cache eviction and deletion, snippet highlighting, and zero network access.

The first milestone is a coverage/latency prototype. Do not promise reliable full-library search until that experiment establishes a suitable backend strategy.

## Implementation validation

Implemented independently from main `f45f88e`. 62 tests pass; release app build and signature verification pass. Native UI found and highlighted a query present only in a text document. Spotlight prototype returned started=false and no results in this environment, so bounded direct text/PDF extraction is the shipped backend. Generated searchable PDFs, cancellation, cache invalidation, and eviction are tested. Cloud providers require device testing.
