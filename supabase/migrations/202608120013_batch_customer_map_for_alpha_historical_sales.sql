-- Resolve customer identities once per package. The former lateral lookup ran
-- the same identity search for every historical sale line, which exceeds the
-- interactive PostgREST budget on large Alpha exports.
create or replace function public.alpha_historical_sales_lines(p_import_batch_id uuid)
returns table(
  staging_row_id uuid,
  row_number integer,
  document_key text,
  sale_date date,
  source_folio text,
  source_invoice text,
  source_status text,
  source_customer_code text,
  source_customer_name text,
  location_id uuid,
  customer_id uuid,
  product_id uuid,
  product_code text,
  product_name text,
  unit_name text,
  quantity numeric,
  unit_price numeric,
  taxable_amount numeric,
  tax_amount numeric,
  total_amount numeric
)
language sql
stable
security definer
set search_path=public
as $$
  with batch as materialized (
    select company_id
    from public.import_batches
    where id=p_import_batch_id
  ), customer_candidates as materialized (
    select
      regexp_replace(linked.external_code,'^0+','','g') external_code,
      linked.customer_id,
      0 priority
    from public.alpha_customer_identity_links linked
    join batch on batch.company_id=linked.company_id
    where nullif(regexp_replace(linked.external_code,'^0+','','g'),'') is not null

    union all

    select
      regexp_replace(customer_data.alpha_external_code,'^0+','','g') external_code,
      customer_data.id customer_id,
      1 priority
    from public.customers customer_data
    join batch on batch.company_id=customer_data.company_id
    where nullif(regexp_replace(customer_data.alpha_external_code,'^0+','','g'),'') is not null
  ), customer_map as materialized (
    select distinct on (external_code) external_code,customer_id
    from customer_candidates
    order by external_code,priority,customer_id
  ), source_lines as materialized (
    select
      row_data.id,
      row_data.row_number,
      row_data.normalized_data,
      row_data.resolved_product_id,
      batch.company_id,
      regexp_replace(coalesce(row_data.normalized_data->>'customerExternalCode',''),'^0+','','g') normalized_customer_code,
      round(coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0),2) source_total,
      round(greatest(coalesce(
        nullif(row_data.normalized_data->>'taxAmount','')::numeric,
        nullif(row_data.normalized_data->>'discountAmount','')::numeric,
        coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0)
          - coalesce(nullif(row_data.normalized_data->>'unitPrice','')::numeric,0)
            * coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0),
        0
      ),0),2) source_tax
    from public.import_staging_rows row_data
    join batch on true
    where row_data.import_batch_id=p_import_batch_id
      and row_data.detected_type='sales'
      and row_data.normalized_data->>'evidenceKind'='sale_line'
      and coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0)>0
  )
  select
    source.id,
    source.row_number,
    encode(extensions.digest(concat_ws('|',
      source.normalized_data->>'saleDate',
      source.normalized_data->>'sourceFolio',
      upper(trim(coalesce(source.normalized_data->>'locationCode',''))),
      upper(trim(coalesce(source.normalized_data->>'warehouseName',''))),
      coalesce(source.normalized_customer_code,''),
      coalesce(source.normalized_data->>'sourceInvoice','')
    ),'sha256'),'hex'),
    nullif(source.normalized_data->>'saleDate','')::date,
    source.normalized_data->>'sourceFolio',
    nullif(source.normalized_data->>'sourceInvoice',''),
    nullif(source.normalized_data->>'sourceStatus',''),
    nullif(source.normalized_customer_code,''),
    nullif(source.normalized_data->>'customerName',''),
    nullif(source.normalized_data->>'canonicalLocationId','')::uuid,
    customer_map.customer_id,
    coalesce(source.resolved_product_id,product_data.id),
    coalesce(product_data.internal_sku,product_data.alpha_sku),
    product_data.name,
    coalesce(nullif(source.normalized_data->>'unit',''),product_data.unit),
    (source.normalized_data->>'quantity')::numeric,
    round(greatest(source.source_total-source.source_tax,0)
      /(source.normalized_data->>'quantity')::numeric,2),
    round(greatest(source.source_total-source.source_tax,0),2),
    least(source.source_tax,source.source_total),
    source.source_total
  from source_lines source
  left join public.products direct_product
    on direct_product.company_id=source.company_id
   and direct_product.alpha_sku=source.normalized_data->>'alphaSku'
  left join public.products product_data
    on product_data.id=coalesce(source.resolved_product_id,direct_product.id)
   and product_data.company_id=source.company_id
  left join customer_map
    on customer_map.external_code=nullif(source.normalized_customer_code,'');
$$;

revoke all on function public.alpha_historical_sales_lines(uuid) from public,anon,authenticated;

