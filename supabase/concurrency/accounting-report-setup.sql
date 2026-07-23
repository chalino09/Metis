delete from public.companies where id='4d100000-0000-4000-8000-000000000001';
delete from auth.users where id='4d100000-0000-4000-8000-000000000002';
insert into public.companies(id,legal_name,display_name) values('4d100000-0000-4000-8000-000000000001','Concurrencia M4D1','Concurrencia M4D1');
insert into auth.users(id,aud,role,email,encrypted_password) values('4d100000-0000-4000-8000-000000000002','authenticated','authenticated','concurrencia-m4d1@example.com','');
insert into public.user_roles(user_id,role_id,company_id) select '4d100000-0000-4000-8000-000000000002',id,'4d100000-0000-4000-8000-000000000001' from public.roles where code='direccion_admin';
insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level) values
('4d100000-0000-4000-8000-000000000003','4d100000-0000-4000-8000-000000000001','1000','Activo','asset','debit',1),
('4d100000-0000-4000-8000-000000000004','4d100000-0000-4000-8000-000000000001','3000','Capital','equity','credit',1);
insert into public.accounting_periods(id,company_id,period_code,starts_on,ends_on) values('4d100000-0000-4000-8000-000000000005','4d100000-0000-4000-8000-000000000001','2026-07','2026-07-01','2026-07-31');
insert into public.accounting_journal_entries(id,company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id) values('4d100000-0000-4000-8000-000000000006','4d100000-0000-4000-8000-000000000001','4d100000-0000-4000-8000-000000000005',1,'2026-07-15','Concurrencia M4D1','manual_adjustment','draft',gen_random_uuid());
insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,debit,credit) values
('4d100000-0000-4000-8000-000000000001','4d100000-0000-4000-8000-000000000006',1,'4d100000-0000-4000-8000-000000000003',25,0),
('4d100000-0000-4000-8000-000000000001','4d100000-0000-4000-8000-000000000006',2,'4d100000-0000-4000-8000-000000000004',0,25);
update public.accounting_journal_entries set status='posted',immutable=true,posted_by='4d100000-0000-4000-8000-000000000002',posted_at=now() where id='4d100000-0000-4000-8000-000000000006';
