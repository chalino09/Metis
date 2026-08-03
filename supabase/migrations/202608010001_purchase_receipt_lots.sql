-- Compras · Lotes y caducidades capturados en la recepción.
-- El control se habilita únicamente para los productos que lo requieren. Los
-- lotes son evidencia de recepción; no se anuncian como disponibilidad hasta
-- que ventas y movimientos de salida también los asignen explícitamente.

begin;

alter table public.products
  add column if not exists lot_controlled boolean not null default false;

comment on column public.products.lot_controlled is
  'Cuando es true, cada recepción del producto exige lotes, caducidad y cantidades que sumen la partida recibida.';

create table if not exists public.purchase_receipt_lots(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  purchase_receipt_line_id uuid not null references public.purchase_receipt_lines(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  lot_code text not null check(length(trim(lot_code)) between 1 and 120),
  expiration_date date not null,
  quantity numeric(18,6) not null check(quantity>0),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  unique(purchase_receipt_line_id,lot_code)
);

create index if not exists purchase_receipt_lots_product_idx
  on public.purchase_receipt_lots(company_id,product_id,expiration_date,created_at desc);

create unique index if not exists audit_product_lot_control_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='product.lot_control_configured' and metadata?'request_id';

create or replace function public.assert_purchase_receipt_lot_integrity()
returns trigger language plpgsql set search_path=public as $$
declare v_line public.purchase_receipt_lines%rowtype; v_receipt public.purchase_receipts%rowtype;
begin
  select * into v_line from public.purchase_receipt_lines where id=new.purchase_receipt_line_id;
  if not found or v_line.company_id<>new.company_id or v_line.product_id<>new.product_id then
    raise exception 'El lote debe pertenecer a la misma partida y producto de recepción.';
  end if;
  select * into v_receipt from public.purchase_receipts where id=v_line.purchase_receipt_id;
  if not found or v_receipt.status<>'draft' then
    raise exception 'Sólo se pueden modificar lotes de recepciones en borrador.';
  end if;
  new.lot_code:=upper(trim(new.lot_code));
  return new;
end $$;

drop trigger if exists purchase_receipt_lots_integrity on public.purchase_receipt_lots;
create trigger purchase_receipt_lots_integrity
before insert or update of company_id,purchase_receipt_line_id,product_id,lot_code,expiration_date,quantity
on public.purchase_receipt_lots for each row execute function public.assert_purchase_receipt_lot_integrity();

alter table public.purchase_receipt_lots enable row level security;
revoke all on public.purchase_receipt_lots from authenticated;
create policy purchase_receipt_lots_read on public.purchase_receipt_lots for select to authenticated using(
  exists(
    select 1 from public.purchase_receipt_lines line
    join public.purchase_receipts receipt on receipt.id=line.purchase_receipt_id
    where line.id=purchase_receipt_line_id
      and public.has_company_permission(receipt.company_id,'view_purchase_receipts')
      and public.can_access_location(receipt.location_id)
  )
);

create or replace function public.set_product_lot_controlled(
  p_company_id uuid, p_product_id uuid, p_lot_controlled boolean,
  p_reason text, p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype; v_replayed jsonb; v_previous boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then
    raise exception 'No autorizado para configurar lotes del producto.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then
    raise exception 'Motivo y referencia idempotente son obligatorios.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,2));
  select to_jsonb(product) into v_replayed
  from public.audit_log audit
  join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id
  where audit.company_id=p_company_id
    and audit.action='product.lot_control_configured'
    and audit.metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true); end if;

  select * into v_product from public.products
  where id=p_product_id and company_id=p_company_id for update;
  if not found then raise exception 'Producto no encontrado.'; end if;
  if coalesce(p_lot_controlled,false) and not v_product.is_inventory_tracked then
    raise exception 'Sólo un producto con existencias puede requerir lotes.';
  end if;
  v_previous:=v_product.lot_controlled;
  update public.products set lot_controlled=coalesce(p_lot_controlled,false),updated_at=now()
  where id=v_product.id returning * into v_product;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'product.lot_control_configured','product',v_product.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),
      'previous',v_previous,'current',v_product.lot_controlled,
      'operational_consequence',case when v_product.lot_controlled
        then 'Las próximas recepciones exigirán lote, caducidad y cantidades por lote.'
        else 'Las próximas recepciones no exigirán lotes; el historial existente se conserva.' end));
  return to_jsonb(v_product)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.save_purchase_receipt(
  p_company_id uuid,p_receipt_id uuid,p_purchase_order_id uuid,p_location_id uuid,p_receipt_date date,
  p_document_reference text default null,p_notes text default null,p_lines jsonb default '[]'::jsonb,
  p_client_request_id uuid default null,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_receipt public.purchase_receipts%rowtype;
  v_order public.purchase_orders%rowtype;
  v_id uuid;
  v_line jsonb;
  v_lot jsonb;
  v_po_line public.purchase_order_lines%rowtype;
  v_receipt_line_id uuid;
  v_qty numeric;
  v_previous numeric;
  v_lot_qty numeric;
  v_lot_total numeric;
  v_expiration date;
  v_lot_count integer:=0;
  v_lot_controlled boolean;
  v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());
  v_before jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts') then
    raise exception 'No autorizado para administrar borradores de recepción.';
  end if;
  if p_receipt_date is null or jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then
    raise exception 'La recepción requiere fecha y al menos una partida.';
  end if;
  select * into v_order from public.purchase_orders
  where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.status<>'approved' then
    raise exception 'Sólo una OC aprobada puede recibirse.';
  end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then
    raise exception 'Ubicación no disponible.';
  end if;
  if p_receipt_id is null then
    select * into v_receipt from public.purchase_receipts
    where company_id=p_company_id and client_request_id=v_request;
    if found then return to_jsonb(v_receipt); end if;
    insert into public.purchase_receipts(company_id,purchase_order_id,supplier_id,location_id,folio,receipt_date,document_reference,notes,client_request_id)
    values(p_company_id,p_purchase_order_id,v_order.supplier_id,p_location_id,public.next_purchase_receipt_folio(p_company_id),p_receipt_date,nullif(trim(p_document_reference),''),nullif(trim(p_notes),''),v_request)
    returning id into v_id;
  else
    select to_jsonb(receipt) into v_before from public.purchase_receipts receipt
    where receipt.id=p_receipt_id and receipt.company_id=p_company_id;
    select * into v_receipt from public.purchase_receipts receipt
    where receipt.id=p_receipt_id and receipt.company_id=p_company_id for update;
    if not found or v_receipt.status<>'draft' or v_receipt.purchase_order_id<>p_purchase_order_id then
      raise exception 'La recepción ya no admite esta edición.';
    end if;
    if p_expected_updated_at is not null and v_receipt.updated_at is distinct from p_expected_updated_at then
      raise exception 'La recepción cambió desde que la abriste.';
    end if;
    v_id:=v_receipt.id;
    update public.purchase_receipts
    set location_id=p_location_id,receipt_date=p_receipt_date,
        document_reference=nullif(trim(p_document_reference),''),notes=nullif(trim(p_notes),''),updated_by=auth.uid()
    where id=v_id;
    delete from public.purchase_receipt_lines where purchase_receipt_id=v_id;
  end if;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    begin v_qty:=round((v_line->>'quantity')::numeric,6); exception when others then raise exception 'Cantidad de recepción inválida.'; end;
    if v_qty<=0 then raise exception 'Las cantidades recibidas deben ser mayores a cero.'; end if;
    select * into v_po_line from public.purchase_order_lines
    where id=nullif(v_line->>'purchase_order_line_id','')::uuid
      and purchase_order_id=p_purchase_order_id and company_id=p_company_id for update;
    if not found or v_po_line.product_id is null then raise exception 'La partida no pertenece a la OC.'; end if;
    select lot_controlled into v_lot_controlled from public.products
    where id=v_po_line.product_id and company_id=p_company_id;
    select coalesce(sum(line.quantity),0) into v_previous
    from public.purchase_receipt_lines line
    join public.purchase_receipts receipt on receipt.id=line.purchase_receipt_id
    where line.purchase_order_line_id=v_po_line.id and receipt.status='confirmed';
    if v_qty>v_po_line.quantity-v_previous then raise exception 'La cantidad recibida supera la cantidad pendiente.'; end if;
    if v_lot_controlled then
      if jsonb_typeof(coalesce(v_line->'lots','null'::jsonb))<>'array' or jsonb_array_length(v_line->'lots')=0 then
        raise exception 'Captura al menos un lote y su caducidad para esta partida.';
      end if;
      select coalesce(sum(round((value->>'quantity')::numeric,6)),0) into v_lot_total
      from jsonb_array_elements(v_line->'lots');
      if abs(v_lot_total-v_qty)>0.000001 then
        raise exception 'Las cantidades de los lotes deben sumar la cantidad recibida.';
      end if;
      if exists(
        select 1 from jsonb_array_elements(v_line->'lots') lot
        group by upper(trim(lot.value->>'lot_code'))
        having count(*)>1
      ) then raise exception 'No repitas un lote dentro de la misma partida.'; end if;
    end if;
    insert into public.purchase_receipt_lines(company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,base_units_per_purchase_unit,unit_cost)
    values(p_company_id,v_id,v_po_line.id,v_po_line.product_id,v_qty,v_po_line.base_units_per_purchase_unit,
      round(v_po_line.unit_cost*(1-v_po_line.discount_percent_1/100)*(1-v_po_line.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6))
    returning id into v_receipt_line_id;
    if v_lot_controlled then
      for v_lot in select value from jsonb_array_elements(v_line->'lots') loop
        begin v_lot_qty:=round((v_lot->>'quantity')::numeric,6); exception when others then raise exception 'Cantidad de lote inválida.'; end;
        if nullif(trim(coalesce(v_lot->>'lot_code','')),'') is null then raise exception 'El código de lote es obligatorio.'; end if;
        if length(trim(v_lot->>'lot_code'))>120 then raise exception 'El código de lote admite hasta 120 caracteres.'; end if;
        if nullif(trim(coalesce(v_lot->>'expiration_date','')),'') is null then raise exception 'La fecha de caducidad es obligatoria y no es válida.'; end if;
        begin
          v_expiration:=(v_lot->>'expiration_date')::date;
          if v_expiration<p_receipt_date then raise exception 'La caducidad no puede ser anterior a la recepción.'; end if;
        exception when invalid_text_representation or datetime_field_overflow then
          raise exception 'La fecha de caducidad es obligatoria y no es válida.';
        end;
        if v_lot_qty<=0 then raise exception 'Las cantidades por lote deben ser mayores a cero.'; end if;
        insert into public.purchase_receipt_lots(company_id,purchase_receipt_line_id,product_id,lot_code,expiration_date,quantity)
        values(p_company_id,v_receipt_line_id,v_po_line.product_id,upper(trim(v_lot->>'lot_code')),v_expiration,v_lot_qty);
        v_lot_count:=v_lot_count+1;
      end loop;
    end if;
  end loop;
  select * into v_receipt from public.purchase_receipts where id=v_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),case when p_receipt_id is null then 'purchase_receipt.draft_created' else 'purchase_receipt.draft_updated' end,
    'purchase_receipt',v_id,jsonb_build_object('before',v_before,'line_count',jsonb_array_length(p_lines),'lot_count',v_lot_count,'client_request_id',v_request));
  return to_jsonb(v_receipt);
