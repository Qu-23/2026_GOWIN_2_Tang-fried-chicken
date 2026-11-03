// Execute the actual inline app script with a small DOM/transport harness.
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync('web/app.html','utf8');
const code=html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(code); // Check the complete script, including boot().
function app(saved={}){
  const elements=new Map(),timers=new Map(),intervals=new Map(),sockets=[];let id=0,now=0;
  const context={console,Uint8Array,Map,Set,JSON,Date:{now:()=>now},
    performance:{now:()=>now},window:{devicePixelRatio:1},navigator:{},location:{host:'localhost:8080',protocol:'http:'},
    localStorage:{getItem:key=>key==='m60k_app_v1'?JSON.stringify(saved):null},
    document:{querySelector:s=>{if(!elements.has(s))elements.set(s,{textContent:'',className:'',classList:{add(){},remove(){}},clientWidth:320,clientHeight:100,
      getContext:()=>({setTransform(){},clearRect(){},fillRect(){},beginPath(){},moveTo(){},lineTo(){},stroke(){}})});return elements.get(s);}},
    setTimeout:fn=>{timers.set(++id,fn);return id;},clearTimeout:n=>timers.delete(n),
    setInterval:fn=>{intervals.set(++id,fn);return id;},clearInterval:n=>intervals.delete(n)};
  context.WebSocket=class {
    constructor(url){this.url=url;this.readyState=0;this.sent=[];sockets.push(this);}
    send(msg){this.sent.push(JSON.parse(msg));}
    close(){this.readyState=3;if(this.onclose)this.onclose();}
  };
  vm.createContext(context);
  vm.runInContext(code.replace(/\bboot\(\);\s*$/, '')+'\nglobalThis.api={S,keyList,loadLocal,wsConnect,wsDisconnect,sendNote,playScore,stopScore,scoreDuration,scoreText,panic,recordEventsForPlayback,buildMidi,scoreLabel};',context);
  return {api:context.api,elements,sockets,timers,intervals,
    advance:ms=>{now+=ms;for(const fn of [...intervals.values()])fn();},
    retry:()=>{const pending=[...timers.values()];timers.clear();pending.forEach(fn=>fn());},
    open:s=>{s.readyState=1;s.onopen();},
    status:s=>s.onmessage({data:JSON.stringify({t:'status',open:true,port:'COM15'})})};
}
let a=app();a.api.loadLocal();assert.equal(a.api.keyList().length,25,'Fresh phones must show all 25 keys');
assert.equal(a.api.keyList()[0],60);assert.equal(a.api.keyList()[24],84);
a=app({nkeys:13});a.api.loadLocal();assert.equal(a.api.keyList().length,13,'Keep explicit saved key count');
a.api.wsConnect('ws://localhost:8080/ws');let old=a.sockets[0];a.open(old);a.status(old);
a.api.S.held.add(60);
// Mobile pointerup may clear UI state before the dead socket reports close.
a.api.S.held.clear();old.close();assert.equal(a.api.S.wsOk,false);
assert(a.timers.size,'Unexpected disconnect must schedule a reconnect');
a.retry();let next=a.sockets[1];assert(next,'Reconnect must create a replacement websocket');a.open(next);a.status(next);
assert(next.sent.some(m=>m.t==='note'&&m.n===60&&!m.on),'Release keys interrupted by a disconnect');
assert.equal(next.sent.filter(m=>m.t==='note'&&!m.on).length,50,'Recover both instruments even when pointerup already cleared held');
assert.deepEqual([...new Set(next.sent.filter(m=>m.t==='note'&&!m.on).map(m=>m.w))].sort(),[0,3]);
old.onclose();assert.equal(a.api.S.wsOk,true,'Stale old close must not break replacement');
a.api.sendNote(64,true,200);assert(next.sent.some(m=>m.t==='note'&&m.n===64&&m.on));
const offBefore=next.sent.filter(m=>m.t==='note'&&!m.on).length;
next.onmessage({data:JSON.stringify({t:'status',open:false,error:'SPP disconnected'})});
a.status(next);
assert.equal(next.sent.filter(m=>m.t==='note'&&!m.on).length,offBefore+50,'Recover serial loss for both instruments even if WS stayed open');
a.advance(16000);assert.equal(next.readyState,3,'Silent dead connections must be detected');
a.retry();next=a.sockets[2];a.open(next);a.status(next);
a.api.wsDisconnect();a.retry();assert.equal(a.sockets.length,3,'Manual disconnect must stay disconnected');
assert.equal(a.intervals.size,0,'Manual disconnect must stop heartbeat');
console.log('PASS default/saved keyboard, reconnect, interrupted key release, stale callbacks, heartbeat, manual stop, note delivery');

