-- Read-only installation check for migration 202607120013.
-- This query does not create, update, or delete data.
select
  to_regprocedure(
    'public.prepare_pos_pilot(uuid,text,text,uuid[],timestamp with time zone)'
  ) is not null as migration_013_prepare_pilot,
  to_regprocedure(
    'public.refresh_pos_assortment_catalog(uuid,uuid,timestamp with time zone)'
  ) is not null as migration_013_refresh_catalog,
  to_regprocedure(
    'public.list_pos_assortment_readiness(uuid,uuid,text,text,integer,integer,timestamp with time zone)'
  ) is not null as migration_013_readiness_list,
  to_regprocedure(
    'public.get_pos_catalog_readiness_summary(uuid,uuid,timestamp with time zone)'
  ) is not null as migration_013_catalog_summary,
  exists (
    select 1
    from pg_proc procedure_data
    where procedure_data.oid = to_regprocedure(
      'public.enforce_sales_assortment_activation()'
    )
      and procedure_data.prosrc like '%sin sucursales asignadas%'
      and procedure_data.prosrc not like '%productos no están listos%'
  ) as migration_013_activation_policy;
