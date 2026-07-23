-- M4B · captura automática de eventos ya confirmados por M1–M3.
-- Los triggers son diferidos: ven el documento completo y la póliza forma parte
-- de la misma transacción. Sin matriz M4B aprobada, la operación actual no cambia.

create or replace function public.accounting_operational_matrix_active(p_company_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.accounting_event_rule_sets where company_id=p_company_id and status='approved')
$$;

create or replace function public.capture_exact_accounting_reversal(
  p_company_id uuid,p_original_event_type text,p_reversal_event_type text,
  p_source_entity_type text,p_source_entity_id uuid,p_accounting_date date,
  p_occurred_at timestamptz,p_description text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_original public.accounting_events%rowtype;v_lines jsonb;v_result jsonb;
begin
  select * into v_original from public.accounting_events where company_id=p_company_id and event_type=p_original_event_type and source_entity_type=p_source_entity_type and source_entity_id=p_source_entity_id and status='posted' order by source_version desc limit 1;
  if not found then raise exception 'No existe contabilización original para revertir.';end if;
  select jsonb_agg(jsonb_build_object('role',line->>'role','debit',coalesce((line->>'credit')::numeric,0),'credit',coalesce((line->>'debit')::numeric,0),'description',coalesce(nullif(line->>'description',''),p_description)) order by ordinal) into v_lines from jsonb_array_elements(v_original.requested_lines) with ordinality as x(line,ordinal);
  v_result:=public.capture_accounting_event(p_company_id,p_reversal_event_type,p_source_entity_type,p_source_entity_id,1,p_accounting_date,p_occurred_at,v_lines,jsonb_build_object('description',p_description,'reverses_event_id',v_original.id));
  update public.accounting_events set original_event_id=v_original.id where id=(v_result->>'id')::uuid and original_event_id is null;
  return v_result;
end $$;

create or replace function public.capture_sale_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_set public.accounting_event_rule_sets%rowtype;v_config public.accounting_config_versions%rowtype;v_payment public.sale_payments%rowtype;v_cost numeric:=0;v_items int:=0;v_costed int:=0;v_settlement text;v_tax_role text;v_lines jsonb;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=new.company_id and status='approved';select * into v_config from public.accounting_config_versions where id=v_set.accounting_config_version_id;
  if new.currency_code<>v_config.base_currency then raise exception 'La venta debe estar en la moneda base contable.';end if;
  select coalesce(sum(si.quantity*pc.amount),0),count(*),count(pc.amount) into v_cost,v_items,v_costed from public.sale_items si left join lateral(select amount from public.product_costs where company_id=new.company_id and product_id=si.product_id and cost_type=v_set.cost_method and currency_code=new.currency_code and valid_from<=new.completed_at and (valid_to is null or valid_to>new.completed_at) order by valid_from desc limit 1)pc on true where si.sale_id=new.id;
  if v_items=0 or v_costed<>v_items then raise exception 'La venta no puede contabilizarse: falta costo vigente para una o más partidas.';end if;
  if new.sale_type='cash' then select * into v_payment from public.sale_payments where sale_id=new.id;if not found then raise exception 'La venta de contado no tiene liquidación.';end if;v_settlement:=case when v_payment.settlement_kind='cash_drawer' then 'cash' else 'banks' end;v_tax_role:='vat_collected';else v_settlement:='accounts_receivable';v_tax_role:='vat_pending';end if;
  v_lines:=jsonb_build_array(jsonb_build_object('role',v_settlement,'debit',new.total_amount,'credit',0,'description','Liquidación de venta'));
  if new.discount_amount>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_discounts','debit',new.discount_amount,'credit',0,'description','Descuento comercial'));end if;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_revenue','debit',0,'credit',new.subtotal_amount,'description','Venta'));if new.tax_amount>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role',v_tax_role,'debit',0,'credit',new.tax_amount,'description','IVA de venta'));end if;
  if round(v_cost,6)>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','cost_of_goods_sold','debit',round(v_cost,6),'credit',0,'description','Costo de venta'),jsonb_build_object('role','inventory','debit',0,'credit',round(v_cost,6),'description','Salida de inventario'));end if;
  perform public.capture_accounting_event(new.company_id,'sale_confirmed','sale',new.id,1,new.completed_at::date,new.completed_at,v_lines,jsonb_build_object('description','Venta confirmada','sale_type',new.sale_type,'cost_method',v_set.cost_method));return new;
end $$;
create constraint trigger sales_accounting_event after insert on public.sales deferrable initially deferred for each row execute function public.capture_sale_accounting_event();

