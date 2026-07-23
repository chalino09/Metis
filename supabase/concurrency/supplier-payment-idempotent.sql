\set ON_ERROR_STOP on
begin;
select set_config('request.jwt.claim.role','authenticated',true),set_config('request.jwt.claim.sub',actor_id::text,true) from public.m3e2_concurrency_context;
select public.confirm_supplier_payment(company_id,proposal_idem,paying_account_id,current_date,'03','CONCURRENT-IDEMPOTENT',idempotency_key) from public.m3e2_concurrency_context;
commit;
