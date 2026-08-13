-- Satrapy BI · Fase 1 visual: lectura operativa agregada.
-- Extiende el contrato existente sin duplicar métricas ni descargar operaciones al cliente.

do $rename_bi_for_decision_summary$
begin
  if to_regprocedure('public.bi_get_executive_charts_before_decision_summary(uuid,date,date,uuid,uuid,uuid,uuid)') is null then
    alter function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid)
      rename to bi_get_executive_charts_before_decision_summary;
  end if;
end
$rename_bi_for_decision_summary$;

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
  v_currency text;
  v_days integer;
  v_previous_from date;
  v_previous_to date;
  v_rows jsonb:='[]'::jsonb;
begin
  v_payload:=public.bi_get_executive_charts_before_decision_summary(
    p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id
  );
  v_currency:=v_payload->>'currency_code';
  v_days:=p_date_to-p_date_from+1;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;

  -- Ventas por sucursal usan exactamente el filtro y la definición de venta neta
  -- del resumen. El proveedor no es una dimensión comprobada de ventas.
  if v_currency is not null and p_supplier_id is null then
    with location_values as materialized (
      select l.id location_id,l.name location_name,
        coalesce(sum(case when s.completed_at::date between p_date_from and p_date_to then
          case when p_product_id is null then s.subtotal_amount-s.discount_amount
            else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)
          end else 0 end),0) current_value,
        coalesce(sum(case when s.completed_at::date between v_previous_from and v_previous_to then
          case when p_product_id is null then s.subtotal_amount-s.discount_amount
            else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)
          end else 0 end),0) previous_value
      from public.locations l
      left join public.sales s on s.location_id=l.id
        and s.company_id=p_company_id
        and s.currency_code=v_currency
        and s.completed_at::date between v_previous_from and p_date_to
        and (p_customer_id is null or s.customer_id=p_customer_id)
        and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
        and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
      where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)
        and (p_location_id is null or l.id=p_location_id)
      group by l.id,l.name
    ), ranked as (
      select *,sum(current_value) over() current_total
      from location_values
    ), ordered as (
      select *,case when previous_value>0 and current_value<previous_value then 'declining'
        when previous_value=0 and current_value>0 then 'new' else 'stable' end status
      from ranked
      order by case when previous_value>0 and current_value<previous_value then 0 else 1 end,
        abs(current_value-previous_value) desc,location_name
      limit 12
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'location_id',location_id,'location_name',location_name,
      'current_value',current_value,'previous_value',previous_value,
      'share_percent',case when current_total=0 then 0 else round(100.0*current_value/current_total,1) end,
      'status',status
    )),'[]'::jsonb) into v_rows
    from ordered;
  end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.executive_operational_summary_queried','bi_query',jsonb_build_object(
    'date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,
    'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id,'row_limit',12
  ));

  return jsonb_set(v_payload,'{operational_rows}',v_rows,true);
end $$;

revoke all on function public.bi_get_executive_charts_before_decision_summary(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;
