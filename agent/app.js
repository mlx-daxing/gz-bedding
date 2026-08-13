const db=window.supabase.createClient(window.SUPABASE_CONFIG.url,window.SUPABASE_CONFIG.publishableKey);
const $=s=>document.querySelector(s);
async function boot(){
  const {data,error}=await db.rpc('active_shareholders');
  if(error)return note(error.message);
  $('#shareholder').innerHTML='<option value="">请选择推荐股东</option>'+data.map(x=>`<option value="${x.id}">${x.name}</option>`).join('');
}
async function apply(){
  if(!$('#shareholder').value)return note('请选择推荐股东。');
  const payload={
    email:$('#email').value.trim(),
    password:$('#password').value,
    options:{data:{
      name:$('#name').value.trim(), phone:$('#phone').value.trim(), wechat:$('#wechat').value.trim(),
      shareholder_id:$('#shareholder').value, application_type:'secondary_agent'
    }}
  };
  const {error}=await db.auth.signUp(payload);
  if(error)return note(error.message);
  note('申请已提交。请按邮箱提示完成验证；管理员审核通过后，才能获得专属推广链接。');
}
function note(t){$('#message').textContent=t}
boot();