end $$;

create or replace function public.confirm_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_balance numeric;v_pending numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_fulfillment text;v_now timestamptz:=clock_timestamp();v_old_cost numeric;v_cost_id uuid;v_cost record;v_lot_quantity numeric;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_purchase_receipts') then raise exception 'No autorizado para confirmar recepciones.';end if;
  select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id for update;
  if not found then raise exception 'Recepción no encontrada.';end if;
  if v_receipt.confirm_request_id=v_request and v_receipt.status in ('confirmed','reversed') then return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status,'idempotent',true,'fulfillment_status',(select fulfillment_status from public.purchase_orders where id=v_receipt.purchase_order_id));end if;
  if v_receipt.status<>'draft' or not public.can_access_location(v_receipt.location_id) then raise exception 'La recepción no está disponible para confirmarse.';end if;
  select * into v_order from public.purchase_orders where id=v_receipt.purchase_order_id and company_id=p_company_id for update;
  if v_order.status<>'approved' or not exists(select 1 from public.purchase_receipt_lines where purchase_receipt_id=v_receipt.id) then raise exception 'La recepción no se puede confirmar.';end if;
  for v_line in
    select line.*,order_line.quantity ordered_quantity,product.lot_controlled
    from public.purchase_receipt_lines line
    join public.purchase_order_lines order_line on order_line.id=line.purchase_order_line_id
    join public.products product on product.id=line.product_id
    where line.purchase_receipt_id=v_receipt.id order by line.purchase_order_line_id for update of order_line
  loop
    select v_line.ordered_quantity-coalesce(sum(other.quantity),0) into v_pending from public.purchase_receipt_lines other join public.purchase_receipts receipt on receipt.id=other.purchase_receipt_id where other.purchase_order_line_id=v_line.purchase_order_line_id and receipt.status='confirmed';
    if v_line.quantity>v_pending then raise exception 'La cantidad recibida supera la cantidad pendiente.';end if;
    if v_line.lot_controlled then
      select coalesce(sum(lot.quantity),0) into v_lot_quantity from public.purchase_receipt_lots lot where lot.purchase_receipt_line_id=v_line.id;
      if abs(v_lot_quantity-v_line.quantity)>0.000001 then raise exception 'Faltan lotes o sus cantidades no coinciden con la partida recibida.'; end if;
    end if;
    insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(p_company_id,v_receipt.location_id,v_line.product_id,0) on conflict(location_id,product_id) do nothing;
    select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_receipt.location_id and product_id=v_line.product_id for update;
    update public.inventory_balances set quantity_on_hand=v_balance+v_line.inventory_quantity,updated_at=v_now where location_id=v_receipt.location_id and product_id=v_line.product_id;
    insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,purchase_receipt_line_id,purchase_receipt_id,purchase_order_id,supplier_id,occurred_at,actor_id)
    values(p_company_id,v_receipt.location_id,v_line.product_id,v_line.inventory_quantity,v_balance+v_line.inventory_quantity,'purchase_receipt',v_line.id,v_receipt.id,v_order.id,v_order.supplier_id,v_now,auth.uid());
  end loop;
  for v_cost in select line.product_id,v_order.currency_code,round(sum(line.line_cost)/sum(line.inventory_quantity),6) amount from public.purchase_receipt_lines line where line.purchase_receipt_id=v_receipt.id group by line.product_id loop
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

