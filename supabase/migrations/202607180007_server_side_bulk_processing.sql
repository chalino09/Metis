-- Satrapy · Paquete 3: procesamiento masivo acotado en servidor.
-- Mantiene las reglas e idempotencia existentes, pero evita trabajo fila por fila
-- en los flujos que razonablemente pueden alcanzar cientos o miles de partidas.

create or replace function public.apply_receivable_payment_fifo_set(
  p_company_id uuid,
  p_customer_id uuid,
  p_payment_id uuid,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_applied numeric;
  v_application_count integer;
begin
  if v_amount <= 0 then raise exception 'El abono debe ser mayor a cero.'; end if;

  -- Sólo se bloquean los documentos que realmente recibirán el abono y siempre
  -- en el mismo orden FIFO. El bloqueo previo del cliente serializa sus pagos.
  perform 1
  from public.customer_receivables receivable
  join (
    with ordered as (
      select item.id, item.due_date, item.issued_at, item.outstanding_amount,
        coalesce(sum(item.outstanding_amount) over (
          order by item.due_date, item.issued_at, item.id
          rows between unbounded preceding and 1 preceding
        ), 0) as consumed
      from public.customer_receivables item
      where item.company_id = p_company_id
        and item.customer_id = p_customer_id
        and item.outstanding_amount > 0
    )
    select id, due_date, issued_at
    from ordered
    where greatest(least(v_amount - consumed, outstanding_amount), 0) > 0
  ) allocation on allocation.id = receivable.id
  order by allocation.due_date, allocation.issued_at, allocation.id
  for update of receivable;

  with ordered as (
    select item.id, item.due_date, item.issued_at, item.outstanding_amount,
      coalesce(sum(item.outstanding_amount) over (
        order by item.due_date, item.issued_at, item.id
        rows between unbounded preceding and 1 preceding
      ), 0) as consumed
    from public.customer_receivables item
    where item.company_id = p_company_id
      and item.customer_id = p_customer_id
      and item.outstanding_amount > 0
  ), allocations as (
    select id, greatest(least(v_amount - consumed, outstanding_amount), 0) as amount
    from ordered
  )
  insert into public.receivable_payment_applications(receivable_payment_id, receivable_id, amount)
  select p_payment_id, id, amount
  from allocations
  where amount > 0;

  select coalesce(sum(application.amount), 0), count(*)
  into v_applied, v_application_count
  from public.receivable_payment_applications application
  where application.receivable_payment_id = p_payment_id;

  if round(v_applied, 2) <> v_amount then
    raise exception 'El saldo abierto cambió durante la aplicación FIFO. No se aplicó el abono.';
  end if;

  update public.customer_receivables receivable
  set outstanding_amount = receivable.outstanding_amount - application.amount
  from public.receivable_payment_applications application
  where application.receivable_payment_id = p_payment_id
    and application.receivable_id = receivable.id;

  return jsonb_build_object('amount_applied', v_applied, 'application_count', v_application_count);
end;
$$;

revoke all on function public.apply_receivable_payment_fifo_set(uuid,uuid,uuid,numeric) from public, anon, authenticated;

create or replace function public.record_receivable_payment(
  p_company_id uuid,
  p_customer_id uuid,
  p_payment_method_id uuid,
  p_amount numeric,
  p_cash_session_id uuid default null,
  p_client_request_id uuid default null,
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_customer public.customers%rowtype;
  v_method public.payment_methods%rowtype;
  v_session public.cash_sessions%rowtype;
  v_existing public.receivable_payments%rowtype;
  v_payment_id uuid;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_total_open numeric;
  v_currency text;
  v_request_id uuid := coalesce(p_client_request_id, gen_random_uuid());
  v_number bigint;
  v_folio text;
  v_payload jsonb;
  v_receipt_id uuid;
begin
  if v_amount <= 0 then raise exception 'El abono debe ser mayor a cero.'; end if;
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'record_receivable_payment')
    or not public.has_company_permission(p_company_id, 'view_customer_credit')
  then raise exception 'No autorizado para registrar abonos.'; end if;

  select * into v_existing
  from public.receivable_payments
  where company_id = p_company_id and client_request_id = v_request_id;
  if found then
    select id, folio, payload into v_receipt_id, v_folio, v_payload
    from public.canonical_receivable_receipts where receivable_payment_id = v_existing.id;
    return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount,
      'receipt_id', v_receipt_id, 'folio', v_folio, 'receipt', v_payload, 'idempotent', true);
  end if;

  select * into v_customer
  from public.customers where id = p_customer_id and company_id = p_company_id for update;
  if not found then raise exception 'Cliente no encontrado.'; end if;

  select * into v_method
  from public.payment_methods
  where id = p_payment_method_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Forma de pago no disponible.'; end if;

  if v_method.settlement_kind = 'cash_drawer' then
    if p_cash_session_id is null then raise exception 'El abono en efectivo requiere una sesión de caja explícita.'; end if;
    select * into v_session
    from public.cash_sessions
    where id = p_cash_session_id and company_id = p_company_id
      and opened_by = auth.uid() and status = 'open'
    for share;
    if not found then raise exception 'La sesión de caja propia no está disponible.'; end if;
    perform public.assert_pos_access(p_company_id, v_session.location_id, 'record_receivable_payment');
  else
    if p_cash_session_id is not null then raise exception 'Una forma de pago externa no debe afectar una caja.'; end if;
    if nullif(trim(coalesce(p_payment_reference, '')), '') is null then
      raise exception 'La referencia es obligatoria para pagos externos.';
    end if;
  end if;

  select coalesce(sum(receivable.outstanding_amount), 0),
    min(coalesce(sale.currency_code, customer_price.currency_code, default_price.currency_code))
  into v_total_open, v_currency
  from public.customer_receivables receivable
  join public.customers customer_data on customer_data.id = receivable.customer_id
  left join public.sales sale on sale.id = receivable.sale_id
  left join public.price_lists customer_price on customer_price.id = customer_data.price_list_id
  left join public.companies company_data on company_data.id = receivable.company_id
  left join public.price_lists default_price on default_price.id = company_data.default_price_list_id
  where receivable.company_id = p_company_id and receivable.customer_id = p_customer_id
    and receivable.outstanding_amount > 0;
  if v_amount > v_total_open then raise exception 'El abono excede el saldo abierto del cliente.'; end if;
  if v_currency is null then raise exception 'No hay una moneda canónica configurada para los documentos del cliente.'; end if;
  if exists (
    select 1
    from public.customer_receivables receivable
    join public.customers customer_data on customer_data.id = receivable.customer_id
    left join public.sales sale on sale.id = receivable.sale_id
    left join public.price_lists customer_price on customer_price.id = customer_data.price_list_id
    left join public.companies company_data on company_data.id = receivable.company_id
    left join public.price_lists default_price on default_price.id = company_data.default_price_list_id
    where receivable.company_id = p_company_id and receivable.customer_id = p_customer_id
      and receivable.outstanding_amount > 0
      and coalesce(sale.currency_code, customer_price.currency_code, default_price.currency_code) is distinct from v_currency
  ) then raise exception 'El cliente tiene documentos abiertos en más de una moneda; registra el pago por moneda.'; end if;

  insert into public.receivable_payments(
    company_id, customer_id, payment_method_id, payment_method_code, settlement_kind,
    cash_session_id, amount, client_request_id, received_by, payment_reference
  ) values (
    p_company_id, p_customer_id, v_method.id, v_method.code, v_method.settlement_kind,
    case when v_method.settlement_kind = 'cash_drawer' then v_session.id else null end,
    v_amount, v_request_id, auth.uid(), nullif(trim(p_payment_reference), '')
  ) returning id into v_payment_id;

  perform public.apply_receivable_payment_fifo_set(p_company_id, p_customer_id, v_payment_id, v_amount);

  if v_method.settlement_kind = 'cash_drawer' then
    insert into public.cash_movements(
      company_id, cash_session_id, movement_type, amount, actor_id, source_entity_type, source_entity_id
    ) values (
      p_company_id, v_session.id, 'receivable_payment', v_amount, auth.uid(), 'receivable_payments', v_payment_id
    );
  end if;

  insert into public.receivable_receipt_sequences(company_id, next_number)
  values(p_company_id, 1) on conflict(company_id) do nothing;
  select next_number into v_number
  from public.receivable_receipt_sequences where company_id = p_company_id for update;
  update public.receivable_receipt_sequences set next_number = next_number + 1 where company_id = p_company_id;
  v_folio := 'RCB-' || lpad(v_number::text, 10, '0');

  select jsonb_build_object(
    'folio', v_folio, 'issued_at', now(), 'company_id', p_company_id,
    'customer_id', v_customer.id, 'customer_code', v_customer.code,
    'customer_name', v_customer.display_name, 'payment_id', v_payment_id,
    'amount', v_amount, 'currency_code', v_currency,
    'payment_method', v_method.display_name, 'payment_method_code', v_method.code,
    'payment_reference', nullif(trim(p_payment_reference), ''),
    'applications', coalesce(jsonb_agg(jsonb_build_object(
      'receivable_id', receivable.id,
      'reference', coalesce(receivable.source_reference, ticket.folio),
      'amount_applied', application.amount
    ) order by receivable.due_date, receivable.issued_at, receivable.id), '[]'::jsonb)
  ) into v_payload
  from public.receivable_payment_applications application
  join public.customer_receivables receivable on receivable.id = application.receivable_id
  left join public.canonical_tickets ticket on ticket.sale_id = receivable.sale_id
  where application.receivable_payment_id = v_payment_id;

  insert into public.canonical_receivable_receipts(
    company_id, receivable_payment_id, folio, payload, content_sha256
  ) values (
    p_company_id, v_payment_id, v_folio, v_payload, encode(digest(v_payload::text, 'sha256'), 'hex')
  ) returning id into v_receipt_id;
  perform public.write_sales_audit(p_company_id, 'receivable_payment.recorded', 'receivable_payments', v_payment_id,
    jsonb_build_object('customer_id', p_customer_id, 'amount', v_amount,
      'reference', nullif(trim(p_payment_reference), ''), 'receipt_folio', v_folio));
  return jsonb_build_object('payment_id', v_payment_id, 'amount', v_amount,
    'receipt_id', v_receipt_id, 'folio', v_folio, 'receipt', v_payload, 'idempotent', false);
