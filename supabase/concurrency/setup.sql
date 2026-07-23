\set ON_ERROR_STOP on
drop table if exists public.validation_concurrency_context;
create table public.validation_concurrency_context(
  label text primary key,
  cart_id uuid not null,
  revision integer not null,
  request_id uuid not null
);
grant select on public.validation_concurrency_context to authenticated;

do $fixtures$
declare v_actor uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','00000000-0000-0000-0000-000000000000','authenticated','authenticated','validation-cashier-b@example.invalid','',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()),
    ('cccccccc-cccc-4ccc-8ccc-cccccccccccc','00000000-0000-0000-0000-000000000000','authenticated','authenticated','validation-cashier-c@example.invalid','',now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
  update public.profiles set full_name=case id
    when 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid then 'Validation Cashier B'
    else 'Validation Cashier C' end
  where id in ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  insert into public.user_roles(user_id,role_id,company_id)
    select actor.id,role_data.id,null from (values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid),('cccccccc-cccc-4ccc-8ccc-cccccccccccc'::uuid)) actor(id)
    cross join public.roles role_data where role_data.code='super_admin';
  insert into public.companies(id,legal_name,display_name) values('24000000-0000-4000-8000-000000000001','Validación concurrencia','Validación concurrencia');
  insert into public.units_of_measure(id,company_id,code,name) values('24000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001','PZA','Pieza');
  insert into public.tax_categories(id,company_id,code,name) values('24000000-0000-4000-8000-000000000003','24000000-0000-4000-8000-000000000001','IVA16','IVA 16%');
  insert into public.tax_rates(id,tax_category_id,jurisdiction_code,rate,valid_from,created_by) values('24000000-0000-4000-8000-000000000004','24000000-0000-4000-8000-000000000003','MX',.16,now()-interval '1 day',v_actor);
  insert into public.price_lists(id,company_id,external_code,name,currency_code,is_active,status,is_default) values('24000000-0000-4000-8000-000000000005','24000000-0000-4000-8000-000000000001','MOSTRADOR','Mostrador','MXN',true,'active',true);
  update public.companies set default_price_list_id='24000000-0000-4000-8000-000000000005' where id='24000000-0000-4000-8000-000000000001';
  insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values('24000000-0000-4000-8000-000000000006','24000000-0000-4000-8000-000000000001','SUC-CONC','Sucursal concurrencia','sucursal','manual_review');
  insert into public.products(id,company_id,alpha_sku,name,unit,product_type,is_active,is_sellable,is_inventory_tracked,sales_unit_id,tax_category_id,commercial_review_required) values
    ('24000000-0000-4000-8000-000000000007','24000000-0000-4000-8000-000000000001','CONC-LAST','Última pieza concurrente','PZA','P. TERMINADO',true,true,true,'24000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000003',false),
    ('24000000-0000-4000-8000-000000000008','24000000-0000-4000-8000-000000000001','CONC-IDEM','Reintento concurrente','PZA','P. TERMINADO',true,true,true,'24000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000003',false);
  insert into public.product_prices(product_id,price_list_id,amount,currency_code,valid_from,created_by) values
    ('24000000-0000-4000-8000-000000000007','24000000-0000-4000-8000-000000000005',100,'MXN',now()-interval '1 day',v_actor),
    ('24000000-0000-4000-8000-000000000008','24000000-0000-4000-8000-000000000005',100,'MXN',now()-interval '1 day',v_actor);
  insert into public.sales_assortments(id,company_id,code,name,status) values('24000000-0000-4000-8000-000000000009','24000000-0000-4000-8000-000000000001','CONC','Concurrencia','draft');
  insert into public.sales_assortment_items(assortment_id,product_id) values
    ('24000000-0000-4000-8000-000000000009','24000000-0000-4000-8000-000000000007'),
    ('24000000-0000-4000-8000-000000000009','24000000-0000-4000-8000-000000000008');
  insert into public.location_sales_assortments(location_id,assortment_id,valid_from) values('24000000-0000-4000-8000-000000000006','24000000-0000-4000-8000-000000000009',now()-interval '1 day');
  update public.sales_assortments set status='active' where id='24000000-0000-4000-8000-000000000009';
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values
    ('24000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000006','24000000-0000-4000-8000-000000000007',1),
    ('24000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000006','24000000-0000-4000-8000-000000000008',1);
  insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code) values
    ('24000000-0000-4000-8000-000000000011','24000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000006','C1','Caja 1','MXN'),
    ('24000000-0000-4000-8000-000000000012','24000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000006','C2','Caja 2','MXN'),
    ('24000000-0000-4000-8000-000000000013','24000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000006','C3','Caja 3','MXN');
  insert into public.payment_methods(id,company_id,code,display_name,settlement_kind) values('24000000-0000-4000-8000-000000000014','24000000-0000-4000-8000-000000000001','EFECTIVO','Efectivo','cash_drawer');
  insert into public.cash_denominations(id,company_id,currency_code,value,display_name) values('24000000-0000-4000-8000-000000000015','24000000-0000-4000-8000-000000000001','MXN',100,'$100');
end $fixtures$;

set role authenticated;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
do $carts$
declare v_session jsonb; v_cart jsonb; v_quote jsonb;
begin
  for i in 1..3 loop
    perform set_config('request.jwt.claim.sub',case i when 1 then 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' when 2 then 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' else 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' end,false);
    v_session:=public.open_cash_session('24000000-0000-4000-8000-000000000001',('24000000-0000-4000-8000-00000000001'||i)::uuid,jsonb_build_array(jsonb_build_object('denomination_id','24000000-0000-4000-8000-000000000015'::uuid,'quantity',0)),('24000000-0000-4000-8000-00000000002'||i)::uuid);
    v_cart:=public.get_or_create_sale_cart('24000000-0000-4000-8000-000000000001',(v_session->>'cash_session_id')::uuid);
    perform public.change_sale_cart_item((v_cart->>'cart_id')::uuid,case when i<3 then '24000000-0000-4000-8000-000000000007'::uuid else '24000000-0000-4000-8000-000000000008'::uuid end,1,(v_cart->>'revision')::integer);
    v_quote:=public.quote_sale_cart((v_cart->>'cart_id')::uuid);
    insert into public.validation_concurrency_context(label,cart_id,revision,request_id) values(
      case i when 1 then 'last-a' when 2 then 'last-b' else 'idem' end,
      (v_cart->>'cart_id')::uuid,(v_quote->>'revision')::integer,
      case i when 1 then '24000000-0000-4000-8000-000000000031'::uuid when 2 then '24000000-0000-4000-8000-000000000032'::uuid else '24000000-0000-4000-8000-000000000033'::uuid end
    );
  end loop;
end $carts$;
reset role;
