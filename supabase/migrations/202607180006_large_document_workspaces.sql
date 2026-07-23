-- Scale-safe workspaces for physical counts and customer receivables.
-- Business mutations remain unchanged; these functions only narrow and page reads.

create or replace function public.search_inventory_count_lines(
  p_inventory_count_id uuid,
  p_query text default null,
  p_capture_status text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_count public.inventory_counts%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(nullif(trim(coalesce(p_query, '')), ''));
  v_filter text := coalesce(nullif(p_capture_status, ''), 'all');
  v_total bigint;
  v_items jsonb;
  v_show_expected boolean;
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  if auth.uid() is null or not public.can_access_location(v_count.location_id) or not (
    public.has_company_permission(v_count.company_id, 'operate_inventory')
    or public.has_company_permission(v_count.company_id, 'approve_inventory_adjustments')
  ) then raise exception 'No autorizado para consultar este conteo.'; end if;
  if v_filter not in ('all', 'pending', 'counted', 'differences') then raise exception 'Filtro no válido.'; end if;
  v_show_expected := v_count.status <> 'open' or public.has_company_permission(v_count.company_id, 'approve_inventory_adjustments');

  select count(*) into v_total
  from public.inventory_count_lines line
  join public.products product on product.id = line.product_id
  where line.inventory_count_id = v_count.id
    and (v_query is null
      or lower(product.name) like '%' || v_query || '%'
      or lower(product.alpha_sku) like '%' || v_query || '%'
      or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
      or lower(coalesce(product.barcode, '')) = v_query
      or exists (
        select 1 from public.product_aliases alias_data
        where alias_data.product_id = product.id
          and alias_data.company_id = v_count.company_id
          and alias_data.normalized_value like '%' || v_query || '%'
      ))
    and (v_filter = 'all'
      or (v_filter = 'pending' and line.counted_quantity is null)
      or (v_filter = 'counted' and line.counted_quantity is not null)
      or (v_filter = 'differences' and line.variance_quantity <> 0));

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', page_data.id,
    'product_id', page_data.product_id,
    'product_code', page_data.product_code,
    'product_barcode', page_data.product_barcode,
    'product_name', page_data.product_name,
    'unit', page_data.unit,
    'expected_quantity', case when v_show_expected then page_data.expected_quantity else null end,
    'counted_quantity', page_data.counted_quantity,
    'variance_quantity', case when v_show_expected then page_data.variance_quantity else null end,
    'counted_at', page_data.counted_at
  ) order by page_data.search_rank, page_data.product_name, page_data.product_id), '[]'::jsonb)
  into v_items
  from (
    select
      line.id,
      line.product_id,
      coalesce(product.internal_sku, product.alpha_sku) product_code,
      product.barcode product_barcode,
      product.name product_name,
      product.unit,
      line.expected_quantity,
      line.counted_quantity,
      line.variance_quantity,
      line.counted_at,
      case
        when v_query is not null and lower(coalesce(product.barcode, '')) = v_query then 0
        when v_query is not null and lower(coalesce(product.internal_sku, product.alpha_sku)) = v_query then 1
        else 2
      end search_rank
    from public.inventory_count_lines line
    join public.products product on product.id = line.product_id
    where line.inventory_count_id = v_count.id
      and (v_query is null
        or lower(product.name) like '%' || v_query || '%'
        or lower(product.alpha_sku) like '%' || v_query || '%'
        or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        or lower(coalesce(product.barcode, '')) = v_query
        or exists (
          select 1 from public.product_aliases alias_data
          where alias_data.product_id = product.id
            and alias_data.company_id = v_count.company_id
            and alias_data.normalized_value like '%' || v_query || '%'
        ))
      and (v_filter = 'all'
        or (v_filter = 'pending' and line.counted_quantity is null)
        or (v_filter = 'counted' and line.counted_quantity is not null)
        or (v_filter = 'differences' and line.variance_quantity <> 0))
    order by search_rank, product.name, line.product_id
    limit v_size offset (v_page - 1) * v_size
  ) page_data;

  return jsonb_build_object('items', v_items, 'total', v_total, 'page', v_page, 'page_size', v_size);
