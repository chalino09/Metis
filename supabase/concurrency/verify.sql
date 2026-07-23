\set ON_ERROR_STOP on
do $assert$
declare v_last_sales integer; v_idem_sales integer; v_last_balance numeric; v_idem_balance numeric; v_idem_tickets integer;
begin
  select count(*) into v_last_sales from public.sale_items where product_id='24000000-0000-4000-8000-000000000007';
  select count(*) into v_idem_sales from public.sale_items where product_id='24000000-0000-4000-8000-000000000008';
  select quantity_on_hand into v_last_balance from public.inventory_balances where product_id='24000000-0000-4000-8000-000000000007' and location_id='24000000-0000-4000-8000-000000000006';
  select quantity_on_hand into v_idem_balance from public.inventory_balances where product_id='24000000-0000-4000-8000-000000000008' and location_id='24000000-0000-4000-8000-000000000006';
  select count(*) into v_idem_tickets from public.canonical_tickets t join public.sales s on s.id=t.sale_id where s.client_request_id='24000000-0000-4000-8000-000000000033';
  if v_last_sales<>1 or v_last_balance<>0 then raise exception 'La contención de última existencia falló: ventas %, saldo %',v_last_sales,v_last_balance; end if;
  if v_idem_sales<>1 or v_idem_balance<>0 or v_idem_tickets<>1 then raise exception 'La idempotencia concurrente duplicó efectos: ventas %, saldo %, tickets %',v_idem_sales,v_idem_balance,v_idem_tickets; end if;
  if exists(select 1 from public.inventory_balances where quantity_on_hand<0) then raise exception 'La concurrencia produjo inventario negativo.'; end if;
end $assert$;
