-- Satrapy · Module 3A: canonical supplier master and safe Alpha promotion.
-- Purchase orders, receipts, AP documents and payments remain staging evidence.

insert into public.permissions(code,description) values
  ('view_suppliers','Consultar el catálogo canónico de proveedores.'),
  ('manage_suppliers','Crear y editar proveedores canónicos.'),
  ('promote_suppliers','Promover proveedores preparados desde staging y resolver excepciones.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in ('view_suppliers','manage_suppliers','promote_suppliers')
on conflict do nothing;

create or replace function public.normalize_supplier_identity(p_value text)
returns text language sql immutable parallel safe as $$
  select regexp_replace(lower(trim(coalesce(p_value,''))),'[^[:alnum:]]','','g')
$$;

create or replace function public.canonical_supplier_tax_id(p_value text)
returns text language sql immutable parallel safe as $$
  select case
    when upper(regexp_replace(coalesce(p_value,''),'[^A-Za-z0-9]','','g')) in ('XAXX010101000','XEXX010101000') then null
    when upper(regexp_replace(coalesce(p_value,''),'[^A-Za-z0-9]','','g')) ~ '^[A-Z&Ñ]{3,4}[0-9]{6}[A-Z0-9]{3}$'
      then upper(regexp_replace(p_value,'[^A-Za-z0-9&Ñ]','','g'))
    else null end
$$;

create table public.suppliers(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check(length(trim(code))>0),
  display_name text not null check(length(trim(display_name))>0),
  legal_name text,
  tax_id text,
  supplier_category text,
  address_line text,
  neighborhood text,
  municipality text,
  state_name text,
  phone text,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index suppliers_company_code_uidx on public.suppliers(company_id,lower(code));
create unique index suppliers_company_tax_id_uidx on public.suppliers(company_id,tax_id) where tax_id is not null;
create index suppliers_company_name_idx on public.suppliers(company_id,public.normalize_supplier_identity(display_name),id);
create index suppliers_company_active_idx on public.suppliers(company_id,is_active,display_name,id);
create trigger suppliers_updated_at before update on public.suppliers for each row execute function public.set_updated_at();

create table public.supplier_external_references(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  source_system text not null check(length(trim(source_system))>0),
  external_code text not null check(length(trim(external_code))>0),
  source_row_hash text,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,source_system,external_code),
  unique(company_id,source_system,source_row_hash)
);
create index supplier_external_references_supplier_idx on public.supplier_external_references(supplier_id);

create table public.supplier_import_exceptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  staged_supplier_id uuid not null references public.alpha_purchasing_import_suppliers(id) on delete cascade,
  conflict_kinds text[] not null check(cardinality(conflict_kinds)>0),
  candidate_supplier_ids uuid[] not null default '{}',
  status text not null default 'pending' check(status in ('pending','resolved')),
  decision text check(decision in ('link_existing','create_separate')),
  resolved_supplier_id uuid references public.suppliers(id) on delete restrict,
  resolution_reason text,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete restrict,
  unique(batch_id,staged_supplier_id)
);
create index supplier_import_exceptions_inbox_idx on public.supplier_import_exceptions(company_id,status,detected_at,id);

alter table public.alpha_purchasing_import_suppliers add column promoted_supplier_id uuid references public.suppliers(id) on delete restrict;
alter table public.alpha_purchasing_import_batches add column supplier_promotion_completed_at timestamptz;
alter table public.alpha_purchasing_import_batches add column supplier_promotion_summary jsonb not null default '{}'::jsonb;

alter table public.suppliers enable row level security;
alter table public.supplier_external_references enable row level security;
alter table public.supplier_import_exceptions enable row level security;
create policy suppliers_read on public.suppliers for select to authenticated using(public.has_company_permission(company_id,'view_suppliers'));
create policy supplier_refs_read on public.supplier_external_references for select to authenticated using(public.has_company_permission(company_id,'view_suppliers'));
create policy supplier_exceptions_read on public.supplier_import_exceptions for select to authenticated using(public.has_company_permission(company_id,'promote_suppliers') or public.has_company_permission(company_id,'view_import_audit'));
revoke all on public.suppliers,public.supplier_external_references,public.supplier_import_exceptions from authenticated;

