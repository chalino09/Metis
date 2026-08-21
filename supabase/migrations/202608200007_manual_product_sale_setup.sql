-- Alta manual asistida de productos listos para configuración de venta.
-- Producto, precio y pertenencia comercial permanecen separados en el dominio,
-- pero la captura puntual se confirma dentro de una sola transacción auditada.

begin;

create unique index if not exists audit_product_sale_setup_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='product.sale_setup_created' and metadata?'request_id';

create or replace function public.get_manual_product_sale_setup_context(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_lists jsonb;v_assortments jsonb;v_locations jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products')
    or not public.has_company_permission(p_company_id,'manage_prices')
    or not public.has_company_permission(p_company_id,'manage_assortments') then
    raise exception 'No autorizado para preparar productos para venta.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',price_list.id,'name',price_list.name,'currency_code',price_list.currency_code,
    'is_default',price_list.is_default or company.default_price_list_id=price_list.id
  ) order by (price_list.is_default or company.default_price_list_id=price_list.id) desc,price_list.name) filter(where price_list.id is not null),'[]'::jsonb)
  into v_lists
  from public.companies company
  left join public.price_lists price_list on price_list.company_id=company.id and price_list.is_active and price_list.status='active'
  where company.id=p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',assortment.id,'code',assortment.code,'name',assortment.name,
    'locations',coalesce((select jsonb_agg(jsonb_build_object('id',location.id,'code',location.external_code,'name',location.name) order by location.name)
      from public.location_sales_assortments assignment
      join public.locations location on location.id=assignment.location_id
      where assignment.assortment_id=assortment.id and assignment.valid_from<=now() and (assignment.valid_to is null or assignment.valid_to>now())
        and location.is_active and location.location_type='sucursal'),'[]'::jsonb)
  ) order by assortment.name),'[]'::jsonb)
  into v_assortments
  from public.sales_assortments assortment
  where assortment.company_id=p_company_id and assortment.status='active'
    and (assortment.valid_from is null or assortment.valid_from<=now()) and (assortment.valid_to is null or assortment.valid_to>now());

  select coalesce(jsonb_agg(jsonb_build_object('id',location.id,'code',location.external_code,'name',location.name) order by location.name),'[]'::jsonb)
  into v_locations
  from public.locations location
  where location.company_id=p_company_id and location.is_active and location.location_type='sucursal';

  return jsonb_build_object('price_lists',v_lists,'assortments',v_assortments,'locations',v_locations);
end $$;

