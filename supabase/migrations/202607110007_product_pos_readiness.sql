-- Satrapy · Module 1 · Task 3
-- Product master ready for a future POS. No sales, customers or transactions.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists btree_gist with schema extensions;

create table if not exists public.units_of_measure (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  source text not null default 'alpha',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id, code)
);

create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  external_code text not null,
  name text not null,
  source text not null default 'alpha',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id, external_code)
);

create table if not exists public.tax_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(company_id, code)
);

create table if not exists public.tax_rates (
  id uuid primary key default gen_random_uuid(),
  tax_category_id uuid not null references public.tax_categories(id) on delete cascade,
  jurisdiction_code text not null default 'MX',
  rate numeric(9,6) not null check (rate >= 0 and rate <= 1),
  valid_from timestamptz not null,
  valid_to timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  exclude using gist (tax_category_id with =, jurisdiction_code with =,
    tstzrange(valid_from, coalesce(valid_to, 'infinity'::timestamptz), '[)') with &&)
);

alter table public.products
  add column if not exists internal_sku text,
  add column if not exists barcode text,
  add column if not exists is_sellable boolean not null default false,
  add column if not exists is_inventory_tracked boolean not null default false,
  add column if not exists base_unit_id uuid references public.units_of_measure(id) on delete restrict,
  add column if not exists sales_unit_id uuid references public.units_of_measure(id) on delete restrict,
  add column if not exists purchase_unit_id uuid references public.units_of_measure(id) on delete restrict,
  add column if not exists category_id uuid references public.product_categories(id) on delete set null,
  add column if not exists tax_category_id uuid references public.tax_categories(id) on delete set null,
  add column if not exists commercial_review_required boolean not null default false;

create unique index if not exists products_company_internal_sku_key
  on public.products(company_id, lower(internal_sku)) where internal_sku is not null;
create unique index if not exists products_company_barcode_key
  on public.products(company_id, barcode) where barcode is not null;
create index if not exists products_name_trgm_idx on public.products using gin (lower(name) extensions.gin_trgm_ops);

create table if not exists public.product_aliases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  alias_type text not null default 'search_alias' check (alias_type in ('search_alias','legacy_sku','barcode')),
  value text not null,
  normalized_value text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(company_id, normalized_value)
);
create index if not exists product_aliases_trgm_idx on public.product_aliases using gin (normalized_value extensions.gin_trgm_ops);

alter table public.price_lists
  add column if not exists semantic_code text,
  add column if not exists status text not null default 'pending_review',
  add column if not exists source text not null default 'alpha',
  add column if not exists is_default boolean not null default false,
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null;
alter table public.price_lists drop constraint if exists price_lists_semantic_code_check;
alter table public.price_lists add constraint price_lists_semantic_code_check
  check (semantic_code is null or semantic_code in ('primera','segunda','tercera','top'));
alter table public.price_lists drop constraint if exists price_lists_status_check;
alter table public.price_lists add constraint price_lists_status_check check (status in ('pending_review','active','inactive'));
create unique index if not exists price_lists_company_semantic_key on public.price_lists(company_id, semantic_code) where semantic_code is not null;
create unique index if not exists price_lists_company_default_key on public.price_lists(company_id) where is_default;

alter table public.product_prices
  add column if not exists valid_from timestamptz not null default now(),
  add column if not exists valid_to timestamptz,
  add column if not exists source_file_name text,
  add column if not exists import_batch_id uuid references public.import_batches(id) on delete set null,
  add column if not exists created_by uuid references auth.users(id) on delete set null;
alter table public.product_prices drop constraint if exists product_prices_product_id_price_list_id_key;
alter table public.product_prices drop constraint if exists product_prices_validity_check;
alter table public.product_prices add constraint product_prices_validity_check check (valid_to is null or valid_to > valid_from);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'product_prices_no_overlap') then
    alter table public.product_prices add constraint product_prices_no_overlap exclude using gist
      (product_id with =, price_list_id with =,
       tstzrange(valid_from, coalesce(valid_to, 'infinity'::timestamptz), '[)') with &&);
  end if;
end $$;

create table if not exists public.product_costs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  cost_type text not null check (cost_type in ('replacement_cost','standard_cost','average_cost')),
  amount numeric(18,6) not null check (amount >= 0),
  currency_code text not null,
  valid_from timestamptz not null,
  valid_to timestamptz,
  source_file_name text,
  import_batch_id uuid references public.import_batches(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  exclude using gist (product_id with =, cost_type with =, currency_code with =,
    tstzrange(valid_from, coalesce(valid_to, 'infinity'::timestamptz), '[)') with &&)
);
create index if not exists product_costs_company_product_idx on public.product_costs(company_id, product_id, valid_from desc);

