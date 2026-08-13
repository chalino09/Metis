-- Ventas en espera del POS. Un cajero conserva una sola venta activa y puede
-- suspender varias dentro de su sesión de caja sin reservar inventario.

alter table public.sale_carts
  add column if not exists held_at timestamptz;

alter table public.sale_carts
  drop constraint if exists sale_carts_status_check;

alter table public.sale_carts
  add constraint sale_carts_status_check
  check (status in ('active', 'held', 'converted', 'discarded'));

create index if not exists sale_carts_held_session_cashier_idx
  on public.sale_carts(cash_session_id, cashier_id, held_at desc, id)
  where status = 'held';

create or replace function public.list_own_held_sale_carts(
  p_cash_session_id uuid,
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_session public.cash_sessions%rowtype;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 20), 1), 50);
  v_total integer;
  v_items jsonb;
begin
  if auth.uid() is null then raise exception 'Sesión no disponible.'; end if;
  select * into v_session
  from public.cash_sessions
  where id = p_cash_session_id and opened_by = auth.uid() and status = 'open';
  if not found then raise exception 'La sesión de caja propia no está disponible.'; end if;
  perform public.assert_pos_access(v_session.company_id, v_session.location_id, 'use_pos');

  select count(*) into v_total
  from public.sale_carts cart
  where cart.cash_session_id = v_session.id
    and cart.cashier_id = auth.uid()
    and cart.status = 'held';

  select coalesce(jsonb_agg(jsonb_build_object(
    'cart_id', held.id,
    'revision', held.revision,
    'customer_id', held.customer_id,
    'customer_name', held.customer_name,
    'held_at', held.held_at,
    'item_count', held.item_count,
    'unit_count', held.unit_count,
    'preview_items', held.preview_items,
    'pending_discount_approval', held.pending_discount_approval
  ) order by held.held_at, held.id), '[]'::jsonb)
  into v_items
  from (
    select
      cart.id,
      cart.revision,
      cart.customer_id,
      customer.display_name as customer_name,
      cart.held_at,
      count(item.id)::integer as item_count,
      coalesce(sum(item.quantity), 0) as unit_count,
      coalesce((
        select jsonb_agg(preview.name order by preview.created_at, preview.id)
        from (
          select product.name, line.created_at, line.id
          from public.sale_cart_items line
          join public.products product on product.id = line.product_id
          where line.cart_id = cart.id
          order by line.created_at, line.id
          limit 3
        ) preview
      ), '[]'::jsonb) as preview_items,
      cart.sale_discount_status = 'pending'
        or bool_or(coalesce(item.discount_status = 'pending', false)) as pending_discount_approval
    from public.sale_carts cart
    left join public.customers customer on customer.id = cart.customer_id
    left join public.sale_cart_items item on item.cart_id = cart.id
    where cart.cash_session_id = v_session.id
      and cart.cashier_id = auth.uid()
      and cart.status = 'held'
    group by cart.id, customer.display_name
    order by cart.held_at, cart.id
    limit v_size offset (v_page - 1) * v_size
  ) held;

  return jsonb_build_object(
    'items', v_items,
    'total', coalesce(v_total, 0),
    'page', v_page,
    'page_size', v_size
  );
end $$;

