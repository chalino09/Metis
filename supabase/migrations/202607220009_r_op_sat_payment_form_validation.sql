-- Satrapy · R-OP: la forma de pago de proveedor es una clave SAT, no texto libre.
-- Se valida en la frontera transaccional para pagos futuros. No se agrega una
-- restricción retroactiva a la tabla porque puede contener descripciones históricas.

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
    select l.accounts_payable_id,l.proposed_amount,ap.supplier_invoice_id,ap.company_id,ap.supplier_id,ap.currency_code,ap.outstanding_amount,ap.reversed_at
    from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id
    where l.proposal_id=p_proposal_id order by ap.id for update of ap
  loop
    if v_line.company_id<>p_company_id or v_line.supplier_id<>v_proposal.supplier_id or v_line.currency_code<>v_proposal.currency_code then raise exception 'Todas las aplicaciones deben conservar empresa, proveedor y moneda.';end if;
    if v_line.reversed_at is not null then raise exception 'No se puede aplicar contra una CxP revertida.';end if;
    if v_line.outstanding_amount<v_line.proposed_amount then raise exception 'El pago excede el saldo actual de una CxP.';end if;
    insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,balance_before,balance_after)
    values(p_company_id,v_payment,v_line.accounts_payable_id,v_line.supplier_invoice_id,v_line.proposed_amount,v_line.outstanding_amount,round(v_line.outstanding_amount-v_line.proposed_amount,6));
    update public.accounts_payable set outstanding_amount=round(outstanding_amount-v_line.proposed_amount,6) where id=v_line.accounts_payable_id;
    v_total:=v_total+v_line.proposed_amount;
  end loop;
  if v_total<=0 or round(v_total,6)<>round(v_proposal.total_proposed,6) then raise exception 'Las aplicaciones no concilian con la propuesta aprobada.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'supplier_payment.confirmed','supplier_payment',v_payment,jsonb_build_object('proposal_id',p_proposal_id,'supplier_id',v_proposal.supplier_id,'currency_code',v_proposal.currency_code,'total_amount',v_total,'effective_date',p_effective_date,'paying_account_id',v_account.id,'payment_form_code',v_payment_form_code,'reference',trim(p_reference),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_payment,'proposal_id',p_proposal_id,'status','confirmed','reconciliation_status','unreconciled','total_amount',round(v_total,6),'idempotent',false);
  insert into public.supplier_payment_requests(company_id,request_id,payment_id,operation,result) values(p_company_id,p_client_request_id,v_payment,'confirm',v_result);
  return v_result;
end $$;

revoke all on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) from public;
grant execute on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) to authenticated;
