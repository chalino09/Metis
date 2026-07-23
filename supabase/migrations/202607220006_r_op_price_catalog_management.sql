-- R-OP · Listas y precios canónicos administrables.
-- La captura manual y la importación convergen en price_lists/product_prices;
-- las vigencias anteriores nunca se sobrescriben.

begin;

alter table public.price_lists add column if not exists internal_code text;
update public.price_lists set internal_code=upper(trim(external_code)) where nullif(trim(internal_code),'') is null;
alter table public.price_lists alter column internal_code set not null;
alter table public.price_lists alter column external_code drop not null;
alter table public.price_lists drop constraint if exists price_lists_internal_code_not_blank;
alter table public.price_lists add constraint price_lists_internal_code_not_blank check(length(trim(internal_code)) between 1 and 80);
create unique index if not exists price_lists_company_internal_code_key on public.price_lists(company_id,lower(internal_code));

comment on column public.price_lists.internal_code is 'Código canónico administrable de Satrapy.';
comment on column public.price_lists.external_code is 'Referencia de importación; puede ser nula para listas creadas en Satrapy.';

create or replace function public.ensure_price_list_canonical_code()
returns trigger language plpgsql set search_path=public as $$
begin
  new.internal_code:=upper(trim(coalesce(nullif(new.internal_code,''),new.external_code)));
  new.external_code:=nullif(trim(new.external_code),'');
  new.currency_code:=upper(trim(new.currency_code));
  if nullif(new.internal_code,'') is null then raise exception 'El código canónico de la lista es obligatorio.';end if;
  return new;
end $$;
drop trigger if exists price_lists_ensure_canonical_code on public.price_lists;
create trigger price_lists_ensure_canonical_code before insert or update of internal_code,external_code,currency_code on public.price_lists for each row execute function public.ensure_price_list_canonical_code();

create unique index if not exists audit_price_list_admin_request_uidx on public.audit_log(company_id,(metadata->>'request_id')) where action='price_list.admin_saved' and metadata?'request_id';
create unique index if not exists audit_price_admin_request_uidx on public.audit_log(company_id,(metadata->>'request_id')) where action='price.admin_saved' and metadata?'request_id';

create or replace function public.list_price_lists_admin(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_prices') then raise exception 'No autorizado para consultar precios.';end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',list.id,'internal_code',list.internal_code,'external_code',list.external_code,'name',list.name,
    'currency_code',list.currency_code,'is_active',list.is_active,'is_default',list.is_default,
    'source',list.source,'updated_at',list.updated_at,
    'current_price_count',(select count(*) from public.product_prices price where price.price_list_id=list.id and price.amount>0 and price.valid_from<=now() and (price.valid_to is null or price.valid_to>now()))
  ) order by list.is_default desc,list.name) from public.price_lists list where list.company_id=p_company_id),'[]'::jsonb);
end $$;

create or replace function public.search_price_list_products(p_company_id uuid,p_price_list_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_prices') then raise exception 'No autorizado para consultar precios.';end if;
  if not exists(select 1 from public.price_lists where id=p_price_list_id and company_id=p_company_id) then raise exception 'Lista de precios no encontrada.';end if;
  select count(*) into v_total from public.products product where product.company_id=p_company_id and (v_query='' or lower(product.internal_sku) like '%'||v_query||'%' or lower(product.name) like '%'||v_query||'%' or lower(coalesce(product.barcode,''))=v_query);
  with page_rows as (
    select product.* from public.products product where product.company_id=p_company_id and (v_query='' or lower(product.internal_sku) like '%'||v_query||'%' or lower(product.name) like '%'||v_query||'%' or lower(coalesce(product.barcode,''))=v_query)
    order by product.name,product.id limit v_size offset (v_page-1)*v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object('product_id',product.id,'internal_sku',product.internal_sku,'name',product.name,'unit',product.unit,'is_active',product.is_active,
    'amount',current_price.amount,'valid_from',current_price.valid_from,'valid_to',current_price.valid_to,
    'next_amount',next_price.amount,'next_valid_from',next_price.valid_from) order by product.name,product.id),'[]'::jsonb) into v_items
  from page_rows product
  left join lateral(select price.amount,price.valid_from,price.valid_to from public.product_prices price where price.product_id=product.id and price.price_list_id=p_price_list_id and price.valid_from<=now() and (price.valid_to is null or price.valid_to>now()) order by price.valid_from desc limit 1) current_price on true
  left join lateral(select price.amount,price.valid_from from public.product_prices price where price.product_id=product.id and price.price_list_id=p_price_list_id and price.valid_from>now() order by price.valid_from limit 1) next_price on true;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.save_price_list(p_company_id uuid,p_price_list_id uuid,p_internal_code text,p_name text,p_currency_code text,p_is_active boolean,p_is_default boolean,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_list public.price_lists%rowtype;v_previous jsonb;v_replayed jsonb;v_default boolean:=coalesce(p_is_default,false) and coalesce(p_is_active,true);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_prices') then raise exception 'No autorizado para administrar precios.';end if;
  if nullif(trim(p_internal_code),'') is null or length(trim(p_internal_code))>80 then raise exception 'El código es obligatorio y admite hasta 80 caracteres.';end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>160 then raise exception 'El nombre es obligatorio y admite hasta 160 caracteres.';end if;
  if upper(trim(coalesce(p_currency_code,''))) !~ '^[A-Z]{3}$' then raise exception 'La moneda debe usar un código ISO de tres letras.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended('price-list:'||p_company_id::text,0));
  select to_jsonb(list) into v_replayed from public.audit_log audit join public.price_lists list on list.id=audit.entity_id where audit.company_id=p_company_id and audit.action='price_list.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true);end if;
  if p_price_list_id is null then
    v_previous:=null;
    insert into public.price_lists(company_id,internal_code,external_code,name,currency_code,is_active,semantic_code,status,source,is_default,reviewed_at,reviewed_by)
    values(p_company_id,p_internal_code,null,trim(p_name),p_currency_code,coalesce(p_is_active,true),null,case when coalesce(p_is_active,true) then 'active' else 'inactive' end,'manual',v_default,now(),auth.uid()) returning * into v_list;
  else
    select * into v_list from public.price_lists where id=p_price_list_id and company_id=p_company_id for update;
    if not found then raise exception 'La lista ya no está disponible.';end if;
    if p_expected_updated_at is null or v_list.updated_at<>p_expected_updated_at then raise exception 'La lista cambió mientras la editabas. Actualiza y vuelve a intentarlo.';end if;
    v_previous:=to_jsonb(v_list);
    update public.price_lists set internal_code=p_internal_code,name=trim(p_name),currency_code=p_currency_code,is_active=coalesce(p_is_active,true),status=case when coalesce(p_is_active,true) then 'active' else 'inactive' end,is_default=v_default,reviewed_at=now(),reviewed_by=auth.uid() where id=p_price_list_id returning * into v_list;
  end if;
  if v_default then
    update public.price_lists set is_default=false where company_id=p_company_id and id<>v_list.id and is_default;
    update public.companies set default_price_policy='specific_list',default_price_list_id=v_list.id where id=p_company_id;
  elsif (select default_price_list_id from public.companies where id=p_company_id)=v_list.id then
    update public.companies set default_price_policy='highest_available',default_price_list_id=null where id=p_company_id;
  end if;
  select * into v_list from public.price_lists where id=v_list.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'price_list.admin_saved','price_list',v_list.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'origin',case when v_list.external_code is null then 'manual' else 'canonical_with_import_reference' end,'previous',v_previous,'current',to_jsonb(v_list)));
  return to_jsonb(v_list)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  if exists(select 1 from public.price_lists where company_id=p_company_id and lower(internal_code)=lower(trim(p_internal_code)) and id is distinct from p_price_list_id) then raise exception 'Ya existe una lista con ese código.';end if;
  raise;
