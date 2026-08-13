const shareholders=[
  {name:'啊瀚',packages:0,sales:0,profit:0,code:'ahan'},
  {name:'yy',packages:0,sales:0,profit:0,code:'yy'},
  {name:'赖狗狗',packages:0,sales:0,profit:0,code:'laigougou'}
];
const agents=[{name:'暂无申请',shareholder:'—',phone:'—',wechat:'—',status:'pending'}];
const orders=[];
const yuan=n=>`¥${Number(n||0).toLocaleString('zh-CN')}`;
const copyLink=code=>{navigator.clipboard?.writeText(`${location.origin}/gz-bedding/?ref=${code}`);toast('已复制股东专属学生商城链接')};
function toast(text){const el=document.querySelector('#toast');el.textContent=text;el.style.display='block';clearTimeout(window.timer);window.timer=setTimeout(()=>el.style.display='none',2000)}
function summary(){const total=shareholders.reduce((n,x)=>n+x.packages,0);document.querySelector('#summary').innerHTML=`<div><small>股东总数</small><strong>3</strong><em>啊瀚 · yy · 赖狗狗</em></div><div><small>套餐总销量</small><strong>${total} 套</strong><em>仅尾款已确认的套餐计入</em></div><div><small>待处理</small><strong>${agents.filter(x=>x.status==='pending').length+orders.filter(x=>x.status!=='paid'&&x.status!=='refunded').length}</strong><em>代理申请与定金订单</em></div>`}
function shareholdersTab(){document.querySelector('#panel').innerHTML=`<div class="panel"><div class="panel-head"><div><h2>股东总览</h2><small>股东本人及其二级代理的“已确认尾款”套餐会合并统计。</small></div></div><div class="shareholder-grid">${shareholders.map(s=>`<article class="share-card"><h3>${s.name}</h3><small>套餐销量</small><b>${s.packages} 套</b><small>学生销售额 ${yuan(s.sales)} · 股东收益 ${yuan(s.profit)}</small><code>${location.origin}/gz-bedding/?ref=${s.code}</code><button class="secondary" style="margin-top:9px" onclick="copyLink('${s.code}')">复制专属链接</button></article>`).join('')}</div></div>`}
function agentsTab(){document.querySelector('#panel').innerHTML=`<div class="panel"><div class="panel-head"><div><h2>代理审核</h2><small>二级代理自助注册后，需你审核通过才有推广链接。</small></div></div>${agents.map(a=>`<div class="row"><div class="grow"><strong>${a.name}</strong> <span class="badge">${a.status==='pending'?'待审核':'已通过'}</span><small>二级代理 · 推荐股东：${a.shareholder} · ${a.phone} · ${a.wechat}</small></div>${a.status==='pending'?'<button onclick="toast(\'演示：已通过，正式后台会保存并生成链接\')">通过</button><button class="danger" onclick="toast(\'演示：已拒绝\')">拒绝</button>':''}</div>`).join('')}</div>`}
function ordersTab(){document.querySelector('#panel').innerHTML=`<div class="panel"><div class="panel-head"><div><h2>订单与退款</h2><small>确认尾款后才计入套餐销量与收益；退款后自动扣回。</small></div></div>${orders.length?orders.map(o=>`<div class="row"><div class="grow"><strong>${o.no} · ${o.customer}</strong><small>${o.product} · 定金 ${yuan(o.deposit)} · 尾款 ${yuan(o.balance)}</small></div><button onclick="toast('演示：尾款确认成功')">确认尾款</button></div>`).join(''):'<p>暂无真实订单。学生从商城提交定金凭证后，会出现在正式后台。</p>'}</div>`}
function settingsTab(){document.querySelector('#panel').innerHTML=`<div class="panel"><h2>结算周期</h2><div class="row"><div class="grow"><strong>2026 招新结算周期</strong><small>当前开启 · 套餐销量决定二级代理 1–9、10–19、20–29、30+ 阶梯；单品不增加阶梯销量。</small></div><button class="secondary" onclick="toast('演示：正式后台会按最终套餐数量重新计算')">重新计算</button></div></div>`}
function tab(name){document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('active',x.dataset.tab===name));({shareholders:shareholdersTab,agents:agentsTab,orders:ordersTab,settings:settingsTab})[name]()}
document.querySelectorAll('nav button').forEach(button=>button.addEventListener('click',()=>tab(button.dataset.tab)));
summary();tab('shareholders');
