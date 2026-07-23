-- Satrapy · Inventory replenishment policies and live min/max suggestions.
-- Suggestions are projections of current balances; they never create orders or move stock.

insert into public.permissions (code, description) values
  ('manage_inventory_replenishment', 'Configurar mínimos y máximos de reabastecimiento en ubicaciones autorizadas.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions(role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code = 'manage_inventory_replenishment'
where role_data.code in ('super_admin', 'direccion_admin', 'almacen')
on conflict do nothing;

create table public.inventory_replenishment_policies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  minimum_quantity numeric(18,6) not null check (minimum_quantity > 0),
  maximum_quantity numeric(18,6) not null check (maximum_quantity >= minimum_quantity),
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (location_id, product_id)
);

create index inventory_replenishment_policies_company_location_idx
  on public.inventory_replenishment_policies(company_id, location_id, product_id);

-- A bulk configuration batch makes retries idempotent and leaves a concise,
-- durable audit trail without turning suggestions into business documents.
create table public.inventory_replenishment_policy_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  client_request_id uuid not null,
  line_count integer not null check (line_count between 1 and 500),
  configured_by uuid not null references auth.users(id) on delete restrict,
  configured_at timestamptz not null default now(),
  unique (company_id, client_request_id)
);

create index inventory_replenishment_policy_batches_company_location_idx
  on public.inventory_replenishment_policy_batches(company_id, location_id, configured_at desc);

create or replace function public.assert_inventory_replenishment_policy_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  select company_id into v_company_id from public.locations where id = new.location_id;
  if v_company_id is distinct from new.company_id then
    raise exception 'La política y la ubicación deben pertenecer a la misma empresa.';
  end if;
  select company_id into v_company_id from public.products where id = new.product_id;
  if v_company_id is distinct from new.company_id then
    raise exception 'La política y el producto deben pertenecer a la misma empresa.';
  end if;
  return new;
end;
$$;

create trigger inventory_replenishment_policies_company_integrity
  before insert or update of company_id, location_id, product_id on public.inventory_replenishment_policies
  for each row execute function public.assert_inventory_replenishment_policy_integrity();

create trigger inventory_replenishment_policies_set_updated_at
  before update on public.inventory_replenishment_policies
  for each row execute function public.set_updated_at();

alter table public.inventory_replenishment_policies enable row level security;
alter table public.inventory_replenishment_policy_batches enable row level security;

create policy inventory_replenishment_policies_read on public.inventory_replenishment_policies
  for select to authenticated
  using (
    public.can_access_location(location_id)
    and (
      public.has_company_permission(company_id, 'view_inventory')
      or public.has_company_permission(company_id, 'manage_inventory_replenishment')
    )
  );

create policy inventory_replenishment_policy_batches_read on public.inventory_replenishment_policy_batches
  for select to authenticated
  using (
    public.can_access_location(location_id)
    and public.has_company_permission(company_id, 'manage_inventory_replenishment')
  );

revoke all on public.inventory_replenishment_policies, public.inventory_replenishment_policy_batches from authenticated;
grant select on public.inventory_replenishment_policies, public.inventory_replenishment_policy_batches to authenticated;

