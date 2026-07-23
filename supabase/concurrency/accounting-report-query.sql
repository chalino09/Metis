select set_config('request.jwt.claim.role','authenticated',false),set_config('request.jwt.claim.sub','4d100000-0000-4000-8000-000000000002',false);
do $$declare r jsonb;begin
 r:=public.list_accounting_report('4d100000-0000-4000-8000-000000000001','trial_balance','2026-07-01','2026-07-31',null,1,50);
 if (r->>'total')::int<>2 or (r#>>'{totals,debit}')::numeric<>25 or (r#>>'{totals,credit}')::numeric<>25 then raise exception 'Lectura concurrente inconsistente: %',r;end if;
end$$;
