-- R-OP · Categorías fiscales canónicas administrables.
-- La captura manual atiende pocos tratamientos fiscales reutilizables; la
-- asignación de muchos productos conserva la operación masiva existente.

begin;

create unique index if not exists audit_tax_category_admin_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='tax_category.admin_saved' and metadata?'request_id';

create or replace function public.list_tax_categories_admin(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then
    raise exception 'No autorizado para administrar categorías fiscales.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id',category.id,'code',category.code,'name',category.name,
      'rate',rate.rate,'is_active',category.is_active) order by category.code)
    from public.tax_categories category
    left join lateral (
      select tax_rate.rate from public.tax_rates tax_rate
      where tax_rate.tax_category_id=category.id and tax_rate.jurisdiction_code='MX'
        and tax_rate.valid_from<=now() and (tax_rate.valid_to is null or tax_rate.valid_to>now())
      order by tax_rate.valid_from desc limit 1
    ) rate on true
    where category.company_id=p_company_id and category.is_active
  ),'[]'::jsonb);
end $$;

create or replace function public.save_tax_category(
  p_company_id uuid, p_code text, p_name text, p_rate numeric,
  p_reason text, p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_category public.tax_categories%rowtype; v_existing_rate numeric; v_replayed jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then
    raise exception 'No autorizado para administrar categorías fiscales.';
  end if;
  if nullif(trim(p_code),'') is null or length(trim(p_code))>40 then raise exception 'El código fiscal es obligatorio y admite hasta 40 caracteres.'; end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>120 then raise exception 'El nombre fiscal es obligatorio y admite hasta 120 caracteres.'; end if;
  if p_rate is null or p_rate<0 or p_rate>1 then raise exception 'La tasa debe estar entre 0 y 100%%.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.'; end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,1));
  select jsonb_build_object('id',category.id,'code',category.code,'name',category.name,'rate',rate.rate,'idempotent',true)
    into v_replayed
  from public.audit_log audit join public.tax_categories category on category.id=audit.entity_id
  left join lateral (select tax_rate.rate from public.tax_rates tax_rate where tax_rate.tax_category_id=category.id and tax_rate.valid_to is null order by tax_rate.valid_from desc limit 1) rate on true
  where audit.company_id=p_company_id and audit.action='tax_category.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed; end if;

  insert into public.tax_categories(company_id,code,name,is_active)
  values(p_company_id,upper(trim(p_code)),trim(p_name),true)
  on conflict(company_id,code) do update set name=excluded.name,is_active=true
  returning * into v_category;
  select rate into v_existing_rate from public.tax_rates where tax_category_id=v_category.id and jurisdiction_code='MX' and valid_to is null order by valid_from desc limit 1 for update;
  if v_existing_rate is null then
    insert into public.tax_rates(tax_category_id,jurisdiction_code,rate,valid_from,created_by)
    values(v_category.id,'MX',p_rate,clock_timestamp(),auth.uid());
  elsif v_existing_rate<>p_rate then
    update public.tax_rates set valid_to=clock_timestamp() where tax_category_id=v_category.id and jurisdiction_code='MX' and valid_to is null;
    insert into public.tax_rates(tax_category_id,jurisdiction_code,rate,valid_from,created_by)
    values(v_category.id,'MX',p_rate,clock_timestamp(),auth.uid());
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'tax_category.admin_saved','tax_category',v_category.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'rate',p_rate,'origin','manual'));
  return jsonb_build_object('id',v_category.id,'code',v_category.code,'name',v_category.name,'rate',p_rate,'idempotent',false);
end $$;

