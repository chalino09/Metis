-- Read-only installation check for POS preflight migrations 011 and 012.
-- This query does not create, update, or delete any data.
select
  to_regclass('public.product_external_references') is not null
    as migration_011_product_references,
  to_regclass('public.location_external_references') is not null
    as migration_011_location_references,
  to_regclass('public.sales_assortments') is not null
    as migration_011_assortments,
  to_regprocedure(
    'public.product_pos_readiness_detail(uuid,uuid,uuid,timestamp with time zone)'
  ) is not null
    as migration_011_readiness,
  to_regprocedure(
    'public.validate_pos_product_for_location(uuid,uuid,uuid,timestamp with time zone)'
  ) is not null
    as migration_011_pos_validation,
  exists (
    select 1
    from pg_proc procedure_data
    where procedure_data.oid = to_regprocedure(
      'public.search_pos_products(uuid,uuid,text,integer,integer,timestamp with time zone)'
    )
      and procedure_data.prosrc like '%''product_id'', paged.id%'
      and procedure_data.prosrc not like '%''product_id'', eligible_products.id%'
  ) as migration_012_search_fix;
