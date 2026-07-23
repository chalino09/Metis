-- Satrapy · Módulo 3B: órdenes de compra, aprobación y promoción histórica.
-- Una OC aprobada no crea recepciones, movimientos de inventario, costos ni CxP.

insert into public.permissions(code,description) values
  ('view_purchase_orders','Consultar órdenes de compra.'),
  ('create_purchase_orders','Crear órdenes de compra en borrador.'),
  ('edit_purchase_orders','Editar órdenes de compra no enviadas.'),
  ('submit_purchase_orders','Enviar órdenes de compra a aprobación.'),
  ('approve_purchase_orders','Aprobar órdenes de compra enviadas.'),
  ('reject_purchase_orders','Rechazar órdenes de compra enviadas.'),
  ('cancel_purchase_orders','Cancelar órdenes de compra con motivo auditado.'),
  ('promote_purchase_orders','Promover órdenes históricas preparadas desde staging.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_purchase_orders','create_purchase_orders','edit_purchase_orders','submit_purchase_orders',
  'approve_purchase_orders','reject_purchase_orders','cancel_purchase_orders','promote_purchase_orders'
) on conflict do nothing;

create table public.purchase_order_folio_counters(
  company_id uuid primary key references public.companies(id) on delete cascade,
  next_value bigint not null default 1 check(next_value>0),
  updated_at timestamptz not null default now()
);

create table public.purchase_orders(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  folio text not null check(length(trim(folio))>0),
  status text not null default 'draft' check(status in ('draft','pending_approval','approved','rejected','cancelled')),
  origin text not null default 'operational' check(origin in ('operational','imported_historical')),
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  ordered_date date not null default current_date,
  expected_date date,
  supplier_reference text,
  requisition_reference text,
  notes text,
  order_discount_percent numeric(9,4) not null default 0 check(order_discount_percent between 0 and 100),
  subtotal numeric(18,6) not null default 0 check(subtotal>=0),
  line_discount_total numeric(18,6) not null default 0 check(line_discount_total>=0),
  order_discount_total numeric(18,6) not null default 0 check(order_discount_total>=0),
  total numeric(18,6) not null default 0 check(total>=0),
  submitted_at timestamptz,
  submitted_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  cancellation_reason text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,folio),
  check(expected_date is null or expected_date>=ordered_date),
  check((status='cancelled')=(cancelled_at is not null and cancellation_reason is not null))
);
create index purchase_orders_catalog_idx on public.purchase_orders(company_id,status,ordered_date desc,id desc);
create index purchase_orders_supplier_idx on public.purchase_orders(company_id,supplier_id,ordered_date desc,id desc);
create trigger purchase_orders_updated_at before update on public.purchase_orders for each row execute function public.set_updated_at();

create table public.purchase_order_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  line_number integer not null check(line_number>0),
  product_id uuid references public.products(id) on delete restrict,
  description text not null check(length(trim(description))>0),
  unit text,
  quantity numeric(18,6) not null check(quantity>0),
  unit_cost numeric(18,6) not null check(unit_cost>=0),
  discount_percent_1 numeric(9,4) not null default 0 check(discount_percent_1 between 0 and 100),
  discount_percent_2 numeric(9,4) not null default 0 check(discount_percent_2 between 0 and 100),
  expected_date date,
  requisition_reference text,
  line_subtotal numeric(18,6) generated always as (round(quantity*unit_cost,6)) stored,
  line_discount numeric(18,6) generated always as (round(quantity*unit_cost-(quantity*unit_cost*(1-discount_percent_1/100)*(1-discount_percent_2/100)),6)) stored,
  line_total numeric(18,6) generated always as (round(quantity*unit_cost*(1-discount_percent_1/100)*(1-discount_percent_2/100),6)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(purchase_order_id,line_number)
);
create index purchase_order_lines_order_idx on public.purchase_order_lines(purchase_order_id,line_number);
create trigger purchase_order_lines_updated_at before update on public.purchase_order_lines for each row execute function public.set_updated_at();

