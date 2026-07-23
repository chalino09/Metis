-- Satrapy · M4D1: confiabilidad del núcleo financiero.
-- Este archivo sustituye el borrador prematuro de cierre. M4D1 sólo corrige
-- auxiliares y reportes históricos; no crea cierres, sucursales ni clasificación.

insert into public.permissions(code,description) values
  ('view_financial_statements','Consultar mayor, auxiliares, balanza y estados financieros reproducibles.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code='view_financial_statements'
on conflict do nothing;

create index if not exists accounting_journal_entries_report_idx
  on public.accounting_journal_entries(company_id,entry_date,entry_number,id) where status='posted';
create index if not exists receivable_payments_as_of_idx
  on public.receivable_payments(company_id,received_at,id);
create index if not exists supplier_payment_applications_as_of_idx
  on public.supplier_payment_applications(company_id,applied_at,payment_id,accounts_payable_id);
create index if not exists inventory_ledger_as_of_idx
  on public.inventory_ledger(company_id,occurred_at,location_id,product_id,id);
create index if not exists cash_movements_as_of_idx
  on public.cash_movements(company_id,occurred_at,cash_session_id,id);
create index if not exists bank_reconciliations_as_of_idx
  on public.bank_reconciliations(company_id,confirmed_at,disconnected_at,bank_transaction_id);

-- El cobro de una venta a crédito vuelve efectivo su IVA en proporción a las
-- aplicaciones. El trigger es diferido, por lo que las aplicaciones inmutables
-- ya existen cuando se captura el evento. Las reversas siguen siendo exactas.
create or replace function public.capture_receivable_payment_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_role text;v_lines jsonb;v_vat numeric:=0;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  v_role:=case when new.settlement_kind='cash_drawer' then 'cash' else 'banks' end;
  select round(coalesce(sum(a.amount*case when s.total_amount>0 then s.tax_amount/s.total_amount else 0 end),0),6)
    into v_vat
  from public.receivable_payment_applications a
  join public.customer_receivables r on r.id=a.receivable_id
  join public.sales s on s.id=r.sale_id
  where a.receivable_payment_id=new.id;
  v_lines:=jsonb_build_array(
    jsonb_build_object('role',v_role,'debit',new.amount,'credit',0,'description','Cobro recibido'),
    jsonb_build_object('role','accounts_receivable','debit',0,'credit',new.amount,'description','Aplicación a CxC')
  );
  if v_vat>0 then
    v_lines:=v_lines||jsonb_build_array(
      jsonb_build_object('role','vat_pending','debit',v_vat,'credit',0,'description','IVA efectivamente cobrado'),
      jsonb_build_object('role','vat_collected','debit',0,'credit',v_vat,'description','IVA efectivamente cobrado')
    );
  end if;
  perform public.capture_accounting_event(new.company_id,'receivable_payment_confirmed','receivable_payment',new.id,1,new.received_at::date,new.received_at,v_lines,jsonb_build_object('description','Cobro confirmado','settlement_kind',new.settlement_kind,'vat_collected',v_vat));
  return new;
end $$;

-- Reconstruye cada auxiliar desde evidencia fechada. Nunca consulta los saldos
-- vivos de CxC, CxP o inventario para contestar una fecha histórica.
create or replace function public.canonical_accounting_auxiliaries(p_company_id uuid,p_as_of date)
returns table(control_key text,amount numeric,detail jsonb)
language sql stable security definer set search_path=public as $$
  with receivable_as_of as (
    select r.id,greatest(0,round(
      case when exists(
        select 1 from public.sale_cancellations sc
        where sc.sale_id=r.sale_id and sc.cancelled_at<(p_as_of+1)::timestamptz
      ) then 0 else r.original_amount-coalesce((
        select sum(a.amount)
        from public.receivable_payment_applications a
        join public.receivable_payments p on p.id=a.receivable_payment_id
        where a.receivable_id=r.id
          and p.received_at<(p_as_of+1)::timestamptz
          and a.created_at<(p_as_of+1)::timestamptz
          and not exists(
            select 1 from public.receivable_payment_reversals rv
            where rv.receivable_payment_id=p.id and rv.reversed_at<(p_as_of+1)::timestamptz
          )
      ),0) end,6)) balance
    from public.customer_receivables r
    where r.company_id=p_company_id and r.issued_at<(p_as_of+1)::timestamptz
  ), payable_as_of as (
    select ap.id,greatest(0,round(ap.original_base_amount
      -coalesce((
        select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)
        from public.supplier_invoices cn
        where cn.original_invoice_id=ap.supplier_invoice_id
          and cn.company_id=p_company_id and cn.document_type='credit_note'
          and cn.confirmed_at<(p_as_of+1)::timestamptz and cn.issued_date<=p_as_of
          and (cn.reversed_at is null or cn.reversed_at>=(p_as_of+1)::timestamptz)
      ),0)
      -coalesce((
        select sum(pa.amount*ap.exchange_rate)
        from public.supplier_payment_applications pa
        join public.supplier_payments p on p.id=pa.payment_id
        where pa.accounts_payable_id=ap.id and pa.applied_at<(p_as_of+1)::timestamptz
          and p.effective_date<=p_as_of and p.confirmed_at<(p_as_of+1)::timestamptz
          and (p.reversed_at is null or p.reversed_at>=(p_as_of+1)::timestamptz)
      ),0),6)) balance
    from public.accounts_payable ap
    join public.supplier_invoices si on si.id=ap.supplier_invoice_id
    where ap.company_id=p_company_id and ap.issued_date<=p_as_of
      and si.confirmed_at<(p_as_of+1)::timestamptz
      and (si.reversed_at is null or si.reversed_at>=(p_as_of+1)::timestamptz)
  ), inventory_quantity as (
    select l.location_id,l.product_id,sum(l.quantity_delta) quantity
    from public.inventory_ledger l
    where l.company_id=p_company_id and l.occurred_at<(p_as_of+1)::timestamptz
    group by l.location_id,l.product_id
  ), inventory_as_of as (
    select q.location_id,q.product_id,q.quantity,c.amount unit_cost
    from inventory_quantity q
    left join lateral (
      select pc.amount
      from public.product_costs pc
      left join public.accounting_event_rule_sets rs
        on rs.company_id=pc.company_id and rs.status='approved'
      where pc.company_id=p_company_id and pc.product_id=q.product_id
        and pc.cost_type=coalesce(rs.cost_method,'replacement_cost')
        and pc.valid_from<(p_as_of+1)::timestamptz
        and (pc.valid_to is null or pc.valid_to>p_as_of::timestamptz)
      order by pc.valid_from desc,pc.id desc limit 1
    )c on true
  ), latest_statement as (
    select distinct on (b.financial_account_id)
      b.id,b.financial_account_id,b.closing_balance,b.period_end
    from public.bank_statement_batches b
    where b.company_id=p_company_id and b.status='promoted' and b.balance_valid
      and b.period_end<=p_as_of and b.promoted_at<(p_as_of+1)::timestamptz
    order by b.financial_account_id,b.period_end desc,b.promoted_at desc,b.id desc
  ), bank_state as (
    select ls.id,ls.financial_account_id,ls.closing_balance,
      count(t.id) filter(where t.amount<>0) movement_count,
      count(t.id) filter(where t.amount<>0 and exists(
        select 1 from public.bank_reconciliations r
        where r.bank_transaction_id=t.id and r.status in ('confirmed','disconnected')
          and r.confirmed_at<(p_as_of+1)::timestamptz
          and (r.disconnected_at is null or r.disconnected_at>=(p_as_of+1)::timestamptz)
      )) reconciled_count,
      count(t.id) filter(where t.amount<>0 and exists(
        select 1 from public.bank_reconciliations r
        where r.bank_transaction_id=t.id and r.status='disconnected'
          and r.disconnected_at<(p_as_of+1)::timestamptz
      )) disconnected_count,
      count(t.id) filter(where t.amount<>0 and not exists(
        select 1 from public.bank_reconciliations r
        where r.bank_transaction_id=t.id
          and r.confirmed_at<(p_as_of+1)::timestamptz
      )) pending_count
    from latest_statement ls
    left join public.bank_transactions t on t.statement_batch_id=ls.id and t.transaction_date<=p_as_of
    group by ls.id,ls.financial_account_id,ls.closing_balance
  ), tax_signed as (
    select line->>'role' role,
      sum(coalesce((line->>'debit')::numeric,0)-coalesce((line->>'credit')::numeric,0)) signed_amount
    from public.accounting_events e
    cross join lateral jsonb_array_elements(e.requested_lines) line
    where e.company_id=p_company_id and e.status='posted' and e.accounting_date<=p_as_of
      and line->>'role' in ('vat_pending','vat_collected','vat_paid','withholdings')
    group by line->>'role'
  ), tax_auxiliary as (
    select c.control_key,
      case when a.normal_balance='debit' then coalesce(t.signed_amount,0) else -coalesce(t.signed_amount,0) end amount
    from public.accounting_config_versions v
    join public.accounting_control_accounts c on c.config_version_id=v.id
    join public.accounting_accounts a on a.id=c.account_id
    left join tax_signed t on t.role=c.control_key
    where v.company_id=p_company_id and v.status='approved'
      and c.control_key in ('vat_pending','vat_collected','vat_paid','withholdings')
  )
  select 'accounts_receivable',coalesce(sum(balance),0),jsonb_build_object(
    'documents',count(*),'open_documents',count(*) filter(where balance<>0),
    'basis','documents minus applications and effective reversals through cutoff','reconcilable',true
  ) from receivable_as_of
  union all
  select 'accounts_payable',coalesce(sum(balance),0),jsonb_build_object(
    'documents',count(*),'open_documents',count(*) filter(where balance<>0),
    'basis','invoices minus credit notes and payments, including effective reversals through cutoff','reconcilable',true
  ) from payable_as_of
  union all
  select 'inventory',coalesce(sum(quantity*coalesce(unit_cost,0)),0),jsonb_build_object(
    'balances',count(*),'quantity',coalesce(sum(quantity),0),'missing_cost_balances',count(*) filter(where quantity<>0 and unit_cost is null),
    'valuation','quantity and configured cost valid at cutoff','reconcilable',count(*) filter(where quantity<>0 and unit_cost is null)=0
  ) from inventory_as_of
  union all
  select 'cash',coalesce(sum(m.amount),0),jsonb_build_object(
    'movements',count(*),'sessions_in_custody',(select count(*) from public.cash_sessions s where s.company_id=p_company_id and s.opened_at<(p_as_of+1)::timestamptz and (s.closed_at is null or s.closed_at>=(p_as_of+1)::timestamptz)),
    'basis','movements and custody existing at cutoff','reconcilable',true
  ) from public.cash_movements m where m.company_id=p_company_id and m.occurred_at<(p_as_of+1)::timestamptz
  union all
  select 'banks',coalesce(sum(closing_balance),0),jsonb_build_object(
    'accounts',count(*),'statements',count(*),'movements',coalesce(sum(movement_count),0),
    'reconciled_movements',coalesce(sum(reconciled_count),0),'pending_movements',coalesce(sum(pending_count),0),
    'disconnected_movements',coalesce(sum(disconnected_count),0),'reconciliation_status','confirmed',
    'basis','latest promoted balanced statement per account at cutoff','reconcilable',count(*)>0
  ) from bank_state
  union all
  select k.control_key,coalesce(t.amount,0),jsonb_build_object('source','posted effective accounting events through cutoff','reconcilable',true)
  from unnest(array['vat_pending','vat_collected','vat_paid','withholdings']) k(control_key)
  left join tax_auxiliary t on t.control_key=k.control_key