exception when unique_violation then
  select * into v_existing
  from public.receivable_payments
  where company_id = p_company_id and client_request_id = v_request_id;
  if found then
    select id, folio, payload into v_receipt_id, v_folio, v_payload
    from public.canonical_receivable_receipts where receivable_payment_id = v_existing.id;
    return jsonb_build_object('payment_id', v_existing.id, 'amount', v_existing.amount,
      'receipt_id', v_receipt_id, 'folio', v_folio, 'receipt', v_payload, 'idempotent', true);
  end if;
  raise;
end;
$$;

revoke all on function public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text) from public;
grant execute on function public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text) to authenticated;

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
    if nullif(trim(coalesce(p_decision_reason, '')), '') is null then
      raise exception 'Explica por qué se rechaza el conteo.';
    end if;
    update public.inventory_counts
    set status = 'rejected', decision_request_id = v_request_id, decision_result = 'rejected',
      decision_reason = trim(p_decision_reason), decided_by = auth.uid(), decided_at = now()
    where id = v_count.id;
    perform public.write_sales_audit(v_count.company_id, 'inventory_count.rejected', 'inventory_counts', v_count.id,
      jsonb_build_object('location_id', v_count.location_id, 'reason', trim(p_decision_reason),
        'client_request_id', v_request_id));
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'rejected', 'idempotent', false);
  end if;

  if exists (
    select 1
    from public.inventory_count_lines line
    left join public.inventory_balances balance
      on balance.location_id = v_count.location_id and balance.product_id = line.product_id
    where line.inventory_count_id = v_count.id and (
      (line.expected_balance_updated_at is not null and (
        balance.product_id is null or balance.quantity_on_hand <> line.expected_quantity
        or balance.updated_at is distinct from line.expected_balance_updated_at
      ))
      or (line.expected_balance_updated_at is null and coalesce(balance.quantity_on_hand, 0) <> 0)
    )
  ) then raise exception 'El inventario cambió después del conteo. No se aplicaron ajustes.'; end if;

  perform 1
  from public.inventory_balances balance
  join public.inventory_count_lines line
    on line.inventory_count_id = v_count.id and line.product_id = balance.product_id
  where balance.location_id = v_count.location_id
  order by balance.product_id
  for update of balance;

  insert into public.inventory_balances(company_id, location_id, product_id, quantity_on_hand)
  select v_count.company_id, v_count.location_id, line.product_id, line.counted_quantity
  from public.inventory_count_lines line
  where line.inventory_count_id = v_count.id and line.variance_quantity <> 0
  order by line.product_id
  on conflict(location_id, product_id) do update
  set quantity_on_hand = excluded.quantity_on_hand, updated_at = now();

  insert into public.inventory_ledger(
    company_id, location_id, product_id, quantity_delta, balance_after,
    movement_type, inventory_count_line_id, actor_id
  )
  select v_count.company_id, v_count.location_id, line.product_id, line.variance_quantity,
    line.counted_quantity, 'physical_count_adjustment', line.id, auth.uid()
  from public.inventory_count_lines line
  where line.inventory_count_id = v_count.id and line.variance_quantity <> 0
  order by line.product_id;

  update public.inventory_count_lines line
  set adjustment_ledger_id = ledger.id
  from public.inventory_ledger ledger
  where line.inventory_count_id = v_count.id
    and ledger.inventory_count_line_id = line.id;

  update public.inventory_counts
  set status = 'posted', decision_request_id = v_request_id, decision_result = 'approved',
    decision_reason = nullif(trim(p_decision_reason), ''), decided_by = auth.uid(),
    decided_at = now(), posted_at = now()
  where id = v_count.id;
  perform public.write_sales_audit(v_count.company_id, 'inventory_count.approved_and_posted', 'inventory_counts', v_count.id,
    jsonb_build_object('location_id', v_count.location_id, 'variance_line_count', v_count.variance_line_count,
      'client_request_id', v_request_id));
  return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'posted',
    'variance_line_count', v_count.variance_line_count, 'idempotent', false);
