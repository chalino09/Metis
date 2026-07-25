-- Satrapy · Abastecimiento: necesidad → cotización → adjudicación → OC.
-- La necesidad es la fuente de verdad; la adjudicación genera OCs por proveedor.

insert into public.permissions(code,description) values
  ('view_procurement','Consultar necesidades, cotizaciones y adjudicaciones.'),
  ('create_procurement_requisitions','Crear necesidades de compra y excepciones justificadas.'),
  ('manage_procurement_quotes','Registrar cotizaciones de proveedores.'),
  ('recommend_procurement_awards','Preparar recomendaciones de adjudicación.'),
  ('approve_procurement_awards','Aprobar adjudicaciones y emitir OCs.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_procurement','create_procurement_requisitions','manage_procurement_quotes',
  'recommend_procurement_awards','approve_procurement_awards'
) on conflict do nothing;

create table public.procurement_requisitions(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  folio text not null, location_id uuid not null references public.locations(id) on delete restrict,
  status text not null default 'draft' check(status in ('draft','quoting','recommended','approved','cancelled')),
  source text not null check(source in ('replenishment','manual_exception')),
  target_date date, exception_reason text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(company_id,folio), check((source='manual_exception') = (nullif(trim(coalesce(exception_reason,'')),'') is not null))
);
create table public.procurement_requisition_lines(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  requisition_id uuid not null references public.procurement_requisitions(id) on delete cascade,
  line_number integer not null check(line_number>0), product_id uuid not null references public.products(id) on delete restrict,
  description text not null, unit text, required_quantity numeric(18,6) not null check(required_quantity>0),
  available_quantity_snapshot numeric(18,6) not null default 0, suggested_quantity_snapshot numeric(18,6),
  unique(requisition_id,line_number), unique(requisition_id,product_id)
);
create table public.procurement_quotes(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  requisition_id uuid not null references public.procurement_requisitions(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict, currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  valid_until date, delivery_days integer check(delivery_days is null or delivery_days>=0), credit_days_snapshot integer,
  prompt_payment_terms_snapshot jsonb not null default '[]'::jsonb, notes text,
  status text not null default 'draft' check(status in ('draft','received','withdrawn','selected')),
  created_by uuid references auth.users(id) on delete set null default auth.uid(), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(requisition_id,supplier_id)
);
create table public.procurement_quote_lines(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  quote_id uuid not null references public.procurement_quotes(id) on delete cascade,
  requisition_line_id uuid not null references public.procurement_requisition_lines(id) on delete restrict,
  available_quantity numeric(18,6) not null check(available_quantity>=0), unit_price numeric(18,6) not null check(unit_price>=0),
  commercial_discount_percent numeric(9,4) not null default 0 check(commercial_discount_percent between 0 and 100),
  prompt_payment_discount_percent numeric(9,4) not null default 0 check(prompt_payment_discount_percent between 0 and 100),
  financing_terms text, expected_date date, unique(quote_id,requisition_line_id)
);
create table public.procurement_awards(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  requisition_id uuid not null unique references public.procurement_requisitions(id) on delete cascade,
  status text not null default 'recommended' check(status in ('recommended','approved','rejected')),
  recommendation_reason text not null, decided_reason text, recommended_by uuid references auth.users(id) on delete set null default auth.uid(), recommended_at timestamptz not null default now(), decided_by uuid references auth.users(id) on delete set null, decided_at timestamptz
);
create table public.procurement_award_lines(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  award_id uuid not null references public.procurement_awards(id) on delete cascade,
  requisition_line_id uuid not null references public.procurement_requisition_lines(id) on delete restrict,
  quote_line_id uuid not null references public.procurement_quote_lines(id) on delete restrict,
  awarded_quantity numeric(18,6) not null check(awarded_quantity>0), reason text, unique(award_id,requisition_line_id)
);
create table public.procurement_purchase_orders(
  procurement_award_id uuid not null references public.procurement_awards(id) on delete restrict,
  purchase_order_id uuid primary key references public.purchase_orders(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete cascade
);
create index procurement_requisitions_company_idx on public.procurement_requisitions(company_id,status,created_at desc);
create index procurement_quotes_requisition_idx on public.procurement_quotes(requisition_id,supplier_id);
create index procurement_quote_lines_quote_idx on public.procurement_quote_lines(quote_id,requisition_line_id);

create or replace function public.next_procurement_requisition_folio(p_company_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare v_number bigint;
begin
  select count(*)+1 into v_number from public.procurement_requisitions where company_id=p_company_id;
  return 'REQ-'||to_char(current_date,'YYYY')||'-'||lpad(v_number::text,6,'0');
end $$;

create or replace function public.save_procurement_requisition(
  p_company_id uuid,p_location_id uuid,p_source text,p_target_date date,p_exception_reason text,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_line jsonb;v_no int:=0;v_source text:=lower(trim(p_source));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'create_procurement_requisitions') then raise exception 'No autorizado para crear necesidades.'; end if;
  if v_source not in ('replenishment','manual_exception') then raise exception 'Origen de necesidad inválido.'; end if;
  if v_source='manual_exception' and nullif(trim(coalesce(p_exception_reason,'')),'') is null then raise exception 'La captura manual requiere una justificación.'; end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La necesidad requiere partidas.'; end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and public.can_access_location(id)) then raise exception 'Ubicación no disponible.'; end if;
  insert into public.procurement_requisitions(company_id,folio,location_id,source,target_date,exception_reason,status)
  values(p_company_id,public.next_procurement_requisition_folio(p_company_id),p_location_id,v_source,p_target_date,case when v_source='manual_exception' then trim(p_exception_reason) end,'quoting') returning id into v_id;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_no:=v_no+1;
    if not exists(select 1 from public.products where id=(v_line->>'product_id')::uuid and company_id=p_company_id and is_active) then raise exception 'Producto no disponible.'; end if;
    insert into public.procurement_requisition_lines(company_id,requisition_id,line_number,product_id,description,unit,required_quantity,available_quantity_snapshot,suggested_quantity_snapshot)
    select p_company_id,v_id,v_no,p.id,p.name,p.unit,(v_line->>'quantity')::numeric,coalesce(b.quantity_on_hand,0),nullif(v_line->>'suggested_quantity','')::numeric
    from public.products p left join public.inventory_balances b on b.product_id=p.id and b.location_id=p_location_id where p.id=(v_line->>'product_id')::uuid;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.requisition_created','procurement_requisition',v_id,jsonb_build_object('source',v_source,'line_count',v_no));
  return public.get_procurement_requisition(p_company_id,v_id);
end $$;

create or replace function public.save_procurement_quote(
  p_company_id uuid,p_requisition_id uuid,p_supplier_id uuid,p_currency_code text,p_valid_until date,p_delivery_days integer,p_notes text,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_quote uuid;v_line jsonb;v_terms jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_procurement_quotes') then raise exception 'No autorizado para cotizar.'; end if;
  if not exists(select 1 from public.procurement_requisitions where id=p_requisition_id and company_id=p_company_id and status in ('draft','quoting','recommended')) then raise exception 'Necesidad no disponible para cotizar.'; end if;
  if to_regclass('public.supplier_prompt_payment_terms') is not null then
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''term_days'',term_days,''discount_components'',discount_components) order by tier_number),''[]''::jsonb) from public.supplier_prompt_payment_terms where supplier_id=$1'
      into v_terms using p_supplier_id;
  else
    v_terms:='[]'::jsonb;
  end if;
  insert into public.procurement_quotes(company_id,requisition_id,supplier_id,currency_code,valid_until,delivery_days,credit_days_snapshot,prompt_payment_terms_snapshot,notes,status)
  select p_company_id,p_requisition_id,s.id,upper(trim(p_currency_code)),p_valid_until,p_delivery_days,s.payable_term_days,coalesce(v_terms,'[]'::jsonb),nullif(trim(p_notes),''),'received' from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id and s.is_active
  on conflict(requisition_id,supplier_id) do update set currency_code=excluded.currency_code,valid_until=excluded.valid_until,delivery_days=excluded.delivery_days,credit_days_snapshot=excluded.credit_days_snapshot,prompt_payment_terms_snapshot=excluded.prompt_payment_terms_snapshot,notes=excluded.notes,status='received',updated_at=now()
  returning id into v_quote;
  if v_quote is null then raise exception 'Proveedor no disponible.'; end if;
  delete from public.procurement_quote_lines where quote_id=v_quote;
  for v_line in select value from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    insert into public.procurement_quote_lines(company_id,quote_id,requisition_line_id,available_quantity,unit_price,commercial_discount_percent,prompt_payment_discount_percent,financing_terms,expected_date)
    select p_company_id,v_quote,r.id,(v_line->>'available_quantity')::numeric,(v_line->>'unit_price')::numeric,coalesce((v_line->>'commercial_discount_percent')::numeric,0),coalesce((v_line->>'prompt_payment_discount_percent')::numeric,0),nullif(trim(v_line->>'financing_terms'),''),nullif(v_line->>'expected_date','')::date from public.procurement_requisition_lines r where r.id=(v_line->>'requisition_line_id')::uuid and r.requisition_id=p_requisition_id;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.quote_saved','procurement_quote',v_quote,jsonb_build_object('requisition_id',p_requisition_id,'supplier_id',p_supplier_id));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

create or replace function public.recommend_procurement_award(p_company_id uuid,p_requisition_id uuid,p_reason text,p_lines jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_award uuid;v_line jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'recommend_procurement_awards') then raise exception 'No autorizado para recomendar.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La recomendación requiere motivo.'; end if;
  insert into public.procurement_awards(company_id,requisition_id,recommendation_reason) values(p_company_id,p_requisition_id,trim(p_reason)) on conflict(requisition_id) do update set status='recommended',recommendation_reason=excluded.recommendation_reason,recommended_by=auth.uid(),recommended_at=now(),decided_by=null,decided_at=null,decided_reason=null returning id into v_award;
  delete from public.procurement_award_lines where award_id=v_award;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    insert into public.procurement_award_lines(company_id,award_id,requisition_line_id,quote_line_id,awarded_quantity,reason)
    select p_company_id,v_award,ql.requisition_line_id,ql.id,(v_line->>'awarded_quantity')::numeric,nullif(trim(v_line->>'reason'),'') from public.procurement_quote_lines ql join public.procurement_quotes q on q.id=ql.quote_id where ql.id=(v_line->>'quote_line_id')::uuid and q.requisition_id=p_requisition_id and q.status='received' and (v_line->>'awarded_quantity')::numeric<=ql.available_quantity;
    if not found then raise exception 'Una adjudicación no corresponde a una cotización vigente o excede disponibilidad.'; end if;
  end loop;
  update public.procurement_requisitions set status='recommended',updated_at=now() where id=p_requisition_id and company_id=p_company_id;
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

create or replace function public.approve_procurement_award(p_company_id uuid,p_requisition_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_award public.procurement_awards%rowtype;v_supplier uuid;v_order uuid;v_quote record;v_lines jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'approve_procurement_awards') then raise exception 'No autorizado para aprobar adjudicación.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La aprobación requiere motivo.'; end if;
  select * into v_award from public.procurement_awards where requisition_id=p_requisition_id and company_id=p_company_id for update;
  if not found or v_award.status<>'recommended' then raise exception 'No hay una recomendación pendiente.'; end if;
  for v_supplier in select distinct q.supplier_id from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id where al.award_id=v_award.id loop
    select q.id,q.currency_code,min(ql.expected_date) expected_date into v_quote from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id where al.award_id=v_award.id and q.supplier_id=v_supplier group by q.id,q.currency_code limit 1;
    insert into public.purchase_orders(company_id,supplier_id,folio,status,currency_code,ordered_date,expected_date,requisition_reference,notes,submitted_at,submitted_by,decided_at,decided_by)
    values(p_company_id,v_supplier,public.next_purchase_order_folio(p_company_id,false),'draft',v_quote.currency_code,current_date,v_quote.expected_date,(select folio from public.procurement_requisitions where id=p_requisition_id),'Generada desde adjudicación aprobada.',now(),auth.uid(),now(),auth.uid()) returning id into v_order;
    insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,product_id,description,unit,quantity,unit_cost,discount_percent_1,expected_date,requisition_reference)
    select p_company_id,v_order,row_number() over(order by rl.line_number),rl.product_id,rl.description,rl.unit,al.awarded_quantity,ql.unit_price,ql.commercial_discount_percent,ql.expected_date,(select folio from public.procurement_requisitions where id=p_requisition_id)
    from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id join public.procurement_requisition_lines rl on rl.id=al.requisition_line_id where al.award_id=v_award.id and q.supplier_id=v_supplier;
    perform public.recalculate_purchase_order(v_order);
    update public.purchase_orders set status='approved',updated_by=auth.uid() where id=v_order;
    insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(p_company_id,v_order,'approved','Adjudicación de abastecimiento aprobada: '||trim(p_reason));
    insert into public.procurement_purchase_orders(procurement_award_id,purchase_order_id,company_id) values(v_award.id,v_order,p_company_id);
  end loop;
  update public.procurement_awards set status='approved',decided_by=auth.uid(),decided_at=now(),decided_reason=trim(p_reason) where id=v_award.id;
  update public.procurement_requisitions set status='approved',updated_at=now() where id=p_requisition_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.award_approved','procurement_award',v_award.id,jsonb_build_object('reason',trim(p_reason)));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

