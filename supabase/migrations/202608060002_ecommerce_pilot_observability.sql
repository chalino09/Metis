-- Ecommerce piloto · Shopify opera; Satrapy registra, controla calidad y analiza.
-- Clientes y direcciones son canónicos; cada pedido conserva sus snapshots.

begin;

drop function if exists public.get_product_shipping_profile(uuid,uuid);
drop function if exists public.save_product_shipping_profile(
  uuid,uuid,numeric,numeric,numeric,numeric,text,integer,boolean,text,timestamptz,text,timestamptz,uuid
);
drop index if exists public.audit_product_shipping_profile_request_uidx;
drop table if exists public.product_shipping_profiles;

create table public.ecommerce_company_settings(
  company_id uuid primary key references public.companies(id) on delete cascade,
  low_margin_percent numeric(7,4) not null default 15 check(low_margin_percent between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger ecommerce_company_settings_updated_at before update on public.ecommerce_company_settings
  for each row execute function public.set_updated_at();

create table public.shopify_stores(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null unique references public.companies(id) on delete cascade,
  shop_domain text not null,
  shop_gid text,
  installed_at timestamptz,
  last_sync_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(shop_domain=lower(trim(shop_domain)) and shop_domain~'^[a-z0-9][a-z0-9-]*\.myshopify\.com$'),
  unique(shop_domain)
);
create trigger shopify_stores_updated_at before update on public.shopify_stores
  for each row execute function public.set_updated_at();

create table public.shopify_customer_links(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  shopify_store_id uuid not null references public.shopify_stores(id) on delete cascade,
  shopify_customer_gid text not null,
  customer_id uuid not null references public.customers(id) on delete cascade,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(shopify_store_id,shopify_customer_gid),
  check(nullif(trim(shopify_customer_gid),'') is not null)
);
create index shopify_customer_links_customer_idx on public.shopify_customer_links(company_id,customer_id);

create table public.meta_ad_accounts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  external_account_id text not null,
  display_name text,
  currency_code text check(currency_code is null or currency_code~'^[A-Z]{3}$'),
  connected_at timestamptz,
  last_sync_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,external_account_id),
  check(nullif(trim(external_account_id),'') is not null)
);
create trigger meta_ad_accounts_updated_at before update on public.meta_ad_accounts
  for each row execute function public.set_updated_at();

create table public.meta_ad_daily_performance(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  meta_ad_account_id uuid not null references public.meta_ad_accounts(id) on delete cascade,
  performance_date date not null,
  campaign_id text not null,
  campaign_name text,
  ad_set_id text,
  ad_set_name text,
  ad_id text,
  ad_name text,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  spend_amount numeric(16,2) not null default 0 check(spend_amount>=0),
  impressions bigint not null default 0 check(impressions>=0),
  clicks bigint not null default 0 check(clicks>=0),
  attributed_purchases numeric(14,4) not null default 0 check(attributed_purchases>=0),
  attributed_purchase_value numeric(16,2) not null default 0 check(attributed_purchase_value>=0),
  performance_grain text generated always as(campaign_id||'|'||coalesce(ad_set_id,'')||'|'||coalesce(ad_id,'')) stored,
  raw_payload jsonb not null,
  last_synced_at timestamptz not null default now(),
  unique(meta_ad_account_id,performance_date,performance_grain)
);
create index meta_ad_daily_performance_company_date_idx on public.meta_ad_daily_performance(company_id,performance_date desc);