create or replace function public.capture_receivable_payment_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_role text;v_lines jsonb;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  v_role:=case when new.settlement_kind='cash_drawer' then 'cash' else 'banks' end;
  v_lines:=jsonb_build_array(jsonb_build_object('role',v_role,'debit',new.amount,'credit',0,'description','Cobro recibido'),jsonb_build_object('role','accounts_receivable','debit',0,'credit',new.amount,'description','Aplicación a CxC'));
  perform public.capture_accounting_event(new.company_id,'receivable_payment_confirmed','receivable_payment',new.id,1,new.received_at::date,new.received_at,v_lines,jsonb_build_object('description','Cobro confirmado','settlement_kind',new.settlement_kind));return new;
end $$;
create constraint trigger receivable_payments_accounting_event after insert on public.receivable_payments deferrable initially deferred for each row execute function public.capture_receivable_payment_accounting_event();

create or replace function public.capture_cash_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_lines jsonb;v_expected numeric;v_counted numeric;v_variance numeric;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if tg_op='INSERT' then
    if new.opening_amount=0 then return new;end if;
    v_lines:=jsonb_build_array(jsonb_build_object('role','cash','debit',new.opening_amount,'credit',0,'description','Fondo de apertura'),jsonb_build_object('role','cash_opening_offset','debit',0,'credit',new.opening_amount,'description','Origen de fondo'));
    perform public.capture_accounting_event(new.company_id,'cash_opened','cash_session',new.id,1,new.opened_at::date,new.opened_at,v_lines,jsonb_build_object('description','Apertura de caja'));return new;
  end if;
  if old.status<>'closed' and new.status='closed' then
    v_expected:=coalesce(new.expected_closing_amount,0);v_counted:=coalesce(new.counted_closing_amount,0);v_variance:=coalesce(new.variance_amount,0);if v_expected=0 and v_counted=0 then return new;end if;
    v_lines:='[]'::jsonb;
    if v_counted>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','cash_close_offset','debit',v_counted,'credit',0,'description','Retiro al cierre'));end if;
    if v_variance>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','cash','debit',v_variance,'credit',0,'description','Sobrante de caja'),jsonb_build_object('role','cash_over_short','debit',0,'credit',v_variance,'description','Sobrante aprobado'),jsonb_build_object('role','cash','debit',0,'credit',v_counted,'description','Cierre de caja'));
    elsif v_variance<0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','cash_over_short','debit',abs(v_variance),'credit',0,'description','Faltante aprobado'),jsonb_build_object('role','cash','debit',0,'credit',v_expected,'description','Cierre de caja'));
    elsif v_counted>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','cash','debit',0,'credit',v_counted,'description','Cierre de caja'));end if;
    perform public.capture_accounting_event(new.company_id,'cash_closed','cash_session',new.id,1,new.closed_at::date,new.closed_at,v_lines,jsonb_build_object('description','Cierre de caja','expected',v_expected,'counted',v_counted,'variance',v_variance));
  end if;return new;
end $$;
create constraint trigger cash_sessions_accounting_event after insert or update on public.cash_sessions deferrable initially deferred for each row execute function public.capture_cash_accounting_event();

create or replace function public.capture_cash_movement_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_lines jsonb;v_amount numeric:=abs(new.amount);
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if new.source_entity_type='cash_movement_reversal' then perform public.capture_exact_accounting_reversal(new.company_id,'cash_movement_recorded','cash_movement_reversed','cash_movement',new.source_entity_id,new.occurred_at::date,new.occurred_at,'Reversa de movimiento de caja');return new;end if;
  if new.movement_type not in ('paid_in','paid_out') or new.source_entity_type in ('sale_cancellation','receivable_payment_reversal') then return new;end if;
  if new.movement_type='paid_in' then v_lines:=jsonb_build_array(jsonb_build_object('role','cash','debit',v_amount,'credit',0,'description','Entrada de caja'),jsonb_build_object('role','cash_movement_offset','debit',0,'credit',v_amount,'description',coalesce(new.reason,'Contrapartida de entrada')));else v_lines:=jsonb_build_array(jsonb_build_object('role','cash_movement_offset','debit',v_amount,'credit',0,'description',coalesce(new.reason,'Contrapartida de salida')),jsonb_build_object('role','cash','debit',0,'credit',v_amount,'description','Salida de caja'));end if;
  perform public.capture_accounting_event(new.company_id,'cash_movement_recorded','cash_movement',new.id,1,new.occurred_at::date,new.occurred_at,v_lines,jsonb_build_object('description','Movimiento de caja','movement_type',new.movement_type));return new;
