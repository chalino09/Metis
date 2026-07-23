-- Satrapy · Corrección de vendibilidad importada y clasificación de sucursales
-- El catálogo maestro define productos comerciales; readiness decide si pueden
-- venderse ahora y el surtido conserva la pertenencia comercial.

create or replace function public.sync_product_commercial_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit uuid;
  v_category uuid;
  v_type text := lower(coalesce(new.product_type, ''));
begin
  if nullif(trim(coalesce(new.unit, '')), '') is not null then
    insert into public.units_of_measure(company_id, code, name)
    values (new.company_id, trim(new.unit), trim(new.unit))
    on conflict(company_id, code) do update set name = excluded.name
    returning id into v_unit;
    if v_unit is null then
      select id into v_unit from public.units_of_measure
      where company_id = new.company_id and code = trim(new.unit);
    end if;
  end if;

  if nullif(trim(coalesce(new.alpha_class, '')), '') is not null then
    insert into public.product_categories(company_id, external_code, name)
    values (new.company_id, trim(new.alpha_class), trim(new.alpha_class))
    on conflict(company_id, external_code) do update set name = excluded.name
    returning id into v_category;
    if v_category is null then
      select id into v_category from public.product_categories
      where company_id = new.company_id and external_code = trim(new.alpha_class);
    end if;
  end if;

  update public.products
  set
    base_unit_id = coalesce(v_unit, base_unit_id),
    sales_unit_id = coalesce(v_unit, sales_unit_id),
    category_id = coalesce(v_category, category_id),
    is_active = v_type <> 'eliminados',
    is_inventory_tracked = v_type = 'p. terminado'
  where id = new.id;

  return new;
end;
$$;

-- Apply canonical import rules after a successful promotion. This keeps Alpha
-- at the import boundary and avoids record-by-record repair.
create or replace function public.apply_completed_import_canonical_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  if new.status <> 'completed' or old.status = 'completed' then
    return new;
  end if;

  if new.import_type = 'products' then
    update public.products product
    set
      is_sellable = product.is_active,
      commercial_review_required = false,
      updated_at = now()
    where product.company_id = new.company_id
      and exists (
        select 1
        from public.import_staging_rows staged
        where staged.import_batch_id = new.id
          and staged.detected_type = 'products'
          and coalesce((staged.normalized_data ->> 'rejected')::boolean, false) = false
          and staged.normalized_data ->> 'alphaSku' = product.alpha_sku
      );
    get diagnostics v_updated = row_count;

    insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
    values (new.company_id, new.imported_by, 'product.sellability_import_applied', 'import_batches', new.id,
      jsonb_build_object('products_processed', v_updated, 'rule', 'accepted_active_catalog_product'));

  elsif new.import_type = 'inventory' then
    update public.locations location
    set
      location_type = staged.location_type,
      classification_source = 'alpha_rule',
      classification_reviewed_at = now(),
      classification_reviewed_by = null,
      updated_at = now()
    from (
      select distinct on (normalized_data ->> 'locationCode')
        normalized_data ->> 'locationCode' as external_code,
        normalized_data ->> 'locationType' as location_type
      from public.import_staging_rows
      where import_batch_id = new.id
        and detected_type = 'inventory'
        and coalesce((normalized_data ->> 'rejected')::boolean, false) = false
        and normalized_data ->> 'classificationSource' = 'alpha_rule'
        and normalized_data ->> 'locationType' in ('sucursal', 'almacen_central', 'almacen_operativo', 'campo')
      order by normalized_data ->> 'locationCode'
    ) staged
    where location.company_id = new.company_id
      and location.external_code = staged.external_code
      and location.location_type = 'pendiente_revision';
    get diagnostics v_updated = row_count;

    if v_updated > 0 then
      insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
      values (new.company_id, new.imported_by, 'location.pending_classification_repaired', 'import_batches', new.id,
        jsonb_build_object('locations_updated', v_updated, 'source', 'alpha_rule'));
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists import_batches_apply_canonical_rules on public.import_batches;
create trigger import_batches_apply_canonical_rules
  after update of status on public.import_batches
  for each row execute function public.apply_completed_import_canonical_rules();

-- One-time product correction for successful product imports already promoted.
insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
select
  product.company_id,
  null,
  'product.sellability_rule_corrected',
  'products',
  null,
  jsonb_build_object(
    'products_updated', count(*),
    'active_sellable', count(*) filter (where product.is_active),
    'inactive_not_sellable', count(*) filter (where not product.is_active),
    'rule', 'accepted_active_catalog_product'
  )
from public.products product
where exists (
    select 1
    from public.import_staging_rows staged
    join public.import_batches batch on batch.id = staged.import_batch_id
    where batch.company_id = product.company_id
      and batch.import_type = 'products'
      and batch.status = 'completed'
      and staged.detected_type = 'products'
      and coalesce((staged.normalized_data ->> 'rejected')::boolean, false) = false
      and staged.normalized_data ->> 'alphaSku' = product.alpha_sku
  )
  and (product.is_sellable is distinct from product.is_active or product.commercial_review_required)
group by product.company_id;

update public.products product
set
  is_sellable = product.is_active,
  commercial_review_required = false,
  updated_at = now()
where exists (
    select 1
    from public.import_staging_rows staged
    join public.import_batches batch on batch.id = staged.import_batch_id
    where batch.company_id = product.company_id
      and batch.import_type = 'products'
      and batch.status = 'completed'
      and staged.detected_type = 'products'
      and coalesce((staged.normalized_data ->> 'rejected')::boolean, false) = false
      and staged.normalized_data ->> 'alphaSku' = product.alpha_sku
  )
  and (product.is_sellable is distinct from product.is_active or product.commercial_review_required);

-- Repair only pending locations that match the same deterministic SUC rule
-- already used by the current Alpha parser. No company-specific names are coded.
insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
select
  location.company_id,
  null,
  'location.pending_classification_repaired',
  'locations',
  null,
  jsonb_build_object('locations_updated', count(*), 'rule', 'word_suc_or_sucursal')
from public.locations location
where location.location_type = 'pendiente_revision'
  and lower(location.external_code || ' ' || location.name) ~ '(^|[^a-z])suc(ursal)?([^a-z]|$)'
group by location.company_id;

update public.locations
set
  location_type = 'sucursal',
  classification_source = 'migration_rule',
  classification_reviewed_at = now(),
  classification_reviewed_by = null,
  updated_at = now()
where location_type = 'pendiente_revision'
  and lower(external_code || ' ' || name) ~ '(^|[^a-z])suc(ursal)?([^a-z]|$)';

revoke all on function public.apply_completed_import_canonical_rules() from public;
