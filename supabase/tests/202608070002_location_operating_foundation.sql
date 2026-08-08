begin;

do $location_operating_foundation$
declare
  c uuid:='a7000000-0000-4000-8000-000000000001';
  admin_user uuid:='a7000000-0000-4000-8000-000000000002';
  loc uuid;col_a uuid:='a7000000-0000-4000-8000-000000000003';col_b uuid:='a7000000-0000-4000-8000-000000000004';
  product_id uuid;register_id uuid;session_id uuid;period_id uuid;entry_id uuid;config_id uuid;rule_set_id uuid;
  expense_account uuid;cogs_account uuid;offset_account uuid;r jsonb;stamp timestamptz;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Red de prueba','Red de prueba');
  insert into auth.users(id,aud,role,email,encrypted_password) values(admin_user,'authenticated','authenticated','red-admin@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select admin_user,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',admin_user::text,true);

  r:=public.save_company_location_operating_model(
    c,null,'SUC-10','Sucursal Operativa','sucursal',true,
    'Av. Central 10',null,'Centro','Monterrey','Nuevo León','64000','MX',25.6866,-100.3161,
    10,5,200,'CC-SUC-10',date'2026-01-01',null,20,10,500,date'2026-01-01','MXN',
    'Apertura aprobada',null,'a7000000-0000-4000-8000-000000000010'
  );
  loc:=(r->>'id')::uuid;
  if r#>>'{profile,cost_center_code}'<>'CC-SUC-10' or (r#>>'{economic_terms,monthly_base_rent}')::numeric<>20
    or not coalesce((r->>'can_deactivate')::boolean,false) then
    raise exception 'El maestro operativo no quedó completo: %',r;
  end if;

  r:=public.save_company_location_operating_model(
    c,null,'SUC-10','Sucursal Operativa','sucursal',true,
    'Av. Central 10',null,'Centro','Monterrey','Nuevo León','64000','MX',25.6866,-100.3161,
    10,5,200,'CC-SUC-10',date'2026-01-01',null,20,10,500,date'2026-01-01','MXN',
    'Apertura aprobada',null,'a7000000-0000-4000-8000-000000000010'
  );
  if (r->>'id')::uuid<>loc
    or (select count(*) from public.location_economic_terms where location_id=loc)<>1
    or (select count(*) from public.audit_log where company_id=c and action='company.location_operating_model_saved')<>1 then
    raise exception 'El guardado integral no fue idempotente.';
  end if;

  insert into public.collaborators(id,company_id,code,display_name,hired_at)
  values(col_a,c,'COL-A','Responsable A',date'2025-01-01'),(col_b,c,'COL-B','Responsable B',date'2025-01-01');
  perform public.assign_location_responsibility(c,loc,'branch_manager',col_a,date'2026-01-01','Nombramiento inicial','a7000000-0000-4000-8000-000000000011');
  perform public.assign_location_responsibility(c,loc,'branch_manager',col_b,date'2026-02-01','Relevo aprobado','a7000000-0000-4000-8000-000000000012');
  perform public.assign_location_responsibility(c,loc,'branch_manager',col_b,date'2025-12-01','Historia recuperada','a7000000-0000-4000-8000-000000000013');
  if not exists(select 1 from public.location_responsibility_assignments where location_id=loc and collaborator_id=col_a and effective_from=date'2026-01-01' and effective_to=date'2026-01-31')
    or not exists(select 1 from public.location_responsibility_assignments where location_id=loc and effective_from=date'2025-12-01' and effective_to=date'2025-12-31') then
    raise exception 'Las vigencias de responsables se solaparon o perdieron historia.';
  end if;

  insert into public.accounting_config_versions(company_id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_by,approved_at)
  values(c,1,'approved','MXN',date'2025-01-01','{}','{}','{}','Configuración de prueba',admin_user,now()) returning id into config_id;
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  values(c,'6100','Gasto operativo','expense','debit',1) returning id into expense_account;
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  values(c,'5100','Costo de venta','expense','debit',1) returning id into cogs_account;
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  values(c,'1100','Contrapartida','asset','debit',1) returning id into offset_account;
  insert into public.accounting_event_rule_sets(company_id,accounting_config_version_id,version,status,cost_method,recognition_policy,reason,approved_by,approved_at)
  values(c,config_id,1,'approved','replacement_cost','{}','Matriz de prueba',admin_user,now()) returning id into rule_set_id;
  insert into public.accounting_event_role_accounts(rule_set_id,company_id,account_role,account_id)
  values(rule_set_id,c,'cost_of_goods_sold',cogs_account);

  insert into public.products(company_id,alpha_sku,name) values(c,'SKU-1','Producto prueba') returning id into product_id;
  insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from)
  values(c,product_id,'replacement_cost',60,'MXN','2025-01-01T00:00:00Z');
  insert into public.cash_registers(company_id,location_id,code,display_name) values(c,loc,'CAJA-1','Caja 1') returning id into register_id;
  insert into public.cash_sessions(company_id,cash_register_id,location_id,opened_by,opened_at,closed_at,status,opening_amount,expected_closing_amount,counted_closing_amount,variance_amount)
  values(c,register_id,loc,admin_user,'2026-01-01T08:00:00Z','2026-01-31T20:00:00Z','closed',0,0,0,0) returning id into session_id;
  insert into public.sales(company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id,completed_at)
  values(c,loc,register_id,session_id,admin_user,'cash','MXN',100,0,0,100,'a7000000-0000-4000-8000-000000000014','2026-01-15T12:00:00Z') returning id into entry_id;
  insert into public.sale_items(sale_id,product_id,product_code,product_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  values(entry_id,product_id,'SKU-1','Producto prueba',1,100,100,0,0,100,0,100);

  insert into public.accounting_periods(company_id,period_code,starts_on,ends_on) values(c,'2026-01',date'2026-01-01',date'2026-01-31') returning id into period_id;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id)
  values(c,period_id,1,date'2026-01-15','Gastos sucursal','manual_adjustment','draft','a7000000-0000-4000-8000-000000000015') returning id into entry_id;
  insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,debit,credit,location_id) values
    (c,entry_id,1,expense_account,10,0,loc),(c,entry_id,2,cogs_account,60,0,loc),(c,entry_id,3,offset_account,0,70,loc);
  update public.accounting_journal_entries set status='posted',posted_by=admin_user,posted_at=now() where id=entry_id;

  r:=public.get_location_profitability(c,loc,date'2026-01-01',date'2026-01-31');
  if (r#>>'{metrics,net_sales}')::numeric<>100 or (r#>>'{metrics,net_cogs}')::numeric<>60
    or (r#>>'{metrics,gross_margin}')::numeric<>40 or (r#>>'{metrics,operating_expenses}')::numeric<>10
    or (r#>>'{metrics,operating_contribution}')::numeric<>30 or (r#>>'{metrics,sales_per_sqm}')::numeric<>10 then
    raise exception 'Las fórmulas de rentabilidad no usan los hechos canónicos esperados: %',r;
  end if;
  if (r#>>'{coverage,recognized_cost_percent}')::numeric<>100 then raise exception 'La cobertura de costo reconocido es incorrecta: %',r;end if;

  select updated_at into stamp from public.locations where id=loc;
  raise notice 'Maestro, idempotencia, responsables vigentes y rentabilidad por sucursal aprobados en %.',stamp;
end;
$location_operating_foundation$;

rollback;
