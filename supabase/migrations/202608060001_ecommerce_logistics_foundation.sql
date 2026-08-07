-- Ecommerce · base logística, direcciones de entrega y evidencia geográfica.
-- Shopify, geocodificación y paqueterías permanecen como adaptadores externos;
-- el dominio conserva productos, clientes y pedidos canónicos de Satrapy.

begin;

alter table public.customer_addresses
  add column if not exists recipient_name text,
  add column if not exists phone text,
  add column if not exists address_line_2 text,
  add column if not exists country_code text not null default 'MX',
  add column if not exists delivery_instructions text,
  add column if not exists normalized_address text,
  add column if not exists latitude numeric(9,6),
  add column if not exists longitude numeric(9,6),
  add column if not exists geocoding_provider text,
  add column if not exists geocoding_precision text,
  add column if not exists geocoding_attempted_at timestamptz,
  add column if not exists geocoded_at timestamptz,
  add column if not exists geocoding_error_code text;

update public.customer_addresses set country_code='MX';

alter table public.customer_addresses drop constraint if exists customer_addresses_country_code_check;
alter table public.customer_addresses add constraint customer_addresses_country_code_check
  check(country_code~'^[A-Z]{2}$');
alter table public.customer_addresses drop constraint if exists customer_addresses_coordinates_check;
alter table public.customer_addresses add constraint customer_addresses_coordinates_check check(
  (latitude is null and longitude is null) or
  (latitude between -90 and 90 and longitude between -180 and 180)
);
alter table public.customer_addresses drop constraint if exists customer_addresses_geocoded_check;
alter table public.customer_addresses add constraint customer_addresses_geocoded_check check(
  geocoded_at is null or (latitude is not null and longitude is not null and geocoding_provider is not null)
);

create index if not exists customer_addresses_geography_idx
  on public.customer_addresses(company_id,state_name,municipality,postal_code);

create table public.product_shipping_profiles(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  packed_weight_kg numeric(12,4) not null check(packed_weight_kg>0),
  length_cm numeric(12,2) not null check(length_cm>0),
  width_cm numeric(12,2) not null check(width_cm>0),
  height_cm numeric(12,2) not null check(height_cm>0),
  package_type text,
  max_units_per_package integer not null default 1 check(max_units_per_package>0),
  ships_in_own_container boolean not null default false,
  measurement_source text not null check(measurement_source in('manual','supplier','import')),
  measured_at timestamptz not null,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,product_id)
);
create index product_shipping_profiles_company_updated_idx
  on public.product_shipping_profiles(company_id,updated_at desc,product_id);
create trigger product_shipping_profiles_updated_at before update on public.product_shipping_profiles
  for each row execute function public.set_updated_at();

create table public.sales_order_delivery_addresses(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null unique references public.sales_deposit_orders(id) on delete cascade,
  customer_address_id uuid references public.customer_addresses(id) on delete set null,
  source text not null check(source in('customer_address','manual','shopify')),
  recipient_name text not null check(nullif(trim(recipient_name),'') is not null),
  phone text,
  address_line text not null check(nullif(trim(address_line),'') is not null),
  address_line_2 text,
  neighborhood text,
  municipality text not null check(nullif(trim(municipality),'') is not null),
  state_name text not null check(nullif(trim(state_name),'') is not null),
  postal_code text not null check(nullif(trim(postal_code),'') is not null),
  country_code text not null check(country_code~'^[A-Z]{2}$'),
  delivery_instructions text,
  normalized_address text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  geocoding_provider text,
  geocoding_precision text,
  geocoding_attempted_at timestamptz,
  geocoded_at timestamptz,
  geocoding_error_code text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check((latitude is null and longitude is null) or (latitude between -90 and 90 and longitude between -180 and 180)),
  check(geocoded_at is null or (latitude is not null and longitude is not null and geocoding_provider is not null))
);
create index sales_order_delivery_addresses_geography_idx
  on public.sales_order_delivery_addresses(company_id,state_name,municipality,postal_code,created_at desc);

