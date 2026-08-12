-- Permite al cajero retirar su propio descuento y descartar una venta en
-- preparación sin depender de un segundo usuario. Ambos flujos conservan
-- evidencia auditada y nunca convierten ni eliminan la venta original.

alter table public.discount_approvals
  drop constraint if exists discount_approvals_status_check;

alter table public.discount_approvals
  add constraint discount_approvals_status_check
  check (status in ('pending', 'approved', 'rejected', 'cancelled'));

alter table public.sale_carts
  drop constraint if exists sale_carts_status_check;

alter table public.sale_carts
  add constraint sale_carts_status_check
  check (status in ('active', 'converted', 'discarded'));

create or replace function public.cancel_own_cart_discount(
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
  v_revision integer;
  v_cancelled_approvals integer := 0;
  v_cleared_lines integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Sesión no disponible.';
  end if;

  select * into v_cart
  from public.sale_carts
  where id = p_cart_id
  for update;

  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then
    raise exception 'Carrito no disponible.';
  end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'apply_discount');
  if v_cart.revision <> p_expected_revision then
    raise exception 'El carrito cambió en otra operación; actualiza la vista.';
  end if;
  if v_cart.sale_discount_status = 'none'
    and v_cart.sale_discount_percent = 0
    and not exists (
      select 1 from public.sale_cart_items
      where cart_id = v_cart.id and (discount_status <> 'none' or discount_percent > 0)
    ) then
    raise exception 'La venta no tiene un descuento para retirar.';
  end if;

  update public.discount_approvals
  set status = 'cancelled',
      decided_by = auth.uid(),
      decided_at = now(),
      decision_reason = 'Retirado por el solicitante'
  where cart_id = v_cart.id
    and requester_id = auth.uid()
    and status = 'pending';
  get diagnostics v_cancelled_approvals = row_count;

  update public.sale_cart_items
  set discount_percent = 0,
      discount_reason = null,
      discount_status = 'none',
      discount_approved_by = null,
      discount_approved_at = null
  where cart_id = v_cart.id
    and (discount_status <> 'none' or discount_percent > 0);
  get diagnostics v_cleared_lines = row_count;

  update public.sale_carts
  set sale_discount_percent = 0,
      sale_discount_reason = null,
      sale_discount_status = 'none',
      sale_discount_approved_by = null,
      sale_discount_approved_at = null,
      revision = revision + 1
  where id = v_cart.id
  returning revision into v_revision;

  perform public.write_sales_audit(
    v_cart.company_id,
    'discount.cancelled',
    'sale_carts',
    v_cart.id,
    jsonb_build_object(
      'scope', 'cart',
      'previous_percent', v_cart.sale_discount_percent,
      'previous_status', v_cart.sale_discount_status,
      'cleared_lines', v_cleared_lines,
      'cancelled_approvals', v_cancelled_approvals,
      'revision', v_revision
    )
  );

  return public.quote_sale_cart(v_cart.id);
end $$;

create or replace function public.discard_own_sale_cart(
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
  v_item_count integer;
  v_cancelled_approvals integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Sesión no disponible.';
  end if;

  select * into v_cart
  from public.sale_carts
  where id = p_cart_id
  for update;

  if not found or v_cart.cashier_id <> auth.uid() or v_cart.status <> 'active' then
    raise exception 'Carrito no disponible.';
  end if;
  perform public.assert_pos_access(v_cart.company_id, v_cart.location_id, 'use_pos');
  if v_cart.revision <> p_expected_revision then
    raise exception 'El carrito cambió en otra operación; actualiza la vista.';
  end if;

  select count(*) into v_item_count
  from public.sale_cart_items
  where cart_id = v_cart.id;

  update public.discount_approvals
  set status = 'cancelled',
      decided_by = auth.uid(),
      decided_at = now(),
      decision_reason = 'Venta descartada por el cajero'
  where cart_id = v_cart.id
    and requester_id = auth.uid()
    and status = 'pending';
  get diagnostics v_cancelled_approvals = row_count;

  update public.sale_carts
  set status = 'discarded',
      revision = revision + 1
  where id = v_cart.id;

  insert into public.sale_carts(
    company_id,
    location_id,
    cash_register_id,
    cash_session_id,
    cashier_id
  ) values (
    v_cart.company_id,
    v_cart.location_id,
    v_cart.cash_register_id,
    v_cart.cash_session_id,
    v_cart.cashier_id
  ) returning id into v_new_cart_id;

  perform public.write_sales_audit(
    v_cart.company_id,
    'sale_cart.discarded',
    'sale_carts',
    v_cart.id,
    jsonb_build_object(
      'replacement_cart_id', v_new_cart_id,
      'item_count', v_item_count,
      'discount_percent', v_cart.sale_discount_percent,
      'discount_status', v_cart.sale_discount_status,
      'cancelled_approvals', v_cancelled_approvals
    )
  );

  return public.quote_sale_cart(v_new_cart_id);
end $$;

revoke all on function public.cancel_own_cart_discount(uuid, integer) from public, anon;
revoke all on function public.discard_own_sale_cart(uuid, integer) from public, anon;
grant execute on function public.cancel_own_cart_discount(uuid, integer) to authenticated;
grant execute on function public.discard_own_sale_cart(uuid, integer) to authenticated;

comment on function public.cancel_own_cart_discount(uuid, integer) is
  'Retira los descuentos del carrito propio y cancela sus solicitudes pendientes, conservando auditoría.';

comment on function public.discard_own_sale_cart(uuid, integer) is
  'Descarta el carrito activo propio y devuelve una cotización vacía de reemplazo, conservando el carrito anterior para auditoría.';