end $$;

create or replace function public.save_product_price(p_company_id uuid,p_price_list_id uuid,p_product_id uuid,p_amount numeric,p_effective_from timestamptz,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_list public.price_lists%rowtype;v_previous public.product_prices%rowtype;v_price public.product_prices%rowtype;v_effective timestamptz:=coalesce(p_effective_from,clock_timestamp());v_replayed jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_prices') then raise exception 'No autorizado para administrar precios.';end if;
  if p_amount is null or p_amount<=0 or p_amount>999999999999 then raise exception 'El precio debe ser mayor que cero.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended('price:'||p_price_list_id::text||':'||p_product_id::text,0));
  select jsonb_build_object('id',price.id,'product_id',price.product_id,'price_list_id',price.price_list_id,'amount',price.amount,'currency_code',price.currency_code,'valid_from',price.valid_from,'valid_to',price.valid_to,'idempotent',true) into v_replayed from public.audit_log audit join public.product_prices price on price.id=audit.entity_id where audit.company_id=p_company_id and audit.action='price.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed;end if;
  select * into v_list from public.price_lists where id=p_price_list_id and company_id=p_company_id and is_active and status='active';
  if not found then raise exception 'La lista de precios no está activa.';end if;
  if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id) then raise exception 'Producto no encontrado.';end if;
  if v_effective<clock_timestamp()-interval '1 minute' then raise exception 'La vigencia no puede iniciar en el pasado.';end if;
  select * into v_previous from public.product_prices where product_id=p_product_id and price_list_id=p_price_list_id and valid_to is null order by valid_from desc limit 1 for update;
  if found then
    if v_effective<=v_previous.valid_from then raise exception 'La nueva vigencia debe ser posterior a la última registrada.';end if;
    update public.product_prices set valid_to=v_effective where id=v_previous.id;
  end if;
  insert into public.product_prices(product_id,price_list_id,amount,currency_code,valid_from,source_file_name,import_batch_id,created_by) values(p_product_id,p_price_list_id,round(p_amount,6),v_list.currency_code,v_effective,null,null,auth.uid()) returning * into v_price;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'price.admin_saved','product_price',v_price.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'origin','manual','previous',case when v_previous.id is null then null else to_jsonb(v_previous) end,'current',to_jsonb(v_price)));
  return to_jsonb(v_price)||jsonb_build_object('idempotent',false);
end $$;

revoke all on function public.ensure_price_list_canonical_code() from public,authenticated;
revoke all on function public.list_price_lists_admin(uuid),public.search_price_list_products(uuid,uuid,text,integer,integer),public.save_price_list(uuid,uuid,text,text,text,boolean,boolean,text,timestamptz,uuid),public.save_product_price(uuid,uuid,uuid,numeric,timestamptz,text,uuid) from public;
grant execute on function public.list_price_lists_admin(uuid),public.search_price_list_products(uuid,uuid,text,integer,integer),public.save_price_list(uuid,uuid,text,text,text,boolean,boolean,text,timestamptz,uuid),public.save_product_price(uuid,uuid,uuid,numeric,timestamptz,text,uuid) to authenticated;

commit;