// Pending Bluetooth connection and stale errors must not look like a live board.
a=app();a.api.wsConnect('ws://localhost:8080/ws');next=a.sockets[0];a.open(next);
next.onmessage({data:JSON.stringify({t:'status',open:false,connecting:true,attempts:2,error:'old timeout'})});
assert.equal(a.elements.get('#bLat').textContent,'蓝牙连接中','Show a pending transport separately from a closed port');
a.status(next);
assert(!a.elements.get('#portHint').textContent.includes('old timeout'),'A recovered connection must clear its old error');
a.api.wsDisconnect();

// The transport must carry each part's timbre without changing the manual keyboard.
function connected(){const a=app();a.api.wsConnect('ws://localhost:8080/ws');const s=a.sockets[0];a.open(s);a.status(s);s.sent=[];return [a,s];}
const duet={name:'Duet fixture',tempo:120,notes:[[72,1],[74,1]],tracks:[
  {name:'EP',wave:0,vari:0,vib:0,gate:.8,notes:[[72,1,180],[74,1,190]]},
  {name:'Cello',wave:3,vari:2,vib:2,gate:1,notes:[[60,4,140]]},
]};
let sock;[a,sock]=connected();a.api.S.wave=3;a.api.S.vari=1;
a.api.playScore(duet);a.advance(20);
let ons=sock.sent.filter(m=>m.t==='note'&&m.on);
assert.deepEqual(ons.map(m=>[m.n,m.w,m.ep,m.v]),[[72,0,0,180],[60,3,2,140]],'Both instruments must sound together');
assert.equal(a.api.S.wave,3);assert.equal(a.api.S.vari,1,'Song playback must preserve manual selection');
assert.equal(a.api.scoreDuration(duet),2,'Duration includes the longer cello part');
a.advance(1010);
assert(!sock.sent.some(m=>m.n===60&&!m.on),'Cello must sustain beyond the melody');
a.api.stopScore();
assert(sock.sent.some(m=>m.n===60&&!m.on&&m.w===3&&m.ep===2),'Stop must release the sustained part with its timbre');
const stoppedCount=sock.sent.filter(m=>m.t==='note').length;a.advance(300);assert.equal(sock.sent.filter(m=>m.t==='note').length,stoppedCount,'Stopped songs must not schedule more notes');

[a,sock]=connected();a.api.playScore(duet);a.advance(20);a.api.panic();
assert(sock.sent.some(m=>m.n===60&&!m.on),'Panic must release score notes as well as manual keys');
assert.equal(a.intervals.size,1,'Panic stops the score but keeps the WS heartbeat');
[a,sock]=connected();a.api.playScore(duet);a.advance(20);
sock.onmessage({data:JSON.stringify({t:'status',open:false,error:'lost'})});
a.status(sock);sock.sent=[];a.advance(500);
assert(!sock.sent.some(m=>m.t==='note'&&m.on),'Serial recovery must not resume a stale song');

[a,sock]=connected();a.api.S.wave=3;a.api.S.vari=2;
a.api.playScore({name:'Old mono',tempo:120,notes:[[64,1,90]]});a.advance(20);
assert(sock.sent.some(m=>m.n===64&&m.on&&m.w===3&&m.ep===2&&m.v===90),'Legacy scores use selected timbre');
a.api.stopScore();sock.sent=[];
a.api.S.mode='serial';const writes=[];a.api.S.serWriter={write:bytes=>{writes.push(Array.from(bytes));return Promise.resolve();}};
a.api.playScore(duet);a.advance(20);
assert.deepEqual(writes.slice(0,2),[[165,128,72,180],[165,171,60,140]],'USB frames must preserve track timbre too');
a.api.stopScore();
assert.equal(a.api.scoreText(duet),'S120\nK72,1\nK74,1\n','Legacy offline export remains the explicit melody');
console.log('PASS duet timbres/overlap/duration/stop/panic/disconnect, legacy scores, USB framing, offline melody');

