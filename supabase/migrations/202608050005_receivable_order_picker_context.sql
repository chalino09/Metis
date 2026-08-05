-- Contexto operativo mínimo para distinguir órdenes al registrar una recepción.
create or replace function public.search_receivable_purchase_order_options(
  p_company_id uuid,
  p_query text default null,
  p_limit integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_limit integer:=least(greatest(coalesce(p_limit,30),1),50);
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'view_purchase_receipts')
    or public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts')
  ) then
    raise exception 'No autorizado para consultar OC recibibles.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.ordered_date,x.id),'[]'::jsonb)
  into v_items
  from (
    select
      po.id,
      po.folio,
      po.ordered_date,
      po.expected_date,
      po.total,
      po.currency_code,
      po.fulfillment_status,
      po.origin,
      s.code as supplier_code,
      s.display_name as supplier_name
    from public.purchase_orders po
    join public.suppliers s on s.id=po.supplier_id
    where po.company_id=p_company_id
      and po.status='approved'
      and po.fulfillment_status<>'fully_received'
      and (
        v_query=''
        or lower(po.folio) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
        or lower(s.code) like '%'||v_query||'%'
      )
    order by po.ordered_date,po.id
    limit v_limit
  ) x;

  return jsonb_build_object('items',v_items);
end
$$;
