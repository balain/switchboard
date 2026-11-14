import test from 'node:test';
import assert from 'node:assert/strict';
import {snapshot, equal} from '../../Extensions/Vivaldi/sync-core.mjs';

class Event { listeners = []; addListener(f) { this.listeners.push(f); } }
const event = () => new Event();
test('worker uses durable journals, retries acknowledgements, and refuses to overwrite external edits', async () => {
  const nodes = new Map([
    ['0', {id:'0',title:'',children:[]}], ['1',{id:'1',parentId:'0',title:'Bookmarks'}],
    ['2',{id:'2',parentId:'1',title:'Original',url:'https://example.com'}]
  ]);
  const tree = () => { const build = n => ({...n,...(!n.url ? {children:[...nodes.values()].filter(c=>c.parentId===n.id).map(build)} : {})}); return [build(nodes.get('0'))]; };
  const db = {endpoint:'http://127.0.0.1:12345/sync',token:'synthetic-test-token',client:'synthetic-test-client',scope:'selection',selected:['1'],destination:'1',enabled:true};
  const reads = [];
  let nextID = 3, writes = 0, journalHook = null, failIdentitySave = true;
  globalThis.chrome = {
    storage:{local:{get:async keys=>{reads.push(keys);assert.notEqual(keys,null);return structuredClone(Object.fromEntries((Array.isArray(keys)?keys:[keys]).filter(k=>k in db).map(k=>[k,db[k]])));},set:async value=>{if(failIdentitySave && Object.keys(value.journal?.created ?? {}).length){failIdentitySave=false;throw Error('Simulated worker stop before identity save');}Object.assign(db,structuredClone(value));if(journalHook && value.journal){const hook=journalHook;journalHook=null;hook();}},setAccessLevel:async()=>{} }},
    alarms:{create:()=>{},onAlarm:event()},action:{onClicked:event()},
    runtime:{id:'test',getURL: name=>'chrome-extension://test/'+name,onMessage:event(),onStartup:event(),onInstalled:event(),openOptionsPage:()=>{}},
    bookmarks:{
      getTree:async()=>tree(),get:async id=>{if(!nodes.has(id))throw Error('missing');return [{...nodes.get(id)}];},
      getChildren:async parent=>[...nodes.values()].filter(n=>n.parentId===parent).map(n=>({...n})),
      create:async value=>{const node={...value,...(value.url ? {url:new URL(value.url).href}:{}),id:String(nextID++)};nodes.set(node.id,node);writes++;return {...node};},
      update:async(id,value)=>{Object.assign(nodes.get(id),value,value.url ? {url:new URL(value.url).href}:{});writes++;return {...nodes.get(id)};},
      move:async(id,value)=>{nodes.get(id).parentId=value.parentId;writes++;return {...nodes.get(id)};},
      remove:async id=>{if([...nodes.values()].some(n=>n.parentId===id))throw Error('folder not empty');nodes.delete(id);writes++;},
      onCreated:event(),onChanged:event(),onMoved:event(),onRemoved:event(),onChildrenReordered:event(),onImportEnded:event()
    }
  };
  const original = snapshot(tree(),db.selected).nodes;
  const desired = original.map(n=>n.id==='2'?{...n,title:'Renamed'}:n);
  desired.push({id:'s:new-folder',title:'New folder',parent:'1',url:null,locked:false});
  desired.push({id:'s:new-url',title:'New URL',parent:'s:new-folder',url:'https://example.org',locked:false});
  let phase='first', lostAck=true, acknowledgements=0, aborted=0, mutationResponse;
  globalThis.fetch = async (endpoint, options) => {
    assert.equal(endpoint,db.endpoint);assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');
    assert.equal(options.headers.Authorization,'Bearer '+db.token);
    const request=JSON.parse(options.body);let response;
    if(request.action==='plan') {
      if(phase==='first')response={status:'apply',transaction:'transaction-1',before:original,desired};
      else if(phase==='race')response=mutationResponse;
      else response={status:'review',message:'Review conflict in Switchboard.'};
    } else if(request.action==='ack') {
      acknowledgements++;
      assert.equal(request.transaction,'transaction-1');assert.equal(request.nodes.find(n=>n.title==='New URL').url,'https://example.org');assert.equal(Object.keys(request.created).length,2);
      assert(equal(request.nodes,snapshot(tree(),db.selected).nodes));
      if(lostAck){lostAck=false;throw Error('Connection lost after commit');}
      response={status:'complete',message:'Synced.'};
    } else if(request.action==='abort') {aborted++;response={status:'complete',message:'Reconciled'};phase='review';}
    else throw Error('Unexpected action');
    return {ok:true,json:async()=>response};
  };
  await import('../../Extensions/Vivaldi/background.js');
  const message=async action=>new Promise(resolve=>chrome.runtime.onMessage.listeners[0]({action},{id:'test',url:'chrome-extension://test/options.html'},resolve));
  await message('sync');
  assert(db.journal);assert.match(db.status,/Simulated worker stop/);assert.equal(nodes.size,4);
  await message('sync');assert(db.journal);assert.match(db.status,/Connection lost/);assert.equal(nodes.size,5);
  const writesBefore=writes;await message('sync');
  assert.equal(db.journal,null);assert.equal(acknowledgements,2);assert.equal(writes,writesBefore);assert.equal(nodes.size,5);
  assert.equal(nodes.get('2').title,'Renamed');assert(db.backups.length);
  phase='race';
  const before=snapshot(tree(),db.selected).nodes;
  mutationResponse={status:'apply',transaction:'transaction-2',before,desired:before.map(n=>n.id==='2'?{...n,title:'App edit'}:n)};
  journalHook=()=>{nodes.get('2').title='Concurrent browser edit';};
  await message('sync');assert.match(db.status,/changed/);assert.equal(nodes.get('2').title,'Concurrent browser edit');assert(db.journal);
  await message('reconcile');assert.equal(aborted,1);assert.equal(db.journal,null);assert.equal(nodes.get('2').title,'Concurrent browser edit');
  reads.length=0;
  await message('sync');assert.match(db.status,/Review conflict/);
  assert(reads.every(keys=>Array.isArray(keys) && !keys.includes('backups')), 'Routine sync must not load recovery snapshots');
  const backup=await message('backup');assert.equal(JSON.parse(backup.json).schemaVersion,1);
});