-- Sustituye el RPC manual de producto para que la captura e importación usen
-- el mismo products.tax_category_id canónico.
drop function if exists public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,text,timestamptz,uuid);
create or replace function public.save_product(
  p_company_id uuid, p_product_id uuid, p_internal_sku text, p_name text,
  p_barcode text, p_unit text, p_product_group text, p_is_inventory_tracked boolean,
  p_is_sellable boolean, p_is_active boolean, p_tax_category_id uuid, p_reason text,
  p_expected_updated_at timestamptz, p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype; v_previous jsonb; v_replayed jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para administrar productos.'; end if;
  if nullif(trim(p_internal_sku),'') is null or length(trim(p_internal_sku))>80 then raise exception 'El código canónico es obligatorio y admite hasta 80 caracteres.'; end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>240 then raise exception 'El nombre es obligatorio y admite hasta 240 caracteres.'; end if;
  if nullif(trim(p_barcode),'') is not null and length(trim(p_barcode))>80 then raise exception 'El código de barras admite hasta 80 caracteres.'; end if;
  if nullif(trim(p_unit),'') is not null and length(trim(p_unit))>80 then raise exception 'La unidad admite hasta 80 caracteres.'; end if;
  if nullif(trim(p_product_group),'') is not null and length(trim(p_product_group))>160 then raise exception 'El grupo admite hasta 160 caracteres.'; end if;
  if p_tax_category_id is not null and not exists(select 1 from public.tax_categories where id=p_tax_category_id and company_id=p_company_id and is_active) then raise exception 'La categoría fiscal no pertenece a esta empresa o está inactiva.'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.'; end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));
  select to_jsonb(product) into v_replayed from public.audit_log audit join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id where audit.company_id=p_company_id and audit.action='product.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true); end if;
  if p_product_id is null then
    v_previous:=null;
    insert into public.products(company_id,internal_sku,alpha_sku,name,barcode,unit,product_group,is_inventory_tracked,is_sellable,is_active,commercial_review_required,tax_category_id)
    values(p_company_id,p_internal_sku,null,trim(p_name),nullif(trim(p_barcode),''),nullif(trim(p_unit),''),nullif(trim(p_product_group),''),coalesce(p_is_inventory_tracked,false),coalesce(p_is_sellable,false),coalesce(p_is_active,true),false,p_tax_category_id) returning * into v_product;
  else
    select * into v_product from public.products where id=p_product_id and company_id=p_company_id for update;
    if not found then raise exception 'El producto ya no está disponible.'; end if;
    if p_expected_updated_at is null or v_product.updated_at<>p_expected_updated_at then raise exception 'El producto cambió mientras lo editabas. Actualiza y vuelve a intentarlo.'; end if;
    v_previous:=to_jsonb(v_product);
    update public.products set internal_sku=p_internal_sku,name=trim(p_name),barcode=nullif(trim(p_barcode),''),unit=nullif(trim(p_unit),''),product_group=nullif(trim(p_product_group),''),is_inventory_tracked=coalesce(p_is_inventory_tracked,false),is_sellable=coalesce(p_is_sellable,false),is_active=coalesce(p_is_active,true),tax_category_id=p_tax_category_id where id=p_product_id returning * into v_product;
  end if;
  select * into v_product from public.products where id=v_product.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'product.admin_saved','product',v_product.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'origin',case when v_product.alpha_sku is null then 'manual' else 'canonical_with_import_reference' end,'previous',v_previous,'current',to_jsonb(v_product)));
  return to_jsonb(v_product)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  if exists(select 1 from public.products where company_id=p_company_id and lower(internal_sku)=lower(trim(p_internal_sku)) and id is distinct from p_product_id) then raise exception 'Ya existe un producto con ese código canónico.'; end if;
  if nullif(trim(p_barcode),'') is not null and exists(select 1 from public.products where company_id=p_company_id and barcode=trim(p_barcode) and id is distinct from p_product_id) then raise exception 'Ya existe un producto con ese código de barras.'; end if;
  raise;
end $$;

-- Compatibilidad para clientes desplegados antes de esta mejora: pueden seguir
-- creando el producto y completar el impuesto después, sin depender de Alpha.
create or replace function public.save_product(
  p_company_id uuid, p_product_id uuid, p_internal_sku text, p_name text,
  p_barcode text, p_unit text, p_product_group text, p_is_inventory_tracked boolean,
  p_is_sellable boolean, p_is_active boolean, p_reason text,
  p_expected_updated_at timestamptz, p_client_request_id uuid
) returns jsonb language sql security definer set search_path=public as $$
  select public.save_product(p_company_id,p_product_id,p_internal_sku,p_name,p_barcode,p_unit,p_product_group,p_is_inventory_tracked,p_is_sellable,p_is_active,null,p_reason,p_expected_updated_at,p_client_request_id);
$$;

grant execute on function public.list_tax_categories_admin(uuid) to authenticated;
grant execute on function public.save_tax_category(uuid,text,text,numeric,text,uuid) to authenticated;
grant execute on function public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,uuid,text,timestamptz,uuid) to authenticated;
grant execute on function public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,text,timestamptz,uuid) to authenticated;

commit;
