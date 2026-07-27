-- Satrapy BI · Fase 6: red de dependencias de abastecimiento.
-- La red se calcula desde el dominio canónico. Sólo se persiste configuración.

insert into public.permissions(code,description) values
  ('view_bi_dependency_network','Consultar la red de dependencias dentro del alcance de empresa y ubicación.'),
  ('expand_bi_dependency_network','Expandir vecinos y consultar evidencia de la red de dependencias.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in('super_admin','direccion_admin') and p.code in(
  'view_bi_dependency_network','expand_bi_dependency_network'
) on conflict do nothing;

alter table public.bi_dashboard_widgets drop constraint if exists bi_dashboard_widgets_widget_type_check;
alter table public.bi_dashboard_widgets add constraint bi_dashboard_widgets_widget_type_check
  check(widget_type in('kpi','chart','table','network'));
alter table public.bi_export_jobs drop constraint if exists bi_export_jobs_target_type_check;
alter table public.bi_export_jobs add constraint bi_export_jobs_target_type_check
  check(target_type in('view','widget','dashboard','network'));
alter table public.bi_export_jobs drop constraint if exists bi_export_jobs_format_check;
alter table public.bi_export_jobs add constraint bi_export_jobs_format_check
  check(format in('csv','xlsx','pdf','png'));

-- Índices sobre uniones y ventanas usadas por la red. No se crea una copia BI del dominio.
create index if not exists purchase_receipt_lines_company_product_receipt_idx
  on public.purchase_receipt_lines(company_id,product_id,purchase_receipt_id);
create index if not exists purchase_order_lines_company_product_order_idx
  on public.purchase_order_lines(company_id,product_id,purchase_order_id);
create index if not exists procurement_award_lines_company_quote_idx
  on public.procurement_award_lines(company_id,quote_line_id,award_id);
create index if not exists sale_items_product_sale_idx on public.sale_items(product_id,sale_id);

