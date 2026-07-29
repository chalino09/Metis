\set ON_ERROR_STOP on
set role authenticated;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',case :'label' when 'last-a' then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' else 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' end,false);
select public.complete_pos_sale(cart_id,revision,'cash','24000000-0000-4000-8000-000000000014',120,request_id,null)
from public.validation_concurrency_context where label=:'label';
