-- Satrapy · Los pagos a proveedor se registran en centavos completos.
-- La salida bancaria se redondea primero y el descuento es la diferencia
-- exacta contra el saldo. No altera pagos ni propuestas históricas.

create or replace function public.save_supplier_payment_proposal(
  p_company_id uuid,p_proposal_id uuid,p_supplier_id uuid,p_currency_code text,p_lines jsonb,
  p_client_request_id uuid,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_proposal_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_payable public.accounts_payable%rowtype;v_line jsonb;v_id uuid;v_amount numeric;v_total numeric:=0;v_result jsonb;v_distinct int;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') then raise exception 'No autorizado para preparar propuestas de pago.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_proposal_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then
    if v_existing.operation<>'save' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;
    return v_existing.result||jsonb_build_object('idempotent',true);
  end if;
  if upper(trim(coalesce(p_currency_code,'')))!~'^[A-Z]{3}$' then raise exception 'Moneda inválida.';end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La propuesta requiere al menos una CxP.';end if;
  select count(distinct value->>'accounts_payable_id') into v_distinct from jsonb_array_elements(p_lines);
  if v_distinct<>jsonb_array_length(p_lines) then raise exception 'Una CxP no puede repetirse en la propuesta.';end if;
  if p_proposal_id is null then
    v_id:=gen_random_uuid();
    insert into public.supplier_payment_proposals(id,company_id,supplier_id,currency_code) values(v_id,p_company_id,p_supplier_id,upper(trim(p_currency_code)));
  else
    select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
    if not found or v_proposal.status<>'draft' then raise exception 'Borrador de propuesta no disponible.';end if;
    if p_expected_updated_at is not null and v_proposal.updated_at<>p_expected_updated_at then raise exception 'La propuesta cambió; recargue antes de guardar.';end if;
    v_id:=v_proposal.id;
    update public.supplier_payment_proposals set supplier_id=p_supplier_id,currency_code=upper(trim(p_currency_code)),updated_by=auth.uid() where id=v_id;
    delete from public.supplier_payment_proposal_lines where proposal_id=v_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    begin v_amount:=(v_line->>'proposed_amount')::numeric;exception when others then raise exception 'Importe propuesto inválido.';end;
    if v_amount<>round(v_amount,2) then raise exception 'Los importes de pago deben expresarse con dos decimales.';end if;
    select * into v_payable from public.accounts_payable where id=(v_line->>'accounts_payable_id')::uuid and company_id=p_company_id for update;
    if not found or v_payable.reversed_at is not null or v_payable.outstanding_amount<=0 then raise exception 'CxP no disponible para propuesta.';end if;
    if v_payable.supplier_id<>p_supplier_id or v_payable.currency_code<>upper(trim(p_currency_code)) then raise exception 'Todas las CxP deben pertenecer al mismo proveedor y moneda.';end if;
    if v_amount<=0 or v_amount>v_payable.outstanding_amount then raise exception 'El importe propuesto debe ser positivo y no superar el saldo actual.';end if;
    insert into public.supplier_payment_proposal_lines(company_id,proposal_id,accounts_payable_id,proposed_amount,balance_snapshot,due_date_snapshot)
    values(p_company_id,v_id,v_payable.id,v_amount,v_payable.outstanding_amount,v_payable.due_date);
    v_total:=v_total+v_amount;
  end loop;
  update public.supplier_payment_proposals set total_proposed=round(v_total,2),updated_by=auth.uid() where id=v_id returning * into v_proposal;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_proposal_id is null then 'supplier_payment_proposal.created' else 'supplier_payment_proposal.updated' end,'supplier_payment_proposal',v_id,jsonb_build_object('supplier_id',p_supplier_id,'currency_code',upper(trim(p_currency_code)),'line_count',jsonb_array_length(p_lines),'total_proposed',round(v_total,2),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_id,'status','draft','total_proposed',round(v_total,2),'updated_at',v_proposal.updated_at,'idempotent',false);
  insert into public.supplier_payment_proposal_requests(company_id,request_id,proposal_id,operation,result) values(p_company_id,p_client_request_id,v_id,'save',v_result);
  return v_result;
end $$;

create or replace function public.confirm_supplier_payment(
  p_company_id uuid,p_proposal_id uuid,p_paying_account_id uuid,p_effective_date date,p_payment_method text,p_reference text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_account public.supplier_paying_accounts%rowtype;v_payment uuid;v_line record;v_total numeric:=0;v_discount_total numeric:=0;v_discount numeric;v_settlement numeric;v_result jsonb;v_payment_form_code text:=upper(trim(coalesce(p_payment_method,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_supplier_payments') then raise exception 'No autorizado para confirmar pagos.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  if p_effective_date is null or v_payment_form_code='' or nullif(trim(coalesce(p_reference,'')),'') is null then raise exception 'Fecha efectiva, forma de pago y referencia son obligatorias.';end if;
  if v_payment_form_code not in ('01','02','03','04','05','06','08','12','13','14','15','17','23','24','25','26','27','28','29','30','31','99') then raise exception 'Forma de pago SAT inválida.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then if v_existing.operation<>'confirm' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;return v_existing.result||jsonb_build_object('idempotent',true);end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status<>'approved' then raise exception 'Sólo una propuesta aprobada puede convertirse en pago.';end if;
  if exists(select 1 from public.supplier_payments where proposal_id=p_proposal_id) then raise exception 'La propuesta ya tiene un pago registrado.';end if;
  if v_proposal.total_proposed<>round(v_proposal.total_proposed,2) then raise exception 'La propuesta contiene fracciones de centavo; recréala antes de confirmar.';end if;
  select * into v_account from public.supplier_paying_accounts where id=p_paying_account_id and company_id=p_company_id for update;
  if not found or not v_account.is_active then raise exception 'Cuenta pagadora activa no disponible.';end if;
  if v_account.currency_code<>v_proposal.currency_code then raise exception 'La cuenta pagadora y la propuesta deben tener la misma moneda.';end if;
  v_payment:=gen_random_uuid();
  insert into public.supplier_payments(id,company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount)
  values(v_payment,p_company_id,p_proposal_id,v_proposal.supplier_id,v_account.id,v_proposal.currency_code,p_effective_date,v_payment_form_code,trim(p_reference),v_proposal.total_proposed);
  for v_line in select l.accounts_payable_id,l.proposed_amount,ap.supplier_invoice_id,ap.company_id,ap.supplier_id,ap.currency_code,ap.outstanding_amount,ap.reversed_at,si.issued_date from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id join public.supplier_invoices si on si.id=ap.supplier_invoice_id where l.proposal_id=p_proposal_id order by ap.id for update of ap loop
    if v_line.company_id<>p_company_id or v_line.supplier_id<>v_proposal.supplier_id or v_line.currency_code<>v_proposal.currency_code then raise exception 'Todas las aplicaciones deben conservar empresa, proveedor y moneda.';end if;
    if v_line.reversed_at is not null then raise exception 'No se puede aplicar contra una CxP revertida.';end if;
    if v_line.proposed_amount<>round(v_line.proposed_amount,2) or v_line.outstanding_amount<>round(v_line.outstanding_amount,2) then raise exception 'La CxP o propuesta contiene fracciones de centavo; recréala antes de confirmar.';end if;
    if v_line.outstanding_amount<v_line.proposed_amount then raise exception 'El pago excede el saldo actual de una CxP.';end if;
    select round(v_line.outstanding_amount-v_line.proposed_amount,2) into v_discount from public.supplier_invoice_prompt_payment_terms t where t.supplier_invoice_id=v_line.supplier_invoice_id and p_effective_date<=v_line.issued_date+t.term_days and round(v_line.proposed_amount,2)=round(v_line.outstanding_amount*(1-public.prompt_payment_effective_discount(t.discount_components)/100),2) order by public.prompt_payment_effective_discount(t.discount_components) desc,t.term_days limit 1;
    v_discount:=coalesce(v_discount,0);v_settlement:=round(v_line.proposed_amount+v_discount,2);
    insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,prompt_payment_discount_amount,balance_before,balance_after) values(p_company_id,v_payment,v_line.accounts_payable_id,v_line.supplier_invoice_id,v_settlement,v_discount,v_line.outstanding_amount,round(v_line.outstanding_amount-v_settlement,2));
    update public.accounts_payable set outstanding_amount=round(outstanding_amount-v_settlement,2) where id=v_line.accounts_payable_id;
    v_total:=v_total+v_line.proposed_amount;v_discount_total:=v_discount_total+v_discount;
  end loop;
  if v_total<=0 or round(v_total,2)<>round(v_proposal.total_proposed,2) then raise exception 'Las aplicaciones no concilian con la propuesta aprobada.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_payment.confirmed','supplier_payment',v_payment,jsonb_build_object('proposal_id',p_proposal_id,'supplier_id',v_proposal.supplier_id,'currency_code',v_proposal.currency_code,'total_amount',round(v_total,2),'prompt_payment_discount_amount',round(v_discount_total,2),'effective_date',p_effective_date,'paying_account_id',v_account.id,'payment_form_code',v_payment_form_code,'reference',trim(p_reference),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_payment,'proposal_id',p_proposal_id,'status','confirmed','reconciliation_status','unreconciled','total_amount',round(v_total,2),'prompt_payment_discount_amount',round(v_discount_total,2),'idempotent',false);
  insert into public.supplier_payment_requests(company_id,request_id,payment_id,operation,result) values(p_company_id,p_client_request_id,v_payment,'confirm',v_result);
  return v_result;
end $$;

create or replace function public.search_supplier_payable_due_inbox_v2(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_currency_code text default null,p_due_bucket text default null,p_due_from date default null,p_due_to date default null,p_min_balance numeric default null,p_max_balance numeric default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;v_items jsonb;
begin
  v_result:=public.search_supplier_payable_due_inbox(p_company_id,p_query,p_supplier_id,p_currency_code,p_due_bucket,p_due_from,p_due_to,p_min_balance,p_max_balance,p_page,p_page_size);
  select coalesce(jsonb_agg(entry.item||jsonb_build_object('prompt_payment_terms',coalesce(terms.options,'[]'::jsonb),'eligible_prompt_payment',terms.eligible) order by entry.ordinality),'[]'::jsonb) into v_items
  from jsonb_array_elements(v_result->'items') with ordinality entry(item,ordinality)
  join public.supplier_invoices si on si.id=(entry.item->>'supplier_invoice_id')::uuid
  left join lateral(
    select jsonb_agg(option order by (option->>'term_days')::integer) options,(jsonb_agg(option order by (option->>'effective_discount_percent')::numeric desc,(option->>'term_days')::integer)->0) eligible
    from(select jsonb_build_object('tier_number',t.tier_number,'term_days',t.term_days,'deadline',si.issued_date+t.term_days,'discount_expression',public.prompt_payment_discount_expression(t.discount_components),'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components),'estimated_total',round((entry.item->>'outstanding_amount')::numeric*(1-public.prompt_payment_effective_discount(t.discount_components)/100),2)) option from public.supplier_invoice_prompt_payment_terms t where t.supplier_invoice_id=si.id and current_date<=si.issued_date+t.term_days) eligible_options
  ) terms on true;
  return jsonb_set(v_result,'{items}',v_items);
end $$;

create or replace function public.search_supplier_payment_calendar(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_currency_code text default null,p_due_from date default null,p_due_to date default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_result jsonb;v_can_proposals boolean;v_can_payments boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then raise exception 'No autorizado para consultar la agenda de pagos.';end if;
  if p_due_from is null or p_due_to is null or p_due_from>p_due_to or p_due_to-p_due_from>366 then raise exception 'La agenda requiere un rango válido de hasta 366 días.';end if;
  v_can_proposals:=public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') or public.has_company_permission(p_company_id,'approve_supplier_payment_proposals');v_can_payments:=public.has_company_permission(p_company_id,'view_supplier_payments');
  with calendar_base as materialized(
    select ap.id,ap.supplier_id,s.code supplier_code,s.display_name supplier_name,ap.supplier_invoice_id,concat_ws('-',si.series,si.folio) invoice_number,ap.currency_code,ap.original_amount,ap.outstanding_amount,ap.issued_date,ap.due_date,case when proposal.proposal_id is not null or payment.payment_id is not null then 'scheduled' when ap.due_date<current_date then 'overdue' when ap.due_date=current_date then 'due_today' when ap.due_date<=current_date+15 then 'upcoming' else 'future' end state,proposal.proposal_id,proposal.proposal_status,payment.payment_id,payment.payment_reference,prompt.eligible_prompt_payment
    from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id
    left join lateral(select pp.id proposal_id,pp.status proposal_status from public.supplier_payment_proposal_lines pl join public.supplier_payment_proposals pp on pp.id=pl.proposal_id where v_can_proposals and pl.company_id=p_company_id and pl.accounts_payable_id=ap.id and pp.status in('draft','submitted','approved') order by case pp.status when 'approved' then 1 when 'submitted' then 2 else 3 end,pp.updated_at desc limit 1) proposal on true
    left join lateral(select p.id payment_id,p.reference payment_reference from public.supplier_payment_applications pa join public.supplier_payments p on p.id=pa.payment_id where v_can_payments and pa.company_id=p_company_id and pa.accounts_payable_id=ap.id and p.status='confirmed' order by p.effective_date desc,p.confirmed_at desc limit 1) payment on true
    left join lateral(select jsonb_build_object('tier_number',t.tier_number,'term_days',t.term_days,'deadline',si.issued_date+t.term_days,'discount_expression',public.prompt_payment_discount_expression(t.discount_components),'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components),'estimated_total',round(ap.outstanding_amount*(1-public.prompt_payment_effective_discount(t.discount_components)/100),2),'estimated_savings',round(ap.outstanding_amount-round(ap.outstanding_amount*(1-public.prompt_payment_effective_discount(t.discount_components)/100),2),2)) eligible_prompt_payment from public.supplier_invoice_prompt_payment_terms t where t.supplier_invoice_id=si.id and current_date<=si.issued_date+t.term_days order by public.prompt_payment_effective_discount(t.discount_components) desc,t.term_days limit 1) prompt on true
    where ap.company_id=p_company_id and ap.reversed_at is null and ap.due_date between p_due_from and p_due_to and (ap.outstanding_amount>0 or payment.payment_id is not null) and (p_supplier_id is null or ap.supplier_id=p_supplier_id) and (p_currency_code is null or ap.currency_code=upper(trim(p_currency_code))) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
  ),paged as(select * from calendar_base order by due_date,supplier_name,invoice_number,id limit v_size offset(v_page-1)*v_size),day_totals as(select due_date,currency_code,count(*) document_count,round(sum(outstanding_amount),6) outstanding_amount from calendar_base group by due_date,currency_code)
  select jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(p) order by p.due_date,p.supplier_name,p.invoice_number,p.id),'[]'::jsonb) from paged p),'totals',(select coalesce(jsonb_agg(to_jsonb(t) order by t.due_date,t.currency_code),'[]'::jsonb) from day_totals t),'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from calendar_base)),'range',jsonb_build_object('from',p_due_from,'to',p_due_to)) into v_result;
  return v_result;
end $$;

revoke all on function public.save_supplier_payment_proposal(uuid,uuid,uuid,text,jsonb,uuid,timestamptz) from public;
grant execute on function public.save_supplier_payment_proposal(uuid,uuid,uuid,text,jsonb,uuid,timestamptz) to authenticated;
revoke all on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) from public;
grant execute on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) to authenticated;
