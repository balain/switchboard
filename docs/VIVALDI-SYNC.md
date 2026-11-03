# Vivaldi two-way bookmark sync

Open **File → Vivaldi Bookmark Sync…** in the new Switchboard build. The companion extension uses Vivaldi’s Chromium bookmark API while the browser runs. It does not edit a live profile’s `Bookmarks` file.

## Setup

1. Choose **Enable / Resume**, then **Show Companion Extension** in Switchboard. The extension is included inside the built app and its source is in `Extensions/Vivaldi`.
2. In Vivaldi, open `vivaldi://extensions`, enable Developer mode, choose **Load unpacked**, and select that extension folder.
3. Open the extension’s **Options**. Copy the pairing code from Switchboard and paste it into the password field. Treat this code as private.
4. Choose **All bookmark folders**, or check any combination of individual bookmarks and folders. Selecting a folder includes its descendants; overlapping selections are deduplicated.
5. Choose a destination folder inside that scope for new items placed directly in Switchboard’s sync root. Individual-bookmark-only scopes can edit existing items, but creating new root items requires a selected destination folder.
6. Choose **Save pairing and start**. Bookmarks appear under a new **Vivaldi Bookmarks** collection. Existing library entries elsewhere are not matched or overwritten.

Keep both apps running. Browser events schedule a sync shortly afterwards, and a periodic alarm checks about once per minute. Local Switchboard changes appear on the next check; **Sync now** requests an immediate check. Closing the library window keeps the app running. Pausing either side stops further cycles; resume with the same pairing. Scope changes require **New Pairing** in Switchboard, then a new code in the extension. Old collections remain intact.

## What syncs

Names, HTTP/HTTPS URLs, folder names, folder placement, additions, and deletions sync in both directions. Move a new Switchboard URL or collection into the synced hierarchy to include it. Notes, tags, favorites, file references, display preferences, browser ordering, and Vivaldi-specific bookmark properties are not synchronized. The normal bookmark API preserves properties it does not edit. Permanent browser folders are controlled by Vivaldi and are recreated locally if removed or renamed in Switchboard.

Moving a synced item outside its scope removes the counterpart. A deleted browser bookmark that wins conflict review on the Switchboard side is recreated with a new browser ID while retaining its Switchboard identity and metadata. Non-web bookmarks are excluded; a previously synchronized item changed to a non-web address pauses sync instead of being treated as a deletion. Managed bookmarks stop the selected scope with an actionable error.

## Conflicts and recovery

A three-way comparison uses the last acknowledged state. Concurrent edits or edit/delete conflicts pause that batch. Open Switchboard’s sync window and choose **Keep Switchboard** or **Keep Vivaldi** for each conflict. Choices apply only to those exact snapshots. Keeping an edited child also keeps the folders required to contain it.

Removing 10 or more items, or at least half the last acknowledged scope, requires approval in Switchboard. Approval applies only to the reviewed snapshot. Individual smaller deletions propagate automatically.

Every changed browser batch retains a pre-change snapshot in extension-local storage (latest 20). **Download browser recovery snapshots** exports those snapshots as JSON. Pause the extension and choose **Restore latest snapshot to a new folder** to restore a separate copy under its destination, preserving existing browser bookmarks. Do this before resuming if recovering a deletion.

Switchboard retains up to 20 `vivaldi-sync` recovery checkpoints in its backup folder, in addition to normal daily/manual backups. Restoring a library backup pauses sync and requires a new pairing; it never pushes the restored library automatically.

Transactions use persisted journals and explicit acknowledgement. Interrupted creates use temporary unique names so a service-worker restart can recover the assigned ID without making a duplicate. These names are replaced with the intended title before completion. A retry after a lost acknowledgement does not repeat the mutation. Unexpected browser edits stop the batch. **Reconcile interrupted sync** keeps partial changes and compares both sides again. Browser APIs offer no multi-item transaction or atomic compare-and-swap; checkpoints and reconciliation handle interruptions, and users should avoid editing the same items during a batch.

## Local connection and limits

The app listens only on `127.0.0.1` when enabled, using a generated private bearer code and an automatically selected port retained for restart. The extension requests only bookmark, local-storage, alarm, and loopback-host permissions. No content scripts, external services, saved-page requests, or telemetry are used. The first profile to pair is pinned to that connection. New Pairing/Disconnect rotates the code. Connection settings are stored separately with owner-only permissions and omitted from portable exports.

The selected graph is limited to 10,000 items, the full input tree to 20,000, depth to 128, and each loopback request to 4 MB. If the saved port is unavailable, choose a new pairing. Alarms may be delayed while the browser or computer sleeps. Browser installation, API compatibility, and permissions should be checked on the user’s installed Vivaldi version before using a large personal scope.

## Verification

Run:

```sh
swift test -j 2 --disable-sandbox --cache-path .build-cache
node --test Tests/VivaldiExtensionTests/*.test.mjs
./scripts/build-app.sh
```

The Swift suite tests merge decisions, protected folders, scope/profile isolation, stale acknowledgements, failed writes, deletion review, backup restoration, concurrent local changes, interrupted creations, browser ID replacement, repeated bidirectional cycles, and a real authenticated loopback listener. Extension tests cover selections, parent-first creates, child-first deletes, token/endpoint validation, durable worker journals, worker interruption before recording a new ID, lost acknowledgements, external edits, and recovery-folder creation. The native pairing window and a synthetic live UI/API round trip have been reviewed. A real Vivaldi profile has not been paired automatically.

API references: [Vivaldi extensions](https://help.vivaldi.com/desktop/appearance-customization/extensions/), [Chromium bookmarks API](https://developer.chrome.com/docs/extensions/reference/api/bookmarks), [alarms](https://developer.chrome.com/docs/extensions/reference/api/alarms), [service-worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle).
