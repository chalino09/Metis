-- Punto 2 · Postventa.
-- Una devolución es un documento separado, ligado a las partidas vendidas.
-- La venta y su ticket permanecen inmutables; inventario sólo se reintegra
-- cuando el operador declara que la mercancía fue recibida en condición vendible.

insert into public.permissions(code,description) values
  ('process_sale_returns','Registrar devoluciones parciales o totales con ajuste financiero, inventario y auditoría.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id
from public.roles r
cross join public.permissions p
where r.code in ('super_admin','direccion_admin','supervisor_sucursal')
  and p.code='process_sale_returns'
on conflict do nothing;

create table public.sale_returns(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete restrict,
  location_id uuid not null references public.locations(id) on delete restrict,
  currency_code text not null check(currency_code ~ '^[A-Z]{3}$'),
  reason text not null check(nullif(trim(reason),'') is not null),
  gross_amount numeric(18,2) not null default 0 check(gross_amount>=0),
  discount_amount numeric(18,2) not null default 0 check(discount_amount>=0),
  taxable_amount numeric(18,2) not null default 0 check(taxable_amount>=0),
  tax_amount numeric(18,2) not null default 0 check(tax_amount>=0),
  total_amount numeric(18,2) not null default 0 check(total_amount>=0),
  recognized_restock_cost_amount numeric(18,6),
  financial_adjustment_kind text not null check(financial_adjustment_kind in ('cash_refund','external_refund','receivable_reduction')),
  cash_session_id uuid references public.cash_sessions(id) on delete restrict,
  external_reference text,
  client_request_id uuid not null,
  returned_by uuid references auth.users(id) on delete set null default auth.uid(),
  returned_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(company_id,client_request_id),
  check(
    (financial_adjustment_kind='cash_refund' and cash_session_id is not null and external_reference is null)
    or (financial_adjustment_kind='external_refund' and cash_session_id is null and nullif(trim(external_reference),'') is not null)
    or (financial_adjustment_kind='receivable_reduction' and cash_session_id is null and external_reference is null)
  )
);
create index sale_returns_sale_returned_idx on public.sale_returns(sale_id,returned_at,id);

create table public.sale_return_items(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  sale_return_id uuid not null references public.sale_returns(id) on delete restrict,
  sale_item_id uuid not null references public.sale_items(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check(quantity>0),
  restocked boolean not null,
  gross_amount numeric(18,2) not null check(gross_amount>=0),
  discount_amount numeric(18,2) not null check(discount_amount>=0),
  taxable_amount numeric(18,2) not null check(taxable_amount>=0),
  tax_amount numeric(18,2) not null check(tax_amount>=0),
  total_amount numeric(18,2) not null check(total_amount>=0),
  recognized_unit_cost numeric(18,6),
  recognized_cost_amount numeric(18,6),
  created_at timestamptz not null default now(),
  unique(sale_return_id,sale_item_id),
  check(
    (recognized_unit_cost is null and recognized_cost_amount is null)
    or (recognized_unit_cost is not null and recognized_unit_cost>=0 and recognized_cost_amount=round(quantity*recognized_unit_cost,6))
  )
);
create index sale_return_items_sale_item_idx on public.sale_return_items(sale_item_id,sale_return_id);

alter table public.inventory_ledger
  add column sale_return_item_id uuid references public.sale_return_items(id) on delete restrict;
alter table public.inventory_ledger
  drop constraint if exists inventory_ledger_movement_type_check,
  drop constraint if exists inventory_ledger_source_check;
alter table public.inventory_ledger
  add constraint inventory_ledger_movement_type_check check(movement_type in (
    'opening_snapshot','sale','sale_reversal','sale_return','controlled_adjustment',
    'physical_count_adjustment','transfer_out','transfer_in','purchase_receipt','purchase_receipt_reversal'
  )),
  add constraint inventory_ledger_source_check check(
    (movement_type='opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='sale_reversal' and sale_cancellation_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_return_item_id is null)
    or (movement_type='sale_return' and sale_return_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null)
    or (movement_type='controlled_adjustment' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type in ('transfer_out','transfer_in') and inventory_transfer_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type in ('purchase_receipt','purchase_receipt_reversal') and purchase_receipt_line_id is not null and purchase_receipt_id is not null and purchase_order_id is not null and supplier_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
  );
create unique index inventory_ledger_sale_return_once_idx
  on public.inventory_ledger(sale_return_item_id) where sale_return_item_id is not null;

alter table public.accounting_events drop constraint if exists accounting_events_event_type_check;
alter table public.accounting_events add constraint accounting_events_event_type_check check(event_type in (
  'sale_confirmed','sale_cancelled','sale_return_confirmed','receivable_payment_confirmed','receivable_payment_reversed',
  'cash_opened','cash_movement_recorded','cash_movement_reversed','cash_closed',
  'purchase_receipt_confirmed','purchase_receipt_reversed','inventory_adjustment_posted','inventory_adjustment_reversed',
  'supplier_invoice_confirmed','supplier_invoice_reversed','supplier_credit_note_confirmed','supplier_credit_note_reversed',
  'supplier_payment_confirmed','supplier_payment_reversed',
  'cash_transfer_dispatched','cash_transfer_received','cash_transfer_confirmed','cash_transfer_reversed'
));

create or replace function public.block_sale_cancellation_after_return()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.sale_returns where sale_id=new.sale_id) then
    raise exception 'La venta ya tiene devoluciones; no puede cancelarse completa.';
  end if;
  return new;
end $$;
create trigger sale_cancellations_block_after_return
before insert on public.sale_cancellations
for each row execute function public.block_sale_cancellation_after_return();

create or replace function public.get_sale_return_context(p_company_id uuid,p_sale_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_sale public.sales%rowtype;v_ticket text;v_items jsonb;v_returns jsonb;v_payment public.sale_payments%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales') then
    raise exception 'No autorizado para consultar la postventa.';
  end if;
  select * into v_sale from public.sales where id=p_sale_id and company_id=p_company_id;
  if not found or not public.can_access_location(v_sale.location_id) then raise exception 'Venta no disponible.';end if;
  select folio into v_ticket from public.canonical_tickets where sale_id=v_sale.id;
  if v_sale.sale_type='cash' then select * into v_payment from public.sale_payments where sale_id=v_sale.id;end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'sale_item_id',si.id,'product_id',si.product_id,'product_code',si.product_code,'product_name',si.product_name,
    'unit_name',si.unit_name,'sold_quantity',si.quantity,
    'returned_quantity',coalesce(x.returned_quantity,0),
    'available_quantity',si.quantity-coalesce(x.returned_quantity,0),
    'unit_price_amount',si.unit_price_amount,'total_amount',si.total_amount,
    'inventory_tracked',il.id is not null
  ) order by si.created_at,si.id),'[]'::jsonb) into v_items
  from public.sale_items si
  left join (
    select sale_item_id,sum(quantity) returned_quantity
    from public.sale_return_items group by sale_item_id
  ) x on x.sale_item_id=si.id
  left join public.inventory_ledger il on il.sale_item_id=si.id and il.movement_type='sale'
  where si.sale_id=v_sale.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',sr.id,'reason',sr.reason,'total_amount',sr.total_amount,
    'financial_adjustment_kind',sr.financial_adjustment_kind,'external_reference',sr.external_reference,
    'returned_by',sr.returned_by,'returned_at',sr.returned_at,
    'items',(select jsonb_agg(jsonb_build_object(
      'sale_item_id',sri.sale_item_id,'product_name',si.product_name,'quantity',sri.quantity,'restocked',sri.restocked
    ) order by sri.id) from public.sale_return_items sri join public.sale_items si on si.id=sri.sale_item_id where sri.sale_return_id=sr.id)
  ) order by sr.returned_at, sr.id),'[]'::jsonb) into v_returns
  from public.sale_returns sr where sr.sale_id=v_sale.id;
  return jsonb_build_object(
    'sale',jsonb_build_object('id',v_sale.id,'folio',v_ticket,'sale_type',v_sale.sale_type,'currency_code',v_sale.currency_code,
      'total_amount',v_sale.total_amount,'completed_at',v_sale.completed_at,'location_id',v_sale.location_id),
    'items',v_items,'returns',v_returns,
    'cancelled',exists(select 1 from public.sale_cancellations where sale_id=v_sale.id),
    'can_process',public.has_company_permission(p_company_id,'process_sale_returns'),
    'settlement_kind',case when v_sale.sale_type='credit' then 'receivable' else v_payment.settlement_kind end,
    'own_open_cash_session_id',(select cs.id from public.cash_sessions cs where cs.company_id=p_company_id
      and cs.location_id=v_sale.location_id and cs.opened_by=auth.uid() and cs.status='open' order by cs.opened_at desc limit 1)
  );