create or replace function public.protect_sales_order_delivery_address()
returns trigger language plpgsql set search_path=public as $$
begin
  if row(
    new.company_id,new.order_id,new.customer_address_id,new.source,new.recipient_name,new.phone,
    new.address_line,new.address_line_2,new.neighborhood,new.municipality,new.state_name,
    new.postal_code,new.country_code,new.delivery_instructions,new.created_by,new.created_at
  ) is distinct from row(
    old.company_id,old.order_id,old.customer_address_id,old.source,old.recipient_name,old.phone,
    old.address_line,old.address_line_2,old.neighborhood,old.municipality,old.state_name,
    old.postal_code,old.country_code,old.delivery_instructions,old.created_by,old.created_at
  ) then raise exception 'La dirección histórica del pedido es inmutable.';end if;
  return new;
end $$;
create trigger sales_order_delivery_addresses_immutable
  before update on public.sales_order_delivery_addresses
  for each row execute function public.protect_sales_order_delivery_address();

alter table public.product_shipping_profiles enable row level security;
alter table public.sales_order_delivery_addresses enable row level security;
revoke all on public.product_shipping_profiles,public.sales_order_delivery_addresses from authenticated;

create unique index audit_product_shipping_profile_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='product.shipping_profile_saved' and metadata?'request_id';

