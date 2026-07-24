begin;

do $test$
declare
  v_actor uuid;
  v_company uuid:='72400000-0000-4000-8000-000000000001';
  v_supplier uuid;
  v_invoice uuid:='72400000-0000-4000-8000-000000000010';
  v_payable uuid:='72400000-0000-4000-8000-000000000011';
  v_account uuid:=gen_random_uuid();
  v_proposal uuid:=gen_random_uuid();
  v_payment uuid;
  v_result jsonb;
  v_rejected boolean:=false;
begin
  if to_regprocedure('public.save_supplier_prompt_payment_terms(uuid,uuid,jsonb)') is null
    or to_regprocedure('public.snapshot_supplier_prompt_payment_terms(uuid,uuid,uuid)') is null
    or to_regprocedure('public.search_supplier_payment_calendar(uuid,text,uuid,text,date,date,integer,integer)') is null then
    raise exception 'Faltan RPC de pronto pago.';
  end if;

  select ur.user_id into v_actor
  from public.user_roles ur join public.roles r on r.id=ur.role_id
  where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;

  insert into public.companies(id,legal_name,display_name)
  values(v_company,'Pronto pago','Pronto pago');
  insert into public.user_roles(user_id,role_id,company_id)
  select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);

  v_result:=public.save_supplier_v2(
    v_company,null,'Proveedor prueba','Proveedor prueba','moral','PPA010101AAA',
    null,'50000','MX',null,'pronto@example.com','7222787751',null,null,null,null,
    null,null,null,30,true,null
  );
  v_supplier:=(v_result->>'id')::uuid;

  v_result:=public.save_supplier_prompt_payment_terms(
    v_company,v_supplier,
    '[{"tier_number":1,"term_days":30,"discount_components":[10,5]},
      {"tier_number":2,"term_days":60,"discount_components":[5]}]'::jsonb
  );
  if jsonb_array_length(v_result->'terms')<>2
    or v_result#>>'{terms,0,discount_expression}'<>'10%+5%'
    or (v_result#>>'{terms,0,effective_discount_percent}')::numeric<>14.5 then
    raise exception 'No se conservaron correctamente los descuentos: %',v_result;
  end if;

  insert into public.supplier_invoices(
    id,company_id,supplier_id,source_kind,document_type,status,folio,issued_date,due_date,
    currency_code,exchange_rate,base_currency_code,subtotal,total,base_total,confirmed_at,
    supplier_payable_term_days_snapshot,due_date_source
  ) values(
    v_invoice,v_company,v_supplier,'expense','invoice','confirmed','PP-001',
    current_date,current_date+30,'MXN',1,'MXN',100,100,100,now(),30,'supplier_terms'
  );
  perform public.snapshot_supplier_prompt_payment_terms(v_company,v_supplier,v_invoice);
  if (select count(*) from public.supplier_invoice_prompt_payment_terms where supplier_invoice_id=v_invoice)<>2 then
    raise exception 'No se congelaron las condiciones en la factura.';
  end if;

  insert into public.accounts_payable(
    id,company_id,supplier_id,supplier_invoice_id,currency_code,exchange_rate,
    base_currency_code,original_amount,outstanding_amount,original_base_amount,
    outstanding_base_amount,issued_date,due_date
  ) values(
    v_payable,v_company,v_supplier,v_invoice,'MXN',1,'MXN',100,100,100,100,
    current_date,current_date+30
  );
  v_result:=public.search_supplier_payment_calendar(
    v_company,null,null,null,current_date,current_date+60,1,25
  );
  if v_result#>>'{items,0,eligible_prompt_payment,discount_expression}'<>'10%+5%'
    or (v_result#>>'{items,0,eligible_prompt_payment,estimated_total}')::numeric<>85.5
    or (select outstanding_amount from public.accounts_payable where id=v_payable)<>100 then
    raise exception 'Agenda no proyectó el pronto pago sin alterar el saldo: %',v_result;
  end if;

  begin
    perform public.recognize_supplier_late_payment_charge(
      v_company,v_invoice,'n/a','n/a','72400000-0000-4000-8000-000000000098'
    );
  exception when others then
    v_rejected:=position('operación fue retirada' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'La operación incorrecta de aumento sigue disponible.';end if;

  insert into public.supplier_paying_accounts(id,company_id,bank_name,alias,currency_code,account_last4)
  values(v_account,v_company,'Banco prueba','Cuenta prueba','MXN','0001');
  insert into public.supplier_payment_proposals(id,company_id,supplier_id,currency_code,status,total_proposed)
  values(v_proposal,v_company,v_supplier,'MXN','draft',85.5);
  insert into public.supplier_payment_proposal_lines(company_id,proposal_id,accounts_payable_id,proposed_amount,balance_snapshot,due_date_snapshot)
  values(v_company,v_proposal,v_payable,85.5,100,current_date+30);
  update public.supplier_payment_proposals set status='approved',submitted_at=now(),approved_at=now() where id=v_proposal;
  v_result:=public.confirm_supplier_payment(v_company,v_proposal,v_account,current_date,'03','PP-DESC-001','72400000-0000-4000-8000-000000000099');
  v_payment:=(v_result->>'id')::uuid;
  if (select outstanding_amount from public.accounts_payable where id=v_payable)<>0
    or (select amount from public.supplier_payment_applications where payment_id=v_payment)<>100
    or (select prompt_payment_discount_amount from public.supplier_payment_applications where payment_id=v_payment)<>14.5
    or (select total_amount from public.supplier_payments where id=v_payment)<>85.5 then
    raise exception 'El pronto pago no liquidó ni separó correctamente el descuento.';
  end if;
  perform public.reverse_supplier_payment(v_company,v_payment,'Prueba de reversa','72400000-0000-4000-8000-000000000100');
  if (select outstanding_amount from public.accounts_payable where id=v_payable)<>100 then
    raise exception 'La reversa no restauró la CxP completa.';
  end if;

  raise notice 'Días de crédito, descuentos encadenados, liquidación y reversa aprobados.';
end;
$test$;

rollback;
