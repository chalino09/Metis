\set ON_ERROR_STOP on
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',actor_id::text,false) from public.m3c_concurrency_context;
select public.confirm_purchase_receipt(company_id,receipt_same,'39000000-0000-4000-8000-000000000020') from public.m3c_concurrency_context;
