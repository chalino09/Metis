\set ON_ERROR_STOP on
do $verify$
declare v_context public.m3e2_concurrency_context%rowtype;
begin
  select * into v_context from public.m3e2_concurrency_context;
  if (select outstanding_amount from public.accounts_payable where id=v_context.payable_overlap)<>20 then raise exception 'La concurrencia permitió sobrepago o aplicó saldo incorrecto.';end if;
  if (select count(*) from public.supplier_payments where proposal_id in (v_context.proposal_a,v_context.proposal_b))<>1 then raise exception 'Debe existir exactamente un pago de las propuestas competidoras.';end if;
  if (select outstanding_amount from public.accounts_payable where id=v_context.payable_idem)<>0 then raise exception 'El pago idempotente no liquidó la CxP.';end if;
  if (select count(*) from public.supplier_payments where proposal_id=v_context.proposal_idem)<>1 or (select count(*) from public.supplier_payment_requests where request_id=v_context.idempotency_key)<>1 then raise exception 'La concurrencia duplicó el pago idempotente.';end if;
  if (select count(*) from public.supplier_payment_applications a join public.supplier_payments p on p.id=a.payment_id where p.company_id=v_context.company_id)<>2 then raise exception 'Las aplicaciones concurrentes no concilian.';end if;
  raise notice 'M3E2 concurrencia: un solo sobrepago ganador e idempotencia concurrente aprobados.';
end $verify$;
