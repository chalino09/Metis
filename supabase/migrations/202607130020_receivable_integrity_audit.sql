-- CxC must use the same customer universe in its summary and its paginated list.
-- This is a read-only, permissioned integrity check: it never changes a document or a balance.

create or replace function public.list_receivable_customers(
  p_company_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_sort text default 'largest_balance'
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_sort text:=coalesce(p_sort,'largest_balance');
  v_total integer;
  v_items jsonb;
  v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then
    raise exception 'No autorizado para consultar cuentas por cobrar.';
  end if;
  if v_sort not in ('largest_balance','most_overdue','due_first') then
    raise exception 'Orden de cobranza no válido.';
  end if;

  with balances as materialized (
    select r.customer_id,
      sum(r.outstanding_amount) as outstanding,
      sum(r.outstanding_amount) filter(where r.due_date<current_date) as overdue,
      min(r.due_date) as next_due
    from public.customer_receivables r
    where r.company_id=p_company_id and r.outstanding_amount>0
    group by r.customer_id
  ), visible as materialized (
    select c.id,c.code,c.display_name,b.outstanding,coalesce(b.overdue,0) as overdue,b.next_due
    from balances b
    join public.customers c on c.id=b.customer_id
    where c.company_id=p_company_id and c.is_active
  )
  select jsonb_build_object(
    'total_outstanding',coalesce(sum(outstanding),0),
    'overdue',coalesce(sum(overdue),0),
    'due_next_7_days',coalesce(sum(outstanding) filter(where next_due between current_date and current_date+7),0),
    'customers',count(*)
  ) into v_summary from visible;

  with balances as materialized (
    select r.customer_id,sum(r.outstanding_amount) as outstanding,sum(r.outstanding_amount) filter(where r.due_date<current_date) as overdue,min(r.due_date) as next_due
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 group by r.customer_id
  )
  select count(*) into v_total
  from balances b join public.customers c on c.id=b.customer_id
  where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query);

  with balances as materialized (
    select r.customer_id,sum(r.outstanding_amount) as outstanding,sum(r.outstanding_amount) filter(where r.due_date<current_date) as overdue,min(r.due_date) as next_due
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 group by r.customer_id
  ), paged as (
    select c.id,c.code,c.display_name,b.outstanding,coalesce(b.overdue,0) as overdue,b.next_due
    from balances b join public.customers c on c.id=b.customer_id
    where c.company_id=p_company_id and c.is_active and public.customer_matches_query(c.id,v_query)
    order by case when v_sort='largest_balance' then b.outstanding end desc nulls last,
      case when v_sort='most_overdue' then coalesce(b.overdue,0) end desc nulls last,
      case when v_sort='due_first' then b.next_due end asc nulls last,c.display_name,c.id
    limit v_size offset (v_page-1)*v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'display_name',display_name,'outstanding_amount',outstanding,'overdue_amount',overdue,'next_due_date',next_due)
    order by case when v_sort='largest_balance' then outstanding end desc nulls last,
      case when v_sort='most_overdue' then overdue end desc nulls last,
      case when v_sort='due_first' then next_due end asc nulls last,display_name),'[]'::jsonb)
  into v_items from paged;

  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size,'summary',v_summary);
end $$;

create or replace function public.get_receivable_integrity_audit(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then
    raise exception 'No autorizado para auditar cuentas por cobrar.';
  end if;

  with open_rows as materialized (
    select r.*,c.is_active
    from public.customer_receivables r
    join public.customers c on c.id=r.customer_id and c.company_id=r.company_id
    where r.company_id=p_company_id and r.outstanding_amount>0
  ), source_totals as (
    select source_kind,count(*) as documents,count(distinct customer_id) as customers,coalesce(sum(outstanding_amount),0) as amount
    from open_rows group by source_kind
  ), duplicate_keys as (
    select source_document_key,count(*) as rows,sum(outstanding_amount) as amount
    from open_rows
    where source_kind in ('alpha_document','alpha_opening_balance') and source_document_key is not null
    group by source_document_key having count(*)>1
  ), duplicate_sales as (
    select sale_id,count(*) as rows,sum(outstanding_amount) as amount
    from open_rows where sale_id is not null group by sale_id having count(*)>1
  ), duplicate_customers as (
    select alpha_external_code,count(*) as rows
    from public.customers
    where company_id=p_company_id and alpha_external_code is not null
    group by alpha_external_code having count(*)>1
  )
  select jsonb_build_object(
    'active_customer_total',coalesce(sum(outstanding_amount) filter(where is_active),0),
    'inactive_customer_total',coalesce(sum(outstanding_amount) filter(where not is_active),0),
    'active_customers',count(distinct customer_id) filter(where is_active),
    'inactive_customers',count(distinct customer_id) filter(where not is_active),
    'open_documents',count(*),
    'by_source',coalesce((select jsonb_agg(jsonb_build_object('source_kind',source_kind,'documents',documents,'customers',customers,'amount',amount) order by source_kind) from source_totals),'[]'::jsonb),
    'duplicate_document_keys',coalesce((select count(*) from duplicate_keys),0),
    'duplicate_document_amount',coalesce((select sum(amount) from duplicate_keys),0),
    'duplicate_sales',coalesce((select count(*) from duplicate_sales),0),
    'duplicate_sale_amount',coalesce((select sum(amount) from duplicate_sales),0),
    'duplicate_imported_customer_keys',coalesce((select count(*) from duplicate_customers),0)
  ) into v_result from open_rows;

  return coalesce(v_result,'{}'::jsonb);
end $$;

revoke all on function public.list_receivable_customers(uuid,text,integer,integer,text) from public;
grant execute on function public.list_receivable_customers(uuid,text,integer,integer,text) to authenticated;
revoke all on function public.get_receivable_integrity_audit(uuid) from public;
grant execute on function public.get_receivable_integrity_audit(uuid) to authenticated;