create or replace function public.audit_product_commercial_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_entity uuid; v_action text; v_metadata jsonb;
begin
  if tg_table_name='products' then
    v_company:=coalesce(new.company_id,old.company_id); v_entity:=coalesce(new.id,old.id);
    v_action:=case when tg_op='INSERT' then 'product.created' when old.is_active is distinct from new.is_active then 'product.status_changed' else 'product.updated' end;
    v_metadata:=jsonb_build_object('alpha_sku',coalesce(new.alpha_sku,old.alpha_sku),'operation',tg_op);
  elsif tg_table_name='product_prices' then
    select company_id into v_company from public.products where id=coalesce(new.product_id,old.product_id); v_entity:=coalesce(new.id,old.id);
    v_action:='price.changed'; v_metadata:=jsonb_build_object('product_id',coalesce(new.product_id,old.product_id),'price_list_id',coalesce(new.price_list_id,old.price_list_id),'operation',tg_op);
  else
    v_company:=coalesce(new.company_id,old.company_id); v_entity:=coalesce(new.id,old.id); v_action:='cost.changed';
    v_metadata:=jsonb_build_object('product_id',coalesce(new.product_id,old.product_id),'cost_type',coalesce(new.cost_type,old.cost_type),'operation',tg_op);
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_company,auth.uid(),v_action,tg_table_name,v_entity,v_metadata);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists products_commercial_audit on public.products;
create trigger products_commercial_audit after insert or update on public.products for each row execute function public.audit_product_commercial_change();
drop trigger if exists product_prices_commercial_audit on public.product_prices;
create trigger product_prices_commercial_audit after insert or update or delete on public.product_prices for each row execute function public.audit_product_commercial_change();
drop trigger if exists product_costs_commercial_audit on public.product_costs;
create trigger product_costs_commercial_audit after insert or update or delete on public.product_costs for each row execute function public.audit_product_commercial_change();

alter table public.import_staging_errors add column if not exists context_key text;
alter table public.import_batches drop constraint if exists import_batches_import_type_check;
alter table public.import_batches add constraint import_batches_import_type_check
  check (import_type in ('products','inventory','prices','costs','unsupported'));
alter table public.import_staging_rows drop constraint if exists import_staging_rows_detected_type_check;
alter table public.import_staging_rows add constraint import_staging_rows_detected_type_check
  check (detected_type in ('products','inventory','prices','costs'));

insert into public.permissions(code, description) values
  ('view_prices','Consultar precios de venta.'),
  ('manage_prices','Configurar listas y precios.'),
  ('import_prices','Importar listas de precios Alpha.'),
  ('import_costs','Importar costos Alpha.')
on conflict(code) do update set description = excluded.description;
insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id from public.roles role_data cross join public.permissions permission_data
where role_data.code in ('super_admin','direccion_admin')
  and permission_data.code in ('view_prices','manage_prices','import_prices','import_costs','view_costs')
on conflict do nothing;
insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id from public.roles role_data cross join public.permissions permission_data
where role_data.code in ('sucursal','ingeniero_campo','almacen','punto_venta') and permission_data.code = 'view_prices'
on conflict do nothing;

create or replace function public.sync_product_commercial_fields()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_unit uuid; v_category uuid; v_type text := lower(coalesce(new.product_type,''));
begin
  if nullif(trim(coalesce(new.unit,'')), '') is not null then
    insert into public.units_of_measure(company_id, code, name) values (new.company_id, trim(new.unit), trim(new.unit))
    on conflict(company_id, code) do update set name = excluded.name returning id into v_unit;
    if v_unit is null then select id into v_unit from public.units_of_measure where company_id=new.company_id and code=trim(new.unit); end if;
  end if;
  if nullif(trim(coalesce(new.alpha_class,'')), '') is not null then
    insert into public.product_categories(company_id, external_code, name)
    values (new.company_id, trim(new.alpha_class), trim(new.alpha_class))
    on conflict(company_id, external_code) do update set name=excluded.name returning id into v_category;
    if v_category is null then select id into v_category from public.product_categories where company_id=new.company_id and external_code=trim(new.alpha_class); end if;
  end if;
  update public.products set base_unit_id=coalesce(v_unit,base_unit_id), sales_unit_id=coalesce(v_unit,sales_unit_id), category_id=coalesce(v_category,category_id),
    is_active = case when v_type='eliminados' then false else true end,
    is_sellable = case when v_type in ('p. terminado','servicios') then true else false end,
    is_inventory_tracked = case when v_type='p. terminado' then true else false end,
    commercial_review_required = case when v_type='activos' then true else false end
  where id=new.id;
  return new;
