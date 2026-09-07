
const cfg = window.APP_CONFIG || {};
const configured = cfg.SUPABASE_URL && !cfg.SUPABASE_URL.includes("COLE_AQUI") &&
                   cfg.SUPABASE_ANON_KEY && !cfg.SUPABASE_ANON_KEY.includes("COLE_AQUI");
const sb = configured ? supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

let materials = [];
let inventories = [];
let currentInventory = null;
let currentItems = new Map();

const $ = id => document.getElementById(id);
const n = v => Number(v ?? 0);
const fmt = v => new Intl.NumberFormat("pt-BR", {maximumFractionDigits:2}).format(n(v));

function toast(msg){
  $("toast").textContent = msg;
  $("toast").classList.add("show");
  setTimeout(()=>$("toast").classList.remove("show"),2600);
}

function calc(m, counted){
  if (counted === null || counted === undefined || counted === "") return {status:"PENDENTE", qty:0};
  const q=n(counted), min=n(m.min_stock), target=n(m.target_stock), mult=Math.max(n(m.purchase_multiple),1);
  if(q < min){
    return {status:"COMPRAR", qty: Math.ceil(Math.max(target-q,0)/mult)*mult};
  }
  return {status:"OK", qty:0};
}

async function boot(){
  if(!sb){
    $("connectionBadge").textContent="Configuração pendente";
    toast("Preencha config.js com URL e chave do Supabase.");
    return;
  }
  $("connectionBadge").textContent="Supabase conectado";
  await Promise.all([loadMaterials(), loadInventories()]);
  renderParams();
  renderHistory();
  refreshPurchaseSelect();
}

async function loadMaterials(){
  const {data,error}=await sb.from("materials").select("*").eq("active",true).order("material_code");
  if(error){toast(error.message);return}
  materials=data||[];
}

async function loadInventories(){
  const {data,error}=await sb.from("inventories").select("*").order("created_at",{ascending:false});
  if(error){toast(error.message);return}
  inventories=data||[];
}

function tabs(){
  document.querySelectorAll(".tabs button").forEach(b=>b.onclick=async()=>{
    document.querySelectorAll(".tabs button").forEach(x=>x.classList.remove("active"));
    document.querySelectorAll(".tab").forEach(x=>x.classList.remove("active"));
    b.classList.add("active"); $("tab-"+b.dataset.tab).classList.add("active");
    if(b.dataset.tab==="historico"){await loadInventories();renderHistory()}
    if(b.dataset.tab==="compras"){await loadInventories();refreshPurchaseSelect()}
  });
}

async function startInventory(){
  const responsible=$("responsible").value.trim();
  if(!responsible){toast("Informe o responsável.");return}
  const payload={responsible,area:$("area").value.trim(),notes:$("notes").value.trim()};
  const {data,error}=await sb.from("inventories").insert(payload).select().single();
  if(error){toast(error.message);return}
  currentInventory=data;
  const rows=materials.map(m=>({inventory_id:data.id,material_id:m.id}));
  const {error:itemErr}=await sb.from("inventory_items").insert(rows);
  if(itemErr){toast(itemErr.message);return}
  await loadCurrentItems();
  $("inventoryWorkspace").classList.remove("hidden");
  $("finishInventory").disabled=false;
  $("inventoryMeta").textContent=`#${data.id.slice(0,8)} • ${data.responsible} • ${new Date().toLocaleDateString("pt-BR")}`;
  renderInventory();
  toast("Inventário iniciado.");
}

async function loadCurrentItems(){
  const {data,error}=await sb.from("inventory_items").select("*").eq("inventory_id",currentInventory.id);
  if(error){toast(error.message);return}
  currentItems=new Map((data||[]).map(x=>[x.material_id,x]));
}

async function saveCount(materialId,value,obs){
  const qty=value===""?null:n(value);
  const row=currentItems.get(materialId);
  const payload={counted_qty:qty,observation:obs||null,checked_at:qty===null?null:new Date().toISOString()};
  const {data,error}=await sb.from("inventory_items").update(payload).eq("id",row.id).select().single();
  if(error){toast(error.message);return}
  currentItems.set(materialId,data);
  renderInventory($("searchMaterial").value);
}

