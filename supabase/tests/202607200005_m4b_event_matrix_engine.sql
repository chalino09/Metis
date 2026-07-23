begin;
do $m4b$
declare c uuid:='4b000000-0000-4000-8000-000000000001';u uuid:='4b000000-0000-4000-8000-000000000010';cfg uuid;rs uuid;p uuid;e uuid;r jsonb;controls jsonb;role text;a uuid;
begin
  insert into public.companies(id,legal_name,display_name) values(c,'M4B test','M4B test');insert into auth.users(id,aud,role,email,encrypted_password) values(u,'authenticated','authenticated','m4b@example.com','');insert into public.user_roles(user_id,role_id,company_id) select u,id,c from public.roles where code='direccion_admin';perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level) select c,lpad(n::text,4,'0'),'Cuenta '||n,case when n in(7,8,9,10,11,12,13,14,15,16,17) then 'expense' else 'asset' end,case when n in(2,7,8,9,10,11,12,13,14,15,16,17) then 'credit' else 'debit' end,1 from generate_series(1,30)n;
  select jsonb_object_agg(k,a.id) into controls from (values('accounts_receivable','0001'),('accounts_payable','0002'),('inventory','0003'),('cash','0004'),('banks','0005'),('vat_pending','0006'),('vat_collected','0007'),('vat_paid','0008'),('withholdings','0009'))x(k,code) join public.accounting_accounts a on a.company_id=c and a.code=x.code;
  r:=public.save_accounting_config(c,'MXN',date '2026-07-08','{"format":"4"}','{"vat_pending":"x","vat_collected":"x","vat_paid":"x","withholdings":"x"}',jsonb_build_object('adjustments',u,'close',u,'reopen',u),'M4B',controls);cfg:=(r->>'id')::uuid;perform public.approve_accounting_config(cfg);r:=public.create_accounting_period(c,'2026-07',date '2026-07-01',date '2026-07-31');p:=(r->>'id')::uuid;
  r:=public.create_accounting_event_rule_set(c,'replacement_cost','{"sale":"confirmation"}','Matriz inicial');rs:=(r->>'id')::uuid;
  for role in select unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) loop select id into a from public.accounting_accounts where company_id=c and code=lpad((10+(select count(*) from public.accounting_event_role_accounts where rule_set_id=rs)+1)::text,4,'0');perform public.set_accounting_event_role_account(rs,role,a);end loop;
  perform public.approve_accounting_event_rule_set(rs,'Aprobada para prueba');
  r:=public.capture_accounting_event(c,'receivable_payment_confirmed','receivable_payment','4b000000-0000-4000-8000-000000000020',1,date '2026-07-08',now(),'[{"role":"banks","debit":100,"credit":0},{"role":"accounts_receivable","debit":0,"credit":100}]','{"description":"Cobro"}');e:=(r->>'id')::uuid;
  if r->>'status'<>'posted' or (select count(*) from public.accounting_journal_entries where accounting_event_id=e)<>1 then raise exception 'Evento no contabilizado.';end if;
  r:=public.capture_accounting_event(c,'receivable_payment_confirmed','receivable_payment','4b000000-0000-4000-8000-000000000020',1,date '2026-07-08',now(),'[]','{}');if not (r->>'idempotent')::boolean then raise exception 'Evento duplicado.';end if;
  -- M4D prueba el cierre autorizado; aquí sólo se prepara el estado cerrado para
  -- conservar la regresión del bloqueo del motor M4B.
  update public.accounting_periods set status='closed',closed_by=u,closed_at=now() where id=p;
  begin perform public.capture_accounting_event(c,'supplier_payment_confirmed','supplier_payment','4b000000-0000-4000-8000-000000000021',1,date '2026-07-08',now(),'[{"role":"accounts_payable","debit":50,"credit":0},{"role":"banks","debit":0,"credit":50}]','{}');raise exception 'Periodo cerrado aceptó evento';exception when others then if position('periodo inexistente o cerrado' in lower(sqlerrm))=0 then raise;end if;end;
  raise notice 'M4B matriz/motor: doble entrada, idempotencia, trazabilidad y bloqueo por periodo cerrado validados.';
end;$m4b$;
rollback;
