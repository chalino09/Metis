-- Satrapy · Physical inventory counts.
-- Full-location counts are captured in batches; only approved variances alter stock.

insert into public.permissions(code, description) values
  ('operate_inventory', 'Capturar y enviar conteos físicos en ubicaciones autorizadas.'),
  ('approve_inventory_adjustments', 'Aprobar o rechazar diferencias de conteo físico.')
on conflict(code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'operate_inventory'
where role_data.code in ('super_admin', 'direccion_admin', 'sucursal', 'ingeniero_campo', 'almacen')
on conflict do nothing;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code in ('view_inventory', 'approve_inventory_adjustments')
where role_data.code in ('super_admin', 'direccion_admin', 'supervisor_sucursal')
on conflict do nothing;

create table public.inventory_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  status text not null default 'open' check (status in ('open', 'pending_approval', 'posted', 'rejected')),
  line_count integer not null default 0 check (line_count >= 0),
  counted_line_count integer not null default 0 check (counted_line_count >= 0),
  variance_line_count integer not null default 0 check (variance_line_count >= 0),
  variance_reason text,
  decision_reason text,
  open_request_id uuid not null,
  submit_request_id uuid,
  decision_request_id uuid,
  decision_result text check (decision_result in ('approved', 'rejected')),
  opened_by uuid not null references auth.users(id) on delete restrict,
  submitted_by uuid references auth.users(id) on delete restrict,
  decided_by uuid references auth.users(id) on delete restrict,
  opened_at timestamptz not null default now(),
  submitted_at timestamptz,
  decided_at timestamptz,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (company_id, open_request_id),
  unique (submit_request_id),
  unique (decision_request_id)
);

create unique index inventory_counts_one_active_location_idx
  on public.inventory_counts(location_id)
  where status in ('open', 'pending_approval');
create index inventory_counts_company_created_idx
  on public.inventory_counts(company_id, created_at desc);

