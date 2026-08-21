-- Ordena cotizaciones y órdenes por la fecha que el usuario ve en la tabla.
-- La fecha de creación sólo desempata documentos con la misma fecha visible.

create or replace function public.search_procurement_documents(
  p_company_id uuid,
  p_query text default null,
  p_document_type text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_can_view_quotes boolean:=public.has_company_permission(p_company_id,'view_procurement');
  v_can_view_orders boolean:=public.has_company_permission(p_company_id,'view_purchase_orders');
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not (v_can_view_quotes or v_can_view_orders) then
    raise exception 'No autorizado para consultar cotizaciones u órdenes.';
  end if;
  if p_document_type is not null and p_document_type not in ('quote','order') then
    raise exception 'Tipo de documento inválido.';
  end if;

  with documents as (
    select
      quote.id,
      'quote'::text document_type,
      requisition.folio reference,
      ('Cotización de '||supplier.display_name)::text reference_note,
      ('quote_'||quote.status)::text status_code,
      requisition.source::text origin_code,
      supplier.id supplier_id,
      supplier.code supplier_code,
      supplier.display_name supplier_name,
      quote.currency_code,
      quote.created_at::date document_date,
      quote.created_at created_at,
      quote_totals.expected_date,
      quote.valid_until,
      coalesce(quote_totals.total,0)::numeric total,
      requisition.id requisition_id,
      requisition.folio requisition_folio
    from public.procurement_quotes quote
    join public.procurement_requisitions requisition on requisition.id=quote.requisition_id and requisition.company_id=quote.company_id
    join public.suppliers supplier on supplier.id=quote.supplier_id and supplier.company_id=quote.company_id
    left join lateral (
      select
        min(quote_line.expected_date) expected_date,
        sum(
          requisition_line.required_quantity
          * quote_line.unit_price
          * (1-(quote_line.commercial_discount_percent/100))
        ) total
      from public.procurement_quote_lines quote_line
      join public.procurement_requisition_lines requisition_line
        on requisition_line.id=quote_line.requisition_line_id and requisition_line.company_id=quote.company_id
      where quote_line.quote_id=quote.id and quote_line.company_id=quote.company_id
    ) quote_totals on true
    where quote.company_id=p_company_id and v_can_view_quotes

    union all

    select
      purchase_order.id,
      'order'::text document_type,
      purchase_order.folio reference,
      coalesce(purchase_order.supplier_reference,purchase_order.requisition_reference,'Sin referencia') reference_note,
      ('order_'||purchase_order.status)::text status_code,
      purchase_order.origin::text origin_code,
      supplier.id supplier_id,
      supplier.code supplier_code,
      supplier.display_name supplier_name,
      purchase_order.currency_code,
      purchase_order.ordered_date document_date,
      purchase_order.created_at created_at,
      purchase_order.expected_date,
      null::date valid_until,
      purchase_order.total,
      requisition.id requisition_id,
      coalesce(requisition.folio,purchase_order.requisition_reference) requisition_folio
    from public.purchase_orders purchase_order
    join public.suppliers supplier on supplier.id=purchase_order.supplier_id and supplier.company_id=purchase_order.company_id
    left join public.procurement_purchase_orders procurement_order
      on procurement_order.purchase_order_id=purchase_order.id and procurement_order.company_id=purchase_order.company_id
    left join public.procurement_awards award
      on award.id=procurement_order.procurement_award_id and award.company_id=purchase_order.company_id
    left join public.procurement_requisitions requisition
      on requisition.id=award.requisition_id and requisition.company_id=purchase_order.company_id
    where purchase_order.company_id=p_company_id and v_can_view_orders
  ), filtered as materialized (
    select *
    from documents
    where (p_document_type is null or document_type=p_document_type)
      and (p_status is null or status_code=p_status)
      and (
        v_query=''
        or lower(reference) like '%'||v_query||'%'
        or lower(reference_note) like '%'||v_query||'%'
        or lower(supplier_code) like '%'||v_query||'%'
        or lower(supplier_name) like '%'||v_query||'%'
        or lower(coalesce(requisition_folio,'')) like '%'||v_query||'%'
      )
  ), paged as (
    select *
    from filtered
    order by document_date desc nulls last,created_at desc,id desc
    limit v_size offset (v_page-1)*v_size
  )
  select
    (select count(*) from filtered),
    coalesce(jsonb_agg(to_jsonb(paged)-'created_at' order by document_date desc nulls last,created_at desc,id desc),'[]'::jsonb)
  into v_total,v_items
  from paged;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0))
  );
end $$;

revoke all on function public.search_procurement_documents(uuid,text,text,text,integer,integer) from public,anon;
grant execute on function public.search_procurement_documents(uuid,text,text,text,integer,integer) to authenticated;