function renderInventory(filter=""){
  const term=filter.trim().toLowerCase();
  const list=materials.filter(m=>(m.material_code+" "+m.description).toLowerCase().includes(term));
  $("materialList").innerHTML=list.map(m=>{
    const item=currentItems.get(m.id)||{};
    const c=item.counted_qty;
    const r=calc(m,c);
    const cls=r.status==="OK"?"ok":r.status==="COMPRAR"?"buy":"pending";
    return `<div class="card">
      <div class="card-head"><div><div class="code">${m.material_code}</div><div class="desc">${m.description}</div></div><span class="tag">${m.type}</span></div>
      <div class="row">
        <label>Qtd. 2025<input value="${m.consumption_2025}" disabled></label>
        <label>Mínimo<input value="${fmt(m.min_stock)}" disabled></label>
        <label>Alvo<input value="${fmt(m.target_stock)}" disabled></label>
        <label>Qtd. contada<input class="count" inputmode="decimal" data-id="${m.id}" value="${c??""}" placeholder="0"></label>
      </div>
      <label style="margin-top:8px">Observação<input class="obs" data-id="${m.id}" value="${item.observation??""}" placeholder="Opcional"></label>
      <div class="status ${cls}">${r.status}${r.status==="COMPRAR" ? ` • sugestão: ${fmt(r.qty)}`:""}</div>
    </div>`;
  }).join("");

  document.querySelectorAll(".count").forEach(inp=>inp.onchange=()=>{
    const obs=document.querySelector(`.obs[data-id="${inp.dataset.id}"]`)?.value||"";
    saveCount(inp.dataset.id,inp.value,obs);
  });
  document.querySelectorAll(".obs").forEach(inp=>inp.onchange=()=>{
    const count=document.querySelector(`.count[data-id="${inp.dataset.id}"]`)?.value||"";
    saveCount(inp.dataset.id,count,inp.value);
  });

  const all=materials.map(m=>({m,item:currentItems.get(m.id)||{}}));
  const checked=all.filter(x=>x.item.counted_qty!==null && x.item.counted_qty!==undefined).length;
  const buy=all.filter(x=>calc(x.m,x.item.counted_qty).status==="COMPRAR").length;
  $("kpiTotal").textContent=materials.length;
  $("kpiChecked").textContent=checked;
  $("kpiPending").textContent=materials.length-checked;
  $("kpiBuy").textContent=buy;
}

async function finishInventory(){
  const pending=materials.filter(m=>{
    const i=currentItems.get(m.id)||{};
    return i.counted_qty===null || i.counted_qty===undefined;
  }).length;
  if(pending){toast(`Ainda existem ${pending} itens sem conferência.`);return}
  const responsible=$("responsible").value.trim();
  if(!responsible){toast("Informe o responsável.");return}
  const payload={
    responsible,
    area:$("area").value.trim(),
    notes:$("notes").value.trim(),
    status:"finished",
    finished_at:new Date().toISOString()
  };
  const {error}=await sb.from("inventories").update(payload).eq("id",currentInventory.id);
  if(error){toast(error.message);return}
  toast("Inventário finalizado. Relatório de compra atualizado.");
  await loadInventories();
  refreshPurchaseSelect(currentInventory.id);
  document.querySelector('[data-tab="compras"]').click();
}

function renderParams(filter=""){
  const term=filter.trim().toLowerCase();
  const list=materials.filter(m=>(m.material_code+" "+m.description).toLowerCase().includes(term));
  $("paramsList").innerHTML=list.map(m=>`<div class="card">
    <div class="card-head"><div><div class="code">${m.material_code}</div><div class="desc">${m.description}</div></div><span class="tag">Consumo 2025: ${m.consumption_2025}</span></div>
    <div class="row three">
      <label>Estoque mínimo<input data-p="min_stock" data-id="${m.id}" type="number" min="0" step="1" value="${n(m.min_stock)}"></label>
      <label>Estoque-alvo<input data-p="target_stock" data-id="${m.id}" type="number" min="0" step="1" value="${n(m.target_stock)}"></label>
      <label>Múltiplo de compra<input data-p="purchase_multiple" data-id="${m.id}" type="number" min="1" step="1" value="${Math.max(n(m.purchase_multiple),1)}"></label>
    </div>
    <button class="save-param primary" data-id="${m.id}" style="margin-top:10px">Salvar parâmetros</button>
  </div>`).join("");
  document.querySelectorAll(".save-param").forEach(btn=>btn.onclick=()=>saveParams(btn.dataset.id));
}

async function saveParams(id){
  const vals={};
  document.querySelectorAll(`[data-id="${id}"][data-p]`).forEach(x=>vals[x.dataset.p]=n(x.value));
  if(vals.target_stock < vals.min_stock){toast("O estoque-alvo deve ser maior ou igual ao mínimo.");return}
  const {data,error}=await sb.from("materials").update(vals).eq("id",id).select().single();
  if(error){toast(error.message);return}
  const ix=materials.findIndex(m=>m.id===id); if(ix>=0)materials[ix]=data;
  renderParams($("searchParams").value);
  if(currentInventory) renderInventory($("searchMaterial").value);
  toast("Parâmetros salvos.");
}

function renderHistory(){
  $("historyList").innerHTML=inventories.length?inventories.map(i=>`
    <div class="history-item">
      <div><strong>${new Date(i.inventory_date+"T12:00:00").toLocaleDateString("pt-BR")}</strong> • ${i.responsible}
      <div class="muted">${i.area||"Sem área"} • ${i.status==="finished"?"Finalizado":"Em aberto"}</div></div>
      <div class="history-actions">
        <button onclick="openReport('${i.id}')">Ver relatório</button>
        <button onclick="requestAdminAction('edit','${i.id}')">Editar</button>
        <button class="danger" onclick="requestAdminAction('delete','${i.id}')">Excluir</button>
      </div>
    </div>`).join(""):`<p class="muted">Nenhum inventário registrado.</p>`;
}