$$;

create or replace function public.list_accounting_report(
  p_company_id uuid,p_report_type text,p_starts_on date,p_ends_on date,
  p_account_id uuid default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_rows jsonb:='[]'::jsonb;v_total bigint:=0;v_offset integer;v_config uuid;
  v_totals jsonb:='{}'::jsonb;v_balanced boolean;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_financial_statements') or public.has_company_permission(p_company_id,'view_accounting')) then raise exception 'No autorizado para consultar estados financieros.';end if;
  if p_report_type not in ('general_ledger','auxiliaries','trial_balance','income_statement','balance_sheet','cash_flow') or p_starts_on is null or p_ends_on is null or p_starts_on>p_ends_on then raise exception 'Consulta financiera inválida.';end if;
  if p_account_id is not null and not exists(select 1 from public.accounting_accounts where id=p_account_id and company_id=p_company_id) then raise exception 'La cuenta no pertenece a la empresa.';end if;
  p_page:=greatest(coalesce(p_page,1),1);p_page_size:=least(greatest(coalesce(p_page_size,50),1),200);v_offset:=(p_page-1)*p_page_size;
  select id into v_config from public.accounting_config_versions where company_id=p_company_id and status='approved';

  if p_report_type='general_ledger' then
    select count(*),jsonb_build_object('debit',coalesce(sum(l.debit),0),'credit',coalesce(sum(l.credit),0))
      into v_total,v_totals
    from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id
    where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on and (p_account_id is null or l.account_id=p_account_id);
    select coalesce(jsonb_agg(to_jsonb(x) order by x.code,x.entry_date,x.entry_number,x.line_number),'[]') into v_rows
    from (
      select e.entry_date,e.entry_number,e.description entry_description,l.line_number,a.id account_id,a.code,a.name,a.normal_balance,l.description,l.debit,l.credit,
        case when a.normal_balance='debit' then coalesce(o.opening,0) else -coalesce(o.opening,0) end opening_balance,
        case when a.normal_balance='debit' then coalesce(o.opening,0)+sum(l.debit-l.credit) over(partition by l.account_id order by e.entry_date,e.entry_number,l.line_number,l.id)
             else -(coalesce(o.opening,0)+sum(l.debit-l.credit) over(partition by l.account_id order by e.entry_date,e.entry_number,l.line_number,l.id)) end running_balance
      from public.accounting_journal_lines l
      join public.accounting_journal_entries e on e.id=l.journal_entry_id
      join public.accounting_accounts a on a.id=l.account_id
      left join lateral (
        select coalesce(sum(ol.debit-ol.credit),0) opening
        from public.accounting_journal_lines ol join public.accounting_journal_entries oe on oe.id=ol.journal_entry_id
        where ol.company_id=p_company_id and ol.account_id=l.account_id and oe.status='posted' and oe.entry_date<p_starts_on
      )o on true
      where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on and (p_account_id is null or l.account_id=p_account_id)
      order by a.code,e.entry_date,e.entry_number,l.line_number,l.id limit p_page_size offset v_offset
    )x;

  elsif p_report_type='auxiliaries' then
    with rows as materialized (
      select c.control_key,c.account_id,a.code,a.name,a.normal_balance,
        case when a.normal_balance='debit' then coalesce(l.signed_amount,0) else -coalesce(l.signed_amount,0) end ledger_amount,
        x.amount auxiliary_amount,
        round((case when a.normal_balance='debit' then coalesce(l.signed_amount,0) else -coalesce(l.signed_amount,0) end)-x.amount,6) difference,x.detail
      from public.accounting_control_accounts c
      join public.accounting_accounts a on a.id=c.account_id
      join public.canonical_accounting_auxiliaries(p_company_id,p_ends_on)x on x.control_key=c.control_key
      left join lateral (
        select coalesce(sum(jl.debit-jl.credit),0) signed_amount
        from public.accounting_journal_lines jl join public.accounting_journal_entries je on je.id=jl.journal_entry_id
        where jl.company_id=p_company_id and jl.account_id=c.account_id and je.status='posted' and je.entry_date<=p_ends_on
      )l on true where c.config_version_id=v_config
    )
    select count(*),coalesce((select jsonb_agg(to_jsonb(p) order by p.control_key) from (select * from rows order by control_key limit p_page_size offset v_offset)p),'[]'),
      jsonb_build_object('ledger_amount',coalesce(sum(ledger_amount),0),'auxiliary_amount',coalesce(sum(auxiliary_amount),0),'difference',coalesce(sum(difference),0))
    into v_total,v_rows,v_totals from rows;

  elsif p_report_type='trial_balance' then
    with balances as materialized (
      select a.id account_id,a.code,a.name,a.account_type,a.normal_balance,
        coalesce(sum(l.debit)filter(where e.entry_date<p_starts_on),0) opening_debit,
        coalesce(sum(l.credit)filter(where e.entry_date<p_starts_on),0) opening_credit,
        coalesce(sum(l.debit)filter(where e.entry_date between p_starts_on and p_ends_on),0) debit,
        coalesce(sum(l.credit)filter(where e.entry_date between p_starts_on and p_ends_on),0) credit
      from public.accounting_accounts a
      left join public.accounting_journal_lines l on l.account_id=a.id
      left join public.accounting_journal_entries e on e.id=l.journal_entry_id and e.status='posted' and e.entry_date<=p_ends_on
      where a.company_id=p_company_id and (p_account_id is null or a.id=p_account_id)
      group by a.id
    ), rows as materialized (
      select account_id,code,name,account_type,normal_balance,
        case when normal_balance='debit' then opening_debit-opening_credit else opening_credit-opening_debit end opening_balance,
        debit,credit,
        case when normal_balance='debit' then opening_debit-opening_credit+debit-credit else opening_credit-opening_debit+credit-debit end ending_balance
      from balances where opening_debit<>0 or opening_credit<>0 or debit<>0 or credit<>0
    )
    select count(*),coalesce((select jsonb_agg(to_jsonb(p) order by p.code) from (select * from rows order by code limit p_page_size offset v_offset)p),'[]'),
      jsonb_build_object('opening_debit',coalesce(sum(opening_debit),0),'opening_credit',coalesce(sum(opening_credit),0),'debit',coalesce(sum(debit),0),'credit',coalesce(sum(credit),0),'ending_debit',coalesce(sum(greatest(opening_debit-opening_credit+debit-credit,0)),0),'ending_credit',coalesce(sum(greatest(opening_credit-opening_debit+credit-debit,0)),0))
    into v_total,v_rows,v_totals from balances where opening_debit<>0 or opening_credit<>0 or debit<>0 or credit<>0;

  elsif p_report_type='income_statement' then
    with rows as materialized (
      select a.id account_id,a.code,a.name,a.account_type,a.normal_balance,
        coalesce(sum(l.debit),0) debit,coalesce(sum(l.credit),0) credit,
        case when a.normal_balance='debit' then coalesce(sum(l.debit-l.credit),0) else coalesce(sum(l.credit-l.debit),0) end period_amount
      from public.accounting_accounts a
      join public.accounting_journal_lines l on l.account_id=a.id
      join public.accounting_journal_entries e on e.id=l.journal_entry_id and e.status='posted'
      where a.company_id=p_company_id and a.account_type in ('revenue','expense')
        and e.entry_date between p_starts_on and p_ends_on and (p_account_id is null or a.id=p_account_id)
      group by a.id
    )
    select count(*),coalesce((select jsonb_agg(to_jsonb(p) order by p.code) from (select * from rows where debit<>0 or credit<>0 order by code limit p_page_size offset v_offset)p),'[]'),
      jsonb_build_object('revenue',coalesce(sum(period_amount)filter(where account_type='revenue'),0),'expense',coalesce(sum(period_amount)filter(where account_type='expense'),0),'net_income',coalesce(sum(period_amount)filter(where account_type='revenue'),0)-coalesce(sum(period_amount)filter(where account_type='expense'),0),'debit',coalesce(sum(debit),0),'credit',coalesce(sum(credit),0))
    into v_total,v_rows,v_totals from rows where debit<>0 or credit<>0;

  elsif p_report_type='balance_sheet' then
    with account_rows as materialized (
      select a.id account_id,a.code,a.name,a.account_type,a.normal_balance,
        case when a.normal_balance='debit' then coalesce(sum(l.debit-l.credit) filter(where e.id is not null),0) else coalesce(sum(l.credit-l.debit) filter(where e.id is not null),0) end ending_balance
      from public.accounting_accounts a
      left join public.accounting_journal_lines l on l.account_id=a.id
      left join public.accounting_journal_entries e on e.id=l.journal_entry_id and e.status='posted' and e.entry_date<=p_ends_on
      where a.company_id=p_company_id and a.account_type in ('asset','liability','equity') and (p_account_id is null or a.id=p_account_id)
      group by a.id
    ), result_row as (
      select null::uuid account_id,'RESULTADO-EJERCICIO'::text code,'Resultado del ejercicio al corte'::text name,'equity'::text account_type,'credit'::text normal_balance,
        coalesce(sum(l.credit-l.debit),0) ending_balance
      from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id and e.status='posted' join public.accounting_accounts a on a.id=l.account_id
      where l.company_id=p_company_id and e.entry_date<=p_ends_on and a.account_type in ('revenue','expense') and p_account_id is null
    ), rows as materialized (
      select * from account_rows where ending_balance<>0 union all select * from result_row where ending_balance<>0
    ), sums as (
      select coalesce(sum(ending_balance)filter(where account_type='asset'),0) assets,
        coalesce(sum(ending_balance)filter(where account_type='liability'),0) liabilities,
        coalesce(sum(ending_balance)filter(where account_type='equity'),0) equity
      from rows
    )
    select (select count(*) from rows),coalesce((select jsonb_agg(to_jsonb(p) order by p.code) from (select * from rows order by code limit p_page_size offset v_offset)p),'[]'),
      jsonb_build_object('assets',assets,'liabilities',liabilities,'equity',equity,'liabilities_and_equity',liabilities+equity,'difference',round(assets-liabilities-equity,6)),round(assets-liabilities-equity,6)=0
    into v_total,v_rows,v_totals,v_balanced from sums;

  else
    with controls as materialized (
      select c.account_id,c.control_key,a.code,a.name,a.normal_balance
      from public.accounting_control_accounts c join public.accounting_accounts a on a.id=c.account_id
      where c.config_version_id=v_config and c.control_key in ('cash','banks')
    ), rows as materialized (
      select c.account_id,c.code,c.name,c.control_key category,e.source_type,
        case when c.normal_balance='debit' then coalesce(sum(l.debit),0) else coalesce(sum(l.credit),0) end inflows,
        case when c.normal_balance='debit' then coalesce(sum(l.credit),0) else coalesce(sum(l.debit),0) end outflows
      from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id join controls c on c.account_id=l.account_id
      where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on
      group by c.account_id,c.code,c.name,c.control_key,c.normal_balance,e.source_type
    )
    select count(*),coalesce((select jsonb_agg(to_jsonb(p) order by p.code,p.source_type) from (select * from rows order by code,source_type limit p_page_size offset v_offset)p),'[]'),
      jsonb_build_object('inflows',coalesce(sum(inflows),0),'outflows',coalesce(sum(outflows),0),'net_cash_flow',coalesce(sum(inflows-outflows),0))
    into v_total,v_rows,v_totals from rows;
  end if;

  return jsonb_build_object('report_type',p_report_type,'starts_on',p_starts_on,'ends_on',p_ends_on,'page',p_page,'page_size',p_page_size,'total',v_total,'totals',v_totals,'balanced',v_balanced,'rows',v_rows,'generated_at',clock_timestamp());
end $$;

revoke all on function public.canonical_accounting_auxiliaries(uuid,date) from public,anon,authenticated;
revoke all on function public.list_accounting_report(uuid,text,date,date,uuid,integer,integer) from public,anon;
grant execute on function public.list_accounting_report(uuid,text,date,date,uuid,integer,integer) to authenticated;
