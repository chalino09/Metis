-- Restaurante: el precio de venta y la existencia siguen bloqueando el POS.
-- El costo pendiente de un ingrediente afecta margen y análisis, no la venta.

alter table public.culinary_sale_item_snapshots
  alter column recognized_unit_cost drop not null,
  alter column recognized_cost_amount drop not null;

alter table public.culinary_sale_item_snapshots
  drop constraint if exists culinary_sale_item_snapshots_cost_complete,
  add constraint culinary_sale_item_snapshots_cost_complete check (
    (recognized_unit_cost is null and recognized_cost_amount is null)
    or (recognized_unit_cost is not null and recognized_cost_amount is not null)
  );

alter table public.culinary_sale_consumptions
  alter column product_cost_id drop not null,
  alter column recognized_unit_cost drop not null,
  alter column recognized_cost_amount drop not null;

alter table public.culinary_sale_consumptions
  drop constraint if exists culinary_sale_consumptions_cost_complete,
  add constraint culinary_sale_consumptions_cost_complete check (
    (product_cost_id is null and recognized_unit_cost is null and recognized_cost_amount is null)
    or (product_cost_id is not null and recognized_unit_cost is not null and recognized_cost_amount is not null)
  );

alter table public.sale_items drop constraint if exists sale_items_recognized_cost_complete;
alter table public.sale_items add constraint sale_items_recognized_cost_complete check (
  (
    recognized_unit_cost is null
    and recognized_cost_method is null
    and recognized_cost_currency_code is null
    and recognized_product_cost_id is null
    and recognized_cost_correction_id is null
  )
  or (
    recognized_unit_cost is not null
    and recognized_unit_cost >= 0
    and recognized_cost_method in ('replacement_cost','standard_cost','average_cost')
    and recognized_cost_currency_code ~ '^[A-Z]{3}$'
    and num_nonnulls(recognized_product_cost_id,recognized_cost_correction_id,recognized_culinary_snapshot_id)=1
  )
);

create or replace function public.culinary_pos_readiness(
  p_company_id uuid,
  p_location_id uuid,
  p_product_id uuid,
  p_quantity numeric default 1,
  p_at timestamptz default now(),
  p_currency_code text default 'MXN'
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_cost jsonb;
  v_cost_warnings jsonb:='[]'::jsonb;
  v_missing jsonb;
  v_conversion_missing jsonb;
  v_version uuid;
begin
  if p_quantity is null or p_quantity<=0 then raise exception 'La cantidad debe ser mayor que cero.';end if;
  select rv.id into v_version
  from public.culinary_recipes r
  join public.culinary_recipe_versions rv on rv.recipe_id=r.id
  where r.company_id=p_company_id and r.product_id=p_product_id
    and rv.status='active' and rv.valid_from<=p_at and(rv.valid_to is null or rv.valid_to>p_at);
  if v_version is null then
    return jsonb_build_object('allowed',false,'blockers',jsonb_build_array(jsonb_build_object('code','missing_active_recipe','message','Agrega y activa una receta.')),'warnings','[]'::jsonb);
  end if;

  begin
    v_cost:=public.culinary_version_cost(v_version,p_quantity,p_at,p_currency_code);
  exception when others then
    return jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_recipe_conversion','message',sqlerrm)),'warnings','[]'::jsonb);
  end;

  if not coalesce((v_cost->>'allowed')::boolean,false) then
    if v_cost#>>'{blockers,0,code}'='missing_component_cost' then
      v_cost_warnings:=coalesce(v_cost->'blockers','[]'::jsonb);
    else
      return v_cost||jsonb_build_object('recipe_version_id',v_version,'warnings','[]'::jsonb);
    end if;
  end if;

  with needed as(select*from public.expand_culinary_recipe(v_version,p_quantity))
  select jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.name)order by p.name)
  into v_conversion_missing
  from needed n
  join public.products p on p.id=n.ingredient_product_id
  left join public.product_purchase_units u on u.product_id=p.id
  where p.is_inventory_tracked and(p.base_unit_id is null or u.product_id is null or u.base_units_per_purchase_unit<=0);
  if v_conversion_missing is not null then
    return v_cost||jsonb_build_object(
      'allowed',false,'recipe_version_id',v_version,'warnings',v_cost_warnings,
      'blockers',jsonb_build_array(jsonb_build_object('code','missing_purchase_conversion','message','Configura la unidad de compra y su equivalencia para los ingredientes indicados.','ingredients',v_conversion_missing))
    );
  end if;

  with needed as(select * from public.expand_culinary_recipe(v_version,p_quantity)),short as(
    select n.ingredient_product_id,p.name,n.quantity,coalesce(b.quantity_on_hand,0) available
    from needed n
    join public.products p on p.id=n.ingredient_product_id
    left join public.inventory_balances b on b.company_id=p_company_id and b.location_id=p_location_id and b.product_id=n.ingredient_product_id
    where coalesce(b.quantity_on_hand,0)<n.quantity
  )
  select jsonb_agg(jsonb_build_object('product_id',ingredient_product_id,'product_name',name,'required',quantity,'available',available)order by name)
  into v_missing from short;
  if v_missing is not null then
    return v_cost||jsonb_build_object(
      'allowed',false,'recipe_version_id',v_version,'warnings',v_cost_warnings,
      'blockers',jsonb_build_array(jsonb_build_object('code','insufficient_ingredient_stock','message','No hay existencia suficiente de los ingredientes de la receta.','ingredients',v_missing))
    );
  end if;

  return v_cost||jsonb_build_object('allowed',true,'recipe_version_id',v_version,'blockers','[]'::jsonb,'warnings',v_cost_warnings);
