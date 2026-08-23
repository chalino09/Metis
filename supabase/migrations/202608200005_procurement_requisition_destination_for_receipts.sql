-- La solicitud es la fuente de verdad del destino; la cotización y la OC la conservan por trazabilidad.
create or replace function public.get_receivable_purchase_order(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_order public.purchase_orders%rowtype;
  v_result jsonb;
  v_destination_location_id uuid;
  v_destination_location_name text;
  v_destination_location_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_purchase_receipts') then raise exception 'No autorizado para consultar recepciones.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id;
  if not found then raise exception 'OC no encontrada.';end if;

  select requisition.location_id,location.name,location.external_code
  into v_destination_location_id,v_destination_location_name,v_destination_location_code
  from public.procurement_purchase_orders procurement_order
  join public.procurement_awards award on award.id=procurement_order.procurement_award_id and award.company_id=p_company_id
  join public.procurement_requisitions requisition on requisition.id=award.requisition_id and requisition.company_id=p_company_id
  join public.locations location on location.id=requisition.location_id and location.company_id=p_company_id
  where procurement_order.purchase_order_id=v_order.id
    and procurement_order.company_id=p_company_id
    and public.can_access_location(requisition.location_id)
  limit 1;

  select jsonb_build_object(
    'purchase_order_id',v_order.id,'folio',v_order.folio,'status',v_order.status,'fulfillment_status',v_order.fulfillment_status,'origin',v_order.origin,
    'destination_location_id',v_destination_location_id,'destination_location_name',v_destination_location_name,'destination_location_code',v_destination_location_code,
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
