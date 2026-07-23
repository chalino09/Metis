\set ON_ERROR_STOP on
set role authenticated;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',false);
select public.complete_sale(cart_id,revision,'cash','24000000-0000-4000-8000-000000000014',120,request_id)
from public.validation_concurrency_context where label='idem';