create or replace function public.get_purchase_receipt_detail(p_company_id uuid,p_receipt_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_can_cost boolean;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id and public.can_access_location(location_id);if not found then raise exception 'Recepción no encontrada.';end if;
  v_can_cost:=public.has_company_permission(p_company_id,'view_costs');
  select to_jsonb(receipt)||jsonb_build_object(
    'purchase_order',jsonb_build_object('id',purchase_order.id,'folio',purchase_order.folio,'status',purchase_order.status,'fulfillment_status',purchase_order.fulfillment_status,'origin',purchase_order.origin),
    'supplier',jsonb_build_object('id',supplier.id,'code',supplier.code,'display_name',supplier.display_name),
    'location',jsonb_build_object('id',location.id,'code',location.external_code,'name',location.name),
    'lines',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',line.id,'purchase_order_line_id',line.purchase_order_line_id,'product_id',line.product_id,
      'product_code',coalesce(product.internal_sku,product.alpha_sku),'product_name',product.name,'lot_controlled',product.lot_controlled,
      'ordered_quantity',order_line.quantity,'previously_received',coalesce((select sum(previous.quantity) from public.purchase_receipt_lines previous join public.purchase_receipts previous_receipt on previous_receipt.id=previous.purchase_receipt_id where previous.purchase_order_line_id=order_line.id and previous_receipt.status='confirmed' and previous_receipt.id<>receipt.id),0),
      'current_quantity',line.quantity,'pending_quantity',order_line.quantity-coalesce((select sum(previous.quantity) from public.purchase_receipt_lines previous join public.purchase_receipts previous_receipt on previous_receipt.id=previous.purchase_receipt_id where previous.purchase_order_line_id=order_line.id and previous_receipt.status='confirmed'),0),
      'unit_cost',case when v_can_cost then line.unit_cost else null end,'line_cost',case when v_can_cost then line.line_cost else null end,
      'lots',(select coalesce(jsonb_agg(jsonb_build_object('id',lot.id,'lot_code',lot.lot_code,'expiration_date',lot.expiration_date,'quantity',lot.quantity) order by lot.expiration_date,lot.lot_code),'[]'::jsonb) from public.purchase_receipt_lots lot where lot.purchase_receipt_line_id=line.id)
    ) order by order_line.line_number),'[]'::jsonb)
    from public.purchase_receipt_lines line join public.purchase_order_lines order_line on order_line.id=line.purchase_order_line_id join public.products product on product.id=line.product_id where line.purchase_receipt_id=receipt.id),
    'movements',(select coalesce(jsonb_agg(jsonb_build_object('id',ledger.id,'movement_type',ledger.movement_type,'product_id',ledger.product_id,'quantity_delta',ledger.quantity_delta,'balance_after',ledger.balance_after,'occurred_at',ledger.occurred_at) order by ledger.occurred_at,ledger.id),'[]'::jsonb) from public.inventory_ledger ledger where ledger.purchase_receipt_id=receipt.id)
  ) into v_result
  from public.purchase_receipts receipt join public.purchase_orders purchase_order on purchase_order.id=receipt.purchase_order_id join public.suppliers supplier on supplier.id=receipt.supplier_id join public.locations location on location.id=receipt.location_id
  where receipt.id=v_receipt.id;
  return v_result;
