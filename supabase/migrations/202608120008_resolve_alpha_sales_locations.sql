-- Resolve Alpha sales abbreviations from the dominant code/warehouse pairing
-- inside each batch. No company-specific aliases or new locations are created.
-- The temporary resolution set avoids repeated scans of large JSON staging rows.

create index if not exists import_staging_errors_batch_row_idx
  on public.import_staging_errors(import_batch_id,staging_row_id);

create temp table alpha_sales_location_resolution on commit drop as
with pair_counts as (
  select r.import_batch_id,
    upper(trim(r.normalized_data->>'locationCode')) source_code,
    upper(trim(r.normalized_data->>'warehouseName')) warehouse_name,
    count(*) total
  from public.import_staging_rows r
  join public.import_batches b on b.id=r.import_batch_id
  where b.import_type='sales' and b.status in ('staged','validation_failed')
    and r.normalized_data->>'evidenceKind'='sale_line'
    and nullif(trim(r.normalized_data->>'locationCode'),'') is not null
    and nullif(trim(r.normalized_data->>'warehouseName'),'') is not null
  group by 1,2,3
), dominant as (
  select distinct on (import_batch_id,source_code)
    import_batch_id,source_code,warehouse_name
  from pair_counts
  order by import_batch_id,source_code,total desc,warehouse_name
)
select r.id row_id,r.import_batch_id,r.row_number,
  r.normalized_data->>'alphaSku' alpha_sku,
  r.normalized_data->>'locationCode' original_location_code,
  r.normalized_data->>'warehouseName' original_warehouse_name,
  d.source_code,d.warehouse_name dominant_warehouse,
  upper(trim(r.normalized_data->>'warehouseName')) row_warehouse,
  l.id location_id,l.external_code canonical_location_code
from public.import_staging_rows r
join dominant d on d.import_batch_id=r.import_batch_id
  and d.source_code=upper(trim(r.normalized_data->>'locationCode'))
join public.import_batches b on b.id=r.import_batch_id
left join lateral (
  select candidate.id,candidate.external_code
  from public.locations candidate
  where candidate.company_id=b.company_id and candidate.is_active
    and (upper(trim(candidate.external_code))=d.warehouse_name or upper(trim(candidate.name))=d.warehouse_name)
  order by (upper(trim(candidate.external_code))=d.warehouse_name) desc,candidate.id
  limit 1
) l on true
where r.normalized_data->>'evidenceKind'='sale_line';

create unique index alpha_sales_location_resolution_row_idx
  on alpha_sales_location_resolution(row_id);
create index alpha_sales_location_resolution_batch_idx
  on alpha_sales_location_resolution(import_batch_id);

update public.import_staging_rows r
set normalized_data=r.normalized_data || jsonb_build_object(
  'canonicalLocationId',x.location_id,
  'canonicalLocationCode',x.canonical_location_code
)
from alpha_sales_location_resolution x
where r.id=x.row_id and x.location_id is not null
  and x.row_warehouse=x.dominant_warehouse
  and r.normalized_data->>'canonicalLocationId' is distinct from x.location_id::text;

-- Delete by indexed batch/error columns. The previous row-by-row OR join was
-- quadratic for 31k rows and could exceed the SQL Editor request timeout.
delete from public.import_staging_errors e
where e.error_code in ('UBICACION_DESCONOCIDA','UBICACION_CONFLICTO')
  and exists (
    select 1 from alpha_sales_location_resolution x
    where x.import_batch_id=e.import_batch_id
  );

insert into public.import_staging_errors(
  import_batch_id,staging_row_id,severity,error_code,message,row_number,alpha_sku,location_code
)
select x.import_batch_id,x.row_id,'warning','UBICACION_CONFLICTO',
  format('La abreviatura %s normalmente corresponde a %s; esta fila declara %s. Requiere revisión.',
    x.source_code,x.dominant_warehouse,x.original_warehouse_name),
  x.row_number,x.alpha_sku,x.original_location_code
from alpha_sales_location_resolution x
where x.row_warehouse<>x.dominant_warehouse;

insert into public.import_staging_errors(
  import_batch_id,staging_row_id,severity,error_code,message,row_number,alpha_sku,location_code
)
select x.import_batch_id,x.row_id,'warning','UBICACION_DESCONOCIDA',
  format('La sucursal %s no coincide con una ubicación canónica; la venta queda como evidencia en staging.',x.source_code),
  x.row_number,x.alpha_sku,x.original_location_code
from alpha_sales_location_resolution x
where x.row_warehouse=x.dominant_warehouse and x.location_id is null;

select public.refresh_import_staging_batch(batch_id,false)
from (select distinct import_batch_id batch_id from alpha_sales_location_resolution) batches;

insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select b.company_id,b.imported_by,'sales_evidence.locations_resolved','import_batch',b.id,
  jsonb_build_object(
    'method','dominant_source_code_warehouse_pair','created_locations',0,
    'resolved_rows',count(*) filter(where x.location_id is not null and x.row_warehouse=x.dominant_warehouse),
    'conflict_rows',count(*) filter(where x.row_warehouse<>x.dominant_warehouse),
    'unknown_rows',count(*) filter(where x.row_warehouse=x.dominant_warehouse and x.location_id is null)
  )
from alpha_sales_location_resolution x
join public.import_batches b on b.id=x.import_batch_id
group by b.id,b.company_id,b.imported_by;

select
  count(*) filter(where location_id is not null and row_warehouse=dominant_warehouse) resolved_rows,
  count(*) filter(where row_warehouse<>dominant_warehouse) conflict_rows,
  count(*) filter(where row_warehouse=dominant_warehouse and location_id is null) unknown_rows
from alpha_sales_location_resolution;