create table public.purchase_order_decisions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  decision text not null check(decision in ('submitted','approved','rejected','cancelled','imported_approved')),
  reason text,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  decided_at timestamptz not null default now()
);
create index purchase_order_decisions_order_idx on public.purchase_order_decisions(purchase_order_id,decided_at,id);

create table public.purchase_order_external_references(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  source_system text not null check(length(trim(source_system))>0),
  external_key text not null check(length(trim(external_key))>0),
  source_row_hash text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(company_id,source_system,external_key),
  unique(company_id,source_system,source_row_hash)
);

create table public.purchase_order_import_exceptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  staged_order_id uuid not null references public.alpha_purchasing_import_orders(id) on delete cascade,
  exception_kinds text[] not null check(cardinality(exception_kinds)>0),
  evidence jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check(status in ('pending','resolved')),
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  resolution_reason text,
  unique(batch_id,staged_order_id)
);
create index purchase_order_import_exceptions_inbox_idx on public.purchase_order_import_exceptions(company_id,status,detected_at,id);

alter table public.alpha_purchasing_import_orders add column promoted_purchase_order_id uuid references public.purchase_orders(id) on delete restrict;
alter table public.alpha_purchasing_import_orders add column order_promotion_status text not null default 'pending' check(order_promotion_status in ('pending','promoted','exception'));
alter table public.alpha_purchasing_import_batches add column order_promotion_completed_at timestamptz;
alter table public.alpha_purchasing_import_batches add column order_promotion_summary jsonb not null default '{}'::jsonb;

create or replace function public.next_purchase_order_folio(p_company_id uuid,p_historical boolean default false)
returns text language plpgsql security definer set search_path=public as $$
declare v_value bigint;
begin
  insert into public.purchase_order_folio_counters(company_id,next_value) values(p_company_id,2)
  on conflict(company_id) do update set next_value=public.purchase_order_folio_counters.next_value+1,updated_at=now()
  returning next_value-1 into v_value;
  return (case when p_historical then 'OCH-' else 'OC-' end)||to_char(current_date,'YYYY')||'-'||lpad(v_value::text,6,'0');
end $$;

create or replace function public.assert_purchase_order_company()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.suppliers s where s.id=new.supplier_id and s.company_id=new.company_id) then raise exception 'El proveedor no pertenece a la empresa.'; end if;
  return new;
end $$;
create trigger purchase_orders_company_guard before insert or update of company_id,supplier_id on public.purchase_orders for each row execute function public.assert_purchase_order_company();

create or replace function public.protect_locked_purchase_order()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status in ('pending_approval','approved','cancelled') and (
    new.company_id is distinct from old.company_id or new.supplier_id is distinct from old.supplier_id or
    new.folio is distinct from old.folio or new.origin is distinct from old.origin or new.currency_code is distinct from old.currency_code or
    new.ordered_date is distinct from old.ordered_date or new.expected_date is distinct from old.expected_date or
    new.supplier_reference is distinct from old.supplier_reference or new.requisition_reference is distinct from old.requisition_reference or
    new.notes is distinct from old.notes or new.order_discount_percent is distinct from old.order_discount_percent or
    new.subtotal is distinct from old.subtotal or new.line_discount_total is distinct from old.line_discount_total or
    new.order_discount_total is distinct from old.order_discount_total or new.total is distinct from old.total
  ) then raise exception 'La OC enviada o cerrada es inmutable; cancélala mediante el procedimiento explícito.'; end if;
  if old.status='approved' and new.status not in ('approved','cancelled') then raise exception 'Una OC aprobada sólo puede cancelarse.'; end if;
  if old.status='cancelled' and new.status<>'cancelled' then raise exception 'Una OC cancelada no puede reabrirse.'; end if;
  return new;
end $$;
create trigger purchase_orders_lock_guard before update on public.purchase_orders for each row execute function public.protect_locked_purchase_order();