create table public.ecommerce_orders(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  shopify_store_id uuid not null references public.shopify_stores(id) on delete cascade,
  shopify_order_gid text not null,
  order_name text not null,
  customer_id uuid references public.customers(id) on delete set null,
  customer_match_status text not null default 'unresolved' check(customer_match_status in('matched','created','guest','unresolved','conflict')),
  customer_name_snapshot text,
  customer_email_snapshot text,
  customer_phone_snapshot text,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  financial_status text,
  fulfillment_status text,
  source_name text,
  referring_site text,
  landing_site text,
  customer_locale text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  meta_campaign_id text,
  meta_ad_set_id text,
  meta_ad_id text,
  fbclid text,
  subtotal_amount numeric(16,2) not null default 0 check(subtotal_amount>=0),
  discount_amount numeric(16,2) not null default 0 check(discount_amount>=0),
  tax_amount numeric(16,2) not null default 0 check(tax_amount>=0),
  shipping_charged_amount numeric(16,2) not null default 0 check(shipping_charged_amount>=0),
  total_amount numeric(16,2) not null default 0 check(total_amount>=0),
  refunded_amount numeric(16,2) not null default 0 check(refunded_amount>=0),
  actual_shipping_cost_amount numeric(16,2) check(actual_shipping_cost_amount is null or actual_shipping_cost_amount>=0),
  processed_at timestamptz not null,
  cancelled_at timestamptz,
  closed_at timestamptz,
  raw_payload jsonb not null,
  first_synced_at timestamptz not null default now(),
  last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(shopify_store_id,shopify_order_gid),
  check(nullif(trim(shopify_order_gid),'') is not null and nullif(trim(order_name),'') is not null),
  check((customer_id is null and customer_match_status in('guest','unresolved','conflict')) or customer_id is not null)
);
create index ecommerce_orders_company_processed_idx on public.ecommerce_orders(company_id,processed_at desc,id);
create index ecommerce_orders_attribution_idx on public.ecommerce_orders(company_id,utm_campaign,meta_campaign_id,processed_at desc);
create trigger ecommerce_orders_updated_at before update on public.ecommerce_orders
  for each row execute function public.set_updated_at();

create table public.ecommerce_order_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null references public.ecommerce_orders(id) on delete cascade,
  shopify_line_gid text not null,
  product_id uuid references public.products(id) on delete set null,
  sku_snapshot text,
  name_snapshot text not null,
  variant_snapshot text,
  quantity numeric(14,3) not null check(quantity>0),
  unit_price_amount numeric(16,2) not null check(unit_price_amount>=0),
  discount_amount numeric(16,2) not null default 0 check(discount_amount>=0),
  total_amount numeric(16,2) not null check(total_amount>=0),
  recognized_unit_cost_amount numeric(18,6) check(recognized_unit_cost_amount is null or recognized_unit_cost_amount>=0),
  recognized_cost_currency_code text check(recognized_cost_currency_code is null or recognized_cost_currency_code~'^[A-Z]{3}$'),
  recognized_product_cost_id uuid references public.product_costs(id) on delete restrict,
  recognized_product_cost_amount numeric(18,6) generated always as(
    case when recognized_unit_cost_amount is null then null else round(quantity*recognized_unit_cost_amount,6) end
  ) stored,
  raw_payload jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id,shopify_line_gid),
  check((recognized_unit_cost_amount is null and recognized_cost_currency_code is null and recognized_product_cost_id is null) or(recognized_unit_cost_amount is not null and recognized_cost_currency_code is not null and recognized_product_cost_id is not null))
);
create index ecommerce_order_lines_product_idx on public.ecommerce_order_lines(company_id,product_id) where product_id is not null;
create trigger ecommerce_order_lines_updated_at before update on public.ecommerce_order_lines
  for each row execute function public.set_updated_at();

