begin;
do $m4a_unified$
declare v_company uuid:='4a030000-0000-4000-8000-000000000001';v_user uuid:='4a030000-0000-4000-8000-000000000010';v_config uuid;v_controls jsonb;v_result jsonb;
begin
  if to_regprocedure('public.complete_accounting_config(uuid,jsonb,text)') is null then raise exception 'Falta completar configuración M4A.';end if;
  if has_function_privilege('anon','public.complete_accounting_config(uuid,jsonb,text)','execute') then raise exception 'anon puede completar configuración contable.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'M4A unificado','M4A unificado');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_user,'authenticated','authenticated','m4a-unified@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_user,id,v_company from public.roles where code='direccion_admin';
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level) values
    (v_company,'1010','CxC','asset','debit',1),(v_company,'2010','CxP','liability','credit',1),(v_company,'1020','Inventario','asset','debit',1),
    (v_company,'1030','Caja','asset','debit',1),(v_company,'1040','Bancos','asset','debit',1),(v_company,'1050','IVA pendiente','asset','debit',1),
    (v_company,'2020','IVA cobrado','liability','credit',1),(v_company,'1060','IVA pagado','asset','debit',1),(v_company,'2030','Retenciones','liability','credit',1);
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_user::text,true);
  v_result:=public.save_accounting_config(v_company,'MXN',date '2026-06-30','{"format":"4"}','{"vat_pending":"separate","vat_collected":"collection","vat_paid":"payment","withholdings":"separate"}',jsonb_build_object('adjustments','Contador','close','Contralor','reopen','Dirección'),'Definición inicial','{}');v_config:=(v_result->>'id')::uuid;
  if (v_result->>'complete')::boolean then raise exception 'La configuración inicial no debe fingir cuentas de control.';end if;
  select jsonb_object_agg(x.k,a.id) into v_controls from (values('accounts_receivable','1010'),('accounts_payable','2010'),('inventory','1020'),('cash','1030'),('banks','1040'),('vat_pending','1050'),('vat_collected','2020'),('vat_paid','1060'),('withholdings','2030'))x(k,code) join public.accounting_accounts a on a.company_id=v_company and a.code=x.code;
  v_result:=public.complete_accounting_config(v_config,v_controls,'Aprobación controlada M4A');
  if v_result->>'status'<>'approved' or (select count(*) from public.accounting_control_accounts where config_version_id=v_config)<>9 then raise exception 'No se completó la configuración después del catálogo.';end if;
  raise notice 'M4A unificado: configuración antes del catálogo y cuentas de control posteriores aprobadas.';
end;$m4a_unified$;
rollback;
