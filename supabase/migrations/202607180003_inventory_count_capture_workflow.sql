-- Satrapy · Scalable physical-count capture and explicit cancellation.
-- Capture remains blind and batched; review reveals variances before approval.

alter table public.inventory_counts
  drop constraint if exists inventory_counts_status_check;

alter table public.inventory_counts
  add constraint inventory_counts_status_check check (
    status in ('open', 'review', 'pending_approval', 'posted', 'rejected', 'cancelled')
  ),
  add column review_request_id uuid,
  add column reviewed_at timestamptz,
  add column cancel_request_id uuid,
  add column cancellation_reason text,
  add column cancelled_by uuid references auth.users(id) on delete restrict,
  add column cancelled_at timestamptz,
  add constraint inventory_counts_review_request_unique unique (review_request_id),
  add constraint inventory_counts_cancel_request_unique unique (cancel_request_id);

drop index if exists public.inventory_counts_one_active_location_idx;
create unique index inventory_counts_one_active_location_idx
  on public.inventory_counts(location_id)
  where status in ('open', 'review', 'pending_approval');

create or replace function public.review_inventory_count(
  p_inventory_count_id uuid,
  p_lines jsonb default '[]'::jsonb,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count public.inventory_counts%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_lines integer;
  v_counted integer;
  v_variances integer;
  v_status text;
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'operate_inventory');

  if v_count.review_request_id = v_request_id and v_count.status in ('review', 'posted') then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_count.status,
      'variance_line_count', v_count.variance_line_count, 'idempotent', true);
  end if;
  if v_count.status <> 'open' then raise exception 'El conteo ya no admite captura.'; end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then
    raise exception 'Las partidas pendientes deben enviarse como una lista.';
  end if;
  if jsonb_array_length(p_lines) > 0 then
    perform public.save_inventory_count_batch(v_count.id, p_lines);
  end if;

  select count(*), count(*) filter (where counted_quantity is not null),
    count(*) filter (where variance_quantity <> 0)
  into v_lines, v_counted, v_variances
  from public.inventory_count_lines where inventory_count_id = v_count.id;
  if v_lines <> v_counted then raise exception 'Faltan % partidas por contar.', v_lines - v_counted; end if;

  if exists (
    select 1
    from public.inventory_count_lines line
    left join public.inventory_balances balance
      on balance.location_id = v_count.location_id and balance.product_id = line.product_id
    where line.inventory_count_id = v_count.id and (
      (line.expected_balance_updated_at is not null and (
        balance.product_id is null
        or balance.quantity_on_hand <> line.expected_quantity
        or balance.updated_at is distinct from line.expected_balance_updated_at
      ))
      or (line.expected_balance_updated_at is null and coalesce(balance.quantity_on_hand, 0) <> 0)
    )
  ) then
    raise exception 'El inventario cambió durante el conteo. Cancela este conteo e inicia uno nuevo.';
  end if;

  v_status := case when v_variances = 0 then 'posted' else 'review' end;
  update public.inventory_counts
  set status = v_status,
      line_count = v_lines,
      counted_line_count = v_counted,
      variance_line_count = v_variances,
      review_request_id = v_request_id,
      reviewed_at = now(),
      posted_at = case when v_variances = 0 then now() else null end
  where id = v_count.id;

  perform public.write_sales_audit(v_count.company_id,
    case when v_variances = 0 then 'inventory_count.posted_without_variance' else 'inventory_count.reviewed' end,
    'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id, 'variance_line_count', v_variances,
      'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_status,
    'variance_line_count', v_variances, 'idempotent', false);
end;
$$;

create or replace function public.submit_inventory_count(
  p_inventory_count_id uuid,
  p_variance_reason text default null,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count public.inventory_counts%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'operate_inventory');

  if v_count.submit_request_id = v_request_id and v_count.status = 'pending_approval' then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_count.status,
      'variance_line_count', v_count.variance_line_count, 'idempotent', true);
  end if;
  if v_count.status <> 'review' then
    raise exception 'Finaliza la captura y revisa las diferencias antes de enviarlas.';
  end if;
  if v_count.variance_line_count < 1 then raise exception 'El conteo no contiene diferencias por aprobar.'; end if;
  if nullif(trim(coalesce(p_variance_reason, '')), '') is null then
    raise exception 'Explica el motivo de las diferencias antes de enviarlas.';
  end if;

  if exists (
    select 1
    from public.inventory_count_lines line
    left join public.inventory_balances balance
      on balance.location_id = v_count.location_id and balance.product_id = line.product_id
    where line.inventory_count_id = v_count.id and (
      (line.expected_balance_updated_at is not null and (
        balance.product_id is null
        or balance.quantity_on_hand <> line.expected_quantity
        or balance.updated_at is distinct from line.expected_balance_updated_at
      ))
      or (line.expected_balance_updated_at is null and coalesce(balance.quantity_on_hand, 0) <> 0)
    )
  ) then
    raise exception 'El inventario cambió después de la captura. Cancela este conteo e inicia uno nuevo.';
  end if;

  update public.inventory_counts
  set status = 'pending_approval',
      variance_reason = trim(p_variance_reason),
      submit_request_id = v_request_id,
      submitted_by = auth.uid(),
      submitted_at = now()
  where id = v_count.id;
  perform public.write_sales_audit(v_count.company_id, 'inventory_count.submitted', 'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id,
      'variance_line_count', v_count.variance_line_count, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'pending_approval',
    'variance_line_count', v_count.variance_line_count, 'idempotent', false);
end;
$$;

