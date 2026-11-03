import {parsePairing, snapshot} from './sync-core.mjs';
const $ = id => document.getElementById(id);
let settings = await chrome.storage.local.get(null);
const tree = await chrome.bookmarks.getTree();
const selected = new Set(settings.selected ?? []);
function draw(nodes, depth = 0, path = '') {
  for (const node of nodes) {
    if (node.id !== '0') {
      const label = document.createElement('label'); label.style.setProperty('--depth', Math.max(0, depth - 1));
      const input = document.createElement('input'); input.type = 'checkbox'; input.value = node.id; input.checked = selected.has(node.id);
      input.disabled = !!node.unmodifiable;
      input.addEventListener('change', () => input.checked ? selected.add(node.id) : selected.delete(node.id));
      label.append(input, document.createTextNode(' ' + (node.title || node.url || 'Untitled folder') + (node.url ? '' : ' /'))); $('tree').append(label);
      if (!node.url && !node.unmodifiable) {
        const option = document.createElement('option'); option.value = node.id; option.textContent = path + (node.title || 'Untitled folder'); $('destination').append(option);
      }
    }
    draw(node.children ?? [], depth + 1, node.id === '0' ? '' : path + (node.title || 'Untitled') + ' / ');
  }
}
draw(tree);
$('all').checked = selected.has('0'); $('destination').value = settings.destination ?? '';
$('status').textContent = settings.status || 'Not paired.';
const display = error => { $('status').textContent = error.message || String(error); };
$('connect').addEventListener('click', async () => {
  try {
    if (chrome.permissions && !await chrome.permissions.contains({origins: ['http://127.0.0.1/*']})) {
      if (!await chrome.permissions.request({origins: ['http://127.0.0.1/*']})) throw new Error('Allow this extension to access the Switchboard loopback connection before pairing.');
    }
    settings = await chrome.storage.local.get(null);
    const code = $('pairing').value.trim();
    if (code) parsePairing(code);
    const ids = $('all').checked ? ['0'] : [...selected].filter(id => id !== '0').sort();
    let reset = false;
    if (settings.journal && code && parsePairing(code).token !== settings.token) {
      reset = confirm('Start a new pairing and abandon the interrupted journal? Partial changes stay in both apps, and the new pairing creates a fresh Switchboard collection.');
      if (!reset) return;
    }
    const reply = await chrome.runtime.sendMessage({action: 'configure', code, selected: ids, destination: $('destination').value, reset});
    if (reply?.error) throw new Error(reply.error);
    $('pairing').value = ''; settings = await chrome.storage.local.get(null);
    await run('sync');
  } catch (error) { display(error); }
});
async function run(action) { const reply = await chrome.runtime.sendMessage({action}); if (reply?.error) throw new Error(reply.error); }
for (const [id, action] of [['sync', 'sync'], ['reconcile', 'reconcile']]) $(id).addEventListener('click', () => run(action).catch(display));
$('pause').addEventListener('click', () => run('pause').catch(display));
$('backup').addEventListener('click', async () => {
  try {
    const response = await chrome.runtime.sendMessage({action: 'backup'}); if (response.error) throw new Error(response.error);
    const url = URL.createObjectURL(new Blob([response.json], {type: 'application/json'}));
    const link = document.createElement('a'); link.href = url; link.download = 'Switchboard-Vivaldi-recovery.json'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (error) { display(error); }
});
chrome.storage.onChanged.addListener(changes => { if (changes.status) $('status').textContent = changes.status.newValue; });

$('restore').addEventListener('click', () => {
  if (confirm('Restore the latest browser snapshot into a new folder at your destination? Existing bookmarks are kept. Pause sync first.')) run('restore').catch(display);
});
