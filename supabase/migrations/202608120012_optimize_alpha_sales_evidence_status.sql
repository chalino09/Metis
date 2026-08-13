-- The prior status query expressed unmatched documents as correlated CTE
-- lookups. With a historical package this can repeatedly compare every sale
-- invoice with every collection invoice. Reconcile each pair exactly once.
create or replace function public.get_alpha_sales_evidence_status(p_import_batch_id uuid)
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
  if not found or auth.uid() is null or not (public.can_import_commercial(v_batch.company_id,'sales') or public.has_company_permission(v_batch.company_id,'view_import_audit')) then
    raise exception 'No autorizado.';
  end if;
  if v_batch.import_type<>'sales' then raise exception 'Tipo de lote inválido.'; end if;

  with sales as materialized (
    select
      regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
      normalized_data->>'sourceInvoice' invoice,
      round(sum(coalesce((normalized_data->>'lineTotal')::numeric,0)),2) amount
    from public.import_staging_rows
    where import_batch_id=p_import_batch_id
      and normalized_data->>'evidenceKind'='sale_line'
      and nullif(normalized_data->>'sourceInvoice','') is not null
    group by 1,2
  ), collections as materialized (
    select
      regexp_replace(coalesce(normalized_data->>'customerExternalCode',''),'^0+','','g') customer_code,
      case when upper(trim(coalesce(normalized_data->>'reference',''))) ~ '^C1[[:space:]]*[0-9]+$'
        then regexp_replace(upper(trim(normalized_data->>'reference')),'^C1[[:space:]]*','','g') end invoice,
      round(sum(coalesce((normalized_data->>'amount')::numeric,0)),2) amount
    from public.import_staging_rows
    where import_batch_id=p_import_batch_id
      and normalized_data->>'evidenceKind'='collection'
    group by 1,2
  ), reconciliation as materialized (
    select s.customer_code sale_customer_code, s.invoice sale_invoice, s.amount sale_amount,
      c.customer_code collection_customer_code, c.invoice collection_invoice, c.amount collection_amount
    from sales s
    full join collections c
      on c.customer_code=s.customer_code
     and c.invoice=s.invoice
  )
  select jsonb_build_object(
    'has_sales',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name ~* '^nvtadesg_'),
    'has_collections',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name ~* '^cob_cte_'),
    'files',coalesce((select jsonb_agg(jsonb_build_object('name',original_name,'row_count',row_count) order by created_at) from public.import_files where import_batch_id=p_import_batch_id),'[]'::jsonb),
    'sales',(select count(*) from sales),
    'collections',(select count(*) from collections where invoice is not null),
    'exact_matches',(select count(*) from reconciliation where sale_invoice is not null and collection_invoice is not null and abs(sale_amount-collection_amount)<=0.01),
    'amount_mismatches',(select count(*) from reconciliation where sale_invoice is not null and collection_invoice is not null and abs(sale_amount-collection_amount)>0.01),
    'sales_without_collection',(select count(*) from reconciliation where sale_invoice is not null and collection_invoice is null),
    'collections_without_sale',(select count(*) from reconciliation where collection_invoice is not null and sale_invoice is null),
    'promotion_enabled',false
  ) into v_result;
  return v_result || jsonb_build_object('complete',(v_result->>'has_sales')::boolean and (v_result->>'has_collections')::boolean);
end;
$$;

alter function public.get_alpha_sales_evidence_status(uuid)
  set statement_timeout = '30s';

revoke all on function public.get_alpha_sales_evidence_status(uuid) from public;
grant execute on function public.get_alpha_sales_evidence_status(uuid) to authenticated;
