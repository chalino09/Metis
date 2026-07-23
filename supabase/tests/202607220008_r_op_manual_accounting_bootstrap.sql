begin;
do $r_op_accounting$
declare
  v_company uuid:='d8000000-0000-4000-8000-000000000001';v_admin uuid:='d8000000-0000-4000-8000-000000000002';v_account jsonb;v_config jsonb;v_controls jsonb;
begin
  insert into public.companies(id,legal_name,display_name) values(v_company,'Contabilidad R-OP','Contabilidad R-OP');
  insert into auth.users(id,aud,role,email,encrypted_password) values(v_admin,'authenticated','authenticated','accounting-r-op@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select v_admin,id,v_company from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',v_admin::text,true);
  v_account:=public.save_accounting_account(v_company,null,'1000','Cuenta de control','asset','debit',null,1,true,true,'Alta inicial',null,'d8000000-0000-4000-8000-000000000010');
  v_controls:=jsonb_build_object('accounts_receivable',v_account->>'id','accounts_payable',v_account->>'id','inventory',v_account->>'id','cash',v_account->>'id','banks',v_account->>'id','vat_pending',v_account->>'id','vat_collected',v_account->>'id','vat_paid',v_account->>'id','withholdings',v_account->>'id');
  v_config:=public.bootstrap_manual_accounting_config(v_company,'MXN',current_date,jsonb_build_object('format','4-3-3'),jsonb_build_object('vat_pending','effective_cash_flow','vat_collected','on_collection','vat_paid','on_payment','withholdings','separate_by_tax'),jsonb_build_object('adjustments',v_admin,'close',v_admin,'reopen',v_admin),v_controls,'Inicio sin saldos históricos','d8000000-0000-4000-8000-000000000011');
  if v_config->>'status'<>'approved' or v_config->>'opening_balance'<>'zero' then raise exception 'El arranque manual no quedó aprobado: %',v_config;end if;
  if (select count(*) from public.accounting_import_batches where company_id=v_company)<>0 then raise exception 'El arranque manual inventó una importación.';end if;
  if (select count(*) from public.accounting_control_accounts where company_id=v_company)<>9 then raise exception 'No se guardaron las nueve cuentas de control.';end if;
  raise notice 'R-OP contable: catálogo y configuración manual aprobados sin archivos ni balanza ficticia.';
end $r_op_accounting$;
rollback;
