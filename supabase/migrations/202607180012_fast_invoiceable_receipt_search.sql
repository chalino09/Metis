-- Satrapy · búsqueda rápida de recepciones facturables.
-- Mantiene el contrato paginado y calcula cada saldo facturable una sola vez
-- por consulta, aun cuando la recepción tenga varias partidas o facturas.

create index if not exists purchase_receipts_folio_trgm_idx
  on public.purchase_receipts using gin (lower(folio) extensions.gin_trgm_ops);
create index if not exists purchase_orders_folio_trgm_idx
  on public.purchase_orders using gin (lower(folio) extensions.gin_trgm_ops);
create index if not exists suppliers_display_name_trgm_idx
  on public.suppliers using gin (lower(display_name) extensions.gin_trgm_ops);

create or replace function public.search_invoiceable_receipts(
  p_company_id uuid,
  p_query text default null,
  p_supplier_id uuid default null,
  p_purchase_order_id uuid default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'view_supplier_invoices')
    or public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts')
  ) then
    raise exception 'No autorizado para consultar recepciones facturables.';
  end if;

  with line_balances as materialized (
    select
      pr.id,
      pr.folio as receipt_folio,
      pr.receipt_date,
      po.id as purchase_order_id,
      po.folio as purchase_order_folio,
      po.currency_code,
      s.id as supplier_id,
      s.code as supplier_code,
      s.display_name as supplier_name,
      prl.id as purchase_receipt_line_id,
      prl.quantity as received_quantity,
      coalesce(sum(sil.quantity) filter (where si.id is not null),0) as invoiced_quantity
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id=pr.purchase_order_id
    join public.suppliers s on s.id=pr.supplier_id
    join public.purchase_receipt_lines prl on prl.purchase_receipt_id=pr.id
    left join public.supplier_invoice_lines sil on sil.purchase_receipt_line_id=prl.id
    left join public.supplier_invoices si
      on si.id=sil.supplier_invoice_id
     and si.company_id=p_company_id
     and si.status='confirmed'
    where pr.company_id=p_company_id
      and pr.status='confirmed'
      and po.status='approved'
      and po.origin='operational'
      and (p_supplier_id is null or s.id=p_supplier_id)
      and (p_purchase_order_id is null or po.id=p_purchase_order_id)
      and (
        v_query=''
        or lower(pr.folio) like '%'||v_query||'%'
        or lower(po.folio) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
      )
    group by
      pr.id,pr.folio,pr.receipt_date,
      po.id,po.folio,po.currency_code,
      s.id,s.code,s.display_name,
      prl.id,prl.quantity
  ),
  candidates as materialized (
    select distinct
      id,receipt_folio,receipt_date,purchase_order_id,purchase_order_folio,
      currency_code,supplier_id,supplier_code,supplier_name
    from line_balances
    where received_quantity>invoiced_quantity
  ),
  counted as (
    select count(*) as total from candidates
  ),
  paged as materialized (
    select *
    from candidates
    order by receipt_date,id
    limit v_size offset (v_page-1)*v_size
  )
  select
    counted.total,
    coalesce(
      (select jsonb_agg(to_jsonb(paged) order by receipt_date,id) from paged),
      '[]'::jsonb
    )
  into v_total,v_items
  from counted;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total)
  );
end
$$;

revoke all on function public.search_invoiceable_receipts(uuid,text,uuid,uuid,integer,integer) from public,anon;
grant execute on function public.search_invoiceable_receipts(uuid,text,uuid,uuid,integer,integer) to authenticated;
