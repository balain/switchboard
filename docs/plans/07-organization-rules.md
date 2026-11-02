# 7. Simple organization rules

Status: implemented on `codex/organization-rules`. See README for behavior and limits.

## Outcome and scope

Automatically tag or organize newly added entries using rules such as “PDFs under this folder get Research” or “URLs from this host go to Work.” A dry-run preview supports applying rules to existing entries. Inspired by [DEVONthink smart rules](https://www.devontechnologies.com/products/devonthink/).

Version one actions: add/remove tags, set/clear a physical collection, and set favorite status. Conditions: name/location text, file extension, kind, exact URL host, favorite state, tags, and folder ancestry. No scripts, network calls, file-system moves, or full-content extraction.

## Design and integration

Add a default-empty Codable rules array to `LibraryData`. Each rule has a UUID, name, enablement, ordered conditions, actions, trigger, and optional stop-processing flag. Reference tags/collections by UUID and share predicate primitives with smart collections. Folder matching uses path components rather than unsafe string-prefix matching; host matching uses parsed URL components.

Implement a pure `RuleEngine` that produces a mutation preview and per-entry explanation. Run enabled rules in explicit order; later rules see the candidate state left by earlier rules. Later assignments win for single-value fields unless stop-processing applies. Show conflicts in the preview.

Trigger once after a successful add/import staging operation, before the candidate is committed. Do not trigger from generic `save()` or every `update()`; that would cause loops and surprise changes during repair, Undo, restore, or rename. Import offers a separate Apply Rules checkbox. No watched-folder service is required.

## Implementation sequence

1. Define the rule model, condition/action validation, and deterministic evaluator.
2. Build Manage Rules with enable/disable, ordering, duplicate, and delete controls.
3. Build Preview Rules for selected or all existing entries, showing before/after changes and reasons.
4. Add event-specific integration for new additions and optional imports; apply changes through bulk transactions with one Undo group.

Deleting referenced tags/collections disables affected rules and identifies missing references. Never reinterpret a missing action target as “clear collection” or “all entries.” Persist rule configuration, not unbounded execution logs; keep a bounded recent-run summary.

## Acceptance and validation

- Identical inputs and ordered rules produce identical previews and mutations.
- Test conflicting rules, stop-processing, repeated runs, missing targets, folder-prefix collisions, and URL subdomains.
- Preview does not mutate or save; confirmed application supports Undo and survives relaunch.
- Undo, restore, bookmark repair, and unrelated edits never retrigger rules.
- Failed writes publish neither new entries nor partial rule results.

Deliver after shared predicates and bulk transactions. Keep trigger semantics narrow before considering update-triggered or watched-folder automation.

## Implementation validation

Implemented independently from main `f45f88e`. 64 tests pass; release app build and signature verification pass. Native UI saved an enabled rule, previewed four changes, applied them, and reversed them in one Undo. Tests cover ordered actions, stop behavior, automatic additions, stale previews, missing references, failure rollback, and legacy decoding. Integrated with feature 6: import previews can apply existing enabled rules explicitly, portable rules start disabled, and backup restore preserves configuration without executing rules.
