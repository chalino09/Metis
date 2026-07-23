-- Focused POS context and explicit, secondary blocked-product search.

create or replace function public.get_pos_context(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'use_pos') then raise exception 'No autorizado.'; end if;
  return jsonb_build_object(
    'locations',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'code',l.external_code) order by l.name) from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)),'[]'::jsonb),
    'registers',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'location_id',r.location_id,'name',r.display_name,'code',r.code,'currency_code',r.currency_code) order by r.display_name) from public.cash_registers r where r.company_id=p_company_id and r.is_active and public.can_access_location(r.location_id)),'[]'::jsonb),
    'payment_methods',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'code',m.code,'name',m.display_name,'settlement_kind',m.settlement_kind) order by m.display_name) from public.payment_methods m where m.company_id=p_company_id and m.is_active),'[]'::jsonb),
    'own_open_session',(select jsonb_build_object('id',s.id,'cash_register_id',s.cash_register_id,'location_id',s.location_id,'status',s.status,'opening_amount',s.opening_amount,'opened_at',s.opened_at) from public.cash_sessions s where s.company_id=p_company_id and s.opened_by=auth.uid() and s.status in ('open','pending_variance_approval') order by s.opened_at desc limit 1)
  );
end $$;

create or replace function public.search_pos_blocked_products(p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_query text default null,p_page integer default 1,p_page_size integer default 30,p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  perform public.assert_pos_access(p_company_id,p_location_id,'use_pos');
  if v_query='' then return jsonb_build_object('items','[]'::jsonb,'total',0,'page',1,'page_size',v_size); end if;
  with detailed as materialized (
    select distinct p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,coalesce(b.quantity_on_hand,0) quantity_on_hand,price_data.price,ready.readiness,
      (not coalesce((ready.readiness->>'pos_ready')::boolean,false) or price_data.price is null or (p.is_inventory_tracked and coalesce(b.quantity_on_hand,0)<=0)) blocked
    from public.sales_assortment_items i join public.sales_assortments a on a.id=i.assortment_id join public.location_sales_assortments la on la.assortment_id=a.id join public.products p on p.id=i.product_id
    left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id
    cross join lateral (select public.resolve_pos_sale_price(p_company_id,p_location_id,p_customer_id,p.id,p_at) price) price_data
    cross join lateral (select public.product_pos_readiness_detail(p_company_id,p.id,null,p_at) readiness) ready
    where la.location_id=p_location_id and la.valid_from<=p_at and (la.valid_to is null or la.valid_to>p_at) and a.status='active' and (a.valid_from is null or a.valid_from<=p_at) and (a.valid_to is null or a.valid_to>p_at) and p.company_id=p_company_id
      and (lower(p.name) like '%'||v_query||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_query||'%' or lower(coalesce(p.barcode,''))=v_query or exists(select 1 from public.product_aliases x where x.product_id=p.id and lower(x.normalized_value) like '%'||v_query||'%') or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||v_query||'%'))
  ) select count(*) into v_total from detailed where blocked;
  with detailed as materialized (
    select distinct p.id,p.name,p.internal_sku,p.barcode,p.unit,p.is_inventory_tracked,coalesce(b.quantity_on_hand,0) quantity_on_hand,price_data.price,ready.readiness,
      (not coalesce((ready.readiness->>'pos_ready')::boolean,false) or price_data.price is null or (p.is_inventory_tracked and coalesce(b.quantity_on_hand,0)<=0)) blocked
    from public.sales_assortment_items i join public.sales_assortments a on a.id=i.assortment_id join public.location_sales_assortments la on la.assortment_id=a.id join public.products p on p.id=i.product_id
    left join public.inventory_balances b on b.location_id=p_location_id and b.product_id=p.id
    cross join lateral (select public.resolve_pos_sale_price(p_company_id,p_location_id,p_customer_id,p.id,p_at) price) price_data
    cross join lateral (select public.product_pos_readiness_detail(p_company_id,p.id,null,p_at) readiness) ready
    where la.location_id=p_location_id and la.valid_from<=p_at and (la.valid_to is null or la.valid_to>p_at) and a.status='active' and (a.valid_from is null or a.valid_from<=p_at) and (a.valid_to is null or a.valid_to>p_at) and p.company_id=p_company_id
      and (lower(p.name) like '%'||v_query||'%' or lower(coalesce(p.internal_sku,'')) like '%'||v_query||'%' or lower(coalesce(p.barcode,''))=v_query or exists(select 1 from public.product_aliases x where x.product_id=p.id and lower(x.normalized_value) like '%'||v_query||'%') or exists(select 1 from public.product_external_references x where x.product_id=p.id and lower(x.external_code) like '%'||v_query||'%'))
  ), paged as (select * from detailed where blocked order by name,id limit v_size offset (v_page-1)*v_size)
  select coalesce(jsonb_agg(jsonb_build_object('product_id',p.id,'code',coalesce(p.internal_sku,p.barcode),'name',p.name,'unit',p.unit,'inventory_tracked',p.is_inventory_tracked,'quantity_on_hand',p.quantity_on_hand,'price_amount',p.price->'amount','currency_code',p.price->'currency_code','blockers',(coalesce(p.readiness->'blockers','[]'::jsonb)||case when p.price is null then jsonb_build_array('missing_or_zero_price') else '[]'::jsonb end||case when p.is_inventory_tracked and p.quantity_on_hand<=0 then jsonb_build_array('out_of_stock') else '[]'::jsonb end)) order by p.name,p.id),'[]'::jsonb) into v_items from paged p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.search_pos_blocked_products(uuid,uuid,uuid,text,integer,integer,timestamptz) from public;
grant execute on function public.search_pos_blocked_products(uuid,uuid,uuid,text,integer,integer,timestamptz) to authenticated;