create or replace function public.search_suppliers(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,
  p_is_active boolean default null,p_origin text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),100); v_q text:=lower(trim(coalesce(p_query,''))); v_total bigint; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_suppliers') then raise exception 'No autorizado para consultar proveedores.'; end if;
  with filtered as materialized(
    select s.*,exists(select 1 from public.supplier_external_references er where er.supplier_id=s.id and er.source_system='alpha') imported
    from public.suppliers s where s.company_id=p_company_id and (p_is_active is null or s.is_active=p_is_active)
      and (p_origin is null or (p_origin='imported' and exists(select 1 from public.supplier_external_references er where er.supplier_id=s.id and er.source_system='alpha')) or (p_origin='manual' and not exists(select 1 from public.supplier_external_references er where er.supplier_id=s.id and er.source_system='alpha')))
      and (v_q='' or lower(s.code) like '%'||v_q||'%' or lower(s.display_name) like '%'||v_q||'%' or lower(coalesce(s.legal_name,'')) like '%'||v_q||'%' or lower(coalesce(s.tax_id,'')) like '%'||v_q||'%' or lower(coalesce(s.phone,'')) like '%'||v_q||'%'
        or exists(select 1 from public.supplier_external_references er where er.supplier_id=s.id and lower(er.external_code) like '%'||v_q||'%'))
  ), counted as(select count(*) total from filtered), paged as(select * from filtered order by display_name,id limit v_size offset (v_page-1)*v_size)
  select (select total from counted),coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'display_name',display_name,'legal_name',legal_name,'tax_id',tax_id,'supplier_category',supplier_category,'address_line',address_line,'neighborhood',neighborhood,'municipality',municipality,'state_name',state_name,'phone',phone,'is_active',is_active,'origin',case when imported then 'imported' else 'manual' end,'updated_at',updated_at) order by display_name,id),'[]'::jsonb)
  into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.save_supplier(
  p_company_id uuid,p_supplier_id uuid,p_code text,p_display_name text,p_legal_name text default null,p_tax_id text default null,
  p_supplier_category text default null,p_address_line text default null,p_neighborhood text default null,p_municipality text default null,
  p_state_name text default null,p_phone text default null,p_is_active boolean default true,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_tax text:=public.canonical_supplier_tax_id(p_tax_id); v_before jsonb; v_after jsonb; v_candidate uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_suppliers') then raise exception 'No autorizado para administrar proveedores.'; end if;
  if nullif(trim(coalesce(p_code,'')),'') is null or nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'Código y nombre son obligatorios.'; end if;
  if nullif(trim(coalesce(p_tax_id,'')),'') is not null and v_tax is null then raise exception 'El RFC no es canónico; corrígelo o déjalo vacío.'; end if;
  select id into v_candidate from public.suppliers where company_id=p_company_id and id is distinct from p_supplier_id and (lower(code)=lower(trim(p_code)) or (v_tax is not null and tax_id=v_tax) or public.normalize_supplier_identity(display_name)=public.normalize_supplier_identity(p_display_name)) limit 1;
  if found then raise exception 'Existe un proveedor candidato con el mismo código, RFC o identidad. Revisa el catálogo antes de guardar.'; end if;
  if p_supplier_id is null then
    insert into public.suppliers(company_id,code,display_name,legal_name,tax_id,supplier_category,address_line,neighborhood,municipality,state_name,phone,is_active)
    values(p_company_id,trim(p_code),trim(p_display_name),nullif(trim(p_legal_name),''),v_tax,nullif(trim(p_supplier_category),''),nullif(trim(p_address_line),''),nullif(trim(p_neighborhood),''),nullif(trim(p_municipality),''),nullif(trim(p_state_name),''),nullif(trim(p_phone),''),coalesce(p_is_active,true)) returning id,to_jsonb(suppliers.*) into v_id,v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.created','supplier',v_id,jsonb_build_object('after',v_after));
  else
    select to_jsonb(s),s.id into v_before,v_id from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id for update;
    if not found then raise exception 'Proveedor no encontrado.'; end if;
    if p_expected_updated_at is not null and (v_before->>'updated_at')::timestamptz is distinct from p_expected_updated_at then raise exception 'El proveedor cambió desde que lo abriste. Actualiza y vuelve a intentar.'; end if;
    update public.suppliers set code=trim(p_code),display_name=trim(p_display_name),legal_name=nullif(trim(p_legal_name),''),tax_id=v_tax,supplier_category=nullif(trim(p_supplier_category),''),address_line=nullif(trim(p_address_line),''),neighborhood=nullif(trim(p_neighborhood),''),municipality=nullif(trim(p_municipality),''),state_name=nullif(trim(p_state_name),''),phone=nullif(trim(p_phone),''),is_active=coalesce(p_is_active,true),updated_by=auth.uid() where id=v_id returning to_jsonb(suppliers.*) into v_after;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier.updated','supplier',v_id,jsonb_build_object('before',v_before,'after',v_after));
  end if;
  return v_after;
end $$;

create or replace function public.promote_alpha_suppliers(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.alpha_purchasing_import_batches%rowtype; v_stage public.alpha_purchasing_import_suppliers%rowtype; v_tax text; v_candidates uuid[]; v_kinds text[]; v_supplier uuid; v_promoted int; v_linked int; v_pending int;
begin
  select * into v_batch from public.alpha_purchasing_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'promote_suppliers') then raise exception 'No autorizado para promover proveedores.'; end if;
  if v_batch.status<>'staged' or coalesce((v_batch.summary->>'error_count')::int,0)>0 then raise exception 'El lote debe estar preparado y sin errores.'; end if;
  if v_batch.supplier_promotion_completed_at is not null then return jsonb_build_object('status','already_promoted','batch_id',p_batch_id,'summary',v_batch.supplier_promotion_summary); end if;
  for v_stage in select * from public.alpha_purchasing_import_suppliers where batch_id=p_batch_id order by source_row_number,id for update loop
    select supplier_id into v_supplier from public.supplier_external_references where company_id=v_batch.company_id and source_system='alpha' and external_code=v_stage.external_code;
    if found then update public.alpha_purchasing_import_suppliers set promoted_supplier_id=v_supplier where id=v_stage.id; continue; end if;
    v_tax:=public.canonical_supplier_tax_id(v_stage.tax_id); v_candidates:='{}'; v_kinds:='{}';
    select coalesce(array_agg(distinct s.id),'{}'::uuid[]) into v_candidates from public.suppliers s where s.company_id=v_batch.company_id and (lower(s.code)=lower(v_stage.external_code) or (v_tax is not null and s.tax_id=v_tax) or public.normalize_supplier_identity(s.display_name)=public.normalize_supplier_identity(v_stage.display_name));
    if exists(select 1 from public.suppliers s where s.company_id=v_batch.company_id and lower(s.code)=lower(v_stage.external_code)) then v_kinds:=array_append(v_kinds,'code'); end if;
    if v_tax is not null and (exists(select 1 from public.suppliers s where s.company_id=v_batch.company_id and s.tax_id=v_tax) or (select count(*) from public.alpha_purchasing_import_suppliers x where x.batch_id=p_batch_id and x.id<>v_stage.id and public.canonical_supplier_tax_id(x.tax_id)=v_tax)>0) then v_kinds:=array_append(v_kinds,'tax_id'); end if;
    if exists(select 1 from public.suppliers s where s.company_id=v_batch.company_id and public.normalize_supplier_identity(s.display_name)=public.normalize_supplier_identity(v_stage.display_name)) or (select count(*) from public.alpha_purchasing_import_suppliers x where x.batch_id=p_batch_id and x.id<>v_stage.id and public.normalize_supplier_identity(x.display_name)=public.normalize_supplier_identity(v_stage.display_name))>0 then v_kinds:=array_append(v_kinds,'identity'); end if;
    if cardinality(v_kinds)>0 then
      insert into public.supplier_import_exceptions(company_id,batch_id,staged_supplier_id,conflict_kinds,candidate_supplier_ids) values(v_batch.company_id,p_batch_id,v_stage.id,v_kinds,v_candidates) on conflict(batch_id,staged_supplier_id) do nothing;
    else
      insert into public.suppliers(company_id,code,display_name,legal_name,tax_id,supplier_category,address_line,neighborhood,municipality,state_name,phone,created_by,updated_by)
      values(v_batch.company_id,'SUP-'||upper(substr(gen_random_uuid()::text,1,8)),v_stage.display_name,v_stage.display_name,v_tax,v_stage.supplier_type,v_stage.address_line,v_stage.neighborhood,v_stage.municipality,v_stage.state_name,v_stage.phone,auth.uid(),auth.uid()) returning id into v_supplier;
      insert into public.supplier_external_references(company_id,supplier_id,source_system,external_code,source_row_hash,metadata) values(v_batch.company_id,v_supplier,'alpha',v_stage.external_code,v_stage.source_row_hash,jsonb_build_object('source_tax_id',v_stage.tax_id,'counterparty_kind',v_stage.counterparty_kind));
      update public.alpha_purchasing_import_suppliers set promoted_supplier_id=v_supplier where id=v_stage.id;
    end if;
  end loop;
  select count(*) into v_promoted from public.alpha_purchasing_import_suppliers where batch_id=p_batch_id and promoted_supplier_id is not null;
  select count(*) into v_linked from public.alpha_purchasing_import_suppliers s where s.batch_id=p_batch_id and exists(select 1 from public.supplier_external_references r where r.supplier_id=s.promoted_supplier_id and r.created_at<v_batch.created_at);
  select count(*) into v_pending from public.supplier_import_exceptions where batch_id=p_batch_id and status='pending';
  update public.alpha_purchasing_import_batches set supplier_promotion_completed_at=now(),supplier_promotion_summary=jsonb_build_object('source_suppliers',(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=p_batch_id),'promoted',v_promoted,'linked_existing',v_linked,'pending_exceptions',v_pending,'purchase_orders_created',0,'payables_created',0,'payments_created',0) where id=p_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'alpha_suppliers.promoted','alpha_purchasing_import_batch',p_batch_id,(select supplier_promotion_summary from public.alpha_purchasing_import_batches where id=p_batch_id));
  return jsonb_build_object('status',case when v_pending>0 then 'completed_with_exceptions' else 'completed' end,'batch_id',p_batch_id,'summary',(select supplier_promotion_summary from public.alpha_purchasing_import_batches where id=p_batch_id));