end $$;
drop trigger if exists products_sync_commercial_fields on public.products;
create trigger products_sync_commercial_fields after insert or update of unit, alpha_class, product_type on public.products
for each row execute function public.sync_product_commercial_fields();

insert into public.units_of_measure(company_id, code, name)
select distinct company_id, trim(unit), trim(unit) from public.products where nullif(trim(coalesce(unit,'')),'') is not null
on conflict(company_id, code) do nothing;
insert into public.product_categories(company_id, external_code, name)
select distinct company_id, trim(alpha_class), trim(alpha_class) from public.products where nullif(trim(coalesce(alpha_class,'')),'') is not null
on conflict(company_id, external_code) do nothing;
update public.products product set
  is_active=case when lower(coalesce(product.product_type,''))='eliminados' then false else true end,
  is_sellable=lower(coalesce(product.product_type,'')) in ('p. terminado','servicios'),
  is_inventory_tracked=lower(coalesce(product.product_type,''))='p. terminado',
  commercial_review_required=lower(coalesce(product.product_type,''))='activos';
update public.products product set base_unit_id=unit_data.id,sales_unit_id=unit_data.id
from public.units_of_measure unit_data where unit_data.company_id=product.company_id and unit_data.code=trim(product.unit);
update public.products product set category_id=category_data.id
from public.product_categories category_data where category_data.company_id=product.company_id and category_data.external_code=trim(product.alpha_class);

create or replace function public.can_import_commercial(target_company_id uuid, target_type text)
returns boolean language sql stable security definer set search_path=public as $$
  select case target_type when 'prices' then public.has_company_permission(target_company_id,'import_prices')
    when 'costs' then public.has_company_permission(target_company_id,'import_costs')
    else public.has_company_permission(target_company_id,'import_data') end;
$$;

create or replace function public.stage_alpha_import(
  p_company_id uuid, p_import_type text, p_source text, p_file_name text, p_file_type text,
  p_file_sha256 text, p_snapshot_date date, p_rows jsonb, p_errors jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch_id uuid; v_completed uuid; v_retry uuid; v_received integer; v_batch public.import_batches%rowtype;
begin
  if auth.uid() is null or not public.can_import_commercial(p_company_id,p_import_type) then raise exception 'No autorizado para preparar esta importación.'; end if;
  if p_import_type not in ('products','inventory','prices','costs','unsupported') then raise exception 'Tipo no permitido.'; end if;
  if p_source not in ('manual_upload','local_development') then raise exception 'Origen no permitido.'; end if;
  select id into v_completed from public.import_batches where company_id=p_company_id and import_type=p_import_type and file_sha256=p_file_sha256 and status='completed' limit 1;
  if v_completed is not null then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(p_company_id,auth.uid(),'import.duplicate_detected','import_batch',v_completed,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256,'import_type',p_import_type));
    return jsonb_build_object('status','duplicate','batch_id',v_completed,'message','Este archivo ya fue importado correctamente.');
  end if;
  select id into v_retry from public.import_batches where company_id=p_company_id and import_type=p_import_type and file_sha256=p_file_sha256 and status in ('failed','validation_failed','discarded','expired') order by started_at desc limit 1;
  select count(*) into v_received from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb));
  insert into public.import_batches(company_id,import_type,source,file_sha256,status,records_received,imported_by,snapshot_date,retry_of_batch_id,last_activity_at)
  values(p_company_id,p_import_type,p_source,p_file_sha256,'staged',v_received,auth.uid(),p_snapshot_date,v_retry,now()) returning id into v_batch_id;
  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count) values(v_batch_id,p_file_name,p_file_type,p_file_sha256,v_received);
  insert into public.import_staging_rows(import_batch_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status)
  select v_batch_id,(item->>'row_number')::int,item->>'source_file',item->>'detected_type',coalesce(item->'raw_data','{}'),coalesce(item->'normalized_data','{}'),item->>'validation_status'
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) item;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key)
  select v_batch_id,item->>'severity',item->>'error_code',item->>'message',nullif(item->>'row_number','')::int,nullif(item->>'alpha_sku',''),nullif(item->>'location_code',''),nullif(item->>'context_key','')
  from jsonb_array_elements(coalesce(p_errors,'[]'::jsonb)) item;
  update public.import_staging_errors e set staging_row_id=r.id from public.import_staging_rows r
  where e.import_batch_id=v_batch_id and r.import_batch_id=v_batch_id and e.row_number=r.row_number;
  perform public.refresh_import_staging_batch(v_batch_id,false); select * into v_batch from public.import_batches where id=v_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values
    (p_company_id,auth.uid(),'import.file_uploaded','import_batch',v_batch_id,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256,'import_type',p_import_type)),
    (p_company_id,auth.uid(),'import.preview_generated','import_batch',v_batch_id,jsonb_build_object('records_received',v_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows));
  return jsonb_build_object('status',v_batch.status,'batch_id',v_batch_id,'records_received',v_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows,'blocking_errors',v_batch.blocking_error_count,'pending_warnings',v_batch.pending_warning_count);