create or replace function public.assert_purchase_order_line_mutable()
returns trigger language plpgsql set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_company uuid;v_product uuid;
begin
  select * into v_order from public.purchase_orders where id=coalesce(new.purchase_order_id,old.purchase_order_id);
  if not found or v_order.status not in ('draft','rejected') then raise exception 'Las partidas sólo pueden modificarse en borrador o después de un rechazo.'; end if;
  if tg_op<>'DELETE' then
    if new.company_id<>v_order.company_id then raise exception 'La partida no pertenece a la empresa de la OC.'; end if;
    if new.expected_date is not null and new.expected_date<v_order.ordered_date then raise exception 'La fecha esperada de una partida no puede ser anterior a la OC.'; end if;
    if new.product_id is not null then select company_id into v_company from public.products where id=new.product_id; if v_company is distinct from v_order.company_id then raise exception 'El producto no pertenece a la empresa.'; end if; end if;
  end if;
  return coalesce(new,old);
end $$;
create trigger purchase_order_lines_mutability_guard before insert or update or delete on public.purchase_order_lines for each row execute function public.assert_purchase_order_line_mutable();

create or replace function public.recalculate_purchase_order(p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_subtotal numeric(18,6);v_line_discount numeric(18,6);v_after_lines numeric(18,6);v_percent numeric(9,4);
begin
  select coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0),coalesce(sum(line_total),0)
  into v_subtotal,v_line_discount,v_after_lines from public.purchase_order_lines where purchase_order_id=p_order_id;
  select order_discount_percent into v_percent from public.purchase_orders where id=p_order_id for update;
  update public.purchase_orders set subtotal=v_subtotal,line_discount_total=v_line_discount,
    order_discount_total=round(v_after_lines*v_percent/100,6),total=round(v_after_lines*(1-v_percent/100),6),updated_by=auth.uid()
  where id=p_order_id;
end $$;

alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.purchase_order_decisions enable row level security;
alter table public.purchase_order_external_references enable row level security;
alter table public.purchase_order_import_exceptions enable row level security;
alter table public.purchase_order_folio_counters enable row level security;
create policy purchase_orders_read on public.purchase_orders for select to authenticated using(public.has_company_permission(company_id,'view_purchase_orders'));
create policy purchase_order_lines_read on public.purchase_order_lines for select to authenticated using(public.has_company_permission(company_id,'view_purchase_orders'));
create policy purchase_order_decisions_read on public.purchase_order_decisions for select to authenticated using(public.has_company_permission(company_id,'view_purchase_orders'));
create policy purchase_order_refs_read on public.purchase_order_external_references for select to authenticated using(public.has_company_permission(company_id,'view_purchase_orders'));
create policy purchase_order_exceptions_read on public.purchase_order_import_exceptions for select to authenticated using(public.has_company_permission(company_id,'promote_purchase_orders') or public.has_company_permission(company_id,'view_import_audit'));
revoke all on public.purchase_orders,public.purchase_order_lines,public.purchase_order_decisions,public.purchase_order_external_references,public.purchase_order_import_exceptions,public.purchase_order_folio_counters from authenticated;

