(async () => {
  const failures = [], passed = [];
  const check = (value, name) => { (value ? passed : failures).push(name); };
  const session = navigator.mediaSession, proto = Object.getPrototypeOf(session);
  const native = name => Object.getOwnPropertyDescriptor(proto, name).get.call(session);
  let calls = 0;
  session.metadata = new MediaMetadata({title:'Opt-out fixture', artist:'Relay'});
  session.playbackState = 'playing';
  session.setActionHandler('play', () => calls++);
  session.setActionHandler('pause', () => calls++);
  session.setActionHandler('nexttrack', () => calls++);
  session.setPositionState({duration:20, position:5, playbackRate:1});
  check(session.metadata.title === 'Opt-out fixture' && session.playbackState === 'playing', 'Provider-facing state stays usable');
  check(native('metadata') === null && native('playbackState') === 'none', 'Website metadata and playback state are not published to the native session');
  session.metadata=null; session.playbackState='none';
  session.metadata=new MediaMetadata({title:'Later update'}); session.playbackState='playing';
  check(native('metadata') === null && native('playbackState') === 'none', 'Repeated provider updates cannot restore native session state');
  const bytes=new ArrayBuffer(44+16000), data=new DataView(bytes);
  const text=(at,value)=>[...value].forEach((c,i)=>data.setUint8(at+i,c.charCodeAt(0)));
  text(0,'RIFF');data.setUint32(4,16036,true);text(8,'WAVE');text(12,'fmt ');data.setUint32(16,16,true);
  data.setUint16(20,1,true);data.setUint16(22,1,true);data.setUint32(24,8000,true);data.setUint32(28,16000,true);
  data.setUint16(32,2,true);data.setUint16(34,16,true);text(36,'data');data.setUint32(40,16000,true);
  const url=URL.createObjectURL(new Blob([bytes],{type:'audio/wav'})), audio=new Audio(url);
  audio.controls=true; audio.loop=true; audio.muted=true; document.body.append(audio);
  try {
    let timer;
    try { await Promise.race([audio.play(), new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Opt-out playback timed out')),4000);})]); }
    finally { clearTimeout(timer); }
    check(!audio.paused, 'Opt-out preserves page playback');
    const reading=window.__relayMedia.read();
    check(!reading.playing && !reading.available && !reading.previous && !reading.next && !reading.title, 'Opt-out never exposes Relay playback controls');
    for (const action of ['play','pause','nexttrack','float']) check(!(await window.__relayMedia.act(action)), 'Opt-out refuses Relay action: '+action);
    check(calls === 0 && !audio.paused, 'Disabled transport neither invokes provider handlers nor pauses the page');
    session.setActionHandler('nexttrack', null);
    // WebKit can independently change native playbackState for real HTML media.
    check(native('metadata') === null, 'Playing HTML media does not publish the withheld website metadata');
    audio.loop=false; audio.controls=false; audio.remove(); audio.pause();
    for (let i=0;i<100 && audio.hasAttribute('src');i++) await new Promise(resolve=>setTimeout(resolve,20));
    check(!audio.hasAttribute('src'), 'Opt-out still cleans up stopped notifications when the site retains metadata');
  } finally {
    audio.pause(); audio.removeAttribute('src'); audio.load(); audio.remove(); URL.revokeObjectURL(url);
    session.metadata=null; session.playbackState='none';
    for (const action of ['play','pause','nexttrack']) session.setActionHandler(action,null);
  }
  return {passed, failures};
})()