end $$;

create or replace function public.process_sale_return(
  p_company_id uuid,p_sale_id uuid,p_reason text,p_items jsonb,
  p_cash_session_id uuid default null,p_external_reference text default null,p_client_request_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_sale public.sales%rowtype;v_existing public.sale_returns%rowtype;v_payment public.sale_payments%rowtype;
  v_receivable public.customer_receivables%rowtype;v_session public.cash_sessions%rowtype;
  v_input record;v_item public.sale_items%rowtype;v_return_id uuid;v_return_item_id uuid;v_request uuid:=p_client_request_id;
  v_prior_quantity numeric;v_prior_gross numeric;v_prior_discount numeric;v_prior_taxable numeric;v_prior_tax numeric;v_prior_total numeric;
  v_gross numeric;v_discount numeric;v_taxable numeric;v_tax numeric;v_total numeric;
  v_gross_sum numeric:=0;v_discount_sum numeric:=0;v_taxable_sum numeric:=0;v_tax_sum numeric:=0;v_total_sum numeric:=0;
  v_restock_cost numeric:=0;v_balance numeric;v_kind text;v_settlement_role text;v_tax_role text;v_lines jsonb:='[]'::jsonb;
  v_item_count int:=0;v_accounting boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'process_sale_returns') then
    raise exception 'No autorizado para registrar devoluciones.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or v_request is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Motivo, partidas y llave de idempotencia son obligatorios.';
  end if;
  select * into v_existing from public.sale_returns where company_id=p_company_id and client_request_id=v_request;
  if found then return to_jsonb(v_existing)||jsonb_build_object('idempotent',true);end if;
  select * into v_sale from public.sales where id=p_sale_id and company_id=p_company_id for update;
  if not found or not public.can_access_location(v_sale.location_id) then raise exception 'Venta no disponible.';end if;
  if exists(select 1 from public.sale_cancellations where sale_id=v_sale.id) then raise exception 'Una venta cancelada no admite devoluciones.';end if;
  if exists(
    select 1 from jsonb_to_recordset(p_items)x(sale_item_id uuid,quantity numeric,restock boolean)
    group by sale_item_id having count(*)>1
  ) then raise exception 'Cada partida vendida debe aparecer una sola vez.';end if;
  v_accounting:=public.accounting_operational_matrix_active(p_company_id);
  if v_sale.sale_type='cash' then
    select * into v_payment from public.sale_payments where sale_id=v_sale.id;
    if not found then raise exception 'La venta no conserva su liquidación original.';end if;
    if v_payment.settlement_kind='cash_drawer' then
      select * into v_session from public.cash_sessions where id=p_cash_session_id and company_id=p_company_id
        and location_id=v_sale.location_id and opened_by=auth.uid() and status='open' for share;
      if not found then raise exception 'El reembolso en efectivo requiere una caja propia abierta en la sucursal de la venta.';end if;
      v_kind:='cash_refund';v_settlement_role:='cash';
    else
      if nullif(trim(coalesce(p_external_reference,'')),'') is null then raise exception 'El reembolso externo requiere una referencia.';end if;
      v_kind:='external_refund';v_settlement_role:='banks';
    end if;
    v_tax_role:='vat_collected';
  else
    select * into v_receivable from public.customer_receivables where sale_id=v_sale.id for update;
    if not found then raise exception 'La venta a crédito no conserva su cuenta por cobrar.';end if;
    v_kind:='receivable_reduction';v_settlement_role:='accounts_receivable';v_tax_role:='vat_pending';
  end if;
  insert into public.sale_returns(company_id,sale_id,location_id,currency_code,reason,financial_adjustment_kind,cash_session_id,external_reference,client_request_id)
  values(p_company_id,v_sale.id,v_sale.location_id,v_sale.currency_code,trim(p_reason),v_kind,
    case when v_kind='cash_refund' then v_session.id end,case when v_kind='external_refund' then trim(p_external_reference) end,v_request)
  returning id into v_return_id;
  for v_input in
    select * from jsonb_to_recordset(p_items)x(sale_item_id uuid,quantity numeric,restock boolean)
    order by sale_item_id
  loop
    if coalesce(v_input.quantity,0)<=0 or v_input.restock is null then raise exception 'Cantidad y condición de recepción son obligatorias.';end if;
    select * into v_item from public.sale_items where id=v_input.sale_item_id and sale_id=v_sale.id for share;
    if not found then raise exception 'La partida no pertenece al ticket original.';end if;
    select coalesce(sum(quantity),0),coalesce(sum(gross_amount),0),coalesce(sum(discount_amount),0),
      coalesce(sum(taxable_amount),0),coalesce(sum(tax_amount),0),coalesce(sum(total_amount),0)
    into v_prior_quantity,v_prior_gross,v_prior_discount,v_prior_taxable,v_prior_tax,v_prior_total
    from public.sale_return_items where sale_item_id=v_item.id;
    if v_prior_quantity+v_input.quantity>v_item.quantity then raise exception 'La devolución excede la cantidad disponible de %.',v_item.product_name;end if;
    if v_input.restock and not exists(select 1 from public.inventory_ledger where sale_item_id=v_item.id and movement_type='sale') then
      raise exception 'La partida % no controla inventario y no puede reintegrarse.',v_item.product_name;
    end if;
    if v_input.restock and v_accounting and v_item.recognized_unit_cost is null then
      raise exception 'La partida % no tiene costo reconocido; no puede reintegrarse con contabilidad activa.',v_item.product_name;
    end if;
    if v_prior_quantity+v_input.quantity=v_item.quantity then
      v_gross:=v_item.gross_amount-v_prior_gross;v_discount:=v_item.discount_amount-v_prior_discount;
      v_taxable:=v_item.taxable_amount-v_prior_taxable;v_tax:=v_item.tax_amount-v_prior_tax;v_total:=v_item.total_amount-v_prior_total;
    else
      v_gross:=round(v_item.gross_amount*v_input.quantity/v_item.quantity,2);
      v_discount:=round(v_item.discount_amount*v_input.quantity/v_item.quantity,2);
      v_taxable:=round(v_item.taxable_amount*v_input.quantity/v_item.quantity,2);
      v_tax:=round(v_item.tax_amount*v_input.quantity/v_item.quantity,2);
      v_total:=round(v_item.total_amount*v_input.quantity/v_item.quantity,2);
    end if;
    insert into public.sale_return_items(company_id,sale_return_id,sale_item_id,product_id,quantity,restocked,
      gross_amount,discount_amount,taxable_amount,tax_amount,total_amount,recognized_unit_cost,recognized_cost_amount)
    values(p_company_id,v_return_id,v_item.id,v_item.product_id,v_input.quantity,v_input.restock,
      v_gross,v_discount,v_taxable,v_tax,v_total,v_item.recognized_unit_cost,
      case when v_item.recognized_unit_cost is null then null else round(v_input.quantity*v_item.recognized_unit_cost,6) end)
    returning id into v_return_item_id;
    if v_input.restock then
      insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)
      values(p_company_id,v_sale.location_id,v_item.product_id,v_input.quantity)
      on conflict(location_id,product_id) do update set quantity_on_hand=public.inventory_balances.quantity_on_hand+excluded.quantity_on_hand,updated_at=now()
      returning quantity_on_hand into v_balance;
      insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,sale_return_item_id,actor_id)
      values(p_company_id,v_sale.location_id,v_item.product_id,v_input.quantity,v_balance,'sale_return',v_return_item_id,auth.uid());
      v_restock_cost:=v_restock_cost+coalesce(round(v_input.quantity*v_item.recognized_unit_cost,6),0);
    end if;
    v_gross_sum:=v_gross_sum+v_gross;v_discount_sum:=v_discount_sum+v_discount;v_taxable_sum:=v_taxable_sum+v_taxable;
    v_tax_sum:=v_tax_sum+v_tax;v_total_sum:=v_total_sum+v_total;v_item_count:=v_item_count+1;
  end loop;
  if v_item_count=0 then raise exception 'Selecciona al menos una partida.';end if;
  if v_sale.sale_type='credit' then
    if v_receivable.outstanding_amount<v_total_sum then
      raise exception 'La devolución excede el saldo pendiente; revierte primero los cobros aplicados a esta venta.';
    end if;
    update public.customer_receivables set outstanding_amount=outstanding_amount-v_total_sum where id=v_receivable.id;
  elsif v_kind='cash_refund' and v_total_sum>0 then
    insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,reason,source_entity_type,source_entity_id)
    values(p_company_id,v_session.id,'paid_out',-v_total_sum,auth.uid(),trim(p_reason),'sale_return',v_return_id);
  end if;
  update public.sale_returns set gross_amount=v_gross_sum,discount_amount=v_discount_sum,taxable_amount=v_taxable_sum,
    tax_amount=v_tax_sum,total_amount=v_total_sum,recognized_restock_cost_amount=case
      when exists(select 1 from public.sale_return_items where sale_return_id=v_return_id and restocked and recognized_cost_amount is null) then null
      else v_restock_cost end
  where id=v_return_id returning * into v_existing;
  if v_accounting then
    if v_gross_sum>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_revenue','debit',v_gross_sum,'credit',0,'description','Devolución sobre venta','location_id',v_sale.location_id));end if;
    if v_tax_sum>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role',v_tax_role,'debit',v_tax_sum,'credit',0,'description','Impuesto devuelto','location_id',v_sale.location_id));end if;
    if v_discount_sum>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_discounts','debit',0,'credit',v_discount_sum,'description','Descuento proporcional revertido','location_id',v_sale.location_id));end if;
    if v_total_sum>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role',v_settlement_role,'debit',0,'credit',v_total_sum,'description','Ajuste financiero de devolución','location_id',v_sale.location_id));end if;
    if v_restock_cost>0 then v_lines:=v_lines||jsonb_build_array(
      jsonb_build_object('role','inventory','debit',v_restock_cost,'credit',0,'description','Mercancía recibible reintegrada','location_id',v_sale.location_id),
      jsonb_build_object('role','cost_of_goods_sold','debit',0,'credit',v_restock_cost,'description','Costo reconocido revertido','location_id',v_sale.location_id)
    );end if;
    if jsonb_array_length(v_lines)>=2 then
      perform public.capture_accounting_event(p_company_id,'sale_return_confirmed','sale_return',v_return_id,1,
        v_existing.returned_at::date,v_existing.returned_at,v_lines,
        jsonb_build_object('description','Devolución de venta','sale_id',v_sale.id,'reason',trim(p_reason),'restock_cost',v_restock_cost));
    end if;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'sale.returned','sale_return',v_return_id,jsonb_build_object(
    'sale_id',v_sale.id,'reason',trim(p_reason),'item_count',v_item_count,'total_amount',v_total_sum,
    'financial_adjustment_kind',v_kind,'client_request_id',v_request
  ));
  return to_jsonb(v_existing)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  select * into v_existing from public.sale_returns where company_id=p_company_id and client_request_id=v_request;
  if found then return to_jsonb(v_existing)||jsonb_build_object('idempotent',true);end if;
  raise;
