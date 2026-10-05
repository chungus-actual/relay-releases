(async () => {
  const failures = [], passed = [];
  const check = (value, name) => { (value ? passed : failures).push(name); };
  const wait = async predicate => {
    for(let i=0;i<200;i++) { if(predicate()) return; await new Promise(r=>setTimeout(r,20)); }
    throw new Error('Media fixture timed out');
  };
  const play = async (item, step) => {
    let timer;
    try {
      await Promise.race([item.play(), new Promise((_, reject) => {
        timer=setTimeout(()=>reject(new Error('playback did not start')),5000);
      })]);
    } catch(error) { throw new Error(step+': '+error); }
    finally { clearTimeout(timer); }
  };
  const bytes = new ArrayBuffer(44+3200), data = new DataView(bytes);
  const text = (at,value) => [...value].forEach((c,i)=>data.setUint8(at+i,c.charCodeAt(0)));
  text(0,'RIFF');data.setUint32(4,3236,true);text(8,'WAVE');text(12,'fmt ');data.setUint32(16,16,true);
  data.setUint16(20,1,true);data.setUint16(22,1,true);data.setUint32(24,8000,true);data.setUint32(28,16000,true);
  data.setUint16(32,2,true);data.setUint16(34,16,true);text(36,'data');data.setUint32(40,3200,true);
  const url = URL.createObjectURL(new Blob([bytes],{type:'audio/wav'}));
  const audio = new Audio(url); audio.muted=true;
  const replacementURL = URL.createObjectURL(new Blob([bytes],{type:'audio/wav'}));
  const video = document.createElement('video');
  try {
    await play(audio, 'first notification');
    check(!window.__relayMedia.read().available, 'Detached notification is not transport media');
    await wait(()=>!audio.hasAttribute('src') && audio.readyState === 0);
    check(audio.paused && audio.readyState === 0 && !audio.hasAttribute('src'), 'Finished short notification releases its native playback source');
    await play(audio, 'repeated notification');
    check(audio.getAttribute('src') === url, 'The service can play its next notification using the same Audio object');
    await wait(()=>!audio.hasAttribute('src') && audio.readyState === 0);
    check(!(await window.__relayMedia.act('play')), 'Relay play cannot replay a finished notification');
    audio.controls=true; audio.src=url; await play(audio, 'short recording');
    await wait(()=>audio.ended);
    check(audio.hasAttribute('src'), 'User-controlled short recordings retain their source');
    video.src=url; video.muted=true; video.controls=true; video.preload='auto';
    document.body.append(video); await wait(()=>video.readyState >= 2);
    check(!window.__relayMedia.read().available, 'Preloaded but unplayed media does not create transport controls');
    video.controls=false; video.autoplay=true; video.loop=true;
    await play(video, 'muted preview');
    check(!window.__relayMedia.read().available && !window.__relayMedia.read().playing, 'Slack-style muted autoplay loop is not now playing');
    check(!(await window.__relayMedia.act('pause')) && !video.paused, 'Transport does not act on decorative autoplay');
    video.pause();
    check(!window.__relayMedia.read().available, 'Pausing a decorative loop does not create a resume control');
    video.muted=false; video.volume=0; await play(video, 'zero-volume preview');
    check(!window.__relayMedia.read().available, 'Zero-volume autoplay is also ignored');
    video.muted=true; video.volume=1; video.controls=true;
    check(window.__relayMedia.read().available && window.__relayMedia.read().playing, 'Video in a messaging service has transport controls');
    await window.__relayMedia.act('float'); await window.__relayMedia.act('float');
    check(document.querySelectorAll('#__relayFloatingStyle').length === 1 && video.hasAttribute('data-relay-floating'), 'Repeated float requests keep one video presentation');
    await window.__relayMedia.act('pause'); check(video.paused, 'Floating media can pause');
    const before = video.currentTime;
    await window.__relayMedia.act('dock'); await window.__relayMedia.act('dock');
    check(!document.getElementById('__relayFloatingStyle') && !video.hasAttribute('data-relay-floating') && video.currentTime === before, 'Dock restores the page without restarting playback');
    check(!(await window.__relayMedia.act('unsupported')), 'Unknown actions do not toggle playback');
    video.controls=false;
    // WebKit can report no played range when paused before the first frame.
    // Exercise that native boundary on every engine, independent of timing.
    Object.defineProperty(video, 'played', {configurable:true, value:{length:0}});
    check(window.__relayMedia.read().available, 'An accepted player stays resumable when muted or its custom controls change');
    delete video.played;
    video.src=replacementURL; await play(video, 'replacement preview');
    check(!window.__relayMedia.read().available, 'Replacing an accepted clip with silent autoplay clears stale eligibility');
    video.remove(); video.pause(); video.removeAttribute('src'); video.load();
    check(!window.__relayMedia.read().available, 'Removing the media clears the bridge');
    audio.controls=false; audio.src=url; await play(audio, 'final notification'); await wait(()=>!audio.hasAttribute('src') && audio.readyState === 0);
    audio.load(); audio.play().catch(()=>{}); await new Promise(r=>setTimeout(r,30));
    check(!audio.hasAttribute('src'), 'Explicit load clears a saved notification source');
  } finally { video.pause(); video.remove(); video.removeAttribute('src'); video.load(); audio.pause(); audio.removeAttribute('src'); audio.load(); URL.revokeObjectURL(url); URL.revokeObjectURL(replacementURL); }
  return {passed,failures};
})()
