-- Satrapy · Módulo 3C: recepción canónica, inventario y costo de reemplazo.
-- Impacto declarado: 84 OC / 731 partidas históricas, 0 recepciones históricas confiables.
-- Los estados Alpha sólo permanecen como evidencia; esta migración no promueve recepciones.

insert into public.permissions(code,description) values
  ('view_purchase_receipts','Consultar recepciones de compra.'),
  ('manage_purchase_receipt_drafts','Crear y editar borradores de recepción.'),
  ('confirm_purchase_receipts','Confirmar recepciones contra OC aprobadas.'),
  ('reverse_purchase_receipts','Autorizar reversas auditadas de recepciones.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_purchase_receipts','manage_purchase_receipt_drafts','confirm_purchase_receipts','reverse_purchase_receipts'
) on conflict do nothing;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code='almacen' and p.code in ('view_purchase_receipts','manage_purchase_receipt_drafts','confirm_purchase_receipts')
on conflict do nothing;

create table public.purchase_receipt_folio_counters(
  company_id uuid primary key references public.companies(id) on delete cascade,
  next_value bigint not null default 1 check(next_value>0),
  updated_at timestamptz not null default now()
);

create table public.purchase_receipts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  location_id uuid not null references public.locations(id) on delete restrict,
  folio text not null check(length(trim(folio))>0),
  status text not null default 'draft' check(status in ('draft','confirmed','reversed')),
  receipt_date date not null default current_date,
  document_reference text,
  notes text,
  client_request_id uuid not null,
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  confirm_request_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  reverse_request_id uuid,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,folio),
  unique(company_id,client_request_id),
  unique(company_id,confirm_request_id),
  unique(company_id,reverse_request_id),
  check((status in ('confirmed','reversed'))=(confirmed_at is not null and confirm_request_id is not null)),
  check((status='reversed')=(reversed_at is not null and reversed_by is not null and reversal_reason is not null and reverse_request_id is not null))
);
create index purchase_receipts_catalog_idx on public.purchase_receipts(company_id,status,receipt_date desc,id desc);
create index purchase_receipts_order_idx on public.purchase_receipts(purchase_order_id,created_at,id);
create index purchase_receipts_location_idx on public.purchase_receipts(company_id,location_id,receipt_date desc,id desc);
create trigger purchase_receipts_updated_at before update on public.purchase_receipts for each row execute function public.set_updated_at();

create table public.purchase_receipt_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_receipt_id uuid not null references public.purchase_receipts(id) on delete restrict,
  purchase_order_line_id uuid not null references public.purchase_order_lines(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check(quantity>0),
  unit_cost numeric(18,6) not null check(unit_cost>=0),
  line_cost numeric(18,6) generated always as (round(quantity*unit_cost,6)) stored,
  created_at timestamptz not null default now(),
  unique(purchase_receipt_id,purchase_order_line_id)
);
create index purchase_receipt_lines_receipt_idx on public.purchase_receipt_lines(purchase_receipt_id,purchase_order_line_id);
create index purchase_receipt_lines_order_line_idx on public.purchase_receipt_lines(purchase_order_line_id,purchase_receipt_id);