create table public.ecommerce_order_addresses(
  order_id uuid primary key references public.ecommerce_orders(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_address_id uuid references public.customer_addresses(id) on delete set null,
  recipient_name text,
  phone text,
  company_name text,
  address_line text,
  address_line_2 text,
  neighborhood text,
  city text,
  province text,
  province_code text,
  postal_code text,
  country_code text check(country_code is null or country_code~'^[A-Z]{2}$'),
  latitude numeric(9,6),
  longitude numeric(9,6),
  coordinates_validated boolean,
  raw_payload jsonb not null,
  last_synced_at timestamptz not null default now(),
  check((latitude is null and longitude is null) or(latitude between -90 and 90 and longitude between -180 and 180))
);
create index ecommerce_order_addresses_map_idx on public.ecommerce_order_addresses(company_id,country_code,province,city)
  where latitude is not null and longitude is not null;

create table public.ecommerce_fulfillments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  order_id uuid not null references public.ecommerce_orders(id) on delete cascade,
  shopify_fulfillment_gid text not null,
  status text,
  tracking_company text,
  tracking_numbers jsonb not null default '[]'::jsonb,
  tracking_urls jsonb not null default '[]'::jsonb,
  shipped_at timestamptz,
  delivered_at timestamptz,
  raw_payload jsonb not null,
  last_synced_at timestamptz not null default now(),
  unique(order_id,shopify_fulfillment_gid),
  check(jsonb_typeof(tracking_numbers)='array' and jsonb_typeof(tracking_urls)='array')
);
create index ecommerce_fulfillments_company_status_idx on public.ecommerce_fulfillments(company_id,status,last_synced_at desc);

create table public.shopify_webhook_receipts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  shopify_store_id uuid not null references public.shopify_stores(id) on delete cascade,
  shopify_event_id text not null,
  topic text not null,
  status text not null default 'received' check(status in('received','processed','failed')),
  occurred_at timestamptz,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  retry_count integer not null default 0 check(retry_count>=0),
  next_retry_at timestamptz,
  error_code text,
  payload jsonb not null,
  unique(shopify_store_id,shopify_event_id),
  check(nullif(trim(shopify_event_id),'') is not null and nullif(trim(topic),'') is not null)
);
create index shopify_webhook_receipts_pending_idx on public.shopify_webhook_receipts(coalesce(next_retry_at,received_at),id)
  where status in('received','failed');

create or replace function public.assert_ecommerce_pilot_company_integrity()
returns trigger language plpgsql set search_path=public as $$
declare v_order_company uuid;v_store_company uuid;v_product_company uuid;v_customer_company uuid;v_account_company uuid;
begin
  if tg_table_name='ecommerce_orders' then
    select company_id into v_store_company from public.shopify_stores where id=new.shopify_store_id;
    if v_store_company is distinct from new.company_id then raise exception 'La tienda no pertenece a la empresa del pedido.';end if;
    if new.customer_id is not null and not exists(select 1 from public.customers where id=new.customer_id and company_id=new.company_id) then raise exception 'El cliente no pertenece a la empresa del pedido.';end if;
  elsif tg_table_name in('ecommerce_order_lines','ecommerce_order_addresses','ecommerce_fulfillments') then
    select company_id into v_order_company from public.ecommerce_orders where id=new.order_id;
    if v_order_company is distinct from new.company_id then raise exception 'El registro no pertenece a la empresa del pedido.';end if;
    if tg_table_name='ecommerce_order_lines' and nullif(to_jsonb(new)->>'product_id','') is not null then
      select company_id into v_product_company from public.products where id=(to_jsonb(new)->>'product_id')::uuid;
      if v_product_company is distinct from new.company_id then raise exception 'El producto vinculado no pertenece a la empresa del pedido.';end if;
    elsif tg_table_name='ecommerce_order_addresses' and nullif(to_jsonb(new)->>'customer_address_id','') is not null then
      select company_id into v_customer_company from public.customer_addresses where id=(to_jsonb(new)->>'customer_address_id')::uuid;
      if v_customer_company is distinct from new.company_id then raise exception 'La dirección vinculada no pertenece a la empresa del pedido.';end if;
    end if;
  elsif tg_table_name in('shopify_customer_links','shopify_webhook_receipts') then
    select company_id into v_store_company from public.shopify_stores where id=new.shopify_store_id;
    if v_store_company is distinct from new.company_id then raise exception 'El registro no pertenece a la empresa de la tienda.';end if;
    if tg_table_name='shopify_customer_links' then
      select company_id into v_customer_company from public.customers where id=new.customer_id;
      if v_customer_company is distinct from new.company_id then raise exception 'El cliente vinculado no pertenece a la empresa.';end if;
    end if;
  elsif tg_table_name='meta_ad_daily_performance' then
    select company_id into v_account_company from public.meta_ad_accounts where id=new.meta_ad_account_id;
    if v_account_company is distinct from new.company_id then raise exception 'El resultado no pertenece a la empresa de la cuenta publicitaria.';end if;
  end if;
  return new;
