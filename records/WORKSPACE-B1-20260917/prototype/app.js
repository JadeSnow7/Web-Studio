/* B1 offline interaction prototype. Runtime, persistence and provider work are simulated. */
(function(){'use strict';
const $=id=>document.getElementById(id), esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])), uid=p=>p+'-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,7), now=()=>new Date().toISOString();
const fixture=r=>`来源：${r.name}\n类型：${r.type==='web'?'网页':r.type==='ssh'?'SSH':'终端'}\n目的地：${r.detail}\n\n这是离线固定示例。它用于演示读取、精确预览和发送链路，不读取真实正文。`;
const state={spaces:[],activeId:'',modalReturn:null};
const newQuestion=()=>({id:uid('question'),draft:'',selectedIds:[],removedIds:[],snapshots:[],previewConfirmed:false,messages:[]});
const newSpace=(name,temp)=>{const s={id:uid(temp?'temp':'space'),name,temp:!!temp,archived:false,closed:false,loaded:true,resources:[],layout:[],focusIndex:0,mode:'content',questions:[newQuestion()],currentQuestionID:'',activeRequest:null,saveError:false,dirty:!!temp,savedDescriptor:null,restartCount:0};s.currentQuestionID=s.questions[0].id;return s};
const initial=newSpace('临时空间',true);state.spaces=[initial];state.activeId=initial.id;
const active=()=>state.spaces.find(s=>s.id===state.activeId)||state.spaces[0], question=(s=active())=>s.questions.find(q=>q.id===s.currentQuestionID)||s.questions[0], resource=(s,id)=>s.resources.find(r=>r.id===id);
function markDirty(s){s.dirty=true;if(!s.temp&&!s.saveError){s.savedDescriptor=descriptor(s);s.dirty=false}}
function fallback(exclude){let s=state.spaces.find(x=>x.id!==exclude&&!x.archived&&!x.closed&&x.loaded);if(s)return s;const t=newSpace('临时空间',true);state.spaces.push(t);return t}
function unload(s){s.loaded=false;s.closed=true;s.activeRequest=null;s.questions=[newQuestion()];s.currentQuestionID=s.questions[0].id;s.resources.forEach(r=>{r.runtime=null;r.state=r.type==='web'?'网页 · 可见':'待启动'});}
function reopen(s){if(s.archived){if(s.saveError)return false;s.archived=false;if(!save(s)){s.archived=true;return false;}}if(!s.loaded||s.closed){if(s.savedDescriptor)restoreDescriptor(s,s.savedDescriptor);s.loaded=true;s.closed=false;s.questions=[newQuestion()];s.currentQuestionID=s.questions[0].id;s.activeRequest=null;s.resources.forEach(r=>{r.runtime=null;r.state=r.type==='web'?'网页 · 可见':'待启动'});render();announce(`已重新打开「${s.name}」`)}return true}
const announce=message=>{const el=document.createElement('div');el.className='announcement';el.textContent=message;document.body.append(el);setTimeout(()=>el.remove(),2300)};
const descriptor=s=>({id:s.id,name:s.name,temp:s.temp,archived:s.archived,resources:s.resources.map(({id,type,name,detail})=>({id,type,name,detail})),layout:[...s.layout],mode:s.mode,focusIndex:s.focusIndex});
function save(s){if(s.saveError){announce('保存失败仍未解决：内存配置保留');return false}s.temp=false;s.savedDescriptor=descriptor(s);s.dirty=false;s.saveError=false;render();announce(`已模拟保存「${s.name}」的配置`);return true}
function render(){const s=active(),q=question(s);$('activeName').textContent=s.name;$('crumbName').textContent=s.name;$('saveState').textContent=s.saveError?'尚未保存 · 可重试':s.temp||s.dirty?'配置有改动 · 模拟未保存':s.archived?'已归档 · 可恢复':s.closed?'已关闭 · 可打开':'配置已保存';$('saveState').className='save-state '+(s.saveError?'error':'');renderSpaces();renderResources();renderWorkspace(s,q);renderAI(s,q);setMode(s.mode,false)}
function renderSpaces(){const row=s=>`<div class="space ${s.id===state.activeId?'active':''}"><button class="space-button" data-space="${esc(s.id)}"><span class="space-dot"></span><span><b>${esc(s.name)}</b><small>${s.resources.length} 个资源${s.closed?' · 已关闭':''}${s.activeRequest?' · 请求中':''}</small></span></button></div>`;const open=state.spaces.filter(s=>!s.archived),arch=state.spaces.filter(s=>s.archived);$('spaceList').innerHTML=open.map(row).join('')+(arch.length?'<div class="list-label">归档 · 可恢复</div>'+arch.map(row).join(''):'');$('spaceList').querySelectorAll('[data-space]').forEach(b=>b.onclick=()=>{const s=state.spaces.find(x=>x.id===b.dataset.space);if(reopen(s))switchSpace(s.id)})}
function renderResources(){const s=active();$('resourceList').innerHTML=s.resources.length?s.resources.map(r=>{const side=s.layout.indexOf(r.id),running=r.runtime?.state==='running';return`<button class="resource ${side>=0?'selected':''}" data-resource="${esc(r.id)}"><span class="resource-icon">${r.type==='web'?'◉':r.type==='ssh'?'⌁':'▣'}</span><span class="resource-info"><b>${esc(r.name)}</b><small>${esc(r.state)}${side>=0?' · '+(side===0?'左':'右'):''}${running?' · 运行 '+esc(r.runtime.instanceId):''}</small></span><span class="resource-menu" data-resource-action="${esc(r.id)}">⋯</span></button>`}).join(''):'<p class="empty-side">这里没有资源。空间不会自动创建网页。</p>';$('resourceList').querySelectorAll('[data-resource]').forEach(b=>b.onclick=e=>{if(e.target.closest('[data-resource-action]'))return;focusResource(b.dataset.resource)});$('resourceList').querySelectorAll('[data-resource-action]').forEach(b=>b.onclick=e=>{e.stopPropagation();resourceActions(b.dataset.resourceAction)})}
function renderWorkspace(s,q){const panes=s.layout.map(id=>resource(s,id)).filter(Boolean);$('workspaceView').innerHTML=`<div class="workspace-grid"><section class="main-column"><div class="pane-grid ${panes.length>1?'split':''}">${panes.length?panes.map((r,i)=>pane(r,i,s)).join(''):`<div class="empty-state"><span class="empty-mark">＋</span><h1>从一个资源开始</h1><p>这是一个空的临时空间。显式添加网页、终端或 SSH 后，资源描述和后果会保持清楚。</p><div class="empty-actions"><button class="btn primary" data-add="web">打开网页</button><button class="btn" data-add="terminal">新建终端</button><button class="btn" data-add="ssh">连接 SSH</button></div></div>`}</div>${sourceCard(s,q)}</section></div>`;$('workspaceView').querySelectorAll('[data-add]').forEach(b=>b.onclick=()=>addResource(b.dataset.add));$('workspaceView').querySelectorAll('[data-pane]').forEach(p=>p.onclick=()=>{s.focusIndex=s.layout.indexOf(p.dataset.pane);markDirty(s);render()});$('workspaceView').querySelectorAll('[data-runtime]').forEach(b=>b.onclick=e=>{e.stopPropagation();toggleRuntime(b.dataset.runtime)});$('workspaceView').querySelectorAll('[data-close-resource]').forEach(b=>b.onclick=e=>{e.stopPropagation();closeResource(b.dataset.closeResource)});$('workspaceView').querySelectorAll('[data-question]').forEach(b=>b.onclick=()=>{s.currentQuestionID=b.dataset.question;render()});$('workspaceView').querySelector('#newQuestion')?.addEventListener('click',()=>{const n=newQuestion();s.questions.push(n);s.currentQuestionID=n.id;markDirty(s);render()});$('workspaceView').querySelector('#readSources')?.addEventListener('click',()=>readSources(s,q));$('workspaceView').querySelector('#previewSources')?.addEventListener('click',()=>previewSources(s,q));$('workspaceView').querySelectorAll('[data-source]').forEach(b=>b.onclick=()=>toggleSource(s,q,b.dataset.source));$('workspaceView').querySelectorAll('[data-remove-source]').forEach(b=>b.onclick=()=>removeSource(s,b.dataset.removeSource))}
function pane(r,i,s){const running=r.runtime?.state==='running';return`<article class="pane ${i===s.focusIndex?'focused':''}" data-pane="${esc(r.id)}"><div class="pane-body"><div class="resource-kicker">${r.type==='web'?'网页':r.type==='ssh'?'SSH':'终端'} <span>${esc(r.state)}</span></div>${r.type==='web'?`<span class="fake-url">${esc(r.detail)}</span><h2>${esc(r.name)}</h2><p>可见网页资源的离线示意。读取动作会生成属于本次问题的固定快照。</p>`:`<div class="terminal"><div><span class="prompt">demo@studio</span>:${esc(r.detail)}$ <span class="dim">echo resource</span></div><div>资源描述已恢复；输出为模拟内容。</div><div class="dim">${running?'实例 '+esc(r.runtime.instanceId)+' 正在运行':'待启动；恢复不会启动会话'}</div></div>`}</div><div class="pane-actions">${r.type!=='web'?`<button class="btn small" data-runtime="${esc(r.id)}">${running?'结束会话':'明确启动'}</button>`:''}<button class="btn small" data-close-resource="${esc(r.id)}">关闭资源</button></div></article>`}
function sourceCard(s,q){const rows=s.resources.length?s.resources.map(r=>{const selected=q.selectedIds.includes(r.id),snap=q.snapshots.find(x=>x.sourceId===r.id),failed=r.readFailure;return`<div class="source-row"><button class="source-check ${selected?'checked':''}" data-source="${esc(r.id)}" aria-label="${selected?'取消选择':'选择'} ${esc(r.name)}">${selected?'✓':'○'}</button><span class="source-icon">${failed?'!':'◉'}</span><span class="source-meta"><b>${esc(r.name)}</b><small>${failed?'读取失败：可重读或明确移除':snap?`已读取 · ${snap.collectedAt} · ${snap.chars} 字 · ${snap.truncated?'已截断':'未截断'}`:'待读取 · 选择后明确读取'}</small></span><span class="tag ${failed?'fail':snap?'ready':''}">${failed?'读取失败':snap?'已读取':'待读取'}</span>${failed?`<button class="btn small" data-remove-source="${esc(r.id)}">移除来源</button>`:''}</div>`}).join(''):'<p class="empty-card">添加资源后，可以逐个选择来源。</p>';const tabs=s.questions.map(x=>`<button class="question-tab ${x.id===s.currentQuestionID?'active':''}" data-question="${esc(x.id)}">${x.draft?'草稿 · ':''}${x.messages.length?'已发送':'新问题'}</button>`).join('');const valid=q.snapshots.length&&q.snapshots.every(x=>q.selectedIds.includes(x.sourceId));return`<section class="card source-card"><div class="card-heading"><div><span class="eyebrow">本次问题</span><h2>资料准备</h2></div><button class="btn small" id="newQuestion">＋ 新问题</button></div><div class="question-tabs">${tabs}</div><div class="flowline"><b>选择资料</b><span>→</span><b>明确读取</b><span>→</span><b>精确预览</b><span>→</span><b>发送</b></div><div class="sources">${rows}</div><div class="card-actions"><button class="btn" id="readSources">读取所选资料</button><button class="btn primary" id="previewSources" ${valid?'':'disabled'}>查看精确预览</button><span class="hint">选择变化会清除旧快照</span></div></section>`}
function renderAI(s,q){const msgs=q.messages.length?q.messages.map(m=>`<div class="msg ${m.role}">${esc(m.text)}</div>`).join(''):'<div class="msg system">先选择资料、读取并确认精确预览。</div>';$('aiView').innerHTML=`<div class="messages">${msgs}${s.activeRequest?`<div class="msg pending">模拟请求处理中 · ${esc(s.activeRequest.requestId)}</div>`:''}</div><div class="composer"><textarea id="question" placeholder="输入问题，草稿会随空间切换保留…">${esc(q.draft)}</textarea><div class="composer-actions"><small>${q.draft?'草稿已保留':'未发送草稿'} · 快照 ${q.snapshots.length} 份</small><button class="btn primary" id="sendQuestion" ${s.activeRequest?'disabled':''}>发送问题</button></div></div>`;$('aiView').querySelector('#question').addEventListener('input',e=>{q.draft=e.target.value});$('aiView').querySelector('#sendQuestion').addEventListener('click',()=>sendQuestion(s,q))}
function setMode(mode,announceMode){active().mode=mode;if(announceMode)markDirty(active());document.querySelectorAll('[data-mode]').forEach(b=>{b.classList.toggle('active',b.dataset.mode===mode);b.setAttribute('aria-selected',b.dataset.mode===mode)});document.body.classList.toggle('ai-only',mode==='ai');if(announceMode)announce(mode==='ai'?'AI 面板已显示，草稿保留':'内容面板已显示')}
function switchSpace(id){if(id===state.activeId)return;const input=$('question');if(input)question().draft=input.value;state.activeId=id;render();announce(`已切换到「${active().name}」`)}
function focusResource(id) {
  const s = active();
  if (!s.layout.includes(id)) {
    if (!s.layout.length) s.layout = [id];
    else s.layout[s.focusIndex] = id;
    s.focusIndex = Math.max(0, s.layout.indexOf(id));
    markDirty(s);
  } else {
    s.focusIndex = Math.max(0, s.layout.indexOf(id));
  }
  render();
}
function addResource(type) {
  const s = active();
  const r = {id:uid(type), type, name:type==='web'?'新网页':type==='ssh'?'SSH 连接':'新终端', detail:type==='web'?'https://example.local/new':type==='ssh'?'user@example.host':'/Users/demo/project', state:type==='web'?'网页 · 可见':'待启动', runtime:null, readFailure:false};
  s.resources.push(r);
  focusResource(r.id);
  markDirty(s);
  render();
  announce(`已添加${type==='web'?'网页':type==='ssh'?' SSH 描述':'终端描述'}；运行仍需明确启动`);
}
function toggleRuntime(id){const r=resource(active(),id);if(!r)return;if(r.runtime?.state==='running'){r.runtime.state='ended';r.state='已结束'}else{r.runtime={state:'running',instanceId:uid('instance')};r.state='运行中'}render();announce(r.runtime.state==='running'?`已启动「${r.name}」`:`已结束会话；「${r.name}」描述保留`)}
function resourceActions(id){const r=resource(active(),id);openModal('资源操作',`${r.name} · ${r.detail}`,`<button class="btn modal-wide" data-action="left">在左侧显示</button><button class="btn modal-wide" data-action="right">在右侧显示</button><button class="btn modal-wide" data-action="failure">注入读取失败</button><button class="btn danger modal-wide" data-action="close">关闭资源</button>`,[{label:'取消',cancel:true}]);$('modalBody').querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>{closeModal();if(b.dataset.action==='failure'){r.readFailure=true;render();announce('已注入来源读取失败，可重读或移除')}else if(b.dataset.action==='close')closeResource(id);else showInPane(id,b.dataset.action==='right'?1:0)})}
function showInPane(id,side){const s=active();if(s.layout.includes(id))s.focusIndex=s.layout.indexOf(id);else{s.layout[side]=id;s.layout=s.layout.filter(Boolean);s.focusIndex=s.layout.indexOf(id)}markDirty(s);render()}
function closeResource(id){const s=active(),r=resource(s,id);if(!r)return;const finish=()=>{s.resources=s.resources.filter(x=>x.id!==id);s.layout=s.layout.filter(x=>x!==id);s.focusIndex=Math.min(Math.max(0,s.focusIndex),Math.max(0,s.layout.length-1));s.questions.forEach(q=>{q.selectedIds=q.selectedIds.filter(x=>x!==id);q.snapshots=q.snapshots.filter(x=>x.sourceId!==id);q.previewConfirmed=false});markDirty(s);render();announce(`已关闭「${r.name}」；资源描述已移除`)};if(r.runtime?.state==='running')openModal('关闭运行中的资源',`「${r.name}」有一个模拟运行实例。关闭资源会结束会话并移除描述。`,'',[{label:'取消',cancel:true},{label:'结束并关闭',primary:true,action:finish}]);else finish()}
function toggleSource(s,q,id){q.selectedIds=q.selectedIds.includes(id)?q.selectedIds.filter(x=>x!==id):[...q.selectedIds,id];q.snapshots=[];q.previewConfirmed=false;render()}
function removeSource(s,id){const r=resource(s,id);if(r){r.readFailure=false}const q=question(s);q.selectedIds=q.selectedIds.filter(x=>x!==id);q.snapshots=q.snapshots.filter(x=>x.sourceId!==id);q.previewConfirmed=false;render();announce('已明确移除失败来源')}
function readSources(s,q){if(!q.selectedIds.length)return announce('请先逐个选择来源');const failed=q.selectedIds.map(id=>resource(s,id)).find(r=>r?.readFailure);if(failed){failed.readFailure=false;markDirty(s);announce(`已重读「${failed.name}」；再次读取将生成快照`);return render()}q.snapshots=q.selectedIds.map(id=>{const r=resource(s,id),text=fixture(r);return{sourceId:id,text,chars:text.length,collectedAt:now(),truncated:false,instanceId:r.runtime?.instanceId||null}});q.previewConfirmed=false;markDirty(s);render();announce(`已读取 ${q.snapshots.length} 份来源；请审阅精确预览`)}
function previewSources(s,q){if(!q.snapshots.length||q.snapshots.some(x=>!q.selectedIds.includes(x.sourceId)))return announce('请先读取当前选择的来源');const html=q.snapshots.map(x=>`<article class="snapshot"><b>${esc(resource(s,x.sourceId).name)}</b><small>${esc(x.collectedAt)} · ${x.chars} 字 · 未截断</small><pre>${esc(x.text)}</pre></article>`).join('');openModal('精确预览 · 将发送的快照','确认后，发送只会携带当前问题和以下固定快照。',html,[{label:'取消',cancel:true},{label:'确认预览',primary:true,action:()=>{q.previewConfirmed=true;markDirty(s);render();announce('精确预览已确认，可以发送')}}])}
function sendQuestion(s,q){const input=$('question');q.draft=input?input.value.trim():q.draft.trim();if(!q.draft)return announce('请输入问题');if(!q.previewConfirmed)return announce('请先确认精确预览');if(s.activeRequest)return announce('当前空间已有一个模拟请求');const frozen={question:q.draft,snapshots:q.snapshots.map(x=>({...x})),spaceId:s.id,questionId:q.id,requestId:uid('request')};q.messages.push({role:'user',text:q.draft});q.draft='';s.activeRequest={requestId:frozen.requestId,questionId:frozen.questionId,startedAt:now(),status:'pending'};markDirty(s);render();setTimeout(()=>{const owner=state.spaces.find(x=>x.id===frozen.spaceId),target=owner?.questions.find(x=>x.id===frozen.questionId);if(!owner||!target||owner.activeRequest?.requestId!==frozen.requestId)return;target.messages.push({role:'assistant',text:`模拟回复已归档到「${owner.name}」；本次请求绑定 ${frozen.snapshots.length} 份快照。`});owner.activeRequest=null;render()},700)}
function saveAs(){const s=active();openModal(s.temp?'保存临时空间':'新建工作空间','只保存空间名称、资源描述和布局；问题正文、快照、进程与请求不会保存。',`<input id="spaceName" aria-label="空间名称" value="${esc(s.temp?'新工作空间':'新空间')}">`,[{label:'取消',cancel:true},{label:'保存',primary:true,action:()=>{const name=$('spaceName').value.trim()||'未命名空间';if(s.temp){s.name=name;markDirty(s);save(s)}else{const n=newSpace(name,false);save(n);state.spaces.push(n);state.activeId=n.id;render();announce(`已创建「${name}」`)}}}])}
function closeSpace(s, archive) {
  const running = s.resources.filter(r => r.runtime?.state === 'running').length;
  const requests = s.activeRequest ? 1 : 0;
  const body = `<div class="impact"><b>${esc(s.name)}</b><span>${s.resources.length} 个资源 · ${running} 个运行中终端 · ${requests} 个活动请求</span><small>取消不会清理会话。确认后才开始模拟关闭。</small></div>`;
  const actions = [{label:'取消', cancel:true}];
  if (s.saveError || s.dirty || s.temp) {
    actions.push({label:'重试保存', action: () => { if (s.temp) { openModal('先命名临时空间','保存前请输入名称。','<input id="spaceNameRetry" aria-label="空间名称" value="新工作空间">',[{label:'取消',cancel:true},{label:'保存并继续',primary:true,action:()=>{const name=$("spaceNameRetry").value.trim();if(!name)return announce('请输入空间名称');s.name=name;s.saveError=false;if(save(s))closeSpace(s,archive);}}]); } else { s.saveError=false; if (save(s)) closeSpace(s,archive); } }});
    actions.push({label:'不保存并关闭', action: () => {
      if (s.savedDescriptor) restoreDescriptor(s, s.savedDescriptor); else { s.resources = []; s.layout = []; }
      s.dirty = false; s.saveError = false;
      if (s.temp) state.spaces = state.spaces.filter(x => x.id !== s.id); else unload(s);
      state.activeId = fallback(s.id).id;
      render(); announce(archive ? '未归档，只关闭并丢弃改动' : '已丢弃本次配置并关闭空间');
    }});
  } else {
    actions.push({label: archive ? '确认归档' : '确认关闭', primary:true, action: () => {
      if (archive) { s.archived = true; if (!save(s)) { s.archived = false; return; } }
      else if (s.dirty && !save(s)) return;
      unload(s);
      state.activeId = fallback(s.id).id;
      render(); announce(archive ? '已关闭并归档空间' : '已关闭空间；目录仍可重新打开');
    }});
  }
  openModal(archive ? '归档空间前的影响' : `关闭「${s.name}」前的影响`, '请选择一个真实的关闭分支。', body, actions);
}
function restoreDescriptor(s,d){s.name=d.name;s.mode=d.mode||'content';s.archived=!!d.archived;s.resources=d.resources.map(r=>({...r,state:r.type==='web'?'网页 · 可见':'待启动',runtime:null,readFailure:false}));s.layout=d.layout.filter(id=>s.resources.some(r=>r.id===id));s.focusIndex=Math.min(d.focusIndex,Math.max(0,s.layout.length-1))}
function closeWindow(){
  const list = state.spaces.filter(s => s.loaded && !s.closed);
  const summary = list.map(s => {
    const running = s.resources.filter(r => r.runtime?.state === 'running').length;
    const requests = s.activeRequest ? 1 : 0;
    return `${s.name}：${running} 个运行中终端，${requests} 个活动请求`;
  }).join('；') || '没有正在载入的空间';
  const body = `${summary}。关闭后会清空所有空间的 AI 草稿、请求和运行实例。`;
  const needsChoice = list.some(s => s.saveError || s.temp);
  const finish = () => {
    list.forEach(unload);
    state.activeId = fallback('none').id;
    render();
  };
  const retryAndClose = () => {
    const temps = list.filter(s => s.temp);
    if (temps.length) {
      const fields = temps.map(s => `<label for="windowSpaceName-${esc(s.id)}">${esc(s.name)}（空间 ${esc(s.id)}）</label><input id="windowSpaceName-${esc(s.id)}" data-space-id="${esc(s.id)}" aria-label="${esc(s.name)} 空间名称">`).join('');
      openModal('先命名临时空间', '关闭窗口前必须先保存所有临时空间配置。请先填写全部名称。', fields, [
        {label: '取消', cancel: true},
        {label: '保存并关闭', primary: true, action: () => {
          const names = temps.map(s => ({space: s, name: document.getElementById(`windowSpaceName-${s.id}`)?.value.trim() || ''}));
          if (names.some(x => !x.name)) return announce('请为所有临时空间输入名称');
          names.forEach(x => { x.space.name = x.name; });
          const saved = list.map(s => { s.saveError = false; return save(s); });
          if (saved.some(ok => !ok)) return announce('仍有空间保存失败，未开始关闭');
          finish();
        }}
      ]);
      return;
    }
    const saved = list.map(s => { s.saveError = false; return save(s); });
    if (saved.some(ok => !ok)) return announce('仍有空间保存失败，未开始关闭');
    finish();
  };
  const discardAndClose = () => {
    list.forEach(s => {
      const wasTemp = s.temp;
      if (s.savedDescriptor) restoreDescriptor(s, s.savedDescriptor);
      s.dirty = false;
      s.saveError = false;
      if (wasTemp) state.spaces = state.spaces.filter(x => x !== s);
      else unload(s);
    });
    state.activeId = fallback('none').id;
    render();
  };
  const actions = [{label: '取消', cancel: true}];
  if (needsChoice) {
    actions.push({label: '重试并关闭', primary: true, action: retryAndClose});
    actions.push({label: '不保存并关闭', action: discardAndClose});
  } else {
    actions.push({label: '确认关闭窗口', primary: true, action: finish});
  }
  openModal('关闭窗口前的影响', body, '<p class="sim-copy">取消不会释放对象；确认或处理保存分支后才清理。</p>', actions);
}
function restart(){
  openModal('模拟重启','只恢复空间配置、资源描述与布局。Shell、SSH、网页运行时和 AI 均不会自动启动；问答正文与草稿不恢复。','<div class="restart-summary">恢复启动计数：Shell 0 · SSH 0 · AI 0<br>终端与 SSH：待启动<br>网页：按需载入</div>',[
    {label:'取消',cancel:true},
    {label:'确认模拟重启',primary:true,action:()=>{
      const restored=state.spaces.filter(s=>!s.temp&&s.savedDescriptor).map(s=>{const n=newSpace(s.savedDescriptor.name,false);n.id=s.savedDescriptor.id;n.archived=s.savedDescriptor.archived;n.savedDescriptor={...s.savedDescriptor};restoreDescriptor(n,s.savedDescriptor);n.loaded=false;n.closed=true;return n});
      const t=newSpace('临时空间',true);state.spaces=[...restored,t];state.activeId=t.id;render();announce('模拟重启完成：只恢复配置，启动计数为 0');
    }}
  ]);
}
function openModal(title,text,body,actions){state.modalReturn=document.activeElement;$('modalTitle').textContent=title;$('modalText').textContent=text;$('modalBody').innerHTML=body||'';$('modalActions').innerHTML=(actions||[{label:'确认',primary:true}]).map((a,i)=>`<button class="btn ${a.primary?'primary':''}" data-modal-index="${i}">${esc(a.label)}</button>`).join('');$('modalWrap').classList.add('open');const buttons=[...$('modalActions').querySelectorAll('button')];(actions||[]).forEach((a,i)=>buttons[i].onclick=()=>{if(a.cancel)closeModal();else{closeModal();a.action?.()}});$('modalBody').querySelectorAll('[data-switch]').forEach(b=>b.onclick=()=>{closeModal();const s=state.spaces.find(x=>x.id===b.dataset.switch);if(reopen(s))switchSpace(s.id)});(actions?$('modalBody').querySelector('input'):null)?.focus()||buttons[0]?.focus()}
function closeModal(){$('modalWrap').classList.remove('open');if(state.modalReturn?.isConnected)state.modalReturn.focus();state.modalReturn=null}
$('saveSpace').onclick=saveAs;
$('newSpace').onclick=()=>saveAs();
$('addWeb').onclick=()=>addResource('web');
$('addTerminal').onclick=()=>addResource('terminal');
$('addSSH').onclick=()=>addResource('ssh');
$('aiToggle').onclick=()=>setMode(active().mode==='ai'?'content':'ai',true);
$('workspaceMenu').onclick=()=>openModal('切换工作空间','关闭空间仍保留在目录；归档空间需要先恢复。',state.spaces.map(s=>`<button class="btn modal-wide" data-switch="${esc(s.id)}">${esc(s.name)} · ${s.archived?'归档':s.closed?'已关闭':'已载入'}</button>`).join(''),[{label:'取消',cancel:true}]);
$('closeBtn').onclick=()=>closeSpace(active(),false);
$('closeWindowBtn').onclick=closeWindow;
$('restartBtn').onclick=restart;
document.addEventListener('click',e=>{const m=e.target.closest('[data-mode]');if(m)setMode(m.dataset.mode,true)});
$('modalWrap').onclick=e=>{if(e.target===$('modalWrap'))closeModal()};
document.addEventListener('keydown',e=>{if(!$('modalWrap').classList.contains('open'))return;if(e.key==='Escape'){e.preventDefault();closeModal()}if(e.key==='Tab'){const f=[...$('modalWrap').querySelectorAll('button,input,textarea')].filter(x=>!x.disabled);if(!f.length)return;const i=f.indexOf(document.activeElement);f[(i+(e.shiftKey?-1:1)+f.length)%f.length].focus();e.preventDefault()}});
$("simulateSaveFailure").onclick=()=>{active().saveError=true;render();announce('已模拟保存失败；内存配置保留，可重试或选择关闭分支')};
$("archiveBtn").onclick=()=>{const s=active();if(s.temp){announce('临时空间需先保存命名后才能归档');return}closeSpace(s,true)};
$("layoutBtn").onclick=()=>{const s=active();if(s.layout.length>1){s.layout=[s.layout[Math.max(0,Math.min(s.focusIndex,s.layout.length-1))]];s.focusIndex=0;markDirty(s);render();announce('已收起右侧视图；资源描述和会话仍保留');return}const choices=s.resources.filter(r=>!s.layout.includes(r.id));if(!choices.length)return announce('至少添加另一个未显示资源后才能并排');openModal('选择并排资源','选择要放到另一侧的资源。点击已显示资源只会切换焦点。',choices.map(r=>`<button class="btn modal-wide" data-side-resource="${esc(r.id)}">${esc(r.name)} · ${esc(r.state)}</button>`).join(''),[{label:'取消',cancel:true}]);$("modalBody").querySelectorAll('[data-side-resource]').forEach(b=>b.onclick=()=>{closeModal();s.layout=[s.layout[0],b.dataset.sideResource];s.focusIndex=1;markDirty(s);render();announce('已打开左右并排')})};
render();
})();
