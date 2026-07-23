-- R-OP · Identidad canónica y administración server-side de productos.
-- Alpha conserva su código únicamente como referencia de importación. Toda
-- operación del dominio identifica al producto por products.id y expone
-- products.internal_sku como código canónico administrable de Satrapy.

begin;

-- Los productos existentes reciben un código canónico sin romper códigos ya
-- administrados. La segunda actualización cubre defensivamente cualquier
-- colisión histórica entre un código interno y un SKU de origen.
update public.products product
set internal_sku=upper(trim(product.alpha_sku))
where nullif(trim(product.internal_sku),'') is null
  and nullif(trim(product.alpha_sku),'') is not null
  and not exists(
    select 1 from public.products existing
    where existing.company_id=product.company_id
      and existing.id<>product.id
      and lower(trim(existing.internal_sku))=lower(trim(product.alpha_sku))
  );

update public.products
set internal_sku='SAT-'||upper(substr(replace(id::text,'-',''),1,12))
where nullif(trim(internal_sku),'') is null;

alter table public.products alter column internal_sku set not null;
alter table public.products alter column alpha_sku drop not null;
alter table public.products drop constraint if exists products_internal_sku_not_blank;
alter table public.products add constraint products_internal_sku_not_blank
  check(length(trim(internal_sku)) between 1 and 80);
alter table public.products drop constraint if exists products_alpha_sku_not_blank;
alter table public.products add constraint products_alpha_sku_not_blank
  check(alpha_sku is null or length(trim(alpha_sku))>0);

comment on column public.products.internal_sku is
  'Código canónico administrable de Satrapy; obligatorio e independiente del sistema de origen.';
comment on column public.products.alpha_sku is
  'Compatibilidad de importación Alpha. No es identidad de dominio y puede ser nulo.';

-- Las importaciones antiguas todavía insertan alpha_sku. Este trigger las
-- adapta en la frontera sin obligar a que el resto del dominio conozca Alpha.
create or replace function public.ensure_product_canonical_code()
returns trigger language plpgsql set search_path=public as $$
begin
  new.internal_sku:=upper(trim(coalesce(nullif(new.internal_sku,''),new.alpha_sku)));
  new.alpha_sku:=nullif(trim(new.alpha_sku),'');
  new.barcode:=nullif(trim(new.barcode),'');
  if nullif(new.internal_sku,'') is null then
    raise exception 'El código canónico del producto es obligatorio.';
  end if;
  return new;
end $$;

drop trigger if exists products_ensure_canonical_code on public.products;
create trigger products_ensure_canonical_code
before insert or update of internal_sku,alpha_sku,barcode on public.products
for each row execute function public.ensure_product_canonical_code();

-- updated_at funciona también como token de concurrencia y debe avanzar aunque
-- dos cambios ocurran dentro de la misma transacción.
create or replace function public.set_product_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end $$;
drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at before update on public.products
for each row execute function public.set_product_updated_at();

-- Mantiene la sincronización genérica de unidades, pero aplica las reglas de
-- clasificación Alpha sólo al importar o cuando realmente cambia esa clase.
create or replace function public.sync_product_commercial_fields()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_unit uuid;
  v_category uuid;
  v_type text:=lower(coalesce(new.product_type,''));
  v_apply_alpha_classification boolean:=new.alpha_sku is not null and (
    tg_op='INSERT'
    or old.product_type is distinct from new.product_type
    or old.alpha_class is distinct from new.alpha_class
  );
begin
  if nullif(trim(coalesce(new.unit,'')),'') is not null then
    insert into public.units_of_measure(company_id,code,name)
    values(new.company_id,trim(new.unit),trim(new.unit))
    on conflict(company_id,code) do update set name=excluded.name
    returning id into v_unit;
    if v_unit is null then
      select id into v_unit from public.units_of_measure
      where company_id=new.company_id and code=trim(new.unit);
    end if;
  end if;
  if nullif(trim(coalesce(new.alpha_class,'')),'') is not null then
    insert into public.product_categories(company_id,external_code,name)
    values(new.company_id,trim(new.alpha_class),trim(new.alpha_class))
    on conflict(company_id,external_code) do update set name=excluded.name
    returning id into v_category;
    if v_category is null then
      select id into v_category from public.product_categories
      where company_id=new.company_id and external_code=trim(new.alpha_class);
    end if;
  end if;

  update public.products set
    base_unit_id=coalesce(v_unit,base_unit_id),
    sales_unit_id=coalesce(v_unit,sales_unit_id),
    category_id=coalesce(v_category,category_id),
    is_active=case when v_apply_alpha_classification then v_type<>'eliminados' else is_active end,
    is_sellable=case when v_apply_alpha_classification then v_type in('p. terminado','servicios') else is_sellable end,
    is_inventory_tracked=case when v_apply_alpha_classification then v_type='p. terminado' else is_inventory_tracked end,
    commercial_review_required=case when v_apply_alpha_classification then v_type='activos' else commercial_review_required end
  where id=new.id;
  return new;