exception when unique_violation then
  select * into v_count from public.inventory_counts where id = p_inventory_count_id;
  if v_count.decision_request_id = v_request_id and v_count.status = 'posted' then
    return jsonb_build_object('inventory_count_id', v_count.id, 'status', 'posted',
      'variance_line_count', v_count.variance_line_count, 'idempotent', true);
  end if;
  raise;
end;
$$;

create or replace function public.save_supplier_payment_proposal(
  p_company_id uuid,
  p_proposal_id uuid,
  p_supplier_id uuid,
  p_currency_code text,
  p_lines jsonb,
  p_client_request_id uuid,
  p_expected_updated_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.supplier_payment_proposal_requests%rowtype;
  v_proposal public.supplier_payment_proposals%rowtype;
  v_id uuid;
  v_currency text := upper(trim(coalesce(p_currency_code, '')));
  v_line_count integer;
  v_distinct_count integer;
  v_missing_count integer;
  v_wrong_owner_count integer;
  v_invalid_amount_count integer;
  v_total numeric;
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'prepare_supplier_payment_proposals') then
    raise exception 'No autorizado para preparar propuestas de pago.';
  end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || p_client_request_id::text, 0));
  select * into v_existing
  from public.supplier_payment_proposal_requests
  where company_id = p_company_id and request_id = p_client_request_id;
  if found then
    if v_existing.operation <> 'save' then raise exception 'La llave de idempotencia pertenece a otra operación.'; end if;
    return v_existing.result || jsonb_build_object('idempotent', true);
  end if;
  if v_currency !~ '^[A-Z]{3}$' then raise exception 'Moneda inválida.'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'La propuesta requiere al menos una CxP.';
  end if;

  begin
    select count(*), count(distinct line.accounts_payable_id)
    into v_line_count, v_distinct_count
    from jsonb_to_recordset(p_lines) as line(accounts_payable_id uuid, proposed_amount numeric);
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Partida o importe propuesto inválido.';
  end;
  if v_line_count <> jsonb_array_length(p_lines) then raise exception 'Partida inválida.'; end if;
  if v_distinct_count <> v_line_count then raise exception 'Una CxP no puede repetirse en la propuesta.'; end if;

  if p_proposal_id is null then
    v_id := gen_random_uuid();
    insert into public.supplier_payment_proposals(id, company_id, supplier_id, currency_code)
    values(v_id, p_company_id, p_supplier_id, v_currency);
  else
    select * into v_proposal
    from public.supplier_payment_proposals
    where id = p_proposal_id and company_id = p_company_id
    for update;
    if not found or v_proposal.status <> 'draft' then raise exception 'Borrador de propuesta no disponible.'; end if;
    if p_expected_updated_at is not null and v_proposal.updated_at <> p_expected_updated_at then
      raise exception 'La propuesta cambió; recargue antes de guardar.';
    end if;
    v_id := v_proposal.id;
  end if;

  -- Bloqueo determinista de todas las CxP participantes antes de validar y escribir.
  perform 1
  from public.accounts_payable payable
  join jsonb_to_recordset(p_lines) as line(accounts_payable_id uuid, proposed_amount numeric)
    on line.accounts_payable_id = payable.id
  where payable.company_id = p_company_id
  order by payable.id
  for update of payable;

  select
    count(*) filter(where payable.id is null),
    count(*) filter(where payable.id is not null and (
      payable.reversed_at is not null or payable.outstanding_amount <= 0
      or payable.supplier_id <> p_supplier_id or payable.currency_code <> v_currency
    )),
    count(*) filter(where line.proposed_amount is null or line.proposed_amount <= 0
      or (payable.id is not null and line.proposed_amount > payable.outstanding_amount)),
    round(coalesce(sum(line.proposed_amount), 0), 6)
  into v_missing_count, v_wrong_owner_count, v_invalid_amount_count, v_total
  from jsonb_to_recordset(p_lines) as line(accounts_payable_id uuid, proposed_amount numeric)
  left join public.accounts_payable payable
    on payable.id = line.accounts_payable_id and payable.company_id = p_company_id;

  if v_missing_count > 0 then raise exception 'CxP no disponible para propuesta.'; end if;
  if v_wrong_owner_count > 0 then raise exception 'Todas las CxP deben estar vigentes y pertenecer al mismo proveedor y moneda.'; end if;
  if v_invalid_amount_count > 0 then raise exception 'El importe propuesto debe ser positivo y no superar el saldo actual.'; end if;

  if p_proposal_id is not null then
    update public.supplier_payment_proposals
    set supplier_id = p_supplier_id, currency_code = v_currency, updated_by = auth.uid()
    where id = v_id;
    delete from public.supplier_payment_proposal_lines where proposal_id = v_id;
  end if;

  insert into public.supplier_payment_proposal_lines(
    company_id, proposal_id, accounts_payable_id, proposed_amount, balance_snapshot, due_date_snapshot
  )
  select p_company_id, v_id, payable.id, line.proposed_amount,
    payable.outstanding_amount, payable.due_date
  from jsonb_to_recordset(p_lines) as line(accounts_payable_id uuid, proposed_amount numeric)
  join public.accounts_payable payable
    on payable.id = line.accounts_payable_id and payable.company_id = p_company_id
  order by payable.id;

  update public.supplier_payment_proposals
  set total_proposed = v_total, updated_by = auth.uid()
  where id = v_id
  returning * into v_proposal;
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(),
    case when p_proposal_id is null then 'supplier_payment_proposal.created' else 'supplier_payment_proposal.updated' end,
    'supplier_payment_proposal', v_id,
    jsonb_build_object('supplier_id', p_supplier_id, 'currency_code', v_currency,
      'line_count', v_line_count, 'total_proposed', v_total, 'client_request_id', p_client_request_id));
  v_result := jsonb_build_object('id', v_id, 'status', 'draft', 'total_proposed', v_total,
    'updated_at', v_proposal.updated_at, 'line_count', v_line_count, 'idempotent', false);
  insert into public.supplier_payment_proposal_requests(company_id, request_id, proposal_id, operation, result)
  values(p_company_id, p_client_request_id, v_id, 'save', v_result);
  return v_result;
end;
$$;

