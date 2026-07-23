begin;

do $test$
declare
  v_preparer uuid:='3e100000-0000-4000-8000-000000000091';v_approver uuid:='3e100000-0000-4000-8000-000000000092';v_outsider uuid:='3e100000-0000-4000-8000-000000000093';
  v_company uuid:='3e100000-0000-4000-8000-000000000001';v_other uuid:='3e100000-0000-4000-8000-000000000002';v_supplier uuid;v_other_supplier uuid;
  v_invoice_overdue uuid;v_invoice_upcoming uuid;v_invoice_future uuid;v_invoice_usd uuid;v_payable_overdue uuid;v_payable_upcoming uuid;v_payable_future uuid;v_payable_usd uuid;
  v_result jsonb;v_proposal uuid;v_rejected uuid;v_cancelled uuid;v_forbidden boolean:=false;
  v_save uuid:='3e100000-0000-4000-8000-000000000010';v_submit uuid:='3e100000-0000-4000-8000-000000000011';v_approve uuid:='3e100000-0000-4000-8000-000000000012';
  v_balance numeric;v_invoice_count bigint;v_inventory bigint;v_ledger bigint;v_cost bigint;v_alpha_payments bigint;
begin
  if to_regprocedure('public.save_supplier_payment_proposal(uuid,uuid,uuid,text,jsonb,uuid,timestamptz)') is null then raise exception 'Faltan RPC de M3E1.';end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payment_proposals' and policyname='supplier_payment_proposals_read') or not exists(select 1 from pg_policies where schemaname='public' and tablename='supplier_payment_proposal_lines' and policyname='supplier_payment_proposal_lines_read') then raise exception 'Faltan políticas RLS de propuestas.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Propuestas M3E1','Propuestas M3E1'),(v_other,'Otra M3E1','Otra M3E1');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_preparer,'authenticated','authenticated','prepara-m3e1@example.com',''),(v_approver,'authenticated','authenticated','aprueba-m3e1@example.com',''),(v_outsider,'authenticated','authenticated','ajeno-m3e1@example.com','');
  insert into public.role_permissions(role_id,permission_id) select r.id,p.id from public.roles r cross join public.permissions p where r.code='almacen' and p.code in ('view_accounts_payable','prepare_supplier_payment_proposals') on conflict do nothing;
  insert into public.role_permissions(role_id,permission_id) select r.id,p.id from public.roles r cross join public.permissions p where r.code='sucursal' and p.code in ('view_accounts_payable','approve_supplier_payment_proposals') on conflict do nothing;
  insert into public.user_roles(user_id,role_id,company_id) select v_preparer,id,v_company from public.roles where code='almacen';
  insert into public.user_roles(user_id,role_id,company_id) select v_approver,id,v_company from public.roles where code='sucursal';
  insert into public.user_roles(user_id,role_id,company_id) select v_outsider,id,v_other from public.roles where code='almacen';
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-E1','Proveedor E1','moral','MX',true) returning id into v_supplier;
  insert into public.suppliers(company_id,code,display_name,legal_entity_type,country_code,is_active) values(v_company,'SUP-E1-B','Otro proveedor E1','moral','MX',true) returning id into v_other_supplier;

  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E1','001',current_date-40,current_date-1,'MXN',100,100,100,now(),now()) returning id into v_invoice_overdue;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E1','002',current_date-20,current_date+15,'MXN',200,200,200,now(),now()) returning id into v_invoice_upcoming;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E1','003',current_date-10,current_date+16,'MXN',300,300,300,now(),now()) returning id into v_invoice_future;
  insert into public.supplier_invoices(company_id,supplier_id,source_kind,status,series,folio,issued_date,due_date,currency_code,exchange_rate,subtotal,total,base_total,expense_approved_at,confirmed_at)
  values(v_company,v_supplier,'expense','confirmed','E1','004',current_date-10,current_date+5,'USD',18,50,50,900,now(),now()) returning id into v_invoice_usd;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_overdue,'MXN',100,100,current_date-40,current_date-1) returning id into v_payable_overdue;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_upcoming,'MXN',200,200,current_date-20,current_date+15) returning id into v_payable_upcoming;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_future,'MXN',300,300,current_date-10,current_date+16) returning id into v_payable_future;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,exchange_rate,original_amount,outstanding_amount,issued_date,due_date) values(v_company,v_supplier,v_invoice_usd,'USD',18,50,50,current_date-10,current_date+5) returning id into v_payable_usd;
  select sum(outstanding_amount),count(*) into v_balance,v_invoice_count from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id where ap.company_id=v_company;
  select count(*) into v_inventory from public.inventory_balances;select count(*) into v_ledger from public.inventory_ledger;select count(*) into v_cost from public.product_costs;select count(*) into v_alpha_payments from public.alpha_purchasing_import_payment_evidence;

  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_preparer::text,true);
  v_result:=public.search_supplier_payable_due_inbox(v_company,null,null,null,'overdue',null,null,null,null,1,25);
  if (v_result#>>'{pagination,total}')::int<>1 or v_result#>>'{items,0,id}'<>v_payable_overdue::text then raise exception 'Bandeja vencida incorrecta: %',v_result;end if;
  v_result:=public.search_supplier_payable_due_inbox(v_company,null,null,'MXN','upcoming',null,null,150,250,1,25);
  if (v_result#>>'{pagination,total}')::int<>1 or v_result#>>'{items,0,id}'<>v_payable_upcoming::text then raise exception 'Corte próximo de 15 días o filtros incorrectos: %',v_result;end if;
  v_result:=public.search_supplier_payable_due_inbox(v_company,null,null,null,'future',null,null,null,null,1,25);
  if (v_result#>>'{pagination,total}')::int<>1 or v_result#>>'{items,0,id}'<>v_payable_future::text then raise exception 'Bandeja futura incorrecta: %',v_result;end if;

  begin perform public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_overdue,'proposed_amount',101)),gen_random_uuid(),null);exception when others then v_forbidden:=position('no superar el saldo' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se permitió proponer más que el saldo.';end if;v_forbidden:=false;
  begin perform public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_usd,'proposed_amount',10)),gen_random_uuid(),null);exception when others then v_forbidden:=position('mismo proveedor y moneda' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Se mezclaron monedas en una propuesta.';end if;v_forbidden:=false;

  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_overdue,'proposed_amount',40),jsonb_build_object('accounts_payable_id',v_payable_upcoming,'proposed_amount',200)),v_save,null);v_proposal:=(v_result->>'id')::uuid;
  if v_result#>>'{total_proposed}'<>'240.000000' or (select count(*) from public.supplier_payment_proposal_lines where proposal_id=v_proposal)<>2 then raise exception 'Borrador parcial/total incorrecto: %',v_result;end if;
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN','[]'::jsonb,v_save,null);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select count(*) from public.supplier_payment_proposals where company_id=v_company)<>1 then raise exception 'Guardado no idempotente.';end if;
  v_result:=public.submit_supplier_payment_proposal(v_company,v_proposal,v_submit);
  v_result:=public.submit_supplier_payment_proposal(v_company,v_proposal,v_submit);
  if coalesce((v_result->>'idempotent')::boolean,false)=false then raise exception 'Envío no idempotente.';end if;
  begin perform public.decide_supplier_payment_proposal(v_company,v_proposal,'approved',null,gen_random_uuid());exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Preparador aprobó sin permiso.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_approver::text,true);
  v_result:=public.decide_supplier_payment_proposal(v_company,v_proposal,'approved',null,v_approve);
  v_result:=public.decide_supplier_payment_proposal(v_company,v_proposal,'approved',null,v_approve);
  if coalesce((v_result->>'idempotent')::boolean,false)=false or (select status from public.supplier_payment_proposals where id=v_proposal)<>'approved' then raise exception 'Aprobación no idempotente.';end if;
  begin perform public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_future,'proposed_amount',10)),gen_random_uuid(),null);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Aprobador preparó sin permiso.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_preparer::text,true);
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'MXN',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_future,'proposed_amount',25)),gen_random_uuid(),null);v_rejected:=(v_result->>'id')::uuid;
  perform public.submit_supplier_payment_proposal(v_company,v_rejected,gen_random_uuid());
  perform set_config('request.jwt.claim.sub',v_approver::text,true);
  begin perform public.decide_supplier_payment_proposal(v_company,v_rejected,'rejected','',gen_random_uuid());exception when others then v_forbidden:=position('requiere motivo' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Rechazo sin motivo.';end if;v_forbidden:=false;
  perform public.decide_supplier_payment_proposal(v_company,v_rejected,'rejected','Flujo de efectivo no autorizado.',gen_random_uuid());
  if (select rejection_reason from public.supplier_payment_proposals where id=v_rejected)<>'Flujo de efectivo no autorizado.' then raise exception 'Motivo de rechazo no conservado.';end if;

  perform set_config('request.jwt.claim.sub',v_preparer::text,true);
  v_result:=public.save_supplier_payment_proposal(v_company,null,v_supplier,'USD',jsonb_build_array(jsonb_build_object('accounts_payable_id',v_payable_usd,'proposed_amount',10)),gen_random_uuid(),null);v_cancelled:=(v_result->>'id')::uuid;
  perform public.cancel_supplier_payment_proposal(v_company,v_cancelled,'Se reprogramará en otra propuesta.',gen_random_uuid());
  if (select status from public.supplier_payment_proposals where id=v_cancelled)<>'cancelled' then raise exception 'Cancelación incorrecta.';end if;

  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin perform public.search_supplier_payment_proposals(v_company,null,null,null,1,25);exception when others then v_forbidden:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not v_forbidden then raise exception 'Empresa ajena consultó propuestas.';end if;v_forbidden:=false;

  perform set_config('request.jwt.claim.sub',v_preparer::text,true);
  if (select sum(outstanding_amount) from public.accounts_payable where company_id=v_company)<>v_balance or (select count(*) from public.accounts_payable where company_id=v_company)<>v_invoice_count then raise exception 'M3E1 modificó saldos de CxP.';end if;
  if (select count(*) from public.inventory_balances)<>v_inventory or (select count(*) from public.inventory_ledger)<>v_ledger or (select count(*) from public.product_costs)<>v_cost then raise exception 'M3E1 modificó inventario o costos.';end if;
  if (select count(*) from public.alpha_purchasing_import_payment_evidence)<>v_alpha_payments then raise exception 'M3E1 alteró evidencia histórica Alpha.';end if;
  raise notice 'M3E1: vencimientos 15 días, filtros, parcial/total, flujo, permisos, RLS, idempotencia y no afectación aprobados.';
end;
$test$;

rollback;
