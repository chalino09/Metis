-- Satrapy BI · selección explícita del periodo comparable.
-- Es incremental: ejecutar después de 202608120019.

create or replace function public.bi_get_executive_summary_compared(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,
  p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null,
  p_comparison_mode text default 'previous_period'
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_mode text:=lower(trim(coalesce(p_comparison_mode,'previous_period')));
  v_comparison_from date;
  v_comparison_to date;
  v_current jsonb;
  v_comparison jsonb;
  v_metrics jsonb;
begin
  if v_mode not in('previous_period','previous_year') then raise exception 'Comparación no permitida.'; end if;
  v_current:=public.bi_get_executive_summary(p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id);
  if v_mode='previous_period' then
    return jsonb_set(v_current,'{period,comparison_mode}',to_jsonb(v_mode),true);
  end if;
  v_comparison_from:=(p_date_from-interval '1 year')::date;
  v_comparison_to:=(p_date_to-interval '1 year')::date;
  v_comparison:=public.bi_get_executive_summary(p_company_id,v_comparison_from,v_comparison_to,p_location_id,p_product_id,p_customer_id,p_supplier_id);
  select coalesce(jsonb_agg(merged.merged_metric order by merged.ordinal),'[]'::jsonb)
  into v_metrics
  from (
    select current_metric.ordinal,
      current_metric.metric || jsonb_build_object('previous_value',comparison.comparison_metric->'value') merged_metric
    from jsonb_array_elements(v_current->'metrics') with ordinality current_metric(metric,ordinal)
    left join lateral (
      select candidate comparison_metric from jsonb_array_elements(v_comparison->'metrics') candidate
      where candidate->>'code'=current_metric.metric->>'code' limit 1
    ) comparison on true
  ) merged;
  v_current:=jsonb_set(v_current,'{metrics}',v_metrics,true);
  v_current:=jsonb_set(v_current,'{period}',jsonb_build_object(
    'from',p_date_from,'to',p_date_to,'previous_from',v_comparison_from,'previous_to',v_comparison_to,
    'days',p_date_to-p_date_from+1,'comparison_mode',v_mode
  ),true);
  return v_current;
end;
$$;

revoke all on function public.bi_get_executive_summary_compared(uuid,date,date,uuid,uuid,uuid,uuid,text) from public,anon;
grant execute on function public.bi_get_executive_summary_compared(uuid,date,date,uuid,uuid,uuid,uuid,text) to authenticated;

notify pgrst,'reload schema';