create or replace function public.hold_own_sale_cart(
  p_cart_id uuid,
  p_expected_revision integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_new_cart_id uuid;
  v_held_at timestamptz := now();
  v_held_count integer;
begin
  if auth.uid() is null then raise exception 'Sesión no disponible.'; end if;
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then
    raise exception 'Carrito no disponible.';
  end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if v_cart.revision <> p_expected_revision then
    raise exception 'El carrito cambió en otra operación; actualiza la vista.';
  end if;
  if not exists (select 1 from public.sale_cart_items where cart_id = v_cart.id) then
    raise exception 'Agrega al menos una partida antes de poner la venta en espera.';
  end if;

  update public.sale_carts
  set status = 'held', held_at = v_held_at, revision = revision + 1
  where id = v_cart.id;

  insert into public.sale_carts(
    company_id, location_id, cash_register_id, cash_session_id, cashier_id
  ) values (
    v_cart.company_id, v_cart.location_id, v_cart.cash_register_id,
    v_cart.cash_session_id, v_cart.cashier_id
  ) returning id into v_new_cart_id;

  select count(*) into v_held_count
  from public.sale_carts
  where cash_session_id = v_cart.cash_session_id
    and cashier_id = auth.uid()
    and status = 'held';

  perform public.write_sales_audit(
    v_cart.company_id,
    'sale_cart.held',
    'sale_carts',
    v_cart.id,
    jsonb_build_object(
      'replacement_cart_id', v_new_cart_id,
      'held_at', v_held_at,
      'revision', v_cart.revision + 1
    )
  );

  return jsonb_build_object(
    'quote', public.quote_sale_cart(v_new_cart_id),
    'held_cart_id', v_cart.id,
    'held_count', v_held_count
  );
end $$;

create or replace function public.resume_own_held_sale_cart(
  p_held_cart_id uuid,
  p_expected_held_revision integer,
  p_active_cart_id uuid,
  p_expected_active_revision integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_held public.sale_carts%rowtype;
  v_active public.sale_carts%rowtype;
  v_active_has_items boolean;
  v_held_count integer;
begin
  if auth.uid() is null then raise exception 'Sesión no disponible.'; end if;
  if p_held_cart_id = p_active_cart_id then raise exception 'Selecciona una venta en espera distinta.'; end if;

  -- Un orden estable evita interbloqueos cuando dos pestañas intentan intercambiar carritos.
  perform 1 from public.sale_carts
  where id in (p_held_cart_id, p_active_cart_id)
  order by id
  for update;

  select * into v_held from public.sale_carts where id = p_held_cart_id;
  select * into v_active from public.sale_carts where id = p_active_cart_id;
  if v_held.id is null or v_active.id is null
    or v_held.cashier_id <> auth.uid() or v_active.cashier_id <> auth.uid()
    or v_held.status <> 'held' or v_active.status <> 'active'
    or v_held.cash_session_id <> v_active.cash_session_id then
    raise exception 'Las ventas ya no están disponibles para intercambiarse.';
  end if;
  perform public.assert_pos_access(v_held.company_id, v_held.location_id, 'use_pos');
  if v_held.revision <> p_expected_held_revision
    or v_active.revision <> p_expected_active_revision then
    raise exception 'Una venta cambió en otra operación; actualiza la vista.';
  end if;

  select exists(select 1 from public.sale_cart_items where cart_id = v_active.id)
  into v_active_has_items;

  update public.sale_carts
  set status = case when v_active_has_items then 'held' else 'discarded' end,
      held_at = case when v_active_has_items then now() else null end,
      revision = revision + 1
  where id = v_active.id;

  update public.sale_carts
  set status = 'active', held_at = null, revision = revision + 1
  where id = v_held.id;

  select count(*) into v_held_count
  from public.sale_carts
  where cash_session_id = v_held.cash_session_id
    and cashier_id = auth.uid()
    and status = 'held';

  perform public.write_sales_audit(
    v_held.company_id,
    'sale_cart.resumed',
    'sale_carts',
    v_held.id,
    jsonb_build_object(
      'previous_active_cart_id', v_active.id,
      'previous_active_disposition', case when v_active_has_items then 'held' else 'discarded' end,
      'revision', v_held.revision + 1
    )
  );

  return jsonb_build_object(
    'quote', public.quote_sale_cart(v_held.id),
    'held_count', v_held_count,
    'previous_active_held', v_active_has_items
  );
end $$;

create or replace function public.discard_own_held_sale_cart(
  p_cart_id uuid,
  p_expected_revision integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_item_count integer;
  v_held_count integer;
begin
  if auth.uid() is null then raise exception 'Sesión no disponible.'; end if;
  select * into v_cart from public.sale_carts where id = p_cart_id for update;
  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'held' then
    raise exception 'La venta en espera ya no está disponible.';
  end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if v_cart.revision <> p_expected_revision then
    raise exception 'La venta cambió en otra operación; actualiza la vista.';
  end if;
  select count(*) into v_item_count from public.sale_cart_items where cart_id = v_cart.id;

  update public.discount_approvals
  set status = 'cancelled', decided_by = auth.uid(), decided_at = now(),
      decision_reason = 'Venta en espera descartada por el cajero'
  where cart_id = v_cart.id and status = 'pending';

  update public.sale_carts
  set status = 'discarded', held_at = null, revision = revision + 1
  where id = v_cart.id;

  select count(*) into v_held_count
  from public.sale_carts
  where cash_session_id = v_cart.cash_session_id
    and cashier_id = auth.uid()
    and status = 'held';

  perform public.write_sales_audit(
    v_cart.company_id,
    'sale_cart.held_discarded',
    'sale_carts',
    v_cart.id,
    jsonb_build_object('item_count', v_item_count, 'revision', v_cart.revision + 1)
  );
  return jsonb_build_object('cart_id', v_cart.id, 'held_count', v_held_count);
end $$;

create or replace function public.prevent_cash_session_close_with_held_sales()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_held_count integer;
begin
  if old.status = 'open' and new.status <> 'open' then
    select count(*) into v_held_count
    from public.sale_carts
    where cash_session_id = old.id and status = 'held';
    if v_held_count > 0 then
      raise exception 'Resuelve las % venta(s) en espera antes de cerrar la caja.', v_held_count;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists cash_sessions_require_resolved_held_sales on public.cash_sessions;
create trigger cash_sessions_require_resolved_held_sales
before update of status on public.cash_sessions
for each row execute function public.prevent_cash_session_close_with_held_sales();

revoke all on function public.list_own_held_sale_carts(uuid, integer, integer) from public, anon;
revoke all on function public.hold_own_sale_cart(uuid, integer) from public, anon;
revoke all on function public.resume_own_held_sale_cart(uuid, integer, uuid, integer) from public, anon;
revoke all on function public.discard_own_held_sale_cart(uuid, integer) from public, anon;
grant execute on function public.list_own_held_sale_carts(uuid, integer, integer) to authenticated;
grant execute on function public.hold_own_sale_cart(uuid, integer) to authenticated;
grant execute on function public.resume_own_held_sale_cart(uuid, integer, uuid, integer) to authenticated;
grant execute on function public.discard_own_held_sale_cart(uuid, integer) to authenticated;

comment on function public.hold_own_sale_cart(uuid, integer) is
  'Suspende la venta activa propia y crea su reemplazo vacío sin reservar inventario.';
comment on function public.resume_own_held_sale_cart(uuid, integer, uuid, integer) is
  'Retoma una venta propia e intercambia de forma atómica la venta activa cuando contiene partidas.';