end $$;

create or replace function public.review_staged_currency(p_import_batch_id uuid,p_source_label text,p_currency_code text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_rows integer;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id for update;
  if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,v_batch.import_type) then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged','validation_failed') or v_batch.import_type not in ('prices','costs') then raise exception 'Lote no editable.'; end if;
  if p_currency_code !~ '^[A-Z]{3}$' then raise exception 'Código ISO inválido.'; end if;
  update public.import_staging_rows set normalized_data=jsonb_set(normalized_data,'{currencyCode}',to_jsonb(p_currency_code),true)
  where import_batch_id=p_import_batch_id and normalized_data->>'currencyLabel'=p_source_label; get diagnostics v_rows=row_count;
  update public.import_staging_errors set resolved_by=auth.uid(),resolved_at=now(),resolution_note='Moneda confirmada: '||p_currency_code
  where import_batch_id=p_import_batch_id and error_code='MONEDA_SIN_MAPEAR' and context_key=p_source_label and resolved_at is null;
  perform public.refresh_import_staging_batch(p_import_batch_id,true);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'import.currency_mapped','import_batch',p_import_batch_id,jsonb_build_object('source',p_source_label,'currency_code',p_currency_code,'rows',v_rows));
  return jsonb_build_object('status','resolved','rows',v_rows);
end $$;

create or replace function public.review_staged_price_list(p_import_batch_id uuid,p_external_code text,p_semantic_code text,p_is_default boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_rows integer;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'manage_prices') then raise exception 'No autorizado.'; end if;
  if v_batch.status not in ('staged','validation_failed') or v_batch.import_type<>'prices' then raise exception 'Lote no editable.'; end if;
  if p_semantic_code not in ('primera','segunda','tercera','top') then raise exception 'Segmento inválido.'; end if;
  if exists(select 1 from public.import_staging_rows where import_batch_id=p_import_batch_id and normalized_data->>'semanticCode'=p_semantic_code and normalized_data->>'listExternalCode'<>p_external_code) then raise exception 'El segmento ya está asignado.'; end if;
  if p_is_default then update public.import_staging_rows set normalized_data=jsonb_set(normalized_data,'{isDefault}','false'::jsonb,true) where import_batch_id=p_import_batch_id and detected_type='prices'; end if;
  update public.import_staging_rows set normalized_data=jsonb_set(jsonb_set(normalized_data,'{semanticCode}',to_jsonb(p_semantic_code),true),'{isDefault}',to_jsonb(p_is_default),true)
  where import_batch_id=p_import_batch_id and normalized_data->>'listExternalCode'=p_external_code; get diagnostics v_rows=row_count;
  update public.import_staging_errors set resolved_by=auth.uid(),resolved_at=now(),resolution_note='Lista asignada a '||p_semantic_code
  where import_batch_id=p_import_batch_id and error_code='LISTA_PRECIO_SIN_MAPEAR' and context_key=p_external_code and resolved_at is null;
  perform public.refresh_import_staging_batch(p_import_batch_id,true);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'price_list.mapped','import_batch',p_import_batch_id,jsonb_build_object('external_code',p_external_code,'semantic_code',p_semantic_code,'is_default',p_is_default,'rows',v_rows));
  return jsonb_build_object('status','resolved','rows',v_rows);
end $$;

create or replace function public.get_commercial_import_requirements(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype;
begin
 select * into v_batch from public.import_batches where id=p_import_batch_id;
 if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,v_batch.import_type) then raise exception 'No autorizado.'; end if;
 return jsonb_build_object(
  'currencies',coalesce((select jsonb_agg(x) from (select normalized_data->>'currencyLabel' source_label,normalized_data->>'currencyCode' currency_code,count(*) rows from public.import_staging_rows where import_batch_id=p_import_batch_id and detected_type in ('prices','costs') group by 1,2 order by 1)x),'[]'),
  'price_lists',coalesce((select jsonb_agg(x) from (select normalized_data->>'listExternalCode' external_code,normalized_data->>'semanticCode' semantic_code,coalesce((normalized_data->>'isDefault')::boolean,false) is_default,count(*) rows from public.import_staging_rows where import_batch_id=p_import_batch_id and detected_type='prices' group by 1,2,3 order by 1)x),'[]')
 );