end $$;

create unique index if not exists audit_product_admin_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='product.admin_saved' and metadata?'request_id';

create or replace function public.save_product(
  p_company_id uuid,
  p_product_id uuid,
  p_internal_sku text,
  p_name text,
  p_barcode text,
  p_unit text,
  p_product_group text,
  p_is_inventory_tracked boolean,
  p_is_sellable boolean,
  p_is_active boolean,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_client_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_product public.products%rowtype;
  v_previous jsonb;
  v_replayed jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then
    raise exception 'No autorizado para administrar productos.';
  end if;
  if nullif(trim(p_internal_sku),'') is null or length(trim(p_internal_sku))>80 then
    raise exception 'El código canónico es obligatorio y admite hasta 80 caracteres.';
  end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>240 then
    raise exception 'El nombre es obligatorio y admite hasta 240 caracteres.';
  end if;
  if nullif(trim(p_barcode),'') is not null and length(trim(p_barcode))>80 then
    raise exception 'El código de barras admite hasta 80 caracteres.';
  end if;
  if nullif(trim(p_unit),'') is not null and length(trim(p_unit))>80 then
    raise exception 'La unidad admite hasta 80 caracteres.';
  end if;
  if nullif(trim(p_product_group),'') is not null and length(trim(p_product_group))>160 then
    raise exception 'El grupo admite hasta 160 caracteres.';
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));
  select to_jsonb(product) into v_replayed
  from public.audit_log audit
  join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id
  where audit.company_id=p_company_id and audit.action='product.admin_saved'
    and audit.metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_replayed is not null then
    return v_replayed||jsonb_build_object('idempotent',true);
  end if;

  if p_product_id is null then
    v_previous:=null;
    insert into public.products(
      company_id,internal_sku,alpha_sku,name,barcode,unit,product_group,
      is_inventory_tracked,is_sellable,is_active,commercial_review_required
    ) values(
      p_company_id,p_internal_sku,null,trim(p_name),nullif(trim(p_barcode),''),
      nullif(trim(p_unit),''),nullif(trim(p_product_group),''),
      coalesce(p_is_inventory_tracked,false),coalesce(p_is_sellable,false),
      coalesce(p_is_active,true),false
    ) returning * into v_product;
  else
    select * into v_product from public.products
    where id=p_product_id and company_id=p_company_id for update;
    if not found then raise exception 'El producto ya no está disponible.';end if;
    if p_expected_updated_at is null or v_product.updated_at<>p_expected_updated_at then
      raise exception 'El producto cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';
    end if;
    v_previous:=to_jsonb(v_product);
    update public.products set
      internal_sku=p_internal_sku,
      name=trim(p_name),
      barcode=nullif(trim(p_barcode),''),
      unit=nullif(trim(p_unit),''),
      product_group=nullif(trim(p_product_group),''),
      is_inventory_tracked=coalesce(p_is_inventory_tracked,false),
      is_sellable=coalesce(p_is_sellable,false),
      is_active=coalesce(p_is_active,true)
    where id=p_product_id returning * into v_product;
  end if;

  -- Los AFTER triggers pueden vincular la unidad y avanzar updated_at.
  select * into v_product from public.products where id=v_product.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'product.admin_saved','product',v_product.id,
    jsonb_build_object(
      'request_id',p_client_request_id,
      'reason',trim(p_reason),
      'origin',case when v_product.alpha_sku is null then 'manual' else 'canonical_with_import_reference' end,
      'previous',v_previous,
      'current',to_jsonb(v_product)
    ));
  return to_jsonb(v_product)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  if exists(select 1 from public.products where company_id=p_company_id
    and lower(internal_sku)=lower(trim(p_internal_sku)) and id is distinct from p_product_id) then
    raise exception 'Ya existe un producto con ese código canónico.';
  end if;
  if nullif(trim(p_barcode),'') is not null and exists(select 1 from public.products
    where company_id=p_company_id and barcode=trim(p_barcode) and id is distinct from p_product_id) then
    raise exception 'Ya existe un producto con ese código de barras.';
  end if;
  raise;
end $$;

revoke all on function public.ensure_product_canonical_code() from public,authenticated;
revoke all on function public.set_product_updated_at() from public,authenticated;
revoke all on function public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,text,timestamptz,uuid) from public;
grant execute on function public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,text,timestamptz,uuid) to authenticated;

commit;