create or replace function public.create_product_sale_setup(
  p_company_id uuid,p_name text,p_unit text,p_product_group text,p_barcode text,p_inventory_policy text,
  p_tax_category_id uuid,p_final_price numeric,p_price_list_id uuid,p_assortment_ids uuid[],p_client_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_product jsonb;v_list jsonb;v_price jsonb;v_result jsonb;v_replayed jsonb;v_readiness jsonb;
  v_product_id uuid;v_price_list_id uuid;v_assortment_ids uuid[]:=coalesce(p_assortment_ids,'{}'::uuid[]);
  v_assortment_id uuid;v_tax_rate numeric;v_base_price numeric;v_locations integer;v_created_default boolean:=false;v_reason text:='Alta manual desde el asistente de venta';
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products')
    or not public.has_company_permission(p_company_id,'manage_prices')
    or not public.has_company_permission(p_company_id,'manage_assortments') then
    raise exception 'No autorizado para preparar productos para venta.';
  end if;
  if p_client_request_id is null then raise exception 'Falta la referencia de la operación.';end if;
  if nullif(trim(p_name),'') is null then raise exception 'Escribe el nombre del producto.';end if;
  if nullif(trim(p_unit),'') is null then raise exception 'Indica la unidad de venta.';end if;
  if p_inventory_policy not in ('tracked','not_required') then raise exception 'Elige mercancía con inventario o servicio sin inventario.';end if;
  if p_tax_category_id is null then raise exception 'Selecciona el impuesto del producto.';end if;
  if p_final_price is null or p_final_price<=0 then raise exception 'Escribe un precio final mayor que cero.';end if;

  perform pg_advisory_xact_lock(hashtextextended('product-sale-setup:'||p_company_id::text||':'||p_client_request_id::text,0));
  select audit.metadata->'result' into v_replayed from public.audit_log audit
  where audit.company_id=p_company_id and audit.action='product.sale_setup_created'
    and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true);end if;

  select rate.rate into v_tax_rate from public.tax_rates rate
  join public.tax_categories category on category.id=rate.tax_category_id
  where category.id=p_tax_category_id and category.company_id=p_company_id and category.is_active
    and rate.jurisdiction_code='MX' and rate.valid_from<=now() and (rate.valid_to is null or rate.valid_to>now())
  order by rate.valid_from desc limit 1;
  if v_tax_rate is null then raise exception 'El impuesto seleccionado no tiene una tasa vigente.';end if;
  v_base_price:=round(p_final_price/(1+v_tax_rate),6);

  select price_list.id into v_price_list_id
  from public.price_lists price_list join public.companies company on company.id=price_list.company_id
  where price_list.company_id=p_company_id and price_list.is_active and price_list.status='active'
    and (p_price_list_id is null or price_list.id=p_price_list_id)
  order by (price_list.id=company.default_price_list_id) desc,price_list.is_default desc,price_list.name limit 1;
  if p_price_list_id is not null and v_price_list_id is null then raise exception 'La lista de precios seleccionada no está activa.';end if;
  if v_price_list_id is null then
    v_list:=public.save_price_list(p_company_id,null,'GENERAL','Precio general','MXN',true,true,v_reason,null,p_client_request_id);
    v_price_list_id:=(v_list->>'id')::uuid;
  end if;

  if cardinality(v_assortment_ids)=0 then
    select coalesce(array_agg(assortment.id order by assortment.name),'{}'::uuid[]) into v_assortment_ids
    from public.sales_assortments assortment
    where assortment.company_id=p_company_id and assortment.status='active'
      and (assortment.valid_from is null or assortment.valid_from<=now()) and (assortment.valid_to is null or assortment.valid_to>now());
  end if;
  if cardinality(v_assortment_ids)=0 then
    select count(*) into v_locations from public.locations location
    where location.company_id=p_company_id and location.is_active and location.location_type='sucursal';
    if v_locations=0 then raise exception 'Crea al menos una sucursal antes de ofrecer el producto.';end if;
    insert into public.sales_assortments(company_id,code,name,status,valid_from,created_by)
    values(p_company_id,public.next_company_internal_code(p_company_id,'SURTIDO','public.sales_assortments'::regclass,'code'),'Productos generales','draft',now(),auth.uid())
    returning id into v_assortment_id;
    insert into public.location_sales_assortments(location_id,assortment_id,valid_from,created_by)
    select location.id,v_assortment_id,now(),auth.uid() from public.locations location
    where location.company_id=p_company_id and location.is_active and location.location_type='sucursal';
    v_assortment_ids:=array[v_assortment_id];
    v_created_default:=true;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(p_company_id,auth.uid(),'sales_assortment.default_created','sales_assortments',v_assortment_id,jsonb_build_object('reason',v_reason,'locations',v_locations));
  elsif exists(
    select 1 from unnest(v_assortment_ids) requested(id)
    left join public.sales_assortments assortment on assortment.id=requested.id and assortment.company_id=p_company_id and assortment.status='active'
    where assortment.id is null
  ) then raise exception 'La selección contiene productos por sucursal inactivos o inválidos.';
  end if;

  v_product:=public.save_product(p_company_id,null::uuid,''::text,p_name,p_barcode,p_unit,p_product_group,p_inventory_policy='tracked',true,true,p_tax_category_id,v_reason,null::timestamptz,p_client_request_id);
  v_product_id:=(v_product->>'id')::uuid;
  v_price:=public.save_product_price(p_company_id,v_price_list_id,v_product_id,v_base_price,null,v_reason,p_client_request_id);
  perform public.set_product_sales_assortments(p_company_id,v_product_id,v_assortment_ids,v_reason);
  if v_created_default then
    update public.sales_assortments set status='active',updated_at=now() where id=v_assortment_id;
  end if;
  v_readiness:=public.product_pos_readiness_detail(p_company_id,v_product_id,v_price_list_id,clock_timestamp());
  v_result:=jsonb_build_object(
    'product_id',v_product_id,'product_code',v_product->>'internal_sku','product_name',v_product->>'name',
    'price_list_id',v_price_list_id,'base_price',v_base_price,'final_price',round(p_final_price,2),
    'currency_code',v_price->>'currency_code','assortment_ids',to_jsonb(v_assortment_ids),'readiness',v_readiness,'idempotent',false
  );
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'product.sale_setup_created','product',v_product_id,jsonb_build_object('request_id',p_client_request_id,'reason',v_reason,'result',v_result));
  return v_result;
end $$;