end $$;

create or replace function public.confirm_commercial_import(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_file text; v_effective timestamptz; v_records integer:=0; v_error text; v_dup uuid;
begin
 select * into v_batch from public.import_batches where id=p_import_batch_id for update;
 if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,v_batch.import_type) then raise exception 'No autorizado.'; end if;
 if v_batch.import_type not in ('prices','costs') then raise exception 'Tipo comercial inválido.'; end if;
 perform public.refresh_import_staging_batch(p_import_batch_id,false); select * into v_batch from public.import_batches where id=p_import_batch_id;
 if v_batch.blocking_error_count>0 or v_batch.pending_warning_count>0 then return jsonb_build_object('status','validation_failed','message','Resuelve errores y reconoce warnings antes de confirmar.'); end if;
 if v_batch.status<>'staged' or v_batch.snapshot_date is null then return jsonb_build_object('status','validation_failed','message','Falta vigencia efectiva.'); end if;
 select id into v_dup from public.import_batches where company_id=v_batch.company_id and import_type=v_batch.import_type and file_sha256=v_batch.file_sha256 and status='completed' and id<>v_batch.id limit 1;
 if v_dup is not null then return jsonb_build_object('status','duplicate','batch_id',v_dup); end if;
 select original_name into v_file from public.import_files where import_batch_id=p_import_batch_id order by created_at limit 1;
 v_effective := v_batch.snapshot_date::timestamptz;
 begin
  if exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and not exists(select 1 from public.products p where p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku')) then raise exception 'Existen SKU sin producto.'; end if;
  if exists(select 1 from public.import_staging_rows where import_batch_id=p_import_batch_id and nullif(normalized_data->>'currencyCode','') is null) then raise exception 'Existen monedas sin mapear.'; end if;
  if v_batch.import_type='prices' then
    if exists(select 1 from public.import_staging_rows where import_batch_id=p_import_batch_id and detected_type='prices' and nullif(normalized_data->>'semanticCode','') is null) then raise exception 'Existen listas sin asignación.'; end if;
    if not exists(select 1 from public.import_staging_rows where import_batch_id=p_import_batch_id and detected_type='prices' and coalesce((normalized_data->>'isDefault')::boolean,false)) then raise exception 'Selecciona una lista predeterminada.'; end if;
    update public.price_lists set is_default=false where company_id=v_batch.company_id;
    insert into public.price_lists(company_id,external_code,name,currency_code,is_active,semantic_code,status,source,is_default,reviewed_at,reviewed_by)
    select distinct v_batch.company_id,r.normalized_data->>'listExternalCode',initcap(r.normalized_data->>'semanticCode'),r.normalized_data->>'currencyCode',true,r.normalized_data->>'semanticCode','active','alpha',coalesce((r.normalized_data->>'isDefault')::boolean,false),now(),auth.uid()
    from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.detected_type='prices'
    on conflict(company_id,external_code) do update set name=excluded.name,currency_code=excluded.currency_code,semantic_code=excluded.semantic_code,status='active',is_active=true,is_default=excluded.is_default,reviewed_at=now(),reviewed_by=auth.uid();
    update public.product_prices pp set valid_to=v_effective
    where valid_to is null and valid_from<v_effective and exists(select 1 from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' join public.price_lists pl on pl.company_id=v_batch.company_id and pl.external_code=r.normalized_data->>'listExternalCode' where r.import_batch_id=p_import_batch_id and pp.product_id=p.id and pp.price_list_id=pl.id);
    if exists(select 1 from public.product_prices pp join public.products p on p.id=pp.product_id join public.price_lists pl on pl.id=pp.price_list_id
      where p.company_id=v_batch.company_id and pp.valid_to is null and pp.valid_from>=v_effective
      and exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.normalized_data->>'alphaSku'=p.alpha_sku and r.normalized_data->>'listExternalCode'=pl.external_code))
    then raise exception 'La vigencia debe ser posterior al precio vigente.'; end if;
    insert into public.product_prices(product_id,price_list_id,amount,currency_code,valid_from,source_file_name,import_batch_id,created_by)
    select p.id,pl.id,(r.normalized_data->>'amount')::numeric,r.normalized_data->>'currencyCode',v_effective,v_file,p_import_batch_id,auth.uid()
    from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' join public.price_lists pl on pl.company_id=v_batch.company_id and pl.external_code=r.normalized_data->>'listExternalCode'
    where r.import_batch_id=p_import_batch_id and r.detected_type='prices' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and (r.normalized_data->>'amount')::numeric>=0;
    get diagnostics v_records=row_count;
  else
    update public.product_costs pc set valid_to=v_effective where company_id=v_batch.company_id and cost_type='replacement_cost' and valid_to is null and valid_from<v_effective and exists(select 1 from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' where r.import_batch_id=p_import_batch_id and pc.product_id=p.id);
    if exists(select 1 from public.product_costs pc join public.products p on p.id=pc.product_id
      where pc.company_id=v_batch.company_id and pc.cost_type='replacement_cost' and pc.valid_to is null and pc.valid_from>=v_effective
      and exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.normalized_data->>'alphaSku'=p.alpha_sku))
    then raise exception 'La vigencia debe ser posterior al costo vigente.'; end if;
    insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,import_batch_id,created_by)
    select v_batch.company_id,p.id,'replacement_cost',(r.normalized_data->>'replacementCost')::numeric,r.normalized_data->>'currencyCode',v_effective,v_file,p_import_batch_id,auth.uid()
    from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku'
    where r.import_batch_id=p_import_batch_id and r.detected_type='costs' and nullif(r.normalized_data->>'replacementCost','') is not null and (r.normalized_data->>'replacementCost')::numeric>=0;
    get diagnostics v_records=row_count;
  end if;
  update public.import_batches set status='completed',records_imported=v_records,completed_at=now(),closed_at=now(),last_activity_at=now(),notes=null where id=p_import_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),case when v_batch.import_type='prices' then 'price.imported' else 'cost.imported' end,'import_batch',p_import_batch_id,jsonb_build_object('records_imported',v_records,'source_file',v_file,'valid_from',v_effective));
 exception when others then v_error:=sqlerrm; end;
 if v_error is not null then update public.import_batches set status='failed',completed_at=now(),closed_at=now(),notes=v_error where id=p_import_batch_id; insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'import.failed','import_batch',p_import_batch_id,jsonb_build_object('error',v_error)); return jsonb_build_object('status','failed','message',v_error,'batch_id',p_import_batch_id); end if;
 return jsonb_build_object('status','completed','records_imported',v_records,'batch_id',p_import_batch_id);