end$$;

create or replace function public.prepare_culinary_sale_item_cost()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_sale public.sales%rowtype;
  v_version uuid;
  v_cost jsonb;
  v_method text;
  v_total numeric;
  v_missing_cost boolean;
begin
  select * into v_sale from public.sales where id=new.sale_id;
  select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
  where r.company_id=v_sale.company_id and r.product_id=new.product_id and rv.status='active' and rv.valid_from<=v_sale.completed_at and(rv.valid_to is null or rv.valid_to>v_sale.completed_at);
  if v_version is null then return new;end if;
  if exists(select 1 from public.products where id=new.product_id and is_inventory_tracked) then raise exception 'El platillo % no puede descontarse como producto y receta al mismo tiempo.',new.product_name;end if;
  v_cost:=public.get_culinary_recipe_cost(v_sale.company_id,new.product_id,new.quantity,v_sale.completed_at,v_sale.currency_code);
  v_missing_cost:=not coalesce((v_cost->>'allowed')::boolean,false) and v_cost#>>'{blockers,0,code}'='missing_component_cost';
  if not coalesce((v_cost->>'allowed')::boolean,false) and not v_missing_cost then raise exception 'El platillo % no está listo: %',new.product_name,v_cost->'blockers';end if;
  new.recognized_product_cost_id:=null;
  new.recognized_cost_correction_id:=null;
  new.recognized_culinary_snapshot_id:=gen_random_uuid();
  if v_missing_cost then
    new.recognized_unit_cost:=null;
    new.recognized_cost_method:=null;
    new.recognized_cost_currency_code:=null;
  else
    v_total:=(v_cost->>'total_cost')::numeric;
    select coalesce(cost_method,'replacement_cost') into v_method from public.accounting_event_rule_sets where company_id=v_sale.company_id and status='approved';
    v_method:=coalesce(v_method,'replacement_cost');
    new.recognized_unit_cost:=round(v_total/new.quantity,6);
    new.recognized_cost_method:=v_method;
    new.recognized_cost_currency_code:=v_sale.currency_code;
  end if;
  return new;
end$$;

create or replace function public.consume_culinary_sale_item()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_sale public.sales%rowtype;
  v_version uuid;
  v_cost jsonb;
  v_component record;
  v_snapshot uuid;
  v_consumption uuid;
  v_balance numeric;
  v_total numeric;
  v_missing_cost boolean;
