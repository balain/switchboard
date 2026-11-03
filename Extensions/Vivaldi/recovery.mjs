import {operations} from './sync-core.mjs';
export async function restoreSnapshot(bookmarks, nodes, destination, date) {
  if (!Array.isArray(nodes) || nodes.length > 10000 || !destination || destination === '0') throw new Error('Choose a recovery destination folder.');
  const [folder] = await bookmarks.get(destination);
  if (!folder || folder.url || folder.unmodifiable) throw new Error('The recovery destination is unavailable.');
  const source = nodes.map(n => {
    if (typeof n.id !== 'string' || !n.title || typeof n.title !== 'string' || (n.url && !/^https?:\/\//i.test(n.url))) throw new Error('Invalid browser recovery snapshot.');
    return {...n, id:'s:'+n.id, parent:n.parent ? 's:'+n.parent : null, locked:false};
  });
  const ordered = operations([], source);
  const root = await bookmarks.create({parentId:destination, title:'Switchboard recovery ' + new Date(date).toISOString().slice(0,10)});
  const created = new Map();
  for (const {node} of ordered) {
    const parentId = node.parent ? created.get(node.parent) : root.id;
    if (!parentId) throw new Error('A recovery parent is unavailable. Partial recovery remains in its new folder.');
    const item = await bookmarks.create({parentId, title:node.title, ...(node.url ? {url:node.url} : {})}); created.set(node.id,item.id);
  }
  return root;
}
