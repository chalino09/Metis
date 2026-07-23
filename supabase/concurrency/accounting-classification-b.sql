begin;
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','4d200000-0000-4000-8000-000000000002',true);
select public.bulk_assign_expense_category(
  '4d200000-0000-4000-8000-000000000001',
  '4d200000-0000-4000-8000-000000000004',
  '4d200000-0000-4000-8000-000000000007',
  'CONC',null,1000,'4d200000-0000-4000-8000-000000000011'
);
commit;