end $$;

create or replace function public.get_product_cost(p_company_id uuid,p_product_id uuid,p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No autorizado para consultar costos.'; end if;
 return (select to_jsonb(x) from (select cost_type,amount,currency_code,valid_from,valid_to from public.product_costs where company_id=p_company_id and product_id=p_product_id and valid_from<=p_at and (valid_to is null or valid_to>p_at) order by valid_from desc limit 1)x);
end $$;

create or replace function public.product_pos_readiness(
  p_company_id uuid,
  p_product_id uuid,
  p_price_list_id uuid default null,
  p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_product public.products%rowtype;
  v_list uuid;
  v_has_price boolean;
  v_has_tax boolean;
  v_has_cost boolean;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'No autorizado.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  select coalesce(p_price_list_id,(select id from public.price_lists where company_id=p_company_id and is_default and status='active' limit 1)) into v_list;
  select exists(select 1 from public.product_prices where product_id=p_product_id and price_list_id=v_list and amount>0 and valid_from<=p_at and (valid_to is null or valid_to>p_at)) into v_has_price;
  select exists(select 1 from public.tax_rates where tax_category_id=v_product.tax_category_id and valid_from<=p_at and (valid_to is null or valid_to>p_at)) into v_has_tax;
  select exists(select 1 from public.product_costs where company_id=p_company_id and product_id=p_product_id and valid_from<=p_at and (valid_to is null or valid_to>p_at)) into v_has_cost;
  return jsonb_build_object(
    'product_id',v_product.id,
    'is_active',v_product.is_active,
    'is_sellable',v_product.is_sellable,
    'sales_unit_valid',v_product.sales_unit_id is not null,
    'tax_configured',v_product.tax_category_id is not null and v_has_tax,
    'price_configured',v_has_price,
    'classification_resolved',not v_product.commercial_review_required,
    'cost_available_for_margin',case when public.has_company_permission(p_company_id,'view_costs') then v_has_cost else null end,
    'pos_ready',v_product.is_active and v_product.is_sellable and v_product.sales_unit_id is not null and v_product.tax_category_id is not null and v_has_tax and v_has_price and not v_product.commercial_review_required
  );
end $$;

create or replace function public.retry_staged_import(p_import_batch_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_source public.import_batches%rowtype; v_new_id uuid; v_completed uuid;
begin
  if nullif(trim(p_reason),'') is null then raise exception 'Indica el motivo del reintento.'; end if;
  select * into v_source from public.import_batches where id=p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_source.company_id,v_source.import_type) then raise exception 'No autorizado.'; end if;
  if v_source.status<>'failed' then raise exception 'Solo los lotes fallidos pueden reintentarse.'; end if;
  if v_source.staging_purged_at is not null then raise exception 'El staging del lote ya fue purgado.'; end if;
  select id into v_completed from public.import_batches where company_id=v_source.company_id and import_type=v_source.import_type and file_sha256=v_source.file_sha256 and status='completed' limit 1;
  if v_completed is not null then return jsonb_build_object('status','duplicate','batch_id',v_completed); end if;
  insert into public.import_batches(company_id,import_type,source,file_sha256,status,records_received,imported_by,snapshot_date,retry_of_batch_id,last_activity_at)
  values(v_source.company_id,v_source.import_type,v_source.source,v_source.file_sha256,'staged',v_source.records_received,auth.uid(),v_source.snapshot_date,v_source.id,now()) returning id into v_new_id;
  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count)
  select v_new_id,original_name,file_type,file_sha256,row_count from public.import_files where import_batch_id=p_import_batch_id;
  insert into public.import_staging_rows(import_batch_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status,resolved_product_id,resolved_by,resolved_at,resolution_reason)
  select v_new_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status,resolved_product_id,resolved_by,resolved_at,resolution_reason from public.import_staging_rows where import_batch_id=p_import_batch_id;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key,resolved_by,resolved_at,resolution_note,acknowledged_by,acknowledged_at,acknowledgement_note)
  select v_new_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key,resolved_by,resolved_at,resolution_note,acknowledged_by,acknowledged_at,acknowledgement_note from public.import_staging_errors where import_batch_id=p_import_batch_id;
  update public.import_staging_errors e set staging_row_id=r.id from public.import_staging_rows r where e.import_batch_id=v_new_id and r.import_batch_id=v_new_id and e.row_number=r.row_number;
  perform public.refresh_import_staging_batch(v_new_id,false);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_source.company_id,auth.uid(),'import.retry_created','import_batch',v_new_id,jsonb_build_object('retry_of_batch_id',p_import_batch_id,'reason',trim(p_reason)));
  return jsonb_build_object('status',(select status from public.import_batches where id=v_new_id),'batch_id',v_new_id);
