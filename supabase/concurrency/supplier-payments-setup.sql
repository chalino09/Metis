\set ON_ERROR_STOP on
do $setup$
declare v_actor uuid;v_company uuid:='3b000000-0000-4000-8000-000000000001';v_supplier uuid;v_invoice_overlap uuid;v_invoice_idem uuid;v_payable_overlap uuid;v_payable_idem uuid;v_account uuid;v_result jsonb;v_proposal_a uuid;v_proposal_b uuid;v_proposal_idem uuid;
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  delete from public.companies where id=v_company;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Concurrencia M3E2','Concurrencia M3E2');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_actor::text,true);
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-CONC-E2','Proveedor concurrencia E2','moral','MX',true) returning id into v_supplier;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at) values(v_company,v_supplier,'expense','confirmed','CE2','OVERLAP',current_date,current_date,'MXN',100,100,100,now(),now()) returning id into v_invoice_overlap;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at) values(v_company,v_supplier,'expense','confirmed','CE2','IDEM',current_date,current_date,'MXN',60,60,60,now(),now()) returning id into v_invoice_idem;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_overlap,'MXN',100,100,current_date,current_date) returning id into v_payable_overlap;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_idem,'MXN',60,60,current_date,current_date) returning id into v_payable_idem;
  v_result:=public.save_supplier_paying_account(v_company,null,'Banco concurrencia','Cuenta concurrencia','MXN','9999',true);v_account:=(v_result->>'id')::uuid;
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_overlap,'proposed_amount',80)),gen_random_uuid(),null);v_proposal_a:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_proposal_a,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_proposal_a,'approved',null,gen_random_uuid());
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_overlap,'proposed_amount',80)),gen_random_uuid(),null);v_proposal_b:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_proposal_b,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_proposal_b,'approved',null,gen_random_uuid());
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_idem,'proposed_amount',60)),gen_random_uuid(),null);v_proposal_idem:=(v_result->>'id')::uuid;perform public.submit_supplier_payment_proposal(v_company,v_proposal_idem,gen_random_uuid());perform public.decide_supplier_payment_proposal(v_company,v_proposal_idem,'approved',null,gen_random_uuid());
  create table if not exists public.m3e2_concurrency_context(company_id uuid,actor_id uuid,paying_account_id uuid,proposal_a uuid,proposal_b uuid,proposal_idem uuid,payable_overlap uuid,payable_idem uuid,idempotency_key uuid);
  truncate public.m3e2_concurrency_context;
  insert into public.m3e2_concurrency_context values(v_company,v_actor,v_account,v_proposal_a,v_proposal_b,v_proposal_idem,v_payable_overlap,v_payable_idem,'3b000000-0000-4000-8000-000000000099');
end $setup$;
