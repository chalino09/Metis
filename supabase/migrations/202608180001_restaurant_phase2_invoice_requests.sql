-- Restaurante fase 2 · funciones culinarias explícitas y solicitudes de factura.
-- Reutiliza productos, clientes, ventas, tickets, permisos y auditoría canónicos.

insert into public.permissions(code,description) values
  ('view_invoice_requests','Consultar solicitudes de factura de venta.'),
  ('manage_invoice_requests','Capturar y atender solicitudes de factura de venta.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in ('view_invoice_requests','manage_invoice_requests')
on conflict do nothing;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('sucursal','punto_venta') and p.code='view_invoice_requests'
on conflict do nothing;

create table if not exists public.product_culinary_roles(
  company_id uuid not null references public.companies(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  role text not null check(role in ('dish','ingredient','preparation')),
  assigned_at timestamptz not null default now(),
  assigned_by uuid references auth.users(id),
  reason text not null,
  primary key(product_id,role)
);
create index if not exists product_culinary_roles_company_role_idx on public.product_culinary_roles(company_id,role,product_id);

-- Conserva la lectura vigente al instalar la migración; desde este punto el rol
-- deja de inferirse y sólo cambia mediante una operación explícita y auditada.
insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
select p.company_id,p.id,case when r.recipe_kind='preparation' then 'preparation' when r.recipe_kind='dish' then 'dish' when p.is_inventory_tracked then 'ingredient' else 'dish' end,
  null,'Clasificación inicial al activar funciones culinarias explícitas'
from public.products p
join public.companies c on c.id=p.company_id and c.product_experience_code='restaurant'
left join lateral(select cr.recipe_kind from public.culinary_recipes cr where cr.company_id=p.company_id and cr.product_id=p.id order by case cr.recipe_kind when 'preparation' then 1 else 2 end limit 1)r on true
on conflict do nothing;

create or replace function public.set_product_culinary_role(p_company_id uuid,p_product_id uuid,p_role text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_product public.products%rowtype;
begin
  if auth.uid() is null or not(public.is_super_admin() or public.has_company_permission(p_company_id,'manage_products')) then raise exception 'No autorizado para cambiar la función culinaria.';end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no válida.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo es obligatorio.';end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id for update;
  if not found then raise exception 'Producto no encontrado.';end if;
  if p_role='preparation' and v_product.is_sellable then raise exception 'Una preparación no puede estar disponible para venta.';end if;
  delete from public.product_culinary_roles where product_id=p_product_id;
  insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason) values(p_company_id,p_product_id,p_role,auth.uid(),trim(p_reason));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'product.culinary_role_changed','products',p_product_id,jsonb_build_object('role',p_role,'reason',trim(p_reason)));
  return jsonb_build_object('product_id',p_product_id,'role',p_role);
end $$;

create or replace function public.search_restaurant_catalog(p_company_id uuid,p_role text default 'dish',p_query text default null,p_page integer default 1,p_page_size integer default 50,p_is_sellable boolean default null)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;v_can_view_prices boolean;
begin
  if auth.uid() is null or not(public.is_super_admin() or public.has_company_permission(p_company_id,'view_products')) then raise exception 'No autorizado para consultar el catálogo.';end if;
  if p_role not in ('dish','ingredient','preparation') then raise exception 'Función culinaria no reconocida.';end if;
  v_can_view_prices:=public.is_super_admin() or public.has_company_permission(p_company_id,'view_prices');
  with scoped as materialized(
    select p.*,price.amount price_amount,price.currency_code,case when v_query='' then 0 when lower(coalesce(p.internal_sku,''))=v_query then 1 when lower(coalesce(p.barcode,''))=v_query then 2 else 3 end rank
    from public.product_culinary_roles role_data join public.products p on p.id=role_data.product_id
    left join lateral(select pp.amount,pp.currency_code from public.product_prices pp where pp.product_id=p.id and pp.valid_from<=now() and(pp.valid_to is null or pp.valid_to>now())order by pp.valid_from desc,pp.id desc limit 1)price on true
    where role_data.company_id=p_company_id and role_data.role=p_role and p.is_active and(p_is_sellable is null or p.is_sellable=p_is_sellable)
      and(v_query='' or lower(p.name)like'%'||v_query||'%' or lower(coalesce(p.internal_sku,''))like'%'||v_query||'%' or lower(coalesce(p.barcode,''))=v_query)
  ),paged as(select * from scoped order by rank,name,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from scoped),coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'alpha_sku',p.alpha_sku,'internal_sku',p.internal_sku,'barcode',p.barcode,'name',p.name,'unit',p.unit,'product_group',p.product_group,'product_type',p.product_type,'is_active',p.is_active,'is_sellable',p.is_sellable,'is_inventory_tracked',p.is_inventory_tracked,'price',case when v_can_view_prices then p.price_amount else null end,'currency_code',case when v_can_view_prices then p.currency_code else null end,'pos_ready',false,'blockers','[]'::jsonb,'catalog_role',p_role,'is_preparation',p_role='preparation')order by p.rank,p.name,p.id)from paged p),'[]')into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'catalog_role',p_role);
