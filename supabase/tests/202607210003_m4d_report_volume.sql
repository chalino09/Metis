begin;
do $volume$
declare c uuid:='4d200000-0000-4000-8000-000000000001';u uuid:='4d200000-0000-4000-8000-000000000002';p uuid:='4d200000-0000-4000-8000-000000000003';a1 uuid:='4d200000-0000-4000-8000-000000000004';a2 uuid:='4d200000-0000-4000-8000-000000000005';j uuid:='4d200000-0000-4000-8000-000000000006';r jsonb;
begin
 insert into public.companies(id,legal_name,display_name) values(c,'Volumen M4D','Volumen M4D');
 insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','volumen-m4d@example.com','');
 insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';
 insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level) values(a1,c,'1000','Cuenta deudora','asset','debit',1),(a2,c,'2000','Cuenta acreedora','liability','credit',1);
 insert into public.accounting_periods(id,company_id,period_code,starts_on,ends_on) values(p,c,'2026-07','2026-07-01','2026-07-31');
 insert into public.accounting_journal_entries(id,company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id) values(j,c,p,1,'2026-07-15','Carga controlada de volumen','manual_adjustment','draft',gen_random_uuid());
 insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit)
 select c,j,n,case when n%2=1 then a1 else a2 end,'Renglón de volumen',case when n%2=1 then 1 else 0 end,case when n%2=0 then 1 else 0 end from generate_series(1,10000)n;
 update public.accounting_journal_entries set status='posted',immutable=true,posted_by=u,posted_at=now() where id=j;
 perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
 r:=public.list_accounting_report(c,'general_ledger','2026-07-01','2026-07-31',null,1,1000);
 if (r->>'total')::int<>10000 or (r->>'page_size')::int<>200 or jsonb_array_length(r->'rows')<>200 then raise exception 'El mayor no paginó 10,000 renglones: %',r;end if;
 r:=public.list_accounting_report(c,'general_ledger','2026-07-01','2026-07-31',null,50,200);
 if jsonb_array_length(r->'rows')<>200 then raise exception 'La última página perdió renglones.';end if;
 r:=public.list_accounting_report(c,'trial_balance','2026-07-01','2026-07-31',null,1,50);
 if (r->>'total')::int<>2 or jsonb_array_length(r->'rows')<>2 then raise exception 'La balanza no acumuló el volumen.';end if;
 raise notice 'M4D volumen controlado: 10,000 partidas, acumulación server-side y páginas máximas de 200 aprobadas.';
end;$volume$;
rollback;