create or replace function public.get_procurement_requisition(p_company_id uuid,p_requisition_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_procurement') then raise exception 'No autorizado.'; end if;
  select to_jsonb(r)||jsonb_build_object('location_name',l.name,'lines',coalesce((select jsonb_agg(to_jsonb(rl)||jsonb_build_object('product_name',p.name,'product_code',coalesce(p.internal_sku,p.alpha_sku)) order by rl.line_number) from public.procurement_requisition_lines rl join public.products p on p.id=rl.product_id where rl.requisition_id=r.id),'[]'::jsonb),'quotes',coalesce((select jsonb_agg(to_jsonb(q)||jsonb_build_object('supplier_name',s.display_name,'lines',(select coalesce(jsonb_agg(to_jsonb(ql)),'[]'::jsonb) from public.procurement_quote_lines ql where ql.quote_id=q.id)) order by s.display_name) from public.procurement_quotes q join public.suppliers s on s.id=q.supplier_id where q.requisition_id=r.id),'[]'::jsonb),'award',(select to_jsonb(a)||jsonb_build_object('lines',(select coalesce(jsonb_agg(to_jsonb(al)),'[]'::jsonb) from public.procurement_award_lines al where al.award_id=a.id),'purchase_order_ids',(select coalesce(jsonb_agg(purchase_order_id),'[]'::jsonb) from public.procurement_purchase_orders po where po.procurement_award_id=a.id)) from public.procurement_awards a where a.requisition_id=r.id)) into v_result from public.procurement_requisitions r join public.locations l on l.id=r.location_id where r.id=p_requisition_id and r.company_id=p_company_id;
  if v_result is null then raise exception 'Necesidad no encontrada.'; end if; return v_result;
end $$;

create or replace function public.search_procurement_requisitions(p_company_id uuid,p_query text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_procurement') then raise exception 'No autorizado.'; end if;
  with filtered as materialized(select r.*,l.name location_name from public.procurement_requisitions r join public.locations l on l.id=r.location_id where r.company_id=p_company_id and (p_status is null or r.status=p_status) and (v_q='' or lower(r.folio) like '%'||v_q||'%' or lower(l.name) like '%'||v_q||'%')), paged as(select * from filtered order by created_at desc,id desc limit v_size offset(v_page-1)*v_size) select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by created_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

alter table public.procurement_requisitions enable row level security; alter table public.procurement_requisition_lines enable row level security; alter table public.procurement_quotes enable row level security; alter table public.procurement_quote_lines enable row level security; alter table public.procurement_awards enable row level security; alter table public.procurement_award_lines enable row level security; alter table public.procurement_purchase_orders enable row level security;
create policy procurement_requisitions_read on public.procurement_requisitions for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_requisition_lines_read on public.procurement_requisition_lines for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_quotes_read on public.procurement_quotes for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_quote_lines_read on public.procurement_quote_lines for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_awards_read on public.procurement_awards for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_award_lines_read on public.procurement_award_lines for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
create policy procurement_purchase_orders_read on public.procurement_purchase_orders for select to authenticated using(public.has_company_permission(company_id,'view_procurement'));
revoke all on public.procurement_requisitions,public.procurement_requisition_lines,public.procurement_quotes,public.procurement_quote_lines,public.procurement_awards,public.procurement_award_lines,public.procurement_purchase_orders from authenticated;
grant execute on function public.save_procurement_requisition(uuid,uuid,text,date,text,jsonb),public.save_procurement_quote(uuid,uuid,uuid,text,date,integer,text,jsonb),public.recommend_procurement_award(uuid,uuid,text,jsonb),public.approve_procurement_award(uuid,uuid,text),public.get_procurement_requisition(uuid,uuid),public.search_procurement_requisitions(uuid,text,text,integer,integer) to authenticated;