create table public.purchase_receipt_cost_changes(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_receipt_id uuid not null references public.purchase_receipts(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  previous_amount numeric(18,6),
  applied_amount numeric(18,6) not null check(applied_amount>=0),
  applied_product_cost_id uuid references public.product_costs(id) on delete restrict,
  reversal_product_cost_id uuid references public.product_costs(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(purchase_receipt_id,product_id,currency_code)
);

alter table public.purchase_orders add column fulfillment_status text not null default 'pending'
  check(fulfillment_status in ('pending','partially_received','fully_received'));

alter table public.inventory_ledger
  add column purchase_receipt_line_id uuid references public.purchase_receipt_lines(id) on delete restrict,
  add column purchase_receipt_id uuid references public.purchase_receipts(id) on delete restrict,
  add column purchase_order_id uuid references public.purchase_orders(id) on delete restrict,
  add column supplier_id uuid references public.suppliers(id) on delete restrict;

alter table public.inventory_ledger
  drop constraint if exists inventory_ledger_movement_type_check,
  drop constraint if exists inventory_ledger_source_check;

alter table public.inventory_ledger
  add constraint inventory_ledger_movement_type_check check(movement_type in (
    'opening_snapshot','sale','controlled_adjustment','physical_count_adjustment','transfer_out','transfer_in',
    'purchase_receipt','purchase_receipt_reversal'
  )),
  add constraint inventory_ledger_source_check check(
    (movement_type='opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null)
    or (movement_type='sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null)
    or (movement_type='controlled_adjustment' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null)
    or (movement_type='physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null)
    or (movement_type in ('transfer_out','transfer_in') and inventory_transfer_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and purchase_receipt_line_id is null)
    or (movement_type in ('purchase_receipt','purchase_receipt_reversal') and purchase_receipt_line_id is not null and purchase_receipt_id is not null and purchase_order_id is not null and supplier_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null)
  );
create unique index inventory_ledger_receipt_line_movement_once_idx
  on public.inventory_ledger(purchase_receipt_line_id,movement_type) where purchase_receipt_line_id is not null;

create or replace function public.next_purchase_receipt_folio(p_company_id uuid)
returns text language plpgsql security definer set search_path=public as $$
declare v_value bigint;
begin
  insert into public.purchase_receipt_folio_counters(company_id,next_value) values(p_company_id,2)
  on conflict(company_id) do update set next_value=public.purchase_receipt_folio_counters.next_value+1,updated_at=now()
  returning next_value-1 into v_value;
  return 'REC-'||to_char(current_date,'YYYY')||'-'||lpad(v_value::text,6,'0');
end $$;

create or replace function public.assert_purchase_receipt_integrity()
returns trigger language plpgsql set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_receipt public.purchase_receipts%rowtype;v_line public.purchase_order_lines%rowtype;
begin
  if tg_table_name='purchase_receipts' then
    select * into v_order from public.purchase_orders where id=new.purchase_order_id;
    if not found or v_order.company_id<>new.company_id or v_order.supplier_id<>new.supplier_id then raise exception 'La recepción, OC y proveedor deben pertenecer a la misma empresa.';end if;
    if not exists(select 1 from public.locations l where l.id=new.location_id and l.company_id=new.company_id and l.is_active) then raise exception 'La ubicación no pertenece a la empresa o está inactiva.';end if;
  else
    select * into v_receipt from public.purchase_receipts where id=new.purchase_receipt_id;
    select * into v_line from public.purchase_order_lines where id=new.purchase_order_line_id;
    if not found or v_receipt.company_id<>new.company_id or v_line.company_id<>new.company_id or v_line.purchase_order_id<>v_receipt.purchase_order_id or v_line.product_id is distinct from new.product_id then raise exception 'La partida no pertenece a la OC de la recepción.';end if;
  end if;
  return new;
end $$;
create trigger purchase_receipts_integrity before insert or update of company_id,purchase_order_id,supplier_id,location_id on public.purchase_receipts for each row execute function public.assert_purchase_receipt_integrity();
create trigger purchase_receipt_lines_integrity before insert or update of company_id,purchase_receipt_id,purchase_order_line_id,product_id on public.purchase_receipt_lines for each row execute function public.assert_purchase_receipt_integrity();

create or replace function public.protect_purchase_receipt()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status in ('confirmed','reversed') and (new.company_id,new.purchase_order_id,new.supplier_id,new.location_id,new.folio,new.receipt_date,new.document_reference,new.notes)
    is distinct from (old.company_id,old.purchase_order_id,old.supplier_id,old.location_id,old.folio,old.receipt_date,old.document_reference,old.notes) then
    raise exception 'Una recepción confirmada es inmutable; usa una reversa auditada.';
  end if;
  if old.status='reversed' and new.status<>'reversed' then raise exception 'Una recepción revertida no puede reabrirse.';end if;
  return new;
end $$;
create trigger purchase_receipts_lock before update on public.purchase_receipts for each row execute function public.protect_purchase_receipt();

create or replace function public.protect_purchase_receipt_line()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;
begin
  select status into v_status from public.purchase_receipts where id=coalesce(new.purchase_receipt_id,old.purchase_receipt_id);
  if v_status is distinct from 'draft' then raise exception 'Las partidas de una recepción confirmada son inmutables.';end if;
  return coalesce(new,old);
end $$;
create trigger purchase_receipt_lines_lock before insert or update or delete on public.purchase_receipt_lines for each row execute function public.protect_purchase_receipt_line();

create or replace function public.recalculate_purchase_order_fulfillment(p_order_id uuid)
returns text language plpgsql security definer set search_path=public as $$
declare v_ordered numeric;v_received numeric;v_status text;
begin
  select coalesce(sum(quantity),0) into v_ordered from public.purchase_order_lines where purchase_order_id=p_order_id;
  select coalesce(sum(rl.quantity),0) into v_received from public.purchase_receipt_lines rl join public.purchase_receipts r on r.id=rl.purchase_receipt_id where r.purchase_order_id=p_order_id and r.status='confirmed';
  v_status:=case when v_received=0 then 'pending' when v_received<v_ordered then 'partially_received' else 'fully_received' end;
  update public.purchase_orders set fulfillment_status=v_status where id=p_order_id;
  return v_status;
end $$;

alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_lines enable row level security;
alter table public.purchase_receipt_cost_changes enable row level security;
alter table public.purchase_receipt_folio_counters enable row level security;
create policy purchase_receipts_read on public.purchase_receipts for select to authenticated using(public.has_company_permission(company_id,'view_purchase_receipts') and public.can_access_location(location_id));
create policy purchase_receipt_lines_read on public.purchase_receipt_lines for select to authenticated using(exists(select 1 from public.purchase_receipts r where r.id=purchase_receipt_id and public.has_company_permission(r.company_id,'view_purchase_receipts') and public.can_access_location(r.location_id)));
create policy purchase_receipt_cost_changes_read on public.purchase_receipt_cost_changes for select to authenticated using(public.has_company_permission(company_id,'view_purchase_receipts') and public.has_company_permission(company_id,'view_costs'));
revoke all on public.purchase_receipts,public.purchase_receipt_lines,public.purchase_receipt_cost_changes,public.purchase_receipt_folio_counters from authenticated;

create or replace function public.save_purchase_receipt(
  p_company_id uuid,p_receipt_id uuid,p_purchase_order_id uuid,p_location_id uuid,p_receipt_date date,
  p_document_reference text default null,p_notes text default null,p_lines jsonb default '[]'::jsonb,
  p_client_request_id uuid default null,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_id uuid;v_line jsonb;v_po_line public.purchase_order_lines%rowtype;v_qty numeric;v_previous numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_before jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts') then raise exception 'No autorizado para administrar borradores de recepción.';end if;
  if p_receipt_date is null then raise exception 'La fecha de recepción es obligatoria.';end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La recepción requiere al menos una partida.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found then raise exception 'OC no encontrada.';end if;
  if v_order.status<>'approved' then raise exception 'Sólo una OC aprobada puede recibirse.';end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then raise exception 'Ubicación no disponible.';end if;
  if p_receipt_id is null then
    select * into v_receipt from public.purchase_receipts where company_id=p_company_id and client_request_id=v_request;
    if found then return to_jsonb(v_receipt);end if;
    insert into public.purchase_receipts(company_id,purchase_order_id,supplier_id,location_id,folio,receipt_date,document_reference,notes,client_request_id)
    values(p_company_id,p_purchase_order_id,v_order.supplier_id,p_location_id,public.next_purchase_receipt_folio(p_company_id),p_receipt_date,nullif(trim(p_document_reference),''),nullif(trim(p_notes),''),v_request) returning id into v_id;
  else
    select to_jsonb(r) into v_before from public.purchase_receipts r where r.id=p_receipt_id and r.company_id=p_company_id;
    select * into v_receipt from public.purchase_receipts r where r.id=p_receipt_id and r.company_id=p_company_id for update;
    if not found then raise exception 'Recepción no encontrada.';end if;
    if v_receipt.status<>'draft' then raise exception 'La recepción ya no admite edición.';end if;
    if v_receipt.purchase_order_id<>p_purchase_order_id then raise exception 'No se puede cambiar la OC de una recepción.';end if;
    if p_expected_updated_at is not null and v_receipt.updated_at is distinct from p_expected_updated_at then raise exception 'La recepción cambió desde que la abriste.';end if;
    v_id:=v_receipt.id;
    update public.purchase_receipts set location_id=p_location_id,receipt_date=p_receipt_date,document_reference=nullif(trim(p_document_reference),''),notes=nullif(trim(p_notes),''),updated_by=auth.uid() where id=v_id;
    delete from public.purchase_receipt_lines where purchase_receipt_id=v_id;
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    begin v_qty:=(v_line->>'quantity')::numeric;exception when others then raise exception 'Cantidad de recepción inválida.';end;
    if v_qty<=0 then raise exception 'Las cantidades recibidas deben ser mayores a cero.';end if;
    select * into v_po_line from public.purchase_order_lines where id=nullif(v_line->>'purchase_order_line_id','')::uuid and purchase_order_id=p_purchase_order_id and company_id=p_company_id for update;
    if not found or v_po_line.product_id is null then raise exception 'La partida no pertenece a la OC o no tiene producto canónico.';end if;
    select coalesce(sum(rl.quantity),0) into v_previous from public.purchase_receipt_lines rl join public.purchase_receipts r on r.id=rl.purchase_receipt_id where rl.purchase_order_line_id=v_po_line.id and r.status='confirmed';
    if v_qty>v_po_line.quantity-v_previous then raise exception 'La cantidad recibida supera la cantidad pendiente.';end if;
    insert into public.purchase_receipt_lines(company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,unit_cost)
    values(p_company_id,v_id,v_po_line.id,v_po_line.product_id,v_qty,round(v_po_line.unit_cost*(1-v_po_line.discount_percent_1/100)*(1-v_po_line.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6));
  end loop;
  select * into v_receipt from public.purchase_receipts where id=v_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_receipt_id is null then 'purchase_receipt.draft_created' else 'purchase_receipt.draft_updated' end,'purchase_receipt',v_id,jsonb_build_object('before',v_before,'line_count',jsonb_array_length(p_lines),'client_request_id',v_request));
  return to_jsonb(v_receipt);
end $$;

create or replace function public.confirm_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_balance numeric;v_pending numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_fulfillment text;v_now timestamptz:=clock_timestamp();v_old_cost numeric;v_cost_id uuid;v_cost record;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_purchase_receipts') then raise exception 'No autorizado para confirmar recepciones.';end if;
  select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id for update;
  if not found then raise exception 'Recepción no encontrada.';end if;
  if v_receipt.confirm_request_id=v_request and v_receipt.status in ('confirmed','reversed') then return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status,'idempotent',true,'fulfillment_status',(select fulfillment_status from public.purchase_orders where id=v_receipt.purchase_order_id));end if;
  if v_receipt.status<>'draft' then raise exception 'La recepción ya fue confirmada o revertida.';end if;
  if not public.can_access_location(v_receipt.location_id) then raise exception 'Ubicación no disponible.';end if;
  select * into v_order from public.purchase_orders where id=v_receipt.purchase_order_id and company_id=p_company_id for update;
  if v_order.status<>'approved' then raise exception 'Sólo una OC aprobada puede recibirse.';end if;
  if not exists(select 1 from public.purchase_receipt_lines where purchase_receipt_id=v_receipt.id) then raise exception 'La recepción no tiene partidas.';end if;
  for v_line in
    select rl.*,pol.quantity ordered_quantity from public.purchase_receipt_lines rl join public.purchase_order_lines pol on pol.id=rl.purchase_order_line_id where rl.purchase_receipt_id=v_receipt.id order by rl.purchase_order_line_id for update of pol
  loop
    select v_line.ordered_quantity-coalesce(sum(other.quantity),0) into v_pending from public.purchase_receipt_lines other join public.purchase_receipts r on r.id=other.purchase_receipt_id where other.purchase_order_line_id=v_line.purchase_order_line_id and r.status='confirmed';
    if v_line.quantity>v_pending then raise exception 'La cantidad recibida supera la cantidad pendiente.';end if;
    insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(p_company_id,v_receipt.location_id,v_line.product_id,0) on conflict(location_id,product_id) do nothing;
    select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_receipt.location_id and product_id=v_line.product_id for update;
    update public.inventory_balances set quantity_on_hand=v_balance+v_line.quantity,updated_at=v_now where location_id=v_receipt.location_id and product_id=v_line.product_id;
    insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,purchase_receipt_line_id,purchase_receipt_id,purchase_order_id,supplier_id,occurred_at,actor_id)
    values(p_company_id,v_receipt.location_id,v_line.product_id,v_line.quantity,v_balance+v_line.quantity,'purchase_receipt',v_line.id,v_receipt.id,v_order.id,v_order.supplier_id,v_now,auth.uid());
  end loop;
  for v_cost in
    select rl.product_id,v_order.currency_code,round(sum(rl.line_cost)/sum(rl.quantity),6) amount from public.purchase_receipt_lines rl where rl.purchase_receipt_id=v_receipt.id group by rl.product_id
  loop
    select amount into v_old_cost from public.product_costs where company_id=p_company_id and product_id=v_cost.product_id and cost_type='replacement_cost' and currency_code=v_cost.currency_code and valid_from<=v_now and (valid_to is null or valid_to>v_now) order by valid_from desc limit 1 for update;
    update public.product_costs set valid_to=v_now where company_id=p_company_id and product_id=v_cost.product_id and cost_type='replacement_cost' and currency_code=v_cost.currency_code and valid_to is null and valid_from<v_now;
    insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,created_by) values(p_company_id,v_cost.product_id,'replacement_cost',v_cost.amount,v_cost.currency_code,v_now,'purchase_receipt:'||v_receipt.folio,auth.uid()) returning id into v_cost_id;
    insert into public.purchase_receipt_cost_changes(company_id,purchase_receipt_id,product_id,currency_code,previous_amount,applied_amount,applied_product_cost_id) values(p_company_id,v_receipt.id,v_cost.product_id,v_cost.currency_code,v_old_cost,v_cost.amount,v_cost_id);
  end loop;
  update public.purchase_receipts set status='confirmed',confirmed_at=v_now,confirmed_by=auth.uid(),confirm_request_id=v_request,updated_by=auth.uid() where id=v_receipt.id;
  v_fulfillment:=public.recalculate_purchase_order_fulfillment(v_order.id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_receipt.confirmed','purchase_receipt',v_receipt.id,jsonb_build_object('purchase_order_id',v_order.id,'supplier_id',v_order.supplier_id,'location_id',v_receipt.location_id,'fulfillment_status',v_fulfillment,'client_request_id',v_request));
  return jsonb_build_object('receipt_id',v_receipt.id,'status','confirmed','idempotent',false,'fulfillment_status',v_fulfillment);
end $$;

create or replace function public.reverse_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_reason text,p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_balance numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_fulfillment text;v_now timestamptz:=clock_timestamp();v_cost record;v_cost_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reverse_purchase_receipts') then raise exception 'No autorizado para autorizar reversas.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La reversa requiere un motivo.';end if;
  select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id for update;
  if not found then raise exception 'Recepción no encontrada.';end if;
  if v_receipt.reverse_request_id=v_request and v_receipt.status='reversed' then return jsonb_build_object('receipt_id',v_receipt.id,'status','reversed','idempotent',true,'fulfillment_status',(select fulfillment_status from public.purchase_orders where id=v_receipt.purchase_order_id));end if;
  if v_receipt.status<>'confirmed' then raise exception 'Sólo una recepción confirmada puede revertirse.';end if;
  select * into v_order from public.purchase_orders where id=v_receipt.purchase_order_id for update;
  for v_line in select * from public.purchase_receipt_lines where purchase_receipt_id=v_receipt.id order by product_id,purchase_order_line_id loop
    select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_receipt.location_id and product_id=v_line.product_id for update;
    if v_balance is null or v_balance<v_line.quantity then raise exception 'Existencia insuficiente para revertir la recepción.';end if;
    update public.inventory_balances set quantity_on_hand=v_balance-v_line.quantity,updated_at=v_now where location_id=v_receipt.location_id and product_id=v_line.product_id;
    insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,purchase_receipt_line_id,purchase_receipt_id,purchase_order_id,supplier_id,occurred_at,actor_id)
    values(p_company_id,v_receipt.location_id,v_line.product_id,-v_line.quantity,v_balance-v_line.quantity,'purchase_receipt_reversal',v_line.id,v_receipt.id,v_order.id,v_order.supplier_id,v_now,auth.uid());
  end loop;
  for v_cost in select * from public.purchase_receipt_cost_changes where purchase_receipt_id=v_receipt.id for update loop
    if exists(select 1 from public.product_costs where id=v_cost.applied_product_cost_id and valid_to is null) then
      update public.product_costs set valid_to=v_now where id=v_cost.applied_product_cost_id;
      if v_cost.previous_amount is not null then
        insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,created_by) values(p_company_id,v_cost.product_id,'replacement_cost',v_cost.previous_amount,v_cost.currency_code,v_now,'purchase_receipt_reversal:'||v_receipt.folio,auth.uid()) returning id into v_cost_id;
        update public.purchase_receipt_cost_changes set reversal_product_cost_id=v_cost_id where id=v_cost.id;
      end if;
    end if;
  end loop;
  update public.purchase_receipts set status='reversed',reversed_at=v_now,reversed_by=auth.uid(),reversal_reason=trim(p_reason),reverse_request_id=v_request,updated_by=auth.uid() where id=v_receipt.id;
  v_fulfillment:=public.recalculate_purchase_order_fulfillment(v_order.id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_receipt.reversed','purchase_receipt',v_receipt.id,jsonb_build_object('purchase_order_id',v_order.id,'supplier_id',v_order.supplier_id,'location_id',v_receipt.location_id,'reason',trim(p_reason),'fulfillment_status',v_fulfillment,'client_request_id',v_request));
  return jsonb_build_object('receipt_id',v_receipt.id,'status','reversed','idempotent',false,'fulfillment_status',v_fulfillment);
end $$;

create or replace function public.search_purchase_receipts(p_company_id uuid,p_query text default null,p_status text default null,p_location_id uuid default null,p_supplier_id uuid default null,p_date_from date default null,p_date_to date default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select count(*) into v_total from public.purchase_receipts r join public.purchase_orders po on po.id=r.purchase_order_id join public.suppliers s on s.id=r.supplier_id join public.locations l on l.id=r.location_id where r.company_id=p_company_id and public.can_access_location(r.location_id) and (p_status is null or r.status=p_status) and (p_location_id is null or r.location_id=p_location_id) and (p_supplier_id is null or r.supplier_id=p_supplier_id) and (p_date_from is null or r.receipt_date>=p_date_from) and (p_date_to is null or r.receipt_date<=p_date_to) and (v_query='' or lower(r.folio) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(r.document_reference,'')) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.receipt_date desc,x.id desc),'[]'::jsonb) into v_items from (select r.id,r.folio,r.status,r.receipt_date,r.document_reference,r.purchase_order_id,po.folio purchase_order_folio,po.fulfillment_status,r.supplier_id,s.display_name supplier_name,r.location_id,l.name location_name,r.created_at,r.updated_at from public.purchase_receipts r join public.purchase_orders po on po.id=r.purchase_order_id join public.suppliers s on s.id=r.supplier_id join public.locations l on l.id=r.location_id where r.company_id=p_company_id and public.can_access_location(r.location_id) and (p_status is null or r.status=p_status) and (p_location_id is null or r.location_id=p_location_id) and (p_supplier_id is null or r.supplier_id=p_supplier_id) and (p_date_from is null or r.receipt_date>=p_date_from) and (p_date_to is null or r.receipt_date<=p_date_to) and (v_query='' or lower(r.folio) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(r.document_reference,'')) like '%'||v_query||'%') order by r.receipt_date desc,r.id desc limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_purchase_receipt_detail(p_company_id uuid,p_receipt_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_can_cost boolean;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id and public.can_access_location(location_id);if not found then raise exception 'Recepción no encontrada.';end if;
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');
  select to_jsonb(r)||jsonb_build_object('purchase_order',jsonb_build_object('id',po.id,'folio',po.folio,'status',po.status,'fulfillment_status',po.fulfillment_status,'origin',po.origin),'supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name),'location',jsonb_build_object('id',l.id,'code',l.external_code,'name',l.name),'lines',(select coalesce(jsonb_agg(jsonb_build_object('id',rl.id,'purchase_order_line_id',rl.purchase_order_line_id,'product_id',rl.product_id,'product_code',p.alpha_sku,'product_name',p.name,'ordered_quantity',pol.quantity,'previously_received',coalesce((select sum(x.quantity) from public.purchase_receipt_lines x join public.purchase_receipts xr on xr.id=x.purchase_receipt_id where x.purchase_order_line_id=pol.id and xr.status='confirmed' and xr.id<>r.id),0),'current_quantity',rl.quantity,'pending_quantity',pol.quantity-coalesce((select sum(x.quantity) from public.purchase_receipt_lines x join public.purchase_receipts xr on xr.id=x.purchase_receipt_id where x.purchase_order_line_id=pol.id and xr.status='confirmed'),0),'unit_cost',case when v_can_cost then rl.unit_cost else null end,'line_cost',case when v_can_cost then rl.line_cost else null end) order by pol.line_number),'[]'::jsonb) from public.purchase_receipt_lines rl join public.purchase_order_lines pol on pol.id=rl.purchase_order_line_id join public.products p on p.id=rl.product_id where rl.purchase_receipt_id=r.id),'movements',(select coalesce(jsonb_agg(jsonb_build_object('id',il.id,'movement_type',il.movement_type,'product_id',il.product_id,'quantity_delta',il.quantity_delta,'balance_after',il.balance_after,'occurred_at',il.occurred_at) order by il.occurred_at,il.id),'[]'::jsonb) from public.inventory_ledger il where il.purchase_receipt_id=r.id)) into v_result from public.purchase_receipts r join public.purchase_orders po on po.id=r.purchase_order_id join public.suppliers s on s.id=r.supplier_id join public.locations l on l.id=r.location_id where r.id=v_receipt.id;
  return v_result;
end $$;

create or replace function public.search_receivable_purchase_orders(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_purchase_receipts') or public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts')) then raise exception 'No autorizado para consultar OC recibibles.';end if;
  select count(*) into v_total from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id where po.company_id=p_company_id and po.status='approved' and po.fulfillment_status<>'fully_received' and (v_query='' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.ordered_date,x.id),'[]'::jsonb) into v_items from (select po.id,po.folio,po.ordered_date,po.fulfillment_status,po.origin,s.code supplier_code,s.display_name supplier_name from public.purchase_orders po join public.suppliers s on s.id=po.supplier_id where po.company_id=p_company_id and po.status='approved' and po.fulfillment_status<>'fully_received' and (v_query='' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%') order by po.ordered_date,po.id limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_receivable_purchase_order(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id;if not found then raise exception 'OC no encontrada.';end if;
  select jsonb_build_object('purchase_order_id',v_order.id,'folio',v_order.folio,'status',v_order.status,'fulfillment_status',v_order.fulfillment_status,'origin',v_order.origin,'historical_receipt_gap',v_order.origin='imported_historical','historical_receipt_gap_note',case when v_order.origin='imported_historical' then 'Los estados Alpha son evidencia; no se promovieron recepciones ni movimientos históricos.' end,'lines',coalesce(jsonb_agg(jsonb_build_object('id',pol.id,'line_number',pol.line_number,'product_id',pol.product_id,'description',pol.description,'unit',pol.unit,'ordered_quantity',pol.quantity,'previously_received',coalesce(x.received,0),'pending_quantity',pol.quantity-coalesce(x.received,0),'unit_cost',case when public.has_company_permission(p_company_id,'view_costs') then round(pol.unit_cost*(1-pol.discount_percent_1/100)*(1-pol.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6) else null end) order by pol.line_number),'[]'::jsonb)) into v_result from public.purchase_order_lines pol left join lateral(select sum(rl.quantity) received from public.purchase_receipt_lines rl join public.purchase_receipts r on r.id=rl.purchase_receipt_id where rl.purchase_order_line_id=pol.id and r.status='confirmed')x on true where pol.purchase_order_id=v_order.id;
  return v_result;
end $$;

create or replace function public.list_purchase_order_receipts(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  return jsonb_build_object('receipts',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'folio',r.folio,'status',r.status,'receipt_date',r.receipt_date,'location_id',r.location_id,'location_name',l.name,'document_reference',r.document_reference,'confirmed_at',r.confirmed_at,'reversed_at',r.reversed_at) order by r.receipt_date,r.id),'[]'::jsonb) from public.purchase_receipts r join public.locations l on l.id=r.location_id where r.company_id=p_company_id and r.purchase_order_id=p_purchase_order_id and public.can_access_location(r.location_id)),'movements',(select coalesce(jsonb_agg(jsonb_build_object('id',il.id,'receipt_id',il.purchase_receipt_id,'movement_type',il.movement_type,'product_id',il.product_id,'location_id',il.location_id,'quantity_delta',il.quantity_delta,'balance_after',il.balance_after,'occurred_at',il.occurred_at) order by il.occurred_at,il.id),'[]'::jsonb) from public.inventory_ledger il where il.company_id=p_company_id and il.purchase_order_id=p_purchase_order_id and public.can_access_location(il.location_id)));
end $$;

revoke all on function public.next_purchase_receipt_folio(uuid) from public;
revoke all on function public.recalculate_purchase_order_fulfillment(uuid) from public;
revoke all on function public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz) from public;
revoke all on function public.confirm_purchase_receipt(uuid,uuid,uuid) from public;
revoke all on function public.reverse_purchase_receipt(uuid,uuid,text,uuid) from public;
revoke all on function public.search_purchase_receipts(uuid,text,text,uuid,uuid,date,date,integer,integer) from public;
revoke all on function public.get_purchase_receipt_detail(uuid,uuid) from public;
revoke all on function public.search_receivable_purchase_orders(uuid,text,integer,integer) from public;
revoke all on function public.get_receivable_purchase_order(uuid,uuid) from public;
revoke all on function public.list_purchase_order_receipts(uuid,uuid) from public;
grant execute on function public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz) to authenticated;
grant execute on function public.confirm_purchase_receipt(uuid,uuid,uuid) to authenticated;
grant execute on function public.reverse_purchase_receipt(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.search_purchase_receipts(uuid,text,text,uuid,uuid,date,date,integer,integer) to authenticated;
grant execute on function public.get_purchase_receipt_detail(uuid,uuid) to authenticated;
grant execute on function public.search_receivable_purchase_orders(uuid,text,integer,integer) to authenticated;
grant execute on function public.get_receivable_purchase_order(uuid,uuid) to authenticated;
grant execute on function public.list_purchase_order_receipts(uuid,uuid) to authenticated;