create or replace function public.bi_assert_network_scope(
  p_company_id uuid,p_location_id uuid default null,p_category_id uuid default null,
  p_supplier_id uuid default null,p_product_id uuid default null
) returns void language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id,'view_bi')
    or not public.has_company_permission(p_company_id,'view_bi_dependency_network') then
    raise exception 'No autorizado para consultar la red de dependencias.';
  end if;
  if p_location_id is not null and not exists(
    select 1 from public.locations l where l.id=p_location_id and l.company_id=p_company_id
      and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.'; end if;
  if p_category_id is not null and not exists(
    select 1 from public.product_categories c where c.id=p_category_id and c.company_id=p_company_id
  ) then raise exception 'Categoría no disponible.'; end if;
  if p_supplier_id is not null and not exists(
    select 1 from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id
  ) then raise exception 'Proveedor no disponible.'; end if;
  if p_product_id is not null and not exists(
    select 1 from public.products p where p.id=p_product_id and p.company_id=p_company_id
  ) then raise exception 'Producto no disponible.'; end if;
end $$;

create or replace function public.bi_search_dependency_nodes(
  p_company_id uuid,p_query text,p_node_type text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_q text:=lower(trim(coalesce(p_query,'')));v_page int:=greatest(coalesce(p_page,1),1);
v_size int:=least(greatest(coalesce(p_page_size,25),1),50);v_total bigint;v_items jsonb;
begin
  perform public.bi_assert_network_scope(p_company_id);
  if p_node_type is not null and p_node_type not in('supplier','product','category','location')then
    raise exception 'Tipo de nodo inválido.';
  end if;
  with nodes as materialized(
    select 'supplier'::text node_type,s.id,s.display_name label,s.code secondary
    from public.suppliers s where s.company_id=p_company_id and s.is_active
    union all select 'product',p.id,p.name,p.internal_sku from public.products p
      where p.company_id=p_company_id and p.is_active
    union all select 'category',c.id,c.name,c.external_code from public.product_categories c
      where c.company_id=p_company_id and c.is_active
    union all select 'location',l.id,l.name,l.external_code from public.locations l
      where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)
  ),filtered as materialized(
    select * from nodes where(p_node_type is null or node_type=p_node_type)
      and(v_q='' or lower(label)like'%'||v_q||'%'or lower(coalesce(secondary,''))like'%'||v_q||'%')
  ),paged as(select * from filtered order by label,id limit v_size offset(v_page-1)*v_size)
  select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by label,id),'[]')into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.bi_dependency_network_query(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,p_category_id uuid default null,
  p_supplier_id uuid default null,p_product_id uuid default null,p_relation_types text[] default null,
  p_operational_state text default null,p_concentration_level text default null,
  p_size_metric text default 'purchases',p_color_metric text default 'node_type',p_edge_metric text default 'amount',
  p_perspective text default 'supplier_dependency',p_anchor_type text default null,p_anchor_id uuid default null,
  p_expansion_levels integer default 0,p_node_limit integer default 120,p_edge_limit integer default 240
) returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_nodes jsonb;v_edges jsonb;v_node_total bigint;v_edge_total bigint;v_node_limit int:=least(greatest(coalesce(p_node_limit,120),1),200);
v_edge_limit int:=least(greatest(coalesce(p_edge_limit,240),1),400);v_levels int:=least(greatest(coalesce(p_expansion_levels,0),0),2);
v_updated timestamptz;v_currency text;v_anchor text:=case when p_anchor_id is null then null else p_anchor_type||':'||p_anchor_id::text end;
begin
  perform public.bi_assert_network_scope(p_company_id,p_location_id,p_category_id,p_supplier_id,p_product_id);
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from>731 then raise exception'Periodo inválido; la red admite hasta 732 días.';end if;
  if p_size_metric not in('purchases','sales','inventory','connections')or p_color_metric not in('node_type','concentration','availability')
    or p_edge_metric not in('amount','quantity','frequency')then raise exception'Codificación visual incompatible.';end if;
  if v_levels>0 and(not public.has_company_permission(p_company_id,'expand_bi_dependency_network'))then raise exception'No autorizado para expandir la red.';end if;
  select c.base_currency into v_currency from public.accounting_config_versions c
  where c.company_id=p_company_id and c.status='approved';

  with
  receipt_evidence as materialized(
    select pr.supplier_id,rl.product_id,sum(rl.line_cost)amount,sum(rl.quantity)quantity,
      count(distinct pr.id)frequency,min(pr.receipt_date)first_at,max(pr.receipt_date)last_at,
      jsonb_build_array(jsonb_build_object('type','purchase_receipt','count',count(distinct pr.id),'first_at',min(pr.receipt_date),'last_at',max(pr.receipt_date))) evidence
    from public.purchase_receipts pr join public.purchase_receipt_lines rl on rl.purchase_receipt_id=pr.id
    join public.products p on p.id=rl.product_id
    where pr.company_id=p_company_id and pr.status='confirmed' and pr.receipt_date between p_date_from and p_date_to
      and public.can_access_location(pr.location_id) and(p_location_id is null or pr.location_id=p_location_id)
      and(p_supplier_id is null or pr.supplier_id=p_supplier_id)and(p_product_id is null or rl.product_id=p_product_id)
      and(p_category_id is null or p.category_id=p_category_id)
    group by pr.supplier_id,rl.product_id
  ),
  order_evidence as materialized(
    select po.supplier_id,pol.product_id,sum(pol.line_total)amount,sum(pol.quantity)quantity,count(distinct po.id)frequency,
      min(po.ordered_date)first_at,max(po.ordered_date)last_at,
      jsonb_build_array(jsonb_build_object('type','purchase_order','count',count(distinct po.id),'first_at',min(po.ordered_date),'last_at',max(po.ordered_date)))evidence
    from public.purchase_orders po join public.purchase_order_lines pol on pol.purchase_order_id=po.id
    join public.products p on p.id=pol.product_id
    where po.company_id=p_company_id and po.status='approved'and po.ordered_date between p_date_from and p_date_to
      and pol.product_id is not null and(p_supplier_id is null or po.supplier_id=p_supplier_id)
      and(p_product_id is null or pol.product_id=p_product_id)and(p_category_id is null or p.category_id=p_category_id)
      and(p_location_id is null or exists(select 1 from public.procurement_purchase_orders ppo join public.procurement_awards pa on pa.id=ppo.procurement_award_id
        join public.procurement_requisitions req on req.id=pa.requisition_id where ppo.purchase_order_id=po.id and req.location_id=p_location_id and public.can_access_location(req.location_id)))
    group by po.supplier_id,pol.product_id
  ),
  award_evidence as materialized(
    select q.supplier_id,rl.product_id,sum(al.awarded_quantity*ql.unit_price*(1-ql.commercial_discount_percent/100))amount,
      sum(al.awarded_quantity)quantity,count(distinct a.id)frequency,min(a.decided_at::date)first_at,max(a.decided_at::date)last_at,
      jsonb_build_array(jsonb_build_object('type','procurement_award','count',count(distinct a.id),'first_at',min(a.decided_at::date),'last_at',max(a.decided_at::date)))evidence
    from public.procurement_awards a join public.procurement_award_lines al on al.award_id=a.id
    join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id
    join public.procurement_requisition_lines rl on rl.id=al.requisition_line_id join public.procurement_requisitions req on req.id=rl.requisition_id
    join public.products p on p.id=rl.product_id
    where a.company_id=p_company_id and a.status='approved'and a.decided_at::date between p_date_from and p_date_to
      and public.can_access_location(req.location_id)and(p_location_id is null or req.location_id=p_location_id)
      and(p_supplier_id is null or q.supplier_id=p_supplier_id)and(p_product_id is null or rl.product_id=p_product_id)
      and(p_category_id is null or p.category_id=p_category_id)
    group by q.supplier_id,rl.product_id
  ),
  quote_evidence as materialized(
    select q.supplier_id,rl.product_id,sum(ql.available_quantity*ql.unit_price*(1-ql.commercial_discount_percent/100))amount,
      sum(ql.available_quantity)quantity,count(distinct q.id)frequency,min(q.created_at::date)first_at,max(q.created_at::date)last_at,
      jsonb_build_array(jsonb_build_object('type','procurement_quote','count',count(distinct q.id),'first_at',min(q.created_at::date),'last_at',max(q.created_at::date)))evidence
    from public.procurement_quotes q join public.procurement_quote_lines ql on ql.quote_id=q.id
    join public.procurement_requisition_lines rl on rl.id=ql.requisition_line_id join public.procurement_requisitions req on req.id=rl.requisition_id
    join public.products p on p.id=rl.product_id
    where q.company_id=p_company_id and q.status in('received','selected')and q.created_at::date between p_date_from and p_date_to
      and public.can_access_location(req.location_id)and(p_location_id is null or req.location_id=p_location_id)
      and(p_supplier_id is null or q.supplier_id=p_supplier_id)and(p_product_id is null or rl.product_id=p_product_id)
      and(p_category_id is null or p.category_id=p_category_id)
    group by q.supplier_id,rl.product_id
  ),
  evidence_pairs as materialized(
    select supplier_id,product_id from receipt_evidence union select supplier_id,product_id from order_evidence
    union select supplier_id,product_id from award_evidence union select supplier_id,product_id from quote_evidence
  ),
  supplier_product as materialized(
    select 'supplier:'||s.id source_id,'product:'||p.id target_id,'supplier_product'::text relation_type,
      case when r.supplier_id is not null then r.amount when o.supplier_id is not null then o.amount when a.supplier_id is not null then a.amount else q.amount end amount,
      case when r.supplier_id is not null then r.quantity when o.supplier_id is not null then o.quantity when a.supplier_id is not null then a.quantity else q.quantity end quantity,
      case when r.supplier_id is not null then r.frequency when o.supplier_id is not null then o.frequency when a.supplier_id is not null then a.frequency else q.frequency end frequency,
      coalesce(r.first_at,o.first_at,a.first_at,q.first_at)first_at,coalesce(r.last_at,o.last_at,a.last_at,q.last_at)last_at,
      (case when r.supplier_id is null then'[]'::jsonb else r.evidence end)||
      (case when o.supplier_id is null then'[]'::jsonb else o.evidence end)||
      (case when a.supplier_id is null then'[]'::jsonb else a.evidence end)||
      (case when q.supplier_id is null then'[]'::jsonb else q.evidence end)evidence,
      case when r.supplier_id is not null then'confirmed_receipt'when o.supplier_id is not null then'approved_order'
        when a.supplier_id is not null then'approved_award'else'received_quote'end metric_source,
      jsonb_build_object('receipts',coalesce(r.frequency,0),'orders',coalesce(o.frequency,0),'awards',coalesce(a.frequency,0),'quotes',coalesce(q.frequency,0))source_counts
    from evidence_pairs ep join public.suppliers s on s.id=ep.supplier_id join public.products p on p.id=ep.product_id
    left join receipt_evidence r on r.supplier_id=s.id and r.product_id=p.id
    left join order_evidence o on o.supplier_id=s.id and o.product_id=p.id
    left join award_evidence a on a.supplier_id=s.id and a.product_id=p.id
    left join quote_evidence q on q.supplier_id=s.id and q.product_id=p.id
    where s.company_id=p_company_id and p.company_id=p_company_id
  ),
  location_seed_products as materialized(
    select p.id product_id from public.products p join public.sales_assortment_items sai on sai.product_id=p.id
    join public.sales_assortments sa on sa.id=sai.assortment_id join public.location_sales_assortments lsa on lsa.assortment_id=sa.id
    where p.company_id=p_company_id and p_perspective='location_coverage'and sa.status='active'
      and public.can_access_location(lsa.location_id)and(p_location_id is null or lsa.location_id=p_location_id)
      and(p_category_id is null or p.category_id=p_category_id)
    order by p.id limit v_node_limit
  ),
  scoped_products as materialized(
    select distinct replace(target_id,'product:','')::uuid product_id from(
      select target_id,amount from supplier_product order by amount desc nulls last,target_id limit v_node_limit
    )bounded_supplier_products
    union select product_id from location_seed_products
    union select p_product_id where p_product_id is not null
  ),
  product_category as(
    select 'product:'||p.id,'category:'||c.id,'product_category',0::numeric,0::numeric,1::bigint,
      null::date,null::date,jsonb_build_array(jsonb_build_object('type','canonical_classification','id',c.id)),
      'products.category_id',jsonb_build_object('classification',1)
    from public.products p join public.product_categories c on c.id=p.category_id and c.company_id=p.company_id
    where p.company_id=p_company_id and p.id in(select product_id from scoped_products)
  ),
  product_assortment as(
    select distinct 'product:'||p.id,'location:'||l.id,'product_location_assortment',0::numeric,0::numeric,1::bigint,
      greatest(sa.valid_from::date,lsa.valid_from::date),least(coalesce(sa.valid_to::date,p_date_to),coalesce(lsa.valid_to::date,p_date_to)),
      jsonb_build_array(jsonb_build_object('type','sales_assortment','id',sa.id,'name',sa.name)),
      'active_sales_assortment',jsonb_build_object('assortment',1)
    from public.products p join public.sales_assortment_items sai on sai.product_id=p.id
    join public.sales_assortments sa on sa.id=sai.assortment_id
    join public.location_sales_assortments lsa on lsa.assortment_id=sa.id join public.locations l on l.id=lsa.location_id
    where p.company_id=p_company_id and p.id in(select product_id from scoped_products)and sa.status='active'
      and tstzrange(coalesce(sa.valid_from,'-infinity'),coalesce(sa.valid_to,'infinity'),'[)')&&tstzrange(p_date_from::timestamptz,(p_date_to+1)::timestamptz,'[)')
      and tstzrange(lsa.valid_from,coalesce(lsa.valid_to,'infinity'),'[)')&&tstzrange(p_date_from::timestamptz,(p_date_to+1)::timestamptz,'[)')
      and public.can_access_location(l.id)and(p_location_id is null or l.id=p_location_id)
  ),
  bounded_locations as materialized(
    select l.* from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)
      and(p_location_id is null or l.id=p_location_id)order by l.id limit least(v_node_limit,50)
  ),
  product_availability as(
    select 'product:'||p.id,'location:'||l.id,'product_location_availability',0::numeric,coalesce(ib.quantity_on_hand,0),1::bigint,
      current_date,current_date,jsonb_build_array(jsonb_build_object('type','inventory_balance','quantity_on_hand',coalesce(ib.quantity_on_hand,0),'updated_at',ib.updated_at),
        jsonb_build_object('type','pos_readiness','pos_ready',coalesce((rd->>'pos_ready')::boolean,false),'blockers',rd->'blockers')),
      'current_inventory_and_readiness',jsonb_build_object('inventory_balance',1),
      case when not coalesce((rd->>'pos_ready')::boolean,false)then'blocked_readiness'
        when coalesce(ib.quantity_on_hand,0)>0 then'available'else'out_of_stock'end operational_state
    from public.products p join bounded_locations l on true
    left join public.inventory_balances ib on ib.product_id=p.id and ib.location_id=l.id
    cross join lateral public.product_pos_readiness_detail(p_company_id,p.id,null,now())rd
    where p.company_id=p_company_id and p.id in(select product_id from scoped_products)
      and public.can_access_location(l.id)
  ),
  all_edges as materialized(
    select *,null::text operational_state from supplier_product union all select *,null::text from product_category
    union all select *,null::text from product_assortment union all select * from product_availability
  ),
  filtered_edges as materialized(
    select *,case p_edge_metric when'quantity'then quantity when'frequency'then frequency else amount end weight
    from all_edges e where(p_relation_types is null or e.relation_type=any(p_relation_types))
      and(p_operational_state is null or e.operational_state=p_operational_state)
      and(v_anchor is null or v_levels=0 or e.source_id=v_anchor or e.target_id=v_anchor
        or(v_levels=2 and exists(select 1 from all_edges first_edge
          where(first_edge.source_id=v_anchor or first_edge.target_id=v_anchor)
            and(e.source_id in(first_edge.source_id,first_edge.target_id)or e.target_id in(first_edge.source_id,first_edge.target_id)))))
  ),
  concentration as materialized(
    select target_id,source_id,amount/nullif(sum(amount)over(partition by target_id),0)share
    from filtered_edges where relation_type='supplier_product'
  ),
  ranked_edges as materialized(
    select e.*,coalesce(c.share,0)concentration_share,
      case when coalesce(c.share,0)>=.8 then'high'when coalesce(c.share,0)>=.5 then'medium'else'low'end concentration_level
    from filtered_edges e left join concentration c on c.target_id=e.target_id and c.source_id=e.source_id
    where p_concentration_level is null or case when coalesce(c.share,0)>=.8 then'high'when coalesce(c.share,0)>=.5 then'medium'else'low'end=p_concentration_level
    order by(case p_perspective when'unique_supplier'then coalesce(c.share,0) when'supply_concentration'then coalesce(c.share,0)else e.weight end)desc nulls last,
      e.relation_type,e.source_id,e.target_id limit v_edge_limit
  ),
  node_keys as materialized(select source_id id from ranked_edges union select target_id from ranked_edges),
  purchase_node as(
    select key,sum(amount)amount from(
      select source_id key,amount from ranked_edges where relation_type='supplier_product'
      union all select target_id,amount from ranked_edges where relation_type='supplier_product')x group by key
  ),
  sales_node as(
    select 'product:'||si.product_id key,sum(si.taxable_amount)amount from public.sales s join public.sale_items si on si.sale_id=s.id
    where s.company_id=p_company_id and s.completed_at::date between p_date_from and p_date_to and public.can_access_location(s.location_id)
      and(p_location_id is null or s.location_id=p_location_id)group by si.product_id
    union all select 'location:'||s.location_id,sum(si.taxable_amount)from public.sales s join public.sale_items si on si.sale_id=s.id
    where s.company_id=p_company_id and s.completed_at::date between p_date_from and p_date_to and public.can_access_location(s.location_id)
      and(p_location_id is null or s.location_id=p_location_id)group by s.location_id
  ),
  inventory_node as(
    select 'product:'||ib.product_id key,sum(ib.quantity_on_hand)amount from public.inventory_balances ib
    where ib.company_id=p_company_id and public.can_access_location(ib.location_id)and(p_location_id is null or ib.location_id=p_location_id)group by ib.product_id
    union all select 'location:'||ib.location_id,sum(ib.quantity_on_hand)from public.inventory_balances ib
    where ib.company_id=p_company_id and public.can_access_location(ib.location_id)and(p_location_id is null or ib.location_id=p_location_id)group by ib.location_id
  ),
  connection_node as(
    select id,count(*)amount from(select source_id id from ranked_edges union all select target_id from ranked_edges)x group by id
  ),
  node_catalog as(
    select 'supplier:'||s.id id,'supplier' node_type,s.id entity_id,s.display_name label,s.code secondary,null::text operational_state
      from public.suppliers s where s.company_id=p_company_id
    union all select 'product:'||p.id,'product',p.id,p.name,p.internal_sku,null from public.products p where p.company_id=p_company_id
    union all select 'category:'||c.id,'category',c.id,c.name,c.external_code,null from public.product_categories c where c.company_id=p_company_id
    union all select 'location:'||l.id,'location',l.id,l.name,l.external_code,null from public.locations l
      where l.company_id=p_company_id and public.can_access_location(l.id)
  ),
  selected_nodes as materialized(
    select n.*,coalesce(pn.amount,0)purchases,coalesce(sn.amount,0)sales,coalesce(inv.amount,0)inventory,
      coalesce(cn.amount,0)connections,case p_size_metric when'sales'then coalesce(sn.amount,0)when'inventory'then coalesce(inv.amount,0)
        when'connections'then coalesce(cn.amount,0)else coalesce(pn.amount,0)end size_value,
      coalesce((select max(concentration_share)from ranked_edges e where e.source_id=n.id or e.target_id=n.id),0)concentration,
      (select min(e.operational_state)from ranked_edges e where(e.source_id=n.id or e.target_id=n.id)and e.operational_state is not null)availability
    from node_catalog n join node_keys k on k.id=n.id left join purchase_node pn on pn.key=n.id
    left join sales_node sn on sn.key=n.id left join inventory_node inv on inv.key=n.id left join connection_node cn on cn.id=n.id
    order by size_value desc,n.node_type,n.label,n.id limit v_node_limit
  ),
  final_edges as materialized(select e.* from ranked_edges e join selected_nodes s on s.id=e.source_id join selected_nodes t on t.id=e.target_id)
  select(select count(*)from node_keys),(select count(*)from filtered_edges),
    coalesce((select jsonb_agg(jsonb_build_object('id',id,'type',node_type,'entity_id',entity_id,'label',label,'secondary',secondary,
      'metrics',jsonb_build_object('purchases',purchases,'sales',sales,'inventory',inventory,'connections',connections),
      'size_value',size_value,'concentration',concentration,'availability',availability)order by size_value desc,node_type,label,id)from selected_nodes),'[]'),
    coalesce((select jsonb_agg(jsonb_build_object('id',relation_type||':'||source_id||':'||target_id,'source',source_id,'target',target_id,
      'type',relation_type,'direction','outbound','amount',amount,'quantity',quantity,'frequency',frequency,'weight',weight,
      'period',jsonb_build_object('from',first_at,'to',last_at),'metric_source',metric_source,'source_counts',source_counts,
      'evidence',evidence,'operational_state',operational_state,'concentration_share',concentration_share,
      'concentration_level',concentration_level)order by weight desc nulls last,relation_type,source_id,target_id)from final_edges),'[]')
  into v_node_total,v_edge_total,v_nodes,v_edges;

  select greatest(
    coalesce((select max(updated_at)from public.purchase_receipts where company_id=p_company_id),'epoch'),
    coalesce((select max(updated_at)from public.purchase_orders where company_id=p_company_id),'epoch'),
    coalesce((select max(updated_at)from public.inventory_balances where company_id=p_company_id),'epoch'),
    coalesce((select max(updated_at)from public.products where company_id=p_company_id),'epoch')
  )into v_updated;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(
    p_company_id,auth.uid(),'bi.network_queried','bi_dependency_network',
    jsonb_build_object('from',p_date_from,'to',p_date_to,'node_limit',v_node_limit,'edge_limit',v_edge_limit,'anchor',v_anchor,'levels',v_levels)
  );
  return jsonb_build_object('nodes',v_nodes,'edges',v_edges,'period',jsonb_build_object('from',p_date_from,'to',p_date_to),
    'currency_code',v_currency,'updated_at',v_updated,'limits',jsonb_build_object('nodes',v_node_limit,'edges',v_edge_limit,'expansion_levels',2),
    'totals',jsonb_build_object('nodes',v_node_total,'edges',v_edge_total),
    'truncated',v_node_total>v_node_limit or v_edge_total>v_edge_limit,
    'methodology',jsonb_build_object(
      'supplier_product','Importe y cantidad de recepciones confirmadas; si no existen, se usa una sola etapa de respaldo: orden aprobada, adjudicación aprobada o cotización recibida.',
      'product_category','Clasificación canónica vigente products.category_id; no se usa texto Alpha.',
      'product_location_assortment','Pertenencia comercial por surtido activo y asignación vigente.',
      'product_location_availability','Estado operativo actual: readiness canónico y existencia; no modifica el surtido.',
      'concentration','Importe proveedor-producto ÷ importe total del producto dentro del filtro. Alto ≥80%; medio ≥50%; bajo <50%.',
      'warning','La cercanía visual no implica causalidad. Las etapas del ciclo de compra no se suman entre sí.'
    ),'trace',jsonb_build_object('query','bi_dependency_network_query','company_id',p_company_id,
      'sources',jsonb_build_array('procurement_quotes','procurement_awards','purchase_orders','purchase_receipts','products','product_categories','sales_assortments','inventory_balances','product_pos_readiness_detail','sales')));