end $$;

create table if not exists public.sale_invoice_requests(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  sale_id uuid not null references public.sales(id) on delete restrict,ticket_id uuid not null references public.canonical_tickets(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete set null,status text not null default 'pending_review' check(status in('pending_review','ready_to_issue','issued','rejected','cancelled')),
  tax_id text not null,legal_name text not null,tax_regime_code text not null,fiscal_postal_code text not null,cfdi_use_code text not null,email text not null,
  public_token uuid not null default gen_random_uuid(),client_request_id uuid not null,source text not null default 'cashier' check(source in('cashier','self_service')),
  rejection_reason text,issued_cfdi_uuid text,created_by uuid references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(company_id,sale_id),unique(company_id,client_request_id),unique(public_token),
  check(tax_id~'^[A-Z&Ñ]{3,4}[0-9]{6}[A-Z0-9]{3}$'),check(fiscal_postal_code~'^[0-9]{5}$'),check(email~'^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
);
create index if not exists sale_invoice_requests_queue_idx on public.sale_invoice_requests(company_id,status,created_at desc,id);
create index if not exists sale_invoice_requests_tax_id_idx on public.sale_invoice_requests(company_id,tax_id);
create table if not exists public.sale_invoice_request_history(
  id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete restrict,
  request_id uuid not null references public.sale_invoice_requests(id) on delete restrict,from_status text,to_status text not null,reason text,actor_id uuid references auth.users(id),created_at timestamptz not null default now()
);

create or replace function public.save_sale_invoice_request(p_company_id uuid,p_sale_id uuid,p_tax_id text,p_legal_name text,p_tax_regime_code text,p_fiscal_postal_code text,p_cfdi_use_code text,p_email text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_sale public.sales%rowtype;v_ticket public.canonical_tickets%rowtype;v_id uuid;v_tax_id text:=public.normalize_customer_tax_id(p_tax_id);v_customer_id uuid;
begin
  if auth.uid() is null or not(public.is_super_admin() or public.has_company_permission(p_company_id,'manage_invoice_requests')) then raise exception 'No autorizado para registrar solicitudes de factura.';end if;
  if p_client_request_id is null then raise exception 'La solicitud requiere una clave de idempotencia.';end if;
  select * into v_sale from public.sales where id=p_sale_id and company_id=p_company_id for share;if not found then raise exception 'Venta no encontrada.';end if;
  if not public.can_access_location(v_sale.location_id) then raise exception 'No autorizado para esta sucursal.';end if;
  if exists(select 1 from public.sale_cancellations where sale_id=p_sale_id)then raise exception 'Una venta cancelada no puede solicitar factura.';end if;
  select * into v_ticket from public.canonical_tickets where sale_id=p_sale_id;
  if nullif(trim(coalesce(p_legal_name,'')),'')is null or nullif(trim(coalesce(p_tax_regime_code,'')),'')is null or trim(coalesce(p_fiscal_postal_code,''))!~'^[0-9]{5}$' or nullif(trim(coalesce(p_cfdi_use_code,'')),'')is null or lower(trim(coalesce(p_email,'')))!~'^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then raise exception 'Completa los datos fiscales y un correo válido.';end if;
  select id into v_id from public.sale_invoice_requests where company_id=p_company_id and client_request_id=p_client_request_id;if v_id is not null then return(select to_jsonb(r)from public.sale_invoice_requests r where r.id=v_id);end if;
  select id into v_customer_id from public.customers where company_id=p_company_id and upper(tax_id)=v_tax_id limit 1;
  insert into public.sale_invoice_requests(company_id,sale_id,ticket_id,customer_id,tax_id,legal_name,tax_regime_code,fiscal_postal_code,cfdi_use_code,email,client_request_id,created_by)
  values(p_company_id,p_sale_id,v_ticket.id,v_customer_id,v_tax_id,upper(trim(p_legal_name)),upper(trim(p_tax_regime_code)),trim(p_fiscal_postal_code),upper(trim(p_cfdi_use_code)),lower(trim(p_email)),p_client_request_id,auth.uid())returning id into v_id;
  insert into public.sale_invoice_request_history(company_id,request_id,to_status,actor_id,reason)values(p_company_id,v_id,'pending_review',auth.uid(),'Solicitud registrada desde el ticket');
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'sale_invoice_request.created','sale_invoice_requests',v_id,jsonb_build_object('sale_id',p_sale_id,'ticket_folio',v_ticket.folio));
  return(select to_jsonb(r)from public.sale_invoice_requests r where r.id=v_id);
exception when unique_violation then raise exception 'Este ticket ya tiene una solicitud de factura.';
end $$;

create or replace function public.list_sale_invoice_requests(p_company_id uuid,p_query text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
 if auth.uid()is null or not(public.is_super_admin() or public.has_company_permission(p_company_id,'view_invoice_requests'))then raise exception 'No autorizado para consultar solicitudes.';end if;
 with scope as materialized(select r.*,t.folio,s.completed_at,l.name location_name from public.sale_invoice_requests r join public.canonical_tickets t on t.id=r.ticket_id join public.sales s on s.id=r.sale_id join public.locations l on l.id=s.location_id where r.company_id=p_company_id and public.can_access_location(s.location_id)and(p_status is null or p_status='all' or r.status=p_status)and(v_query='' or lower(t.folio)like'%'||v_query||'%' or lower(r.tax_id)like'%'||v_query||'%' or lower(r.legal_name)like'%'||v_query||'%'))
 select(select count(*)from scope),coalesce((select jsonb_agg(to_jsonb(p)order by p.created_at desc,p.id)from(select * from scope order by created_at desc,id limit v_size offset(v_page-1)*v_size)p),'[]')into v_total,v_items;
 return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.update_sale_invoice_request_status(p_company_id uuid,p_request_id uuid,p_status text,p_reason text default null,p_cfdi_uuid text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_request public.sale_invoice_requests%rowtype;v_allowed boolean:=false;
begin
 if auth.uid()is null or not(public.is_super_admin() or public.has_company_permission(p_company_id,'manage_invoice_requests'))then raise exception 'No autorizado para atender solicitudes.';end if;
 select * into v_request from public.sale_invoice_requests where id=p_request_id and company_id=p_company_id for update;if not found then raise exception 'Solicitud no encontrada.';end if;
 v_allowed:=(v_request.status='pending_review'and p_status in('ready_to_issue','rejected','cancelled'))or(v_request.status='ready_to_issue'and p_status in('issued','rejected','cancelled'));
 if not v_allowed then raise exception 'El cambio de estado no está permitido.';end if;
 if p_status='rejected'and nullif(trim(coalesce(p_reason,'')),'')is null then raise exception 'Indica el motivo del rechazo.';end if;
 if p_status='issued'and nullif(trim(coalesce(p_cfdi_uuid,'')),'')is null then raise exception 'No se puede marcar como emitida sin UUID fiscal.';end if;
 update public.sale_invoice_requests set status=p_status,rejection_reason=case when p_status='rejected'then trim(p_reason)else null end,issued_cfdi_uuid=case when p_status='issued'then upper(trim(p_cfdi_uuid))else null end,updated_at=now()where id=p_request_id;
 insert into public.sale_invoice_request_history(company_id,request_id,from_status,to_status,reason,actor_id)values(p_company_id,p_request_id,v_request.status,p_status,nullif(trim(coalesce(p_reason,'')),''),auth.uid());
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'sale_invoice_request.status_changed','sale_invoice_requests',p_request_id,jsonb_build_object('from',v_request.status,'to',p_status,'reason',p_reason));
 return(select to_jsonb(r)from public.sale_invoice_requests r where r.id=p_request_id);
end $$;

alter table public.product_culinary_roles enable row level security;alter table public.sale_invoice_requests enable row level security;alter table public.sale_invoice_request_history enable row level security;
create policy product_culinary_roles_read on public.product_culinary_roles for select to authenticated using(public.has_company_permission(company_id,'view_products'));
create policy sale_invoice_requests_read on public.sale_invoice_requests for select to authenticated using(public.has_company_permission(company_id,'view_invoice_requests'));
create policy sale_invoice_request_history_read on public.sale_invoice_request_history for select to authenticated using(public.has_company_permission(company_id,'view_invoice_requests'));
revoke all on public.product_culinary_roles,public.sale_invoice_requests,public.sale_invoice_request_history from public,anon,authenticated;
revoke all on function public.set_product_culinary_role(uuid,uuid,text,text),public.save_sale_invoice_request(uuid,uuid,text,text,text,text,text,text,uuid),public.list_sale_invoice_requests(uuid,text,text,integer,integer),public.update_sale_invoice_request_status(uuid,uuid,text,text,text) from public,anon;
grant execute on function public.set_product_culinary_role(uuid,uuid,text,text),public.save_sale_invoice_request(uuid,uuid,text,text,text,text,text,text,uuid),public.list_sale_invoice_requests(uuid,text,text,integer,integer),public.update_sale_invoice_request_status(uuid,uuid,text,text,text) to authenticated;