create or replace function public.save_purchase_order(
  p_company_id uuid,p_purchase_order_id uuid,p_supplier_id uuid,p_currency_code text,p_ordered_date date,
  p_expected_date date default null,p_supplier_reference text default null,p_requisition_reference text default null,
  p_notes text default null,p_order_discount_percent numeric default 0,p_lines jsonb default '[]'::jsonb,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_before jsonb;v_after jsonb;v_line jsonb;v_line_no int:=0;v_status text;v_currency text:=upper(trim(coalesce(p_currency_code,'')));
begin
  if auth.uid() is null then raise exception 'No autorizado.'; end if;
  if p_purchase_order_id is null and not public.has_company_permission(p_company_id,'create_purchase_orders') then raise exception 'No autorizado para crear órdenes de compra.'; end if;
  if p_purchase_order_id is not null and not public.has_company_permission(p_company_id,'edit_purchase_orders') then raise exception 'No autorizado para editar órdenes de compra.'; end if;
  if v_currency!~'^[A-Z]{3}$' then raise exception 'La moneda debe usar un código ISO de tres letras.'; end if;
  if p_ordered_date is null or (p_expected_date is not null and p_expected_date<p_ordered_date) then raise exception 'Las fechas de la OC no son válidas.'; end if;
  if coalesce(p_order_discount_percent,0) not between 0 and 100 then raise exception 'El descuento general debe estar entre 0 y 100.'; end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La OC requiere al menos una partida.'; end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id and company_id=p_company_id and is_active) then raise exception 'Selecciona un proveedor activo de la empresa.'; end if;
  if p_purchase_order_id is null then
    insert into public.purchase_orders(company_id,supplier_id,folio,currency_code,ordered_date,expected_date,supplier_reference,requisition_reference,notes,order_discount_percent)
    values(p_company_id,p_supplier_id,public.next_purchase_order_folio(p_company_id,false),v_currency,p_ordered_date,p_expected_date,nullif(trim(p_supplier_reference),''),nullif(trim(p_requisition_reference),''),nullif(trim(p_notes),''),coalesce(p_order_discount_percent,0))
    returning id into v_id;
  else
    select to_jsonb(po),po.status into v_before,v_status from public.purchase_orders po where po.id=p_purchase_order_id and po.company_id=p_company_id for update;
    if not found then raise exception 'OC no encontrada.'; end if;
    if v_status not in ('draft','rejected') then raise exception 'La OC ya fue enviada y no admite edición.'; end if;
    if p_expected_updated_at is not null and (v_before->>'updated_at')::timestamptz is distinct from p_expected_updated_at then raise exception 'La OC cambió desde que la abriste.'; end if;
    v_id:=p_purchase_order_id;
    update public.purchase_orders set supplier_id=p_supplier_id,currency_code=v_currency,ordered_date=p_ordered_date,expected_date=p_expected_date,
      supplier_reference=nullif(trim(p_supplier_reference),''),requisition_reference=nullif(trim(p_requisition_reference),''),notes=nullif(trim(p_notes),''),
      order_discount_percent=coalesce(p_order_discount_percent,0),status='draft',updated_by=auth.uid() where id=v_id;
    delete from public.purchase_order_lines where purchase_order_id=v_id;
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_no:=v_line_no+1;
    insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,product_id,description,unit,quantity,unit_cost,discount_percent_1,discount_percent_2,expected_date,requisition_reference)
    values(p_company_id,v_id,v_line_no,nullif(v_line->>'product_id','')::uuid,trim(coalesce(v_line->>'description','')),nullif(trim(v_line->>'unit'),''),
      (v_line->>'quantity')::numeric,(v_line->>'unit_cost')::numeric,coalesce((v_line->>'discount_percent_1')::numeric,0),coalesce((v_line->>'discount_percent_2')::numeric,0),
      nullif(v_line->>'expected_date','')::date,nullif(trim(v_line->>'requisition_reference'),''));
  end loop;
  perform public.recalculate_purchase_order(v_id);
  select to_jsonb(po) into v_after from public.purchase_orders po where id=v_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),case when p_purchase_order_id is null then 'purchase_order.created' else 'purchase_order.updated' end,'purchase_order',v_id,jsonb_build_object('before',v_before,'after',v_after,'line_count',v_line_no));
  return v_after;
exception when invalid_text_representation or numeric_value_out_of_range or not_null_violation or check_violation then
  raise exception 'Una o más partidas contienen datos inválidos.';
end $$;

create or replace function public.submit_purchase_order(p_company_id uuid,p_purchase_order_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'submit_purchase_orders') then raise exception 'No autorizado para enviar OC.'; end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.status<>'draft' then raise exception 'Sólo una OC en borrador puede enviarse.'; end if;
  if not exists(select 1 from public.purchase_order_lines where purchase_order_id=p_purchase_order_id) then raise exception 'La OC no tiene partidas.'; end if;
  update public.purchase_orders set status='pending_approval',submitted_at=now(),submitted_by=auth.uid(),updated_by=auth.uid() where id=p_purchase_order_id;
  insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(p_company_id,p_purchase_order_id,'submitted',nullif(trim(p_reason),''));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_order.submitted','purchase_order',p_purchase_order_id,jsonb_build_object('reason',nullif(trim(p_reason),'')));
  return (select to_jsonb(po) from public.purchase_orders po where id=p_purchase_order_id);
