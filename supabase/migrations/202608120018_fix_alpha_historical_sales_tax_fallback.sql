-- Older staged nvtadesg rows stored the source Dcto. column as
-- discountAmount and did not persist taxAmount. A discount is not tax
-- evidence: when taxAmount is absent, derive the inclusive tax difference
-- from line total minus unit price times quantity, matching the current
-- parser. Confirmed POS documents are immutable, so an incomplete promotion
-- keeps its already-issued block and resumes with the corrected interpretation.
-- The interpretation boundary and the reconciled aggregate are audited.

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

do $reconcile_incomplete_promotions$
declare
  v_progress record;
  v_existing_documents integer;
  v_existing_lines integer;
  v_total_documents integer;
  v_total_lines integer;
  v_taxable_amount numeric;
  v_tax_amount numeric;
  v_total_amount numeric;
begin
  for v_progress in
    select progress.import_batch_id,progress.company_id,progress.requested_by
    from public.alpha_historical_sales_promotion_progress progress
    join public.import_batches batch on batch.id=progress.import_batch_id
    where progress.status='processing'
      and batch.import_type='sales'
      and batch.status in ('staged','validation_failed')
    for update of progress,batch
  loop
    with source_lines as materialized (
      select
        row_data.normalized_data->>'saleDate' sale_date,
        row_data.normalized_data->>'sourceFolio' source_folio,
        upper(trim(coalesce(row_data.normalized_data->>'locationCode',''))) location_code,
        upper(trim(coalesce(row_data.normalized_data->>'warehouseName',''))) warehouse_name,
        regexp_replace(coalesce(row_data.normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
        coalesce(row_data.normalized_data->>'sourceInvoice','') source_invoice,
        nullif(row_data.normalized_data->>'canonicalLocationId','')::uuid location_id,
        coalesce(row_data.resolved_product_id,direct_product.id) product_id,
        round(coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0),2) total_amount,
        round(greatest(coalesce(
          nullif(row_data.normalized_data->>'taxAmount','')::numeric,
          coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0)
            - coalesce(nullif(row_data.normalized_data->>'unitPrice','')::numeric,0)
              * coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0),
          0
        ),0),2) tax_amount
      from public.import_staging_rows row_data
      left join public.products direct_product
        on row_data.resolved_product_id is null
       and direct_product.company_id=v_progress.company_id
       and direct_product.alpha_sku=row_data.normalized_data->>'alphaSku'
      where row_data.import_batch_id=v_progress.import_batch_id
        and row_data.detected_type='sales'
        and row_data.normalized_data->>'evidenceKind'='sale_line'
        and coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0)>0
    ), eligible_documents as materialized (
      select
        encode(extensions.digest(concat_ws('|',
          line.sale_date,
          line.source_folio,
          line.location_code,
          line.warehouse_name,
          line.customer_code,
          line.source_invoice
        ),'sha256'),'hex') document_key,
        count(*)::integer line_count,
        round(sum(greatest(line.total_amount-line.tax_amount,0)),2) taxable_amount,
        round(sum(least(line.tax_amount,line.total_amount)),2) tax_amount,
        round(sum(line.total_amount),2) total_amount
      from source_lines line
      group by line.sale_date,line.source_folio,line.location_code,
        line.warehouse_name,line.customer_code,line.source_invoice
      having count(*) filter(where line.location_id is null)=0
        and count(distinct line.location_id)=1
        and count(*) filter(where line.product_id is null)=0
    ), immutable_item_counts as materialized (
      select item.sale_id,count(*)::integer line_count
      from public.sale_items item
      join public.sales sale_data on sale_data.id=item.sale_id
      where sale_data.company_id=v_progress.company_id
        and sale_data.source_kind='alpha_historical'
        and sale_data.source_import_batch_id=v_progress.import_batch_id
      group by item.sale_id
    ), immutable_block as (
      select
        count(*)::integer document_count,
        coalesce(sum(item_counts.line_count),0)::integer line_count,
        coalesce(round(sum(sale_data.subtotal_amount),2),0) taxable_amount,
        coalesce(round(sum(sale_data.tax_amount),2),0) tax_amount,
        coalesce(round(sum(sale_data.total_amount),2),0) total_amount
      from public.sales sale_data
      left join immutable_item_counts item_counts on item_counts.sale_id=sale_data.id
      where sale_data.company_id=v_progress.company_id
        and sale_data.source_kind='alpha_historical'
        and sale_data.source_import_batch_id=v_progress.import_batch_id
    ), pending_block as (
      select
        count(*)::integer document_count,
        coalesce(sum(document.line_count),0)::integer line_count,
        coalesce(round(sum(document.taxable_amount),2),0) taxable_amount,
        coalesce(round(sum(document.tax_amount),2),0) tax_amount,
        coalesce(round(sum(document.total_amount),2),0) total_amount
      from eligible_documents document
      where not exists (
        select 1
        from public.sales sale_data
        where sale_data.company_id=v_progress.company_id
          and sale_data.source_kind='alpha_historical'
          and sale_data.source_import_batch_id=v_progress.import_batch_id
          and sale_data.source_document_key=document.document_key
      )
    )
    select
      immutable.document_count,
      immutable.line_count,
      immutable.document_count+pending.document_count,
      immutable.line_count+pending.line_count,
      immutable.taxable_amount+pending.taxable_amount,
      immutable.tax_amount+pending.tax_amount,
      immutable.total_amount+pending.total_amount
    into
      v_existing_documents,v_existing_lines,v_total_documents,v_total_lines,
      v_taxable_amount,v_tax_amount,v_total_amount
    from immutable_block immutable
    cross join pending_block pending;

    update public.alpha_historical_sales_promotion_progress
    set total_documents=v_total_documents,
      total_lines=v_total_lines,
      taxable_amount=v_taxable_amount,
      tax_amount=v_tax_amount,
      total_amount=v_total_amount
    where import_batch_id=v_progress.import_batch_id;

    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    select v_progress.company_id,v_progress.requested_by,
      'sales_history.tax_interpretation_boundary','import_batch',v_progress.import_batch_id,
      jsonb_build_object(
        'reason','Dcto. no es evidencia fiscal. Los documentos ya confirmados son inmutables; el saldo pendiente usa la interpretación corregida.',
        'immutable_documents',v_existing_documents,
        'immutable_lines',v_existing_lines,
        'pending_documents',v_total_documents-v_existing_documents,
        'pending_lines',v_total_lines-v_existing_lines,
        'canonical_documents_mutated',false,
        'reconciled_taxable_amount',v_taxable_amount,
        'reconciled_tax_amount',v_tax_amount,
        'reconciled_total_amount',v_total_amount
      )
    where not exists (
      select 1 from public.audit_log existing
      where existing.entity_type='import_batch'
        and existing.entity_id=v_progress.import_batch_id
        and existing.action='sales_history.tax_interpretation_boundary'
    );
  end loop;
end;
$reconcile_incomplete_promotions$;
