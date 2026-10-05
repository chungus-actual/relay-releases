(() => {
  'use strict';
  const native = window.webkit?.messageHandlers?.relayTerminal;
  const send = (type, data = {}) => native ? native.postMessage({type, ...data}) : window.chrome.webview.postMessage({type, ...data});
  const panes = new Map(), tabs = new Map(), splits = new Map();
  const workspace = document.getElementById('workspace'), parked = document.getElementById('parked');
  let state = {tabs:[],activeTab:null}, layoutKey = '', theme, resizeFrame, noticeTimer, editing;
  const defaults={cursorBlink:true,cursorStyle:'block',fontSize:14,fontFamily:'Cascadia Mono, Menlo, Consolas, monospace',lineHeight:1,scrollback:5000,minimumContrastRatio:4.5};
  let profileOptions={}, profileColors={};
  const terminalColors=()=>({...theme?colors(theme):{background:'#161719',foreground:'#e8e8e8'},...profileColors});
  const paths = {
    new:'<path d="M8 2v12M2 8h12"/>', close:'<path d="m4 4 8 8M12 4l-8 8"/>',
    columns:'<rect x="1.5" y="2" width="13" height="12" rx="1.5"/><path d="M8 2v12"/>',
    rows:'<rect x="1.5" y="2" width="13" height="12" rx="1.5"/><path d="M2 8h12"/>',
    zoom:'<path d="M6 2H2v4m8-4h4v4M2 10v4h4m8-4v4h-4"/>',
    restart:'<path d="M13 6a5.3 5.3 0 1 0 0 4M13 2v4H9"/>',
    closeView:'<rect x="1.5" y="2" width="13" height="12" rx="1.5"/><path d="m6 6 4 4m0-4-4 4"/>'
  };
  const icon = name => '<svg viewBox="0 0 16 16" aria-hidden="true">'+paths[name]+'</svg>';
  for (const button of document.querySelectorAll('[data-icon]')) button.innerHTML=icon(button.dataset.icon);
  const current = () => state.tabs.find(tab=>tab.id === state.activeTab);
  const command = (type, data={}) => send(type,{pane:current()?.activePane,...data});
  const notice = text => {
    const box=document.getElementById('notice'); box.textContent=text; box.hidden=!text;
    clearTimeout(noticeTimer); if(text) noticeTimer=setTimeout(()=>box.hidden=true,6000);
  };
  function beginRename(kind, id) {
    const data=kind==='tab'?state.tabs.find(t=>t.id===id):current()?.panes.find(p=>p.id===id);
    const label=kind==='tab'?tabs.get(id)?.select:panes.get(id)?.name;
    if(!data||!label)return;
    editing?.finish(true);
    const input=document.createElement('input');input.className='session-name-input';input.type='text';
    input.value=data.name;input.maxLength=80;input.setAttribute('aria-label','Rename '+data.name);
    input.autocomplete='off';input.spellcheck=false;
    const finish=(save,restoreFocus=false)=>{
      if(editing?.input!==input)return;
      editing=null;input.remove();label.hidden=false;
      const name=input.value.trim();
      if(save&&name!==data.name){
        if(name&&name.length<=80&&!/[\x00-\x1f\x7f-\x9f\u2028\u2029]/.test(name))send('rename-'+kind,{[kind]:id,name});
        else notice('Use a name of 1–80 characters on one line.');
      }
      if(restoreFocus)panes.get(current()?.activePane)?.terminal.focus();
    };
    editing={kind,id,input,finish};
    input.onkeydown=e=>{
      e.stopPropagation();if(e.isComposing)return;
      if(e.key==='Enter'||e.key==='Escape'){e.preventDefault();finish(e.key==='Enter',true);}
    };
    input.onblur=()=>finish(true);
    input.onpointerdown=e=>e.stopPropagation();
    label.hidden=true;label.before(input);input.focus();input.select();
  }
  function renameEvents(label, kind, id) {
    label.ondblclick=e=>{e.preventDefault();beginRename(kind,id);};
    label.onkeydown=e=>{if(e.key==='F2'){e.preventDefault();e.stopPropagation();beginRename(kind,id);}};
  }
  function colors(message) {
    const c=message.colors;
    return {background:c.background,foreground:c.foreground,cursor:c.accent,cursorAccent:c.background,
      selectionBackground:c.accent+'55',selectionForeground:c.foreground,
      black:'#202830',brightBlack:message.dark?'#9ba4af':'#536b82',
      red:message.dark?'#f07d82':'#a92336',green:message.dark?'#85df9b':'#186d36',yellow:message.dark?'#edc37f':'#835510',
      blue:message.dark?'#8abbff':'#235db7',magenta:message.dark?'#baa4ff':'#7250ba',cyan:message.dark?'#79d6d0':'#0f6770',
      white:message.dark?'#e8e8e8':'#353f49',brightWhite:c.foreground};
  }
  function paintFocus() {
    const active=current();
    for (const [id,pane] of panes) pane.element.classList.toggle('active',id===active?.activePane);
  }
  function focusPane(id, takeFocus=false) {
    const tab=current(); if (!tab?.panes.some(p=>p.id===id)) return;
    tab.activePane=id; paintFocus(); send('focus',{pane:id});
    if(takeFocus) panes.get(id)?.terminal.focus();
  }
  function fitAll() {
    // WebKit can suppress animation frames in retained/occluded windows. Shell
    // readiness and PTY dimensions must not depend on a screen repaint.
    if(native)clearTimeout(resizeFrame);else cancelAnimationFrame(resizeFrame);
    const schedule=native?callback=>setTimeout(callback,0):requestAnimationFrame;
    resizeFrame=schedule(()=>{
      for(const [id,pane] of panes) if(pane.host.clientWidth>8 && pane.host.clientHeight>8) {
        pane.fit.fit();
        if(!pane.ready){pane.ready=true;send('pane-ready',{pane:id,cols:pane.terminal.cols,rows:pane.terminal.rows});}
      }
    });
  }
  function createPane(data) {
    const element=document.createElement('section');element.className='terminal-pane';element.dataset.paneId=data.id;
    const bar=document.createElement('div');bar.className='pane-bar';
    const name=document.createElement('button');name.className='pane-name';name.textContent=data.name;renameEvents(name,'pane',data.id);
    const status=document.createElement('span');status.className='pane-state';
    const close=document.createElement('button');close.className='pane-close';close.innerHTML=icon('close');
    close.title='Close pane · Ends this shell';close.setAttribute('aria-label','Close '+data.name);
    close.onclick=e=>{e.stopPropagation();send('close-pane',{pane:data.id});};
    bar.append(name,status,close);
    const host=document.createElement('div');host.className='terminal-host';host.setAttribute('aria-label',data.name);
    element.append(bar,host);parked.append(element);
    const terminal=new Terminal({...defaults,...profileOptions,theme:terminalColors(),allowProposedApi:false});
    const fit=new FitAddon.FitAddon();terminal.loadAddon(fit);terminal.open(host);
    const observer=new ResizeObserver(fitAll);observer.observe(host);
    element.addEventListener('pointerdown',()=>focusPane(data.id));
    host.addEventListener('focusin',()=>focusPane(data.id));
    terminal.onData(text=>{for(let i=0;i<text.length;i+=16384)send('input',{pane:data.id,data:text.slice(i,i+16384)});});
    terminal.onResize(({cols,rows})=>send('resize',{pane:data.id,cols,rows}));
    let prefix=false;host.addEventListener('focusout',()=>prefix=false);
    terminal.attachCustomKeyEventHandler(event=>{
      if(event.type!=='keydown')return true;
      const consume=()=>{event.preventDefault();return false;};
      if(prefix){
        prefix=false;
        if(event.key==='%'||event.key==='"'){send('split',{pane:data.id,direction:event.key==='%'?'columns':'rows'});return consume();}
        if(event.key===','){beginRename('tab',state.activeTab);return consume();}
        const commands={c:'new',z:'zoom',n:'next',p:'previous',x:'close-pane'};
        if(commands[event.key]){send(commands[event.key],{pane:data.id});return consume();}
        if(event.ctrlKey&&event.key==='b'){send('input',{pane:data.id,data:'\x02'});return consume();}
      }
      if(event.ctrlKey&&event.key==='b'){prefix=true;return consume();}
      return true;
    });
    return {element,host,name,close,status,terminal,fit,observer,ready:false};
  }
  function ratio(node, element) {
    element.style[node.direction==='columns'?'gridTemplateColumns':'gridTemplateRows']=`${node.ratio}fr 5px ${1-node.ratio}fr`;
    const separator=element.children[1];separator.setAttribute('aria-valuenow',String(Math.round(node.ratio*100)));
  }
  function makeLayout(node) {
    if(node.pane)return panes.get(node.pane).element;
    const element=document.createElement('div');element.className='split';element.dataset.splitId=node.id;splits.set(node.id,element);
    const separator=document.createElement('div');separator.className='separator '+node.direction;separator.tabIndex=0;
    separator.setAttribute('role','separator');separator.setAttribute('aria-orientation',node.direction==='columns'?'vertical':'horizontal');
    separator.setAttribute('aria-label','Resize terminal panes');separator.setAttribute('aria-valuemin','15');separator.setAttribute('aria-valuemax','85');
    let dragging=false, value=node.ratio;
    const apply=v=>{value=Math.min(.85,Math.max(.15,v));node.ratio=value;ratio(node,element);fitAll();};
    const commit=()=>command('resize-layout',{split:node.id,ratio:value});
    separator.onpointerdown=e=>{dragging=true;separator.setPointerCapture(e.pointerId);e.preventDefault();};
    separator.onpointermove=e=>{if(!dragging)return;const r=element.getBoundingClientRect();apply(node.direction==='columns'?(e.clientX-r.left)/r.width:(e.clientY-r.top)/r.height);};
    separator.onpointerup=e=>{if(!dragging)return;dragging=false;separator.releasePointerCapture(e.pointerId);commit();};
    separator.onpointercancel=()=>{if(dragging){dragging=false;commit();}};
    separator.ondblclick=()=>{apply(.5);commit();};
    separator.onkeydown=e=>{const step=['ArrowLeft','ArrowUp'].includes(e.key)?-.05:['ArrowRight','ArrowDown'].includes(e.key)?.05:0;if(!step)return;e.preventDefault();apply(value+step);commit();};
    element.append(makeLayout(node.first),separator,makeLayout(node.second));ratio(node,element);return element;
  }
  const structure=node=>!node?null:node.pane||[node.id,node.direction,structure(node.first),structure(node.second)];
  function updateRatios(node){if(!node||node.pane)return;const element=splits.get(node.id);if(element)ratio(node,element);updateRatios(node.first);updateRatios(node.second);}
  function render(message) {
    state=message;
    if(editing&&!(editing.kind==='tab'?state.tabs:current()?.panes||[]).some(item=>item.id===editing.id))editing.finish(false);
    const live=new Set(state.tabs.flatMap(t=>t.panes.map(p=>p.id)));
    for(const [id,pane]of panes)if(!live.has(id)){pane.observer.disconnect();pane.terminal.dispose();pane.element.remove();panes.delete(id);}
    for(const tab of state.tabs)for(const data of tab.panes){
      if(!panes.has(data.id))panes.set(data.id,createPane(data));
      const pane=panes.get(data.id);pane.status.textContent=data.status==='Running'?'':data.status;
      pane.name.textContent=data.name;pane.name.title=data.name+' · Double-click or press F2 to rename';
      pane.host.setAttribute('aria-label',data.name);pane.close.setAttribute('aria-label','Close '+data.name);
    }
    const nav=document.getElementById('tabs');
    for(const [id,item]of tabs)if(!state.tabs.some(t=>t.id===id)){item.root.remove();tabs.delete(id);}
    for(const [index,tab]of state.tabs.entries()){
      let item=tabs.get(tab.id);
      if(!item){
        const root=document.createElement('div');root.className='tab';root.dataset.tabId=tab.id;
        const select=document.createElement('button');select.className='tab-select';select.setAttribute('role','tab');select.onclick=()=>send('select-tab',{tab:tab.id});
        const close=document.createElement('button');close.className='tab-close';close.innerHTML=icon('close');close.title='Close tab · Ends its shells';close.setAttribute('aria-label','Close '+tab.name);close.onclick=()=>send('close-tab',{tab:tab.id});
        renameEvents(select,'tab',tab.id);
        root.append(select,close);item={root,select,close};tabs.set(tab.id,item);
      }
      item.select.textContent=tab.name;item.select.title=tab.name+' · Double-click or press F2 to rename';item.close.setAttribute('aria-label','Close '+tab.name);item.select.setAttribute('aria-selected',String(tab.id===state.activeTab));
      item.root.classList.toggle('active',tab.id===state.activeTab);
      if(nav.children[index]!==item.root)nav.insertBefore(item.root,nav.children[index]||null);
    }
    const tab=current(), key=JSON.stringify([state.activeTab,tab?.zoomed?tab.activePane:structure(tab?.layout)]);
    workspace.hidden=!tab;document.getElementById('empty').hidden=!!tab;
    workspace.classList.toggle('multiple',!!tab&&tab.panes.length>1);
    if(key!==layoutKey){
      for(const pane of panes.values())parked.append(pane.element);
      workspace.replaceChildren();splits.clear();
      if(tab)workspace.append(tab.zoomed?panes.get(tab.activePane).element:makeLayout(tab.layout));
      layoutKey=key;fitAll();
    }
    updateRatios(tab?.layout);paintFocus();
    for(const id of ['split','split-rows','restart','zoom'])document.getElementById(id).disabled=!tab||(id==='zoom'&&tab.panes.length<2);
    document.getElementById('zoom').setAttribute('aria-label',tab?.zoomed?'Restore panes':'Expand pane');
    if(message.focus&&tab){
      const focused=document.activeElement;
      requestAnimationFrame(()=>{if(!editing&&document.activeElement===focused&&current()?.id===tab.id)panes.get(current().activePane)?.terminal.focus();});
    }
    if(message.focus)tabs.get(state.activeTab)?.root.scrollIntoView({block:'nearest',inline:'nearest'});
  }
  const receive = message=>{
    const pane=panes.get(message.pane);
    if(message.type==='workspace')render(message);
    if(message.type==='output'){
      const data=message.encoding==='base64'?Uint8Array.from(atob(message.data),c=>c.charCodeAt(0)):message.data;
      if(!native){pane?.terminal.write(data);return;}
      return new Promise(resolve=>{
        if(pane){
          // Disposing a pane can discard xterm's pending callbacks.
          const timer=setTimeout(resolve,1000);
          pane.terminal.write(data,()=>{clearTimeout(timer);resolve();});
        }
        else resolve();
      });
    }
    if(message.type==='status'){if(pane)pane.status.textContent=message.data;notice(message.data);}
    if(message.type==='reset')pane?.terminal.reset();
    if(message.type==='profile'&&native){
      profileOptions=message.options||{};profileColors=message.colors||{};
      const select=document.getElementById('profile');
      select.replaceChildren(new Option('Relay defaults', ''));
      for(const item of message.profiles||[])select.append(new Option(item.name,item.id));
      if(message.selected)select.append(new Option('Reimport current profile…','__reimport'));
      select.append(new Option('Rescan profiles…','__rescan'));
      select.value=message.selected||'';select.hidden=!message.profiles?.length;
      select.dataset.selected=message.selected||'';
      select.options[0].text=message.selected?'Relay defaults':'Import profile…';
      select.title='Import display settings · '+(profileOptions.fontFamily||defaults.fontFamily);
      for(const pane of panes.values()){
        for(const [key,value]of Object.entries({...defaults,...profileOptions}))pane.terminal.options[key]=value;
        pane.terminal.options.theme=terminalColors();
      }
      document.documentElement.style.setProperty('--terminal-background',profileColors.background||'var(--background)');
      fitAll();
    }
    if(message.type==='theme'){
      theme=message;for(const [name,value]of Object.entries(message.colors))document.documentElement.style.setProperty('--'+name,value);
      document.documentElement.style.colorScheme=message.dark?'dark':'light';
      for(const pane of panes.values())pane.terminal.options.theme=terminalColors();
    }
  };
  if(native)window.__relayTerminalReceive=receive;
  else window.chrome.webview.addEventListener('message',event=>receive(event.data));
  for(const type of ['new','restart','zoom','close-view'])document.getElementById(type).onclick=()=>command(type);
  document.getElementById('empty-new').onclick=()=>command('new');
  document.getElementById('profile').onchange=event=>{
    const select=event.target;
    if(select.value==='__rescan')command('refresh-profiles');
    else command('import-profile',{id:select.value==='__reimport'?select.dataset.selected:select.value});
  };
  document.getElementById('split').onclick=()=>command('split',{direction:'columns'});
  document.getElementById('split-rows').onclick=()=>command('split',{direction:'rows'});
  document.getElementById('tabs').onkeydown=e=>{if(!['ArrowLeft','ArrowRight'].includes(e.key))return;e.preventDefault();command(e.key==='ArrowLeft'?'previous':'next');};
  send('ready');
})();