-- El listado administrativo devuelve un único diagnóstico que también incluye
-- la pertenencia comercial. La existencia continúa siendo un estado operativo
-- por sucursal y no modifica esta pertenencia.
create or replace function public.search_products(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,
  p_category_id uuid default null,p_is_active boolean default null,p_is_sellable boolean default null,
  p_inventory_tracked boolean default null,p_price_list_id uuid default null
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);
  v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;v_policy text;v_default_list uuid;v_list uuid;v_can_view_prices boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para consultar productos.';end if;
  v_can_view_prices:=public.has_company_permission(p_company_id,'view_prices');
  select default_price_policy,default_price_list_id into v_policy,v_default_list from public.companies where id=p_company_id;
  if v_can_view_prices then v_list:=coalesce(p_price_list_id,case when v_policy='specific_list' then v_default_list else null end);end if;
  with filtered as materialized(
    select product.*,case when v_q='' then 0 when lower(coalesce(product.barcode,''))=v_q then 1 when lower(product.alpha_sku)=v_q or lower(coalesce(product.internal_sku,''))=v_q then 2 when lower(product.alpha_sku) like v_q||'%' then 3 when exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||v_q||'%') then 4 else 5 end rank
    from public.products product where product.company_id=p_company_id and (p_category_id is null or product.category_id=p_category_id) and (p_is_active is null or product.is_active=p_is_active) and (p_is_sellable is null or product.is_sellable=p_is_sellable) and (p_inventory_tracked is null or product.is_inventory_tracked=p_inventory_tracked)
      and (v_q='' or lower(product.alpha_sku) like '%'||v_q||'%' or lower(coalesce(product.internal_sku,'')) like '%'||v_q||'%' or lower(coalesce(product.barcode,''))=v_q or lower(product.name) like '%'||v_q||'%' or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||v_q||'%'))
  ),paged as materialized(
    select * from filtered order by rank,name limit v_size offset (v_page-1)*v_size
  ),detailed as(
    select product.*,price.amount base_price_amount,price.currency_code,tax.rate tax_rate,coalesce(commercial.assortment_count,0) assortment_count,coalesce(commercial.offered_location_count,0) offered_location_count,array_remove(array[
      case when not product.is_active then 'inactive' end,case when not product.is_sellable then 'not_sellable' end,case when product.commercial_review_required then 'commercial_review_required' end,
      case when product.inventory_policy='unclassified' then 'inventory_setup_required' end,case when product.sales_unit_id is null then 'missing_sales_unit' end,case when product.tax_category_id is null then 'missing_tax_category' end,
      case when product.tax_category_id is not null and tax.rate is null then 'missing_current_tax_rate' end,case when coalesce(price.amount,0)<=0 then 'missing_or_zero_price' end,
      case when coalesce(commercial.offered_location_count,0)=0 then 'outside_assortment' end
    ]::text[],null) blockers
    from paged product
    left join lateral(select product_price.amount,product_price.currency_code from public.product_prices product_price where product_price.product_id=product.id and product_price.valid_from<=now() and (product_price.valid_to is null or product_price.valid_to>now()) and (v_list is null or product_price.price_list_id=v_list) order by case when v_list is null then product_price.amount end desc nulls last,product_price.valid_from desc limit 1) price on true
    left join lateral(select tax_rate.rate from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id and tax_rate.valid_from<=now() and (tax_rate.valid_to is null or tax_rate.valid_to>now()) order by tax_rate.valid_from desc limit 1) tax on true
    left join lateral(select count(distinct assortment.id)::integer assortment_count,count(distinct assignment.location_id)::integer offered_location_count from public.sales_assortment_items item join public.sales_assortments assortment on assortment.id=item.assortment_id left join public.location_sales_assortments assignment on assignment.assortment_id=assortment.id and assignment.valid_from<=now() and (assignment.valid_to is null or assignment.valid_to>now()) where item.product_id=product.id and assortment.company_id=p_company_id and assortment.status='active' and (assortment.valid_from is null or assortment.valid_from<=now()) and (assortment.valid_to is null or assortment.valid_to>now())) commercial on true
  )
  select (select count(*) from filtered),coalesce((select jsonb_agg(jsonb_build_object(
    'id',product.id,'alpha_sku',product.alpha_sku,'internal_sku',product.internal_sku,'barcode',product.barcode,'name',product.name,'unit',product.unit,'alpha_class',product.alpha_class,'product_group',product.product_group,'product_type',product.product_type,
    'inventory_policy',product.inventory_policy,'is_active',product.is_active,'is_sellable',product.is_sellable,'is_inventory_tracked',product.is_inventory_tracked,'category_id',product.category_id,'tax_category_id',product.tax_category_id,
    'base_price',case when v_can_view_prices then product.base_price_amount else null end,'price',case when v_can_view_prices and product.base_price_amount is not null and product.tax_rate is not null then round(product.base_price_amount*(1+product.tax_rate),2) else null end,
    'currency_code',case when v_can_view_prices then product.currency_code else null end,'assortment_count',product.assortment_count,'offered_location_count',product.offered_location_count,
    'blockers',to_jsonb(product.blockers),'warnings','[]'::jsonb,'pos_ready',cardinality(product.blockers)=0
  ) order by product.rank,product.name) from detailed product),'[]'::jsonb) into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_list,'price_policy',case when p_price_list_id is not null then 'selected_list' else v_policy end);
end $$;

revoke all on function public.get_manual_product_sale_setup_context(uuid),public.create_product_sale_setup(uuid,text,text,text,text,text,uuid,numeric,uuid,uuid[],uuid) from public,anon;
grant execute on function public.get_manual_product_sale_setup_context(uuid),public.create_product_sale_setup(uuid,text,text,text,text,text,uuid,numeric,uuid,uuid[],uuid) to authenticated;

notify pgrst,'reload schema';

commit;