create table public.inventory_count_lines (
  id uuid primary key default gen_random_uuid(),
  inventory_count_id uuid not null references public.inventory_counts(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  expected_quantity numeric(18,6) not null check (expected_quantity >= 0),
  expected_balance_updated_at timestamptz,
  counted_quantity numeric(18,6) check (counted_quantity >= 0),
  variance_quantity numeric(18,6) not null default 0,
  counted_by uuid references auth.users(id) on delete restrict,
  counted_at timestamptz,
  adjustment_ledger_id uuid,
  created_at timestamptz not null default now(),
  unique (inventory_count_id, product_id)
);

create index inventory_count_lines_count_product_idx
  on public.inventory_count_lines(inventory_count_id, product_id);

create or replace function public.assert_inventory_count_company_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if tg_table_name = 'inventory_counts' then
    select company_id into v_company_id from public.locations where id = new.location_id;
    if v_company_id is distinct from new.company_id then
      raise exception 'El conteo y la ubicación deben pertenecer a la misma empresa.';
    end if;
  else
    select count_data.company_id into v_company_id
    from public.inventory_counts count_data where count_data.id = new.inventory_count_id;
    if not exists (select 1 from public.products product where product.id = new.product_id and product.company_id = v_company_id) then
      raise exception 'El producto del conteo debe pertenecer a la misma empresa.';
    end if;
  end if;
  return new;
end;
$$;

create trigger inventory_counts_company_integrity
  before insert or update of company_id, location_id on public.inventory_counts
  for each row execute function public.assert_inventory_count_company_integrity();
create trigger inventory_count_lines_company_integrity
  before insert or update of inventory_count_id, product_id on public.inventory_count_lines
  for each row execute function public.assert_inventory_count_company_integrity();

alter table public.inventory_ledger
  add column inventory_count_line_id uuid references public.inventory_count_lines(id) on delete restrict;

alter table public.inventory_ledger
  drop constraint if exists inventory_ledger_movement_type_check,
  drop constraint if exists inventory_ledger_check;

alter table public.inventory_ledger
  add constraint inventory_ledger_movement_type_check check (
    movement_type in ('opening_snapshot', 'sale', 'controlled_adjustment', 'physical_count_adjustment')
  ),
  add constraint inventory_ledger_source_check check (
    (movement_type = 'opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null)
    or (movement_type = 'sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null)
    or (movement_type = 'controlled_adjustment' and inventory_count_line_id is null)
    or (movement_type = 'physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null)
  );

create unique index inventory_ledger_count_line_once_idx
  on public.inventory_ledger(inventory_count_line_id)
  where inventory_count_line_id is not null;

alter table public.inventory_count_lines
  add constraint inventory_count_lines_adjustment_ledger_fkey
  foreign key (adjustment_ledger_id) references public.inventory_ledger(id) on delete restrict;
create unique index inventory_count_lines_adjustment_once_idx
  on public.inventory_count_lines(adjustment_ledger_id)
  where adjustment_ledger_id is not null;

alter table public.inventory_counts enable row level security;
alter table public.inventory_count_lines enable row level security;

create policy inventory_counts_read on public.inventory_counts
  for select to authenticated
  using (
    public.can_access_location(location_id)
    and (
      public.has_company_permission(company_id, 'operate_inventory')
      or public.has_company_permission(company_id, 'approve_inventory_adjustments')
    )
  );

create policy inventory_count_lines_read on public.inventory_count_lines
  for select to authenticated
  using (exists (
    select 1 from public.inventory_counts count_data
    where count_data.id = inventory_count_id
      and public.can_access_location(count_data.location_id)
      and (
        public.has_company_permission(count_data.company_id, 'operate_inventory')
        or public.has_company_permission(count_data.company_id, 'approve_inventory_adjustments')
      )
  ));

revoke all on public.inventory_counts, public.inventory_count_lines from authenticated;
grant select on public.inventory_counts, public.inventory_count_lines to authenticated;

create or replace function public.assert_inventory_count_access(
  p_company_id uuid,
  p_location_id uuid,
  p_permission text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, p_permission)
    or not public.can_access_location(p_location_id)
    or not exists (
      select 1 from public.locations location_data
      where location_data.id = p_location_id
        and location_data.company_id = p_company_id
        and location_data.is_active
    ) then
    raise exception 'No autorizado para operar inventario en esta ubicación.';
  end if;
end;
$$;

create or replace function public.open_inventory_count(
  p_company_id uuid,
  p_location_id uuid,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_count_id uuid;
  v_lines integer;
begin
  perform public.assert_inventory_count_access(p_company_id, p_location_id, 'operate_inventory');

  select id into v_count_id
  from public.inventory_counts
  where company_id = p_company_id and open_request_id = v_request_id;
  if found then
    return jsonb_build_object('inventory_count_id', v_count_id, 'status', (select status from public.inventory_counts where id = v_count_id), 'idempotent', true);
  end if;

  if exists (
    select 1 from public.inventory_counts
    where location_id = p_location_id and status in ('open', 'pending_approval')
  ) then
    raise exception 'La ubicación ya tiene un conteo activo.';
  end if;

  insert into public.inventory_counts(company_id, location_id, open_request_id, opened_by)
  values (p_company_id, p_location_id, v_request_id, auth.uid())
  returning id into v_count_id;

  insert into public.inventory_count_lines(
    inventory_count_id, product_id, expected_quantity, expected_balance_updated_at
  )
  select v_count_id, balance.product_id, balance.quantity_on_hand, balance.updated_at
  from public.inventory_balances balance
  where balance.company_id = p_company_id and balance.location_id = p_location_id
  order by balance.product_id;
  get diagnostics v_lines = row_count;

  update public.inventory_counts set line_count = v_lines where id = v_count_id;
  perform public.write_sales_audit(p_company_id, 'inventory_count.opened', 'inventory_counts', v_count_id,
    jsonb_build_object('location_id', p_location_id, 'line_count', v_lines, 'client_request_id', v_request_id));

  return jsonb_build_object('inventory_count_id', v_count_id, 'status', 'open', 'line_count', v_lines, 'idempotent', false);
exception when unique_violation then
  select id into v_count_id from public.inventory_counts where company_id = p_company_id and open_request_id = v_request_id;
  if v_count_id is not null then
    return jsonb_build_object('inventory_count_id', v_count_id, 'status', (select status from public.inventory_counts where id = v_count_id), 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.save_inventory_count_batch(
  p_inventory_count_id uuid,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count public.inventory_counts%rowtype;
  v_received integer;
  v_distinct integer;
  v_line_count integer;
  v_counted_count integer;
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'operate_inventory');
  if v_count.status <> 'open' then raise exception 'El conteo ya no admite captura.'; end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then raise exception 'Las partidas deben enviarse como una lista.'; end if;

  select count(*), count(distinct input.product_id)
  into v_received, v_distinct
  from jsonb_to_recordset(p_lines) input(product_id uuid, counted_quantity numeric);
  if v_received < 1 or v_received > 500 or v_received <> v_distinct then
    raise exception 'Envía entre 1 y 500 productos distintos por lote.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_id uuid, counted_quantity numeric)
    left join public.products product on product.id = input.product_id and product.company_id = v_count.company_id
    where input.product_id is null or input.counted_quantity is null or input.counted_quantity < 0
      or product.id is null
      or (not product.is_inventory_tracked and not exists (
        select 1 from public.inventory_count_lines line where line.inventory_count_id = v_count.id and line.product_id = input.product_id
      ))
  ) then
    raise exception 'El lote contiene productos o cantidades no válidos.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_id uuid, counted_quantity numeric)
    join public.inventory_balances balance on balance.location_id = v_count.location_id and balance.product_id = input.product_id
    where not exists (
      select 1 from public.inventory_count_lines line where line.inventory_count_id = v_count.id and line.product_id = input.product_id
    )
  ) then
    raise exception 'El saldo cambió después de abrir el conteo. Inicia un conteo nuevo.';
  end if;

  insert into public.inventory_count_lines(
    inventory_count_id, product_id, expected_quantity, expected_balance_updated_at
  )
  select v_count.id, input.product_id, 0, null
  from jsonb_to_recordset(p_lines) input(product_id uuid, counted_quantity numeric)
  where not exists (
    select 1 from public.inventory_count_lines line where line.inventory_count_id = v_count.id and line.product_id = input.product_id
  )
  on conflict do nothing;

  update public.inventory_count_lines line
  set counted_quantity = input.counted_quantity,
      variance_quantity = input.counted_quantity - line.expected_quantity,
      counted_by = auth.uid(),
      counted_at = now()
  from jsonb_to_recordset(p_lines) input(product_id uuid, counted_quantity numeric)
  where line.inventory_count_id = v_count.id and line.product_id = input.product_id;

  select count(*), count(*) filter (where counted_quantity is not null)
  into v_line_count, v_counted_count
  from public.inventory_count_lines where inventory_count_id = v_count.id;
  update public.inventory_counts
  set line_count = v_line_count, counted_line_count = v_counted_count
  where id = v_count.id;

  return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'open', 'line_count', v_line_count, 'counted_line_count', v_counted_count);
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
  v_lines integer;
  v_counted integer;
  v_variances integer;
  v_status text;
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'operate_inventory');

  if v_count.submit_request_id = v_request_id and v_count.status in ('pending_approval', 'posted') then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_count.status, 'variance_line_count', v_count.variance_line_count, 'idempotent', true);
  end if;
  if v_count.status <> 'open' then raise exception 'El conteo no está abierto.'; end if;

  select count(*), count(*) filter (where counted_quantity is not null), count(*) filter (where variance_quantity <> 0)
  into v_lines, v_counted, v_variances
  from public.inventory_count_lines where inventory_count_id = v_count.id;
  if v_lines <> v_counted then raise exception 'Faltan % partidas por contar.', v_lines - v_counted; end if;
  if v_variances > 0 and nullif(trim(coalesce(p_variance_reason, '')), '') is null then
    raise exception 'Explica el motivo de las diferencias antes de enviar.';
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
    raise exception 'El inventario cambió durante el conteo. Inicia un conteo nuevo.';
  end if;

  v_status := case when v_variances = 0 then 'posted' else 'pending_approval' end;
  update public.inventory_counts
  set status = v_status,
      line_count = v_lines,
      counted_line_count = v_counted,
      variance_line_count = v_variances,
      variance_reason = nullif(trim(p_variance_reason), ''),
      submit_request_id = v_request_id,
      submitted_by = auth.uid(),
      submitted_at = now(),
      posted_at = case when v_variances = 0 then now() else null end
  where id = v_count.id;

  perform public.write_sales_audit(v_count.company_id,
    case when v_variances = 0 then 'inventory_count.posted_without_variance' else 'inventory_count.submitted' end,
    'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id, 'variance_line_count', v_variances, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_status, 'variance_line_count', v_variances, 'idempotent', false);
end;
$$;

create or replace function public.decide_inventory_count(
  p_inventory_count_id uuid,
  p_approve boolean,
  p_decision_reason text default null,
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
  v_line public.inventory_count_lines%rowtype;
  v_ledger_id uuid;
begin
  select * into v_count from public.inventory_counts where id = p_inventory_count_id for update;
  if not found then raise exception 'Conteo no encontrado.'; end if;
  perform public.assert_inventory_count_access(v_count.company_id, v_count.location_id, 'approve_inventory_adjustments');

  if v_count.decision_request_id = v_request_id
    and v_count.decided_by = auth.uid()
    and v_count.decision_result = (case when p_approve then 'approved' else 'rejected' end)
    and v_count.status in ('posted', 'rejected') then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', v_count.status, 'idempotent', true);
  end if;
  if v_count.status <> 'pending_approval' then raise exception 'El conteo no tiene diferencias pendientes.'; end if;
  if auth.uid() = v_count.opened_by or auth.uid() = v_count.submitted_by then
    raise exception 'La aprobación requiere una persona distinta a quien realizó el conteo.';
  end if;

  if not p_approve then
    if nullif(trim(coalesce(p_decision_reason, '')), '') is null then raise exception 'Explica por qué se rechaza el conteo.'; end if;
    update public.inventory_counts
    set status = 'rejected', decision_request_id = v_request_id, decision_result = 'rejected',
        decision_reason = trim(p_decision_reason), decided_by = auth.uid(), decided_at = now()
    where id = v_count.id;
    perform public.write_sales_audit(v_count.company_id, 'inventory_count.rejected', 'inventory_counts', v_count.id,
      jsonb_build_object('location_id', v_count.location_id, 'reason', trim(p_decision_reason), 'client_request_id', v_request_id));
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'rejected', 'idempotent', false);
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
    raise exception 'El inventario cambió después del conteo. No se aplicaron ajustes.';
  end if;

  perform 1
  from public.inventory_balances balance
  join public.inventory_count_lines line
    on line.inventory_count_id = v_count.id and line.product_id = balance.product_id
  where balance.location_id = v_count.location_id
  order by balance.product_id
  for update of balance;

  for v_line in
    select * from public.inventory_count_lines
    where inventory_count_id = v_count.id and variance_quantity <> 0
    order by product_id
  loop
    update public.inventory_balances
    set quantity_on_hand = v_line.counted_quantity, updated_at = now()
    where location_id = v_count.location_id and product_id = v_line.product_id;
    if not found then
      insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
      values (v_count.company_id, v_count.location_id, v_line.product_id, v_line.counted_quantity);
    end if;

    insert into public.inventory_ledger(
      company_id, location_id, product_id, quantity_delta, balance_after,
      movement_type, inventory_count_line_id, actor_id
    ) values (
      v_count.company_id, v_count.location_id, v_line.product_id, v_line.variance_quantity,
      v_line.counted_quantity, 'physical_count_adjustment', v_line.id, auth.uid()
    ) returning id into v_ledger_id;
    update public.inventory_count_lines set adjustment_ledger_id = v_ledger_id where id = v_line.id;
  end loop;

  update public.inventory_counts
  set status = 'posted', decision_request_id = v_request_id, decision_result = 'approved',
      decision_reason = nullif(trim(p_decision_reason), ''), decided_by = auth.uid(), decided_at = now(), posted_at = now()
  where id = v_count.id;
  perform public.write_sales_audit(v_count.company_id, 'inventory_count.approved_and_posted', 'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id, 'variance_line_count', v_count.variance_line_count, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'posted', 'variance_line_count', v_count.variance_line_count, 'idempotent', false);
exception when unique_violation then
  select * into v_count from public.inventory_counts where id = p_inventory_count_id;
  if v_count.decision_request_id = v_request_id and v_count.status = 'posted' then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'posted', 'variance_line_count', v_count.variance_line_count, 'idempotent', true);
  end if;
  raise;
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
  if p_status is not null and p_status not in ('open', 'pending_approval', 'posted', 'rejected') then raise exception 'Estado no válido.'; end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then raise exception 'Ubicación no disponible.'; end if;

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
      count_data.opened_by, opener.full_name as opened_by_name, count_data.submitted_by,
      submitter.full_name as submitted_by_name, count_data.decided_by, decider.full_name as decided_by_name,
      count_data.opened_at, count_data.submitted_at, count_data.decided_at, count_data.posted_at
    from public.inventory_counts count_data
    join public.locations location_data on location_data.id = count_data.location_id
    left join public.profiles opener on opener.id = count_data.opened_by
    left join public.profiles submitter on submitter.id = count_data.submitted_by
    left join public.profiles decider on decider.id = count_data.decided_by
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

create or replace function public.list_inventory_count_lines(
  p_inventory_count_id uuid,
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
  v_show_expected := v_count.status <> 'open' or public.has_company_permission(v_count.company_id, 'approve_inventory_adjustments');

  select count(*) into v_total from public.inventory_count_lines where inventory_count_id = v_count.id;
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
    order by product.name, line.product_id
    limit v_size offset (v_page - 1) * v_size
  ) page_data;
  return jsonb_build_object(
    'count', jsonb_build_object('id', v_count.id, 'location_id', v_count.location_id, 'status', v_count.status,
      'line_count', v_count.line_count, 'counted_line_count', v_count.counted_line_count,
      'variance_line_count', v_count.variance_line_count, 'variance_reason', v_count.variance_reason),
    'items', v_items, 'total', v_total, 'page', v_page, 'page_size', v_size
  );
end;
$$;

revoke all on function public.assert_inventory_count_access(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.assert_inventory_count_company_integrity() from public, anon, authenticated;
revoke all on function public.open_inventory_count(uuid, uuid, uuid) from public, anon;
revoke all on function public.save_inventory_count_batch(uuid, jsonb) from public, anon;
revoke all on function public.submit_inventory_count(uuid, text, uuid) from public, anon;
revoke all on function public.decide_inventory_count(uuid, boolean, text, uuid) from public, anon;
revoke all on function public.list_inventory_counts(uuid, uuid, text, integer, integer) from public, anon;
revoke all on function public.list_inventory_count_lines(uuid, integer, integer) from public, anon;
grant execute on function public.open_inventory_count(uuid, uuid, uuid) to authenticated;
grant execute on function public.save_inventory_count_batch(uuid, jsonb) to authenticated;
grant execute on function public.submit_inventory_count(uuid, text, uuid) to authenticated;
grant execute on function public.decide_inventory_count(uuid, boolean, text, uuid) to authenticated;
grant execute on function public.list_inventory_counts(uuid, uuid, text, integer, integer) to authenticated;
grant execute on function public.list_inventory_count_lines(uuid, integer, integer) to authenticated;