end $$;

create or replace function public.bi_dependency_network_drilldown(
  p_company_id uuid,p_relation_type text,p_source_id uuid,p_target_id uuid,p_date_from date,p_date_to date,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);
v_total bigint;v_items jsonb;
begin
  perform public.bi_assert_network_scope(p_company_id);
  if p_relation_type='supplier_product'then
    with evidence as materialized(
      select pr.id,pr.receipt_date occurred_at,'Recepción confirmada' evidence_type,pr.folio reference,
        l.name location_name,rl.line_cost amount,rl.quantity,pr.location_id
      from public.purchase_receipts pr join public.purchase_receipt_lines rl on rl.purchase_receipt_id=pr.id
      join public.locations l on l.id=pr.location_id where pr.company_id=p_company_id and pr.supplier_id=p_source_id
        and rl.product_id=p_target_id and pr.status='confirmed'and pr.receipt_date between p_date_from and p_date_to
        and public.can_access_location(pr.location_id)
    ),paged as(select*from evidence order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from evidence),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
  elsif p_relation_type in('product_location_assortment','product_location_availability')then
    with evidence as materialized(
      select sa.id,lsa.valid_from::date occurred_at,'Surtido comercial' evidence_type,sa.name reference,l.name location_name,
        null::numeric amount,null::numeric quantity,l.id location_id
      from public.sales_assortment_items sai join public.sales_assortments sa on sa.id=sai.assortment_id
      join public.location_sales_assortments lsa on lsa.assortment_id=sa.id join public.locations l on l.id=lsa.location_id
      where sai.product_id=p_source_id and l.id=p_target_id and sa.company_id=p_company_id and public.can_access_location(l.id)
    ),paged as(select*from evidence order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from evidence),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
  else v_total:=1;v_items:=jsonb_build_array(jsonb_build_object('id',p_target_id,'evidence_type','Clasificación canónica','occurred_at',null));
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(p_company_id,auth.uid(),'bi.network_drilldown','bi_dependency_network',
    jsonb_build_object('relation_type',p_relation_type,'source_id',p_source_id,'target_id',p_target_id,'page',v_page));
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.bi_start_network_export(
  p_company_id uuid,p_format text,p_definition jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_job uuid;
begin
  perform public.bi_assert_network_scope(p_company_id);
  if not public.has_company_permission(p_company_id,'export_bi_reports')then raise exception'No autorizado para exportar BI.';end if;
  if p_format not in('csv','xlsx','pdf','png')then raise exception'Formato no disponible.';end if;
  perform public.bi_assert_explorer_definition(p_company_id,p_definition);
  insert into public.bi_export_jobs(company_id,target_type,target_id,format,query_snapshot)
  values(p_company_id,'network',gen_random_uuid(),p_format,p_definition)returning id into v_job;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.network_export_started','bi_export_job',v_job,jsonb_build_object('format',p_format));
  return v_job;
end $$;

-- Fase 4 se extiende para validar configuración de Explorador o de Red.
create or replace function public.bi_assert_explorer_definition(p_company_id uuid,p_definition jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb;codes text[];d1 date;d2 date;
begin
  if jsonb_typeof(p_definition)<>'object'then raise exception'Definición de BI inválida.';end if;
  d1:=(p_definition->>'date_from')::date;d2:=(p_definition->>'date_to')::date;
  if coalesce(p_definition->>'kind','explorer')='network'then
    r:=public.bi_dependency_network_query(p_company_id,d1,d2,nullif(p_definition->>'location_id','')::uuid,
      nullif(p_definition->>'category_id','')::uuid,nullif(p_definition->>'supplier_id','')::uuid,
      nullif(p_definition->>'product_id','')::uuid,
      case when jsonb_typeof(p_definition->'relation_types')='array'then array(select jsonb_array_elements_text(p_definition->'relation_types'))end,
      nullif(p_definition->>'operational_state',''),nullif(p_definition->>'concentration_level',''),
      coalesce(p_definition->>'size_metric','purchases'),coalesce(p_definition->>'color_metric','node_type'),
      coalesce(p_definition->>'edge_metric','amount'),coalesce(p_definition->>'perspective','supplier_dependency'),null,null,0,1,1);
    return jsonb_build_object('valid',true,'kind','network','query',r->'trace');
  end if;
  select array_agg(value)into codes from jsonb_array_elements_text(p_definition->'metric_codes');
  r:=public.bi_explorer_query(p_company_id,codes,p_definition->>'dimension',p_definition->>'visualization',d1,d2,
    nullif(p_definition->>'location_id','')::uuid,nullif(p_definition->>'product_id','')::uuid,
    nullif(p_definition->>'customer_id','')::uuid,nullif(p_definition->>'supplier_id','')::uuid,
    coalesce((p_definition->>'compare_previous')::boolean,true),1,1);
  return jsonb_build_object('valid',true,'catalog_updated_at',(public.bi_get_metric_catalog(p_company_id)->>'updated_at'),'query',r->'query');
exception when invalid_text_representation or datetime_field_overflow then raise exception'Filtros o periodo de BI inválidos.';
end $$;

create or replace function public.bi_view_availability(p_company_id uuid,p_definition jsonb)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c jsonb;code text;metric jsonb;warnings jsonb:='[]'::jsonb;
begin
  if coalesce(p_definition->>'kind','explorer')='network'then
    if not public.has_company_permission(p_company_id,'view_bi_dependency_network')then
      warnings:=warnings||jsonb_build_array('No tienes permiso para consultar la red de dependencias.');
    end if;
    return jsonb_build_object('available',jsonb_array_length(warnings)=0,'warnings',warnings,'kind','network');
  end if;
  c:=public.bi_get_metric_catalog(p_company_id);
  for code in select value from jsonb_array_elements_text(p_definition->'metric_codes')loop
    select value into metric from jsonb_array_elements(c->'metrics')where value->>'code'=code;
    if metric is null then warnings:=warnings||jsonb_build_array('La métrica '||code||' ya no existe en el catálogo.');
    elsif not coalesce((metric->>'available')::boolean,false)then warnings:=warnings||jsonb_build_array(coalesce(metric->>'unavailable_reason','Métrica no disponible.'));
    end if;
  end loop;
  return jsonb_build_object('available',jsonb_array_length(warnings)=0,'warnings',warnings);
end $$;

create or replace function public.bi_add_dashboard_widget(
  p_company_id uuid,p_dashboard_id uuid,p_saved_view_id uuid,p_widget_type text,p_title text,p_filter_mode text default'inherit'
)returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;w public.bi_dashboard_widgets%rowtype;pos integer;definition jsonb;preview jsonb;
begin
  if not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'No autorizado.';end if;
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id for update;
  if not found then raise exception'Tablero no disponible.';end if;
  select vv.definition into definition from public.bi_saved_views v join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
  where v.id=p_saved_view_id and v.company_id=p_company_id and v.visibility='company';
  if not found then raise exception'Comparte la vista con la empresa antes de agregarla a un tablero.';end if;
  if coalesce(definition->>'kind','explorer')='network'and p_widget_type<>'network'then raise exception'Una vista de red requiere un widget de red.';end if;
  if coalesce(definition->>'kind','explorer')<>'network'and p_widget_type='network'then raise exception'El widget de red requiere una vista de red.';end if;
  if p_widget_type='network'then
    preview:=public.bi_dependency_network_query(p_company_id,(definition->>'date_from')::date,(definition->>'date_to')::date,
      nullif(definition->>'location_id','')::uuid,nullif(definition->>'category_id','')::uuid,nullif(definition->>'supplier_id','')::uuid,
      nullif(definition->>'product_id','')::uuid,case when jsonb_array_length(coalesce(definition->'relation_types','[]'))>0 then array(select jsonb_array_elements_text(definition->'relation_types'))end,
      nullif(definition->>'operational_state',''),nullif(definition->>'concentration_level',''),coalesce(definition->>'size_metric','purchases'),
      coalesce(definition->>'color_metric','node_type'),coalesce(definition->>'edge_metric','amount'),coalesce(definition->>'perspective','supplier_dependency'),
      null,null,0,40,80);
    if coalesce((preview->>'truncated')::boolean,false)then raise exception'La red es demasiado grande para un tablero. Acótala a 40 nodos y 80 relaciones con filtros.';end if;
  end if;
  if(select count(*)from public.bi_dashboard_widgets where dashboard_id=d.id)>=12 then raise exception'Un tablero admite hasta 12 widgets.';end if;
  select coalesce(max(position),-1)+1 into pos from public.bi_dashboard_widgets where dashboard_id=d.id;
  insert into public.bi_dashboard_widgets(dashboard_id,company_id,saved_view_id,widget_type,title,filter_mode,position,width,height)
  values(d.id,p_company_id,p_saved_view_id,p_widget_type,nullif(trim(coalesce(p_title,'')),''),p_filter_mode,pos,case when p_widget_type='network'then 4 else 2 end,case when p_widget_type='network'then 2 else 1 end)returning*into w;
  update public.bi_dashboards set revision=revision+1,updated_at=now()where id=d.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.widget_added','bi_dashboard_widget',w.id,jsonb_build_object('dashboard_id',d.id,'saved_view_id',p_saved_view_id,'widget_type',p_widget_type));
  return to_jsonb(w);
end $$;

create or replace function public.bi_get_dashboard_snapshot(p_company_id uuid,p_dashboard_id uuid,p_global_filters jsonb default'{}')
returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;w record;definition jsonb;effective jsonb;result jsonb;widgets jsonb:='[]';from_date date;to_date date;codes text[];
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_dashboards')then raise exception'No autorizado para consultar tableros.';end if;
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id;
  if not found then raise exception'Tablero no disponible.';end if;
  for w in select x.*,v.name view_name,v.current_version,v.visibility,v.owner_id,vv.definition
    from public.bi_dashboard_widgets x join public.bi_saved_views v on v.id=x.saved_view_id
    join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    where x.dashboard_id=d.id order by x.position
  loop begin
    definition:=w.definition;effective:=definition;
    if w.filter_mode='inherit'then effective:=effective||jsonb_strip_nulls(jsonb_build_object(
      'date_from',p_global_filters->>'date_from','date_to',p_global_filters->>'date_to','location_id',p_global_filters->>'location_id'));
    else effective:=effective||w.own_filters;end if;
    from_date:=(effective->>'date_from')::date;to_date:=(effective->>'date_to')::date;
    if coalesce(effective->>'kind','explorer')='network'then
      result:=public.bi_dependency_network_query(p_company_id,from_date,to_date,nullif(effective->>'location_id','')::uuid,
        nullif(effective->>'category_id','')::uuid,nullif(effective->>'supplier_id','')::uuid,nullif(effective->>'product_id','')::uuid,
        case when jsonb_array_length(coalesce(effective->'relation_types','[]'))>0 then array(select jsonb_array_elements_text(effective->'relation_types'))end,
        nullif(effective->>'operational_state',''),nullif(effective->>'concentration_level',''),coalesce(effective->>'size_metric','purchases'),
        coalesce(effective->>'color_metric','node_type'),coalesce(effective->>'edge_metric','amount'),coalesce(effective->>'perspective','supplier_dependency'),
        null,null,0,40,80);
      if coalesce((result->>'truncated')::boolean,false)then raise exception'Red demasiado grande para el tablero; reduce sus filtros.';end if;
    else
      select array_agg(value)into codes from jsonb_array_elements_text(effective->'metric_codes');
      result:=public.bi_explorer_query(p_company_id,codes,effective->>'dimension',effective->>'visualization',from_date,to_date,
        nullif(effective->>'location_id','')::uuid,nullif(effective->>'product_id','')::uuid,nullif(effective->>'customer_id','')::uuid,
        nullif(effective->>'supplier_id','')::uuid,coalesce((effective->>'compare_previous')::boolean,true),1,case when w.widget_type='table'then 25 else 12 end);
    end if;
    widgets:=widgets||jsonb_build_array(to_jsonb(w)-'definition'||jsonb_build_object('status','ready','definition',effective,'result',result));
  exception when others then widgets:=widgets||jsonb_build_array(to_jsonb(w)-'definition'||jsonb_build_object('status','error','error',sqlerrm,'availability',public.bi_view_availability(p_company_id,w.definition)));end;end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.dashboard_queried','bi_dashboard',d.id,jsonb_build_object('widget_count',jsonb_array_length(widgets)));
  return jsonb_build_object('dashboard',to_jsonb(d),'widgets',widgets,'updated_at',now());
end $$;

revoke all on function public.bi_assert_network_scope(uuid,uuid,uuid,uuid,uuid),
  public.bi_search_dependency_nodes(uuid,text,text,integer,integer),
  public.bi_dependency_network_query(uuid,date,date,uuid,uuid,uuid,uuid,text[],text,text,text,text,text,text,text,uuid,integer,integer,integer),
  public.bi_dependency_network_drilldown(uuid,text,uuid,uuid,date,date,integer,integer),
  public.bi_start_network_export(uuid,text,jsonb) from public;
grant execute on function public.bi_search_dependency_nodes(uuid,text,text,integer,integer),
  public.bi_dependency_network_query(uuid,date,date,uuid,uuid,uuid,uuid,text[],text,text,text,text,text,text,text,uuid,integer,integer,integer),
  public.bi_dependency_network_drilldown(uuid,text,uuid,uuid,date,date,integer,integer),
  public.bi_start_network_export(uuid,text,jsonb) to authenticated;
