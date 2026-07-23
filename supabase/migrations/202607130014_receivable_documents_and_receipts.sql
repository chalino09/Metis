-- Receivable detail, deterministic FIFO preview and immutable payment receipts.

alter table public.receivable_payments add column payment_reference text;

create table public.receivable_receipt_sequences (
  company_id uuid primary key references public.companies(id) on delete cascade,
  next_number bigint not null default 1 check (next_number>0)
);

create table public.canonical_receivable_receipts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  receivable_payment_id uuid not null unique references public.receivable_payments(id) on delete restrict,
  folio text not null,
  schema_version integer not null default 1,
  payload jsonb not null,
  content_sha256 text not null,
  issued_at timestamptz not null default now(),
  unique(company_id,folio)
);
create trigger canonical_receivable_receipts_immutable before update or delete on public.canonical_receivable_receipts for each row execute function public.prevent_pos_document_mutation();
alter table public.canonical_receivable_receipts enable row level security;
create policy canonical_receivable_receipts_read on public.canonical_receivable_receipts for select to authenticated using(public.has_company_permission(company_id,'view_customer_credit'));
revoke insert,update,delete on public.canonical_receivable_receipts from authenticated;
grant select on public.canonical_receivable_receipts to authenticated;
revoke all on public.receivable_receipt_sequences from authenticated;

create or replace function public.list_customer_open_receivables(p_company_id uuid,p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar CxC.'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and company_id=p_company_id) then raise exception 'Cliente no encontrado.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',coalesce(r.source_reference,t.folio),'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount,'currency_code',coalesce(s.currency_code,cpl.currency_code,dpl.currency_code),'source_kind',r.source_kind) order by r.due_date,r.issued_at,r.id) from public.customer_receivables r join public.customers c on c.id=r.customer_id left join public.sales s on s.id=r.sale_id left join public.canonical_tickets t on t.sale_id=r.sale_id left join public.price_lists cpl on cpl.id=c.price_list_id left join public.companies company_data on company_data.id=r.company_id left join public.price_lists dpl on dpl.id=company_data.default_price_list_id where r.company_id=p_company_id and r.customer_id=p_customer_id and r.outstanding_amount>0),'[]'::jsonb);
end $$;

create or replace function public.preview_receivable_payment_fifo(p_company_id uuid,p_customer_id uuid,p_amount numeric)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_remaining numeric:=round(coalesce(p_amount,0),2); v_total numeric; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'record_receivable_payment') or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para registrar abonos.'; end if;
  if v_remaining<=0 then raise exception 'El abono debe ser mayor a cero.'; end if;
  select coalesce(sum(outstanding_amount),0) into v_total from public.customer_receivables where company_id=p_company_id and customer_id=p_customer_id and outstanding_amount>0;
  if v_remaining>v_total then raise exception 'El abono excede el saldo abierto del cliente.'; end if;
  with ordered as (select r.*,coalesce(sum(r.outstanding_amount) over(order by r.due_date,r.issued_at,r.id rows between unbounded preceding and 1 preceding),0) consumed from public.customer_receivables r where r.company_id=p_company_id and r.customer_id=p_customer_id and r.outstanding_amount>0), applied as (select o.*,greatest(least(v_remaining-o.consumed,o.outstanding_amount),0) applied_amount from ordered o)
  select coalesce(jsonb_agg(jsonb_build_object('receivable_id',a.id,'reference',coalesce(a.source_reference,t.folio),'due_date',a.due_date,'current_balance',a.outstanding_amount,'amount_applied',a.applied_amount,'remaining_after',a.outstanding_amount-a.applied_amount) order by a.due_date,a.issued_at,a.id) filter(where a.applied_amount>0),'[]'::jsonb) into v_items from applied a left join public.canonical_tickets t on t.sale_id=a.sale_id;
  return v_items;
end $$;

