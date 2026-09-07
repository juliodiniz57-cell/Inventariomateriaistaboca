-- PATCH: senha administrativa para Editar/Excluir no Histórico
-- Senha inicial gerada: Ukalhdi!S1rsr8
-- Execute TODO este arquivo no SQL Editor do Supabase.

create extension if not exists pgcrypto;

create table if not exists public.app_admin (
  id integer primary key check (id = 1),
  password_hash text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_admin enable row level security;

revoke all on public.app_admin from anon, authenticated;

insert into public.app_admin (id, password_hash)
values (1, crypt('Ukalhdi!S1rsr8', gen_salt('bf')))
on conflict (id) do update set
  password_hash = excluded.password_hash,
  updated_at = now();

-- Inventários finalizados não podem ser reabertos diretamente pelo navegador.
drop policy if exists "inventories_update" on public.inventories;
create policy "inventories_update"
on public.inventories
for update
to anon, authenticated
using (status = 'open')
with check (status in ('open','finished'));

-- Itens só podem ser alterados enquanto o inventário estiver aberto.
drop policy if exists "inventory_items_update" on public.inventory_items;
create policy "inventory_items_update"
on public.inventory_items
for update
to anon, authenticated
using (
  exists (
    select 1 from public.inventories i
    where i.id = inventory_items.inventory_id
      and i.status = 'open'
  )
)
with check (
  exists (
    select 1 from public.inventories i
    where i.id = inventory_items.inventory_id
      and i.status = 'open'
  )
);

create or replace function public.admin_reopen_inventory(
  p_inventory_id uuid,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash from public.app_admin where id = 1;
  if v_hash is null or crypt(p_password, v_hash) <> v_hash then
    return false;
  end if;

  update public.inventories
     set status = 'open',
         finished_at = null
   where id = p_inventory_id;

  return found;
end;
$$;

create or replace function public.admin_delete_inventory(
  p_inventory_id uuid,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash from public.app_admin where id = 1;
  if v_hash is null or crypt(p_password, v_hash) <> v_hash then
    return false;
  end if;

  delete from public.inventories where id = p_inventory_id;
  return found;
end;
$$;

revoke all on function public.admin_reopen_inventory(uuid,text) from public;
revoke all on function public.admin_delete_inventory(uuid,text) from public;

grant execute on function public.admin_reopen_inventory(uuid,text) to anon, authenticated;
grant execute on function public.admin_delete_inventory(uuid,text) to anon, authenticated;
