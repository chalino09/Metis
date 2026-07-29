begin;
do $test$
declare c uuid:='ce000000-0000-4000-8000-000000000001';admin_user uuid:='ce000000-0000-4000-8000-000000000002';branch_user uuid:='ce000000-0000-4000-8000-000000000003';cfg uuid:='ce000000-0000-4000-8000-000000000004';draft_id uuid;stamp timestamptz;controls jsonb;result jsonb;coverage jsonb;blocked boolean:=false;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Cobertura controlada','Cobertura controlada');
  insert into auth.users(id,aud,role,email,encrypted_password) values(admin_user,'authenticated','authenticated','admin-coverage@example.com',''),(branch_user,'authenticated','authenticated','branch-coverage@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select admin_user,id,c from public.roles where code='direccion_admin' union all select branch_user,id,c from public.roles where code='sucursal';
  insert into public.accounting_config_versions(id,company_id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(cfg,c,1,'approved','MXN','2026-06-30','{"format":"4-3-3"}','{"vat_pending":"effective_cash_flow","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate_by_tax"}',jsonb_build_object('adjustments',admin_user,'close',admin_user,'reopen',admin_user),'Configuración inicial',admin_user,now());
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level,accepts_posting)
  select c,'C'||n,'Cuenta '||n,'asset','debit',1,true from generate_series(1,9)n;
  select jsonb_object_agg((array['accounts_receivable','accounts_payable','inventory','cash','banks','vat_pending','vat_collected','vat_paid','withholdings'])[substring(code from 2)::int],id)
  into controls from public.accounting_accounts where company_id=c;
  insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) select cfg,c,key,value::uuid from jsonb_each_text(controls);
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',admin_user::text,true);
  result:=public.start_accounting_config_revision(c,'Cambio de responsables','ce000000-0000-4000-8000-000000000010');draft_id:=(result->>'id')::uuid;
  if (result->>'version')::int<>2 or (select count(*) from public.accounting_control_accounts where config_version_id=draft_id)<>9 then raise exception 'La revisión no copió la configuración vigente: %',result;end if;
  result:=public.start_accounting_config_revision(c,'Reintento','ce000000-0000-4000-8000-000000000010');if not (result->>'idempotent')::boolean or (result->>'id')::uuid<>draft_id then raise exception 'El inicio no fue idempotente.';end if;
  select updated_at into stamp from public.accounting_config_versions where id=draft_id;
  result:=public.save_accounting_config_revision(draft_id,'MXN','2026-07-31','{"format":"4-3-3"}','{"vat_pending":"effective_cash_flow","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate_by_tax"}',jsonb_build_object('adjustments',admin_user,'close',admin_user,'reopen',admin_user),controls,'Actualización julio',stamp,'ce000000-0000-4000-8000-000000000011',false);
  begin perform public.save_accounting_config_revision(draft_id,'MXN','2026-07-31','{"format":"4-3-3"}','{"vat_pending":"effective_cash_flow","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate_by_tax"}',jsonb_build_object('adjustments',admin_user,'close',admin_user,'reopen',admin_user),controls,'Edición atrasada',stamp-interval '1 second','ce000000-0000-4000-8000-000000000012',false);exception when others then blocked:=position('cambió mientras' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'La revisión no protegió concurrencia.';end if;blocked:=false;
  select updated_at into stamp from public.accounting_config_versions where id=draft_id;
  result:=public.save_accounting_config_revision(draft_id,'MXN','2026-07-31','{"format":"4-3-3"}','{"vat_pending":"effective_cash_flow","vat_collected":"on_collection","vat_paid":"on_payment","withholdings":"separate_by_tax"}',jsonb_build_object('adjustments',admin_user,'close',admin_user,'reopen',admin_user),controls,'Aprobación julio',stamp,'ce000000-0000-4000-8000-000000000013',true);
  if result->>'status'<>'approved' or (select status from public.accounting_config_versions where id=cfg)<>'superseded' then raise exception 'La aprobación no versionó correctamente: %',result;end if;
  coverage:=public.get_initial_migration_readiness(c);
  if jsonb_array_length(coverage->'modules')<>7 or (coverage->>'total_checks')::int<>18 or (coverage->>'ready_checks')::int>=(coverage->>'total_checks')::int or coalesce((coverage->>'ready')::boolean,false) then raise exception 'La cobertura volvió a declarar completitud sin evidencia: %',coverage;end if;
  perform set_config('request.jwt.claim.sub',branch_user::text,true);
  begin perform public.start_accounting_config_revision(c,'No autorizado','ce000000-0000-4000-8000-000000000014');exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;
  if not blocked then raise exception 'Un rol operativo versionó Contabilidad.';end if;
  raise notice 'Configuración: cobertura granular y revisión contable versionada aprobadas.';
end $test$;
rollback;