drop function if exists public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid);
create function public.record_receivable_payment(p_company_id uuid,p_customer_id uuid,p_payment_method_id uuid,p_amount numeric,p_cash_session_id uuid default null,p_client_request_id uuid default null,p_payment_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_customer public.customers%rowtype; v_method public.payment_methods%rowtype; v_session public.cash_sessions%rowtype; v_existing public.receivable_payments%rowtype; v_payment_id uuid; v_remaining numeric:=round(coalesce(p_amount,0),2); v_total_open numeric; v_currency text; v_receivable record; v_applied numeric; v_request_id uuid:=coalesce(p_client_request_id,gen_random_uuid()); v_number bigint; v_folio text; v_payload jsonb; v_receipt_id uuid;
begin
  if v_remaining<=0 then raise exception 'El abono debe ser mayor a cero.'; end if;
  if auth.uid() is null or not public.has_company_permission(p_company_id,'record_receivable_payment') or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para registrar abonos.'; end if;
  select * into v_existing from public.receivable_payments where company_id=p_company_id and client_request_id=v_request_id;
  if found then select id,folio,payload into v_receipt_id,v_folio,v_payload from public.canonical_receivable_receipts where receivable_payment_id=v_existing.id; return jsonb_build_object('payment_id',v_existing.id,'amount',v_existing.amount,'receipt_id',v_receipt_id,'folio',v_folio,'receipt',v_payload,'idempotent',true); end if;
  select * into v_customer from public.customers where id=p_customer_id and company_id=p_company_id for update; if not found then raise exception 'Cliente no encontrado.'; end if;
  select * into v_method from public.payment_methods where id=p_payment_method_id and company_id=p_company_id and is_active; if not found then raise exception 'Forma de pago no disponible.'; end if;
  if v_method.settlement_kind='cash_drawer' then
    if p_cash_session_id is null then raise exception 'El abono en efectivo requiere una sesión de caja explícita.'; end if;
    select * into v_session from public.cash_sessions where id=p_cash_session_id and company_id=p_company_id and opened_by=auth.uid() and status='open' for share; if not found then raise exception 'La sesión de caja propia no está disponible.'; end if;
    perform public.assert_pos_access(p_company_id,v_session.location_id,'record_receivable_payment');
  else
    if p_cash_session_id is not null then raise exception 'Una forma de pago externa no debe afectar una caja.'; end if;
    if nullif(trim(coalesce(p_payment_reference,'')),'') is null then raise exception 'La referencia es obligatoria para pagos externos.'; end if;
  end if;
  select coalesce(sum(r.outstanding_amount),0),min(coalesce(s.currency_code,cpl.currency_code,dpl.currency_code)) into v_total_open,v_currency from public.customer_receivables r join public.customers c on c.id=r.customer_id left join public.sales s on s.id=r.sale_id left join public.price_lists cpl on cpl.id=c.price_list_id left join public.companies company_data on company_data.id=r.company_id left join public.price_lists dpl on dpl.id=company_data.default_price_list_id where r.company_id=p_company_id and r.customer_id=p_customer_id and r.outstanding_amount>0; if v_remaining>v_total_open then raise exception 'El abono excede el saldo abierto del cliente.'; end if;
  if v_currency is null then raise exception 'No hay una moneda canónica configurada para los documentos del cliente.'; end if;
  if exists(select 1 from public.customer_receivables r join public.customers c on c.id=r.customer_id left join public.sales s on s.id=r.sale_id left join public.price_lists cpl on cpl.id=c.price_list_id left join public.companies company_data on company_data.id=r.company_id left join public.price_lists dpl on dpl.id=company_data.default_price_list_id where r.company_id=p_company_id and r.customer_id=p_customer_id and r.outstanding_amount>0 and coalesce(s.currency_code,cpl.currency_code,dpl.currency_code) is distinct from v_currency) then raise exception 'El cliente tiene documentos abiertos en más de una moneda; registra el pago por moneda.'; end if;
  insert into public.receivable_payments(company_id,customer_id,payment_method_id,payment_method_code,settlement_kind,cash_session_id,amount,client_request_id,received_by,payment_reference) values(p_company_id,p_customer_id,v_method.id,v_method.code,v_method.settlement_kind,case when v_method.settlement_kind='cash_drawer' then v_session.id else null end,v_remaining,v_request_id,auth.uid(),nullif(trim(p_payment_reference),'')) returning id into v_payment_id;
  for v_receivable in select * from public.customer_receivables where company_id=p_company_id and customer_id=p_customer_id and outstanding_amount>0 order by due_date,issued_at,id for update loop exit when v_remaining=0; v_applied:=least(v_remaining,v_receivable.outstanding_amount); update public.customer_receivables set outstanding_amount=outstanding_amount-v_applied where id=v_receivable.id; insert into public.receivable_payment_applications(receivable_payment_id,receivable_id,amount) values(v_payment_id,v_receivable.id,v_applied); v_remaining:=v_remaining-v_applied; end loop;
  if v_method.settlement_kind='cash_drawer' then insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id,source_entity_type,source_entity_id) values(p_company_id,v_session.id,'receivable_payment',p_amount,auth.uid(),'receivable_payments',v_payment_id); end if;
  insert into public.receivable_receipt_sequences(company_id,next_number) values(p_company_id,1) on conflict(company_id) do nothing;
  select next_number into v_number from public.receivable_receipt_sequences where company_id=p_company_id for update; update public.receivable_receipt_sequences set next_number=next_number+1 where company_id=p_company_id; v_folio:='RCB-'||lpad(v_number::text,10,'0');
  select jsonb_build_object('folio',v_folio,'issued_at',now(),'company_id',p_company_id,'customer_id',v_customer.id,'customer_code',v_customer.code,'customer_name',v_customer.display_name,'payment_id',v_payment_id,'amount',p_amount,'currency_code',v_currency,'payment_method',v_method.display_name,'payment_method_code',v_method.code,'payment_reference',nullif(trim(p_payment_reference),''),'applications',coalesce(jsonb_agg(jsonb_build_object('receivable_id',r.id,'reference',coalesce(r.source_reference,t.folio),'amount_applied',a.amount) order by r.due_date,r.issued_at,r.id),'[]'::jsonb)) into v_payload from public.receivable_payment_applications a join public.customer_receivables r on r.id=a.receivable_id left join public.canonical_tickets t on t.sale_id=r.sale_id where a.receivable_payment_id=v_payment_id;
  insert into public.canonical_receivable_receipts(company_id,receivable_payment_id,folio,payload,content_sha256) values(p_company_id,v_payment_id,v_folio,v_payload,encode(digest(v_payload::text,'sha256'),'hex')) returning id into v_receipt_id;
  perform public.write_sales_audit(p_company_id,'receivable_payment.recorded','receivable_payments',v_payment_id,jsonb_build_object('customer_id',p_customer_id,'amount',p_amount,'reference',nullif(trim(p_payment_reference),''),'receipt_folio',v_folio));
  return jsonb_build_object('payment_id',v_payment_id,'amount',p_amount,'receipt_id',v_receipt_id,'folio',v_folio,'receipt',v_payload,'idempotent',false);
exception when unique_violation then
  select * into v_existing from public.receivable_payments where company_id=p_company_id and client_request_id=v_request_id; if found then select id,folio,payload into v_receipt_id,v_folio,v_payload from public.canonical_receivable_receipts where receivable_payment_id=v_existing.id; return jsonb_build_object('payment_id',v_existing.id,'amount',v_existing.amount,'receipt_id',v_receipt_id,'folio',v_folio,'receipt',v_payload,'idempotent',true); end if; raise;
end $$;

revoke all on function public.list_customer_open_receivables(uuid,uuid),public.preview_receivable_payment_fifo(uuid,uuid,numeric),public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text) from public;
grant execute on function public.list_customer_open_receivables(uuid,uuid),public.preview_receivable_payment_fifo(uuid,uuid,numeric),public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text) to authenticated;
