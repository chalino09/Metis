-- Provider-neutral evidence for card and other externally settled POS payments.
-- The processor remains outside Satrapy for now; its authorization/reference is
-- preserved atomically with the immutable sale and ticket.

alter table public.sale_payments
  add column if not exists payment_reference text;

create or replace function public.capture_pos_payment_reference()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reference text := nullif(trim(current_setting('satrapy.pos_payment_reference', true)), '');
begin
  if new.settlement_kind = 'external' and v_reference is not null then
    new.payment_reference := v_reference;
  end if;
  return new;
end $$;

drop trigger if exists sale_payments_capture_reference on public.sale_payments;
create trigger sale_payments_capture_reference
before insert on public.sale_payments
for each row execute function public.capture_pos_payment_reference();

create or replace function public.add_pos_payment_reference_to_ticket()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_reference text;
begin
  select payment.payment_reference
  into v_reference
  from public.sale_payments payment
  where payment.sale_id = new.sale_id;

  if v_reference is not null then
    new.payload := jsonb_set(new.payload, '{payment,reference}', to_jsonb(v_reference), true);
    new.content_sha256 := encode(extensions.digest(new.payload::text, 'sha256'), 'hex');
  end if;
  return new;
end $$;

drop trigger if exists canonical_tickets_add_payment_reference on public.canonical_tickets;
create trigger canonical_tickets_add_payment_reference
before insert on public.canonical_tickets
for each row execute function public.add_pos_payment_reference_to_ticket();

create or replace function public.complete_pos_sale(
  p_cart_id uuid,
  p_expected_revision integer,
  p_sale_type text,
  p_payment_method_id uuid default null,
  p_received_amount numeric default null,
  p_client_request_id uuid default null,
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cart public.sale_carts%rowtype;
  v_method public.payment_methods%rowtype;
  v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_result jsonb;
  v_ticket_payload jsonb;
begin
  select * into v_cart
  from public.sale_carts
  where id = p_cart_id and cashier_id = auth.uid();
  if not found then raise exception 'Carrito no disponible.'; end if;

  if p_sale_type = 'cash' then
    select * into v_method
    from public.payment_methods
    where id = p_payment_method_id
      and company_id = v_cart.company_id
      and is_active;
    if not found then raise exception 'Forma de pago no disponible.'; end if;
    if v_method.settlement_kind = 'external' and v_reference is null then
      raise exception 'Captura la autorización o referencia del cobro externo.';
    end if;
  else
    v_reference := null;
  end if;

  perform set_config('satrapy.pos_payment_reference', coalesce(v_reference, ''), true);
  v_result := public.complete_sale(
    p_cart_id,
    p_expected_revision,
    p_sale_type,
    p_payment_method_id,
    p_received_amount,
    p_client_request_id
  );

  select ticket.payload into v_ticket_payload
  from public.canonical_tickets ticket
  where ticket.id = (v_result ->> 'ticket_id')::uuid;

  if v_ticket_payload is not null then
    v_result := jsonb_set(v_result, '{ticket}', v_ticket_payload, true);
  end if;
  return v_result;
end $$;

revoke execute on function public.complete_sale(uuid, integer, text, uuid, numeric, uuid)
  from public, authenticated;
grant execute on function public.complete_pos_sale(uuid, integer, text, uuid, numeric, uuid, text)
  to authenticated;
