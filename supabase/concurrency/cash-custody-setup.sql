begin;
insert into public.companies(id,legal_name,display_name,base_currency_code)
values('4d300000-0000-4000-8000-000000000001','Concurrencia M4D3','Concurrencia M4D3','MXN');
insert into auth.users(id,aud,role,email,encrypted_password) values
('4d300000-0000-4000-8000-000000000002','authenticated','authenticated','m4d3-concurrency@example.com','');
insert into public.user_roles(user_id,role_id,company_id)
select '4d300000-0000-4000-8000-000000000002',id,'4d300000-0000-4000-8000-000000000001'
from public.roles where code='direccion_admin';
insert into public.locations(id,company_id,external_code,name,location_type) values
('4d300000-0000-4000-8000-000000000010','4d300000-0000-4000-8000-000000000001','ORIG','Origen concurrente','sucursal'),
('4d300000-0000-4000-8000-000000000011','4d300000-0000-4000-8000-000000000001','DEST','Destino concurrente','sucursal');
insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code) values
('4d300000-0000-4000-8000-000000000020','4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000010','ORIG','Caja origen','MXN'),
('4d300000-0000-4000-8000-000000000021','4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000011','DEST','Caja destino','MXN');
insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by,opening_amount,open_request_id)
values('4d300000-0000-4000-8000-000000000030','4d300000-0000-4000-8000-000000000001',
  '4d300000-0000-4000-8000-000000000020','4d300000-0000-4000-8000-000000000010',
  '4d300000-0000-4000-8000-000000000002',500,'4d300000-0000-4000-8000-000000000031');
insert into public.cash_movements(company_id,cash_session_id,movement_type,amount,actor_id)
values('4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000030','opening',500,
  '4d300000-0000-4000-8000-000000000002');
commit;
begin;

insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level) values
('4d300000-0000-4000-8000-000000000040','4d300000-0000-4000-8000-000000000001','1101','Caja origen','asset','debit',1),
('4d300000-0000-4000-8000-000000000041','4d300000-0000-4000-8000-000000000001','1102','Caja destino','asset','debit',1),
('4d300000-0000-4000-8000-000000000042','4d300000-0000-4000-8000-000000000001','1103','Efectivo en tránsito','asset','debit',1);
insert into public.accounting_config_versions(id,company_id,version,status,base_currency,cutoff_date,catalog_structure,
  tax_treatment,responsibilities,change_reason,approved_by,approved_at)
values('4d300000-0000-4000-8000-000000000043','4d300000-0000-4000-8000-000000000001',1,'approved','MXN',
  current_date,'{}','{}','{}','Concurrencia','4d300000-0000-4000-8000-000000000002',now());
insert into public.accounting_periods(company_id,period_code,starts_on,ends_on)
values('4d300000-0000-4000-8000-000000000001',to_char(current_date,'YYYY-MM'),
  date_trunc('month',current_date)::date,(date_trunc('month',current_date)+interval '1 month - 1 day')::date);
insert into public.accounting_event_rule_sets(id,company_id,accounting_config_version_id,version,status,cost_method,
  recognition_policy,reason,approved_by,approved_at)
values('4d300000-0000-4000-8000-000000000044','4d300000-0000-4000-8000-000000000001',
  '4d300000-0000-4000-8000-000000000043',1,'approved','replacement_cost','{}','Concurrencia',
  '4d300000-0000-4000-8000-000000000002',now());
insert into public.cash_register_accounting_accounts(company_id,cash_register_id,account_id,reason) values
('4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000020','4d300000-0000-4000-8000-000000000040','Concurrencia'),
('4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000021','4d300000-0000-4000-8000-000000000041','Concurrencia');
insert into public.cash_custody_account_config(company_id,in_transit_account_id,reason)
values('4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000042','Concurrencia');
insert into public.cash_custody_transfers(id,company_id,currency_code,origin_cash_register_id,origin_location_id,
  destination_cash_register_id,destination_location_id,amount,effective_date,responsible_id,reason,reference,evidence,
  status,prepare_request_id,approval_request_id,prepared_by,approved_by,approved_at) values
('4d300000-0000-4000-8000-000000000050','4d300000-0000-4000-8000-000000000001','MXN',
  '4d300000-0000-4000-8000-000000000020','4d300000-0000-4000-8000-000000000010',
  '4d300000-0000-4000-8000-000000000021','4d300000-0000-4000-8000-000000000011',400,current_date,
  '4d300000-0000-4000-8000-000000000002','Concurrente A','CONC-A','{}','approved',
  '4d300000-0000-4000-8000-000000000051','4d300000-0000-4000-8000-000000000052',
  '4d300000-0000-4000-8000-000000000002',
  '4d300000-0000-4000-8000-000000000002',now()),
('4d300000-0000-4000-8000-000000000060','4d300000-0000-4000-8000-000000000001','MXN',
  '4d300000-0000-4000-8000-000000000020','4d300000-0000-4000-8000-000000000010',
  '4d300000-0000-4000-8000-000000000021','4d300000-0000-4000-8000-000000000011',400,current_date,
  '4d300000-0000-4000-8000-000000000002','Concurrente B','CONC-B','{}','approved',
  '4d300000-0000-4000-8000-000000000061','4d300000-0000-4000-8000-000000000062',
  '4d300000-0000-4000-8000-000000000002',
  '4d300000-0000-4000-8000-000000000002',now());
commit;