begin
  select * into v_sale from public.sales where id=new.sale_id;
  select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
  where r.company_id=v_sale.company_id and r.product_id=new.product_id and rv.status='active' and rv.valid_from<=v_sale.completed_at and(rv.valid_to is null or rv.valid_to>v_sale.completed_at);
  if v_version is null then return new;end if;
  v_cost:=public.get_culinary_recipe_cost(v_sale.company_id,new.product_id,new.quantity,v_sale.completed_at,v_sale.currency_code);
  v_missing_cost:=not coalesce((v_cost->>'allowed')::boolean,false) and v_cost#>>'{blockers,0,code}'='missing_component_cost';
  if not coalesce((v_cost->>'allowed')::boolean,false) and not v_missing_cost then raise exception 'El platillo % no está listo: %',new.product_name,v_cost->'blockers';end if;
  v_total:=case when v_missing_cost then null else (v_cost->>'total_cost')::numeric end;
  v_snapshot:=new.recognized_culinary_snapshot_id;
  insert into public.culinary_sale_item_snapshots(id,company_id,sale_item_id,root_recipe_version_id,recognized_unit_cost,recognized_cost_amount,currency_code)
  values(v_snapshot,v_sale.company_id,new.id,v_version,new.recognized_unit_cost,v_total,v_sale.currency_code);
  with recursive versions(id,depth,path)as(
    select v_version,0,array[v_version]::uuid[] union all
    select child.id,v.depth+1,v.path||child.id from versions v join public.culinary_recipe_components c on c.recipe_version_id=v.id
    join public.culinary_recipes r on r.product_id=c.component_product_id and r.company_id=v_sale.company_id join public.culinary_recipe_versions child on child.recipe_id=r.id and child.status='active'
    where v.depth<32 and not child.id=any(v.path))
  insert into public.culinary_sale_item_recipe_versions(snapshot_id,recipe_version_id,depth) select v_snapshot,id,min(depth) from versions group by id;
  for v_component in select * from jsonb_to_recordset(v_cost->'components')as x(product_id uuid,base_unit_code text,quantity numeric,product_cost_id uuid,unit_cost numeric,cost_amount numeric) order by product_id loop
    select quantity_on_hand into v_balance from public.inventory_balances where company_id=v_sale.company_id and location_id=v_sale.location_id and product_id=v_component.product_id for update;
    if coalesce(v_balance,0)<v_component.quantity then raise exception 'Existencia insuficiente para el ingrediente %.',(select name from public.products where id=v_component.product_id);end if;
    update public.inventory_balances set quantity_on_hand=quantity_on_hand-v_component.quantity,updated_at=now()
    where company_id=v_sale.company_id and location_id=v_sale.location_id and product_id=v_component.product_id returning quantity_on_hand into v_balance;
    insert into public.culinary_sale_consumptions(company_id,snapshot_id,ingredient_product_id,base_unit_code,quantity,product_cost_id,recognized_unit_cost,recognized_cost_amount)
    values(v_sale.company_id,v_snapshot,v_component.product_id,v_component.base_unit_code,v_component.quantity,v_component.product_cost_id,v_component.unit_cost,v_component.cost_amount) returning id into v_consumption;
    insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,culinary_consumption_id,actor_id)
    values(v_sale.company_id,v_sale.location_id,v_component.product_id,-v_component.quantity,v_balance,'culinary_sale',v_consumption,auth.uid());
  end loop;
  return new;
end$$;