end $$;
create constraint trigger cash_movements_accounting_event after insert on public.cash_movements deferrable initially deferred for each row execute function public.capture_cash_movement_accounting_event();

create or replace function public.capture_purchase_receipt_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_amount numeric;v_lines jsonb;
begin
  if (tg_op='UPDATE' and old.status=new.status) or not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if new.status='confirmed' then select round(coalesce(sum(line_cost),0),6) into v_amount from public.purchase_receipt_lines where purchase_receipt_id=new.id;if v_amount<=0 then raise exception 'La recepción no tiene valor contabilizable.';end if;v_lines:=jsonb_build_array(jsonb_build_object('role','inventory','debit',v_amount,'credit',0,'description','Inventario recibido'),jsonb_build_object('role','goods_received_not_invoiced','debit',0,'credit',v_amount,'description','Recepción pendiente de factura'));perform public.capture_accounting_event(new.company_id,'purchase_receipt_confirmed','purchase_receipt',new.id,1,new.receipt_date,new.confirmed_at,v_lines,jsonb_build_object('description','Recepción confirmada','folio',new.folio));
  elsif new.status='reversed' then perform public.capture_exact_accounting_reversal(new.company_id,'purchase_receipt_confirmed','purchase_receipt_reversed','purchase_receipt',new.id,new.reversed_at::date,new.reversed_at,'Reversa de recepción');end if;return new;
end $$;
create constraint trigger purchase_receipts_accounting_event after update on public.purchase_receipts deferrable initially deferred for each row execute function public.capture_purchase_receipt_accounting_event();

create or replace function public.capture_inventory_adjustment_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_set public.accounting_event_rule_sets%rowtype;v_value numeric;v_items int;v_costed int;v_lines jsonb;
begin
  if old.status=new.status or new.status<>'posted' or not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=new.company_id and status='approved';select round(coalesce(sum(l.variance_quantity*pc.amount),0),6),count(*) filter(where l.variance_quantity<>0),count(pc.amount) filter(where l.variance_quantity<>0) into v_value,v_items,v_costed from public.inventory_count_lines l left join lateral(select amount from public.product_costs where company_id=new.company_id and product_id=l.product_id and cost_type=v_set.cost_method and valid_from<=new.posted_at and (valid_to is null or valid_to>new.posted_at) order by valid_from desc limit 1)pc on true where l.inventory_count_id=new.id;
  if v_items=0 then return new;end if;if v_items<>v_costed then raise exception 'El ajuste físico no puede contabilizarse: faltan costos vigentes.';end if;if v_value=0 then return new;end if;
  if v_value>0 then v_lines:=jsonb_build_array(jsonb_build_object('role','inventory','debit',v_value,'credit',0,'description','Aumento por conteo físico'),jsonb_build_object('role','inventory_adjustment','debit',0,'credit',v_value,'description','Ajuste de inventario'));else v_lines:=jsonb_build_array(jsonb_build_object('role','inventory_adjustment','debit',abs(v_value),'credit',0,'description','Ajuste de inventario'),jsonb_build_object('role','inventory','debit',0,'credit',abs(v_value),'description','Disminución por conteo físico'));end if;
  perform public.capture_accounting_event(new.company_id,'inventory_adjustment_posted','inventory_count',new.id,1,new.posted_at::date,new.posted_at,v_lines,jsonb_build_object('description','Ajuste por conteo físico','cost_method',v_set.cost_method));return new;
end $$;
create constraint trigger inventory_counts_accounting_event after update on public.inventory_counts deferrable initially deferred for each row execute function public.capture_inventory_adjustment_accounting_event();