-- The preview only needs aggregate eligibility. Avoid constructing each
-- document hash and customer UUID before its final group-by.
create or replace function public.preview_alpha_historical_sales_promotion(p_import_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_result jsonb;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Este lote no contiene ventas históricas.'; end if;
  if auth.uid() is null or not (
    public.can_import_commercial(v_batch.company_id,'sales')
    or public.has_company_permission(v_batch.company_id,'view_import_audit')
  ) then raise exception 'No autorizado para revisar la promoción histórica.'; end if;

  with customer_codes as materialized (
    select regexp_replace(linked.external_code,'^0+','','g') external_code
    from public.alpha_customer_identity_links linked
    where linked.company_id=v_batch.company_id
      and nullif(regexp_replace(linked.external_code,'^0+','','g'),'') is not null
    union
    select regexp_replace(customer_data.alpha_external_code,'^0+','','g') external_code
    from public.customers customer_data
    where customer_data.company_id=v_batch.company_id
      and nullif(regexp_replace(customer_data.alpha_external_code,'^0+','','g'),'') is not null
  ), lines as materialized (
    select
      nullif(row_data.normalized_data->>'saleDate','')::date sale_date,
      row_data.normalized_data->>'sourceFolio' source_folio,
      upper(trim(coalesce(row_data.normalized_data->>'locationCode',''))) location_code,
      upper(trim(coalesce(row_data.normalized_data->>'warehouseName',''))) warehouse_name,
      regexp_replace(coalesce(row_data.normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
      nullif(row_data.normalized_data->>'sourceInvoice','') source_invoice,
      coalesce(row_data.resolved_product_id,direct_product.id) product_id,
      customer_codes.external_code is not null customer_linked,
      round(coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0),2) total_amount,
      round(greatest(coalesce(
        nullif(row_data.normalized_data->>'taxAmount','')::numeric,
        nullif(row_data.normalized_data->>'discountAmount','')::numeric,
        coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0)
          - coalesce(nullif(row_data.normalized_data->>'unitPrice','')::numeric,0)
            * coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0),
        0
      ),0),2) tax_amount,
      nullif(row_data.normalized_data->>'canonicalLocationId','')::uuid location_id
    from public.import_staging_rows row_data
    left join public.products direct_product
      on direct_product.company_id=v_batch.company_id
     and direct_product.alpha_sku=row_data.normalized_data->>'alphaSku'
    left join customer_codes
      on customer_codes.external_code=nullif(regexp_replace(coalesce(row_data.normalized_data->>'customerExternalCode',''),'^0+','','g'),'')
    where row_data.import_batch_id=p_import_batch_id
      and row_data.detected_type='sales'
      and row_data.normalized_data->>'evidenceKind'='sale_line'
      and coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0)>0
  ), documents as materialized (
    select
      count(*) line_count,
      count(*) filter(where location_id is null) missing_location_lines,
      count(distinct location_id) location_count,
      count(*) filter(where product_id is null) missing_product_lines,
      bool_or(customer_linked) customer_linked,
      round(sum(greatest(total_amount-tax_amount,0)),2) taxable_amount,
      round(sum(least(tax_amount,total_amount)),2) tax_amount,
      round(sum(total_amount),2) total_amount
    from lines
    group by sale_date,source_folio,location_code,warehouse_name,customer_code,source_invoice
  ), summary as (
    select
      count(*)::integer document_count,
      coalesce(sum(line_count),0)::integer line_count,
      count(*) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0)::integer eligible_documents,
      coalesce(sum(line_count) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0)::integer eligible_lines,
      count(*) filter(where missing_location_lines>0 or location_count<>1)::integer excluded_location_documents,
      coalesce(sum(line_count) filter(where missing_location_lines>0 or location_count<>1),0)::integer excluded_location_lines,
      coalesce(sum(missing_product_lines),0)::integer missing_product_lines,
      count(*) filter(where customer_linked)::integer linked_customer_documents,
      count(*) filter(where not customer_linked)::integer unlinked_customer_documents,
      round(coalesce(sum(taxable_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) taxable_amount,
      round(coalesce(sum(tax_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) tax_amount,
      round(coalesce(sum(total_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) total_amount
    from documents
  )
  select jsonb_build_object(
    'document_count',summary.document_count,
    'line_count',summary.line_count,
    'eligible_documents',summary.eligible_documents,
    'eligible_lines',summary.eligible_lines,
    'excluded_location_documents',summary.excluded_location_documents,
    'excluded_location_lines',summary.excluded_location_lines,
    'missing_product_lines',summary.missing_product_lines,
    'linked_customer_documents',summary.linked_customer_documents,
    'unlinked_customer_documents',summary.unlinked_customer_documents,
    'taxable_amount',summary.taxable_amount,
    'tax_amount',summary.tax_amount,
    'total_amount',summary.total_amount,
    'already_promoted_documents',(select count(*) from public.sales sale_data where sale_data.source_kind='alpha_historical' and sale_data.source_import_batch_id=p_import_batch_id),
    'has_sales',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^nvtadesg_'),
    'has_collections',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^cob_cte_'),
    'can_promote',
      v_batch.status in ('staged','validation_failed')
      and v_batch.blocking_error_count=0
      and v_batch.pending_warning_count=0
      and summary.eligible_documents>0
      and summary.missing_product_lines=0
      and exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^nvtadesg_')
      and exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^cob_cte_')
  ) into v_result from summary;
  return coalesce(v_result,'{}'::jsonb);
end;
$$;

alter function public.preview_alpha_historical_sales_promotion(uuid)
  set statement_timeout = '30s';

revoke all on function public.preview_alpha_historical_sales_promotion(uuid) from public,anon;
grant execute on function public.preview_alpha_historical_sales_promotion(uuid) to authenticated;
