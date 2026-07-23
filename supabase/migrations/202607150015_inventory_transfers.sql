-- Satrapy · Operational inventory transfers.
-- A transfer is created in bulk as sent, deducts stock only on dispatch, and
-- adds stock only when the destination confirms receipt.

create table public.inventory_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  source_location_id uuid not null references public.locations(id) on delete restrict,
  destination_location_id uuid not null references public.locations(id) on delete restrict,
  status text not null default 'sent' check (status in ('sent', 'in_transit', 'received')),
  line_count integer not null default 0 check (line_count > 0),
  sent_request_id uuid not null unique,
  transit_request_id uuid unique,
  received_request_id uuid unique,
  sent_by uuid not null references auth.users(id) on delete restrict,
  transited_by uuid references auth.users(id) on delete restrict,
  received_by uuid references auth.users(id) on delete restrict,
  sent_at timestamptz not null default now(),
  in_transit_at timestamptz,
  received_at timestamptz,
  created_at timestamptz not null default now(),
  check (source_location_id <> destination_location_id),
  check ((status = 'sent' and in_transit_at is null and received_at is null)
    or (status = 'in_transit' and in_transit_at is not null and received_at is null)
    or (status = 'received' and in_transit_at is not null and received_at is not null))
);

create index inventory_transfers_company_created_idx
  on public.inventory_transfers(company_id, created_at desc);
create index inventory_transfers_source_status_idx
  on public.inventory_transfers(source_location_id, status, created_at desc);
create index inventory_transfers_destination_status_idx
  on public.inventory_transfers(destination_location_id, status, created_at desc);

