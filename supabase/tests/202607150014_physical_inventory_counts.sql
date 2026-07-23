-- Physical count transaction, approval segregation, conflict protection and security.
begin;

do $installation$
begin
  if to_regclass('public.inventory_counts') is null or to_regclass('public.inventory_count_lines') is null then
    raise exception 'Faltan las tablas de conteos físicos.';
  end if;
  if to_regprocedure('public.open_inventory_count(uuid,uuid,uuid)') is null
    or to_regprocedure('public.save_inventory_count_batch(uuid,jsonb)') is null
    or to_regprocedure('public.review_inventory_count(uuid,jsonb,uuid)') is null
    or to_regprocedure('public.submit_inventory_count(uuid,text,uuid)') is null
    or to_regprocedure('public.cancel_inventory_count(uuid,text,uuid)') is null
    or to_regprocedure('public.search_inventory_count_lines(uuid,text,text,integer,integer)') is null
    or to_regprocedure('public.decide_inventory_count(uuid,boolean,text,uuid)') is null then
    raise exception 'Faltan RPCs de conteos físicos.';
  end if;
  if has_table_privilege('authenticated', 'public.inventory_counts', 'insert')
    or has_table_privilege('authenticated', 'public.inventory_count_lines', 'update')
    or has_table_privilege('authenticated', 'public.inventory_ledger', 'insert') then
    raise exception 'authenticated no debe mutar directamente documentos o ledger.';
  end if;
  if has_function_privilege('anon', 'public.decide_inventory_count(uuid,boolean,text,uuid)', 'execute') then
    raise exception 'anon no debe aprobar conteos.';
  end if;
  if not exists (select 1 from public.permissions where code = 'operate_inventory')
    or not exists (select 1 from public.permissions where code = 'approve_inventory_adjustments') then
    raise exception 'Faltan permisos operativos de conteo.';
  end if;
end;
$installation$;

create temporary table physical_count_context (
  company_id uuid,
  location_id uuid,
  product_id uuid,
  counter_id uuid,
  approver_id uuid,
  count_id uuid,
  conflict_count_id uuid
);

do $fixtures$
declare
  v_company uuid := '15140000-0000-4000-8000-000000000001';
  v_location uuid := '15140000-0000-4000-8000-000000000002';
  v_product uuid := '15140000-0000-4000-8000-000000000003';
  v_counter uuid := '15140000-0000-4000-8000-000000000004';
  v_approver uuid := '15140000-0000-4000-8000-000000000005';
  v_user uuid;
begin
  foreach v_user in array array[v_counter, v_approver] loop
    insert into auth.users(id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'count-' || v_user || '@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb,
      '{}'::jsonb, now(), now());
  end loop;

  insert into public.companies(id, legal_name, display_name)
  values (v_company, 'Conteo físico temporal', 'Conteo físico temporal');
  insert into public.locations(id, company_id, external_code, name, location_type, classification_source)
  values (v_location, v_company, 'COUNT-01', 'Ubicación de conteo', 'sucursal', 'manual_review');
  insert into public.products(id, company_id, alpha_sku, internal_sku, name, unit, is_inventory_tracked)
  values (v_product, v_company, 'ALPHA-COUNT-1', 'COUNT-1', 'Producto de conteo', 'PZA', true);
  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  values (v_company, v_location, v_product, 5);
  insert into public.product_costs(company_id, product_id, cost_type, amount, currency_code, valid_from, created_by)
  values (v_company, v_product, 'replacement_cost', 12, 'MXN', now() - interval '1 day', v_counter);

  insert into public.role_permissions(role_id, permission_id)
  select r.id, p.id from public.roles r cross join public.permissions p
  where r.code = 'sucursal' and p.code in ('configure_accounting','approve_accounting_config','configure_accounting_events','approve_accounting_events')
  on conflict do nothing;

  insert into public.user_roles(user_id, role_id, company_id)
  select v_counter, id, v_company from public.roles where code = 'sucursal'
  union all
  select v_approver, id, v_company from public.roles where code = 'direccion_admin';
  insert into public.user_location_access(user_id, location_id)
  values (v_counter, v_location), (v_approver, v_location);
  insert into physical_count_context values (v_company, v_location, v_product, v_counter, v_approver, null, null);
end;
$fixtures$;