end $$;

create or replace function public.list_sales(
  p_company_id uuid,p_location_id uuid default null,p_query text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));v_total integer;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales') then raise exception 'No autorizado.';end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then raise exception 'No autorizado para esta ubicación.';end if;
  with filtered as (
    select s.id,s.location_id,s.sale_type,s.currency_code,s.total_amount,s.completed_at,c.display_name customer_name,t.folio,
      coalesce((select sum(sr.total_amount) from public.sale_returns sr where sr.sale_id=s.id),0) returned_amount,
      exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id) cancelled
    from public.sales s join public.canonical_tickets t on t.sale_id=s.id left join public.customers c on c.id=s.customer_id
    where s.company_id=p_company_id and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id)
      and (v_query='' or lower(t.folio) like '%'||v_query||'%' or lower(coalesce(c.display_name,'')) like '%'||v_query||'%')
  ) select count(*) into v_total from filtered;
  with filtered as (
    select s.id,s.location_id,s.sale_type,s.currency_code,s.total_amount,s.completed_at,c.display_name customer_name,t.folio,
      coalesce((select sum(sr.total_amount) from public.sale_returns sr where sr.sale_id=s.id),0) returned_amount,
      exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id) cancelled
    from public.sales s join public.canonical_tickets t on t.sale_id=s.id left join public.customers c on c.id=s.customer_id
    where s.company_id=p_company_id and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id)
      and (v_query='' or lower(t.folio) like '%'||v_query||'%' or lower(coalesce(c.display_name,'')) like '%'||v_query||'%')
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'sale_id',p.id,'folio',p.folio,'location_id',p.location_id,'sale_type',p.sale_type,'customer_name',p.customer_name,
    'currency_code',p.currency_code,'total_amount',p.total_amount,'returned_amount',p.returned_amount,'cancelled',p.cancelled,'completed_at',p.completed_at
  ) order by p.completed_at desc),'[]'::jsonb) into v_items
  from(select * from filtered order by completed_at desc limit v_size offset(v_page-1)*v_size)p;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

alter table public.sale_returns enable row level security;
alter table public.sale_return_items enable row level security;
create policy sale_returns_read on public.sale_returns for select to authenticated
  using(public.has_company_permission(company_id,'view_sales') and public.can_access_location(location_id));
create policy sale_return_items_read on public.sale_return_items for select to authenticated
  using(exists(select 1 from public.sale_returns sr where sr.id=sale_return_id and public.has_company_permission(sr.company_id,'view_sales') and public.can_access_location(sr.location_id)));
revoke all on public.sale_returns,public.sale_return_items from public,anon,authenticated;
revoke all on function public.get_sale_return_context(uuid,uuid),public.process_sale_return(uuid,uuid,text,jsonb,uuid,text,uuid) from public,anon;
grant execute on function public.get_sale_return_context(uuid,uuid),public.process_sale_return(uuid,uuid,text,jsonb,uuid,text,uuid) to authenticated;
revoke all on function public.list_sales(uuid,uuid,text,integer,integer) from public,anon;
grant execute on function public.list_sales(uuid,uuid,text,integer,integer) to authenticated;
