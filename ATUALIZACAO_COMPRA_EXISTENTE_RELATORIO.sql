-- ATUALIZAÇÃO V4 — COMPRA EXISTENTE + RELATÓRIO COMPLETO
-- Execute TODO este arquivo uma única vez no SQL Editor do Supabase.

alter table public.inventory_items
  add column if not exists has_existing_purchase boolean not null default false;

alter table public.inventory_items
  add column if not exists purchase_order_number text;

alter table public.inventory_items
  add column if not exists purchase_order_qty numeric(12,2);

comment on column public.inventory_items.has_existing_purchase
  is 'Indica que já existe pedido de compra para o material no momento do inventário.';

comment on column public.inventory_items.purchase_order_number
  is 'Número do pedido de compra já existente.';

comment on column public.inventory_items.purchase_order_qty
  is 'Quantidade solicitada no pedido de compra já existente.';

-- Mantém as colunas originais da view na mesma ordem e acrescenta
-- os dados do pedido ao final para preservar compatibilidade.
create or replace view public.v_inventory_report as
select
  i.id as inventory_id,
  i.inventory_date,
  i.responsible,
  i.area,
  i.status,
  m.material_code,
  m.description,
  m.type,
  m.consumption_2025,
  m.min_stock,
  m.target_stock,
  m.purchase_multiple,
  ii.counted_qty,
  ii.observation,
  case
    when ii.counted_qty is null then 'PENDENTE'
    when coalesce(ii.has_existing_purchase,false) then 'EM COMPRA'
    when ii.counted_qty < m.min_stock then 'COMPRAR'
    else 'OK'
  end as purchase_status,
  case
    when ii.counted_qty is null then 0
    when coalesce(ii.has_existing_purchase,false) then 0
    when ii.counted_qty < m.min_stock then
      ceil(greatest(m.target_stock - ii.counted_qty, 0) / greatest(m.purchase_multiple, 1))
      * greatest(m.purchase_multiple, 1)
    else 0
  end as suggested_purchase_qty,
  coalesce(ii.has_existing_purchase,false) as has_existing_purchase,
  ii.purchase_order_number,
  ii.purchase_order_qty
from public.inventories i
join public.inventory_items ii on ii.inventory_id = i.id
join public.materials m on m.id = ii.material_id;

grant select on public.v_inventory_report to anon, authenticated;
