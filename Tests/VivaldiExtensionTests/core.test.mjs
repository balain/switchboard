import test from 'node:test';
import assert from 'node:assert/strict';
import {parsePairing, snapshot, operations, equal, canonical, advance} from '../../Extensions/Vivaldi/sync-core.mjs';
const node = (id, title, parent = null, url = null, locked = false) => ({id, title, parent, url, locked});
const tree = [{id: '0', title: '', children: [{id: '1', title: 'Bookmarks', parentId: '0', children: [
  {id: '2', title: 'Folder', parentId: '1', children: [{id: '3', title: 'A', parentId: '2', url: 'https://example.com'}]},
  {id: '4', title: 'B', parentId: '1', url: 'https://example.org'},
  {id: '5', title: 'Internal', parentId: '1', url: 'vivaldi://settings'}]}]}];
test('pairing accepts only loopback and a full private token', () => {
  assert.equal(parsePairing('http://127.0.0.1:12345/#' + 'a'.repeat(64)).endpoint, 'http://127.0.0.1:12345/sync');
  for (const value of ['https://127.0.0.1:12345/#', 'http://localhost:123/#', 'http://example.com:123/#', 'http://127.0.0.1:123/sync#', 'http://user@127.0.0.1:123/#']) assert.throws(() => parsePairing(value + 'a'.repeat(64)));
});
test('scope supports root, multiple subtrees, individual bookmarks, and overlapping selections', () => {
  const all = snapshot(tree, ['0']); assert.equal(all.nodes.length, 4); assert.equal(all.skipped, 1); assert.equal(all.nodes[0].locked, true);
  const multiple = snapshot(tree, ['2', '3', '4']); assert.deepEqual(multiple.nodes.map(n => n.id), ['2', '3', '4']);
  assert.equal(multiple.nodes.find(n => n.id === '2').parent, null); assert.equal(multiple.nodes.find(n => n.id === '3').parent, '2');
  assert.deepEqual(snapshot(tree, ['3']).nodes, [node('3', 'A', null, 'https://example.com')]);
  assert.throws(() => snapshot(tree, ['0'], new Set(['5']))); assert.throws(() => snapshot(tree, []));
});
test('operations create parents first and remove folders only after children', () => {
  const before = [node('1', 'Folder'), node('2', 'URL', '1', 'https://example.com')];
  const desired = [node('s:child', 'New', 's:parent', 'https://example.org'), node('s:parent', 'New folder')];
  const ops = operations(before, desired);
  assert.deepEqual(ops.map(o => [o.kind, o.node?.id ?? o.before.id]), [['create','s:parent'],['create','s:child'],['remove','2'],['remove','1']]);
  const result = ops.reduce(advance, before); assert(equal(result, desired));
  assert.throws(() => operations([node('1','Fixed',null,null,true)], []));
  assert.throws(() => operations([], [node('s:a','A','s:b'), node('s:b','B','s:a')]));
});
test('normalizing created identities is stable across reordered snapshots and nullable fields', () => {
  const actual = [node('44','URL','43','https://example.com'), node('43','Folder')];
  assert(equal(canonical(actual, {'s:a':'43','s:b':'44'}), [node('s:a','Folder'), node('s:b','URL','s:a','https://example.com')]));
  assert(!equal(actual, [node('43','Changed')]));
});

test('recovery creates a separate folder and never updates or deletes existing bookmarks', async () => {
  const {restoreSnapshot} = await import('../../Extensions/Vivaldi/recovery.mjs');
  const created = [];
  const api = {get:async()=>[{id:'destination',title:'Bookmarks'}],create:async value=>{const node={...value,id:String(created.length+1)};created.push(node);return node;}};
  await restoreSnapshot(api,[node('folder','Folder'),node('url','A','folder','https://example.com')],'destination',0);
  assert.equal(created.length,3);assert.equal(created[0].parentId,'destination');assert.equal(created[1].parentId,created[0].id);assert.equal(created[2].parentId,created[1].id);
  await assert.rejects(()=>restoreSnapshot(api,[node('x','Bad',null,'javascript:alert(1)')],'destination',0));
  assert.equal(created.length,3);
});

test('URL comparisons accept browser encoding differences without hiding query or fragment changes', async () => {
  const {acknowledgementNodes} = await import('../../Extensions/Vivaldi/sync-core.mjs');
  const wanted = node('s:new', 'Unicode page', null, 'https://EXAMPLE.com/a file/Ω?q=hello world#section');
  const actual = node('42', 'Unicode page', null, 'https://example.com/a%20file/%CE%A9?q=hello%20world#section');
  const ack = acknowledgementNodes([actual], [wanted], {'s:new':'42'});
  assert.equal(ack[0].url, wanted.url); assert.equal(ack[0].id, '42');
  assert.throws(() => acknowledgementNodes([{...actual,url:actual.url.replace('hello%20world','other')}],[wanted],{'s:new':'42'}));
  assert.throws(() => acknowledgementNodes([{...actual,url:actual.url.replace('#section','#different')}],[wanted],{'s:new':'42'}));
  assert(equal([node('1','Home',null,'https://example.com')],[node('1','Home',null,'https://example.com/')]));
  assert.deepEqual(operations([node('1','Home',null,'https://example.com')],[node('1','Home',null,'https://example.com/')]),[]);
});
test('invalid bookmark diagnostics identify the folder and title without exposing address credentials or queries', () => {
  const invalid=[{id:'0',children:[{id:'1',title:'Research',parentId:'0',children:[{id:'2',parentId:'1',title:'Broken report',url:'https://user:private-password@?token=private-token'}]}]}];
  assert.throws(()=>snapshot(invalid,['0']), error=>{
    assert.match(error.message,/Research \/ Broken report/);assert.match(error.message,/malformed web address/);
    assert(!error.message.includes('private-password'));assert(!error.message.includes('private-token'));return true;
  });
  invalid[0].children[0].children[0].url='vivaldi://settings';
  assert.throws(()=>snapshot(invalid,['0'],new Set(['2'])),/Research \/ Broken report/);
  assert.equal(snapshot(invalid,['0']).skipped,1);
});
