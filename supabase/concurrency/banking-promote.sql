begin;
select set_config('request.jwt.claim.role','authenticated',true),set_config('request.jwt.claim.sub','4c100000-0000-4000-8000-000000000002',true);
select public.promote_bank_statement('4c100000-0000-4000-8000-000000000004','4c100000-0000-4000-8000-000000000006');
commit;