end $$;

create or replace function public.decide_purchase_order(p_company_id uuid,p_purchase_order_id uuid,p_decision text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_action text:=lower(trim(coalesce(p_decision,'')));
begin
  if auth.uid() is null then raise exception 'No autorizado.'; end if;
  if v_action='approved' and not public.has_company_permission(p_company_id,'approve_purchase_orders') then raise exception 'No autorizado para aprobar OC.'; end if;
  if v_action='rejected' and not public.has_company_permission(p_company_id,'reject_purchase_orders') then raise exception 'No autorizado para rechazar OC.'; end if;
  if v_action not in ('approved','rejected') then raise exception 'Decisión no válida.'; end if;
  if v_action='rejected' and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo de rechazo es obligatorio.'; end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.status<>'pending_approval' then raise exception 'La OC no está pendiente de aprobación.'; end if;
  update public.purchase_orders set status=v_action,decided_at=now(),decided_by=auth.uid(),updated_by=auth.uid() where id=p_purchase_order_id;
  insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(p_company_id,p_purchase_order_id,v_action,nullif(trim(p_reason),''));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_order.'||v_action,'purchase_order',p_purchase_order_id,jsonb_build_object('decision',v_action,'reason',nullif(trim(p_reason),'')));
  return (select to_jsonb(po) from public.purchase_orders po where id=p_purchase_order_id);
end $$;

create or replace function public.cancel_purchase_order(p_company_id uuid,p_purchase_order_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'cancel_purchase_orders') then raise exception 'No autorizado para cancelar OC.'; end if;
  if v_reason is null then raise exception 'El motivo de cancelación es obligatorio.'; end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.status='cancelled' then raise exception 'La OC no está disponible para cancelación.'; end if;
  update public.purchase_orders set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=v_reason,updated_by=auth.uid() where id=p_purchase_order_id;
  insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(p_company_id,p_purchase_order_id,'cancelled',v_reason);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_order.cancelled','purchase_order',p_purchase_order_id,jsonb_build_object('previous_status',v_order.status,'reason',v_reason));
  return (select to_jsonb(po) from public.purchase_orders po where id=p_purchase_order_id);
end $$;

create or replace function public.search_purchase_orders(
  p_company_id uuid,p_query text default null,p_status text default null,p_supplier_id uuid default null,p_origin text default null,
  p_date_from date default null,p_date_to date default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_orders') then raise exception 'No autorizado para consultar OC.'; end if;
  with filtered as materialized(
    select po.*,s.code supplier_code,s.display_name supplier_name from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id
    where po.company_id=p_company_id and (p_status is null or po.status=p_status) and (p_supplier_id is null or po.supplier_id=p_supplier_id)
      and (p_origin is null or po.origin=p_origin) and (p_date_from is null or po.ordered_date>=p_date_from) and (p_date_to is null or po.ordered_date<=p_date_to)
      and (v_q='' or lower(po.folio) like '%'||v_q||'%' or lower(s.code) like '%'||v_q||'%' or lower(s.display_name) like '%'||v_q||'%' or lower(coalesce(po.supplier_reference,'')) like '%'||v_q||'%' or lower(coalesce(po.requisition_reference,'')) like '%'||v_q||'%')
  ),paged as(select * from filtered order by ordered_date desc,id desc limit v_size offset (v_page-1)*v_size)
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by ordered_date desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.get_purchase_order_detail(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_orders') then raise exception 'No autorizado para consultar OC.'; end if;
  select to_jsonb(po)||jsonb_build_object('supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name,'tax_id',s.tax_id),
    'lines',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name) order by l.line_number) from public.purchase_order_lines l left join public.products p on p.id=l.product_id where l.purchase_order_id=po.id),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(to_jsonb(d)||jsonb_build_object('actor_name',pr.full_name) order by d.decided_at,d.id) from public.purchase_order_decisions d left join public.profiles pr on pr.id=d.actor_id where d.purchase_order_id=po.id),'[]'::jsonb))
  into v_result from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id where po.id=p_purchase_order_id and po.company_id=p_company_id;
  if v_result is null then raise exception 'OC no encontrada.'; end if;return v_result;