create table public.inventory_transfer_lines (
  id uuid primary key default gen_random_uuid(),
  inventory_transfer_id uuid not null references public.inventory_transfers(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check (quantity > 0),
  outbound_ledger_id uuid,
  inbound_ledger_id uuid,
  created_at timestamptz not null default now(),
  unique (inventory_transfer_id, product_id)
);

create index inventory_transfer_lines_transfer_idx
  on public.inventory_transfer_lines(inventory_transfer_id, product_id);

create or replace function public.assert_inventory_transfer_company_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if tg_table_name = 'inventory_transfers' then
    select company_id into v_company_id from public.locations where id = new.source_location_id;
    if v_company_id is distinct from new.company_id then
      raise exception 'El origen de la transferencia debe pertenecer a la misma empresa.';
    end if;
    select company_id into v_company_id from public.locations where id = new.destination_location_id;
    if v_company_id is distinct from new.company_id then
      raise exception 'El destino de la transferencia debe pertenecer a la misma empresa.';
    end if;
  else
    select transfer_data.company_id into v_company_id
    from public.inventory_transfers transfer_data
    where transfer_data.id = new.inventory_transfer_id;
    if not exists (
      select 1 from public.products product
      where product.id = new.product_id and product.company_id = v_company_id
    ) then
      raise exception 'El producto de la transferencia debe pertenecer a la misma empresa.';
    end if;
  end if;
  return new;
end;
$$;

create trigger inventory_transfers_company_integrity
  before insert or update of company_id, source_location_id, destination_location_id on public.inventory_transfers
  for each row execute function public.assert_inventory_transfer_company_integrity();
create trigger inventory_transfer_lines_company_integrity
  before insert or update of inventory_transfer_id, product_id on public.inventory_transfer_lines
  for each row execute function public.assert_inventory_transfer_company_integrity();

alter table public.inventory_ledger
  add column inventory_transfer_line_id uuid references public.inventory_transfer_lines(id) on delete restrict;

alter table public.inventory_ledger
  drop constraint if exists inventory_ledger_movement_type_check,
  drop constraint if exists inventory_ledger_source_check;

alter table public.inventory_ledger
  add constraint inventory_ledger_movement_type_check check (
    movement_type in (
      'opening_snapshot', 'sale', 'controlled_adjustment', 'physical_count_adjustment',
      'transfer_out', 'transfer_in'
    )
  ),
  add constraint inventory_ledger_source_check check (
    (movement_type = 'opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null)
    or (movement_type = 'sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null)
    or (movement_type = 'controlled_adjustment' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null)
    or (movement_type = 'physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_transfer_line_id is null)
    or (movement_type in ('transfer_out', 'transfer_in') and inventory_transfer_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null)
  );

create unique index inventory_ledger_transfer_line_movement_once_idx
  on public.inventory_ledger(inventory_transfer_line_id, movement_type)
  where inventory_transfer_line_id is not null;

alter table public.inventory_transfer_lines
  add constraint inventory_transfer_lines_outbound_ledger_fkey
    foreign key (outbound_ledger_id) references public.inventory_ledger(id) on delete restrict,
  add constraint inventory_transfer_lines_inbound_ledger_fkey
    foreign key (inbound_ledger_id) references public.inventory_ledger(id) on delete restrict;
create unique index inventory_transfer_lines_outbound_ledger_once_idx
  on public.inventory_transfer_lines(outbound_ledger_id) where outbound_ledger_id is not null;
create unique index inventory_transfer_lines_inbound_ledger_once_idx
  on public.inventory_transfer_lines(inbound_ledger_id) where inbound_ledger_id is not null;

alter table public.inventory_transfers enable row level security;
alter table public.inventory_transfer_lines enable row level security;

create policy inventory_transfers_read on public.inventory_transfers
  for select to authenticated
  using (
    public.has_company_permission(company_id, 'operate_inventory')
    and (public.can_access_location(source_location_id) or public.can_access_location(destination_location_id))
  );
create policy inventory_transfer_lines_read on public.inventory_transfer_lines
  for select to authenticated
  using (exists (
    select 1 from public.inventory_transfers transfer_data
    where transfer_data.id = inventory_transfer_id
      and public.has_company_permission(transfer_data.company_id, 'operate_inventory')
      and (public.can_access_location(transfer_data.source_location_id) or public.can_access_location(transfer_data.destination_location_id))
  ));

revoke all on public.inventory_transfers, public.inventory_transfer_lines from authenticated;
grant select on public.inventory_transfers, public.inventory_transfer_lines to authenticated;

create or replace function public.assert_inventory_transfer_access(
  p_company_id uuid,
  p_location_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'operate_inventory')
    or not public.can_access_location(p_location_id)
    or not exists (
      select 1 from public.locations location_data
      where location_data.id = p_location_id
        and location_data.company_id = p_company_id
        and location_data.is_active
    ) then
    raise exception 'No autorizado para operar transferencias en esta ubicación.';
  end if;
end;
$$;

create or replace function public.create_inventory_transfer(
  p_company_id uuid,
  p_source_location_id uuid,
  p_destination_location_id uuid,
  p_lines jsonb,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_transfer_id uuid;
  v_received integer;
  v_distinct integer;
begin
  perform public.assert_inventory_transfer_access(p_company_id, p_source_location_id);
  perform public.assert_inventory_transfer_access(p_company_id, p_destination_location_id);
  if p_source_location_id = p_destination_location_id then
    raise exception 'El origen y el destino deben ser distintos.';
  end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then
    raise exception 'Las partidas deben enviarse como una lista.';
  end if;

  select id into v_transfer_id
  from public.inventory_transfers
  where sent_request_id = v_request_id;
  if found then
    return jsonb_build_object('inventory_transfer_id', v_transfer_id, 'status', (select status from public.inventory_transfers where id = v_transfer_id), 'idempotent', true);
  end if;

  select count(*), count(distinct lower(trim(input.product_code)))
  into v_received, v_distinct
  from jsonb_to_recordset(p_lines) input(product_code text, quantity numeric);
  if v_received < 1 or v_received > 500 or v_received <> v_distinct then
    raise exception 'Envía entre 1 y 500 SKU distintos por lote.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_code text, quantity numeric)
    left join public.products product
      on product.company_id = p_company_id
      and lower(product.alpha_sku) = lower(trim(input.product_code))
      and product.is_active
    where nullif(trim(coalesce(input.product_code, '')), '') is null
      or input.quantity is null or input.quantity <= 0
      or product.id is null
  ) then
    raise exception 'El lote contiene SKU inactivos, inexistentes o cantidades no válidas.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_code text, quantity numeric)
    join public.products product
      on product.company_id = p_company_id
      and lower(product.alpha_sku) = lower(trim(input.product_code))
    left join public.inventory_balances balance
      on balance.location_id = p_source_location_id and balance.product_id = product.id
    where coalesce(balance.quantity_on_hand, 0) < input.quantity
  ) then
    raise exception 'El origen no tiene existencia suficiente para enviar todas las partidas.';
  end if;

  insert into public.inventory_transfers(
    company_id, source_location_id, destination_location_id, line_count, sent_request_id, sent_by
  )
  values (p_company_id, p_source_location_id, p_destination_location_id, v_received, v_request_id, auth.uid())
  returning id into v_transfer_id;

  insert into public.inventory_transfer_lines(inventory_transfer_id, product_id, quantity)
  select v_transfer_id, product.id, input.quantity
  from jsonb_to_recordset(p_lines) input(product_code text, quantity numeric)
  join public.products product
    on product.company_id = p_company_id
    and lower(product.alpha_sku) = lower(trim(input.product_code));

  perform public.write_sales_audit(p_company_id, 'inventory_transfer.sent', 'inventory_transfers', v_transfer_id,
    jsonb_build_object('source_location_id', p_source_location_id, 'destination_location_id', p_destination_location_id, 'line_count', v_received, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_transfer_id', v_transfer_id, 'status', 'sent', 'line_count', v_received, 'idempotent', false);
exception when unique_violation then
  select id into v_transfer_id from public.inventory_transfers where sent_request_id = v_request_id;
  if v_transfer_id is not null then
    return jsonb_build_object('inventory_transfer_id', v_transfer_id, 'status', (select status from public.inventory_transfers where id = v_transfer_id), 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.mark_inventory_transfer_in_transit(
  p_inventory_transfer_id uuid,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.inventory_transfers%rowtype;
  v_line public.inventory_transfer_lines%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_balance numeric;
  v_ledger_id uuid;
begin
  select * into v_transfer from public.inventory_transfers where id = p_inventory_transfer_id for update;
  if not found then raise exception 'Transferencia no encontrada.'; end if;
  perform public.assert_inventory_transfer_access(v_transfer.company_id, v_transfer.source_location_id);

  if v_transfer.status = 'in_transit' and v_transfer.transit_request_id = v_request_id then
    return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'in_transit', 'idempotent', true);
  end if;
  if v_transfer.status <> 'sent' then raise exception 'Solo una transferencia enviada puede pasar a tránsito.'; end if;

  for v_line in
    select * from public.inventory_transfer_lines
    where inventory_transfer_id = v_transfer.id
    order by product_id
  loop
    select quantity_on_hand into v_balance
    from public.inventory_balances
    where location_id = v_transfer.source_location_id and product_id = v_line.product_id
    for update;
    if coalesce(v_balance, 0) < v_line.quantity then
      raise exception 'El origen ya no tiene existencia suficiente para marcar la transferencia en tránsito.';
    end if;
  end loop;

  for v_line in
    select * from public.inventory_transfer_lines
    where inventory_transfer_id = v_transfer.id
    order by product_id
  loop
    update public.inventory_balances
    set quantity_on_hand = quantity_on_hand - v_line.quantity, updated_at = now()
    where location_id = v_transfer.source_location_id and product_id = v_line.product_id
    returning quantity_on_hand into v_balance;

    insert into public.inventory_ledger(
      company_id, location_id, product_id, quantity_delta, balance_after,
      movement_type, inventory_transfer_line_id, actor_id
    )
    values (
      v_transfer.company_id, v_transfer.source_location_id, v_line.product_id, -v_line.quantity, v_balance,
      'transfer_out', v_line.id, auth.uid()
    ) returning id into v_ledger_id;
    update public.inventory_transfer_lines set outbound_ledger_id = v_ledger_id where id = v_line.id;
  end loop;

  update public.inventory_transfers
  set status = 'in_transit', transit_request_id = v_request_id, transited_by = auth.uid(), in_transit_at = now()
  where id = v_transfer.id;
  perform public.write_sales_audit(v_transfer.company_id, 'inventory_transfer.in_transit', 'inventory_transfers', v_transfer.id,
    jsonb_build_object('source_location_id', v_transfer.source_location_id, 'destination_location_id', v_transfer.destination_location_id, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'in_transit', 'idempotent', false);
exception when unique_violation then
  select * into v_transfer from public.inventory_transfers where id = p_inventory_transfer_id;
  if v_transfer.transit_request_id = v_request_id and v_transfer.status = 'in_transit' then
    return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'in_transit', 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.receive_inventory_transfer(
  p_inventory_transfer_id uuid,
  p_client_request_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.inventory_transfers%rowtype;
  v_line public.inventory_transfer_lines%rowtype;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_balance numeric;
  v_ledger_id uuid;
begin
  select * into v_transfer from public.inventory_transfers where id = p_inventory_transfer_id for update;
  if not found then raise exception 'Transferencia no encontrada.'; end if;
  perform public.assert_inventory_transfer_access(v_transfer.company_id, v_transfer.destination_location_id);

  if v_transfer.status = 'received' and v_transfer.received_request_id = v_request_id then
    return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'received', 'idempotent', true);
  end if;
  if v_transfer.status <> 'in_transit' then raise exception 'Solo una transferencia en tránsito puede recibirse.'; end if;

  for v_line in
    select * from public.inventory_transfer_lines
    where inventory_transfer_id = v_transfer.id
    order by product_id
  loop
    insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
    values (v_transfer.company_id, v_transfer.destination_location_id, v_line.product_id, v_line.quantity)
    on conflict (location_id, product_id) do update
      set quantity_on_hand = public.inventory_balances.quantity_on_hand + excluded.quantity_on_hand,
          updated_at = now()
    returning quantity_on_hand into v_balance;

    insert into public.inventory_ledger(
      company_id, location_id, product_id, quantity_delta, balance_after,
      movement_type, inventory_transfer_line_id, actor_id
    )
    values (
      v_transfer.company_id, v_transfer.destination_location_id, v_line.product_id, v_line.quantity, v_balance,
      'transfer_in', v_line.id, auth.uid()
    ) returning id into v_ledger_id;
    update public.inventory_transfer_lines set inbound_ledger_id = v_ledger_id where id = v_line.id;
  end loop;

  update public.inventory_transfers
  set status = 'received', received_request_id = v_request_id, received_by = auth.uid(), received_at = now()
  where id = v_transfer.id;
  perform public.write_sales_audit(v_transfer.company_id, 'inventory_transfer.received', 'inventory_transfers', v_transfer.id,
    jsonb_build_object('source_location_id', v_transfer.source_location_id, 'destination_location_id', v_transfer.destination_location_id, 'client_request_id', v_request_id));
  return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'received', 'idempotent', false);
exception when unique_violation then
  select * into v_transfer from public.inventory_transfers where id = p_inventory_transfer_id;
  if v_transfer.received_request_id = v_request_id and v_transfer.status = 'received' then
    return jsonb_build_object('inventory_transfer_id', v_transfer.id, 'status', 'received', 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.list_inventory_transfers(
  p_company_id uuid,
  p_status text default null,
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
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_total integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'operate_inventory') then
    raise exception 'No autorizado para consultar transferencias.';
  end if;
  if p_status is not null and p_status not in ('sent', 'in_transit', 'received') then
    raise exception 'Estado de transferencia no válido.';
  end if;

  select count(*) into v_total
  from public.inventory_transfers transfer_data
  where transfer_data.company_id = p_company_id
    and (p_status is null or transfer_data.status = p_status)
    and (public.can_access_location(transfer_data.source_location_id) or public.can_access_location(transfer_data.destination_location_id));

  return jsonb_build_object('total', v_total, 'items', coalesce((
    select jsonb_agg(to_jsonb(row_data) order by row_data.sent_at desc)
    from (
      select transfer_data.id, transfer_data.source_location_id, source_location.external_code as source_location_code,
        source_location.name as source_location_name, transfer_data.destination_location_id,
        destination_location.external_code as destination_location_code, destination_location.name as destination_location_name,
        transfer_data.status, transfer_data.line_count, transfer_data.sent_at, transfer_data.in_transit_at, transfer_data.received_at,
        sender.full_name as sent_by_name, carrier.full_name as transited_by_name, receiver.full_name as received_by_name
      from public.inventory_transfers transfer_data
      join public.locations source_location on source_location.id = transfer_data.source_location_id
      join public.locations destination_location on destination_location.id = transfer_data.destination_location_id
      left join public.profiles sender on sender.id = transfer_data.sent_by
      left join public.profiles carrier on carrier.id = transfer_data.transited_by
      left join public.profiles receiver on receiver.id = transfer_data.received_by
      where transfer_data.company_id = p_company_id
        and (p_status is null or transfer_data.status = p_status)
        and (public.can_access_location(transfer_data.source_location_id) or public.can_access_location(transfer_data.destination_location_id))
      order by transfer_data.sent_at desc
      offset (v_page - 1) * v_size limit v_size
    ) row_data
  ), '[]'::jsonb));
end;
$$;

create or replace function public.list_inventory_transfer_lines(
  p_inventory_transfer_id uuid,
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
  v_transfer public.inventory_transfers%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_total integer;
begin
  select * into v_transfer from public.inventory_transfers where id = p_inventory_transfer_id;
  if not found then raise exception 'Transferencia no encontrada.'; end if;
  if auth.uid() is null
    or not public.has_company_permission(v_transfer.company_id, 'operate_inventory')
    or not (public.can_access_location(v_transfer.source_location_id) or public.can_access_location(v_transfer.destination_location_id)) then
    raise exception 'No autorizado para consultar esta transferencia.';
  end if;

  select count(*) into v_total from public.inventory_transfer_lines where inventory_transfer_id = v_transfer.id;
  return jsonb_build_object('total', v_total, 'items', coalesce((
    select jsonb_agg(to_jsonb(row_data) order by row_data.product_code)
    from (
      select line.id, line.product_id, product.alpha_sku as product_code, product.name as product_name,
        product.unit, line.quantity, line.outbound_ledger_id is not null as dispatched,
        line.inbound_ledger_id is not null as received
      from public.inventory_transfer_lines line
      join public.products product on product.id = line.product_id
      where line.inventory_transfer_id = v_transfer.id
      order by product.alpha_sku
      offset (v_page - 1) * v_size limit v_size
    ) row_data
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.create_inventory_transfer(uuid,uuid,uuid,jsonb,uuid) from public, anon;
revoke all on function public.mark_inventory_transfer_in_transit(uuid,uuid) from public, anon;
revoke all on function public.receive_inventory_transfer(uuid,uuid) from public, anon;
revoke all on function public.list_inventory_transfers(uuid,text,integer,integer) from public, anon;
revoke all on function public.list_inventory_transfer_lines(uuid,integer,integer) from public, anon;
grant execute on function public.create_inventory_transfer(uuid,uuid,uuid,jsonb,uuid) to authenticated;
grant execute on function public.mark_inventory_transfer_in_transit(uuid,uuid) to authenticated;
grant execute on function public.receive_inventory_transfer(uuid,uuid) to authenticated;
grant execute on function public.list_inventory_transfers(uuid,text,integer,integer) to authenticated;
grant execute on function public.list_inventory_transfer_lines(uuid,integer,integer) to authenticated;
