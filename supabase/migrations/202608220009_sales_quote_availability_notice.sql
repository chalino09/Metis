-- Satrapy · Disponibilidad visible durante toda la cotización.
-- La existencia es informativa: no bloquea la propuesta ni reserva mercancía.

begin;

create or replace function public.get_sales_quote_detail(p_company_id uuid, p_quote_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype;
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotización no disponible.'; end if;
  return jsonb_build_object(
    'id', v_quote.id, 'folio', v_quote.folio, 'status', v_quote.status, 'currency_code', v_quote.currency_code,
    'valid_until', v_quote.valid_until, 'subtotal_amount', v_quote.subtotal_amount, 'tax_amount', v_quote.tax_amount,
    'total_amount', v_quote.total_amount, 'approved_at', v_quote.approved_at,
    'approved_by', (select jsonb_build_object('id', profile_data.id, 'name', profile_data.full_name) from public.profiles profile_data where profile_data.id = v_quote.approved_by),
    'updated_at', v_quote.updated_at,
    'supply_status', case when exists(
      select 1
      from public.sales_quote_lines quote_line
      join public.products product_data on product_data.id = quote_line.product_id and product_data.is_inventory_tracked
      left join public.inventory_balances balance on balance.location_id = v_quote.location_id and balance.product_id = quote_line.product_id
      where quote_line.quote_id = v_quote.id
        and greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0) < quote_line.quantity
    ) then 'pending' else 'available' end,
    'shortage_line_count', (
      select count(*)
      from public.sales_quote_lines quote_line
      join public.products product_data on product_data.id = quote_line.product_id and product_data.is_inventory_tracked
      left join public.inventory_balances balance on balance.location_id = v_quote.location_id and balance.product_id = quote_line.product_id
      where quote_line.quote_id = v_quote.id
        and greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0) < quote_line.quantity
    ),
    'customer', (select jsonb_build_object('id', customer_data.id, 'code', customer_data.code, 'display_name', customer_data.display_name) from public.customers customer_data where customer_data.id = v_quote.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_quote.location_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', line_data.id, 'product_id', line_data.product_id, 'product_code', line_data.product_code,
        'product_name', line_data.product_name, 'unit_name', line_data.unit_name, 'quantity', line_data.quantity,
        'unit_total_amount', line_data.unit_total_amount, 'line_total_amount', line_data.line_total_amount,
        'inventory_tracked', product_data.is_inventory_tracked,
        'quantity_on_hand', case when product_data.is_inventory_tracked then coalesce(balance.quantity_on_hand, 0) else null end,
        'available_quantity', case when product_data.is_inventory_tracked then greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0) else null end,
        'shortage_quantity', case when product_data.is_inventory_tracked then greatest(line_data.quantity - greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0), 0) else 0 end,
        'availability_status', case
          when not product_data.is_inventory_tracked then 'not_applicable'
          when greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0) >= line_data.quantity then 'available'
          when greatest(coalesce(balance.quantity_on_hand, 0) - coalesce(balance.quantity_reserved, 0), 0) <= 0 then 'unavailable'
          else 'partial'
        end
      ) order by line_data.created_at, line_data.id)
      from public.sales_quote_lines line_data
      join public.products product_data on product_data.id = line_data.product_id
      left join public.inventory_balances balance on balance.location_id = v_quote.location_id and balance.product_id = line_data.product_id
      where line_data.quote_id = v_quote.id
    ), '[]'::jsonb),
    'follow_ups', coalesce((select jsonb_agg(jsonb_build_object('id', follow_up.id, 'event_type', follow_up.event_type, 'reason_code', follow_up.reason_code, 'note', follow_up.note, 'created_at', follow_up.created_at, 'actor_name', profile_data.full_name) order by follow_up.created_at desc, follow_up.id desc) from public.sales_quote_follow_ups follow_up left join public.profiles profile_data on profile_data.id = follow_up.created_by where follow_up.quote_id = v_quote.id), '[]'::jsonb),
    'order', (select jsonb_build_object('id', order_data.id, 'folio', order_data.folio, 'status', order_data.status) from public.sales_deposit_orders order_data where order_data.company_id = p_company_id and order_data.source_quote_id = v_quote.id)
  );
end $$;

grant execute on function public.get_sales_quote_detail(uuid, uuid) to authenticated;

commit;
