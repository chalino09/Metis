-- List customers with open receivables without truncating the operational result set.

create or replace function public.list_receivable_customers(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_customer_credit') then
    raise exception 'No autorizado para consultar cuentas por cobrar.';
  end if;

  with open_balances as materialized (
    select receivable.customer_id, sum(receivable.outstanding_amount) as outstanding_amount
    from public.customer_receivables receivable
    where receivable.company_id = p_company_id and receivable.outstanding_amount > 0
    group by receivable.customer_id
  ), filtered as (
    select
      customer_data.id,
      customer_data.code,
      customer_data.display_name,
      customer_data.credit_enabled and (customer_data.alpha_external_code is null or customer_data.migration_status = 'promoted') as credit_enabled,
      customer_data.price_list_id,
      customer_data.credit_limit,
      customer_data.credit_term_days,
      customer_data.migration_status,
      customer_data.alpha_external_code,
      balance.outstanding_amount
    from open_balances balance
    join public.customers customer_data on customer_data.id = balance.customer_id
    where customer_data.company_id = p_company_id
      and customer_data.is_active
      and (
        v_query = ''
        or lower(customer_data.code) like '%' || v_query || '%'
        or lower(customer_data.display_name) like '%' || v_query || '%'
        or lower(coalesce(customer_data.tax_id, '')) like '%' || v_query || '%'
        or lower(coalesce(customer_data.phone, '')) like '%' || v_query || '%'
      )
  )
  select count(*) into v_total from filtered;

  with open_balances as materialized (
    select receivable.customer_id, sum(receivable.outstanding_amount) as outstanding_amount
    from public.customer_receivables receivable
    where receivable.company_id = p_company_id and receivable.outstanding_amount > 0
    group by receivable.customer_id
  ), filtered as (
    select
      customer_data.id,
      customer_data.code,
      customer_data.display_name,
      customer_data.credit_enabled and (customer_data.alpha_external_code is null or customer_data.migration_status = 'promoted') as credit_enabled,
      customer_data.price_list_id,
      customer_data.credit_limit,
      customer_data.credit_term_days,
      customer_data.migration_status,
      customer_data.alpha_external_code,
      balance.outstanding_amount
    from open_balances balance
    join public.customers customer_data on customer_data.id = balance.customer_id
    where customer_data.company_id = p_company_id
      and customer_data.is_active
      and (
        v_query = ''
        or lower(customer_data.code) like '%' || v_query || '%'
        or lower(customer_data.display_name) like '%' || v_query || '%'
        or lower(coalesce(customer_data.tax_id, '')) like '%' || v_query || '%'
        or lower(coalesce(customer_data.phone, '')) like '%' || v_query || '%'
      )
  ), paged as (
    select *
    from filtered
    order by display_name, id
    limit v_size offset (v_page - 1) * v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', paged.id,
    'code', paged.code,
    'display_name', paged.display_name,
    'credit_enabled', paged.credit_enabled,
    'price_list_id', paged.price_list_id,
    'credit_limit', paged.credit_limit,
    'credit_term_days', paged.credit_term_days,
    'outstanding_amount', paged.outstanding_amount,
    'available_credit', greatest(paged.credit_limit - paged.outstanding_amount, 0),
    'migration_status', paged.migration_status,
    'alpha_external_code', paged.alpha_external_code
  ) order by paged.display_name, paged.id), '[]'::jsonb)
  into v_items
  from paged;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end $$;

revoke all on function public.list_receivable_customers(uuid, text, integer, integer) from public;
grant execute on function public.list_receivable_customers(uuid, text, integer, integer) to authenticated;
