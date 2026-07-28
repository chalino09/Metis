-- Satrapy BI · Red de abastecimiento: panorama ejecutivo por proveedor.
-- Agrega en servidor; nunca construye un resumen a partir de una subred truncada.

create or replace function public.bi_supplier_dependency_overview(
  p_company_id uuid,p_date_from date,p_date_to date,
  p_location_id uuid default null,p_category_id uuid default null,p_supplier_id uuid default null,p_product_id uuid default null,
  p_concentration_level text default null,p_page integer default 1,p_page_size integer default 24
) returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,24),1),50);
  v_total bigint:=0;v_amount numeric:=0;v_products bigint:=0;v_high bigint:=0;v_unique bigint:=0;
  v_items jsonb:='[]'::jsonb;v_currency text;v_updated timestamptz;
begin
  perform public.bi_assert_network_scope(p_company_id,p_location_id,p_category_id,p_supplier_id,p_product_id);
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from>731 then
    raise exception 'Periodo inválido; la red admite hasta 732 días.';
  end if;
  if p_concentration_level is not null and p_concentration_level not in('low','medium','high')then
    raise exception 'Nivel de concentración inválido.';
  end if;

  select c.base_currency into v_currency from public.accounting_config_versions c
  where c.company_id=p_company_id and c.status='approved';

  with
  receipt_evidence as materialized(
    select pr.supplier_id,rl.product_id,sum(rl.line_cost)amount,sum(rl.quantity)quantity,count(distinct pr.id)frequency,
      min(pr.receipt_date)first_at,max(pr.receipt_date)last_at
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
      min(po.ordered_date)first_at,max(po.ordered_date)last_at
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
      sum(al.awarded_quantity)quantity,count(distinct a.id)frequency,min(a.decided_at::date)first_at,max(a.decided_at::date)last_at
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
      sum(ql.available_quantity)quantity,count(distinct q.id)frequency,min(q.created_at::date)first_at,max(q.created_at::date)last_at
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
    select ep.supplier_id,ep.product_id,s.display_name supplier_label,s.code supplier_code,p.name product_label,p.internal_sku product_sku,
      case when r.supplier_id is not null then r.amount when o.supplier_id is not null then o.amount when a.supplier_id is not null then a.amount else q.amount end amount,
      case when r.supplier_id is not null then r.quantity when o.supplier_id is not null then o.quantity when a.supplier_id is not null then a.quantity else q.quantity end quantity,
      case when r.supplier_id is not null then r.frequency when o.supplier_id is not null then o.frequency when a.supplier_id is not null then a.frequency else q.frequency end frequency,
      case when r.supplier_id is not null then'confirmed_receipt'when o.supplier_id is not null then'approved_order'
        when a.supplier_id is not null then'approved_award'else'received_quote'end metric_source
    from evidence_pairs ep join public.suppliers s on s.id=ep.supplier_id join public.products p on p.id=ep.product_id
    left join receipt_evidence r on r.supplier_id=ep.supplier_id and r.product_id=ep.product_id
    left join order_evidence o on o.supplier_id=ep.supplier_id and o.product_id=ep.product_id
    left join award_evidence a on a.supplier_id=ep.supplier_id and a.product_id=ep.product_id
    left join quote_evidence q on q.supplier_id=ep.supplier_id and q.product_id=ep.product_id
    where s.company_id=p_company_id and p.company_id=p_company_id
  ),
  concentration as materialized(
    select sp.*,sp.amount/nullif(sum(sp.amount)over(partition by sp.product_id),0)concentration_share,
      count(*)over(partition by sp.product_id) supplier_count
    from supplier_product sp
  ),
  scoped_products as materialized(
    select *,case when concentration_share>=.8 then'high'when concentration_share>=.5 then'medium'else'low'end concentration_level
    from concentration
    where p_concentration_level is null or case when concentration_share>=.8 then'high'when concentration_share>=.5 then'medium'else'low'end=p_concentration_level
  ),
  product_locations as materialized(
    select distinct sp.supplier_id,sp.product_id,l.id location_id
    from scoped_products sp join public.sales_assortment_items sai on sai.product_id=sp.product_id
    join public.sales_assortments sa on sa.id=sai.assortment_id
    join public.location_sales_assortments lsa on lsa.assortment_id=sa.id join public.locations l on l.id=lsa.location_id
    where sa.status='active'and public.can_access_location(l.id)and(p_location_id is null or l.id=p_location_id)
      and tstzrange(coalesce(sa.valid_from,'-infinity'),coalesce(sa.valid_to,'infinity'),'[)')&&tstzrange(p_date_from::timestamptz,(p_date_to+1)::timestamptz,'[)')
      and tstzrange(lsa.valid_from,coalesce(lsa.valid_to,'infinity'),'[)')&&tstzrange(p_date_from::timestamptz,(p_date_to+1)::timestamptz,'[)')
  ),
  supplier_locations as materialized(
    select supplier_id,count(distinct location_id)::bigint location_count from product_locations group by supplier_id
  ),
  ranked_products as materialized(
    select sp.*,row_number()over(partition by supplier_id order by amount desc nulls last,product_label,product_id)product_rank
    from scoped_products sp
  ),
  top_products as materialized(
    select supplier_id,jsonb_agg(jsonb_build_object('product_id',product_id,'label',product_label,'sku',product_sku,'amount',amount,
      'concentration',concentration_share,'supplier_count',supplier_count,'metric_source',metric_source)order by amount desc nulls last,product_label,product_id)top_products
    from ranked_products where product_rank<=5 group by supplier_id
  ),
  supplier_rows as materialized(
    select sp.supplier_id,sp.supplier_label,sp.supplier_code,coalesce(sum(sp.amount),0)total_amount,coalesce(sum(sp.quantity),0)total_quantity,
      coalesce(sum(sp.frequency),0)::bigint frequency,count(distinct sp.product_id)::bigint product_count,coalesce(sl.location_count,0)location_count,
      count(distinct sp.product_id)filter(where sp.supplier_count=1)::bigint unique_product_count,
      count(distinct sp.product_id)filter(where sp.concentration_share>=.8)::bigint high_dependency_product_count,
      coalesce(max(sp.concentration_share),0)max_concentration,coalesce(tp.top_products,'[]'::jsonb)top_products,
      count(distinct sp.product_id)filter(where sp.supplier_count=1)*1000000+
        count(distinct sp.product_id)filter(where sp.concentration_share>=.8)*10000+coalesce(sum(sp.amount),0)/1000 risk_score
    from scoped_products sp left join supplier_locations sl on sl.supplier_id=sp.supplier_id left join top_products tp on tp.supplier_id=sp.supplier_id
    group by sp.supplier_id,sp.supplier_label,sp.supplier_code,sl.location_count,tp.top_products
  ),
  paged as materialized(
    select * from supplier_rows order by risk_score desc,total_amount desc,supplier_label,supplier_id limit v_size offset(v_page-1)*v_size
  )
  select
    (select count(*)from supplier_rows),(select coalesce(sum(total_amount),0)from supplier_rows),
    (select coalesce(sum(product_count),0)from supplier_rows),(select coalesce(sum(high_dependency_product_count),0)from supplier_rows),
    (select coalesce(sum(unique_product_count),0)from supplier_rows),
    (select coalesce(jsonb_agg(jsonb_build_object('supplier_id',supplier_id,'label',supplier_label,'code',supplier_code,'total_amount',total_amount,
      'total_quantity',total_quantity,'frequency',frequency,'product_count',product_count,'location_count',location_count,
      'unique_product_count',unique_product_count,'high_dependency_product_count',high_dependency_product_count,
      'max_concentration',max_concentration,'top_products',top_products)order by risk_score desc,total_amount desc,supplier_label,supplier_id),'[]'::jsonb)from paged)
  into v_total,v_amount,v_products,v_high,v_unique,v_items;

  select greatest(
    coalesce((select max(updated_at)from public.purchase_receipts where company_id=p_company_id),'epoch'),
    coalesce((select max(updated_at)from public.purchase_orders where company_id=p_company_id),'epoch'),
    coalesce((select max(updated_at)from public.products where company_id=p_company_id),'epoch')
  )into v_updated;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(
    p_company_id,auth.uid(),'bi.supplier_dependency_overview_queried','bi_dependency_network',
    jsonb_build_object('from',p_date_from,'to',p_date_to,'page',v_page,'page_size',v_size,'location_id',p_location_id,'supplier_id',p_supplier_id)
  );
  return jsonb_build_object(
    'items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'totals',jsonb_build_object('suppliers',v_total,'amount',v_amount,'products',v_products,'high_dependency_products',v_high,'unique_supplier_products',v_unique),
    'currency_code',v_currency,'updated_at',v_updated,'period',jsonb_build_object('from',p_date_from,'to',p_date_to),
    'methodology',jsonb_build_object(
      'amount','Para cada proveedor-producto se usa una sola fuente: recepción confirmada; si falta, orden aprobada, adjudicación aprobada o cotización recibida.',
      'dependency','Alta dependencia: el proveedor aporta ≥80% del importe comprobado de un producto. Proveedor único: existe una sola relación proveedor-producto dentro del filtro.',
      'coverage','Ubicaciones muestra la cobertura por surtido comercial activo; readiness no modifica el surtido.'
    ),
    'trace',jsonb_build_object('query','bi_supplier_dependency_overview','company_id',p_company_id,'aggregation','supplier','page',v_page,'page_size',v_size)
  );
end $$;

revoke all on function public.bi_supplier_dependency_overview(uuid,date,date,uuid,uuid,uuid,uuid,text,integer,integer) from public;
grant execute on function public.bi_supplier_dependency_overview(uuid,date,date,uuid,uuid,uuid,uuid,text,integer,integer) to authenticated;
