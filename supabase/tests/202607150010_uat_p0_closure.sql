begin;

do $$
declare
  v_search_path text;
begin
  select proconfig_value
  into v_search_path
  from pg_proc function_data
  cross join lateral unnest(coalesce(function_data.proconfig,'{}'::text[])) proconfig_value
  where function_data.oid = 'public.complete_sale(uuid,integer,text,uuid,numeric,uuid)'::regprocedure
    and proconfig_value = 'search_path=public, extensions';

  if v_search_path is null then
    raise exception 'complete_sale no resuelve pgcrypto desde extensions.';
  end if;

  if exists (
    select 1
    from public.customer_receivables receivable
    join public.customers customer_data on customer_data.id = receivable.customer_id
    join public.companies company_data on company_data.id = receivable.company_id
    left join public.sales sale_data on sale_data.id = receivable.sale_id
    left join public.price_lists customer_list on customer_list.id = customer_data.price_list_id
    left join public.price_lists company_list on company_list.id = company_data.default_price_list_id
    where receivable.outstanding_amount > 0
      and coalesce(sale_data.currency_code, customer_list.currency_code, company_list.currency_code) is null
  ) then
    raise exception 'Persisten documentos abiertos sin moneda canónica.';
  end if;
end $$;

rollback;
