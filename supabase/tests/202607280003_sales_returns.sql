-- Postventa: devolución parcial/total, idempotencia, inventario recibible,
-- ajuste de CxC, costo reconocido, contabilidad y bloqueo de cancelación.
begin;

do $setup$
declare
  c uuid:='72800000-0000-4000-8000-000000000001';
  u uuid:='72800000-0000-4000-8000-000000000002';
  cfg uuid;rs uuid;r jsonb;controls jsonb;role text;a uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Postventa SQL','Postventa SQL');
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','postventa-sql@example.com','');
  insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);

  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level)
  select c,lpad(n::text,4,'0'),'Cuenta '||n,case when n between 11 and 30 then 'expense' else 'asset' end,
    case when n in(2,7,9) or n between 11 and 30 then 'credit' else 'debit' end,1
  from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into controls
  from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),
    ('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code)
  join public.accounting_accounts a on a.company_id=c and a.code=x.code;
  r:=public.save_accounting_config(c,'MXN',current_date,'{"format":"4"}',
    '{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',
    jsonb_build_object('adjustments',u,'close',u,'reopen',u),'Postventa SQL',controls);
  cfg:=(r->>'id')::uuid;
  perform public.approve_accounting_config(cfg);
  perform public.create_accounting_period(c,to_char(current_date,'YYYY-MM'),date_trunc('month',current_date)::date,
    (date_trunc('month',current_date)+interval '1 month' - interval '1 day')::date);
  r:=public.create_accounting_event_rule_set(c,'replacement_cost','{"sale":"confirmation"}','Matriz postventa');
  rs:=(r->>'id')::uuid;
  for role in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced',
    'purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset',
    'cash_over_short','supplier_credit_note_offset','inventory_adjustment'])
  loop
    select id into a from public.accounting_accounts where company_id=c
      and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=rs)+1)::text,4,'0');
    perform public.set_accounting_event_role_account(rs,role,a);
  end loop;
  perform public.approve_accounting_event_rule_set(rs,'Matriz aprobada para postventa');

  insert into public.customers(id,company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,created_by)
  values('72800000-0000-4000-8000-000000000010',c,'CLI-RETURN','Cliente devolución',true,1000,30,u);
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source)
  values('72800000-0000-4000-8000-000000000011',c,'RETURN','Sucursal devolución','sucursal','manual_review');
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code)
  values('72800000-0000-4000-8000-000000000012',c,'72800000-0000-4000-8000-000000000011','RETURN','Caja devolución','MXN');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,opening_amount)
  values('72800000-0000-4000-8000-000000000013',c,'72800000-0000-4000-8000-000000000012','72800000-0000-4000-8000-000000000011',u,0);
  insert into public.units_of_measure(id,company_id,code,name)
  values('72800000-0000-4000-8000-000000000014',c,'PZA','Pieza');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type,is_active,is_sellable,is_inventory_tracked,sales_unit_id,commercial_review_required)
  values('72800000-0000-4000-8000-000000000015',c,'RETURN-SKU','Producto devolución','PZA','P. TERMINADO',true,true,true,'72800000-0000-4000-8000-000000000014',false);
  insert into public.product_costs(id,company_id,product_id,cost_type,amount,currency_code,valid_from,created_by)
  values('72800000-0000-4000-8000-000000000016',c,'72800000-0000-4000-8000-000000000015','replacement_cost',60,'MXN',now()-interval '1 day',u);
  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,customer_id,sale_type,
    currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,due_date,client_request_id)
  values('72800000-0000-4000-8000-000000000020',c,'72800000-0000-4000-8000-000000000011',
    '72800000-0000-4000-8000-000000000012','72800000-0000-4000-8000-000000000013',u,
    '72800000-0000-4000-8000-000000000010','credit','MXN',200,0,32,232,current_date+30,
    '72800000-0000-4000-8000-000000000021');
  insert into public.sale_items(id,sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,
    gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)
  values('72800000-0000-4000-8000-000000000022','72800000-0000-4000-8000-000000000020',
    '72800000-0000-4000-8000-000000000015','RETURN-SKU','Producto devolución','PZA',2,100,200,0,0,200,32,232);
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)
  values(c,'72800000-0000-4000-8000-000000000011','72800000-0000-4000-8000-000000000015',8);
  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,sale_item_id,actor_id)
  values(c,'72800000-0000-4000-8000-000000000011','72800000-0000-4000-8000-000000000015',-2,8,'sale','72800000-0000-4000-8000-000000000022',u);
  insert into public.customer_receivables(id,company_id,customer_id,sale_id,due_date,original_amount,outstanding_amount,source_kind)
  values('72800000-0000-4000-8000-000000000023',c,'72800000-0000-4000-8000-000000000010',
    '72800000-0000-4000-8000-000000000020',current_date+30,232,232,'sale');