end;
$$;

create or replace function public.list_customer_open_receivables_page(
  p_company_id uuid,
  p_customer_id uuid,
  p_query text default null,
  p_due_status text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_query text := lower(nullif(trim(coalesce(p_query, '')), ''));
  v_due_status text := coalesce(nullif(p_due_status, ''), 'all');
  v_total bigint;
  v_items jsonb;
  v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'view_customer_credit') then
    raise exception 'No autorizado para consultar CxC.';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and company_id = p_company_id) then
    raise exception 'Cliente no encontrado.';
  end if;
  if v_due_status not in ('all', 'overdue', 'due_7_days', 'future') then
    raise exception 'Filtro de vencimiento no válido.';
  end if;

  with documents as (
    select
      receivable.id,
      coalesce(receivable.source_reference, ticket.folio) reference,
      receivable.issued_at,
      receivable.due_date,
      receivable.original_amount,
      receivable.outstanding_amount,
      coalesce(sale.currency_code, customer_list.currency_code, default_list.currency_code) currency_code,
      receivable.source_kind
    from public.customer_receivables receivable
    join public.customers customer_data on customer_data.id = receivable.customer_id
    left join public.sales sale on sale.id = receivable.sale_id
    left join public.canonical_tickets ticket on ticket.sale_id = receivable.sale_id
    left join public.price_lists customer_list on customer_list.id = customer_data.price_list_id
    left join public.companies company_data on company_data.id = receivable.company_id
    left join public.price_lists default_list on default_list.id = company_data.default_price_list_id
    where receivable.company_id = p_company_id
      and receivable.customer_id = p_customer_id
      and receivable.outstanding_amount > 0
  )
  select count(*) into v_total
  from documents
  where (v_query is null or lower(coalesce(reference, '')) like '%' || v_query || '%')
    and (v_due_status = 'all'
      or v_due_status = 'overdue' and due_date < current_date
      or v_due_status = 'due_7_days' and due_date between current_date and current_date + 7
      or v_due_status = 'future' and due_date > current_date + 7);

  with documents as (
    select
      receivable.id,
      coalesce(receivable.source_reference, ticket.folio) reference,
      receivable.issued_at,
      receivable.due_date,
      receivable.original_amount,
      receivable.outstanding_amount,
      coalesce(sale.currency_code, customer_list.currency_code, default_list.currency_code) currency_code,
      receivable.source_kind
    from public.customer_receivables receivable
    join public.customers customer_data on customer_data.id = receivable.customer_id
    left join public.sales sale on sale.id = receivable.sale_id
    left join public.canonical_tickets ticket on ticket.sale_id = receivable.sale_id
    left join public.price_lists customer_list on customer_list.id = customer_data.price_list_id
    left join public.companies company_data on company_data.id = receivable.company_id
    left join public.price_lists default_list on default_list.id = company_data.default_price_list_id
    where receivable.company_id = p_company_id
      and receivable.customer_id = p_customer_id
      and receivable.outstanding_amount > 0
  )
  select coalesce(jsonb_agg(to_jsonb(page_data) order by page_data.due_date, page_data.issued_at, page_data.id), '[]'::jsonb)
  into v_items
  from (
    select * from documents
    where (v_query is null or lower(coalesce(reference, '')) like '%' || v_query || '%')
      and (v_due_status = 'all'
        or v_due_status = 'overdue' and due_date < current_date
        or v_due_status = 'due_7_days' and due_date between current_date and current_date + 7
        or v_due_status = 'future' and due_date > current_date + 7)
    order by due_date, issued_at, id
    limit v_size offset (v_page - 1) * v_size
  ) page_data;

  select jsonb_build_object(
    'document_count', count(*),
    'outstanding_amount', coalesce(sum(outstanding_amount), 0),
    'overdue_count', count(*) filter (where due_date < current_date),
    'overdue_amount', coalesce(sum(outstanding_amount) filter (where due_date < current_date), 0),
    'next_due_date', min(due_date)
  ) into v_summary
  from public.customer_receivables
  where company_id = p_company_id and customer_id = p_customer_id and outstanding_amount > 0;

  return jsonb_build_object(
    'items', v_items,
    'summary', v_summary,
    'pagination', jsonb_build_object('page', v_page, 'page_size', v_size, 'total', v_total)
  );
