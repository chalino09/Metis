-- M4C: los cobros externos conservan cuenta, moneda y referencia bancarias.

create or replace function public.list_receivable_financial_accounts(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'record_receivable_payment')
    or not public.has_company_permission(p_company_id, 'view_customer_credit')
  then
    raise exception 'No autorizado para consultar cuentas receptoras.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', account.id,
      'alias', account.alias,
      'institution_name', account.institution_name,
      'currency_code', account.currency_code,
      'masked_ending', '•••• ' || account.account_last4
    ) order by account.alias, account.id)
    from public.financial_accounts account
    where account.company_id = p_company_id and account.is_active
  ), '[]'::jsonb);
end;
$$;

create or replace function public.capture_receivable_payment_bank_evidence()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.financial_accounts%rowtype;
  v_currency text;
  v_account_id uuid;
begin
  if new.settlement_kind <> 'external' then
    return new;
  end if;

  v_account_id := coalesce(
    nullif(current_setting('satrapy.receivable_financial_account_id', true), '')::uuid,
    new.financial_account_id
  );
  if v_account_id is null then
    raise exception 'Selecciona la cuenta financiera que recibió el cobro.';
  end if;

  select * into v_account
  from public.financial_accounts
  where id = v_account_id
    and company_id = new.company_id
    and is_active;
  if not found then raise exception 'Cuenta financiera receptora no disponible.'; end if;

  v_currency := upper(nullif(trim(coalesce(new.currency_code, '')), ''));
  if v_currency is null then
    select min(coalesce(sale.currency_code, customer_price.currency_code, default_price.currency_code))
    into v_currency
    from public.customer_receivables receivable
    join public.customers customer_data on customer_data.id = receivable.customer_id
    left join public.sales sale on sale.id = receivable.sale_id
    left join public.price_lists customer_price on customer_price.id = customer_data.price_list_id
    left join public.companies company_data on company_data.id = receivable.company_id
    left join public.price_lists default_price on default_price.id = company_data.default_price_list_id
    where receivable.company_id = new.company_id
      and receivable.customer_id = new.customer_id
      and receivable.outstanding_amount > 0;
  end if;
  if v_currency is null then raise exception 'No hay una moneda canónica configurada para el cobro.'; end if;
  if v_account.currency_code <> v_currency then raise exception 'La moneda del cobro no coincide con la cuenta financiera.'; end if;

  new.financial_account_id := v_account.id;
  new.currency_code := v_currency;
  new.bank_reference := nullif(trim(coalesce(new.bank_reference, new.payment_reference, '')), '');
  return new;
end;
$$;

drop trigger if exists receivable_payments_bank_evidence on public.receivable_payments;
create trigger receivable_payments_bank_evidence
before insert on public.receivable_payments
for each row execute function public.capture_receivable_payment_bank_evidence();

create or replace function public.record_receivable_payment_to_account(
  p_company_id uuid,
  p_customer_id uuid,
  p_payment_method_id uuid,
  p_amount numeric,
  p_cash_session_id uuid,
  p_client_request_id uuid,
  p_payment_reference text,
  p_financial_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method public.payment_methods%rowtype;
  v_account public.financial_accounts%rowtype;
  v_result jsonb;
  v_payment_id uuid;
  v_payment public.receivable_payments%rowtype;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id, 'record_receivable_payment')
    or not public.has_company_permission(p_company_id, 'view_customer_credit')
  then
    raise exception 'No autorizado para registrar abonos.';
  end if;

  select * into v_method
  from public.payment_methods
  where id = p_payment_method_id and company_id = p_company_id and is_active;
  if not found then raise exception 'Forma de pago no disponible.'; end if;

  if v_method.settlement_kind = 'external' then
    if p_financial_account_id is null then
      raise exception 'Selecciona la cuenta financiera que recibió el cobro.';
    end if;
    select * into v_account
    from public.financial_accounts
    where id = p_financial_account_id and company_id = p_company_id and is_active;
    if not found then raise exception 'Cuenta financiera receptora no disponible.'; end if;
  elsif p_financial_account_id is not null then
    raise exception 'Un cobro de caja no debe asignarse a una cuenta bancaria.';
  end if;

  perform set_config('satrapy.receivable_financial_account_id', coalesce(p_financial_account_id::text, ''), true);
  v_result := public.record_receivable_payment(
    p_company_id,
    p_customer_id,
    p_payment_method_id,
    p_amount,
    p_cash_session_id,
    p_client_request_id,
    p_payment_reference
  );

  v_payment_id := nullif(v_result->>'payment_id', '')::uuid;
  select * into v_payment from public.receivable_payments where id = v_payment_id and company_id = p_company_id;
  if not found or v_payment.currency_code is null then raise exception 'El recibo no devolvió evidencia financiera completa.'; end if;

  if v_method.settlement_kind = 'external' then
    insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
    values (
      p_company_id,
      auth.uid(),
      'receivable_payment.bank_evidence_assigned',
      'receivable_payments',
      v_payment_id,
      jsonb_build_object(
        'financial_account_id', v_account.id,
        'currency_code', v_payment.currency_code,
        'bank_reference', nullif(trim(p_payment_reference), '')
      )
    );
  end if;

  return v_result || jsonb_build_object(
    'financial_account_id', case when v_method.settlement_kind = 'external' then v_account.id else null end,
    'currency_code', v_payment.currency_code
  );
