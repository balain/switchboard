import {restoreSnapshot} from './recovery.mjs';
import {acknowledgementNodes, comparableURL, parsePairing, snapshot, operations, canonical, advance, equal} from './sync-core.mjs';

let active = false, requested = false;
// Recovery snapshots can be several megabytes; ordinary polls only need live settings.
const state = () => chrome.storage.local.get(['endpoint', 'token', 'client', 'scope', 'selected', 'destination', 'enabled', 'knownIDs', 'journal']);
const save = value => chrome.storage.local.set(value);
async function status(message) { await save({status: message}); }
async function post(settings, action, extra = {}) {
  const response = await fetch(settings.endpoint, {method: 'POST', redirect: 'error', credentials: 'omit', cache: 'no-store', targetAddressSpace: 'loopback',
    headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + settings.token},
    body: JSON.stringify({action, client: settings.client, scope: settings.scope, destination: settings.destination || null, nodes: [], ...extra}), signal: AbortSignal.timeout(12000)});
  const result = await response.json();
  if (!response.ok) throw new Error(result.message || 'Switchboard rejected this sync.');
  return result;
}
async function current(settings, created = {}) {
  const tree = await chrome.bookmarks.getTree();
  const value = snapshot(tree, settings.selected, new Set(settings.knownIDs ?? []));
  return {...value, canonical: canonical(value.nodes, created)};
}
function browserID(id, journal) { return journal.created[id] ?? id; }
async function destination(node, journal, settings) {
  const parent = node.parent ? browserID(node.parent, journal) : settings.destination;
  if (!parent) throw new Error('Choose a destination folder to create or move items at the sync root.');
  const [folder] = await chrome.bookmarks.get(parent);
  if (!folder || folder.url || folder.unmodifiable || folder.id === '0') throw new Error('The destination folder is unavailable.');
  return parent;
}
async function recoverCreation(settings, journal, op) {
  if (journal.created[op.node.id]) return;
  const parentId = await destination(op.node, journal, settings);
  const marker = 'Switchboard pending ' + journal.transaction + ' ' + journal.index;
  const matches = (await chrome.bookmarks.getChildren(parentId)).filter(n => n.title === marker && (n.url ?? null) === op.node.url);
  if (matches.length > 1) throw new Error('Ambiguous interrupted bookmark creation. Review the pending items in Vivaldi.');
  if (!matches.length && !equal((await current(settings, journal.created)).canonical, journal.working)) throw new Error('An interrupted creation changed outside sync. Reconcile before continuing.');
  const node = matches[0] ?? await chrome.bookmarks.create({parentId, title: marker, ...(op.node.url ? {url: op.node.url} : {})});
  journal.created[op.node.id] = node.id;
  await save({journal});
}
async function finish(settings, journal) {
  for (; journal.index < journal.operations.length;) {
    const op = journal.operations[journal.index];
    const next = advance(journal.working, op);
    if (op.kind === 'create') {
      // A durable marker allows recovery if the worker stops between create and recording its new ID.
      let before = await current(settings, journal.created);
      if (!journal.inFlight) {
        if (!equal(before.canonical, journal.working)) throw new Error('Bookmarks changed before this operation. Use Reconcile interrupted sync.');
        journal.inFlight = true; await save({journal});
      }
      await recoverCreation(settings, journal, op);
      const id = journal.created[op.node.id];
      const [item] = await chrome.bookmarks.get(id);
      const marker = 'Switchboard pending ' + journal.transaction + ' ' + journal.index;
      if (item.title !== marker && item.title !== op.node.title) throw new Error('A pending bookmark was edited. Reconcile interrupted sync.');
      if (item.title === marker) await chrome.bookmarks.update(id, {title: op.node.title});
    } else {
      const before = await current(settings, journal.created);
      if (!equal(before.canonical, next)) {
        if (!equal(before.canonical, journal.working)) throw new Error('Bookmarks changed while syncing. Use Reconcile interrupted sync.');
        journal.inFlight = true; await save({journal});
        const id = browserID(op.kind === 'remove' ? op.before.id : op.node.id, journal);
        if (op.kind === 'remove') {
          // remove, never removeTree: an unexpected new child makes a folder removal fail safely.
          await chrome.bookmarks.remove(id);
        } else {
          if (op.before.parent !== op.node.parent) await chrome.bookmarks.move(id, {parentId: await destination(op.node, journal, settings)});
          await chrome.bookmarks.update(id, {title: op.node.title, ...(op.node.url && comparableURL(op.node.url) !== comparableURL(op.before.url) ? {url: op.node.url} : {})});
        }
      }
    }
    const after = await current(settings, journal.created);
    if (!equal(after.canonical, next)) throw new Error('Bookmarks changed during an operation. Use Reconcile interrupted sync.');
    journal.working = next; journal.index++; journal.inFlight = false; await save({journal});
  }
  const final = await current(settings, journal.created);
  if (!equal(final.canonical, journal.desired)) throw new Error('Bookmarks changed before acknowledgement. Reconcile interrupted sync.');
  const result = await post(settings, 'ack', {transaction: journal.transaction, created: journal.created, nodes: acknowledgementNodes(final.nodes, journal.desired, journal.created)});
  if (result.status !== 'complete') throw new Error(result.message || 'Acknowledgement failed.');
  await save({journal: null, knownIDs: final.nodes.map(n => n.id), status: result.message + (final.skipped ? ` ${final.skipped} non-web bookmarks were excluded.` : ''), lastSync: Date.now()});
}
async function synchronize() {
  if (active) { requested = true; return; }
  active = true;
  try {
    const settings = await state();
    if (!settings.enabled || !settings.token || !settings.selected?.length) return;
    if (settings.journal) { await finish(settings, settings.journal); return; }
    const browser = await current(settings);
    const response = await post(settings, 'plan', {nodes: browser.nodes});
    if (response.status === 'complete') { await save({knownIDs: browser.nodes.map(n => n.id), status: response.message, lastSync: Date.now()}); return; }
    if (response.status === 'review') { await status(response.message + ' Open File → Vivaldi Bookmark Sync in Switchboard.'); return; }
    if (response.status !== 'apply' || !response.transaction || !response.desired || !response.before) throw new Error('Unexpected sync response.');
    if (!equal(browser.nodes, response.before)) throw new Error('An earlier transaction needs reconciliation. Use Reconcile interrupted sync.');
    const ops = operations(browser.nodes, response.desired);
    const journal = {transaction: response.transaction, desired: response.desired, operations: ops, index: 0, created: {}, working: browser.nodes, inFlight: false};
    // Recovery snapshots are taken before any browser mutation, bounded to the latest 20 batches.
    if (ops.length) {
      const {backups = []} = await chrome.storage.local.get('backups');
      backups.unshift({date: Date.now(), nodes: browser.nodes});
      await save({journal, backups: backups.slice(0, 20)});
    } else { await save({journal}); }
    await finish(settings, journal);
  } catch (error) { await status(error.message + '\nThis sync attempt stopped. Fix the issue above, then choose Sync now.'); }
  finally { active = false; if (requested) { requested = false; schedule(); } }
}
function schedule() { chrome.alarms.create('switchboard-soon', {when: Date.now() + 1500}); }
async function reconcile() {
  const settings = await state();
  if (!settings.token) throw new Error('Pair with Switchboard first.');
  const journal = settings.journal;
  if (journal?.inFlight && journal.operations[journal.index]?.kind === 'create') {
    // Recover an already-created marker; do not create anything during reconciliation.
    const op = journal.operations[journal.index], parent = await destination(op.node, journal, settings);
    if (!journal.created[op.node.id]) {
      const marker = 'Switchboard pending ' + journal.transaction + ' ' + journal.index;
      const nodes = (await chrome.bookmarks.getChildren(parent)).filter(n => n.title === marker && (n.url ?? null) === op.node.url);
      if (nodes.length > 1) throw new Error('Review duplicate pending markers before reconciling.');
      if (nodes[0]) { journal.created[op.node.id] = nodes[0].id; await save({journal}); }
    }
    const id = journal.created[op.node.id];
    if (id) { const [node] = await chrome.bookmarks.get(id); if (node.title.startsWith('Switchboard pending ')) await chrome.bookmarks.update(id, {title: op.node.title}); }
  }
  const browser = await current(settings);
  // If the extension restarted before saving its journal, retrieve the app's pending ID.
  const pending = journal ?? await post(settings, 'plan', {nodes: browser.nodes});
  const transaction = pending.transaction;
  if (transaction) await post(settings, 'abort', {transaction, created: journal?.created ?? {}, nodes: browser.nodes});
  await save({journal: null, status: 'Reconciled. Retained all partial changes for the next three-way comparison.'});
  schedule();
}
async function downloadBackup() {
  const {backups = []} = await chrome.storage.local.get('backups');
  if (!backups.length) throw new Error('No browser recovery snapshots yet.');
  // Returned to the trusted options page, which offers a local JSON download.
  return JSON.stringify({schemaVersion: 1, snapshots: backups}, null, 2);
}
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(chrome.runtime.getURL('options.html'))) return;
  if (active && message.action !== 'status') { respond({error: 'A sync is in progress. Try again shortly.'}); return; }
  const action = async () => {
    if (message.action === 'configure' || message.action === 'pause') {
      active = true;
      try {
        const existing = await state();
        if (message.action === 'pause') { await save({enabled: false, status: 'Paused in Vivaldi.'}); return {}; }
        const pairing = message.code?.trim() ? parsePairing(message.code) : {endpoint: existing.endpoint, token: existing.token};
        if (!pairing.token) throw new Error('Paste a pairing code from Switchboard.');
        if (!Array.isArray(message.selected) || message.selected.length > 10000 || !message.selected.every(id => typeof id === 'string' && id.length < 128)) throw new Error('Invalid bookmark selection.');
        const selected = message.selected.includes('0') ? ['0'] : [...new Set(message.selected)].sort();
        const scope = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(selected))))].map(n => n.toString(16).padStart(2, '0')).join('');
        const changed = existing.token !== pairing.token;
        if (!changed && existing.scope && existing.scope !== scope) throw new Error('Use New Pairing in Switchboard before changing scope.');
        if (existing.journal && !(changed && message.reset)) throw new Error('Reconcile the interrupted sync or confirm a new pairing first.');
        const view = snapshot(await chrome.bookmarks.getTree(), selected);
        const destination = message.destination || '';
        if (destination && !view.nodes.some(n => n.id === destination && !n.url)) throw new Error('The destination must be a folder within the selected scope.');
        await save({...pairing, selected, scope, destination, enabled: true, client: existing.client ?? crypto.randomUUID(),
          ...(changed ? {knownIDs: [], journal: null} : {}), status: 'Paired. Waiting for sync.'});
        return {};
      } finally { active = false; schedule(); }
    }
    if (message.action === 'sync') { await synchronize(); return {}; }
    if (message.action === 'reconcile') { await reconcile(); return {}; }
    if (message.action === 'restore') {
      active = true;
      try {
        const settings = await state();
        if (settings.enabled) throw new Error('Pause sync in Vivaldi before restoring a recovery snapshot.');
        const {backups = []} = await chrome.storage.local.get('backups');
        const backup = backups[0];
        if (!backup) throw new Error('No browser recovery snapshots yet.');
        const folder = await restoreSnapshot(chrome.bookmarks, backup.nodes, settings.destination, backup.date);
        await status('Recovered into a new folder: ' + folder.title + '. Existing bookmarks were kept.');
        return {};
      } finally { active = false; }
    }
    if (message.action === 'backup') return {json: await downloadBackup()};
    return {};
  };
  action().then(respond, error => respond({error: error.message})); return true;
});
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
for (const event of [chrome.bookmarks.onCreated, chrome.bookmarks.onChanged, chrome.bookmarks.onMoved, chrome.bookmarks.onRemoved, chrome.bookmarks.onChildrenReordered, chrome.bookmarks.onImportEnded]) event.addListener(schedule);
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name.startsWith('switchboard-')) synchronize(); });
chrome.runtime.onStartup.addListener(schedule);
chrome.runtime.onInstalled.addListener(schedule);
chrome.storage.local.setAccessLevel({accessLevel: 'TRUSTED_CONTEXTS'}).catch(() => {});
chrome.alarms.create('switchboard-periodic', {periodInMinutes: 1});
