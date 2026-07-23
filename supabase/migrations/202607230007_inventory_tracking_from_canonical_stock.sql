-- Reconcile inventory tracking from canonical operational evidence.
-- This is set-based, transactional and does not modify branch assortment.

with inventory_candidates as materialized (
  select p.id, p.company_id
  from public.products p
  where not p.is_inventory_tracked
    and (
      exists (
        select 1
        from public.inventory_balances ib
        where ib.company_id = p.company_id
          and ib.product_id = p.id
      )
      or exists (
        select 1
        from public.inventory_ledger il
        where il.company_id = p.company_id
          and il.product_id = p.id
      )
      or exists (
        select 1
        from public.inventory_snapshot_items isi
        join public.inventory_snapshots ins on ins.id = isi.snapshot_id
        where ins.company_id = p.company_id
          and isi.product_id = p.id
          and ins.status = 'completed'
      )
    )
),
updated_products as (
  update public.products p
  set is_inventory_tracked = true,
      updated_at = now()
  from inventory_candidates candidate
  where p.id = candidate.id
    and p.company_id = candidate.company_id
  returning p.id, p.company_id
)
insert into public.audit_log (
  company_id,
  actor_id,
  action,
  entity_type,
  entity_id,
  metadata
)
select
  company_id,
  null,
  'inventory.tracking_reconciled',
  'products',
  null,
  jsonb_build_object(
    'product_count', count(*),
    'evidence', 'canonical_inventory',
    'scope', 'company'
  )
from updated_products
group by company_id;

create or replace function public.track_products_from_new_inventory_balances()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  with updated_products as (
    update public.products p
    set is_inventory_tracked = true,
        updated_at = now()
    from (
      select distinct company_id, product_id
      from new_inventory_rows
    ) row_evidence
    where p.company_id = row_evidence.company_id
      and p.id = row_evidence.product_id
      and not p.is_inventory_tracked
    returning p.id, p.company_id
  )
  insert into public.audit_log (
    company_id,
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  select
    company_id,
    auth.uid(),
    'inventory.tracking_enabled',
    'products',
    null,
    jsonb_build_object(
      'product_count', count(*),
      'evidence', 'inventory_balance_insert',
      'scope', 'statement'
    )
  from updated_products
  group by company_id;

  return null;
end;
$$;

drop trigger if exists inventory_balances_track_products on public.inventory_balances;
create trigger inventory_balances_track_products
after insert on public.inventory_balances
referencing new table as new_inventory_rows
for each statement
execute function public.track_products_from_new_inventory_balances();

revoke all on function public.track_products_from_new_inventory_balances() from public, anon, authenticated;
