\set ON_ERROR_STOP on
do $verify$
declare v public.m3d_concurrency_context%rowtype;
begin
  select * into v from public.m3d_concurrency_context;
  if (select count(*) from public.accounts_payable where supplier_invoice_id=v.invoice_same)<>1 then raise exception 'La confirmación idempotente duplicó CxP.';end if;
  if (select count(*) from public.supplier_invoices where id in(v.invoice_a,v.invoice_b) and status='confirmed')<>1 then raise exception 'Dos facturas consumieron el mismo pendiente.';end if;
  if (select sum(sil.quantity) from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=v.receipt_line_id and si.status='confirmed')<>10 then raise exception 'La concurrencia perdió o duplicó cantidades.';end if;
  if (select count(*) from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id where si.id in(v.invoice_same,v.invoice_a,v.invoice_b))<>2 then raise exception 'La concurrencia duplicó obligaciones.';end if;
  if (select count(*) from public.inventory_ledger where company_id=v.company_id)<>v.ledger_count or (select count(*) from public.product_costs where company_id=v.company_id)<>v.cost_count then raise exception 'La facturación concurrente modificó inventario o costo.';end if;
end $verify$;