create or replace function public.capture_supplier_invoice_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_net numeric;v_tax numeric;v_withholding numeric;v_total numeric;v_received numeric:=0;v_variance numeric;v_lines jsonb;v_original_type text;
begin
  if (tg_op='UPDATE' and old.status=new.status) or not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if new.status='reversed' then v_original_type:=case when new.document_type='credit_note' then 'supplier_credit_note_confirmed' else 'supplier_invoice_confirmed' end;perform public.capture_exact_accounting_reversal(new.company_id,v_original_type,case when new.document_type='credit_note' then 'supplier_credit_note_reversed' else 'supplier_invoice_reversed' end,'supplier_invoice',new.id,new.reversed_at::date,new.reversed_at,'Reversa de documento de proveedor');return new;end if;
  if new.status<>'confirmed' then return new;end if;
  v_net:=round((new.subtotal-new.discount_total)*new.exchange_rate,6);v_tax:=round(new.tax_total*new.exchange_rate,6);v_withholding:=round(coalesce(new.withholding_total,0)*new.exchange_rate,6);v_total:=case when new.base_total>0 then new.base_total else round(new.total*new.exchange_rate,6) end;
  if new.document_type='credit_note' then v_lines:=jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',v_total,'credit',0,'description','Aplicación de nota de crédito'));if v_withholding>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','withholdings','debit',v_withholding,'credit',0,'description','Reversa de retención'));end if;v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','supplier_credit_note_offset','debit',0,'credit',v_net,'description','Nota de crédito'));if v_tax>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_pending','debit',0,'credit',v_tax,'description','IVA de nota de crédito'));end if;perform public.capture_accounting_event(new.company_id,'supplier_credit_note_confirmed','supplier_invoice',new.id,1,new.issued_date,new.confirmed_at,v_lines,jsonb_build_object('description','Nota de crédito confirmada','folio',new.folio));return new;end if;
  v_lines:='[]'::jsonb;
  if new.source_kind='receipt' then select round(coalesce(sum(l.quantity*l.received_unit_cost),0)*new.exchange_rate,6) into v_received from public.supplier_invoice_lines l where l.supplier_invoice_id=new.id;v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','goods_received_not_invoiced','debit',v_received,'credit',0,'description','Recepciones facturadas'));v_variance:=round(v_net-v_received,6);if v_variance>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','purchase_variance','debit',v_variance,'credit',0,'description','Variación de compra'));elsif v_variance<0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','purchase_variance','debit',0,'credit',abs(v_variance),'description','Variación de compra'));end if;else v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','supplier_expense','debit',v_net,'credit',0,'description','Gasto o servicio'));end if;
  if v_tax>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_pending','debit',v_tax,'credit',0,'description','IVA pendiente de pago'));end if;if v_withholding>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','withholdings','debit',0,'credit',v_withholding,'description','Retenciones por pagar'));end if;v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',0,'credit',v_total,'description','Cuenta por pagar'));
  perform public.capture_accounting_event(new.company_id,'supplier_invoice_confirmed','supplier_invoice',new.id,1,new.issued_date,new.confirmed_at,v_lines,jsonb_build_object('description','Factura de proveedor confirmada','folio',new.folio,'source_kind',new.source_kind));return new;
end $$;
create constraint trigger supplier_invoices_accounting_event after insert or update on public.supplier_invoices deferrable initially deferred for each row execute function public.capture_supplier_invoice_accounting_event();

create or replace function public.capture_supplier_payment_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_base numeric;v_vat numeric;v_lines jsonb;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if tg_op='UPDATE' and old.status=new.status then return new;end if;
  if new.status='reversed' then perform public.capture_exact_accounting_reversal(new.company_id,'supplier_payment_confirmed','supplier_payment_reversed','supplier_payment',new.id,new.reversed_at::date,new.reversed_at,'Reversa de pago a proveedor');return new;end if;
  select round(coalesce(sum(a.amount*ap.exchange_rate),0),6),round(coalesce(sum(a.amount*ap.exchange_rate*case when si.total>0 then si.tax_total/si.total else 0 end),0),6) into v_base,v_vat from public.supplier_payment_applications a join public.accounts_payable ap on ap.id=a.accounts_payable_id join public.supplier_invoices si on si.id=a.supplier_invoice_id where a.payment_id=new.id;
  if v_base<=0 then raise exception 'El pago no tiene aplicaciones contabilizables.';end if;v_lines:=jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',v_base,'credit',0,'description','Pago aplicado a CxP'),jsonb_build_object('role','banks','debit',0,'credit',v_base,'description','Salida bancaria'));
  if v_vat>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_paid','debit',v_vat,'credit',0,'description','IVA efectivamente pagado'),jsonb_build_object('role','vat_pending','debit',0,'credit',v_vat,'description','Reclasificación de IVA'));end if;
  perform public.capture_accounting_event(new.company_id,'supplier_payment_confirmed','supplier_payment',new.id,1,new.effective_date,new.confirmed_at,v_lines,jsonb_build_object('description','Pago a proveedor confirmado','reference',new.reference));return new;
end $$;
create constraint trigger supplier_payments_accounting_event after insert or update on public.supplier_payments deferrable initially deferred for each row execute function public.capture_supplier_payment_accounting_event();

revoke all on function public.accounting_operational_matrix_active(uuid),public.capture_exact_accounting_reversal(uuid,text,text,text,uuid,date,timestamptz,text) from public,anon,authenticated;