end;
$$;

-- La evidencia histórica se lee desde el recibo canónico: no se modifican documentos confirmados.
create or replace function public.refresh_bank_reconciliation_candidates_with_receivables(p_company_id uuid, p_financial_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_created integer := 0;
begin
  v_result := public.refresh_bank_reconciliation_candidates(p_company_id, p_financial_account_id);

  insert into public.bank_reconciliation_candidates(company_id, bank_transaction_id, source_type, source_id, match_quality, amount_difference, date_difference_days, account_matches, currency_matches, amount_matches, date_matches, reference_matches, evidence)
  select
    p_company_id,
    transaction.id,
    'receivable_payment',
    payment.id,
    case when transaction.amount = payment.amount and transaction.transaction_date = payment.received_at::date and lower(trim(transaction.reference)) = lower(trim(coalesce(payment.bank_reference, payment.payment_reference))) then 'exact' else 'possible' end,
    round(transaction.amount - payment.amount, 6),
    abs(transaction.transaction_date - payment.received_at::date),
    true, true,
    transaction.amount = payment.amount,
    transaction.transaction_date = payment.received_at::date,
    lower(trim(transaction.reference)) = lower(trim(coalesce(payment.bank_reference, payment.payment_reference))),
    jsonb_build_object('account_id', transaction.financial_account_id, 'currency', transaction.currency_code, 'bank_amount', transaction.amount, 'source_amount', payment.amount, 'bank_date', transaction.transaction_date, 'source_date', payment.received_at::date, 'bank_reference', transaction.reference, 'source_reference', coalesce(payment.bank_reference, payment.payment_reference), 'evidence_origin', 'canonical_receipt')
  from public.bank_transactions transaction
  join public.receivable_payments payment
    on payment.company_id = transaction.company_id
   and payment.settlement_kind = 'external'
   and payment.amount between transaction.amount - 1 and transaction.amount + 1
   and payment.received_at::date between transaction.transaction_date - 3 and transaction.transaction_date + 3
  join public.canonical_receivable_receipts receipt on receipt.receivable_payment_id = payment.id
  left join lateral (
    select (array_agg(account.id order by account.id))[1] id
    from public.financial_accounts account
    where account.company_id = payment.company_id
      and account.currency_code = upper(nullif(receipt.payload->>'currency_code', ''))
      and account.is_active
    having count(*) = 1
  ) fallback on payment.financial_account_id is null
  where transaction.company_id = p_company_id
    and transaction.financial_account_id = p_financial_account_id
    and transaction.direction = 'credit'
    and coalesce(payment.currency_code, upper(nullif(receipt.payload->>'currency_code', ''))) = transaction.currency_code
    and coalesce(payment.bank_reference, payment.payment_reference) is not null
    and (payment.financial_account_id = transaction.financial_account_id or (payment.financial_account_id is null and fallback.id = transaction.financial_account_id))
    and not exists(select 1 from public.receivable_payment_reversals reversal where reversal.receivable_payment_id = payment.id)
    and not exists(select 1 from public.bank_reconciliations reconciliation where reconciliation.bank_transaction_id = transaction.id and reconciliation.status = 'confirmed')
  on conflict(bank_transaction_id, source_type, source_id) do nothing;
  get diagnostics v_created = row_count;

  return v_result || jsonb_build_object('historic_receivable_candidates_created', v_created);
end;
$$;

revoke all on function public.list_receivable_financial_accounts(uuid) from public;
revoke all on function public.record_receivable_payment_to_account(uuid,uuid,uuid,numeric,uuid,uuid,text,uuid) from public;
revoke all on function public.refresh_bank_reconciliation_candidates_with_receivables(uuid,uuid) from public;
grant execute on function public.list_receivable_financial_accounts(uuid) to authenticated;
grant execute on function public.record_receivable_payment_to_account(uuid,uuid,uuid,numeric,uuid,uuid,text,uuid) to authenticated;
grant execute on function public.refresh_bank_reconciliation_candidates_with_receivables(uuid,uuid) to authenticated;
