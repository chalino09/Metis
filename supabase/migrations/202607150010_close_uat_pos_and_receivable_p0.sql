-- Close the two UAT P0s without changing the validated POS/CxC contracts.

-- pgcrypto lives in Supabase's extensions schema. The function already calls
-- digest() when creating the immutable ticket, so expose that schema explicitly.
alter function public.complete_sale(uuid,integer,text,uuid,numeric,uuid)
  set search_path to public,extensions;

-- Persist the approved Alpha commercial mapping in the operational company:
-- ALPHA_LIST_1 -> primera, PESOS -> MXN, default list.
-- CxC uses this canonical list only as the currency authority for migrated
-- documents that are not backed by a Satrapy sale.
update public.companies company_data
set default_price_policy = 'specific_list',
    default_price_list_id = price_list.id
from public.price_lists price_list
where price_list.company_id = company_data.id
  and price_list.external_code = 'ALPHA_LIST_1'
  and price_list.semantic_code = 'primera'
  and price_list.currency_code = 'MXN'
  and price_list.is_active
  and price_list.status = 'active'
  and (
    company_data.default_price_policy is distinct from 'specific_list'
    or company_data.default_price_list_id is distinct from price_list.id
  );

do $$
begin
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
    raise exception 'P0 CxC: aún existen documentos abiertos sin moneda canónica.';
  end if;
end $$;