do $m4b_setup$
declare
  c uuid := '15140000-0000-4000-8000-000000000001';
  u uuid := '15140000-0000-4000-8000-000000000004';
  cfg uuid; rule_set uuid; result jsonb; controls jsonb; role_code text; account_id uuid;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  select c,lpad(n::text,4,'0'),'Cuenta M4B '||n,case when n between 11 and 30 then 'expense' else 'asset' end,case when n in(2,7,9) or n between 11 and 30 then 'credit' else 'debit' end,1 from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into controls from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code) join public.accounting_accounts a on a.company_id=c and a.code=x.code;
  result:=public.save_accounting_config(c,'MXN',current_date,'{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',u,'close',u,'reopen',u),'M4B conteo',controls);cfg:=(result->>'id')::uuid;perform public.approve_accounting_config(cfg);perform public.create_accounting_period(c,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month'-interval '1 day')::date);
  result:=public.create_accounting_event_rule_set(c,'replacement_cost','{"inventory_adjustment":"approval"}','Matriz conteo');rule_set:=(result->>'id')::uuid;
  for role_code in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop select id into account_id from public.accounting_accounts where company_id=c and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=rule_set)+1)::text,4,'0');perform public.set_accounting_event_role_account(rule_set,role_code,account_id);end loop;perform public.approve_accounting_event_rule_set(rule_set,'Prueba M4B conteo');
end;
$m4b_setup$;

grant select, update on physical_count_context to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', counter_id::text, true) from physical_count_context;

do $counter_flow$
declare
  v_context physical_count_context%rowtype;
  v_open jsonb;
  v_submit jsonb;
  v_denied boolean := false;