end $$;

create or replace function public.search_products(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,p_category_id uuid default null,p_is_active boolean default null,p_is_sellable boolean default null,p_inventory_tracked boolean default null,p_price_list_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),100); v_q text:=lower(trim(coalesce(p_query,''))); v_total bigint; v_items jsonb; v_list uuid;
begin
 if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'No autorizado.'; end if;
 if not public.has_company_permission(p_company_id,'view_prices') then p_price_list_id:=null; end if;
 select coalesce(p_price_list_id,(select id from public.price_lists where company_id=p_company_id and is_default and status='active' limit 1)) into v_list;
 select count(*) into v_total from public.products p where p.company_id=p_company_id and (p_category_id is null or p.category_id=p_category_id) and (p_is_active is null or p.is_active=p_is_active) and (p_is_sellable is null or p.is_sellable=p_is_sellable) and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
  and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'));
 with filtered as (
  select p.*,case when v_q='' then 0 when lower(coalesce(p.barcode,''))=v_q then 1 when lower(p.alpha_sku)=v_q or lower(coalesce(p.internal_sku,''))=v_q then 2 when lower(p.alpha_sku) like v_q||'%' then 3 when exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%') then 4 else 5 end rank
  from public.products p where p.company_id=p_company_id and (p_category_id is null or p.category_id=p_category_id) and (p_is_active is null or p.is_active=p_is_active) and (p_is_sellable is null or p.is_sellable=p_is_sellable) and (p_inventory_tracked is null or p.is_inventory_tracked=p_inventory_tracked)
  and (v_q='' or lower(p.alpha_sku) like '%'||v_q||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(p.barcode,''))=v_q or lower(p.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases a where a.product_id=p.id and a.normalized_value like '%'||v_q||'%'))
 ), paged as (select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size)
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,'name',p.name,'unit',p.unit,'alpha_class',p.alpha_class,'product_group',p.product_group,'product_type',p.product_type,'is_active',p.is_active,'is_sellable',p.is_sellable,'is_inventory_tracked',p.is_inventory_tracked,'category_id',p.category_id,'tax_category_id',p.tax_category_id,'price',case when public.has_company_permission(p_company_id,'view_prices') then price.amount else null end,'currency_code',case when public.has_company_permission(p_company_id,'view_prices') then price.currency_code else null end,'pos_ready',p.is_active and p.is_sellable and not p.commercial_review_required and p.sales_unit_id is not null and p.tax_category_id is not null and price.amount>0 and exists(select 1 from public.tax_rates tr where tr.tax_category_id=p.tax_category_id and tr.valid_from<=now() and (tr.valid_to is null or tr.valid_to>now()))) order by p.rank,p.name),'[]'::jsonb) into v_items
 from paged p left join lateral(select pp.id,pp.amount,pp.currency_code from public.product_prices pp where pp.product_id=p.id and pp.price_list_id=v_list and pp.valid_from<=now() and (pp.valid_to is null or pp.valid_to>now()) order by pp.valid_from desc limit 1)price on true;
 return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_list);
