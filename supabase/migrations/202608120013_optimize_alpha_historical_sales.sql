-- Keep Alpha code normalization at the import boundary, but make the lookup
-- indexable for historical batches with tens of thousands of sale lines.
create index if not exists alpha_customer_links_company_code_norm_idx
  on public.alpha_customer_identity_links (
    company_id,
    (regexp_replace(external_code, '^0+', '', 'g'))
  );

create index if not exists customers_company_alpha_external_code_normalized_idx
  on public.customers (
    company_id,
    (regexp_replace(coalesce(alpha_external_code, ''), '^0+', '', 'g'))
  )
  where alpha_external_code is not null;

-- These RPCs are intentionally bounded but need more than the short interactive
-- query budget when promoting a complete historical package.
alter function public.preview_alpha_historical_sales_promotion(uuid)
  set statement_timeout = '30s';

alter function public.promote_alpha_historical_sales(uuid,text)
  set statement_timeout = '120s';
