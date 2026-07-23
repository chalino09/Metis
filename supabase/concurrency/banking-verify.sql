do $$begin
  if (select count(*) from public.bank_transactions where statement_batch_id='4c100000-0000-4000-8000-000000000004')<>1 then raise exception 'La promoción concurrente duplicó movimientos.';end if;
  if (select count(*) from public.bank_reconciliation_requests where company_id='4c100000-0000-4000-8000-000000000001' and request_id='4c100000-0000-4000-8000-000000000006')<>1 then raise exception 'La concurrencia duplicó la llave.';end if;
  if (select status from public.bank_statement_batches where id='4c100000-0000-4000-8000-000000000004')<>'promoted' then raise exception 'El lote no quedó promovido.';end if;
  raise notice 'Concurrencia bancaria: dos solicitudes simultáneas, un movimiento y una llave.';
end$$;
