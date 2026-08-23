-- Evita que el margen ejecutivo repita autorización y filtros no indexables
-- por cada partida histórica. Esta función es de sólo lectura: no modifica
-- ventas, partidas ni documentos POS confirmados.

create or replace function public.sale_margin_coverage(
  p_company_id uuid,
  p_date_from date,
  p_date_to date,
  p_currency_code text,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null
) returns table(
  net_sales numeric,
  recognized_cost numeric,
  gross_margin numeric,
  item_count bigint,
  costed_item_count bigint,
  missing_cost_item_count bigint
)
language sql
stable
security definer
set search_path=public
as $$
  with accessible_locations as materialized (
    select location_data.id
    from public.locations location_data
    where location_data.company_id=p_company_id
      and public.can_access_location(location_data.id)
      and (p_location_id is null or location_data.id=p_location_id)
  ), selected_sales as materialized (
    select sale_data.id
    from public.sales sale_data
    join accessible_locations location_access
      on location_access.id=sale_data.location_id
    left join public.sale_cancellations cancellation
      on cancellation.sale_id=sale_data.id
    where sale_data.company_id=p_company_id
      and sale_data.currency_code=p_currency_code
      and sale_data.completed_at>=p_date_from::timestamptz
      and sale_data.completed_at<(p_date_to+1)::timestamptz
      and (p_customer_id is null or sale_data.customer_id=p_customer_id)
      and cancellation.sale_id is null
  )
  select
    coalesce(sum(item.taxable_amount),0),
    coalesce(sum(item.recognized_cost_amount),0),
    case when count(*) filter(where item.recognized_cost_amount is null)=0
      then coalesce(sum(item.taxable_amount-item.recognized_cost_amount),0) end,
    count(*),
    count(item.recognized_cost_amount),
    count(*) filter(where item.recognized_cost_amount is null)
  from selected_sales selected_sale
  join public.sale_items item on item.sale_id=selected_sale.id
  where p_product_id is null or item.product_id=p_product_id;
$$;

revoke all on function public.sale_margin_coverage(uuid,date,date,text,uuid,uuid,uuid)
  from public,anon,authenticated;