end $$;

create or replace function public.promote_alpha_purchase_orders(p_batch_id uuid,p_page_size integer default 25)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.alpha_purchasing_import_batches%rowtype;v_stage public.alpha_purchasing_import_orders%rowtype;v_supplier uuid;v_order uuid;v_folio text;v_kinds text[];v_lines jsonb;v_line_count int;v_promoted_page int:=0;v_exception_page int:=0;v_remaining int;v_summary jsonb;
begin
  select * into v_batch from public.alpha_purchasing_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'promote_purchase_orders') then raise exception 'No autorizado para promover OC.'; end if;
  if v_batch.status<>'staged' or coalesce((v_batch.summary->>'error_count')::int,0)>0 then raise exception 'El lote debe estar preparado y sin errores.'; end if;
  if v_batch.order_promotion_completed_at is not null then return jsonb_build_object('status','already_promoted','batch_id',p_batch_id,'summary',v_batch.order_promotion_summary); end if;
  for v_stage in select * from public.alpha_purchasing_import_orders where batch_id=p_batch_id and order_promotion_status='pending' order by source_row_number,id limit least(greatest(coalesce(p_page_size,25),1),100) for update skip locked loop
    v_kinds:='{}';v_supplier:=null;v_line_count:=0;
    select aps.promoted_supplier_id into v_supplier from public.alpha_purchasing_import_suppliers aps where aps.batch_id=p_batch_id and aps.external_code=v_stage.supplier_external_code;
    if v_supplier is null then v_kinds:=array_append(v_kinds,'supplier_unresolved'); end if;
    if v_stage.currency_code is null or v_stage.currency_code!~'^[A-Z]{3}$' then v_kinds:=array_append(v_kinds,'currency_unresolved'); end if;
    select count(*),coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'description',l.description,'unit',l.unit,'quantity',l.quantity,'unit_cost',l.unit_cost_mxn,
      'discount_percent_1',coalesce(l.discount_1,0),'discount_percent_2',coalesce(l.discount_2,0),'expected_date',l.expected_date,'requisition_reference',l.requisition_reference) order by l.line_number),'[]'::jsonb)
    into v_line_count,v_lines from public.alpha_purchasing_import_order_lines l left join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=l.alpha_sku where l.batch_id=p_batch_id and l.source_order_key=v_stage.source_order_key;
    if v_line_count=0 then v_kinds:=array_append(v_kinds,'missing_lines'); end if;
    if exists(select 1 from public.alpha_purchasing_import_order_lines l left join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=l.alpha_sku where l.batch_id=p_batch_id and l.source_order_key=v_stage.source_order_key and p.id is null) then v_kinds:=array_append(v_kinds,'product_unresolved'); end if;
    if exists(select 1 from public.alpha_purchasing_import_order_lines l where l.batch_id=p_batch_id and l.source_order_key=v_stage.source_order_key and (l.quantity<=0 or l.unit_cost_mxn<0 or nullif(trim(l.description),'') is null)) then v_kinds:=array_append(v_kinds,'invalid_line'); end if;
    select purchase_order_id into v_order from public.purchase_order_external_references where company_id=v_batch.company_id and source_system='alpha' and external_key=v_stage.source_order_key;
    if found then
      update public.alpha_purchasing_import_orders set promoted_purchase_order_id=v_order,order_promotion_status='promoted' where id=v_stage.id;continue;
    end if;
    if cardinality(v_kinds)>0 then
      insert into public.purchase_order_import_exceptions(company_id,batch_id,staged_order_id,exception_kinds,evidence)
      values(v_batch.company_id,p_batch_id,v_stage.id,v_kinds,jsonb_build_object('source_order_key',v_stage.source_order_key,'order_number',v_stage.order_number,'supplier_external_code',v_stage.supplier_external_code,'currency',v_stage.source_currency,'line_count',v_line_count))
      on conflict(batch_id,staged_order_id) do update set exception_kinds=excluded.exception_kinds,evidence=excluded.evidence,detected_at=now();
      update public.alpha_purchasing_import_orders set order_promotion_status='exception' where id=v_stage.id;v_exception_page:=v_exception_page+1;continue;
    end if;
    v_folio:=public.next_purchase_order_folio(v_batch.company_id,true);
    insert into public.purchase_orders(company_id,supplier_id,folio,status,origin,currency_code,ordered_date,expected_date,supplier_reference,requisition_reference,notes,order_discount_percent,submitted_at,submitted_by,decided_at,decided_by)
    select v_batch.company_id,v_supplier,v_folio,'draft','imported_historical',v_stage.currency_code,v_stage.ordered_date,min((x->>'expected_date')::date),v_stage.order_number,
      min(nullif(x->>'requisition_reference','')),'OC histórica promovida desde staging consolidado.',coalesce(v_stage.discount_percent,0),now(),auth.uid(),now(),auth.uid() from jsonb_array_elements(v_lines) x returning id into v_order;
    insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,product_id,description,unit,quantity,unit_cost,discount_percent_1,discount_percent_2,expected_date,requisition_reference)
    select v_batch.company_id,v_order,row_number() over(),(x->>'product_id')::uuid,x->>'description',nullif(x->>'unit',''),(x->>'quantity')::numeric,(x->>'unit_cost')::numeric,(x->>'discount_percent_1')::numeric,(x->>'discount_percent_2')::numeric,nullif(x->>'expected_date','')::date,nullif(x->>'requisition_reference','') from jsonb_array_elements(v_lines) x;
    perform public.recalculate_purchase_order(v_order);
    update public.purchase_orders set status='approved' where id=v_order;
    insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(v_batch.company_id,v_order,'imported_approved','La fuente histórica reporta la OC como Aceptada.');
    insert into public.purchase_order_external_references(company_id,purchase_order_id,source_system,external_key,source_row_hash,metadata)
    values(v_batch.company_id,v_order,'alpha',v_stage.source_order_key,v_stage.source_row_hash,jsonb_build_object('order_number',v_stage.order_number,'branch_code',v_stage.branch_code,'source_status',v_stage.source_status,'source_approval_status',v_stage.source_approval_status,'batch_id',p_batch_id));
    update public.alpha_purchasing_import_orders set promoted_purchase_order_id=v_order,order_promotion_status='promoted' where id=v_stage.id;v_promoted_page:=v_promoted_page+1;
  end loop;
  select count(*) into v_remaining from public.alpha_purchasing_import_orders where batch_id=p_batch_id and order_promotion_status='pending';
  select jsonb_build_object('source_orders',count(*),'source_lines',(select count(*) from public.alpha_purchasing_import_order_lines where batch_id=p_batch_id),
    'promoted_orders',count(*) filter(where order_promotion_status='promoted'),'promoted_lines',(select count(*) from public.purchase_order_lines l join public.purchase_orders po on po.id=l.purchase_order_id join public.purchase_order_external_references er on er.purchase_order_id=po.id where er.company_id=v_batch.company_id and er.source_system='alpha' and (er.metadata->>'batch_id')::uuid=p_batch_id),
    'exceptions',count(*) filter(where order_promotion_status='exception'),'remaining',count(*) filter(where order_promotion_status='pending')) into v_summary from public.alpha_purchasing_import_orders where batch_id=p_batch_id;
  if v_remaining=0 then
    update public.alpha_purchasing_import_batches set order_promotion_completed_at=now(),order_promotion_summary=v_summary where id=p_batch_id;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'alpha_purchase_orders.promoted','alpha_purchasing_import_batch',p_batch_id,v_summary);
  end if;
  return jsonb_build_object('status',case when v_remaining=0 then case when (v_summary->>'exceptions')::int>0 then 'completed_with_exceptions' else 'completed' end else 'in_progress' end,'batch_id',p_batch_id,'page',jsonb_build_object('promoted',v_promoted_page,'exceptions',v_exception_page),'summary',v_summary);
