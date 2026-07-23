-- Normalize the optional readiness filter without changing the public RPC.
alter function public.list_pos_assortment_readiness(uuid,uuid,text,text,integer,integer,timestamptz)
  rename to list_pos_assortment_readiness_before_status_normalization;

revoke all on function public.list_pos_assortment_readiness_before_status_normalization(uuid,uuid,text,text,integer,integer,timestamptz)
  from public, anon, authenticated;

create function public.list_pos_assortment_readiness(
  p_company_id uuid,
  p_assortment_id uuid,
  p_query text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_at timestamptz default now()
) returns jsonb
language sql stable security definer set search_path=public
as $$
  select public.list_pos_assortment_readiness_before_status_normalization(
    p_company_id,
    p_assortment_id,
    p_query,
    case when nullif(lower(trim(coalesce(p_status,''))), '') is null then 'all' else p_status end,
    p_page,
    p_page_size,
    p_at
  )
$$;

revoke all on function public.list_pos_assortment_readiness(uuid,uuid,text,text,integer,integer,timestamptz)
  from public, anon;
grant execute on function public.list_pos_assortment_readiness(uuid,uuid,text,text,integer,integer,timestamptz)
  to authenticated;

-- PostgreSQL has no max(uuid). Preserve keyset pagination by selecting the
-- last UUID in the same deterministic order used by the page.
create or replace function public.backfill_inventory_opening_balances(
  p_company_id uuid,
  p_after_snapshot_item_id uuid default null,
  p_page_size integer default 1000
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_size integer := least(greatest(coalesce(p_page_size,1000),1),5000);
  v_processed integer := 0;
  v_next_cursor uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_locations') then
    raise exception 'No autorizado para inicializar inventario operativo.';
  end if;
  with latest_snapshot_per_location as (
    select distinct on (item.location_id) item.location_id,snapshot.id snapshot_id
    from public.inventory_snapshot_items item
    join public.inventory_snapshots snapshot on snapshot.id=item.snapshot_id
    where snapshot.company_id=p_company_id and snapshot.status='completed'
    order by item.location_id,snapshot.snapshot_date desc nulls last,snapshot.created_at desc
  ), paged as materialized (
    select item.id,item.location_id,item.product_id,coalesce(item.available_quantity,item.quantity) quantity
    from public.inventory_snapshot_items item
    join latest_snapshot_per_location latest on latest.snapshot_id=item.snapshot_id
    where p_after_snapshot_item_id is null or item.id>p_after_snapshot_item_id
    order by item.id limit v_size
  ), inserted as (
    insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,source_snapshot_item_id,actor_id)
    select p_company_id,paged.location_id,paged.product_id,paged.quantity,paged.quantity,'opening_snapshot',paged.id,auth.uid()
    from paged where paged.quantity>0
    on conflict (source_snapshot_item_id) where source_snapshot_item_id is not null do nothing
    returning location_id,product_id,quantity_delta
  ), applied as (
    insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand)
    select p_company_id,location_id,product_id,quantity_delta from inserted
    on conflict (location_id,product_id) do update
      set quantity_on_hand=public.inventory_balances.quantity_on_hand+excluded.quantity_on_hand,updated_at=now()
    returning 1
  )
  select
    (select count(*) from paged),
    (select id from paged order by id desc limit 1)
  into v_processed,v_next_cursor;
  perform public.write_sales_audit(p_company_id,'inventory.opening_backfilled','inventory_ledger',null,jsonb_build_object('processed',v_processed,'next_cursor',v_next_cursor));
  return jsonb_build_object('processed',coalesce(v_processed,0),'next_snapshot_item_id',v_next_cursor,'complete',v_processed<v_size);
end $$;

revoke all on function public.backfill_inventory_opening_balances(uuid,uuid,integer) from public,anon;
grant execute on function public.backfill_inventory_opening_balances(uuid,uuid,integer) to authenticated;