end;
$$;

create or replace function public.get_customer_master(p_company_id uuid, p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_customer public.customers%rowtype;
  v_can_credit boolean;
  v_outstanding numeric;
  v_receivables_summary jsonb;
begin
  v_customer := public.assert_customer_master_access(p_company_id, p_customer_id, false);
  v_can_credit := public.has_company_permission(p_company_id, 'view_customer_credit');
  select coalesce(sum(outstanding_amount), 0) into v_outstanding
  from public.customer_receivables where customer_id = p_customer_id and company_id = p_company_id;
  select jsonb_build_object(
    'document_count', count(*) filter (where outstanding_amount > 0),
    'outstanding_amount', coalesce(sum(outstanding_amount) filter (where outstanding_amount > 0), 0),
    'overdue_count', count(*) filter (where outstanding_amount > 0 and due_date < current_date),
    'overdue_amount', coalesce(sum(outstanding_amount) filter (where outstanding_amount > 0 and due_date < current_date), 0)
  ) into v_receivables_summary
  from public.customer_receivables where customer_id = p_customer_id and company_id = p_company_id;

  return jsonb_build_object(
    'id', v_customer.id,
    'code', v_customer.code,
    'display_name', v_customer.display_name,
    'tax_id', v_customer.tax_id,
    'customer_type', v_customer.customer_type,
    'notes', v_customer.notes,
    'is_active', v_customer.is_active,
    'is_imported', v_customer.alpha_external_code is not null,
    'source_reference', v_customer.alpha_external_code,
    'migration_status', v_customer.migration_status,
    'addresses', coalesce((select jsonb_agg(jsonb_build_object('id', address_data.id, 'label', address_data.label, 'address_line', address_data.address_line, 'neighborhood', address_data.neighborhood, 'municipality', address_data.municipality, 'state_name', address_data.state_name, 'postal_code', address_data.postal_code, 'is_primary', address_data.is_primary) order by address_data.is_primary desc, address_data.created_at) from public.customer_addresses address_data where address_data.customer_id = p_customer_id), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('id', contact_data.id, 'display_name', contact_data.display_name, 'role_name', contact_data.role_name, 'phone', contact_data.phone, 'email', contact_data.email, 'is_primary', contact_data.is_primary) order by contact_data.is_primary desc, contact_data.created_at) from public.customer_contacts contact_data where contact_data.customer_id = p_customer_id), '[]'::jsonb),
    'commercial', jsonb_build_object(
      'price_list_id', v_customer.price_list_id,
      'price_list_name', (select name from public.price_lists where id = v_customer.price_list_id),
      'payment_manager', v_customer.payment_manager,
      'sales_agent', v_customer.sales_agent,
      'credit_enabled', case when v_can_credit then v_customer.credit_enabled else null end,
      'credit_limit', case when v_can_credit then v_customer.credit_limit else null end,
      'credit_term_days', case when v_can_credit then v_customer.credit_term_days else null end,
      'outstanding_amount', case when v_can_credit then v_outstanding else null end,
      'available_credit', case when v_can_credit and v_customer.credit_enabled then greatest(v_customer.credit_limit - v_outstanding, 0) else null end
    ),
    'receivables_summary', case when v_can_credit then v_receivables_summary else null end,
    'open_receivables', '[]'::jsonb
  );
end;
$$;

revoke all on function public.search_inventory_count_lines(uuid, text, text, integer, integer) from public, anon;
revoke all on function public.list_customer_open_receivables_page(uuid, uuid, text, text, integer, integer) from public, anon;
grant execute on function public.search_inventory_count_lines(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.list_customer_open_receivables_page(uuid, uuid, text, text, integer, integer) to authenticated;
