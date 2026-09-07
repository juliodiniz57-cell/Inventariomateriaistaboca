-- ATUALIZAÇÃO ÚNICA DO BACKEND
-- Habilita cadastro dinâmico de equipamentos e materiais pela própria página.
-- A senha administrativa continua sendo a já configurada no projeto.

create extension if not exists pgcrypto;

create table if not exists public.equipment_catalog (
  id uuid primary key default gen_random_uuid(),
  model text not null unique,
  tags text[] not null default '{}'::text[],
  image_data text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.equipment_materials (
  equipment_id uuid not null references public.equipment_catalog(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (equipment_id, material_id)
);

create index if not exists idx_equipment_materials_material
  on public.equipment_materials(material_id);

create or replace function public.touch_equipment_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_equipment_updated_at on public.equipment_catalog;
create trigger trg_equipment_updated_at
before update on public.equipment_catalog
for each row execute procedure public.touch_equipment_updated_at();

alter table public.equipment_catalog enable row level security;
alter table public.equipment_materials enable row level security;

drop policy if exists "equipment_catalog_read" on public.equipment_catalog;
create policy "equipment_catalog_read"
on public.equipment_catalog
for select
to anon, authenticated
using (true);

drop policy if exists "equipment_materials_read" on public.equipment_materials;
create policy "equipment_materials_read"
on public.equipment_materials
for select
to anon, authenticated
using (true);

grant select on public.equipment_catalog to anon, authenticated;
grant select on public.equipment_materials to anon, authenticated;

-- Validação da senha administrativa já armazenada em app_admin.
create or replace function public.admin_check_password(p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
begin
  select password_hash into v_hash
  from public.app_admin
  where id = 1;

  return v_hash is not null
     and extensions.crypt(p_password, v_hash) = v_hash;
end;
$$;

create or replace function public.admin_save_equipment(
  p_equipment_id uuid,
  p_model text,
  p_tags text[],
  p_image_data text,
  p_material_ids uuid[],
  p_password text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_existing_active boolean;
begin
  if not public.admin_check_password(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if nullif(btrim(p_model),'') is null then
    raise exception 'Informe o modelo do equipamento';
  end if;

  if p_equipment_id is null then
    select id, active
      into v_id, v_existing_active
      from public.equipment_catalog
     where lower(model)=lower(btrim(p_model))
     limit 1;

    if v_id is null then
      insert into public.equipment_catalog(model,tags,image_data,active)
      values (
        btrim(p_model),
        coalesce(p_tags,'{}'::text[]),
        nullif(p_image_data,''),
        true
      )
      returning id into v_id;
    elsif v_existing_active then
      raise exception 'O equipamento % já está cadastrado', btrim(p_model);
    else
      update public.equipment_catalog
         set model=btrim(p_model),
             tags=coalesce(p_tags,'{}'::text[]),
             image_data=coalesce(nullif(p_image_data,''),image_data),
             active=true
       where id=v_id;
    end if;
  else
    update public.equipment_catalog
       set model=btrim(p_model),
           tags=coalesce(p_tags,'{}'::text[]),
           image_data=coalesce(nullif(p_image_data,''),image_data),
           active=true
     where id=p_equipment_id
     returning id into v_id;

    if v_id is null then
      raise exception 'Equipamento não encontrado';
    end if;
  end if;

  delete from public.equipment_materials
   where equipment_id=v_id;

  insert into public.equipment_materials(equipment_id,material_id)
  select v_id, u.id
  from unnest(coalesce(p_material_ids,'{}'::uuid[])) as u(id)
  join public.materials m on m.id=u.id and m.active=true
  on conflict do nothing;

  return v_id;
end;
$$;

create or replace function public.admin_set_equipment_active(
  p_equipment_id uuid,
  p_active boolean,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.admin_check_password(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  update public.equipment_catalog
     set active=p_active
   where id=p_equipment_id;

  return found;
end;
$$;

create or replace function public.admin_save_material(
  p_material_id uuid,
  p_material_code text,
  p_description text,
  p_type text,
  p_consumption_2025 integer,
  p_min_stock numeric,
  p_target_stock numeric,
  p_purchase_multiple numeric,
  p_equipment_ids uuid[],
  p_password text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
  v_existing_active boolean;
begin
  if not public.admin_check_password(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if nullif(btrim(p_material_code),'') is null then
    raise exception 'Informe o código do material';
  end if;

  if nullif(btrim(p_description),'') is null then
    raise exception 'Informe a descrição do material';
  end if;

  if coalesce(p_target_stock,0) < coalesce(p_min_stock,0) then
    raise exception 'O estoque-alvo deve ser maior ou igual ao estoque mínimo';
  end if;

  if p_material_id is null then
    select id, active
      into v_id, v_existing_active
      from public.materials
     where material_code=btrim(p_material_code)
     limit 1;

    if v_id is null then
      insert into public.materials(
        material_code,description,type,consumption_2025,
        min_stock,target_stock,purchase_multiple,active
      )
      values(
        btrim(p_material_code),
        btrim(p_description),
        coalesce(nullif(btrim(p_type),''),'PD'),
        greatest(coalesce(p_consumption_2025,0),0),
        greatest(coalesce(p_min_stock,0),0),
        greatest(coalesce(p_target_stock,0),0),
        greatest(coalesce(p_purchase_multiple,1),1),
        true
      )
      returning id into v_id;
    elsif v_existing_active then
      raise exception 'O material % já está cadastrado', btrim(p_material_code);
    else
      update public.materials
         set description=btrim(p_description),
             type=coalesce(nullif(btrim(p_type),''),'PD'),
             consumption_2025=greatest(coalesce(p_consumption_2025,0),0),
             min_stock=greatest(coalesce(p_min_stock,0),0),
             target_stock=greatest(coalesce(p_target_stock,0),0),
             purchase_multiple=greatest(coalesce(p_purchase_multiple,1),1),
             active=true
       where id=v_id;
    end if;
  else
    update public.materials
       set material_code=btrim(p_material_code),
           description=btrim(p_description),
           type=coalesce(nullif(btrim(p_type),''),'PD'),
           consumption_2025=greatest(coalesce(p_consumption_2025,0),0),
           min_stock=greatest(coalesce(p_min_stock,0),0),
           target_stock=greatest(coalesce(p_target_stock,0),0),
           purchase_multiple=greatest(coalesce(p_purchase_multiple,1),1),
           active=true
     where id=p_material_id
     returning id into v_id;

    if v_id is null then
      raise exception 'Material não encontrado';
    end if;
  end if;

  delete from public.equipment_materials
   where material_id=v_id;

  insert into public.equipment_materials(equipment_id,material_id)
  select u.id, v_id
  from unnest(coalesce(p_equipment_ids,'{}'::uuid[])) as u(id)
  join public.equipment_catalog e on e.id=u.id and e.active=true
  on conflict do nothing;

  return v_id;
end;
$$;

create or replace function public.admin_set_material_active(
  p_material_id uuid,
  p_active boolean,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.admin_check_password(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  update public.materials
     set active=p_active
   where id=p_material_id;

  return found;
end;
$$;

create or replace function public.admin_set_material_equipment_link(
  p_material_id uuid,
  p_equipment_id uuid,
  p_linked boolean,
  p_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.admin_check_password(p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if p_linked then
    insert into public.equipment_materials(equipment_id,material_id)
    values(p_equipment_id,p_material_id)
    on conflict do nothing;
  else
    delete from public.equipment_materials
     where equipment_id=p_equipment_id
       and material_id=p_material_id;
  end if;

  return true;
end;
$$;

revoke all on function public.admin_check_password(text) from public;
revoke all on function public.admin_save_equipment(uuid,text,text[],text,uuid[],text) from public;
revoke all on function public.admin_set_equipment_active(uuid,boolean,text) from public;
revoke all on function public.admin_save_material(uuid,text,text,text,integer,numeric,numeric,numeric,uuid[],text) from public;
revoke all on function public.admin_set_material_active(uuid,boolean,text) from public;
revoke all on function public.admin_set_material_equipment_link(uuid,uuid,boolean,text) from public;

grant execute on function public.admin_check_password(text) to anon, authenticated;
grant execute on function public.admin_save_equipment(uuid,text,text[],text,uuid[],text) to anon, authenticated;
grant execute on function public.admin_set_equipment_active(uuid,boolean,text) to anon, authenticated;
grant execute on function public.admin_save_material(uuid,text,text,text,integer,numeric,numeric,numeric,uuid[],text) to anon, authenticated;
grant execute on function public.admin_set_material_active(uuid,boolean,text) to anon, authenticated;
grant execute on function public.admin_set_material_equipment_link(uuid,uuid,boolean,text) to anon, authenticated;

-- Carga inicial dos equipamentos atuais.
insert into public.equipment_catalog(model,tags,active)
values
  ('D8T', ARRAY['7016TE','7017TE','7019TE','7020TE','7021TE']::text[], true),
  ('844L', ARRAY['7029PC','7030PC','7031PC']::text[], true),
  ('336', ARRAY['7017ES','7015ES','7020ES']::text[], true),
  ('374', ARRAY['7019ES','7014ES']::text[], true),
  ('50VX', ARRAY['7037EM']::text[], true),
  ('924K', ARRAY['7027PC']::text[], true),
  ('724K', ARRAY['7028PC']::text[], true),
  ('374DL', ARRAY['7012ES','7013ES']::text[], true),
  ('ATEGO 1719', ARRAY['7145CB']::text[], true),
  ('ACTROS 4844', ARRAY['7081CB','7082CB','7083CB','7084CB']::text[], true),
  ('416E', ARRAY['7006RE']::text[], true),
  ('670G', ARRAY['7009MN']::text[], true),
  ('350G LC', ARRAY['7018ES']::text[], true),
  ('OUTROS', ARRAY['COMPRESSOR']::text[], true)
on conflict(model) do update set
  tags=excluded.tags,
  active=true;

-- Relação inicial equipamento x material.
insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('133478', '135324', '134105')
where e.model = 'D8T'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('144592', '144594', '144595', '142734', '144578', '144591')
where e.model = '844L'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('127514', '140450', '134878', '141124')
where e.model = '336'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('134876', '139365')
where e.model = '374'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('97942')
where e.model = '50VX'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('127515', '136364', '136365', '103089', '103088', '102167', '124599', '124600', '109156')
where e.model = '924K'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('126569')
where e.model = '724K'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('134116', '134115', '134118', '134117')
where e.model = '374DL'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('119118', '119119', '134750', '156397')
where e.model = 'ATEGO 1719'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('127213', '144154')
where e.model = 'ACTROS 4844'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('117429', '122125', '126958')
where e.model = '416E'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('142738', '142735', '142644')
where e.model = '670G'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('142640', '142636', '142637', '142638', '142639', '142643')
where e.model = '350G LC'
on conflict do nothing;

insert into public.equipment_materials (equipment_id, material_id)
select e.id, m.id
from public.equipment_catalog e
join public.materials m on m.material_code in ('149528')
where e.model = 'OUTROS'
on conflict do nothing;