create or replace function public.change_sale_cart_item(
  p_cart_id uuid,p_product_id uuid,p_quantity_delta numeric,p_expected_revision integer
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_cart public.sale_carts%rowtype;
  v_quantity numeric;
  v_new_revision integer;
  v_product public.products%rowtype;
  v_balance numeric;
  v_validation jsonb;
  v_message text;
begin
  if coalesce(p_quantity_delta,0)=0 then raise exception 'El cambio de cantidad no puede ser cero.';end if;
  select * into v_cart from public.sale_carts where id=p_cart_id for update;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  if v_cart.revision<>p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.';end if;
  select * into v_product from public.products where id=p_product_id and company_id=v_cart.company_id;
  if not found then raise exception 'Producto no encontrado.';end if;
  v_validation:=public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,p_product_id);
  if not coalesce((v_validation->>'allowed')::boolean,false) then
    v_message:=coalesce(v_validation#>>'{culinary_readiness,blockers,0,message}','El producto ya no está disponible para POS.');
    raise exception '%',v_message;
  end if;
  select quantity into v_quantity from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id;
  v_quantity:=coalesce(v_quantity,0)+p_quantity_delta;
  if v_quantity<0 then raise exception 'La cantidad no puede ser negativa.';end if;
  if v_product.is_inventory_tracked then
    select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_cart.location_id and product_id=p_product_id;
    if coalesce(v_balance,0)<v_quantity then raise exception 'No hay existencia disponible para esa cantidad.';end if;
  end if;
  if v_quantity=0 then delete from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id;
  elsif exists(select 1 from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id) then update public.sale_cart_items set quantity=v_quantity where cart_id=p_cart_id and product_id=p_product_id;
  else insert into public.sale_cart_items(cart_id,product_id,quantity)values(p_cart_id,p_product_id,v_quantity);end if;
  update public.sale_carts set revision=revision+1 where id=p_cart_id returning revision into v_new_revision;
  return jsonb_build_object('cart_id',p_cart_id,'revision',v_new_revision);
end$$;

create or replace function public.search_pos_cart_products(
  p_cart_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_cart public.sale_carts%rowtype;v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g')));v_total integer;v_items jsonb;v_price_list_id uuid;v_currency_code text;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  select coalesce(v_cart.price_list_id,customer.price_list_id,location.default_price_list_id,company.default_price_list_id)
  into v_price_list_id from public.companies company join public.locations location on location.id=v_cart.location_id and location.company_id=company.id
  left join public.customers customer on customer.id=v_cart.customer_id and customer.company_id=company.id where company.id=v_cart.company_id;
  select list.currency_code into v_currency_code from public.price_lists list where list.id=v_price_list_id and list.company_id=v_cart.company_id and list.is_active and list.status='active';
  if v_currency_code is null then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);end if;
  with candidate_ids as materialized(
    select distinct item.product_id from public.location_sales_assortments assignment
    join public.sales_assortments assortment on assortment.id=assignment.assortment_id
    join public.sales_assortment_items item on item.assortment_id=assortment.id
    where assignment.location_id=v_cart.location_id and assignment.valid_from<=p_at and(assignment.valid_to is null or assignment.valid_to>p_at)
      and assortment.company_id=v_cart.company_id and assortment.status='active' and(assortment.valid_from is null or assortment.valid_from<=p_at)and(assortment.valid_to is null or assortment.valid_to>p_at)
  ),matched as materialized(
    select product.*,case when v_query='' then 9 when lower(coalesce(product.barcode,''))=v_query then 1 when lower(coalesce(product.internal_sku,''))=v_query then 2
      when lower(coalesce(product.internal_sku,''))like v_query||'%' then 3 when exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code)=v_query)then 4 else 5 end rank
    from candidate_ids candidate join public.products product on product.id=candidate.product_id
    where product.company_id=v_cart.company_id and(v_query='' or not exists(select 1 from regexp_split_to_table(v_query,'\s+')token where token<>'' and not(
      lower(product.name)like'%'||token||'%' or lower(coalesce(product.internal_sku,''))like'%'||token||'%' or lower(coalesce(product.barcode,''))=token
      or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like'%'||token||'%')
      or exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code)like'%'||token||'%')
    )))
  ),eligible as materialized(
    select product.id,product.name,product.internal_sku,product.barcode,product.unit,product.is_inventory_tracked,coalesce(balance.quantity_on_hand,0)quantity_on_hand,
      price.amount base_price_amount,tax.rate tax_rate,round(price.amount*tax.rate,2)tax_amount,round(price.amount*(1+tax.rate),2)price_amount,product.rank
    from matched product
    left join public.inventory_balances balance on balance.location_id=v_cart.location_id and balance.product_id=product.id
    left join lateral(select product_price.amount from public.product_prices product_price where product_price.product_id=product.id and product_price.price_list_id=v_price_list_id
      and product_price.currency_code=v_currency_code and product_price.valid_from<=p_at and(product_price.valid_to is null or product_price.valid_to>p_at)order by product_price.valid_from desc limit 1)price on true
    left join lateral(select tax_rate.rate from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id and tax_rate.valid_from<=p_at
      and(tax_rate.valid_to is null or tax_rate.valid_to>p_at)order by tax_rate.valid_from desc limit 1)tax on true
    cross join lateral(select public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,product.id,p_at) result)validation
    where product.is_active and product.is_sellable and not product.commercial_review_required and product.inventory_policy<>'unclassified'
      and product.sales_unit_id is not null and product.tax_category_id is not null and tax.rate is not null and coalesce(price.amount,0)>0
      and(not product.is_inventory_tracked or coalesce(balance.quantity_on_hand,0)>0)
      and coalesce((validation.result->>'allowed')::boolean,false)
  ),paged as(select * from eligible order by rank,name limit v_size offset(v_page-1)*v_size)
  select(select count(*)from eligible),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',product.id,'code',coalesce(product.internal_sku,product.barcode),'name',product.name,'unit',product.unit,'inventory_tracked',product.is_inventory_tracked,
    'quantity_on_hand',product.quantity_on_hand,'price_list_id',v_price_list_id,'base_price_amount',round(product.base_price_amount,2),'tax_rate',product.tax_rate,
    'tax_amount',product.tax_amount,'price_amount',product.price_amount,'currency_code',v_currency_code
  )order by product.rank,product.name)from paged product),'[]'::jsonb)into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);
