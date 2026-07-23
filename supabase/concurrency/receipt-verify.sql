\set ON_ERROR_STOP on
do $verify$
declare v public.m3c_concurrency_context%rowtype;
begin
  select * into v from public.m3c_concurrency_context;
  if (select quantity_on_hand from public.inventory_balances where location_id=v.location_id and product_id=v.product_id)<>10 then raise exception 'Concurrencia duplicó o perdió existencias.';end if;
  if (select count(*) from public.inventory_ledger where purchase_order_id=v.order_id and movement_type='purchase_receipt')<>2 then raise exception 'Concurrencia duplicó movimientos.';end if;
  if (select count(*) from public.purchase_receipts where id in(v.receipt_a,v.receipt_b) and status='confirmed')<>1 then raise exception 'Dos recepciones consumieron el mismo pendiente.';end if;
  if (select fulfillment_status from public.purchase_orders where id=v.order_id)<>'fully_received' then raise exception 'Cumplimiento concurrente incorrecto.';end if;
end $verify$;