end $$;

create trigger ecommerce_orders_company_guard before insert or update on public.ecommerce_orders for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger ecommerce_order_lines_company_guard before insert or update on public.ecommerce_order_lines for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger ecommerce_order_addresses_company_guard before insert or update on public.ecommerce_order_addresses for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger ecommerce_fulfillments_company_guard before insert or update on public.ecommerce_fulfillments for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger shopify_customer_links_company_guard before insert or update on public.shopify_customer_links for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger shopify_webhook_receipts_company_guard before insert or update on public.shopify_webhook_receipts for each row execute function public.assert_ecommerce_pilot_company_integrity();
create trigger meta_ad_daily_performance_company_guard before insert or update on public.meta_ad_daily_performance for each row execute function public.assert_ecommerce_pilot_company_integrity();

create or replace function public.resolve_shopify_customer(
  p_company_id uuid,p_shopify_store_id uuid,p_shopify_customer_gid text,p_email text,p_phone text,p_display_name text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_email text:=nullif(lower(trim(coalesce(p_email,''))),'');v_phone text:=nullif(regexp_replace(coalesce(p_phone,''),'[^0-9]','','g'),'');
  v_email_customer uuid;v_phone_customer uuid;v_customer uuid;v_status text;v_link public.shopify_customer_links%rowtype;v_contact uuid;v_email_matches integer:=0;v_phone_matches integer:=0;
begin
  if auth.role()<>'service_role' then raise exception 'Disponible únicamente para el sincronizador.';end if;
  if not exists(select 1 from public.shopify_stores where id=p_shopify_store_id and company_id=p_company_id) then raise exception 'Tienda no disponible.';end if;
  if nullif(trim(coalesce(p_shopify_customer_gid,'')),'') is not null then
    select * into v_link from public.shopify_customer_links where shopify_store_id=p_shopify_store_id and shopify_customer_gid=trim(p_shopify_customer_gid) for update;
    if found then update public.shopify_customer_links set last_seen_at=now() where id=v_link.id;return jsonb_build_object('customer_id',v_link.customer_id,'status','matched');end if;
  end if;
  if v_email is not null then
    select count(distinct customer_id) into v_email_matches from public.customer_contacts where company_id=p_company_id and lower(email)=v_email;
    select customer_id into v_email_customer from public.customer_contacts where company_id=p_company_id and lower(email)=v_email order by created_at,id limit 1;
  end if;
  if v_phone is not null then
    select count(distinct customer_id) into v_phone_matches from public.customer_contacts where company_id=p_company_id and regexp_replace(coalesce(phone,''),'[^0-9]','','g')=v_phone;
    select customer_id into v_phone_customer from public.customer_contacts where company_id=p_company_id and regexp_replace(coalesce(phone,''),'[^0-9]','','g')=v_phone order by created_at,id limit 1;
  end if;
  if v_email_matches>1 or v_phone_matches>1 or(v_email_customer is not null and v_phone_customer is not null and v_email_customer<>v_phone_customer) then return jsonb_build_object('customer_id',null,'status','conflict');end if;
  v_customer:=coalesce(v_email_customer,v_phone_customer);
  if v_customer is null then
    if nullif(trim(coalesce(p_display_name,'')),'') is null or(v_email is null and v_phone is null) then return jsonb_build_object('customer_id',null,'status',case when nullif(trim(coalesce(p_shopify_customer_gid,'')),'') is null then 'guest' else 'unresolved' end);end if;
    insert into public.customers(company_id,code,display_name,credit_enabled,credit_limit,credit_term_days,is_active,created_by)
    values(p_company_id,'ECOM-'||upper(substr(md5(coalesce(nullif(trim(p_shopify_customer_gid),''),v_email,v_phone,gen_random_uuid()::text)),1,12)),trim(p_display_name),false,0,0,true,null)
    returning id into v_customer;
    insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,email,is_primary,created_by)
    values(p_company_id,v_customer,trim(p_display_name),'Contacto principal',nullif(trim(p_phone),''),v_email,true,null);
    v_status:='created';
  else
    v_status:='matched';
    select id into v_contact from public.customer_contacts where customer_id=v_customer and((v_email is not null and lower(email)=v_email)or(v_phone is not null and regexp_replace(coalesce(phone,''),'[^0-9]','','g')=v_phone)) order by is_primary desc,created_at limit 1;
    if v_contact is not null then update public.customer_contacts set email=coalesce(email,v_email),phone=coalesce(phone,nullif(trim(p_phone),'')) where id=v_contact;end if;
  end if;
  if nullif(trim(coalesce(p_shopify_customer_gid,'')),'') is not null then
    insert into public.shopify_customer_links(company_id,shopify_store_id,shopify_customer_gid,customer_id)
    values(p_company_id,p_shopify_store_id,trim(p_shopify_customer_gid),v_customer)
    on conflict(shopify_store_id,shopify_customer_gid) do update set customer_id=excluded.customer_id,last_seen_at=now();
  end if;
  return jsonb_build_object('customer_id',v_customer,'status',v_status);