end $setup$;

set constraints all immediate;

do $assertions$
declare
  c uuid:='72800000-0000-4000-8000-000000000001';
  sale uuid:='72800000-0000-4000-8000-000000000020';
  item uuid:='72800000-0000-4000-8000-000000000022';
  first_request uuid:='72800000-0000-4000-8000-000000000030';
  second_request uuid:='72800000-0000-4000-8000-000000000031';
  r jsonb;retry jsonb;v_failed boolean:=false;v_cost numeric;
begin
  r:=public.process_sale_return(c,sale,'Empaque íntegro: mercancía recibible',
    jsonb_build_array(jsonb_build_object('sale_item_id',item,'quantity',1,'restock',true)),
    null,null,first_request);
  retry:=public.process_sale_return(c,sale,'Empaque íntegro: mercancía recibible',
    jsonb_build_array(jsonb_build_object('sale_item_id',item,'quantity',1,'restock',true)),
    null,null,first_request);
  if not (retry->>'idempotent')::boolean or retry->>'id'<>r->>'id' then raise exception 'El reintento duplicó la devolución.';end if;
  if (select outstanding_amount from public.customer_receivables where sale_id=sale)<>116 then raise exception 'La devolución parcial no redujo CxC.';end if;
  if (select quantity_on_hand from public.inventory_balances where location_id='72800000-0000-4000-8000-000000000011' and product_id='72800000-0000-4000-8000-000000000015')<>9 then raise exception 'La mercancía recibible no volvió a inventario.';end if;
  select (line->>'debit')::numeric into v_cost
  from public.accounting_events e cross join lateral jsonb_array_elements(e.requested_lines)line
  where e.source_entity_id=(r->>'id')::uuid and e.event_type='sale_return_confirmed' and line->>'role'='inventory';
  if v_cost<>60 then raise exception 'La devolución no usó el costo reconocido congelado: %',v_cost;end if;

  perform public.process_sale_return(c,sale,'Mercancía dañada: no recibible',
    jsonb_build_array(jsonb_build_object('sale_item_id',item,'quantity',1,'restock',false)),
    null,null,second_request);
  if (select outstanding_amount from public.customer_receivables where sale_id=sale)<>0 then raise exception 'La devolución total no extinguió CxC.';end if;
  if (select quantity_on_hand from public.inventory_balances where location_id='72800000-0000-4000-8000-000000000011' and product_id='72800000-0000-4000-8000-000000000015')<>9 then raise exception 'La mercancía no recibible alteró inventario.';end if;
  if exists(select 1 from public.inventory_ledger where sale_return_item_id in (
    select id from public.sale_return_items where sale_return_id=(select id from public.sale_returns where client_request_id=second_request)
  )) then raise exception 'La mercancía no recibible creó un movimiento de inventario.';end if;
  if exists(select 1 from public.accounting_events e cross join lateral jsonb_array_elements(e.requested_lines)line
    where e.source_entity_id=(select id from public.sale_returns where client_request_id=second_request)
      and line->>'role' in ('inventory','cost_of_goods_sold')) then raise exception 'La mercancía no recibible revirtió costo o inventario contable.';end if;

  begin
    perform public.process_sale_return(c,sale,'Excede cantidad vendida',
      jsonb_build_array(jsonb_build_object('sale_item_id',item,'quantity',1,'restock',true)),
      null,null,'72800000-0000-4000-8000-000000000032');
  exception when others then v_failed:=position('excede la cantidad disponible' in lower(sqlerrm))>0;end;
  if not v_failed then raise exception 'La devolución excedente no fue bloqueada.';end if;
  begin
    insert into public.sale_cancellations(company_id,sale_id,reason,client_request_id)
    values(c,sale,'Cancelación posterior indebida','72800000-0000-4000-8000-000000000033');
    v_failed:=false;
  exception when others then v_failed:=position('ya tiene devoluciones' in lower(sqlerrm))>0;end;
  if not v_failed then raise exception 'La cancelación total posterior no fue bloqueada.';end if;
  if (select count(*) from public.audit_log where company_id=c and action='sale.returned')<>2 then raise exception 'La auditoría no conserva ambas devoluciones.';end if;
  if (select count(*) from public.accounting_events where company_id=c and event_type='sale_return_confirmed' and status='posted')<>2 then raise exception 'Las devoluciones no generaron sus pólizas.';end if;
  raise notice 'Postventa validada: parcial/total, recibible/no recibible, CxC, costo, póliza, idempotencia y auditoría.';
end $assertions$;

rollback;