create or replace function public.cancel_inventory_count(
  p_inventory_count_id uuid,
  p_reason text,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count public.inventory_counts%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'operate_inventory');
  if v_count.cancel_request_id = v_request_id and v_count.status = 'cancelled' then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'cancelled', 'idempotent', true);
  end if;
  if v_count.status not in ('open', 'review') then
    raise exception 'Solo se puede cancelar un conteo abierto o en revisión.';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Indica el motivo de cancelación.'; end if;

  update public.inventory_counts
  set status = 'cancelled', cancel_request_id = v_request_id,
      cancellation_reason = trim(p_reason), cancelled_by = auth.uid(), cancelled_at = now()
  where id = v_count.id;
  perform public.write_sales_audit(v_count.company_id, 'inventory_count.cancelled', 'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id, 'reason', trim(p_reason),
      'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'cancelled', 'idempotent', false);
end;
$$;

create or replace function public.list_inventory_counts(
  p_company_id uuid,
  p_location_id uuid default null,
  p_status text default null,
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
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id, 'operate_inventory')
    or public.has_company_permission(p_company_id, 'approve_inventory_adjustments')
  ) then raise exception 'No autorizado para consultar conteos.'; end if;
  if p_status is not null and p_status not in ('open', 'review', 'pending_approval', 'posted', 'rejected', 'cancelled') then
    raise exception 'Estado no válido.';
  end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then
    raise exception 'Ubicación no disponible.';
  end if;

  select count(*) into v_total
  from public.inventory_counts count_data
  where count_data.company_id = p_company_id
    and public.can_access_location(count_data.location_id)
    and (p_location_id is null or count_data.location_id = p_location_id)
    and (p_status is null or count_data.status = p_status);

  select coalesce(jsonb_agg(to_jsonb(page_data) order by page_data.opened_at desc), '[]'::jsonb) into v_items
  from (
    select count_data.id, count_data.location_id, location_data.external_code as location_code,
      location_data.name as location_name, count_data.status, count_data.line_count,
      count_data.counted_line_count, count_data.variance_line_count, count_data.variance_reason,
      count_data.cancellation_reason, count_data.opened_by, opener.full_name as opened_by_name,
      count_data.submitted_by, submitter.full_name as submitted_by_name,
      count_data.decided_by, decider.full_name as decided_by_name,
      count_data.cancelled_by, canceller.full_name as cancelled_by_name,
      count_data.opened_at, count_data.reviewed_at, count_data.submitted_at, count_data.decided_at,
      count_data.posted_at, count_data.cancelled_at
    from public.inventory_counts count_data
    join public.locations location_data on location_data.id = count_data.location_id
    left join public.profiles opener on opener.id = count_data.opened_by
    left join public.profiles submitter on submitter.id = count_data.submitted_by
    left join public.profiles decider on decider.id = count_data.decided_by
    left join public.profiles canceller on canceller.id = count_data.cancelled_by
    where count_data.company_id = p_company_id
      and public.can_access_location(count_data.location_id)
      and (p_location_id is null or count_data.location_id = p_location_id)
      and (p_status is null or count_data.status = p_status)
    order by count_data.opened_at desc
    limit v_size offset (v_page - 1) * v_size
  ) page_data;
  return jsonb_build_object('items', v_items, 'total', v_total, 'page', v_page, 'page_size', v_size);
end;
$$;

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
  v_query text := nullif(trim(coalesce(p_query, '')), '');
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
    and (v_query is null or product.name ilike '%' || v_query || '%'
      or product.alpha_sku ilike '%' || v_query || '%'
      or product.internal_sku ilike '%' || v_query || '%')
    and (v_filter = 'all'
      or (v_filter = 'pending' and line.counted_quantity is null)
      or (v_filter = 'counted' and line.counted_quantity is not null)
      or (v_filter = 'differences' and line.variance_quantity <> 0));

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', page_data.id, 'product_id', page_data.product_id, 'product_code', page_data.product_code,
    'product_name', page_data.product_name, 'unit', page_data.unit,
    'expected_quantity', case when v_show_expected then page_data.expected_quantity else null end,
    'counted_quantity', page_data.counted_quantity,
    'variance_quantity', case when v_show_expected then page_data.variance_quantity else null end,
    'counted_at', page_data.counted_at
  ) order by page_data.product_name, page_data.product_id), '[]'::jsonb) into v_items
  from (
    select line.id, line.product_id, coalesce(product.internal_sku, product.alpha_sku) product_code,
      product.name product_name, product.unit, line.expected_quantity, line.counted_quantity,
      line.variance_quantity, line.counted_at
    from public.inventory_count_lines line
    join public.products product on product.id = line.product_id
    where line.inventory_count_id = v_count.id
      and (v_query is null or product.name ilike '%' || v_query || '%'
        or product.alpha_sku ilike '%' || v_query || '%'
        or product.internal_sku ilike '%' || v_query || '%')
      and (v_filter = 'all'
        or (v_filter = 'pending' and line.counted_quantity is null)
        or (v_filter = 'counted' and line.counted_quantity is not null)
        or (v_filter = 'differences' and line.variance_quantity <> 0))
    order by product.name, line.product_id
    limit v_size offset (v_page - 1) * v_size
  ) page_data;
  return jsonb_build_object('items', v_items, 'total', v_total, 'page', v_page, 'page_size', v_size);
end;
$$;

revoke all on function public.review_inventory_count(uuid, jsonb, uuid) from public, anon;
revoke all on function public.cancel_inventory_count(uuid, text, uuid) from public, anon;
revoke all on function public.search_inventory_count_lines(uuid, text, text, integer, integer) from public, anon;
grant execute on function public.review_inventory_count(uuid, jsonb, uuid) to authenticated;
grant execute on function public.cancel_inventory_count(uuid, text, uuid) to authenticated;
grant execute on function public.search_inventory_count_lines(uuid, text, text, integer, integer) to authenticated;
