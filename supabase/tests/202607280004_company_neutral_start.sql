-- Arranque neutral: empresa nueva sin hechos, sin saldos y sin historia estimada.
begin;

do $setup$
declare
  c constant uuid:='72800004-0000-4000-8000-000000000001';
  u constant uuid:='72800004-0000-4000-8000-000000000002';
begin
  insert into public.companies(id,legal_name,display_name) values(c,'Neutral SQL','Neutral SQL');
  insert into auth.users(id,aud,role,email,encrypted_password)
  values(u,'authenticated','authenticated','neutral-start-sql@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)
  select u,id,c from public.roles where code='direccion_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',u::text,true);
end
$setup$;

do $neutral_assertions$
declare
  c constant uuid:='72800004-0000-4000-8000-000000000001';
  r jsonb;
  summary jsonb;
  charts jsonb;
  metric jsonb;
begin
  r:=public.get_company_neutral_start(c);
  if not (r->>'neutral_start')::boolean then raise exception 'La empresa nueva no inició neutral.';end if;
  if exists(select 1 from public.inventory_balances where company_id=c)
    or exists(select 1 from public.customer_receivables where company_id=c)
    or exists(select 1 from public.accounts_payable where company_id=c)
    or exists(select 1 from public.bank_transactions where company_id=c)
    or exists(select 1 from public.accounting_journal_entries where company_id=c)
  then raise exception 'La consulta neutral creó saldos o hechos.';end if;
  if (select count(*) from public.audit_log where company_id=c and action='company.neutral_start_inspected')<>1
  then raise exception 'La consulta del estado no quedó auditada.';end if;

  summary:=public.bi_get_executive_summary(c,current_date-29,current_date,null,null,null,null);
  select value into metric from jsonb_array_elements(summary->'metrics') where value->>'code'='net_sales';
  if metric->>'value_state'<>'zero_no_operations' or (metric->>'value')::numeric<>0 or not (metric->>'available')::boolean
  then raise exception 'Ventas sin operaciones no se presentó como cero verificable: %',metric;end if;
  select value into metric from jsonb_array_elements(summary->'metrics') where value->>'code'='average_ticket';
  if metric->>'value_state'<>'unavailable' or (metric->>'available')::boolean
  then raise exception 'Ticket promedio sin denominador no quedó No disponible: %',metric;end if;

  charts:=public.bi_get_executive_charts(c,current_date-29,current_date,null,null,null,null);
  select value into metric from jsonb_array_elements(charts->'charts') where value->>'code'='sales';
  if metric->>'value_state'<>'unavailable' or jsonb_array_length(metric->'points')<>0
  then raise exception 'BI reconstruyó una comparación histórica inexistente: %',metric;end if;
  metric:=charts#>'{comparisons,receivables}';
  if metric->>'value_state'<>'zero_no_operations' or not (metric->>'available')::boolean
  then raise exception 'La comparación avanzada ocultó el cero neutral de CxC: %',metric;end if;
end
$neutral_assertions$;

do $module_independence$
declare
  c constant uuid:='72800004-0000-4000-8000-000000000001';
  u constant uuid:='72800004-0000-4000-8000-000000000002';
  l constant uuid:='72800004-0000-4000-8000-000000000010';
  p constant uuid:='72800004-0000-4000-8000-000000000011';
  s constant uuid:='72800004-0000-4000-8000-000000000012';
  i constant uuid:='72800004-0000-4000-8000-000000000013';
  r jsonb;
begin
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source)
  values(l,c,'NEUTRAL','Neutral','sucursal','manual_review');
  insert into public.products(id,company_id,alpha_sku,name)
  values(p,c,'NEUTRAL-SKU','Producto neutral');
  insert into public.inventory_snapshots(id,company_id,source_file_name,snapshot_date,status,created_by)
  values(s,c,'opening-set.csv',current_date,'completed',u);
  insert into public.inventory_snapshot_items(id,snapshot_id,product_id,location_id,quantity,source_alpha_sku)
  values(i,s,p,l,5,'NEUTRAL-SKU');
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)
  values(c,l,p,5);
  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,source_snapshot_item_id,actor_id)
  values(c,l,p,5,5,'opening_snapshot',i,u);

  r:=public.company_neutral_start_snapshot(c);
  if (r#>>'{modules,inventory,neutral}')::boolean then raise exception 'La apertura formal no activó inventario.';end if;
  if not (r#>>'{modules,receivables,neutral}')::boolean
    or not (r#>>'{modules,payables,neutral}')::boolean
    or not (r#>>'{modules,cash_banks,neutral}')::boolean
    or not (r#>>'{modules,accounting,neutral}')::boolean
  then raise exception 'Una apertura de inventario modificó módulos ajenos.';end if;
end
$module_independence$;

rollback;
