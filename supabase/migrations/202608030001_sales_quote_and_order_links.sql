-- Satrapy · Conexiones visibles entre cotizaciones y pedidos.
-- Las entidades permanecen separadas; se exponen sus vínculos canónicos para navegación operativa.

begin;

create or replace function public.get_sales_quote_detail(p_company_id uuid, p_quote_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype;
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotización no disponible.'; end if;
  return jsonb_build_object(
    'id', v_quote.id, 'folio', v_quote.folio, 'status', v_quote.status, 'currency_code', v_quote.currency_code, 'valid_until', v_quote.valid_until, 'subtotal_amount', v_quote.subtotal_amount, 'tax_amount', v_quote.tax_amount, 'total_amount', v_quote.total_amount, 'updated_at', v_quote.updated_at,
    'customer', (select jsonb_build_object('id', customer_data.id, 'code', customer_data.code, 'display_name', customer_data.display_name) from public.customers customer_data where customer_data.id = v_quote.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_quote.location_id),
    'order', (select jsonb_build_object('id', order_data.id, 'folio', order_data.folio, 'status', order_data.status) from public.sales_deposit_orders order_data where order_data.company_id = p_company_id and order_data.source_quote_id = v_quote.id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', line_data.id, 'product_id', line_data.product_id, 'product_code', line_data.product_code, 'product_name', line_data.product_name, 'unit_name', line_data.unit_name, 'quantity', line_data.quantity, 'unit_total_amount', line_data.unit_total_amount, 'line_total_amount', line_data.line_total_amount) order by line_data.created_at, line_data.id) from public.sales_quote_lines line_data where line_data.quote_id = v_quote.id), '[]'::jsonb),
    'follow_ups', coalesce((select jsonb_agg(jsonb_build_object('id', follow_up.id, 'event_type', follow_up.event_type, 'reason_code', follow_up.reason_code, 'note', follow_up.note, 'created_at', follow_up.created_at, 'actor_name', profile_data.full_name) order by follow_up.created_at desc, follow_up.id desc) from public.sales_quote_follow_ups follow_up left join public.profiles profile_data on profile_data.id = follow_up.created_by where follow_up.quote_id = v_quote.id), '[]'::jsonb)
  );
end $$;

create or replace function public.get_sales_deposit_order_detail(p_company_id uuid, p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_order public.sales_deposit_orders%rowtype;
begin
  select * into v_order from public.sales_deposit_orders where id = p_order_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible.'; end if;
  return jsonb_build_object(
    'id', v_order.id, 'folio', v_order.folio, 'status', v_order.status,
    'expected_delivery_date', v_order.expected_delivery_date, 'currency_code', v_order.currency_code,
    'subtotal_amount', v_order.subtotal_amount, 'tax_amount', v_order.tax_amount, 'total_amount', v_order.total_amount,
    'paid_amount', v_order.paid_amount, 'outstanding_amount', round(v_order.total_amount - v_order.paid_amount, 2),
    'sale_id', v_order.sale_id, 'created_at', v_order.created_at, 'completed_at', v_order.completed_at,
    'source', case when v_order.source_quote_id is not null then (select jsonb_build_object('kind', 'quote', 'id', quote_data.id, 'folio', quote_data.folio) from public.sales_quotes quote_data where quote_data.id = v_order.source_quote_id) else jsonb_build_object('kind', 'pos') end,
    'customer', (select jsonb_build_object('id', customer.id, 'code', customer.code, 'display_name', customer.display_name) from public.customers customer where customer.id = v_order.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_order.location_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', line.id, 'product_id', line.product_id, 'product_code', line.product_code, 'product_name', line.product_name, 'unit_name', line.unit_name, 'quantity', line.quantity, 'unit_total_amount', line.unit_total_amount, 'line_total_amount', line.line_total_amount) order by line.created_at, line.id) from public.sales_deposit_order_lines line where line.order_id = v_order.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', payment.id, 'payment_kind', payment.payment_kind, 'payment_method_id', payment.payment_method_id, 'payment_method_name', payment.payment_method_name, 'settlement_kind', payment.settlement_kind, 'amount', payment.amount, 'payment_reference', payment.payment_reference, 'received_at', payment.received_at) order by payment.received_at desc, payment.id desc) from public.sales_deposit_order_payments payment where payment.order_id = v_order.id), '[]'::jsonb)
  );
end $$;

commit;