end $$;

create or replace function public.list_supplier_import_exceptions(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_total int;v_items jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'promote_suppliers') then raise exception 'No autorizado para revisar excepciones.'; end if;
 select count(*) into v_total from public.supplier_import_exceptions where company_id=p_company_id and status='pending';
 select coalesce(jsonb_agg(to_jsonb(x) order by x.detected_at,x.id),'[]'::jsonb) into v_items from(select e.id,e.batch_id,e.conflict_kinds,e.candidate_supplier_ids,e.detected_at,s.external_code,s.display_name,s.tax_id,s.source_row_number,coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'display_name',c.display_name,'tax_id',c.tax_id) order by c.display_name) from public.suppliers c where c.id=any(e.candidate_supplier_ids)),'[]'::jsonb) candidates from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id where e.company_id=p_company_id and e.status='pending' order by e.detected_at,e.id limit v_size offset(v_page-1)*v_size)x;
 return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.resolve_supplier_import_exception(p_exception_id uuid,p_decision text,p_target_supplier_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_e public.supplier_import_exceptions%rowtype;v_s public.alpha_purchasing_import_suppliers%rowtype;v_supplier uuid;v_tax text;v_summary jsonb;
begin
 select * into v_e from public.supplier_import_exceptions where id=p_exception_id for update;
 if not found or auth.uid() is null or not public.has_company_permission(v_e.company_id,'promote_suppliers') then raise exception 'No autorizado para resolver la excepción.'; end if;
 if v_e.status='resolved' then return jsonb_build_object('status','already_resolved','supplier_id',v_e.resolved_supplier_id); end if;
 if p_decision not in('link_existing','create_separate') or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Decisión y motivo son obligatorios.'; end if;
 select * into v_s from public.alpha_purchasing_import_suppliers where id=v_e.staged_supplier_id for update;
 if p_decision='link_existing' then
   select id into v_supplier from public.suppliers where id=p_target_supplier_id and company_id=v_e.company_id;
   if not found or not(v_supplier=any(v_e.candidate_supplier_ids)) then raise exception 'Selecciona un candidato verificable de la misma empresa.'; end if;
 else
   v_tax:=public.canonical_supplier_tax_id(v_s.tax_id);
   if v_tax is not null and exists(select 1 from public.suppliers where company_id=v_e.company_id and tax_id=v_tax) then v_tax:=null; end if;
   insert into public.suppliers(company_id,code,display_name,legal_name,tax_id,supplier_category,address_line,neighborhood,municipality,state_name,phone) values(v_e.company_id,'SUP-'||upper(substr(gen_random_uuid()::text,1,8)),v_s.display_name,v_s.display_name,v_tax,v_s.supplier_type,v_s.address_line,v_s.neighborhood,v_s.municipality,v_s.state_name,v_s.phone) returning id into v_supplier;
 end if;
 insert into public.supplier_external_references(company_id,supplier_id,source_system,external_code,source_row_hash,metadata) values(v_e.company_id,v_supplier,'alpha',v_s.external_code,v_s.source_row_hash,jsonb_build_object('resolution',p_decision,'reason',trim(p_reason)));
 update public.alpha_purchasing_import_suppliers set promoted_supplier_id=v_supplier where id=v_s.id;
 update public.supplier_import_exceptions set status='resolved',decision=p_decision,resolved_supplier_id=v_supplier,resolution_reason=trim(p_reason),resolved_at=now(),resolved_by=auth.uid() where id=p_exception_id;
 v_summary:=jsonb_build_object('source_suppliers',(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_e.batch_id),'promoted',(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_e.batch_id and promoted_supplier_id is not null),'pending_exceptions',(select count(*) from public.supplier_import_exceptions where batch_id=v_e.batch_id and status='pending'),'purchase_orders_created',0,'payables_created',0,'payments_created',0);
 update public.alpha_purchasing_import_batches set supplier_promotion_summary=v_summary where id=v_e.batch_id;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_e.company_id,auth.uid(),'alpha_suppliers.exception_resolved','supplier_import_exception',p_exception_id,jsonb_build_object('decision',p_decision,'supplier_id',v_supplier,'reason',trim(p_reason),'batch_id',v_e.batch_id));
 return jsonb_build_object('status','resolved','supplier_id',v_supplier,'summary',v_summary);