create or replace function public.save_product_shipping_profile(
  p_company_id uuid,p_product_id uuid,p_packed_weight_kg numeric,
  p_length_cm numeric,p_width_cm numeric,p_height_cm numeric,p_package_type text,
  p_max_units_per_package integer,p_ships_in_own_container boolean,p_measurement_source text,
  p_measured_at timestamptz,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_profile public.product_shipping_profiles%rowtype;v_previous jsonb;v_replayed jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para administrar datos logísticos.';end if;
  if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id) then raise exception 'Producto no encontrado.';end if;
  if least(coalesce(p_packed_weight_kg,0),coalesce(p_length_cm,0),coalesce(p_width_cm,0),coalesce(p_height_cm,0))<=0 then raise exception 'Peso y dimensiones empacadas deben ser mayores a cero.';end if;
  if coalesce(p_max_units_per_package,0)<=0 then raise exception 'La capacidad del paquete debe ser mayor a cero.';end if;
  if p_measurement_source not in('manual','supplier','import') then raise exception 'Origen de medición no válido.';end if;
  if p_measured_at is null or p_measured_at>clock_timestamp()+interval '1 minute' then raise exception 'La fecha de medición no es válida.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Motivo y referencia idempotente son obligatorios.';end if;
  perform pg_advisory_xact_lock(hashtextextended('shipping-profile:'||p_company_id::text||':'||p_product_id::text,0));
  select metadata->'result' into v_replayed from public.audit_log where company_id=p_company_id and action='product.shipping_profile_saved' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true);end if;
  select * into v_profile from public.product_shipping_profiles where company_id=p_company_id and product_id=p_product_id for update;
  if found then
    if p_expected_updated_at is null or v_profile.updated_at<>p_expected_updated_at then raise exception 'El perfil logístico cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    v_previous:=to_jsonb(v_profile);
    update public.product_shipping_profiles set packed_weight_kg=round(p_packed_weight_kg,4),length_cm=round(p_length_cm,2),width_cm=round(p_width_cm,2),height_cm=round(p_height_cm,2),package_type=nullif(trim(p_package_type),''),max_units_per_package=p_max_units_per_package,ships_in_own_container=coalesce(p_ships_in_own_container,false),measurement_source=p_measurement_source,measured_at=p_measured_at,updated_by=auth.uid() where id=v_profile.id returning * into v_profile;
  else
    v_previous:=null;
    insert into public.product_shipping_profiles(company_id,product_id,packed_weight_kg,length_cm,width_cm,height_cm,package_type,max_units_per_package,ships_in_own_container,measurement_source,measured_at)
    values(p_company_id,p_product_id,round(p_packed_weight_kg,4),round(p_length_cm,2),round(p_width_cm,2),round(p_height_cm,2),nullif(trim(p_package_type),''),p_max_units_per_package,coalesce(p_ships_in_own_container,false),p_measurement_source,p_measured_at) returning * into v_profile;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'product.shipping_profile_saved','product_shipping_profile',v_profile.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'previous',v_previous,'result',to_jsonb(v_profile)||jsonb_build_object('idempotent',false)));
  return to_jsonb(v_profile)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.save_customer_delivery_address(
  p_company_id uuid,p_customer_id uuid,p_address_id uuid,p_label text,p_recipient_name text,p_phone text,
  p_address_line text,p_address_line_2 text,p_neighborhood text,p_municipality text,p_state_name text,
  p_postal_code text,p_country_code text,p_delivery_instructions text,p_is_primary boolean
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_customer public.customers%rowtype;v_address public.customer_addresses%rowtype;v_id uuid;v_country text:=upper(trim(coalesce(p_country_code,'MX')));
begin
  v_customer:=public.assert_customer_master_access(p_company_id,p_customer_id,true);
  if nullif(trim(coalesce(p_recipient_name,'')),'') is null or nullif(trim(coalesce(p_address_line,'')),'') is null then raise exception 'Destinatario y dirección son obligatorios.';end if;
  if nullif(trim(coalesce(p_municipality,'')),'') is null or nullif(trim(coalesce(p_state_name,'')),'') is null or nullif(trim(coalesce(p_postal_code,'')),'') is null then raise exception 'Municipio, estado y código postal son obligatorios para envíos.';end if;
  if v_country!~'^[A-Z]{2}$' then raise exception 'El país debe usar un código ISO de dos letras.';end if;
  if v_country='MX' and trim(p_postal_code)!~'^[0-9]{5}$' then raise exception 'El código postal de México debe tener 5 dígitos.';end if;
  if p_is_primary then update public.customer_addresses set is_primary=false where customer_id=p_customer_id and(p_address_id is null or id<>p_address_id);end if;
  if p_address_id is null then
    insert into public.customer_addresses(company_id,customer_id,label,recipient_name,phone,address_line,address_line_2,neighborhood,municipality,state_name,postal_code,country_code,delivery_instructions,is_primary)
    values(p_company_id,p_customer_id,coalesce(nullif(trim(p_label),''),'Entrega'),trim(p_recipient_name),nullif(trim(p_phone),''),trim(p_address_line),nullif(trim(p_address_line_2),''),nullif(trim(p_neighborhood),''),trim(p_municipality),trim(p_state_name),trim(p_postal_code),v_country,nullif(trim(p_delivery_instructions),''),coalesce(p_is_primary,false) or not exists(select 1 from public.customer_addresses where customer_id=p_customer_id)) returning id into v_id;
  else
    select * into v_address from public.customer_addresses where id=p_address_id and customer_id=p_customer_id and company_id=p_company_id for update;
    if not found then raise exception 'Dirección no encontrada.';end if;
    update public.customer_addresses set label=coalesce(nullif(trim(p_label),''),'Entrega'),recipient_name=trim(p_recipient_name),phone=nullif(trim(p_phone),''),address_line=trim(p_address_line),address_line_2=nullif(trim(p_address_line_2),''),neighborhood=nullif(trim(p_neighborhood),''),municipality=trim(p_municipality),state_name=trim(p_state_name),postal_code=trim(p_postal_code),country_code=v_country,delivery_instructions=nullif(trim(p_delivery_instructions),''),is_primary=coalesce(p_is_primary,false),normalized_address=null,latitude=null,longitude=null,geocoding_provider=null,geocoding_precision=null,geocoding_attempted_at=null,geocoded_at=null,geocoding_error_code=null where id=p_address_id returning id into v_id;
  end if;
  perform public.write_sales_audit(p_company_id,'customer.delivery_address_saved','customer_addresses',v_id,jsonb_build_object('customer_id',p_customer_id,'is_primary',coalesce(p_is_primary,false)));
  return v_id;
end $$;

create or replace function public.record_sales_order_delivery_address(
  p_company_id uuid,p_order_id uuid,p_customer_address_id uuid,p_source text,p_recipient_name text,p_phone text,
  p_address_line text,p_address_line_2 text,p_neighborhood text,p_municipality text,p_state_name text,
  p_postal_code text,p_country_code text,p_delivery_instructions text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.sales_deposit_orders%rowtype;v_existing public.sales_order_delivery_addresses%rowtype;v_address public.sales_order_delivery_addresses%rowtype;v_country text:=upper(trim(coalesce(p_country_code,'MX')));
begin
  select * into v_order from public.sales_deposit_orders where id=p_order_id and company_id=p_company_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(p_company_id,'manage_sales_orders') or not public.can_access_location(v_order.location_id) then raise exception 'Pedido no disponible.';end if;
  if p_source not in('customer_address','manual','shopify') then raise exception 'Origen de dirección no válido.';end if;
  if nullif(trim(coalesce(p_recipient_name,'')),'') is null or nullif(trim(coalesce(p_address_line,'')),'') is null or nullif(trim(coalesce(p_municipality,'')),'') is null or nullif(trim(coalesce(p_state_name,'')),'') is null or nullif(trim(coalesce(p_postal_code,'')),'') is null then raise exception 'La dirección de entrega está incompleta.';end if;
  if v_country!~'^[A-Z]{2}$' or(v_country='MX' and trim(p_postal_code)!~'^[0-9]{5}$') then raise exception 'País o código postal no válido.';end if;
  if p_customer_address_id is not null and not exists(select 1 from public.customer_addresses where id=p_customer_address_id and company_id=p_company_id and customer_id=v_order.customer_id) then raise exception 'La dirección no pertenece al cliente del pedido.';end if;
  select * into v_existing from public.sales_order_delivery_addresses where order_id=p_order_id;
  if found then
    if row(v_existing.source,v_existing.customer_address_id,v_existing.recipient_name,coalesce(v_existing.phone,''),v_existing.address_line,coalesce(v_existing.address_line_2,''),coalesce(v_existing.neighborhood,''),v_existing.municipality,v_existing.state_name,v_existing.postal_code,v_existing.country_code,coalesce(v_existing.delivery_instructions,''))
      is distinct from row(p_source,p_customer_address_id,trim(p_recipient_name),coalesce(nullif(trim(p_phone),''),''),trim(p_address_line),coalesce(nullif(trim(p_address_line_2),''),''),coalesce(nullif(trim(p_neighborhood),''),''),trim(p_municipality),trim(p_state_name),trim(p_postal_code),v_country,coalesce(nullif(trim(p_delivery_instructions),''),'')) then raise exception 'El pedido ya conserva otra dirección de entrega.';end if;
    return to_jsonb(v_existing)||jsonb_build_object('idempotent',true);
  end if;
  insert into public.sales_order_delivery_addresses(company_id,order_id,customer_address_id,source,recipient_name,phone,address_line,address_line_2,neighborhood,municipality,state_name,postal_code,country_code,delivery_instructions)
  values(p_company_id,p_order_id,p_customer_address_id,p_source,trim(p_recipient_name),nullif(trim(p_phone),''),trim(p_address_line),nullif(trim(p_address_line_2),''),nullif(trim(p_neighborhood),''),trim(p_municipality),trim(p_state_name),trim(p_postal_code),v_country,nullif(trim(p_delivery_instructions),'')) returning * into v_address;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'sales_order.delivery_address_recorded','sales_order_delivery_address',v_address.id,jsonb_build_object('order_id',p_order_id,'source',p_source));
  return to_jsonb(v_address)||jsonb_build_object('idempotent',false);
end $$;

revoke all on function public.protect_sales_order_delivery_address() from public,anon,authenticated;
revoke all on function public.save_product_shipping_profile(uuid,uuid,numeric,numeric,numeric,numeric,text,integer,boolean,text,timestamptz,text,timestamptz,uuid) from public,anon;
revoke all on function public.save_customer_delivery_address(uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,boolean) from public,anon;
revoke all on function public.record_sales_order_delivery_address(uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.save_product_shipping_profile(uuid,uuid,numeric,numeric,numeric,numeric,text,integer,boolean,text,timestamptz,text,timestamptz,uuid) to authenticated;
grant execute on function public.save_customer_delivery_address(uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.record_sales_order_delivery_address(uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,text,text) to authenticated;

commit;
