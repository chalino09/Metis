\set ON_ERROR_STOP on
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',actor_id::text,false) from public.m3d_concurrency_context;
select public.confirm_supplier_invoice(company_id,invoice_same,'3a000000-0000-4000-8000-000000000010'::uuid) from public.m3d_concurrency_context;