function refreshPurchaseSelect(preselect){
  const sel=$("purchaseInventorySelect");
  const finished=inventories.filter(i=>i.status==="finished");
  sel.innerHTML=finished.map(i=>`<option value="${i.id}">${new Date(i.inventory_date+"T12:00:00").toLocaleDateString("pt-BR")} • ${i.responsible}</option>`).join("");
  if(preselect) sel.value=preselect;
  if(sel.value) loadPurchaseReport(sel.value); else {$("purchaseTable").innerHTML="";$("purchaseSummary").textContent="Nenhum inventário finalizado."}
}

async function loadPurchaseReport(id){
  const {data,error}=await sb.from("v_inventory_report").select("*").eq("inventory_id",id).eq("purchase_status","COMPRAR").order("material_code");
  if(error){toast(error.message);return}
  const rows=data||[];
  const totalQty=rows.reduce((s,r)=>s+n(r.suggested_purchase_qty),0);
  $("purchaseSummary").textContent=`${rows.length} itens precisam de compra • ${fmt(totalQty)} unidades sugeridas`;
  $("purchaseTable").innerHTML=rows.length?rows.map(r=>`<tr>
    <td><strong>${r.material_code}</strong></td><td>${r.description}</td><td>${fmt(r.counted_qty)}</td>
    <td>${fmt(r.min_stock)}</td><td>${fmt(r.target_stock)}</td><td><strong>${fmt(r.suggested_purchase_qty)}</strong></td>
  </tr>`).join(""):`<tr><td colspan="6">Nenhum item abaixo do estoque mínimo.</td></tr>`;
}


let pendingAdminAction = null;

window.requestAdminAction = (action, inventoryId) => {
  pendingAdminAction = {action, inventoryId};
  $("adminPassword").value = "";
  $("adminModalTitle").textContent = action==="delete" ? "Excluir inventário" : "Editar inventário";
  $("adminModalText").textContent = action==="delete"
    ? "Esta ação excluirá definitivamente o relatório e seus itens. Digite a senha administrativa."
    : "Digite a senha administrativa para reabrir e editar este inventário.";
  $("adminConfirm").className = action==="delete" ? "danger" : "primary";
  $("adminModal").classList.remove("hidden");
  setTimeout(()=>$("adminPassword").focus(),50);
};

function closeAdminModal(){
  pendingAdminAction=null;
  $("adminPassword").value="";
  $("adminModal").classList.add("hidden");
}

$("adminCancel").onclick=closeAdminModal;
$("adminModal").onclick=e=>{ if(e.target.id==="adminModal") closeAdminModal(); };

$("adminConfirm").onclick=async()=>{
  if(!pendingAdminAction) return;
  const pwd=$("adminPassword").value;
  if(!pwd){toast("Digite a senha administrativa.");return}
  const {action,inventoryId}=pendingAdminAction;
  $("adminConfirm").disabled=true;
  try{
    if(action==="delete"){
      const {data,error}=await sb.rpc("admin_delete_inventory",{p_inventory_id:inventoryId,p_password:pwd});
      if(error) throw error;
      if(!data){toast("Senha incorreta.");return}
      closeAdminModal();
      await loadInventories();
      renderHistory();
      refreshPurchaseSelect();
      toast("Inventário excluído.");
    }else{
      const {data,error}=await sb.rpc("admin_reopen_inventory",{p_inventory_id:inventoryId,p_password:pwd});
      if(error) throw error;
      if(!data){toast("Senha incorreta.");return}
      closeAdminModal();
      const inv=inventories.find(x=>x.id===inventoryId) || (await sb.from("inventories").select("*").eq("id",inventoryId).single()).data;
      currentInventory={...inv,status:"open",finished_at:null};
      $("responsible").value=currentInventory.responsible||"";
      $("area").value=currentInventory.area||"";
      $("notes").value=currentInventory.notes||"";
      await loadCurrentItems();
      $("inventoryWorkspace").classList.remove("hidden");
      $("finishInventory").disabled=false;
      $("inventoryMeta").textContent=`EDITANDO • ${currentInventory.responsible} • ${new Date(currentInventory.inventory_date+"T12:00:00").toLocaleDateString("pt-BR")}`;
      renderInventory();
      document.querySelector('[data-tab="inventario"]').click();
      toast("Inventário reaberto para edição.");
    }
  }catch(err){
    toast(err.message || "Não foi possível concluir a ação.");
  }finally{
    $("adminConfirm").disabled=false;
  }
};

$("adminPassword").addEventListener("keydown",e=>{
  if(e.key==="Enter") $("adminConfirm").click();
});

window.openReport = id => {
  document.querySelector('[data-tab="compras"]').click();
  $("purchaseInventorySelect").value=id;
  loadPurchaseReport(id);
};

$("startInventory").onclick=startInventory;
$("finishInventory").onclick=finishInventory;
$("searchMaterial").oninput=e=>renderInventory(e.target.value);
$("searchParams").oninput=e=>renderParams(e.target.value);
$("purchaseInventorySelect").onchange=e=>loadPurchaseReport(e.target.value);
$("printReport").onclick=()=>window.print();
tabs();
boot();