end $$;

create or replace function public.get_receivable_purchase_order(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id;if not found then raise exception 'OC no encontrada.';end if;
  select jsonb_build_object(
    'purchase_order_id',v_order.id,'folio',v_order.folio,'status',v_order.status,'fulfillment_status',v_order.fulfillment_status,'origin',v_order.origin,
    'historical_receipt_gap',v_order.origin='imported_historical','historical_receipt_gap_note',case when v_order.origin='imported_historical' then 'Los estados Alpha son evidencia; no se promovieron recepciones ni movimientos históricos.' end,
    'lines',coalesce(jsonb_agg(jsonb_build_object(
      'id',order_line.id,'line_number',order_line.line_number,'product_id',order_line.product_id,'description',order_line.description,'unit',order_line.unit,
      'ordered_quantity',order_line.quantity,'previously_received',coalesce(received.received,0),'pending_quantity',order_line.quantity-coalesce(received.received,0),
      'unit_cost',case when public.has_company_permission(p_company_id,'view_costs') then round(order_line.unit_cost*(1-order_line.discount_percent_1/100)*(1-order_line.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6) else null end,
      'lot_controlled',product.lot_controlled,
      'lot_suggestions',(select coalesce(jsonb_agg(jsonb_build_object('lot_code',suggestion.lot_code,'expiration_date',suggestion.expiration_date) order by suggestion.expiration_date,suggestion.lot_code),'[]'::jsonb)
        from (select distinct lot.lot_code,lot.expiration_date from public.purchase_receipt_lots lot join public.purchase_receipt_lines received_line on received_line.id=lot.purchase_receipt_line_id join public.purchase_receipts received_receipt on received_receipt.id=received_line.purchase_receipt_id where lot.company_id=p_company_id and lot.product_id=order_line.product_id and received_receipt.status='confirmed' order by lot.expiration_date,lot.lot_code limit 8) suggestion)
    ) order by order_line.line_number),'[]'::jsonb)
  ) into v_result
  from public.purchase_order_lines order_line
  join public.products product on product.id=order_line.product_id
  left join lateral(select sum(receipt_line.quantity) received from public.purchase_receipt_lines receipt_line join public.purchase_receipts receipt on receipt.id=receipt_line.purchase_receipt_id where receipt_line.purchase_order_line_id=order_line.id and receipt.status='confirmed') received on true
  where order_line.purchase_order_id=v_order.id;
  return v_result;
end $$;

revoke all on function public.set_product_lot_controlled(uuid,uuid,boolean,text,uuid) from public;
revoke all on function public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz) from public;
revoke all on function public.confirm_purchase_receipt(uuid,uuid,uuid) from public;
revoke all on function public.get_purchase_receipt_detail(uuid,uuid) from public;
revoke all on function public.get_receivable_purchase_order(uuid,uuid) from public;
grant execute on function public.set_product_lot_controlled(uuid,uuid,boolean,text,uuid) to authenticated;
grant execute on function public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz) to authenticated;
grant execute on function public.confirm_purchase_receipt(uuid,uuid,uuid) to authenticated;
grant execute on function public.get_purchase_receipt_detail(uuid,uuid) to authenticated;
grant execute on function public.get_receivable_purchase_order(uuid,uuid) to authenticated;

commit;