end$$;

create or replace function public.search_pos_cart_blocked_products(
  p_cart_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30,p_at timestamptz default now()
)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_cart public.sale_carts%rowtype;v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,30),1),100);
  v_query text:=lower(trim(regexp_replace(coalesce(p_query,''),'\s+',' ','g')));v_total integer;v_items jsonb;v_price_list_id uuid;v_currency_code text;
  v_can_view_inventory boolean;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  perform public.assert_pos_access(v_cart.company_id,v_cart.location_id,'use_pos');
  if v_query='' then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',1,'page_size',v_size);end if;
  v_can_view_inventory:=public.has_company_permission(v_cart.company_id,'view_inventory');
  select coalesce(v_cart.price_list_id,customer.price_list_id,location.default_price_list_id,company.default_price_list_id)
  into v_price_list_id from public.companies company join public.locations location on location.id=v_cart.location_id and location.company_id=company.id
  left join public.customers customer on customer.id=v_cart.customer_id and customer.company_id=company.id where company.id=v_cart.company_id;
  select list.currency_code into v_currency_code from public.price_lists list where list.id=v_price_list_id and list.company_id=v_cart.company_id and list.is_active and list.status='active';
  with matching as materialized(
    select product.* from public.products product where product.company_id=v_cart.company_id and not exists(select 1 from regexp_split_to_table(v_query,'\s+')token where token<>'' and not(
      lower(product.name)like'%'||token||'%' or lower(coalesce(product.internal_sku,''))like'%'||token||'%' or lower(coalesce(product.barcode,''))=token
      or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like'%'||token||'%')
      or exists(select 1 from public.product_external_references reference where reference.product_id=product.id and lower(reference.external_code)like'%'||token||'%')
    ))
  ),detailed as materialized(
    select product.id,product.name,product.internal_sku,product.barcode,product.unit,product.is_inventory_tracked,coalesce(balance.quantity_on_hand,0)quantity_on_hand,
      price.amount price_amount,coalesce(remote_stock.location_count,0)other_location_stock_count,coalesce(remote_stock.quantity_on_hand,0)other_location_stock_quantity,
      array_remove(array[
        case when not exists(select 1 from public.location_sales_assortments assignment join public.sales_assortments assortment on assortment.id=assignment.assortment_id
          join public.sales_assortment_items item on item.assortment_id=assortment.id and item.product_id=product.id where assignment.location_id=v_cart.location_id
          and assignment.valid_from<=p_at and(assignment.valid_to is null or assignment.valid_to>p_at)and assortment.company_id=v_cart.company_id and assortment.status='active'
          and(assortment.valid_from is null or assortment.valid_from<=p_at)and(assortment.valid_to is null or assortment.valid_to>p_at))then'outside_assortment'end,
        case when not product.is_active then'inactive'end,case when not product.is_sellable then'not_sellable'end,
        case when product.commercial_review_required then'commercial_review_required'end,case when product.inventory_policy='unclassified' then'inventory_setup_required'end,
        case when product.sales_unit_id is null then'missing_sales_unit'end,case when product.tax_category_id is null then'missing_tax_category'end,
        case when product.tax_category_id is not null and not exists(select 1 from public.tax_rates tax_rate where tax_rate.tax_category_id=product.tax_category_id
          and tax_rate.valid_from<=p_at and(tax_rate.valid_to is null or tax_rate.valid_to>p_at))then'missing_current_tax_rate'end,
        case when coalesce(price.amount,0)<=0 then'missing_or_zero_price'end,case when product.is_inventory_tracked and coalesce(balance.quantity_on_hand,0)<=0 then'out_of_stock'end,
        case when not coalesce((validation.result->>'allowed')::boolean,false) then validation.result#>>'{culinary_readiness,blockers,0,code}' end
      ]::text[],null)blockers
    from matching product left join public.inventory_balances balance on balance.location_id=v_cart.location_id and balance.product_id=product.id
    left join lateral(select product_price.amount from public.product_prices product_price where product_price.product_id=product.id and product_price.price_list_id=v_price_list_id
      and product_price.currency_code=v_currency_code and product_price.valid_from<=p_at and(product_price.valid_to is null or product_price.valid_to>p_at)order by product_price.valid_from desc limit 1)price on true
    left join lateral(select count(*)::integer location_count,coalesce(sum(remote_balance.quantity_on_hand),0)quantity_on_hand from public.inventory_balances remote_balance
      join public.locations remote_location on remote_location.id=remote_balance.location_id where v_can_view_inventory and remote_balance.company_id=v_cart.company_id
      and remote_balance.product_id=product.id and remote_balance.location_id<>v_cart.location_id and remote_balance.quantity_on_hand>0 and remote_location.is_active
      and public.can_access_location(remote_location.id))remote_stock on true
    cross join lateral(select public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,product.id,p_at)result)validation
  ),blocked as materialized(select * from detailed where cardinality(blockers)>0),paged as(select * from blocked order by name,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from blocked),coalesce((select jsonb_agg(jsonb_build_object(
    'product_id',product.id,'code',coalesce(product.internal_sku,product.barcode),'name',product.name,'unit',product.unit,'inventory_tracked',product.is_inventory_tracked,
    'quantity_on_hand',product.quantity_on_hand,'price_amount',product.price_amount,'currency_code',v_currency_code,'other_location_stock_count',product.other_location_stock_count,
    'other_location_stock_quantity',product.other_location_stock_quantity,'blockers',to_jsonb(product.blockers)
  )order by product.name,product.id)from paged product),'[]'::jsonb)into v_total,v_items;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size,'price_list_id',v_price_list_id);
end$$;

revoke all on function public.culinary_pos_readiness(uuid,uuid,uuid,numeric,timestamptz,text) from public,anon;
revoke all on function public.change_sale_cart_item(uuid,uuid,numeric,integer) from public,anon;
revoke all on function public.search_pos_cart_products(uuid,text,integer,integer,timestamptz) from public,anon;
revoke all on function public.search_pos_cart_blocked_products(uuid,text,integer,integer,timestamptz) from public,anon;
grant execute on function public.culinary_pos_readiness(uuid,uuid,uuid,numeric,timestamptz,text) to authenticated;
grant execute on function public.change_sale_cart_item(uuid,uuid,numeric,integer) to authenticated;
grant execute on function public.search_pos_cart_products(uuid,text,integer,integer,timestamptz) to authenticated;
grant execute on function public.search_pos_cart_blocked_products(uuid,text,integer,integer,timestamptz) to authenticated;
