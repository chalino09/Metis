do $$
begin
  if (select count(*) from public.cash_custody_transfers
    where company_id='4d300000-0000-4000-8000-000000000001' and status='in_transit')<>1
    or (select count(*) from public.cash_custody_transfers
    where company_id='4d300000-0000-4000-8000-000000000001' and status='approved')<>1
  then raise exception 'La concurrencia no dejó exactamente un ganador y un traslado intacto.';end if;
  if public.cash_register_custody_balance_as_of(
    '4d300000-0000-4000-8000-000000000001','4d300000-0000-4000-8000-000000000020',now())<>100
  then raise exception 'La caja concurrente no conservó el saldo exacto de 100.';end if;
  if (select count(*) from public.accounting_events where company_id='4d300000-0000-4000-8000-000000000001'
    and event_type='cash_transfer_dispatched')<>1
  then raise exception 'La concurrencia duplicó la póliza de retiro.';end if;
  raise notice 'M4D3 concurrencia: una sola confirmación ganó, sin sobregiro ni duplicación.';
end
$$;
