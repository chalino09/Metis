begin;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','4d300000-0000-4000-8000-000000000002',true);
select public.confirm_cash_transfer_dispatch(
  '4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000060',
  '{"client":"B"}','4d300000-0000-4000-8000-000000000063');
commit;
