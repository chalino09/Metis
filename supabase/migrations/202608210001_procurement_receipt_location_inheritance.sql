-- La recepción de una OC originada en abastecimiento conserva la ubicación
-- definida en la solicitud. Las OCs manuales o históricas continúan permitiendo
-- seleccionar una ubicación al recibir.

create or replace function public.assert_purchase_receipt_integrity()
returns trigger language plpgsql set search_path=public as $$
declare
  v_order public.purchase_orders%rowtype;
  v_receipt public.purchase_receipts%rowtype;
  v_line public.purchase_order_lines%rowtype;
  v_expected_location_id uuid;
begin
  if tg_table_name='purchase_receipts' then
    select * into v_order from public.purchase_orders where id=new.purchase_order_id;
    if not found or v_order.company_id<>new.company_id or v_order.supplier_id<>new.supplier_id then
      raise exception 'La recepción, OC y proveedor deben pertenecer a la misma empresa.';
    end if;
    if not exists(select 1 from public.locations l where l.id=new.location_id and l.company_id=new.company_id and l.is_active) then
      raise exception 'La ubicación no pertenece a la empresa o está inactiva.';
    end if;

    select source.location_id
      into v_expected_location_id
      from (
        select requisition.location_id,1 priority
          from public.procurement_purchase_orders link
          join public.procurement_awards award on award.id=link.procurement_award_id
          join public.procurement_requisitions requisition on requisition.id=award.requisition_id
         where link.purchase_order_id=new.purchase_order_id and link.company_id=new.company_id
        union all
        select requisition.location_id,2 priority
          from public.procurement_requisitions requisition
         where requisition.company_id=new.company_id
           and requisition.folio=v_order.requisition_reference
      ) source
     order by source.priority
     limit 1;

    if v_expected_location_id is not null and new.location_id<>v_expected_location_id then
      raise exception 'El almacén de recepción debe coincidir con la ubicación definida en la solicitud de compra.';
    end if;
  else
    select * into v_receipt from public.purchase_receipts where id=new.purchase_receipt_id;
    select * into v_line from public.purchase_order_lines where id=new.purchase_order_line_id;
    if not found or v_receipt.company_id<>new.company_id or v_line.company_id<>new.company_id or v_line.purchase_order_id<>v_receipt.purchase_order_id or v_line.product_id is distinct from new.product_id then
      raise exception 'La partida no pertenece a la OC de la recepción.';
    end if;
  end if;
  return new;
end $$;

create or replace function public.get_receivable_purchase_order(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_order public.purchase_orders%rowtype;
  v_result jsonb;
  v_inherited_location_id uuid;
  v_inherited_location_name text;
  v_inherited_location_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then
    raise exception 'No autorizado para consultar recepciones.';
  end if;

  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id;
  if not found then raise exception 'OC no encontrada.';end if;

  select source.location_id,location.name,location.external_code
    into v_inherited_location_id,v_inherited_location_name,v_inherited_location_code
    from (
      select requisition.location_id,1 priority
        from public.procurement_purchase_orders link
        join public.procurement_awards award on award.id=link.procurement_award_id
        join public.procurement_requisitions requisition on requisition.id=award.requisition_id
       where link.purchase_order_id=v_order.id and link.company_id=p_company_id
      union all
      select requisition.location_id,2 priority
        from public.procurement_requisitions requisition
       where requisition.company_id=p_company_id
         and requisition.folio=v_order.requisition_reference
    ) source
    join public.locations location on location.id=source.location_id
   order by source.priority
   limit 1;

  select jsonb_build_object(
    'purchase_order_id',v_order.id,
    'folio',v_order.folio,
    'status',v_order.status,
    'fulfillment_status',v_order.fulfillment_status,
    'origin',v_order.origin,
    'inherited_location_id',v_inherited_location_id,
    'inherited_location_name',v_inherited_location_name,
    'inherited_location_code',v_inherited_location_code,
    'historical_receipt_gap',v_order.origin='imported_historical',
    'historical_receipt_gap_note',case when v_order.origin='imported_historical' then 'Los estados Alpha son evidencia; no se promovieron recepciones ni movimientos históricos.' end,
    'lines',coalesce(jsonb_agg(jsonb_build_object(
      'id',order_line.id,
      'line_number',order_line.line_number,
      'product_id',order_line.product_id,
      'description',order_line.description,
      'unit',order_line.unit,
      'ordered_quantity',order_line.quantity,
      'previously_received',coalesce(received.received,0),
      'pending_quantity',order_line.quantity-coalesce(received.received,0),
      'unit_cost',case when public.has_company_permission(p_company_id,'view_costs') then round(order_line.unit_cost*(1-order_line.discount_percent_1/100)*(1-order_line.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6) else null end,
      'lot_controlled',product.lot_controlled,
      'lot_suggestions',(select coalesce(jsonb_agg(jsonb_build_object('lot_code',suggestion.lot_code,'expiration_date',suggestion.expiration_date) order by suggestion.expiration_date,suggestion.lot_code),'[]'::jsonb)
        from (select distinct lot.lot_code,lot.expiration_date from public.purchase_receipt_lots lot join public.purchase_receipt_lines received_line on received_line.id=lot.purchase_receipt_line_id join public.purchase_receipts received_receipt on received_receipt.id=received_line.purchase_receipt_id where lot.company_id=p_company_id and lot.product_id=order_line.product_id and received_receipt.status='confirmed' order by lot.expiration_date,lot.lot_code limit 8) suggestion)
    ) order by order_line.line_number),'[]'::jsonb)
  ) into v_result
  from public.purchase_order_lines order_line
  join public.products product on product.id=order_line.product_id
  left join lateral(
    select sum(receipt_line.quantity) received
      from public.purchase_receipt_lines receipt_line
      join public.purchase_receipts receipt on receipt.id=receipt_line.purchase_receipt_id
     where receipt_line.purchase_order_line_id=order_line.id
       and receipt.status='confirmed'
  ) received on true
  where order_line.purchase_order_id=v_order.id;

  return v_result;
end $$;

revoke all on function public.get_receivable_purchase_order(uuid,uuid) from public;
grant execute on function public.get_receivable_purchase_order(uuid,uuid) to authenticated;