end $$;

alter table public.units_of_measure enable row level security;
alter table public.product_categories enable row level security;
alter table public.tax_categories enable row level security;
alter table public.tax_rates enable row level security;
alter table public.product_aliases enable row level security;
alter table public.product_costs enable row level security;
create policy units_read on public.units_of_measure for select to authenticated using(public.has_company_access(company_id));
create policy categories_read on public.product_categories for select to authenticated using(public.has_company_access(company_id));
create policy tax_categories_read on public.tax_categories for select to authenticated using(public.has_company_access(company_id));
create policy tax_rates_read on public.tax_rates for select to authenticated using(exists(select 1 from public.tax_categories t where t.id=tax_category_id and public.has_company_access(t.company_id)));
create policy aliases_read on public.product_aliases for select to authenticated using(public.has_company_access(company_id));
create policy commercial_reference_write_units on public.units_of_measure for all to authenticated using(public.has_company_permission(company_id,'manage_products')) with check(public.has_company_permission(company_id,'manage_products'));
create policy commercial_reference_write_categories on public.product_categories for all to authenticated using(public.has_company_permission(company_id,'manage_products')) with check(public.has_company_permission(company_id,'manage_products'));
create policy commercial_reference_write_tax on public.tax_categories for all to authenticated using(public.has_company_permission(company_id,'manage_products')) with check(public.has_company_permission(company_id,'manage_products'));
create policy commercial_reference_write_tax_rates on public.tax_rates for all to authenticated
using(exists(select 1 from public.tax_categories t where t.id=tax_category_id and public.has_company_permission(t.company_id,'manage_products')))
with check(exists(select 1 from public.tax_categories t where t.id=tax_category_id and public.has_company_permission(t.company_id,'manage_products')));
create policy aliases_write on public.product_aliases for all to authenticated using(public.has_company_permission(company_id,'manage_products')) with check(public.has_company_permission(company_id,'manage_products'));
drop policy if exists price_lists_read on public.price_lists;
create policy price_lists_read on public.price_lists for select to authenticated using(public.has_company_permission(company_id,'view_prices'));
drop policy if exists product_prices_read on public.product_prices;
create policy product_prices_read on public.product_prices for select to authenticated using(exists(select 1 from public.products p where p.id=product_id and public.has_company_permission(p.company_id,'view_prices')));
drop policy if exists price_lists_write on public.price_lists;
create policy price_lists_write on public.price_lists for all to authenticated using(public.has_company_permission(company_id,'manage_prices')) with check(public.has_company_permission(company_id,'manage_prices'));
drop policy if exists product_prices_write on public.product_prices;
create policy product_prices_write on public.product_prices for all to authenticated
using(exists(select 1 from public.products p where p.id=product_id and public.has_company_permission(p.company_id,'manage_prices')))
with check(exists(select 1 from public.products p where p.id=product_id and public.has_company_permission(p.company_id,'manage_prices')));

grant select on public.units_of_measure,public.product_categories,public.tax_categories,public.tax_rates,public.product_aliases to authenticated;
revoke all on public.product_costs from authenticated;
revoke all on function public.get_product_cost(uuid,uuid,timestamptz) from public;
grant execute on function public.get_product_cost(uuid,uuid,timestamptz) to authenticated;
revoke all on function public.product_pos_readiness(uuid,uuid,uuid,timestamptz) from public;
grant execute on function public.product_pos_readiness(uuid,uuid,uuid,timestamptz) to authenticated;
revoke all on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) from public;
grant execute on function public.search_products(uuid,text,integer,integer,uuid,boolean,boolean,boolean,uuid) to authenticated;
revoke all on function public.review_staged_currency(uuid,text,text) from public;
revoke all on function public.review_staged_price_list(uuid,text,text,boolean) from public;
revoke all on function public.get_commercial_import_requirements(uuid) from public;
revoke all on function public.confirm_commercial_import(uuid) from public;
grant execute on function public.review_staged_currency(uuid,text,text),public.review_staged_price_list(uuid,text,text,boolean),public.get_commercial_import_requirements(uuid),public.confirm_commercial_import(uuid) to authenticated;