// New firmware routes off by (pitch, instrument), so UI ownership must match.
[a,sock]=connected();a.api.sendNote(64,1,180);a.api.S.wave=3;a.api.S.vari=2;a.api.sendNote(64,0,0);
assert.equal(sock.sent.filter(m=>m.t==='note').at(-1).w,0,'Manual key-up must retain key-down timbre after a selector change');
[a,sock]=connected();
const unison=JSON.parse(JSON.stringify(duet));unison.tracks[0].notes=[[60,1,180]];
a.api.playScore(unison);a.advance(20);sock.sent=[];a.api.stopScore();
assert.deepEqual(sock.sent.filter(m=>m.t==='note'&&!m.on).map(m=>m.w).sort(),[0,3],'Stop must release both parts of an unison');
[a,sock]=connected();a.api.S.rec=true;a.api.playScore(duet);a.advance(20);a.api.S.rec=false;
const recorded=a.api.recordEventsForPlayback();
assert.deepEqual(Array.from(recorded,e=>[e.n,e.part.wave,e.part.vari]),[[72,0,0],[60,3,2]],'Duet recording must retain per-note instruments');
a.api.stopScore();
a.api.S.recEv=[{t:0,n:64,on:1,v:120}];
assert(!a.api.recordEventsForPlayback()[0].part,'Old recordings keep the current-instrument fallback');
console.log('PASS instrument-specific recovery, manual key-up ownership, unison stop, duet recording and old recording compatibility');

// Decode actual MIDI bytes: independent same-pitch parts need separate channels.
function midiEvents(bytes){
  let p=22,t=0;const events=[];
  function vlq(){let v=0,b;do{b=bytes[p++];v=(v<<7)|(b&127);}while(b&128);return v;}
  while(p<bytes.length){
    t+=vlq();const k=bytes[p++];
    if(k===255){p++;const len=vlq();p+=len;continue;}
    if((k&240)===192){events.push({t,k,n:bytes[p++]});continue;}
    const n=bytes[p++],v=bytes[p++];events.push({t,k,n,v});
  }
  return events;
}
a=app();const ep={wave:0,vari:0,vib:0},cello={wave:3,vari:2,vib:2};
a.api.S.recEv=[{t:0,n:64,on:1,v:180,part:ep},{t:0,n:64,on:1,v:140,part:cello},
  {t:500,n:64,on:0,v:0,part:ep},{t:2000,n:64,on:0,v:0,part:cello}];
const midi=midiEvents(a.api.buildMidi());
assert.deepEqual(midi.filter(e=>(e.k&240)===128).map(e=>[e.t,e.k,e.n]),[[400,128,64],[1600,129,64]],'MIDI must preserve both instruments and independent release times');
assert.deepEqual(midi.filter(e=>(e.k&240)===192).map(e=>[e.k,e.n]),[[192,4],[193,42]],'MIDI programs must identify electric piano and cello');
assert(midi.filter(e=>(e.k&240)===144).every(e=>e.v>0&&e.v<=127),'MIDI velocity must fit 7 bits');
console.log('PASS exported MIDI payload, per-instrument channels/programs and independent unison note-offs');

// Exercise the actual shipped library, including every note and release.
const library=JSON.parse(fs.readFileSync('web/scores/index.json','utf8'));
assert.equal(library.length,6,'Only Little Star is a duet; do not list the old duet diagnostic');
for(let i=0;i<library.length;i++){
  const sc=JSON.parse(fs.readFileSync('web/scores/'+library[i].file,'utf8'));
  const expected=[[0,3],[0],[3],[3],[0],[0]][i];
  [a,sock]=connected();a.api.S.wave=expected.length===1&&expected[0]===0?3:0;
  const selected=a.api.S.wave;
  assert.equal(a.api.scoreLabel(sc),sc.arrangement,'Display the actual arrangement for each score');
  a.api.playScore(sc);a.advance(20);
  if(i===0)assert.deepEqual(sock.sent.filter(m=>m.t==='note'&&m.on).map(m=>m.w),[0,3],'Little Star starts both parts in the first callback');
  const end=a.api.scoreDuration(sc)*1000;
  for(let t=20;t<=end+40;t+=20){
    if(t%1000===0)a.status(sock); // Model the live relay's heartbeat replies.
    a.advance(20);
  }
  const notes=sock.sent.filter(m=>m.t==='note');
  assert.deepEqual([...new Set(notes.filter(m=>m.on).map(m=>m.w))].sort(),expected,sc.name+' sends only its assigned instrument(s)');
  for(const wave of expected){
    const wanted=sc.tracks.filter(p=>p.wave===wave).flatMap(p=>p.notes).filter(n=>n[0]);
    const starts=notes.filter(m=>m.on&&m.w===wave),ends=notes.filter(m=>!m.on&&m.w===wave);
    assert.deepEqual(starts.map(m=>m.n),wanted.map(n=>n[0]),sc.name+' keeps the complete note order');
    assert.equal(ends.length,starts.length,sc.name+' releases every scheduled note');
  }
  assert.equal(a.api.S.wave,selected,'Score playback preserves manual timbre selection');
  assert.equal(a.intervals.size,1,'Completed scores stop their scheduler and retain the WS heartbeat');
}
console.log('PASS actual six-score library: simultaneous Little Star duet, five explicit solo scores, all notes released');