end $$;

create or replace function public.resolve_shopify_customer_address(
  p_company_id uuid,p_customer_id uuid,p_recipient_name text,p_phone text,p_address_line text,p_address_line_2 text,
  p_neighborhood text,p_city text,p_province text,p_postal_code text,p_country_code text
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_primary boolean;v_country text:=upper(nullif(trim(coalesce(p_country_code,'')),''));
begin
  if auth.role()<>'service_role' then raise exception 'Disponible únicamente para el sincronizador.';end if;
  if not exists(select 1 from public.customers where id=p_customer_id and company_id=p_company_id) then raise exception 'Cliente no disponible.';end if;
  if nullif(trim(coalesce(p_address_line,'')),'') is null then return null;end if;
  select id into v_id from public.customer_addresses where company_id=p_company_id and customer_id=p_customer_id
    and lower(trim(address_line))=lower(trim(p_address_line)) and lower(coalesce(trim(address_line_2),''))=lower(coalesce(trim(p_address_line_2),''))
    and lower(coalesce(trim(municipality),''))=lower(coalesce(trim(p_city),'')) and lower(coalesce(trim(state_name),''))=lower(coalesce(trim(p_province),''))
    and coalesce(trim(postal_code),'')=coalesce(trim(p_postal_code),'') and country_code=coalesce(v_country,'MX') order by created_at limit 1;
  if v_id is not null then return v_id;end if;
  v_primary:=not exists(select 1 from public.customer_addresses where customer_id=p_customer_id);
  insert into public.customer_addresses(company_id,customer_id,label,recipient_name,phone,address_line,address_line_2,neighborhood,municipality,state_name,postal_code,country_code,is_primary,created_by)
  values(p_company_id,p_customer_id,'Entrega Shopify',nullif(trim(p_recipient_name),''),nullif(trim(p_phone),''),trim(p_address_line),nullif(trim(p_address_line_2),''),nullif(trim(p_neighborhood),''),nullif(trim(p_city),''),nullif(trim(p_province),''),nullif(trim(p_postal_code),''),coalesce(v_country,'MX'),v_primary,null)
  returning id into v_id;
  return v_id;
end $$;

alter table public.ecommerce_company_settings enable row level security;
alter table public.shopify_stores enable row level security;
alter table public.shopify_customer_links enable row level security;
alter table public.meta_ad_accounts enable row level security;
alter table public.meta_ad_daily_performance enable row level security;
alter table public.ecommerce_orders enable row level security;
alter table public.ecommerce_order_lines enable row level security;
alter table public.ecommerce_order_addresses enable row level security;
alter table public.ecommerce_fulfillments enable row level security;
alter table public.shopify_webhook_receipts enable row level security;
revoke all on public.ecommerce_company_settings,public.shopify_stores,public.shopify_customer_links,public.meta_ad_accounts,public.meta_ad_daily_performance,public.ecommerce_orders,public.ecommerce_order_lines,public.ecommerce_order_addresses,public.ecommerce_fulfillments,public.shopify_webhook_receipts from authenticated;

create or replace function public.get_ecommerce_pilot_summary(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_store public.shopify_stores%rowtype;v_meta public.meta_ad_accounts%rowtype;v_threshold numeric;v_orders bigint;v_alerts jsonb;
begin
  if auth.uid() is null or not(
    public.has_company_permission(p_company_id,'view_sales_orders') or public.has_company_permission(p_company_id,'view_products') or public.has_company_permission(p_company_id,'view_bi')
  ) then raise exception 'No autorizado para consultar Ecommerce.';end if;
  select * into v_store from public.shopify_stores where company_id=p_company_id;
  select * into v_meta from public.meta_ad_accounts where company_id=p_company_id order by connected_at desc nulls last,created_at desc limit 1;
  select low_margin_percent into v_threshold from public.ecommerce_company_settings where company_id=p_company_id;
  v_threshold:=coalesce(v_threshold,15);
  select count(*) into v_orders from public.ecommerce_orders where company_id=p_company_id;
  with order_margin as(
    select o.id,o.total_amount-o.refunded_amount net_revenue,o.actual_shipping_cost_amount,
      count(l.id) line_count,count(l.recognized_product_cost_amount) costed_lines,sum(l.recognized_product_cost_amount) product_cost
    from public.ecommerce_orders o left join public.ecommerce_order_lines l on l.order_id=o.id
    where o.company_id=p_company_id and o.cancelled_at is null group by o.id
  ), alert_counts as(
    select
      (select count(*) from public.shopify_webhook_receipts where company_id=p_company_id and status='failed') failed_sync,
      (select count(*) from public.ecommerce_order_lines where company_id=p_company_id and product_id is null) unlinked_products,
      (select count(*) from public.ecommerce_orders o left join public.ecommerce_order_addresses a on a.order_id=o.id where o.company_id=p_company_id and(a.order_id is null or nullif(trim(a.address_line),'') is null or nullif(trim(a.city),'') is null or nullif(trim(a.province),'') is null or nullif(trim(a.postal_code),'') is null or nullif(trim(a.country_code),'') is null)) incomplete_addresses,
      (select count(*) from public.ecommerce_orders where company_id=p_company_id and actual_shipping_cost_amount is null) unknown_shipping,
      (select count(*) from order_margin where line_count>0 and line_count=costed_lines and actual_shipping_cost_amount is not null and net_revenue-product_cost-actual_shipping_cost_amount<0) negative_margin,
      (select count(*) from order_margin where line_count>0 and line_count=costed_lines and actual_shipping_cost_amount is not null and net_revenue>0 and net_revenue-product_cost-actual_shipping_cost_amount>=0 and((net_revenue-product_cost-actual_shipping_cost_amount)/net_revenue*100)<v_threshold) low_margin
  ) select jsonb_build_array(
    jsonb_build_object('code','sync_failed','title','Actualizaciones sin sincronizar','count',failed_sync,'severity','critical','detail','Reintenta la importación desde Shopify.'),
    jsonb_build_object('code','product_unlinked','title','Productos sin vincular','count',unlinked_products,'severity','warning','detail','Relaciona el SKU de Shopify con el producto canónico.'),
    jsonb_build_object('code','address_incomplete','title','Direcciones incompletas','count',incomplete_addresses,'severity','warning','detail','Corrige el domicilio en Shopify para recibir la actualización.'),
    jsonb_build_object('code','shipping_cost_unknown','title','Costos de envío desconocidos','count',unknown_shipping,'severity','warning','detail','Importa el costo real antes de evaluar rentabilidad.'),
    jsonb_build_object('code','margin_at_risk','title','Ventas con margen en riesgo','count',negative_margin+low_margin,'severity',case when negative_margin>0 then 'critical' else 'warning' end,'detail',negative_margin||' con margen negativo y '||low_margin||' debajo de '||trim(to_char(v_threshold,'FM999990.##'))||'%.')
  ) into v_alerts from alert_counts;
  return jsonb_build_object(
    'settings',jsonb_build_object('low_margin_percent',v_threshold),
    'shopify',case when v_store.id is null then jsonb_build_object('connected',false) else jsonb_build_object('connected',v_store.installed_at is not null,'shop_domain',v_store.shop_domain,'installed_at',v_store.installed_at,'last_sync_at',v_store.last_sync_at,'last_error_code',v_store.last_error_code) end,
    'meta_ads',case when v_meta.id is null then jsonb_build_object('connected',false) else jsonb_build_object('connected',v_meta.connected_at is not null,'account_name',v_meta.display_name,'last_sync_at',v_meta.last_sync_at,'last_error_code',v_meta.last_error_code) end,
    'coverage',jsonb_build_object(
      'orders',v_orders,
      'order_lines',(select count(*) from public.ecommerce_order_lines where company_id=p_company_id),
      'linked_lines',(select count(*) from public.ecommerce_order_lines where company_id=p_company_id and product_id is not null),
      'complete_addresses',(select count(*) from public.ecommerce_order_addresses where company_id=p_company_id and nullif(trim(address_line),'') is not null and nullif(trim(city),'') is not null and nullif(trim(province),'') is not null and nullif(trim(postal_code),'') is not null and nullif(trim(country_code),'') is not null),
      'known_shipping_costs',(select count(*) from public.ecommerce_orders where company_id=p_company_id and actual_shipping_cost_amount is not null),
      'attributed_orders',(select count(*) from public.ecommerce_orders where company_id=p_company_id and(utm_campaign is not null or meta_campaign_id is not null)),
      'last_order_at',(select max(processed_at) from public.ecommerce_orders where company_id=p_company_id)
    ),
    'alerts',v_alerts,
    'currency_totals',coalesce((select jsonb_agg(to_jsonb(currency_data) order by currency_data.currency_code) from(
      select currency_code,count(*) order_count,round(sum(total_amount-refunded_amount),2) net_sales_amount,round(sum(shipping_charged_amount),2) shipping_charged_amount,round(sum(coalesce(actual_shipping_cost_amount,0)),2) known_shipping_cost_amount
      from public.ecommerce_orders where company_id=p_company_id group by currency_code
    ) currency_data),'[]'::jsonb)
  );
end $$;

revoke all on function public.assert_ecommerce_pilot_company_integrity() from public,anon,authenticated;
revoke all on function public.resolve_shopify_customer(uuid,uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.resolve_shopify_customer_address(uuid,uuid,text,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.resolve_shopify_customer(uuid,uuid,text,text,text,text) to service_role;
grant execute on function public.resolve_shopify_customer_address(uuid,uuid,text,text,text,text,text,text,text,text,text) to service_role;
revoke all on function public.get_ecommerce_pilot_summary(uuid) from public,anon;
grant execute on function public.get_ecommerce_pilot_summary(uuid) to authenticated;

commit;