begin
  select * into v_context from physical_count_context;
  v_open := public.open_inventory_count(v_context.company_id, v_context.location_id, '15140000-0000-4000-8000-000000000010');
  update physical_count_context set count_id = (v_open ->> 'inventory_count_id')::uuid;
  perform public.save_inventory_count_batch((v_open ->> 'inventory_count_id')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', v_context.product_id, 'counted_quantity', 3)));
  perform public.review_inventory_count((v_open ->> 'inventory_count_id')::uuid, '[]'::jsonb,
    '15140000-0000-4000-8000-000000000014');
  v_submit := public.submit_inventory_count((v_open ->> 'inventory_count_id')::uuid, 'Diferencia física verificada', '15140000-0000-4000-8000-000000000011');
  if v_submit ->> 'status' <> 'pending_approval' or (v_submit ->> 'variance_line_count')::integer <> 1 then
    raise exception 'El conteo con diferencia no quedó pendiente: %', v_submit;
  end if;
  begin
    perform public.decide_inventory_count((v_open ->> 'inventory_count_id')::uuid, true, null, '15140000-0000-4000-8000-000000000012');
  exception when others then v_denied := true;
  end;
  if not v_denied then raise exception 'El contador pudo aprobar su propia diferencia.'; end if;
end;
$counter_flow$;

select set_config('request.jwt.claim.sub', approver_id::text, true) from physical_count_context;

do $approval$
declare
  v_count_id uuid;
  v_result jsonb;
  v_retry jsonb;
begin
  select count_id into v_count_id from physical_count_context;
  v_result := public.decide_inventory_count(v_count_id, true, 'Validación física independiente', '15140000-0000-4000-8000-000000000013');
  v_retry := public.decide_inventory_count(v_count_id, true, 'Validación física independiente', '15140000-0000-4000-8000-000000000013');
  if v_result ->> 'status' <> 'posted' or coalesce((v_result ->> 'idempotent')::boolean, true) then
    raise exception 'La aprobación inicial no se aplicó correctamente: %', v_result;
  end if;
  if not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'El reintento no fue idempotente: %', v_retry;
  end if;
end;
$approval$;

reset role;
set constraints all immediate;

do $m4b_accounting_assertion$
declare c uuid := '15140000-0000-4000-8000-000000000001';d numeric;h numeric;
begin
  if (select count(*) from public.accounting_events where company_id=c and event_type='inventory_adjustment_posted' and status='posted')<>1 then raise exception 'El ajuste físico confirmado no produjo exactamente un evento contable.';end if;
  select sum(l.debit),sum(l.credit) into d,h from public.accounting_journal_lines l where l.company_id=c;if d<>24 or h<>24 then raise exception 'El ajuste físico no quedó valuado a costo: % / %',d,h;end if;
  raise notice 'M4B inventario: ajuste físico valuado y contabilizado una sola vez.';
end;
$m4b_accounting_assertion$;

do $posted_assertions$
declare
  v_context physical_count_context%rowtype;
  v_balance numeric;
  v_movements integer;
begin
  select * into v_context from physical_count_context;
  select quantity_on_hand into v_balance from public.inventory_balances
  where location_id = v_context.location_id and product_id = v_context.product_id;
  select count(*) into v_movements from public.inventory_ledger
  where inventory_count_line_id in (
    select id from public.inventory_count_lines where inventory_count_id = v_context.count_id
  ) and movement_type = 'physical_count_adjustment';
  if v_balance <> 3 or v_movements <> 1 then
    raise exception 'El ajuste físico no quedó conciliado: saldo %, movimientos %.', v_balance, v_movements;
  end if;
end;
$posted_assertions$;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', counter_id::text, true) from physical_count_context;

do $open_conflicting_count$
declare
  v_context physical_count_context%rowtype;
  v_open jsonb;
begin
  select * into v_context from physical_count_context;
  v_open := public.open_inventory_count(v_context.company_id, v_context.location_id, '15140000-0000-4000-8000-000000000020');
  update physical_count_context set conflict_count_id = (v_open ->> 'inventory_count_id')::uuid;
  perform public.save_inventory_count_batch((v_open ->> 'inventory_count_id')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', v_context.product_id, 'counted_quantity', 2)));
  perform public.review_inventory_count((v_open ->> 'inventory_count_id')::uuid, '[]'::jsonb,
    '15140000-0000-4000-8000-000000000024');
  perform public.submit_inventory_count((v_open ->> 'inventory_count_id')::uuid, 'Segunda diferencia', '15140000-0000-4000-8000-000000000021');
end;
$open_conflicting_count$;

reset role;
update public.inventory_balances
set quantity_on_hand = 4, updated_at = now() + interval '1 second'
where location_id = '15140000-0000-4000-8000-000000000002'
  and product_id = '15140000-0000-4000-8000-000000000003';
insert into public.inventory_ledger(company_id, location_id, product_id, quantity_delta, balance_after, movement_type)
values ('15140000-0000-4000-8000-000000000001', '15140000-0000-4000-8000-000000000002',
  '15140000-0000-4000-8000-000000000003', 1, 4, 'controlled_adjustment');

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', approver_id::text, true) from physical_count_context;

do $conflict_assertion$
declare
  v_count_id uuid;
  v_blocked boolean := false;
  v_rejected jsonb;
  v_retry jsonb;
begin
  select conflict_count_id into v_count_id from physical_count_context;
  begin
    perform public.decide_inventory_count(v_count_id, true, null, '15140000-0000-4000-8000-000000000022');
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'Se aplicó un conteo obsoleto sobre inventario modificado.'; end if;
  if (select status from public.inventory_counts where id = v_count_id) <> 'pending_approval' then
    raise exception 'El conflicto modificó indebidamente el documento de conteo.';
  end if;
  v_rejected := public.decide_inventory_count(v_count_id, false, 'El saldo cambió antes de aprobar', '15140000-0000-4000-8000-000000000023');
  v_retry := public.decide_inventory_count(v_count_id, false, 'El saldo cambió antes de aprobar', '15140000-0000-4000-8000-000000000023');
  if v_rejected ->> 'status' <> 'rejected' or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'El rechazo terminal no fue idempotente: %, %', v_rejected, v_retry;
  end if;
end;
$conflict_assertion$;

reset role;

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('request.jwt.claim.sub', counter_id::text, true) from physical_count_context;

do $cancel_open_count$
declare
  v_context physical_count_context%rowtype;
  v_open jsonb;
  v_cancel jsonb;
  v_retry jsonb;
begin
  select * into v_context from physical_count_context;
  v_open := public.open_inventory_count(v_context.company_id, v_context.location_id, '15140000-0000-4000-8000-000000000040');
  v_cancel := public.cancel_inventory_count((v_open ->> 'inventory_count_id')::uuid,
    'Apertura de prueba', '15140000-0000-4000-8000-000000000041');
  v_retry := public.cancel_inventory_count((v_open ->> 'inventory_count_id')::uuid,
    'Apertura de prueba', '15140000-0000-4000-8000-000000000041');
  if v_cancel ->> 'status' <> 'cancelled' or not coalesce((v_retry ->> 'idempotent')::boolean, false) then
    raise exception 'La cancelación no quedó terminal e idempotente: %, %', v_cancel, v_retry;
  end if;
  if exists (select 1 from public.inventory_ledger where inventory_count_line_id in (
    select id from public.inventory_count_lines where inventory_count_id = (v_open ->> 'inventory_count_id')::uuid
  )) then raise exception 'La cancelación generó movimientos de inventario.'; end if;
end;
$cancel_open_count$;

do $no_variance$
declare
  v_context physical_count_context%rowtype;
  v_open jsonb;
  v_submit jsonb;
begin
  select * into v_context from physical_count_context;
  v_open := public.open_inventory_count(v_context.company_id, v_context.location_id, '15140000-0000-4000-8000-000000000030');
  v_submit := public.review_inventory_count((v_open ->> 'inventory_count_id')::uuid,
    jsonb_build_array(jsonb_build_object('product_id', v_context.product_id, 'counted_quantity', 4)),
    '15140000-0000-4000-8000-000000000031');
  if v_submit ->> 'status' <> 'posted' or (v_submit ->> 'variance_line_count')::integer <> 0 then
    raise exception 'El conteo sin diferencias no se cerró directamente: %', v_submit;
  end if;
end;
$no_variance$;

reset role;
do $final_ledger$
declare v_movements integer;
begin
  select count(*) into v_movements from public.inventory_ledger where movement_type = 'physical_count_adjustment'
    and location_id = '15140000-0000-4000-8000-000000000002';
  if v_movements <> 1 then raise exception 'Rechazo o conteo sin diferencia generó movimientos adicionales: %', v_movements; end if;
end;
$final_ledger$;

rollback;
