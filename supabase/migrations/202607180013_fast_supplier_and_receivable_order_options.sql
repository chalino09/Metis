-- Satrapy · opciones ligeras para selectores operativos de Compras.
-- Los selectores no cargan perfiles completos ni calculan totales que no utilizan.

create index if not exists suppliers_code_trgm_idx
  on public.suppliers using gin (lower(code) extensions.gin_trgm_ops);
create index if not exists suppliers_tax_id_trgm_idx
  on public.suppliers using gin (lower(coalesce(tax_id,'')) extensions.gin_trgm_ops);

create or replace function public.search_supplier_options(
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
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_suppliers') then
    raise exception 'No autorizado para consultar proveedores.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('id',x.id,'code',x.code,'display_name',x.display_name,'tax_id',x.tax_id)
      order by x.rank,x.display_name,x.id
    ),
    '[]'::jsonb
  )
  into v_items
  from (
    select
      s.id,
      s.code,
      s.display_name,
      s.tax_id,
      case
        when v_query<>'' and lower(s.code)=v_query then 0
        when v_query<>'' and lower(coalesce(s.tax_id,''))=v_query then 0
        else 1
      end as rank
    from public.suppliers s
    where s.company_id=p_company_id
      and s.is_active=true
      and (
        v_query=''
        or lower(s.code) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
        or lower(coalesce(s.tax_id,'')) like '%'||v_query||'%'
      )
    order by rank,s.display_name,s.id
    limit v_limit
  ) x;

  return jsonb_build_object('items',v_items);
end
$$;

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

revoke all on function public.search_supplier_options(uuid,text,integer) from public,anon;
revoke all on function public.search_receivable_purchase_order_options(uuid,text,integer) from public,anon;
grant execute on function public.search_supplier_options(uuid,text,integer) to authenticated;
grant execute on function public.search_receivable_purchase_order_options(uuid,text,integer) to authenticated;
