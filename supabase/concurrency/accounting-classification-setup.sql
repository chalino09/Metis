begin;
delete from public.companies where id='4d200000-0000-4000-8000-000000000001';
delete from auth.users where id='4d200000-0000-4000-8000-000000000002';

insert into public.companies(id,legal_name,display_name)
values('4d200000-0000-4000-8000-000000000001','Concurrencia M4D2','Concurrencia M4D2');
insert into auth.users(id,aud,role,email,encrypted_password)
values('4d200000-0000-4000-8000-000000000002','authenticated','authenticated','concurrencia-m4d2@example.com','');
insert into public.user_roles(user_id,role_id,company_id)
select '4d200000-0000-4000-8000-000000000002',id,'4d200000-0000-4000-8000-000000000001'
from public.roles where code='direccion_admin';

insert into public.accounting_accounts(id,company_id,code,name,account_type,normal_balance,level)
values('4d200000-0000-4000-8000-000000000003','4d200000-0000-4000-8000-000000000001','6100','Gasto concurrente','expense','debit',1);
insert into public.accounting_expense_category_versions(
  id,company_id,category_id,version,code,display_name,account_id,status,valid_from,
  change_reason,created_by
) values (
  '4d200000-0000-4000-8000-000000000005','4d200000-0000-4000-8000-000000000001',
  '4d200000-0000-4000-8000-000000000004',1,'CONC','Categoría concurrente',
  '4d200000-0000-4000-8000-000000000003','active',current_date,
  'Configuración de prueba','4d200000-0000-4000-8000-000000000002'
);
insert into public.suppliers(id,company_id,code,display_name,country_code)
values('4d200000-0000-4000-8000-000000000006','4d200000-0000-4000-8000-000000000001','SUP-CONC','Proveedor concurrente','US');
insert into public.supplier_invoices(
  id,company_id,supplier_id,source_kind,status,folio,issued_date,due_date,
  currency_code,exchange_rate,base_currency_code,subtotal,tax_total,total,base_total,
  expense_approved_at,expense_approved_by
) values (
  '4d200000-0000-4000-8000-000000000007','4d200000-0000-4000-8000-000000000001',
  '4d200000-0000-4000-8000-000000000006','expense','draft','CONC-2000',current_date,current_date,
  'MXN',1,'MXN',2000,0,2000,2000,now(),'4d200000-0000-4000-8000-000000000002'
);
insert into public.supplier_invoice_expense_lines(
  company_id,supplier_invoice_id,line_number,product_service_code,quantity,unit_code,
  description,unit_value,subtotal,discount_amount,tax_amount,withheld_tax_amount,
  tax_object_code,tax_details,expense_category
)
select
  '4d200000-0000-4000-8000-000000000001','4d200000-0000-4000-8000-000000000007',
  n,'01010101',1,'E48','Concepto concurrente '||n,1,1,0,0,0,'02','[]','CONC'
from generate_series(1,2000) n;
commit;
