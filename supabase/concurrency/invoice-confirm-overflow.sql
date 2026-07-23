\set ON_ERROR_STOP on
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',actor_id::text,false) from public.m3d_concurrency_context;
select public.confirm_supplier_invoice(company_id,case when :'side'='a' then invoice_a else invoice_b end,case when :'side'='a' then '3a000000-0000-4000-8000-000000000011'::uuid else '3a000000-0000-4000-8000-000000000012'::uuid end) from public.m3d_concurrency_context;