end $$;

create or replace function public.list_alpha_purchasing_import_batches(p_company_id uuid,p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,20),1),100);v_total integer;v_items jsonb;
begin
 if auth.uid() is null or not(public.has_company_permission(p_company_id,'import_data') or public.has_company_permission(p_company_id,'view_import_audit') or public.has_company_permission(p_company_id,'promote_suppliers')) then raise exception 'No autorizado.'; end if;
 select count(*) into v_total from public.alpha_purchasing_import_batches where company_id=p_company_id;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_items from(select b.id,b.cutoff_date,b.status,b.records_received,b.summary,b.supplier_promotion_completed_at,b.supplier_promotion_summary,b.completed_at,b.created_at,(select count(*) from public.alpha_purchasing_import_differences d where d.batch_id=b.id) differences,(select coalesce(jsonb_agg(jsonb_build_object('report_type',f.report_type,'original_name',f.original_name,'row_count',f.row_count) order by f.report_type),'[]'::jsonb) from public.alpha_purchasing_import_files f where f.batch_id=b.id) files from public.alpha_purchasing_import_batches b where b.company_id=p_company_id order by b.created_at desc limit v_size offset(v_page-1)*v_size)x;
 return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

revoke all on function public.normalize_supplier_identity(text),public.canonical_supplier_tax_id(text),public.search_suppliers(uuid,text,integer,integer,boolean,text),public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz),public.promote_alpha_suppliers(uuid),public.list_supplier_import_exceptions(uuid,integer,integer),public.resolve_supplier_import_exception(uuid,text,uuid,text) from public;
grant execute on function public.search_suppliers(uuid,text,integer,integer,boolean,text),public.save_supplier(uuid,uuid,text,text,text,text,text,text,text,text,text,text,boolean,timestamptz),public.promote_alpha_suppliers(uuid),public.list_supplier_import_exceptions(uuid,integer,integer),public.resolve_supplier_import_exception(uuid,text,uuid,text) to authenticated;
revoke all on function public.list_alpha_purchasing_import_batches(uuid,integer,integer) from public;
grant execute on function public.list_alpha_purchasing_import_batches(uuid,integer,integer) to authenticated;
