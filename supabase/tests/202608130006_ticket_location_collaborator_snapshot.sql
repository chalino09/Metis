begin;

do $$
declare
  c uuid:='81360000-0000-4000-8000-000000000001';
  u uuid:='81360000-0000-4000-8000-000000000002';
  l uuid:='81360000-0000-4000-8000-000000000003';
  r uuid:='81360000-0000-4000-8000-000000000004';
  s uuid:='81360000-0000-4000-8000-000000000005';
  sale_id uuid:='81360000-0000-4000-8000-000000000006';
  collaborator_id uuid:='81360000-0000-4000-8000-000000000007';
  result public.canonical_tickets%rowtype;
begin
  insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','ticket-v2@example.com','');
  insert into public.companies(id,legal_name,display_name) values(c,'Empresa Ticket V2 SA','Empresa Ticket V2');
  insert into public.profiles(id,full_name,default_company_id) values(u,'Usuario de respaldo',c)
  on conflict(id) do update set full_name=excluded.full_name,default_company_id=excluded.default_company_id;
  insert into public.locations(id,company_id,external_code,name,location_type) values(l,c,'CENTRO','Sucursal Centro','sucursal');
  insert into public.location_operating_profiles(location_id,company_id,address_line_1,municipality,state_name,postal_code,contact_phone)
  values(l,c,'Av. Prueba 10','Toluca','Estado de México','50000','+52 722 123 4567');
  insert into public.cash_registers(id,company_id,location_id,code,display_name) values(r,c,l,'CAJA-01','Caja principal');
  insert into public.cash_sessions(id,company_id,cash_register_id,location_id,opened_by) values(s,c,r,l,u);
  insert into public.collaborators(id,company_id,code,display_name,hired_at) values(collaborator_id,c,'COL-01','María López',current_date);
  insert into public.collaborator_user_links(company_id,collaborator_id,user_id,effective_from,reason,created_by)
  values(c,collaborator_id,u,current_date,'Prueba de ticket v2',u);
  insert into public.sales(id,company_id,location_id,cash_register_id,cash_session_id,cashier_id,sale_type,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,client_request_id)
  values(sale_id,c,l,r,s,u,'cash','MXN',100,0,0,100,gen_random_uuid());
  insert into public.canonical_tickets(sale_id,company_id,location_id,folio,payload,content_sha256)
  values(sale_id,c,l,'0000000001',jsonb_build_object('schema_version',1,'folio','0000000001','sale',jsonb_build_object('total_amount',100)),'pending')
  returning * into result;
  if result.schema_version<>2
    or result.payload#>>'{identity,location,name}'<>'Sucursal Centro'
    or result.payload#>>'{identity,location,contact_phone}'<>'+52 722 123 4567'
    or result.payload#>>'{identity,register,name}'<>'Caja principal'
    or result.payload#>>'{identity,collaborator,display_name}'<>'María López'
    or result.content_sha256='pending' then
    raise exception 'El snapshot operativo del ticket quedó incompleto: %',result.payload;
  end if;
end $$;

rollback;