end $$;

create or replace function public.list_purchase_order_import_exceptions(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'promote_purchase_orders') or public.has_company_permission(p_company_id,'view_import_audit')) then raise exception 'No autorizado.'; end if;
  select count(*) into v_total from public.purchase_order_import_exceptions where company_id=p_company_id and status='pending';
  select coalesce(jsonb_agg(to_jsonb(x) order by x.detected_at,x.id),'[]'::jsonb) into v_items from (select e.*,o.order_number,o.supplier_name,o.source_row_number from public.purchase_order_import_exceptions e join public.alpha_purchasing_import_orders o on o.id=e.staged_order_id where e.company_id=p_company_id and e.status='pending' order by e.detected_at,e.id limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.list_purchase_order_promotion_batches(p_company_id uuid,p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,20),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'promote_purchase_orders') or public.has_company_permission(p_company_id,'view_import_audit')) then raise exception 'No autorizado.';end if;
  select count(*) into v_total from public.alpha_purchasing_import_batches where company_id=p_company_id;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_items from (
    select b.id,b.cutoff_date,b.status,b.created_at,b.order_promotion_completed_at,b.order_promotion_summary,
      (select count(*) from public.alpha_purchasing_import_orders o where o.batch_id=b.id) source_orders,
      (select count(*) from public.alpha_purchasing_import_order_lines l where l.batch_id=b.id) source_lines,
      (select count(*) from public.alpha_purchasing_import_orders o where o.batch_id=b.id and o.order_promotion_status='promoted') promoted_orders,
      (select count(*) from public.alpha_purchasing_import_orders o where o.batch_id=b.id and o.order_promotion_status='exception') exceptions
    from public.alpha_purchasing_import_batches b where b.company_id=p_company_id order by b.created_at desc limit v_size offset (v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

revoke all on function public.next_purchase_order_folio(uuid,boolean) from public;
revoke all on function public.recalculate_purchase_order(uuid) from public;
revoke all on function public.save_purchase_order(uuid,uuid,uuid,text,date,date,text,text,text,numeric,jsonb,timestamptz) from public;
revoke all on function public.submit_purchase_order(uuid,uuid,text) from public;
revoke all on function public.decide_purchase_order(uuid,uuid,text,text) from public;
revoke all on function public.cancel_purchase_order(uuid,uuid,text) from public;
revoke all on function public.search_purchase_orders(uuid,text,text,uuid,text,date,date,integer,integer) from public;
revoke all on function public.get_purchase_order_detail(uuid,uuid) from public;
revoke all on function public.promote_alpha_purchase_orders(uuid,integer) from public;
revoke all on function public.list_purchase_order_import_exceptions(uuid,integer,integer) from public;
revoke all on function public.list_purchase_order_promotion_batches(uuid,integer,integer) from public;
grant execute on function public.save_purchase_order(uuid,uuid,uuid,text,date,date,text,text,text,numeric,jsonb,timestamptz) to authenticated;
grant execute on function public.submit_purchase_order(uuid,uuid,text) to authenticated;
grant execute on function public.decide_purchase_order(uuid,uuid,text,text) to authenticated;
grant execute on function public.cancel_purchase_order(uuid,uuid,text) to authenticated;
grant execute on function public.search_purchase_orders(uuid,text,text,uuid,text,date,date,integer,integer) to authenticated;
grant execute on function public.get_purchase_order_detail(uuid,uuid) to authenticated;
grant execute on function public.promote_alpha_purchase_orders(uuid,integer) to authenticated;
grant execute on function public.list_purchase_order_import_exceptions(uuid,integer,integer) to authenticated;
grant execute on function public.list_purchase_order_promotion_batches(uuid,integer,integer) to authenticated;
