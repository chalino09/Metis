\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claim.role','authenticated',true),set_config('request.jwt.claim.sub',actor_id::text,true) from public.m3e2_concurrency_context;
select public.confirm_supplier_payment(company_id,case when :'side'='a' then proposal_a else proposal_b end,paying_account_id,current_date,'03',concat('CONCURRENT-',:'side'),gen_random_uuid()) from public.m3e2_concurrency_context;
commit;
