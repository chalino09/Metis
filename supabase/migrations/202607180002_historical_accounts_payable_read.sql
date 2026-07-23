-- Consulta histórica de CxP conservadas en staging. Es estrictamente de solo lectura:
-- no crea facturas, saldos, propuestas, pagos ni aplicaciones.

create or replace function public.search_historical_accounts_payable(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_batch_id uuid;
  v_snapshot_date date;
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_query text:=nullif(trim(coalesce(p_query,'')),'');
  v_total integer:=0;
  v_items jsonb:='[]'::jsonb;
  v_totals jsonb:='[]'::jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then
    raise exception 'No autorizado para consultar el historial de CxP.';
  end if;

  select b.id,b.cutoff_date into v_batch_id,v_snapshot_date
  from public.alpha_purchasing_import_batches b
  where b.company_id=p_company_id and b.status='staged'
  order by b.cutoff_date desc,b.created_at desc
  limit 1;

  if v_batch_id is null then
    return jsonb_build_object(
      'items','[]'::jsonb,
      'snapshot_date',null,
      'totals','[]'::jsonb,
      'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',0)
    );
  end if;

  select count(*) into v_total
  from public.alpha_purchasing_import_payable_documents d
  where d.batch_id=v_batch_id and (
    v_query is null
    or d.supplier_name ilike '%'||v_query||'%'
    or d.supplier_external_code ilike '%'||v_query||'%'
    or d.folio ilike '%'||v_query||'%'
  );

  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date,x.supplier_name,x.folio),'[]'::jsonb) into v_items
  from (
    select d.id,d.folio,d.supplier_external_code,d.supplier_name,d.issued_date,d.due_date,
      d.outstanding_amount,coalesce(nullif(d.currency_code,''),'MXN') currency_code,
      case when d.due_date<v_snapshot_date then 'overdue' else 'not_due' end condition_at_snapshot
    from public.alpha_purchasing_import_payable_documents d
    where d.batch_id=v_batch_id and (
      v_query is null
      or d.supplier_name ilike '%'||v_query||'%'
      or d.supplier_external_code ilike '%'||v_query||'%'
      or d.folio ilike '%'||v_query||'%'
    )
    order by d.due_date,d.supplier_name,d.folio
    limit v_size offset (v_page-1)*v_size
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
    'currency_code',x.currency_code,
    'document_count',x.document_count,
    'outstanding_amount',x.outstanding_amount
  ) order by x.currency_code),'[]'::jsonb) into v_totals
  from (
    select coalesce(nullif(d.currency_code,''),'MXN') currency_code,count(*) document_count,sum(d.outstanding_amount) outstanding_amount
    from public.alpha_purchasing_import_payable_documents d
    where d.batch_id=v_batch_id
    group by coalesce(nullif(d.currency_code,''),'MXN')
  ) x;

  return jsonb_build_object(
    'items',v_items,
    'snapshot_date',v_snapshot_date,
    'totals',v_totals,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total)
  );
end $$;

revoke all on function public.search_historical_accounts_payable(uuid,text,integer,integer) from public;
grant execute on function public.search_historical_accounts_payable(uuid,text,integer,integer) to authenticated;

