-- Keep the lightweight aggregate surface, but delegate the line projection to
-- the batch-mapped helper. PostgreSQL plans this set-returning helper as a
-- single scan; the direct CTE form can be misplanned as nested loops.
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

  with lines as materialized (
    select * from public.alpha_historical_sales_lines(p_import_batch_id)
  ), documents as materialized (
    select document_key,
      count(*) line_count,
      count(*) filter(where location_id is null) missing_location_lines,
      count(distinct location_id) location_count,
      count(*) filter(where product_id is null) missing_product_lines,
      bool_or(customer_id is not null) customer_linked,
      round(sum(taxable_amount),2) taxable_amount,
      round(sum(tax_amount),2) tax_amount,
      round(sum(total_amount),2) total_amount
    from lines group by document_key
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
