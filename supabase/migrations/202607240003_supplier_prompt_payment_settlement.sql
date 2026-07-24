-- Satrapy · El descuento por pronto pago liquida la CxP sin fingir un pago parcial.
-- amount conserva el importe que se extingue de la CxP; el descuento separa la
-- salida bancaria real y queda trazable dentro de la misma aplicación inmutable.

alter table public.supplier_payment_applications
  add column if not exists prompt_payment_discount_amount numeric(18,6) not null default 0
  check(prompt_payment_discount_amount>=0 and prompt_payment_discount_amount<amount);

create or replace function public.confirm_supplier_payment(
  p_company_id uuid,p_proposal_id uuid,p_paying_account_id uuid,p_effective_date date,p_payment_method text,p_reference text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_existing public.supplier_payment_requests%rowtype;
  v_proposal public.supplier_payment_proposals%rowtype;
  v_account public.supplier_paying_accounts%rowtype;
  v_payment uuid;
  v_line record;
  v_total numeric:=0;
  v_discount_total numeric:=0;
  v_discount numeric;
  v_settlement numeric;
  v_result jsonb;
  v_payment_form_code text:=upper(trim(coalesce(p_payment_method,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_supplier_payments') then raise exception 'No autorizado para confirmar pagos.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  if p_effective_date is null or v_payment_form_code='' or nullif(trim(coalesce(p_reference,'')),'') is null then raise exception 'Fecha efectiva, forma de pago y referencia son obligatorias.';end if;
  if v_payment_form_code not in ('01','02','03','04','05','06','08','12','13','14','15','17','23','24','25','26','27','28','29','30','31','99') then raise exception 'Forma de pago SAT inválida.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then
    if v_existing.operation<>'confirm' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;
    return v_existing.result||jsonb_build_object('idempotent',true);
  end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status<>'approved' then raise exception 'Sólo una propuesta aprobada puede convertirse en pago.';end if;
  if exists(select 1 from public.supplier_payments where proposal_id=p_proposal_id) then raise exception 'La propuesta ya tiene un pago registrado.';end if;
  select * into v_account from public.supplier_paying_accounts where id=p_paying_account_id and company_id=p_company_id for update;
  if not found or not v_account.is_active then raise exception 'Cuenta pagadora activa no disponible.';end if;
  if v_account.currency_code<>v_proposal.currency_code then raise exception 'La cuenta pagadora y la propuesta deben tener la misma moneda.';end if;
  v_payment:=gen_random_uuid();
  insert into public.supplier_payments(id,company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount)
  values(v_payment,p_company_id,p_proposal_id,v_proposal.supplier_id,v_account.id,v_proposal.currency_code,p_effective_date,v_payment_form_code,trim(p_reference),v_proposal.total_proposed);
  for v_line in
    select l.accounts_payable_id,l.proposed_amount,ap.supplier_invoice_id,ap.company_id,ap.supplier_id,ap.currency_code,ap.outstanding_amount,ap.reversed_at,si.issued_date
    from public.supplier_payment_proposal_lines l
    join public.accounts_payable ap on ap.id=l.accounts_payable_id
    join public.supplier_invoices si on si.id=ap.supplier_invoice_id
    where l.proposal_id=p_proposal_id order by ap.id for update of ap
  loop
    if v_line.company_id<>p_company_id or v_line.supplier_id<>v_proposal.supplier_id or v_line.currency_code<>v_proposal.currency_code then raise exception 'Todas las aplicaciones deben conservar empresa, proveedor y moneda.';end if;
    if v_line.reversed_at is not null then raise exception 'No se puede aplicar contra una CxP revertida.';end if;
    if v_line.outstanding_amount<v_line.proposed_amount then raise exception 'El pago excede el saldo actual de una CxP.';end if;
    select round(v_line.outstanding_amount-v_line.proposed_amount,6) into v_discount
    from public.supplier_invoice_prompt_payment_terms t
    where t.supplier_invoice_id=v_line.supplier_invoice_id
      and p_effective_date<=v_line.issued_date+t.term_days
      and round(v_line.proposed_amount,6)=round(v_line.outstanding_amount*(1-public.prompt_payment_effective_discount(t.discount_components)/100),6)
    order by public.prompt_payment_effective_discount(t.discount_components) desc,t.term_days limit 1;
    v_discount:=coalesce(v_discount,0);
    v_settlement:=round(v_line.proposed_amount+v_discount,6);
    insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,prompt_payment_discount_amount,balance_before,balance_after)
    values(p_company_id,v_payment,v_line.accounts_payable_id,v_line.supplier_invoice_id,v_settlement,v_discount,v_line.outstanding_amount,round(v_line.outstanding_amount-v_settlement,6));
    update public.accounts_payable set outstanding_amount=round(outstanding_amount-v_settlement,6) where id=v_line.accounts_payable_id;
    v_total:=v_total+v_line.proposed_amount;
    v_discount_total:=v_discount_total+v_discount;
  end loop;
  if v_total<=0 or round(v_total,6)<>round(v_proposal.total_proposed,6) then raise exception 'Las aplicaciones no concilian con la propuesta aprobada.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'supplier_payment.confirmed','supplier_payment',v_payment,jsonb_build_object('proposal_id',p_proposal_id,'supplier_id',v_proposal.supplier_id,'currency_code',v_proposal.currency_code,'total_amount',v_total,'prompt_payment_discount_amount',round(v_discount_total,6),'effective_date',p_effective_date,'paying_account_id',v_account.id,'payment_form_code',v_payment_form_code,'reference',trim(p_reference),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_payment,'proposal_id',p_proposal_id,'status','confirmed','reconciliation_status','unreconciled','total_amount',round(v_total,6),'prompt_payment_discount_amount',round(v_discount_total,6),'idempotent',false);
  insert into public.supplier_payment_requests(company_id,request_id,payment_id,operation,result) values(p_company_id,p_client_request_id,v_payment,'confirm',v_result);
  return v_result;
end $$;

create or replace function public.capture_supplier_payment_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_settlement numeric;v_cash numeric;v_discount numeric;v_vat numeric;v_lines jsonb;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if tg_op='UPDATE' and old.status=new.status then return new;end if;
  if new.status='reversed' then perform public.capture_exact_accounting_reversal(new.company_id,'supplier_payment_confirmed','supplier_payment_reversed','supplier_payment',new.id,new.reversed_at::date,new.reversed_at,'Reversa de pago a proveedor');return new;end if;
  select round(coalesce(sum(a.amount*ap.exchange_rate),0),6),round(coalesce(sum((a.amount-a.prompt_payment_discount_amount)*ap.exchange_rate),0),6),round(coalesce(sum(a.prompt_payment_discount_amount*ap.exchange_rate),0),6),round(coalesce(sum((a.amount-a.prompt_payment_discount_amount)*ap.exchange_rate*case when si.total>0 then si.tax_total/si.total else 0 end),0),6)
    into v_settlement,v_cash,v_discount,v_vat
  from public.supplier_payment_applications a join public.accounts_payable ap on ap.id=a.accounts_payable_id join public.supplier_invoices si on si.id=a.supplier_invoice_id where a.payment_id=new.id;
  if v_settlement<=0 or round(v_cash,6)<>round(new.total_amount,6) then raise exception 'El pago no concilia con sus aplicaciones.';end if;
  v_lines:=jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',v_settlement,'credit',0,'description','Pago y descuento aplicados a CxP'),jsonb_build_object('role','banks','debit',0,'credit',v_cash,'description','Salida bancaria'));
  if v_discount>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','supplier_credit_note_offset','debit',0,'credit',v_discount,'description','Descuento obtenido por pronto pago'));end if;
  if v_vat>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_paid','debit',v_vat,'credit',0,'description','IVA efectivamente pagado'),jsonb_build_object('role','vat_pending','debit',0,'credit',v_vat,'description','Reclasificación de IVA'));end if;
  perform public.capture_accounting_event(new.company_id,'supplier_payment_confirmed','supplier_payment',new.id,1,new.effective_date,new.confirmed_at,v_lines,jsonb_build_object('description','Pago a proveedor confirmado','reference',new.reference,'prompt_payment_discount_amount',v_discount));return new;
end $$;

revoke all on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) from public;
grant execute on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) to authenticated;
