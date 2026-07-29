-- Satrapy · Arranque neutral por empresa.
-- El estado se deriva de hechos canónicos: no agrega flags, no crea saldos y no
-- modifica empresas existentes. Las aperturas siguen entrando por sus flujos
-- transaccionales, importables y auditados.

create or replace function public.company_neutral_start_snapshot(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_inventory_operations bigint;
  v_inventory_opening_sets bigint;
  v_cash_operations bigint;
  v_cash_opening_sets bigint;
  v_bank_transactions bigint;
  v_bank_opening_sets bigint;
  v_receivable_operations bigint;
  v_receivable_opening_sets bigint;
  v_sales_operations bigint;
  v_payable_operations bigint;
  v_accounting_operations bigint;
  v_accounting_opening_sets bigint;
  v_neutral boolean;
  v_modules jsonb;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then
    raise exception 'Empresa no disponible.';
  end if;

  select
    count(*) filter(where movement_type<>'opening_snapshot'),
    count(distinct source_snapshot_item_id) filter(where movement_type='opening_snapshot')
  into v_inventory_operations,v_inventory_opening_sets
  from public.inventory_ledger
  where company_id=p_company_id;

  select
    count(*) filter(where movement_type<>'opening'),
    count(*) filter(where movement_type='opening')
  into v_cash_operations,v_cash_opening_sets
  from public.cash_movements
  where company_id=p_company_id;

  select count(*) into v_bank_transactions
  from public.bank_transactions
  where company_id=p_company_id;

  select count(*) into v_bank_opening_sets
  from public.bank_statement_batches
  where company_id=p_company_id and status='promoted';

  select
    count(*) filter(where sale_id is not null),
    count(*) filter(where sale_id is null and source_cutoff_date is not null)
  into v_receivable_operations,v_receivable_opening_sets
  from public.customer_receivables
  where company_id=p_company_id;

  select count(*) into v_sales_operations
  from public.sales
  where company_id=p_company_id
    and not exists(select 1 from public.sale_cancellations where sale_id=sales.id);

  select count(*) into v_payable_operations
  from public.accounts_payable
  where company_id=p_company_id;

  select
    count(*) filter(where source_type<>'opening'),
    count(*) filter(where source_type='opening')
  into v_accounting_operations,v_accounting_opening_sets
  from public.accounting_journal_entries
  where company_id=p_company_id and status in('posted','reversed');

  v_modules:=jsonb_build_object(
    'inventory',jsonb_build_object(
      'neutral',v_inventory_operations+v_inventory_opening_sets=0,
      'operation_count',v_inventory_operations,
      'opening_set_count',v_inventory_opening_sets,
      'empty_value','zero_no_operations',
      'next_step','/satrapy/configuracion/migracion-inicial'
    ),
    'cash_banks',jsonb_build_object(
      'neutral',v_cash_operations+v_cash_opening_sets+v_bank_transactions+v_bank_opening_sets=0,
      'operation_count',v_cash_operations+v_bank_transactions,
      'opening_set_count',v_cash_opening_sets+v_bank_opening_sets,
      'empty_value','zero_no_operations',
      'next_step','/satrapy/configuracion/importaciones'
    ),
    'receivables',jsonb_build_object(
      'neutral',v_receivable_operations+v_receivable_opening_sets=0,
      'operation_count',v_receivable_operations,
      'opening_set_count',v_receivable_opening_sets,
      'empty_value','zero_no_operations',
      'next_step','/satrapy/configuracion/importaciones'
    ),
    'sales',jsonb_build_object(
      'neutral',v_sales_operations=0,
      'operation_count',v_sales_operations,
      'opening_set_count',0,
      'empty_value','zero_no_operations',
      'next_step','/satrapy/ventas/punto-de-venta'
    ),
    'payables',jsonb_build_object(
      'neutral',v_payable_operations=0,
      'operation_count',v_payable_operations,
      'opening_set_count',0,
      'empty_value','zero_no_operations',
      'next_step','/satrapy/configuracion/importaciones'
    ),
    'accounting',jsonb_build_object(
      'neutral',v_accounting_operations+v_accounting_opening_sets=0,
      'operation_count',v_accounting_operations,
      'opening_set_count',v_accounting_opening_sets,
      'empty_value','no_data',
      'next_step','/satrapy/contabilidad/apertura'
    )
  );

  v_neutral:=
    (v_modules#>>'{inventory,neutral}')::boolean
    and (v_modules#>>'{sales,neutral}')::boolean
    and (v_modules#>>'{cash_banks,neutral}')::boolean
    and (v_modules#>>'{receivables,neutral}')::boolean
    and (v_modules#>>'{payables,neutral}')::boolean
    and (v_modules#>>'{accounting,neutral}')::boolean;

  v_modules:=v_modules||jsonb_build_object(
    'bi',jsonb_build_object(
      'neutral',v_neutral,
      'empty_value','zero_or_unavailable_by_metric',
      'next_step','/satrapy/configuracion/migracion-inicial'
    )
  );

  return jsonb_build_object(
    'company_id',p_company_id,
    'neutral_start',v_neutral,
    'derived_at',clock_timestamp(),
    'modules',v_modules,
    'rules',jsonb_build_object(
      'creates_opening_balances',false,
      'manual_row_capture_supported',false,
      'opening_method','server_side_transactional_import_set',
      'historical_estimation_allowed',false
    )
  );
end $$;

create or replace function public.get_company_neutral_start(p_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_result jsonb;
begin
  v_result:=public.company_neutral_start_snapshot(p_company_id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,
    auth.uid(),
    'company.neutral_start_inspected',
    'company',
    p_company_id,
    jsonb_build_object(
      'neutral_start',v_result->'neutral_start',
      'module_evidence',(select jsonb_object_agg(key,jsonb_build_object(
        'operation_count',value->'operation_count',
        'opening_set_count',value->'opening_set_count'
      )) from jsonb_each(v_result->'modules') where key<>'bi')
    )
  );
  return v_result;
end $$;

create or replace function public.bi_apply_neutral_start_to_summary(p_payload jsonb,p_state jsonb)
returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare
  v_metric jsonb;
  v_metrics jsonb:='[]'::jsonb;
  v_code text;
  v_module text;
  v_module_neutral boolean;
begin
  for v_metric in select value from jsonb_array_elements(coalesce(p_payload->'metrics','[]'::jsonb))
  loop
    v_code:=v_metric->>'code';
    v_module:=case
      when v_code in('net_sales','tickets','average_ticket','gross_margin') then 'sales'
      when v_code in('collections','receivables','overdue_receivables') then 'receivables'
      when v_code in('supplier_payments','payables') then 'payables'
      when v_code in('bank_net_flow','bank_reconciliation') then 'cash_banks'
      when v_code='inventory_value' then 'inventory'
      else null
    end;
    v_module_neutral:=v_module is not null and coalesce((p_state#>>array['modules',v_module,'neutral'])::boolean,false);

    if v_module_neutral and v_code in('average_ticket','bank_reconciliation') then
      v_metric:=v_metric||jsonb_build_object(
        'value',null,
        'previous_value',null,
        'available',false,
        'value_state','unavailable',
        'comparison_available',false,
        'reason',case when v_code='average_ticket'
          then 'No disponible: todavía no hay tickets para calcular un promedio.'
          else 'No disponible: todavía no hay movimientos bancarios para calcular una proporción.' end
      );
    elsif v_module_neutral then
      v_metric:=v_metric||jsonb_build_object(
        'value',0,
        'previous_value',null,
        'available',true,
        'value_state','zero_no_operations',
        'comparison_available',false,
        'reason','Sin operaciones ni saldos iniciales formalmente importados.'
      );
    end if;
    v_metrics:=v_metrics||jsonb_build_array(v_metric);
  end loop;
  return jsonb_set(p_payload,'{metrics}',v_metrics,true)||jsonb_build_object('neutral_start',p_state);
end $$;

create or replace function public.bi_apply_neutral_start_to_charts(p_payload jsonb,p_state jsonb)
returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare
  v_chart jsonb;
  v_charts jsonb:='[]'::jsonb;
  v_comparison jsonb;
  v_comparisons jsonb:=coalesce(p_payload->'comparisons','{}'::jsonb);
  v_code text;
  v_module text;
  v_module_neutral boolean;
begin
  for v_chart in select value from jsonb_array_elements(coalesce(p_payload->'charts','[]'::jsonb))
  loop
    v_code:=v_chart->>'code';
    v_module:=case
      when v_code in('sales','gross_margin') then 'sales'
      when v_code='inventory' then 'inventory'
      when v_code='cash_flow' then 'cash_banks'
      when v_code='receivables' then 'receivables'
      when v_code='payables' then 'payables'
      else null
    end;
    v_module_neutral:=v_module is not null and coalesce((p_state#>>array['modules',v_module,'neutral'])::boolean,false);
    if v_module_neutral then
      v_chart:=v_chart||jsonb_build_object(
        'available',false,
        'value_state','unavailable',
        'points','[]'::jsonb,
        'reason','No disponible: aún no existe base histórica para comparar periodos.'
      );
    end if;
    v_charts:=v_charts||jsonb_build_array(v_chart);
  end loop;

  for v_code,v_comparison in select key,value from jsonb_each(v_comparisons)
  loop
    v_module:=case
      when v_code='gross_margin' then 'sales'
      when v_code in('receivables','overdue_receivables') then 'receivables'
      when v_code='payables' then 'payables'
      when v_code='inventory_value' then 'inventory'
      else null
    end;
    v_module_neutral:=v_module is not null and coalesce((p_state#>>array['modules',v_module,'neutral'])::boolean,false);
    if v_module_neutral then
      v_comparison:=v_comparison||jsonb_build_object(
        'value',0,
        'previous_value',null,
        'available',true,
        'value_state','zero_no_operations',
        'comparison_available',false,
        'reason','Sin operaciones ni saldos iniciales formalmente importados.'
      );
      v_comparisons:=jsonb_set(v_comparisons,array[v_code],v_comparison,true);
    end if;
  end loop;

  return jsonb_set(
    jsonb_set(p_payload,'{charts}',v_charts,true),
    '{comparisons}',v_comparisons,true
  )||jsonb_build_object('neutral_start',p_state);
end $$;

do $rename_bi_for_neutral_start$
begin
  if to_regprocedure('public.bi_get_executive_summary_before_neutral_start(uuid,date,date,uuid,uuid,uuid,uuid)') is null then
    alter function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid)
      rename to bi_get_executive_summary_before_neutral_start;
  end if;
  if to_regprocedure('public.bi_get_executive_charts_before_neutral_start(uuid,date,date,uuid,uuid,uuid,uuid)') is null then
    alter function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid)
      rename to bi_get_executive_charts_before_neutral_start;
  end if;
end
$rename_bi_for_neutral_start$;

create or replace function public.bi_get_executive_summary(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,
  p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payload jsonb;
  v_state jsonb;
begin
  v_payload:=public.bi_get_executive_summary_before_neutral_start(
    p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id
  );
  v_state:=public.company_neutral_start_snapshot(p_company_id);
  return public.bi_apply_neutral_start_to_summary(v_payload,v_state);
end $$;

create or replace function public.bi_get_executive_charts(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,
  p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payload jsonb;
  v_state jsonb;
begin
  v_payload:=public.bi_get_executive_charts_before_neutral_start(
    p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id
  );
  v_state:=public.company_neutral_start_snapshot(p_company_id);
  return public.bi_apply_neutral_start_to_charts(v_payload,v_state);
end $$;

revoke all on function public.company_neutral_start_snapshot(uuid) from public,anon,authenticated;
revoke all on function public.get_company_neutral_start(uuid) from public,anon;
revoke all on function public.bi_apply_neutral_start_to_summary(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.bi_apply_neutral_start_to_charts(jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.bi_get_executive_summary_before_neutral_start(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.bi_get_executive_charts_before_neutral_start(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon;
revoke all on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.get_company_neutral_start(uuid) to authenticated;
grant execute on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;
