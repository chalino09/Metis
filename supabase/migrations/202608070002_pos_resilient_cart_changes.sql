-- POS resiliente: cada cambio de partida devuelve la cotización resultante, y
-- admite reintentos idempotentes. Esto no confirma ventas sin conexión.

create table if not exists public.sale_cart_change_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cart_id uuid not null references public.sale_carts(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  client_request_id uuid not null,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity_delta numeric not null check (quantity_delta <> 0),
  result jsonb not null,
  created_at timestamptz not null default now(),
  unique (company_id, client_request_id)
);

create index if not exists sale_cart_change_requests_cart_created_idx
  on public.sale_cart_change_requests(cart_id, created_at desc);

alter table public.sale_cart_change_requests enable row level security;
revoke all on public.sale_cart_change_requests from anon, authenticated;

create or replace function public.change_sale_cart_item_and_quote(
  p_cart_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_expected_revision integer,
  p_client_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_existing public.sale_cart_change_requests%rowtype;
  v_change jsonb;
  v_quote jsonb;
  v_result jsonb;
begin
  if auth.uid() is null or p_client_request_id is null then
    raise exception 'La solicitud idempotente es obligatoria.';
  end if;
  if coalesce(p_quantity_delta, 0) = 0 then
    raise exception 'El cambio de cantidad no puede ser cero.';
  end if;

  select * into v_cart from public.sale_carts where id = p_cart_id;
  if not found or v_cart.cashier_id <> auth.uid() then
    raise exception 'Carrito no disponible.';
  end if;

  -- Serializa reintentos de la misma solicitud antes de tocar la revisión.
  perform pg_advisory_xact_lock(hashtextextended(p_client_request_id::text, 0));
  select * into v_existing
  from public.sale_cart_change_requests
  where company_id = v_cart.company_id and client_request_id = p_client_request_id;
  if found then
    if v_existing.cart_id <> p_cart_id
      or v_existing.product_id <> p_product_id
      or v_existing.quantity_delta <> p_quantity_delta then
      raise exception 'La clave idempotente ya pertenece a otro cambio de carrito.';
    end if;
    return v_existing.result || jsonb_build_object('idempotent', true);
  end if;

  v_change := public.change_sale_cart_item(p_cart_id, p_product_id, p_quantity_delta, p_expected_revision);
  v_quote := public.quote_sale_cart(p_cart_id);
  v_result := v_quote || jsonb_build_object(
    'idempotent', false,
    'change', v_change,
    'client_request_id', p_client_request_id
  );

  insert into public.sale_cart_change_requests(
    company_id, cart_id, requested_by, client_request_id, product_id, quantity_delta, result
  ) values (
    v_cart.company_id, p_cart_id, auth.uid(), p_client_request_id, p_product_id, p_quantity_delta, v_result
  );

  perform public.write_sales_audit(
    v_cart.company_id,
    'sale_cart.item_changed',
    'sale_carts',
    p_cart_id,
    jsonb_build_object(
      'product_id', p_product_id,
      'quantity_delta', p_quantity_delta,
      'revision', v_quote -> 'revision',
      'client_request_id', p_client_request_id
    )
  );
  return v_result;
end $$;

revoke all on function public.change_sale_cart_item_and_quote(uuid, uuid, numeric, integer, uuid) from public, anon;
grant execute on function public.change_sale_cart_item_and_quote(uuid, uuid, numeric, integer, uuid) to authenticated;

comment on function public.change_sale_cart_item_and_quote(uuid, uuid, numeric, integer, uuid) is
  'Cambia una partida y devuelve la nueva cotización en la misma transacción; permite reintentos idempotentes de una cola POS local.';
