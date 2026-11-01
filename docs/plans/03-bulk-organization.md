# 3. Bulk organization and Undo

## Outcome and scope

Apply tags, favorites, or collection membership to selected entries in one action. Undo and Redo reverse an entire bulk action, including removal from the library. Original files stay untouched. Inspired by [DEVONthink batch processing](https://www.devontechnologies.com/apps/devonthink/editions).

Provide additive and subtractive tag actions rather than a replacement text field that could erase differing tags. Favorite actions are explicitly “Mark Favorite” and “Remove Favorite.” A collection action sets one physical collection or clears membership.

## Design and integration

Build on the candidate-state persistence transaction from plan 6. Introduce `LibraryMutation`/`EntryPatch` values describing changed fields and before/after values. Resolve IDs against the current store when applying; skip deleted entries and report the affected count.

Register one grouped operation with the app’s Undo architecture per successful mutation. Use a shared library history, or explicitly reconcile per-window histories, so two windows cannot blindly restore stale whole-library snapshots. Route library Undo through the responder chain without replacing text-field editing Undo. Reference [Apple UndoManager](https://developer.apple.com/documentation/foundation/undomanager).

Use field-level patches so Undo does not overwrite later unrelated edits. Before applying an inverse patch, verify its expected current value; reject or explain conflicts rather than silently restoring stale state. Clear incompatible history after library restore/replacement. Add descriptive menu labels such as “Undo Add Tags.”

## Implementation sequence

1. Add transactional patch application, persistence failure handling, and inverse generation.
2. Connect grouped Undo/Redo; migrate relevant single-entry edits to the same pipeline.
3. Add a multi-selection inspector with mixed-value summaries and a bulk actions menu.
4. Align card, thumbnail, list, and table context menus to act on the clicked entry or current selection consistently.

## Acceptance and validation

- Adding a tag preserves each entry’s other tags; removing a tag preserves unrelated data.
- Mixed favorites and collections have unambiguous actions and summaries.
- One Undo/Redo reverses/reapplies the whole successful batch and persists it.
- Failed writes do not publish changes or create misleading Undo history.
- Test stale selections, interleaved edits, removed tags/collections, and two-window history behavior.
- Verify Command-click/Shift-click, context-menu selection, text-editor Undo, and keyboard actions in every display format.

Do not add bulk file-system rename/move/delete. Transaction design is shared with imports, health repairs, and rules.
