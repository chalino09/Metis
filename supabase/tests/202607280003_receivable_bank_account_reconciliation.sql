begin;

do $$
begin
  if to_regprocedure('public.list_receivable_financial_accounts(uuid)') is null then
    raise exception 'Falta el catálogo server-side de cuentas receptoras.';
  end if;
  if to_regprocedure('public.record_receivable_payment_to_account(uuid,uuid,uuid,numeric,uuid,uuid,text,uuid)') is null then
    raise exception 'Falta el registro de cobro con evidencia bancaria.';
  end if;
  if to_regprocedure('public.refresh_bank_reconciliation_candidates_with_receivables(uuid,uuid)') is null then
    raise exception 'Falta el refresco de conciliación de cobros históricos.';
  end if;
  if has_function_privilege('anon', 'public.list_receivable_financial_accounts(uuid)', 'execute')
    or has_function_privilege('anon', 'public.record_receivable_payment_to_account(uuid,uuid,uuid,numeric,uuid,uuid,text,uuid)', 'execute')
    or has_function_privilege('anon', 'public.refresh_bank_reconciliation_candidates_with_receivables(uuid,uuid)', 'execute')
  then
    raise exception 'Las funciones bancarias de cobranza quedaron expuestas a anon.';
  end if;
  if not has_function_privilege('authenticated', 'public.list_receivable_financial_accounts(uuid)', 'execute')
    or not has_function_privilege('authenticated', 'public.record_receivable_payment_to_account(uuid,uuid,uuid,numeric,uuid,uuid,text,uuid)', 'execute')
    or not has_function_privilege('authenticated', 'public.refresh_bank_reconciliation_candidates_with_receivables(uuid,uuid)', 'execute')
  then
    raise exception 'Authenticated no puede operar la cobranza bancaria.';
  end if;
end;
$$;

rollback;
