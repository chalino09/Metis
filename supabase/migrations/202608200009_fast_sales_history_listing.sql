-- La bitácora de ventas puede contener históricos importados. La consulta debe
-- resolver el alcance una vez, paginar en servidor y enriquecer sólo la página.

create index if not exists sales_company_completed_id_idx
  on public.sales(company_id,completed_at desc,id desc);

create index if not exists canonical_tickets_folio_search_idx
  on public.canonical_tickets using gin(lower(folio) extensions.gin_trgm_ops);

create index if not exists canonical_tickets_customer_name_search_idx
  on public.canonical_tickets using gin(lower(coalesce(payload#>>'{sale,customer,display_name}','')) extensions.gin_trgm_ops);

drop function if exists public.list_sales(uuid,uuid,text,integer,integer);

create function public.list_sales(
  p_company_id uuid,
  p_location_id uuid default null,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_include_total boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_is_super_admin boolean:=public.is_super_admin();
  v_allowed_location_ids uuid[];
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales') then
    raise exception 'No autorizado.';
  end if;

  if v_is_super_admin then
    select coalesce(array_agg(location_data.id),'{}'::uuid[])
      into v_allowed_location_ids
      from public.locations location_data
      where location_data.company_id=p_company_id;
  else
    select coalesce(array_agg(location_data.id),'{}'::uuid[])
      into v_allowed_location_ids
      from public.locations location_data
      where location_data.company_id=p_company_id
        and public.can_access_location(location_data.id);
  end if;

  if p_location_id is not null and not (p_location_id=any(v_allowed_location_ids)) then
    raise exception 'No autorizado para esta ubicación.';
  end if;

  if cardinality(v_allowed_location_ids)=0 then
    return jsonb_build_object('items','[]'::jsonb,'total',case when p_include_total then 0 else null end,'page',v_page,'page_size',v_size);
  end if;

  if p_include_total then
    with filtered as materialized (
      select sale_data.id,sale_data.location_id,sale_data.sale_type,sale_data.source_kind,sale_data.currency_code,sale_data.total_amount,sale_data.completed_at,
        coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}') customer_name,ticket.folio
      from public.sales sale_data
      join public.canonical_tickets ticket on ticket.sale_id=sale_data.id
      left join public.customers customer_data on customer_data.id=sale_data.customer_id
      where sale_data.company_id=p_company_id
        and sale_data.location_id=any(v_allowed_location_ids)
        and (p_location_id is null or sale_data.location_id=p_location_id)
        and (v_query='' or lower(ticket.folio) like '%'||v_query||'%' or lower(coalesce(customer_data.display_name,'')) like '%'||v_query||'%' or (customer_data.display_name is null and lower(coalesce(ticket.payload#>>'{sale,customer,display_name}','')) like '%'||v_query||'%'))
    ), paged as (
      select * from filtered
      order by completed_at desc,id desc
      limit v_size offset (v_page-1)*v_size
    )
    select jsonb_build_object(
      'items',coalesce((
        select jsonb_agg(jsonb_build_object(
          'sale_id',page_data.id,'folio',page_data.folio,'location_id',page_data.location_id,'sale_type',page_data.sale_type,'source_kind',page_data.source_kind,
          'customer_name',page_data.customer_name,'currency_code',page_data.currency_code,'total_amount',page_data.total_amount,
          'returned_amount',coalesce((select sum(return_data.total_amount) from public.sale_returns return_data where return_data.sale_id=page_data.id),0),
          'cancelled',exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=page_data.id),
          'completed_at',page_data.completed_at
        ) order by page_data.completed_at desc,page_data.id desc)
        from paged page_data
      ),'[]'::jsonb),
      'total',(select count(*) from filtered),
      'page',v_page,'page_size',v_size
    ) into v_result;
  else
    with paged as (
      select sale_data.id,sale_data.location_id,sale_data.sale_type,sale_data.source_kind,sale_data.currency_code,sale_data.total_amount,sale_data.completed_at,
        coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}') customer_name,ticket.folio
      from public.sales sale_data
      join public.canonical_tickets ticket on ticket.sale_id=sale_data.id
      left join public.customers customer_data on customer_data.id=sale_data.customer_id
      where sale_data.company_id=p_company_id
        and sale_data.location_id=any(v_allowed_location_ids)
        and (p_location_id is null or sale_data.location_id=p_location_id)
        and (v_query='' or lower(ticket.folio) like '%'||v_query||'%' or lower(coalesce(customer_data.display_name,'')) like '%'||v_query||'%' or (customer_data.display_name is null and lower(coalesce(ticket.payload#>>'{sale,customer,display_name}','')) like '%'||v_query||'%'))
      order by sale_data.completed_at desc,sale_data.id desc
      limit v_size offset (v_page-1)*v_size
    )
    select jsonb_build_object(
      'items',coalesce(jsonb_agg(jsonb_build_object(
        'sale_id',page_data.id,'folio',page_data.folio,'location_id',page_data.location_id,'sale_type',page_data.sale_type,'source_kind',page_data.source_kind,
        'customer_name',page_data.customer_name,'currency_code',page_data.currency_code,'total_amount',page_data.total_amount,
        'returned_amount',coalesce((select sum(return_data.total_amount) from public.sale_returns return_data where return_data.sale_id=page_data.id),0),
        'cancelled',exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=page_data.id),
        'completed_at',page_data.completed_at
      ) order by page_data.completed_at desc,page_data.id desc),'[]'::jsonb),
      'total',null,'page',v_page,'page_size',v_size
    ) into v_result
    from paged page_data;
  end if;

  return v_result;
end $$;

revoke all on function public.list_sales(uuid,uuid,text,integer,integer,boolean) from public,anon;
grant execute on function public.list_sales(uuid,uuid,text,integer,integer,boolean) to authenticated;
