export const sorted = nodes => [...nodes].sort((a, b) => a.id.localeCompare(b.id));
export function comparableURL(value) {
  if (value == null) return null;
  try { const url = new URL(value); if (['http:', 'https:'].includes(url.protocol)) return url.href; } catch {}
  return value;
}
const comparable = node => ({...normalize(node), url: comparableURL(node.url)});
export const equal = (a, b) => JSON.stringify(sorted(a).map(comparable)) === JSON.stringify(sorted(b).map(comparable));
const normalize = n => ({id: n.id, title: n.title, parent: n.parent ?? null, url: n.url ?? null, locked: !!n.locked});
export function parsePairing(code) {
  const url = new URL(code.trim());
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.pathname !== '/' || url.search || !/^#[a-fA-F0-9]{64}$/.test(url.hash) || url.username || url.password) throw new Error('Paste a valid pairing code from Switchboard.');
  return {endpoint: url.origin + '/sync', token: url.hash.slice(1)};
}
export function snapshot(tree, selected, knownIDs = new Set()) {
  if (!Array.isArray(tree) || !selected.length) throw new Error('Choose all bookmarks or at least one bookmark or folder.');
  const byID = new Map();
  function index(node, depth = 0) {
    if (depth > 128 || byID.size > 20000 || typeof node.id !== 'string' || byID.has(node.id)) throw new Error('Invalid or oversized browser tree.');
    byID.set(node.id, node); for (const child of node.children ?? []) index(child, depth + 1);
  }
  tree.forEach(n => index(n));
  const included = new Map(); let skipped = 0;
  function location(node) {
    const names = []; const seen = new Set();
    while (node && node.id !== '0' && !seen.has(node.id)) {
      seen.add(node.id); names.unshift(String(node.title || 'Untitled bookmark').slice(0, 120)); node = byID.get(node.parentId);
    }
    return names.join(' / ').slice(0, 500);
  }
  function addressError(node, reason) {
    return new Error(`Vivaldi: cannot sync “${location(node)}” — ${reason}. Edit this bookmark’s address, then choose Sync now. Only HTTP and HTTPS addresses with a hostname are supported.`);
  }
  function add(node) {
    if (node.id !== '0') {
      if (node.url && !/^https?:\/\//i.test(node.url)) { if (knownIDs.has(node.id)) throw addressError(node, 'a previously synced bookmark now has an unsupported address type'); skipped++; return; }
      if (node.url != null && /^https?:/i.test(node.url)) {
        try { const url = new URL(node.url); if (!url.hostname || !/^https?:$/.test(url.protocol)) throw new Error(); }
        catch { throw addressError(node, 'malformed web address (a valid hostname is required)'); }
      }
      if (node.unmodifiable || node.folderType === 'managed') throw new Error('Managed bookmarks cannot be synchronized. Choose another scope.');
      included.set(node.id, node);
    }
    for (const child of node.children ?? []) add(child);
  }
  for (const id of selected) { const node = byID.get(id); if (node) add(node); }
  const nodes = [...included.values()].map(n => ({id: n.id, title: n.title?.trim() ? n.title : (n.url || 'Untitled folder'),
    parent: included.has(n.parentId) ? n.parentId : null, url: n.url ?? null,
    locked: n.parentId === '0' || !!n.folderType}));
  if (nodes.length > 10000) throw new Error('The selected scope exceeds 10,000 items.');
  return {nodes: sorted(nodes), skipped, byID};
}
export function operations(before, desired) {
  const old = new Map(before.map(n => [n.id, normalize(n)]));
  const target = new Map(desired.map(n => [n.id, normalize(n)]));
  if (old.size !== before.length || target.size !== desired.length) throw new Error('Duplicate bookmark identities.');
  const result = [], visited = new Set(), visiting = new Set();
  function visit(node) {
    if (visited.has(node.id)) return;
    if (visiting.has(node.id)) throw new Error('Folder cycle detected.');
    visiting.add(node.id);
    if (node.parent) { const parent = target.get(node.parent); if (!parent || parent.url) throw new Error('Unavailable parent folder.'); visit(parent); }
    const previous = old.get(node.id);
    if (!previous) {
      if (!node.id.startsWith('s:')) throw new Error('Unknown browser identity in sync response.');
      result.push({kind: 'create', node});
    } else if (!equal([previous], [node])) {
      if (previous.locked || (previous.url === null) !== (node.url === null)) throw new Error('A protected folder or item kind cannot be changed.');
      result.push({kind: 'update', before: previous, node});
    }
    visiting.delete(node.id); visited.add(node.id);
  }
  for (const node of desired) visit(normalize(node));
  const deleted = before.filter(n => !target.has(n.id));
  function depth(n) { let count = 0, cursor = n, seen = new Set(); while (cursor?.parent) { if (seen.has(cursor.id)) throw new Error('Folder cycle detected.'); seen.add(cursor.id); cursor = old.get(cursor.parent); count++; } return count; }
  deleted.sort((a, b) => depth(b) - depth(a));
  for (const node of deleted) { if (node.locked) throw new Error('Protected folders cannot be deleted.'); result.push({kind: 'remove', before: normalize(node)}); }
  return result;
}
export function canonical(nodes, created) {
  const reverse = new Map(Object.entries(created).map(([local, browser]) => [browser, local]));
  return sorted(nodes.map(n => ({...normalize(n), id: reverse.get(n.id) ?? n.id, parent: reverse.get(n.parent) ?? n.parent ?? null})));
}
export function advance(working, op) {
  const byID = new Map(working.map(n => [n.id, n]));
  if (op.kind === 'remove') byID.delete(op.before.id); else byID.set(op.node.id, normalize(op.node));
  return sorted([...byID.values()]);
}

// Browser APIs may canonicalize a valid address while creating/updating it. Acknowledge
// the reviewed spelling only after proving every field still matches semantically.
export function acknowledgementNodes(actual, desired, created) {
  if (!equal(canonical(actual, created), desired)) throw new Error('Bookmarks changed before acknowledgement. Reconcile interrupted sync.');
  const wanted = new Map(desired.map(n => [created[n.id] ?? n.id, n]));
  return actual.map(node => ({...node, url: wanted.get(node.id)?.url ?? null}));
}