create or replace function public.assert_inventory_replenishment_management_access(
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
    or not public.has_company_permission(p_company_id, 'manage_inventory_replenishment')
    or not public.can_access_location(p_location_id)
    or not exists (
      select 1
      from public.locations location_data
      where location_data.id = p_location_id
        and location_data.company_id = p_company_id
        and location_data.is_active
    ) then
    raise exception 'No autorizado para configurar reabastecimiento en esta ubicación.';
  end if;
end;
$$;

create or replace function public.configure_inventory_replenishment_policies(
  p_company_id uuid,
  p_location_id uuid,
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
  v_batch_id uuid;
  v_received integer;
  v_distinct integer;
begin
  perform public.assert_inventory_replenishment_management_access(p_company_id, p_location_id);
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' then
    raise exception 'Las políticas deben enviarse como una lista.';
  end if;

  select id into v_batch_id
  from public.inventory_replenishment_policy_batches
  where company_id = p_company_id and client_request_id = v_request_id;
  if found then
    return jsonb_build_object('batch_id', v_batch_id, 'line_count', (select line_count from public.inventory_replenishment_policy_batches where id = v_batch_id), 'idempotent', true);
  end if;

  select count(*), count(distinct lower(trim(input.product_code)))
  into v_received, v_distinct
  from jsonb_to_recordset(p_lines) input(product_code text, minimum_quantity numeric, maximum_quantity numeric);
  if v_received < 1 or v_received > 500 or v_received <> v_distinct then
    raise exception 'Envía entre 1 y 500 SKU distintos por lote.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_lines) input(product_code text, minimum_quantity numeric, maximum_quantity numeric)
    left join public.products product
      on product.company_id = p_company_id
      and lower(product.alpha_sku) = lower(trim(input.product_code))
      and product.is_active
      and product.is_inventory_tracked
    where nullif(trim(coalesce(input.product_code, '')), '') is null
      or input.minimum_quantity is null or input.minimum_quantity <= 0
      or input.maximum_quantity is null or input.maximum_quantity < input.minimum_quantity
      or product.id is null
  ) then
    raise exception 'El lote contiene SKU no inventariables, inactivos o mínimos/máximos no válidos.';
  end if;

  insert into public.inventory_replenishment_policy_batches(
    company_id, location_id, client_request_id, line_count, configured_by
  )
  values (p_company_id, p_location_id, v_request_id, v_received, auth.uid())
  returning id into v_batch_id;

  insert into public.inventory_replenishment_policies(
    company_id, location_id, product_id, minimum_quantity, maximum_quantity, created_by, updated_by
  )
  select p_company_id, p_location_id, product.id, input.minimum_quantity, input.maximum_quantity, auth.uid(), auth.uid()
  from jsonb_to_recordset(p_lines) input(product_code text, minimum_quantity numeric, maximum_quantity numeric)
  join public.products product
    on product.company_id = p_company_id
    and lower(product.alpha_sku) = lower(trim(input.product_code))
  on conflict (location_id, product_id) do update
    set minimum_quantity = excluded.minimum_quantity,
        maximum_quantity = excluded.maximum_quantity,
        updated_by = auth.uid(),
        updated_at = now();

  perform public.write_sales_audit(
    p_company_id,
    'inventory_replenishment.policies_configured',
    'inventory_replenishment_policy_batch',
    v_batch_id,
    jsonb_build_object(
      'location_id', p_location_id,
      'line_count', v_received,
      'client_request_id', v_request_id
    )
  );

  return jsonb_build_object('batch_id', v_batch_id, 'line_count', v_received, 'idempotent', false);
exception when unique_violation then
  select id into v_batch_id
  from public.inventory_replenishment_policy_batches
  where company_id = p_company_id and client_request_id = v_request_id;
  if v_batch_id is not null then
    return jsonb_build_object('batch_id', v_batch_id, 'line_count', (select line_count from public.inventory_replenishment_policy_batches where id = v_batch_id), 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.list_inventory_replenishment_suggestions(
  p_company_id uuid,
  p_location_id uuid default null,
  p_query text default null,
  p_below_minimum_only boolean default true,
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
  v_query text := lower(trim(coalesce(p_query, '')));
  v_total bigint;
begin
  if auth.uid() is null
    or not (
      public.has_company_permission(p_company_id, 'view_inventory')
      or public.has_company_permission(p_company_id, 'manage_inventory_replenishment')
    ) then
    raise exception 'No autorizado para consultar reabastecimiento.';
  end if;

  if p_location_id is not null and not exists (
    select 1
    from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  select count(*) into v_total
  from public.inventory_replenishment_policies policy
  join public.products product on product.id = policy.product_id and product.company_id = p_company_id
  left join public.inventory_balances balance on balance.location_id = policy.location_id and balance.product_id = policy.product_id
  where policy.company_id = p_company_id
    and product.is_active and product.is_inventory_tracked
    and public.can_access_location(policy.location_id)
    and (p_location_id is null or policy.location_id = p_location_id)
    and (not p_below_minimum_only or coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity)
    and (
      v_query = ''
      or lower(product.name) like '%' || v_query || '%'
      or lower(product.alpha_sku) like '%' || v_query || '%'
      or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
    );

  return jsonb_build_object('total', v_total, 'items', coalesce((
    select jsonb_agg(to_jsonb(row_data) order by row_data.is_below_minimum desc, row_data.shortage_quantity desc, row_data.location_name, row_data.product_name)
    from (
      select
        policy.id as policy_id,
        policy.location_id,
        location_data.external_code as location_code,
        location_data.name as location_name,
        policy.product_id,
        coalesce(product.internal_sku, product.alpha_sku) as product_code,
        product.name as product_name,
        product.unit,
        coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
        policy.minimum_quantity,
        policy.maximum_quantity,
        coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity as is_below_minimum,
        greatest(policy.minimum_quantity - coalesce(balance.quantity_on_hand, 0), 0) as shortage_quantity,
        case
          when coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity
            then policy.maximum_quantity - coalesce(balance.quantity_on_hand, 0)
          else 0
        end as suggested_quantity,
        policy.updated_at
      from public.inventory_replenishment_policies policy
      join public.products product on product.id = policy.product_id and product.company_id = p_company_id
      join public.locations location_data on location_data.id = policy.location_id and location_data.company_id = p_company_id
      left join public.inventory_balances balance on balance.location_id = policy.location_id and balance.product_id = policy.product_id
      where policy.company_id = p_company_id
        and product.is_active and product.is_inventory_tracked
        and public.can_access_location(policy.location_id)
        and (p_location_id is null or policy.location_id = p_location_id)
        and (not p_below_minimum_only or coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity)
        and (
          v_query = ''
          or lower(product.name) like '%' || v_query || '%'
          or lower(product.alpha_sku) like '%' || v_query || '%'
          or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        )
      order by
        (coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity) desc,
        greatest(policy.minimum_quantity - coalesce(balance.quantity_on_hand, 0), 0) desc,
        location_data.name,
        product.name,
        product.id
      offset (v_page - 1) * v_size limit v_size
    ) row_data
  ), '[]'::jsonb));
end;
$$;

revoke all on function public.assert_inventory_replenishment_management_access(uuid,uuid) from public, anon;
revoke all on function public.configure_inventory_replenishment_policies(uuid,uuid,jsonb,uuid) from public, anon;
revoke all on function public.list_inventory_replenishment_suggestions(uuid,uuid,text,boolean,integer,integer) from public, anon;
grant execute on function public.configure_inventory_replenishment_policies(uuid,uuid,jsonb,uuid) to authenticated;
grant execute on function public.list_inventory_replenishment_suggestions(uuid,uuid,text,boolean,integer,integer) to authenticated;
