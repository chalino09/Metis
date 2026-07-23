-- Satrapy · M4D3: dimensión canónica de ubicación y custodia de efectivo.
-- Reutiliza locations, cash_registers, cash_sessions, cash_movements y el motor
-- contable M4B/M4D2. No crea ubicaciones, cajas, cuentas ni dimensiones paralelas.

begin;

insert into public.permissions(code,description) values
  ('manage_cash_custody','Preparar traslados y concentraciones de efectivo.'),
  ('approve_cash_custody','Aprobar traslados y concentraciones de efectivo.'),
  ('confirm_cash_custody','Confirmar entregas y recepciones físicas de efectivo.'),
  ('correct_accounting_location','Corregir ubicación contable con trazabilidad.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin')
  and p.code in ('manage_cash_custody','approve_cash_custody','confirm_cash_custody','correct_accounting_location')
on conflict do nothing;

alter table public.accounting_events
  add column if not exists location_id uuid references public.locations(id) on delete restrict;
alter table public.accounting_journal_lines
  add column if not exists location_id uuid references public.locations(id) on delete restrict;
alter table public.supplier_invoice_expense_lines
  add column if not exists location_id uuid references public.locations(id) on delete restrict;

create index if not exists accounting_events_location_idx
  on public.accounting_events(company_id,location_id,accounting_date,id);
create index if not exists accounting_journal_lines_location_idx
  on public.accounting_journal_lines(company_id,location_id,journal_entry_id,id);
create index if not exists supplier_expense_lines_location_idx
  on public.supplier_invoice_expense_lines(company_id,location_id,supplier_invoice_id,id);

alter table public.accounting_events drop constraint if exists accounting_events_event_type_check;
alter table public.accounting_events add constraint accounting_events_event_type_check check(event_type in (
  'sale_confirmed','sale_cancelled','receivable_payment_confirmed','receivable_payment_reversed',
  'cash_opened','cash_movement_recorded','cash_movement_reversed','cash_closed',
  'purchase_receipt_confirmed','purchase_receipt_reversed','inventory_adjustment_posted','inventory_adjustment_reversed',
  'supplier_invoice_confirmed','supplier_invoice_reversed','supplier_credit_note_confirmed','supplier_credit_note_reversed',
  'supplier_payment_confirmed','supplier_payment_reversed',
  'cash_transfer_dispatched','cash_transfer_received','cash_transfer_confirmed','cash_transfer_reversed'
));

-- Una caja usa una cuenta afectable ya existente. La cuenta de tránsito también
-- debe existir y ser aprobada explícitamente; nunca se crea una cuenta aquí.
create table public.cash_register_accounting_accounts(
  company_id uuid not null references public.companies(id) on delete cascade,
  cash_register_id uuid primary key references public.cash_registers(id) on delete restrict,
  account_id uuid not null,
  reason text not null check(nullif(trim(reason),'') is not null),
  configured_by uuid references auth.users(id) on delete set null default auth.uid(),
  configured_at timestamptz not null default now(),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict
);

create table public.cash_custody_account_config(
  company_id uuid primary key references public.companies(id) on delete cascade,
  in_transit_account_id uuid not null,
  reason text not null check(nullif(trim(reason),'') is not null),
  configured_by uuid references auth.users(id) on delete set null default auth.uid(),
  configured_at timestamptz not null default now(),
  foreign key(company_id,in_transit_account_id) references public.accounting_accounts(company_id,id) on delete restrict
);

create table public.cash_custody_transfers(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  origin_cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  origin_location_id uuid not null references public.locations(id) on delete restrict,
  destination_cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  destination_location_id uuid not null references public.locations(id) on delete restrict,
  amount numeric(18,2) not null check(amount>0),
  effective_date date not null,
  responsible_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check(nullif(trim(reason),'') is not null),
  reference text not null check(nullif(trim(reference),'') is not null),
  evidence jsonb not null default '{}' check(jsonb_typeof(evidence)='object'),
  status text not null default 'prepared' check(status in ('prepared','approved','in_transit','confirmed','reversed')),
  prepare_request_id uuid not null,
  approval_request_id uuid,
  dispatch_request_id uuid,
  confirm_request_id uuid,
  reverse_request_id uuid,
  prepared_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  prepared_at timestamptz not null default now(),
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  dispatched_by uuid references auth.users(id) on delete restrict,
  dispatched_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete restrict,
  confirmed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete restrict,
  reversed_at timestamptz,
  reversal_reason text,
  journal_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  receipt_journal_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  reversal_journal_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,prepare_request_id),
  unique(company_id,approval_request_id),
  unique(company_id,dispatch_request_id),
  unique(company_id,confirm_request_id),
  unique(company_id,reverse_request_id),
  check(origin_cash_register_id<>destination_cash_register_id),
  check((status in ('approved','in_transit','confirmed','reversed'))=(approved_at is not null)),
  check((status in ('in_transit','confirmed','reversed'))=(dispatched_at is not null)),
  check((status in ('confirmed','reversed'))=(confirmed_at is not null)),
  check((status='reversed')=(reversed_at is not null and reversal_reason is not null))
);
create index cash_custody_transfers_origin_idx
  on public.cash_custody_transfers(company_id,origin_cash_register_id,effective_date,status,id);
create index cash_custody_transfers_destination_idx
  on public.cash_custody_transfers(company_id,destination_cash_register_id,effective_date,status,id);

create table public.cash_concentration_batches(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cutoff_date date not null,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  destination_cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  destination_location_id uuid not null references public.locations(id) on delete restrict,
  status text not null default 'prepared' check(status in ('prepared','approved','confirmed','reversed')),
  prepare_request_id uuid not null,
  approval_request_id uuid,
  confirm_request_id uuid,
  reverse_request_id uuid,
  prepared_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  prepared_at timestamptz not null default now(),
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete restrict,
  confirmed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete restrict,
  reversed_at timestamptz,
  reversal_reason text,
  created_at timestamptz not null default now(),
  unique(company_id,prepare_request_id),
  unique(company_id,approval_request_id),
  unique(company_id,confirm_request_id),
  unique(company_id,reverse_request_id),
  check((status='reversed')=(reversed_at is not null and reversal_reason is not null))
);

create table public.cash_concentration_lines(
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.cash_concentration_batches(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete cascade,
  origin_cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  origin_location_id uuid not null references public.locations(id) on delete restrict,
  previous_balance numeric(18,2) not null check(previous_balance>=0),
  proposed_amount numeric(18,2) not null check(proposed_amount>=0 and proposed_amount<=previous_balance),
  resulting_balance numeric(18,2) generated always as (previous_balance-proposed_amount) stored,
  excluded boolean not null default false,
  exception_reason text,
  exception_evidence jsonb,
  transfer_id uuid references public.cash_custody_transfers(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(batch_id,origin_cash_register_id),
  check((excluded and proposed_amount=0 and nullif(trim(exception_reason),'') is not null) or not excluded),
  check(exception_evidence is null or jsonb_typeof(exception_evidence)='object')
);
create index cash_concentration_lines_page_idx on public.cash_concentration_lines(batch_id,id);

create table public.accounting_location_corrections(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  accounting_event_id uuid not null references public.accounting_events(id) on delete restrict,
  journal_line_id uuid references public.accounting_journal_lines(id) on delete restrict,
  previous_location_id uuid references public.locations(id) on delete restrict,
  corrected_location_id uuid references public.locations(id) on delete restrict,
  reason text not null check(nullif(trim(reason),'') is not null),
  client_request_id uuid not null,
  corrected_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  corrected_at timestamptz not null default now(),
  unique(company_id,client_request_id)
);

create or replace function public.assert_m4d3_location_company()
returns trigger language plpgsql set search_path=public as $$
declare v_company uuid;
begin
  if tg_table_name='cash_register_accounting_accounts' then
    select company_id into v_company from public.cash_registers where id=new.cash_register_id;
  elsif tg_table_name='cash_custody_transfers' then
    if not exists(select 1 from public.cash_registers r join public.locations l on l.id=r.location_id
      where r.id=new.origin_cash_register_id and r.company_id=new.company_id and r.location_id=new.origin_location_id
        and r.currency_code=new.currency_code and l.company_id=new.company_id)
      or not exists(select 1 from public.cash_registers r join public.locations l on l.id=r.location_id
      where r.id=new.destination_cash_register_id and r.company_id=new.company_id and r.location_id=new.destination_location_id
        and r.currency_code=new.currency_code and l.company_id=new.company_id)
    then raise exception 'Origen y destino deben pertenecer a la empresa, ubicación y moneda indicadas.';end if;
    return new;
  elsif tg_table_name='cash_concentration_batches' then
    if not exists(select 1 from public.cash_registers r where r.id=new.destination_cash_register_id
      and r.company_id=new.company_id and r.location_id=new.destination_location_id and r.currency_code=new.currency_code)
    then raise exception 'La caja destino no pertenece a la empresa, ubicación o moneda.';end if;
    return new;
  elsif tg_table_name='cash_concentration_lines' then
    if not exists(select 1 from public.cash_registers r where r.id=new.origin_cash_register_id
      and r.company_id=new.company_id and r.location_id=new.origin_location_id)
    then raise exception 'La caja origen no pertenece a la empresa o ubicación.';end if;
    return new;
  elsif tg_table_name='supplier_invoice_expense_lines' then
    if new.location_id is null then return new;end if;
    select company_id into v_company from public.locations where id=new.location_id;
  else
    return new;
  end if;
  if v_company is distinct from new.company_id then raise exception 'La ubicación o caja no pertenece a la empresa.';end if;
  return new;
end $$;

create trigger cash_register_account_company_guard before insert or update on public.cash_register_accounting_accounts
for each row execute function public.assert_m4d3_location_company();
create trigger cash_transfer_company_guard before insert or update on public.cash_custody_transfers
for each row execute function public.assert_m4d3_location_company();
create trigger concentration_batch_company_guard before insert or update on public.cash_concentration_batches
for each row execute function public.assert_m4d3_location_company();
create trigger concentration_line_company_guard before insert or update on public.cash_concentration_lines
for each row execute function public.assert_m4d3_location_company();
create trigger supplier_expense_location_company_guard before insert or update of location_id on public.supplier_invoice_expense_lines
for each row execute function public.assert_m4d3_location_company();
create trigger cash_custody_transfers_updated_at before update on public.cash_custody_transfers
for each row execute function public.set_updated_at();

create or replace function public.guard_confirmed_cash_custody()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='DELETE' and old.status in ('in_transit','confirmed','reversed') then
    raise exception 'Un traslado con movimiento físico no puede eliminarse.';
  elsif tg_op='UPDATE' and old.status in ('confirmed','reversed') then
    if new.company_id is distinct from old.company_id or new.currency_code is distinct from old.currency_code
      or new.origin_cash_register_id is distinct from old.origin_cash_register_id
      or new.destination_cash_register_id is distinct from old.destination_cash_register_id
      or new.amount is distinct from old.amount or new.effective_date is distinct from old.effective_date
      or new.responsible_id is distinct from old.responsible_id or new.reason is distinct from old.reason
      or new.reference is distinct from old.reference or new.evidence is distinct from old.evidence
    then raise exception 'Un traslado confirmado conserva íntegra su identidad física.';end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger cash_custody_immutable_guard before update or delete on public.cash_custody_transfers
for each row execute function public.guard_confirmed_cash_custody();

-- La única excepción a la inmutabilidad es el RPC de corrección dimensional:
-- puede cambiar location_id y renovar el hash, pero no importes, cuentas ni texto.
create or replace function public.guard_accounting_immutable_mutation()
returns trigger language plpgsql set search_path=public as $$
declare v_entry public.accounting_journal_entries%rowtype;v_period_status text;v_correction boolean;
begin
  v_correction:=coalesce(current_setting('app.accounting_location_correction',true),'')<>'';
  if tg_table_name='accounting_journal_entries' then
    v_entry:=old;
    if v_correction and tg_op='UPDATE'
      and (to_jsonb(new)-'content_sha256')=(to_jsonb(old)-'content_sha256') then return new;end if;
  else
    select * into v_entry from public.accounting_journal_entries where id=coalesce(new.journal_entry_id,old.journal_entry_id);
    if v_correction and tg_op='UPDATE'
      and (to_jsonb(new)-'location_id')=(to_jsonb(old)-'location_id') then return new;end if;
  end if;
  select status into v_period_status from public.accounting_periods where id=v_entry.period_id;
  if v_entry.immutable or v_entry.status in ('posted','reversed') or v_period_status='closed'
  then raise exception 'La póliza contabilizada, de apertura o de periodo cerrado es inmutable.';end if;
  return case when tg_op='DELETE' then old else new end;
end $$;

create or replace function public.resolve_accounting_source_location(
  p_company_id uuid,p_source_entity_type text,p_source_entity_id uuid
) returns uuid language plpgsql stable security definer set search_path=public as $$
declare v_location uuid;v_count int;
begin
  case p_source_entity_type
    when 'sale' then select location_id into v_location from public.sales where id=p_source_entity_id and company_id=p_company_id;
    when 'receivable_payment' then
      select s.location_id into v_location from public.receivable_payments p
      join public.cash_sessions s on s.id=p.cash_session_id
      where p.id=p_source_entity_id and p.company_id=p_company_id and p.settlement_kind='cash_drawer';
    when 'cash_session' then select location_id into v_location from public.cash_sessions where id=p_source_entity_id and company_id=p_company_id;
    when 'cash_movement' then
      select s.location_id into v_location from public.cash_movements m join public.cash_sessions s on s.id=m.cash_session_id
      where m.id=p_source_entity_id and m.company_id=p_company_id;
    when 'purchase_receipt' then select location_id into v_location from public.purchase_receipts where id=p_source_entity_id and company_id=p_company_id;
    when 'inventory_count' then select location_id into v_location from public.inventory_counts where id=p_source_entity_id and company_id=p_company_id;
    when 'supplier_invoice' then
      if exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=p_source_entity_id) then
        select count(distinct location_id),(array_agg(distinct location_id))[1] into v_count,v_location
        from public.supplier_invoice_expense_lines where supplier_invoice_id=p_source_entity_id and company_id=p_company_id and location_id is not null;
        if v_count<>1 or exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=p_source_entity_id and location_id is null)
        then v_location:=null;end if;
      else
        select count(distinct receipt.location_id),(array_agg(distinct receipt.location_id))[1] into v_count,v_location
        from public.supplier_invoice_receipts link join public.purchase_receipts receipt on receipt.id=link.purchase_receipt_id
        where link.supplier_invoice_id=p_source_entity_id and link.company_id=p_company_id;
        if v_count<>1 then v_location:=null;end if;
      end if;
    when 'cash_transfer' then
      select case when status='in_transit' then origin_location_id else destination_location_id end into v_location
      from public.cash_custody_transfers where id=p_source_entity_id and company_id=p_company_id;
    else v_location:=null;
  end case;
  if v_location is not null and not exists(select 1 from public.locations where id=v_location and company_id=p_company_id)
  then raise exception 'La ubicación canónica no pertenece a la empresa.';end if;
  return v_location;
end $$;

-- El saldo histórico parte de la sesión más reciente de cada caja al corte.
-- Antes del cierre usa movimientos; después del cierre usa el conteo físico.
-- Luego aplica exclusivamente traslados físicos fechados, nunca saldos actuales.
create or replace function public.cash_register_custody_balance_as_of(
  p_company_id uuid,p_cash_register_id uuid,p_cutoff timestamptz
) returns numeric language sql stable security definer set search_path=public as $$
  with last_session as (
    select s.* from public.cash_sessions s
    where s.company_id=p_company_id and s.cash_register_id=p_cash_register_id and s.opened_at<=p_cutoff
    order by s.opened_at desc,s.id desc limit 1
  ), session_balance as (
    select coalesce(case when s.closed_at is not null and s.closed_at<=p_cutoff
      then s.counted_closing_amount
      else (select sum(m.amount) from public.cash_movements m where m.cash_session_id=s.id and m.occurred_at<=p_cutoff)
    end,0)::numeric amount,coalesce(s.opened_at,'-infinity'::timestamptz) starts_at from last_session s
  ), transfer_delta as (
    select coalesce(sum(case
      when t.origin_cash_register_id=p_cash_register_id and t.dispatched_at<=p_cutoff then -t.amount
      when t.destination_cash_register_id=p_cash_register_id and t.confirmed_at<=p_cutoff then t.amount
      else 0 end),0) amount
    from public.cash_custody_transfers t,(select coalesce(min(starts_at),'-infinity'::timestamptz) starts_at from session_balance)s
    where t.company_id=p_company_id and t.status in ('in_transit','confirmed')
      and t.reversed_at is null and t.effective_date<=p_cutoff::date
      and (t.dispatched_at>=s.starts_at or t.confirmed_at>=s.starts_at)
  )
  select round(coalesce((select amount from session_balance),0)+coalesce((select amount from transfer_delta),0),2)
$$;

create or replace function public.configure_cash_custody_accounts(
  p_company_id uuid,p_cash_register_id uuid,p_account_id uuid,p_in_transit_account_id uuid,
  p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_replay jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting_events')
    or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select metadata into v_replay from public.audit_log where company_id=p_company_id
    and action='cash_custody.accounts_configured' and metadata->>'request_id'=p_client_request_id::text;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  if not exists(select 1 from public.cash_registers where id=p_cash_register_id and company_id=p_company_id)
    or not exists(select 1 from public.accounting_accounts where id=p_account_id and company_id=p_company_id and is_active and accepts_posting)
    or not exists(select 1 from public.accounting_accounts where id=p_in_transit_account_id and company_id=p_company_id and is_active and accepts_posting)
  then raise exception 'La caja o alguna cuenta afectable aprobada no está disponible.';end if;
  insert into public.cash_register_accounting_accounts(company_id,cash_register_id,account_id,reason)
  values(p_company_id,p_cash_register_id,p_account_id,trim(p_reason))
  on conflict(cash_register_id) do update set account_id=excluded.account_id,reason=excluded.reason,configured_by=auth.uid(),configured_at=now();
  insert into public.cash_custody_account_config(company_id,in_transit_account_id,reason)
  values(p_company_id,p_in_transit_account_id,trim(p_reason))
  on conflict(company_id) do update set in_transit_account_id=excluded.in_transit_account_id,reason=excluded.reason,configured_by=auth.uid(),configured_at=now();
  v_replay:=jsonb_build_object('request_id',p_client_request_id,'cash_register_id',p_cash_register_id,
    'account_id',p_account_id,'in_transit_account_id',p_in_transit_account_id,'reason',trim(p_reason));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.accounts_configured','cash_register',p_cash_register_id,v_replay);
  return v_replay||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.assign_expense_line_location(
  p_company_id uuid,p_line_id uuid,p_location_id uuid,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_line public.supplier_invoice_expense_lines%rowtype;v_previous uuid;v_replay jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_expense_invoices')
    or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select metadata into v_replay from public.audit_log where company_id=p_company_id
    and action='accounting.expense_location_assigned' and metadata->>'request_id'=p_client_request_id::text;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  select line.* into v_line from public.supplier_invoice_expense_lines line
    join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
    where line.id=p_line_id and line.company_id=p_company_id and invoice.status='draft' for update;
  if not found then raise exception 'El concepto no es un borrador editable.';end if;
  if p_location_id is not null and not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id)
  then raise exception 'La ubicación no pertenece a la empresa.';end if;
  v_previous:=v_line.location_id;
  update public.supplier_invoice_expense_lines set location_id=p_location_id where id=p_line_id;
  v_replay:=jsonb_build_object('request_id',p_client_request_id,'line_id',p_line_id,
    'previous_location_id',v_previous,'location_id',p_location_id,'reason',trim(p_reason));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'accounting.expense_location_assigned','supplier_invoice_expense_line',p_line_id,v_replay);
  return v_replay||jsonb_build_object('idempotent',false);
end $$;

-- M4D2 ahora agrupa gasto por cuenta, categoría y ubicación explícita. No reparte
-- una línea ni usa centro de costo/proyecto como sustitutos.
create or replace function public.build_expense_accounting_lines(p_invoice_id uuid,p_target_amount numeric,p_side text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_lines jsonb;
begin
  with weights as (
    select line.resolved_account_id account_id,line.expense_category_version_id,line.location_id,
      category.code,category.display_name,sum(line.subtotal-line.discount_amount) weight
    from public.supplier_invoice_expense_lines line
    join public.accounting_expense_category_versions category on category.id=line.expense_category_version_id
    where line.supplier_invoice_id=p_invoice_id and line.resolved_account_id is not null and line.expense_category_version_id is not null
    group by line.resolved_account_id,line.expense_category_version_id,line.location_id,category.code,category.display_name
  ), shares as (
    select *,row_number() over(order by code,expense_category_version_id,location_id nulls last) rn,count(*) over() n,
      round(p_target_amount*weight/nullif(sum(weight) over(),0),6) rounded
    from weights where weight>0
  ), adjusted as (
    select *,case when rn=n then round(p_target_amount-coalesce(sum(rounded) over(order by rn rows between unbounded preceding and 1 preceding),0),6) else rounded end amount
    from shares
  )
  select jsonb_agg(jsonb_build_object('account_id',account_id,'expense_category_version_id',expense_category_version_id,
    'location_id',location_id,'role',null,'debit',case when p_side='debit' then amount else 0 end,
    'credit',case when p_side='credit' then amount else 0 end,'description',code||' · '||display_name) order by rn)
  into v_lines from adjusted where amount>0;
  if coalesce(jsonb_array_length(v_lines),0)=0 then raise exception 'La factura no conserva clasificación contable resoluble.';end if;
  return v_lines;
end $$;

-- Captura siempre resuelve ubicación desde el documento. Sólo acepta una
-- ubicación de línea explícita cuando fue construida server-side por el origen.
create or replace function public.capture_accounting_event(
  p_company_id uuid,p_event_type text,p_source_entity_type text,p_source_entity_id uuid,p_source_version int,
  p_accounting_date date,p_occurred_at timestamptz,p_lines jsonb,p_payload jsonb default '{}'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_event public.accounting_events%rowtype;v_location uuid;v_lines jsonb;v_line jsonb;
  v_distinct_locations int;v_has_null boolean;v_only_location uuid;
begin
  v_location:=public.resolve_accounting_source_location(p_company_id,p_source_entity_type,p_source_entity_id);
  v_lines:='[]'::jsonb;
  for v_line in select value from jsonb_array_elements(coalesce(p_lines,'[]')) loop
    if v_line?'location_id' and nullif(v_line->>'location_id','') is not null then
      if not exists(select 1 from public.locations where id=(v_line->>'location_id')::uuid and company_id=p_company_id)
      then raise exception 'La ubicación de partida no pertenece a la empresa.';end if;
      v_lines:=v_lines||jsonb_build_array(v_line);
    else
      v_lines:=v_lines||jsonb_build_array(v_line||jsonb_build_object('location_id',v_location));
    end if;
  end loop;
  select count(distinct nullif(line->>'location_id','')),
    coalesce(bool_or(nullif(line->>'location_id','') is null),true),
    (array_agg(distinct (nullif(line->>'location_id',''))::uuid)
      filter(where nullif(line->>'location_id','') is not null))[1]
  into v_distinct_locations,v_has_null,v_only_location
  from jsonb_array_elements(v_lines) line;
  -- Un evento homogéneo y sus partidas comparten location_id. Un documento
  -- multilocal conserva cada partida y deja el encabezado nulo antes que mentir.
  v_location:=case when v_distinct_locations=1 and not v_has_null then v_only_location else null end;
  insert into public.accounting_events(company_id,event_type,source_entity_type,source_entity_id,source_version,
    accounting_date,occurred_at,requested_lines,payload,location_id)
  values(p_company_id,p_event_type,p_source_entity_type,p_source_entity_id,coalesce(p_source_version,1),
    p_accounting_date,p_occurred_at,v_lines,coalesce(p_payload,'{}'),v_location)
  on conflict(company_id,event_type,source_entity_type,source_entity_id,source_version) do nothing returning * into v_event;
  if not found then
    select * into v_event from public.accounting_events where company_id=p_company_id and event_type=p_event_type
      and source_entity_type=p_source_entity_type and source_entity_id=p_source_entity_id and source_version=coalesce(p_source_version,1);
    return to_jsonb(v_event)||jsonb_build_object('idempotent',true);
  end if;
  return public.post_pending_accounting_event(v_event.id);
end $$;

create or replace function public.post_pending_accounting_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_event public.accounting_events%rowtype;v_set public.accounting_event_rule_sets%rowtype;
  v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;
  v_line record;v_account uuid;v_debit numeric:=0;v_credit numeric:=0;v_number int:=0;
begin
  select * into v_event from public.accounting_events where id=p_event_id for update;
  if not found then raise exception 'Evento contable no disponible.';end if;
  if v_event.status='posted' then return to_jsonb(v_event)||jsonb_build_object('idempotent',true);end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=v_event.company_id and status='approved';
  if not found then return to_jsonb(v_event)||jsonb_build_object('waiting_for_matrix',true);end if;
  select * into v_period from public.accounting_periods where company_id=v_event.company_id
    and v_event.accounting_date between starts_on and ends_on for update;
  if not found or v_period.status<>'open' then raise exception 'El evento pertenece a un periodo inexistente o cerrado.';end if;
  if jsonb_array_length(v_event.requested_lines)<2 or jsonb_array_length(v_event.requested_lines)>1000
  then raise exception 'El evento no contiene partidas válidas.';end if;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)
    x(role text,account_id uuid,expense_category_version_id uuid,location_id uuid,debit numeric,credit numeric,description text)
  loop
    if coalesce(v_line.debit,0)<0 or coalesce(v_line.credit,0)<0
      or (coalesce(v_line.debit,0)>0)=(coalesce(v_line.credit,0)>0) then raise exception 'Partida operativa inválida.';end if;
    if v_line.location_id is not null and not exists(select 1 from public.locations where id=v_line.location_id and company_id=v_event.company_id)
    then raise exception 'La ubicación de partida no pertenece a la empresa.';end if;
    if v_event.location_id is not null and v_line.location_id is distinct from v_event.location_id
    then raise exception 'Evento y partida no conservan la misma ubicación canónica.';end if;
    if v_line.account_id is not null then
      select id into v_account from public.accounting_accounts where id=v_line.account_id and company_id=v_event.company_id and accepts_posting and is_active;
      if v_account is null then raise exception 'La cuenta directa no es una cuenta afectable activa aprobada.';end if;
      if v_line.expense_category_version_id is not null and not exists(select 1 from public.accounting_expense_category_versions
        where id=v_line.expense_category_version_id and company_id=v_event.company_id and account_id=v_account)
      then raise exception 'La categoría no respalda la cuenta solicitada.';end if;
    else
      v_account:=public.resolve_accounting_event_role(v_set.id,v_line.role);
      if v_account is null then raise exception 'La matriz no resuelve el rol %.',v_line.role;end if;
    end if;
    v_debit:=v_debit+coalesce(v_line.debit,0);v_credit:=v_credit+coalesce(v_line.credit,0);
  end loop;
  if round(v_debit-v_credit,6)<>0 then raise exception 'El evento no cumple doble entrada.';end if;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,
    immutable,client_request_id,accounting_event_id)
  values(v_event.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),v_event.accounting_date,
    coalesce(nullif(v_event.payload->>'description',''),v_event.event_type),'operational_event','draft',false,v_event.id,v_event.id)
  returning * into v_entry;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)
    x(role text,account_id uuid,expense_category_version_id uuid,location_id uuid,debit numeric,credit numeric,description text)
  loop
    v_number:=v_number+1;v_account:=coalesce(v_line.account_id,public.resolve_accounting_event_role(v_set.id,v_line.role));
    insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,
      expense_category_version_id,location_id,description,debit,credit)
    values(v_event.company_id,v_entry.id,v_number,v_account,v_line.expense_category_version_id,
      v_line.location_id,v_line.description,coalesce(v_line.debit,0),coalesce(v_line.credit,0));
  end loop;
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),
    content_sha256=encode(digest((select jsonb_agg(to_jsonb(line) order by line_number)::text
      from public.accounting_journal_lines line where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id;
  update public.accounting_events set status='posted',rule_set_id=v_set.id,journal_entry_id=v_entry.id,posted_at=now()
    where id=v_event.id returning * into v_event;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_event.company_id,auth.uid(),'accounting.operational_event_posted','accounting_event',v_event.id,
    jsonb_build_object('event_type',v_event.event_type,'source_type',v_event.source_entity_type,
      'source_id',v_event.source_entity_id,'journal_entry_id',v_entry.id,'location_id',v_event.location_id));
  return to_jsonb(v_event)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.capture_exact_accounting_reversal(
  p_company_id uuid,p_original_event_type text,p_reversal_event_type text,p_source_entity_type text,
  p_source_entity_id uuid,p_accounting_date date,p_occurred_at timestamptz,p_description text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_original public.accounting_events%rowtype;v_lines jsonb;v_result jsonb;
begin
  select * into v_original from public.accounting_events where company_id=p_company_id
    and event_type=p_original_event_type and source_entity_type=p_source_entity_type
    and source_entity_id=p_source_entity_id and status='posted' order by source_version desc limit 1;
  if not found then raise exception 'No existe contabilización original para revertir.';end if;
  select jsonb_agg(jsonb_build_object('role',line->>'role','account_id',line->>'account_id',
    'expense_category_version_id',line->>'expense_category_version_id','location_id',line->>'location_id',
    'debit',coalesce((line->>'credit')::numeric,0),'credit',coalesce((line->>'debit')::numeric,0),
    'description',coalesce(nullif(line->>'description',''),p_description)) order by ordinal)
  into v_lines from jsonb_array_elements(v_original.requested_lines) with ordinality as x(line,ordinal);
  v_result:=public.capture_accounting_event(p_company_id,p_reversal_event_type,p_source_entity_type,p_source_entity_id,1,
    p_accounting_date,p_occurred_at,v_lines,jsonb_build_object('description',p_description,'reverses_event_id',v_original.id));
  update public.accounting_events set original_event_id=v_original.id,location_id=v_original.location_id
    where id=(v_result->>'id')::uuid and original_event_id is null;
  return v_result;
end $$;

-- Cerrar sólo registra arqueo y diferencia. Se elimina el retiro ficticio de M4B.
create or replace function public.capture_cash_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_lines jsonb;v_variance numeric;
begin
  if not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if tg_op='INSERT' then
    if new.opening_amount>0 then
      v_lines:=jsonb_build_array(
        jsonb_build_object('role','cash','debit',new.opening_amount,'credit',0,'description','Fondo de apertura'),
        jsonb_build_object('role','cash_opening_offset','debit',0,'credit',new.opening_amount,'description','Contrapartida de apertura'));
      perform public.capture_accounting_event(new.company_id,'cash_opened','cash_session',new.id,1,new.opened_at::date,new.opened_at,
        v_lines,jsonb_build_object('description','Apertura de caja'));
    end if;return new;
  end if;
  if old.status=new.status or new.status<>'closed' then return new;end if;
  v_variance:=coalesce(new.variance_amount,0);
  if v_variance=0 then return new;end if;
  if v_variance>0 then
    v_lines:=jsonb_build_array(
      jsonb_build_object('role','cash','debit',v_variance,'credit',0,'description','Sobrante de caja'),
      jsonb_build_object('role','cash_over_short','debit',0,'credit',v_variance,'description','Sobrante de caja'));
  else
    v_lines:=jsonb_build_array(
      jsonb_build_object('role','cash_over_short','debit',abs(v_variance),'credit',0,'description','Faltante de caja'),
      jsonb_build_object('role','cash','debit',0,'credit',abs(v_variance),'description','Faltante de caja'));
  end if;
  perform public.capture_accounting_event(new.company_id,'cash_closed','cash_session',new.id,1,new.closed_at::date,new.closed_at,
    v_lines,jsonb_build_object('description','Diferencia de arqueo','expected',new.expected_closing_amount,
      'counted',new.counted_closing_amount,'variance',v_variance));
  return new;
end $$;

create or replace function public.prepare_cash_transfer(
  p_company_id uuid,p_currency_code text,p_origin_cash_register_id uuid,p_destination_cash_register_id uuid,
  p_amount numeric,p_effective_date date,p_responsible_id uuid,p_reason text,p_reference text,p_evidence jsonb,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_origin public.cash_registers%rowtype;v_destination public.cash_registers%rowtype;v_transfer public.cash_custody_transfers%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_cash_custody')
    or p_client_request_id is null then raise exception 'No autorizado o falta idempotencia.';end if;
  select * into v_transfer from public.cash_custody_transfers where company_id=p_company_id and prepare_request_id=p_client_request_id;
  if found then return to_jsonb(v_transfer)||jsonb_build_object('idempotent',true);end if;
  if coalesce(p_amount,0)<=0 or p_origin_cash_register_id=p_destination_cash_register_id
    or p_effective_date is null or p_responsible_id is null
    or nullif(trim(coalesce(p_reason,'')),'') is null or nullif(trim(coalesce(p_reference,'')),'') is null
    or jsonb_typeof(coalesce(p_evidence,'{}'))<>'object'
  then raise exception 'Importe, fecha, responsable, motivo, referencia y evidencia son obligatorios.';end if;
  select * into v_origin from public.cash_registers where id=p_origin_cash_register_id and company_id=p_company_id for share;
  select * into v_destination from public.cash_registers where id=p_destination_cash_register_id and company_id=p_company_id for share;
  if v_origin.id is null or v_destination.id is null or v_origin.currency_code<>upper(trim(p_currency_code))
    or v_destination.currency_code<>upper(trim(p_currency_code)) then raise exception 'Cajas o moneda no disponibles.';end if;
  if not public.can_access_location(v_origin.location_id) or not public.can_access_location(v_destination.location_id)
  then raise exception 'Sin acceso a la ubicación origen o destino.';end if;
  insert into public.cash_custody_transfers(company_id,currency_code,origin_cash_register_id,origin_location_id,
    destination_cash_register_id,destination_location_id,amount,effective_date,responsible_id,reason,reference,evidence,prepare_request_id)
  values(p_company_id,upper(trim(p_currency_code)),v_origin.id,v_origin.location_id,v_destination.id,v_destination.location_id,
    round(p_amount,2),p_effective_date,p_responsible_id,trim(p_reason),trim(p_reference),coalesce(p_evidence,'{}'),p_client_request_id)
  returning * into v_transfer;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.transfer_prepared','cash_custody_transfer',v_transfer.id,
    jsonb_build_object('request_id',p_client_request_id,'amount',v_transfer.amount,'origin',v_origin.id,'destination',v_destination.id));
  return to_jsonb(v_transfer)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.approve_cash_transfer(
  p_company_id uuid,p_transfer_id uuid,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_transfer public.cash_custody_transfers%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'approve_cash_custody')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select * into v_transfer from public.cash_custody_transfers where company_id=p_company_id and approval_request_id=p_client_request_id;
  if found then return to_jsonb(v_transfer)||jsonb_build_object('idempotent',true);end if;
  select * into v_transfer from public.cash_custody_transfers where id=p_transfer_id and company_id=p_company_id for update;
  if not found or v_transfer.status<>'prepared' then raise exception 'El traslado no está preparado.';end if;
  if v_transfer.prepared_by=auth.uid() then raise exception 'La aprobación requiere una persona distinta de quien preparó.';end if;
  update public.cash_custody_transfers set status='approved',approval_request_id=p_client_request_id,
    approved_by=auth.uid(),approved_at=now() where id=v_transfer.id returning * into v_transfer;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.transfer_approved','cash_custody_transfer',v_transfer.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason)));
  return to_jsonb(v_transfer)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.confirm_cash_transfer_dispatch(
  p_company_id uuid,p_transfer_id uuid,p_evidence jsonb,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_transfer public.cash_custody_transfers%rowtype;v_origin_account uuid;v_transit_account uuid;v_balance numeric;v_event jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_cash_custody')
    or p_client_request_id is null or jsonb_typeof(coalesce(p_evidence,'{}'))<>'object'
  then raise exception 'No autorizado o faltan idempotencia/evidencia.';end if;
  select * into v_transfer from public.cash_custody_transfers where company_id=p_company_id and dispatch_request_id=p_client_request_id;
  if found then return to_jsonb(v_transfer)||jsonb_build_object('idempotent',true);end if;
  select * into v_transfer from public.cash_custody_transfers where id=p_transfer_id and company_id=p_company_id for update;
  if not found or v_transfer.status<>'approved' then raise exception 'El traslado no está aprobado para retiro.';end if;
  perform pg_advisory_xact_lock(hashtextextended(v_transfer.origin_cash_register_id::text,403));
  select account_id into v_origin_account from public.cash_register_accounting_accounts
    where cash_register_id=v_transfer.origin_cash_register_id and company_id=p_company_id;
  select in_transit_account_id into v_transit_account from public.cash_custody_account_config where company_id=p_company_id;
  if v_origin_account is null or v_transit_account is null then raise exception 'Falta una cuenta de custodia aprobada para origen o tránsito.';end if;
  v_balance:=public.cash_register_custody_balance_as_of(p_company_id,v_transfer.origin_cash_register_id,
    (v_transfer.effective_date+1)::timestamptz-interval '1 microsecond');
  if v_transfer.amount>v_balance then raise exception 'El traslado excede el efectivo elegible bajo custodia.';end if;
  update public.cash_custody_transfers set status='in_transit',dispatch_request_id=p_client_request_id,
    dispatched_by=auth.uid(),dispatched_at=now(),evidence=evidence||coalesce(p_evidence,'{}')
    where id=v_transfer.id returning * into v_transfer;
  v_event:=public.capture_accounting_event(p_company_id,'cash_transfer_dispatched','cash_transfer',v_transfer.id,1,
    v_transfer.effective_date,v_transfer.dispatched_at,jsonb_build_array(
      jsonb_build_object('account_id',v_transit_account,'location_id',v_transfer.origin_location_id,'debit',v_transfer.amount,'credit',0,'description','Efectivo retirado pendiente de entrega'),
      jsonb_build_object('account_id',v_origin_account,'location_id',v_transfer.origin_location_id,'debit',0,'credit',v_transfer.amount,'description','Salida de custodia operativa')),
    jsonb_build_object('description','Retiro de efectivo confirmado','reference',v_transfer.reference));
  update public.cash_custody_transfers set journal_entry_id=(v_event->>'journal_entry_id')::uuid where id=v_transfer.id returning * into v_transfer;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.transfer_dispatched','cash_custody_transfer',v_transfer.id,
    jsonb_build_object('request_id',p_client_request_id,'journal_entry_id',v_transfer.journal_entry_id));
  return to_jsonb(v_transfer)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.confirm_cash_transfer(
  p_company_id uuid,p_transfer_id uuid,p_evidence jsonb,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_transfer public.cash_custody_transfers%rowtype;v_destination_account uuid;v_transit_account uuid;v_event jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_cash_custody')
    or p_client_request_id is null or jsonb_typeof(coalesce(p_evidence,'{}'))<>'object'
  then raise exception 'No autorizado o faltan idempotencia/evidencia.';end if;
  select * into v_transfer from public.cash_custody_transfers where company_id=p_company_id and confirm_request_id=p_client_request_id;
  if found then return to_jsonb(v_transfer)||jsonb_build_object('idempotent',true);end if;
  select * into v_transfer from public.cash_custody_transfers where id=p_transfer_id and company_id=p_company_id for update;
  if not found or v_transfer.status<>'in_transit' then raise exception 'El efectivo no está retirado y pendiente de entrega.';end if;
  select account_id into v_destination_account from public.cash_register_accounting_accounts
    where cash_register_id=v_transfer.destination_cash_register_id and company_id=p_company_id;
  select in_transit_account_id into v_transit_account from public.cash_custody_account_config where company_id=p_company_id;
  if v_destination_account is null or v_transit_account is null then raise exception 'Falta una cuenta de custodia aprobada para destino o tránsito.';end if;
  update public.cash_custody_transfers set status='confirmed',confirm_request_id=p_client_request_id,
    confirmed_by=auth.uid(),confirmed_at=now(),evidence=evidence||coalesce(p_evidence,'{}')
    where id=v_transfer.id returning * into v_transfer;
  v_event:=public.capture_accounting_event(p_company_id,'cash_transfer_received','cash_transfer',v_transfer.id,2,
    v_transfer.effective_date,v_transfer.confirmed_at,jsonb_build_array(
      jsonb_build_object('account_id',v_destination_account,'location_id',v_transfer.destination_location_id,'debit',v_transfer.amount,'credit',0,'description','Efectivo recibido en caja destino'),
      jsonb_build_object('account_id',v_transit_account,'location_id',v_transfer.destination_location_id,'debit',0,'credit',v_transfer.amount,'description','Entrega de efectivo en tránsito')),
    jsonb_build_object('description','Entrega de efectivo confirmada','reference',v_transfer.reference));
  update public.cash_custody_transfers set receipt_journal_entry_id=(v_event->>'journal_entry_id')::uuid where id=v_transfer.id returning * into v_transfer;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.transfer_confirmed','cash_custody_transfer',v_transfer.id,
    jsonb_build_object('request_id',p_client_request_id,'journal_entry_id',v_transfer.receipt_journal_entry_id));
  return to_jsonb(v_transfer)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.reverse_cash_transfer(
  p_company_id uuid,p_transfer_id uuid,p_effective_date date,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_transfer public.cash_custody_transfers%rowtype;v_event jsonb;v_lines jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_cash_custody')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select * into v_transfer from public.cash_custody_transfers where company_id=p_company_id and reverse_request_id=p_client_request_id;
  if found then return to_jsonb(v_transfer)||jsonb_build_object('idempotent',true);end if;
  select * into v_transfer from public.cash_custody_transfers where id=p_transfer_id and company_id=p_company_id for update;
  if not found or v_transfer.status<>'confirmed' then raise exception 'Sólo un traslado confirmado puede revertirse.';end if;
  -- Una sola póliza invierte exactamente las cuatro partidas de recepción y
  -- retiro; conserva cuenta, importe, ubicación y orden de los originales.
  select jsonb_agg(jsonb_build_object('account_id',line.account_id,'location_id',line.location_id,
    'expense_category_version_id',line.expense_category_version_id,'role',null,
    'debit',line.credit,'credit',line.debit,'description',coalesce(line.description,trim(p_reason)))
    order by event.source_version desc,line.line_number)
  into v_lines
  from public.accounting_events event
  join public.accounting_journal_lines line on line.journal_entry_id=event.journal_entry_id
  where event.company_id=p_company_id and event.source_entity_type='cash_transfer'
    and event.source_entity_id=v_transfer.id and event.event_type in ('cash_transfer_dispatched','cash_transfer_received')
    and event.status='posted';
  if coalesce(jsonb_array_length(v_lines),0)<>4 then raise exception 'La cadena contable original del traslado está incompleta.';end if;
  v_event:=public.capture_accounting_event(p_company_id,'cash_transfer_reversed','cash_transfer',v_transfer.id,1,
    p_effective_date,now(),v_lines,jsonb_build_object('description',trim(p_reason),'reverses_transfer_id',v_transfer.id));
  update public.cash_custody_transfers set status='reversed',reverse_request_id=p_client_request_id,
    reversed_by=auth.uid(),reversed_at=now(),reversal_reason=trim(p_reason),
    reversal_journal_entry_id=(v_event->>'journal_entry_id')::uuid where id=v_transfer.id returning * into v_transfer;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.transfer_reversed','cash_custody_transfer',v_transfer.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason)));
  return to_jsonb(v_transfer)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.prepare_cash_concentration(
  p_company_id uuid,p_cutoff_date date,p_currency_code text,p_destination_cash_register_id uuid,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.cash_concentration_batches%rowtype;v_destination public.cash_registers%rowtype;v_count int;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_cash_custody') or p_client_request_id is null
  then raise exception 'No autorizado o falta idempotencia.';end if;
  select * into v_batch from public.cash_concentration_batches where company_id=p_company_id and prepare_request_id=p_client_request_id;
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true,'line_count',(select count(*) from public.cash_concentration_lines where batch_id=v_batch.id));end if;
  select * into v_destination from public.cash_registers where id=p_destination_cash_register_id
    and company_id=p_company_id and currency_code=upper(trim(p_currency_code)) and is_active for share;
  if not found or not public.can_access_location(v_destination.location_id) then raise exception 'Caja destino existente no disponible.';end if;
  insert into public.cash_concentration_batches(company_id,cutoff_date,currency_code,destination_cash_register_id,
    destination_location_id,prepare_request_id)
  values(p_company_id,p_cutoff_date,upper(trim(p_currency_code)),v_destination.id,v_destination.location_id,p_client_request_id)
  returning * into v_batch;
  insert into public.cash_concentration_lines(batch_id,company_id,origin_cash_register_id,origin_location_id,previous_balance,proposed_amount)
  select v_batch.id,p_company_id,r.id,r.location_id,b.balance,b.balance
  from public.cash_registers r
  cross join lateral(select greatest(0,public.cash_register_custody_balance_as_of(
    p_company_id,r.id,(p_cutoff_date+1)::timestamptz-interval '1 microsecond')) balance)b
  where r.company_id=p_company_id and r.currency_code=v_batch.currency_code and r.is_active
    and r.id<>v_destination.id and b.balance>0 and public.can_access_location(r.location_id)
  order by r.id;
  get diagnostics v_count=row_count;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.concentration_prepared','cash_concentration_batch',v_batch.id,
    jsonb_build_object('request_id',p_client_request_id,'cutoff_date',p_cutoff_date,'currency',v_batch.currency_code,
      'destination_cash_register_id',v_destination.id,'line_count',v_count));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false,'line_count',v_count);
end $$;

create or replace function public.set_cash_concentration_exception(
  p_company_id uuid,p_line_id uuid,p_exclude boolean,p_reduced_amount numeric,p_reason text,p_evidence jsonb,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_line public.cash_concentration_lines%rowtype;v_batch public.cash_concentration_batches%rowtype;v_replay jsonb;v_amount numeric;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_cash_custody')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
    or jsonb_typeof(coalesce(p_evidence,'{}'))<>'object'
  then raise exception 'No autorizado o faltan motivo, evidencia e idempotencia.';end if;
  select metadata into v_replay from public.audit_log where company_id=p_company_id
    and action='cash_custody.concentration_exception' and metadata->>'request_id'=p_client_request_id::text;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  select line.* into v_line from public.cash_concentration_lines line where line.id=p_line_id and line.company_id=p_company_id for update;
  select * into v_batch from public.cash_concentration_batches where id=v_line.batch_id for update;
  if v_line.id is null or v_batch.status<>'prepared' then raise exception 'La concentración ya no es editable.';end if;
  v_amount:=case when coalesce(p_exclude,false) then 0 else round(coalesce(p_reduced_amount,v_line.proposed_amount),2) end;
  if v_amount<0 or v_amount>v_line.previous_balance or (not p_exclude and v_amount>=v_line.proposed_amount)
  then raise exception 'Sólo se permite excluir o reducir sin exceder el saldo elegible.';end if;
  update public.cash_concentration_lines set proposed_amount=v_amount,excluded=coalesce(p_exclude,false),
    exception_reason=trim(p_reason),exception_evidence=coalesce(p_evidence,'{}') where id=v_line.id returning * into v_line;
  v_replay:=jsonb_build_object('request_id',p_client_request_id,'line_id',v_line.id,'excluded',v_line.excluded,
    'previous_balance',v_line.previous_balance,'proposed_amount',v_line.proposed_amount,'reason',trim(p_reason),'evidence',p_evidence);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.concentration_exception','cash_concentration_line',v_line.id,v_replay);
  return v_replay||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.approve_cash_concentration(
  p_company_id uuid,p_batch_id uuid,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.cash_concentration_batches%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'approve_cash_custody')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select * into v_batch from public.cash_concentration_batches where company_id=p_company_id and approval_request_id=p_client_request_id;
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true);end if;
  select * into v_batch from public.cash_concentration_batches where id=p_batch_id and company_id=p_company_id for update;
  if not found or v_batch.status<>'prepared' then raise exception 'La concentración no está preparada.';end if;
  if v_batch.prepared_by=auth.uid() then raise exception 'La aprobación requiere una persona distinta de quien preparó.';end if;
  update public.cash_concentration_batches set status='approved',approval_request_id=p_client_request_id,
    approved_by=auth.uid(),approved_at=now() where id=v_batch.id returning * into v_batch;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.concentration_approved','cash_concentration_batch',v_batch.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason)));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.confirm_cash_concentration(
  p_company_id uuid,p_batch_id uuid,p_responsible_id uuid,p_reason text,p_reference text,p_evidence jsonb,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.cash_concentration_batches%rowtype;v_line public.cash_concentration_lines%rowtype;
  v_current numeric;v_transfer jsonb;v_count int:=0;v_prepare uuid;v_approve uuid;v_dispatch uuid;v_confirm uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_cash_custody')
    or p_client_request_id is null or p_responsible_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
    or nullif(trim(coalesce(p_reference,'')),'') is null or jsonb_typeof(coalesce(p_evidence,'{}'))<>'object'
  then raise exception 'No autorizado o faltan datos de confirmación.';end if;
  select * into v_batch from public.cash_concentration_batches where company_id=p_company_id and confirm_request_id=p_client_request_id;
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true,'confirmed_lines',
    (select count(*) from public.cash_concentration_lines where batch_id=v_batch.id and transfer_id is not null));end if;
  select * into v_batch from public.cash_concentration_batches where id=p_batch_id and company_id=p_company_id for update;
  if not found or v_batch.status<>'approved' then raise exception 'La concentración no está aprobada.';end if;
  -- Primero valida todas las cajas bajo locks deterministas; ningún parcial sobrevive.
  for v_line in select * from public.cash_concentration_lines where batch_id=v_batch.id and not excluded and proposed_amount>0 order by origin_cash_register_id for update loop
    perform pg_advisory_xact_lock(hashtextextended(v_line.origin_cash_register_id::text,403));
    v_current:=greatest(0,public.cash_register_custody_balance_as_of(p_company_id,v_line.origin_cash_register_id,
      (v_batch.cutoff_date+1)::timestamptz-interval '1 microsecond'));
    if v_current<>v_line.previous_balance then raise exception 'El saldo elegible cambió; recalcula y vuelve a aprobar.';end if;
  end loop;
  for v_line in select * from public.cash_concentration_lines where batch_id=v_batch.id and not excluded and proposed_amount>0 order by origin_cash_register_id loop
    v_prepare:=extensions.uuid_generate_v5(p_client_request_id,'prepare:'||v_line.id::text);
    v_approve:=extensions.uuid_generate_v5(p_client_request_id,'approve:'||v_line.id::text);
    v_dispatch:=extensions.uuid_generate_v5(p_client_request_id,'dispatch:'||v_line.id::text);
    v_confirm:=extensions.uuid_generate_v5(p_client_request_id,'confirm:'||v_line.id::text);
    v_transfer:=public.prepare_cash_transfer(p_company_id,v_batch.currency_code,v_line.origin_cash_register_id,
      v_batch.destination_cash_register_id,v_line.proposed_amount,v_batch.cutoff_date,p_responsible_id,
      p_reason,p_reference||' · '||v_line.id,coalesce(p_evidence,'{}'),v_prepare);
    -- La concentración ya fue aprobada por separado; se conserva esa identidad.
    update public.cash_custody_transfers set status='approved',approval_request_id=v_approve,
      approved_by=v_batch.approved_by,approved_at=v_batch.approved_at where id=(v_transfer->>'id')::uuid;
    perform public.confirm_cash_transfer_dispatch(p_company_id,(v_transfer->>'id')::uuid,p_evidence,v_dispatch);
    perform public.confirm_cash_transfer(p_company_id,(v_transfer->>'id')::uuid,p_evidence,v_confirm);
    update public.cash_concentration_lines set transfer_id=(v_transfer->>'id')::uuid where id=v_line.id;
    v_count:=v_count+1;
  end loop;
  update public.cash_concentration_batches set status='confirmed',confirm_request_id=p_client_request_id,
    confirmed_by=auth.uid(),confirmed_at=now() where id=v_batch.id returning * into v_batch;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.concentration_confirmed','cash_concentration_batch',v_batch.id,
    jsonb_build_object('request_id',p_client_request_id,'confirmed_lines',v_count));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false,'confirmed_lines',v_count);
end $$;

create or replace function public.reverse_cash_concentration(
  p_company_id uuid,p_batch_id uuid,p_effective_date date,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_batch public.cash_concentration_batches%rowtype;v_line record;v_count int:=0;v_request uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_cash_custody')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select * into v_batch from public.cash_concentration_batches where company_id=p_company_id and reverse_request_id=p_client_request_id;
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true,'reversed_lines',
    (select count(*) from public.cash_concentration_lines where batch_id=v_batch.id and transfer_id is not null));end if;
  select * into v_batch from public.cash_concentration_batches where id=p_batch_id and company_id=p_company_id for update;
  if not found or v_batch.status<>'confirmed' then raise exception 'Sólo una concentración confirmada puede revertirse.';end if;
  for v_line in select id,transfer_id from public.cash_concentration_lines
    where batch_id=v_batch.id and transfer_id is not null order by id
  loop
    v_request:=extensions.uuid_generate_v5(p_client_request_id,'reverse:'||v_line.id::text);
    perform public.reverse_cash_transfer(p_company_id,v_line.transfer_id,p_effective_date,p_reason,v_request);
    v_count:=v_count+1;
  end loop;
  update public.cash_concentration_batches set status='reversed',reverse_request_id=p_client_request_id,
    reversed_by=auth.uid(),reversed_at=now(),reversal_reason=trim(p_reason)
    where id=v_batch.id returning * into v_batch;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'cash_custody.concentration_reversed','cash_concentration_batch',v_batch.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'reversed_lines',v_count));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false,'reversed_lines',v_count);
end $$;

create or replace function public.correct_accounting_location(
  p_company_id uuid,p_accounting_event_id uuid,p_journal_line_id uuid,p_location_id uuid,
  p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_event public.accounting_events%rowtype;v_line public.accounting_journal_lines%rowtype;v_correction public.accounting_location_corrections%rowtype;v_previous uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'correct_accounting_location')
    or p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null
  then raise exception 'No autorizado o faltan motivo e idempotencia.';end if;
  select correction.* into v_correction from public.accounting_location_corrections correction
    where correction.company_id=p_company_id and correction.client_request_id=p_client_request_id;
  if found then return to_jsonb(v_correction)||jsonb_build_object('idempotent',true);end if;
  select * into v_event from public.accounting_events where id=p_accounting_event_id and company_id=p_company_id and status='posted' for update;
  if not found then raise exception 'Evento contabilizado no disponible.';end if;
  if p_location_id is not null and not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id)
  then raise exception 'La ubicación corregida no pertenece a la empresa.';end if;
  if p_journal_line_id is null then
    v_previous:=v_event.location_id;
    perform set_config('app.accounting_location_correction',p_client_request_id::text,true);
    update public.accounting_events set location_id=p_location_id where id=v_event.id;
    update public.accounting_journal_lines set location_id=p_location_id where journal_entry_id=v_event.journal_entry_id;
  else
    select * into v_line from public.accounting_journal_lines where id=p_journal_line_id
      and company_id=p_company_id and journal_entry_id=v_event.journal_entry_id for update;
    if not found then raise exception 'La partida no pertenece al evento.';end if;
    v_previous:=v_line.location_id;
    perform set_config('app.accounting_location_correction',p_client_request_id::text,true);
    update public.accounting_journal_lines set location_id=p_location_id where id=v_line.id;
    update public.accounting_events set location_id=case
      when not exists(select 1 from public.accounting_journal_lines l where l.journal_entry_id=v_event.journal_entry_id
        and l.id<>v_line.id and l.location_id is distinct from p_location_id) then p_location_id else null end
    where id=v_event.id;
  end if;
  update public.accounting_journal_entries set content_sha256=encode(digest((
    select jsonb_agg(to_jsonb(line) order by line_number)::text from public.accounting_journal_lines line
    where journal_entry_id=v_event.journal_entry_id),'sha256'),'hex') where id=v_event.journal_entry_id;
  perform set_config('app.accounting_location_correction','',true);
  insert into public.accounting_location_corrections(company_id,accounting_event_id,journal_line_id,
    previous_location_id,corrected_location_id,reason,client_request_id)
  values(p_company_id,v_event.id,p_journal_line_id,v_previous,p_location_id,trim(p_reason),p_client_request_id)
  returning * into v_correction;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'accounting.location_corrected','accounting_event',v_event.id,
    jsonb_build_object('request_id',p_client_request_id,'journal_line_id',p_journal_line_id,
      'previous_location_id',v_previous,'location_id',p_location_id,'reason',trim(p_reason)));
  return to_jsonb(v_correction)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.list_cash_custody(
  p_company_id uuid,p_cutoff_date date,p_currency_code text,p_status text default null,
  p_location_id uuid default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_cash_reports') then raise exception 'No autorizado.';end if;
  return (
    with rows as (
      select r.id cash_register_id,r.code,r.display_name,r.location_id,l.name location_name,
        public.cash_register_custody_balance_as_of(p_company_id,r.id,(p_cutoff_date+1)::timestamptz-interval '1 microsecond') custody_amount
      from public.cash_registers r join public.locations l on l.id=r.location_id
      where r.company_id=p_company_id and r.currency_code=upper(trim(p_currency_code))
        and (p_location_id is null or r.location_id=p_location_id) and public.can_access_location(r.location_id)
    ), filtered as (
      select * from rows where p_status is null
        or (p_status='in_custody' and custody_amount<>0)
    ), page_rows as (
      select * from filtered order by location_name,code,cash_register_id offset (v_page-1)*v_size limit v_size
    )
    select jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from filtered),
      'total_amount',(select coalesce(sum(custody_amount),0) from filtered),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by location_name,code,cash_register_id) from page_rows x),'[]'::jsonb))
  );
end $$;

create or replace function public.list_cash_transfers(
  p_company_id uuid,p_status text default null,p_location_id uuid default null,p_from date default null,p_to date default null,
  p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_cash_reports') then raise exception 'No autorizado.';end if;
  return (
    with filtered as (
      select t.*,ol.name origin_location_name,dl.name destination_location_name
      from public.cash_custody_transfers t join public.locations ol on ol.id=t.origin_location_id
      join public.locations dl on dl.id=t.destination_location_id
      where t.company_id=p_company_id and (p_status is null or t.status=p_status)
        and (p_location_id is null or t.origin_location_id=p_location_id or t.destination_location_id=p_location_id)
        and (p_from is null or t.effective_date>=p_from) and (p_to is null or t.effective_date<=p_to)
        and public.can_access_location(t.origin_location_id) and public.can_access_location(t.destination_location_id)
    ), page_rows as (
      select * from filtered order by effective_date desc,id desc offset (v_page-1)*v_size limit v_size
    )
    select jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from filtered),
      'total_amount',(select coalesce(sum(amount),0) from filtered),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by effective_date desc,id desc) from page_rows x),'[]'::jsonb))
  );
end $$;

create or replace function public.list_cash_concentrations(
  p_company_id uuid,p_status text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_cash_reports') then raise exception 'No autorizado.';end if;
  return (
    with filtered as (
      select b.*,coalesce(sum(l.proposed_amount),0) proposed_total,count(l.id) line_count,
        count(*) filter(where l.excluded) excluded_count
      from public.cash_concentration_batches b left join public.cash_concentration_lines l on l.batch_id=b.id
      where b.company_id=p_company_id and (p_status is null or b.status=p_status)
        and public.can_access_location(b.destination_location_id)
      group by b.id
    ), page_rows as (
      select * from filtered order by cutoff_date desc,id desc offset (v_page-1)*v_size limit v_size
    )
    select jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from filtered),
      'total_amount',(select coalesce(sum(proposed_total),0) from filtered),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by cutoff_date desc,id desc) from page_rows x),'[]'::jsonb))
  );
end $$;

create or replace function public.list_cash_concentration_lines(
  p_company_id uuid,p_batch_id uuid,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_cash_reports') then raise exception 'No autorizado.';end if;
  return (
    with filtered as (
      select l.*,r.code cash_register_code,r.display_name cash_register_name,loc.name location_name
      from public.cash_concentration_lines l join public.cash_registers r on r.id=l.origin_cash_register_id
      join public.locations loc on loc.id=l.origin_location_id
      where l.company_id=p_company_id and l.batch_id=p_batch_id and public.can_access_location(l.origin_location_id)
    ), page_rows as (
      select * from filtered order by cash_register_code,id offset (v_page-1)*v_size limit v_size
    )
    select jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from filtered),
      'previous_total',(select coalesce(sum(previous_balance),0) from filtered),
      'proposed_total',(select coalesce(sum(proposed_amount),0) from filtered),
      'resulting_total',(select coalesce(sum(resulting_balance),0) from filtered),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by cash_register_code,id) from page_rows x),'[]'::jsonb))
  );
end $$;

create or replace function public.list_unassigned_accounting_locations(
  p_company_id uuid,p_from date default null,p_to date default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounting') then raise exception 'No autorizado.';end if;
  return (
    with filtered as (
      select e.id accounting_event_id,e.event_type,e.source_entity_type,e.source_entity_id,e.accounting_date,
        l.id journal_line_id,l.line_number,l.account_id,l.debit,l.credit,'Sin asignar' location_name
      from public.accounting_events e join public.accounting_journal_lines l on l.journal_entry_id=e.journal_entry_id
      where e.company_id=p_company_id and l.location_id is null
        and (p_from is null or e.accounting_date>=p_from) and (p_to is null or e.accounting_date<=p_to)
    ), page_rows as (
      select * from filtered order by accounting_date desc,accounting_event_id,line_number offset (v_page-1)*v_size limit v_size
    )
    select jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from filtered),
      'total_debit',(select coalesce(sum(debit),0) from filtered),'total_credit',(select coalesce(sum(credit),0) from filtered),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by accounting_date desc,accounting_event_id,line_number) from page_rows x),'[]'::jsonb))
  );
end $$;

-- Backfill estrictamente determinista. Los gastos históricos sin ubicación
-- explícita y cualquier documento ambiguo permanecen "Sin asignar".
update public.accounting_events e set location_id=public.resolve_accounting_source_location(e.company_id,e.source_entity_type,e.source_entity_id)
where e.location_id is null and public.resolve_accounting_source_location(e.company_id,e.source_entity_type,e.source_entity_id) is not null;
select set_config('app.accounting_location_correction','m4d3-deterministic-backfill',true);
update public.accounting_journal_lines l set location_id=e.location_id
from public.accounting_events e where e.journal_entry_id=l.journal_entry_id and l.location_id is null and e.location_id is not null;
update public.accounting_journal_entries entry set content_sha256=encode(extensions.digest((
  select jsonb_agg(to_jsonb(line) order by line.line_number)::text
  from public.accounting_journal_lines line where line.journal_entry_id=entry.id
),'sha256'),'hex')
where exists(
  select 1 from public.accounting_events event
  where event.journal_entry_id=entry.id and event.location_id is not null
);
select set_config('app.accounting_location_correction','',true);

alter table public.cash_register_accounting_accounts enable row level security;
alter table public.cash_custody_account_config enable row level security;
alter table public.cash_custody_transfers enable row level security;
alter table public.cash_concentration_batches enable row level security;
alter table public.cash_concentration_lines enable row level security;
alter table public.accounting_location_corrections enable row level security;

create policy cash_register_accounting_accounts_read on public.cash_register_accounting_accounts for select to authenticated
using(public.has_company_permission(company_id,'view_accounting') and public.can_access_location(
  (select location_id from public.cash_registers where id=cash_register_id)));
create policy cash_custody_account_config_read on public.cash_custody_account_config for select to authenticated
using(public.has_company_permission(company_id,'view_accounting'));
create policy cash_custody_transfers_read on public.cash_custody_transfers for select to authenticated
using(public.has_company_permission(company_id,'view_cash_reports')
  and public.can_access_location(origin_location_id) and public.can_access_location(destination_location_id));
create policy cash_concentration_batches_read on public.cash_concentration_batches for select to authenticated
using(public.has_company_permission(company_id,'view_cash_reports') and public.can_access_location(destination_location_id));
create policy cash_concentration_lines_read on public.cash_concentration_lines for select to authenticated
using(public.has_company_permission(company_id,'view_cash_reports') and public.can_access_location(origin_location_id));
create policy accounting_location_corrections_read on public.accounting_location_corrections for select to authenticated
using(public.has_company_permission(company_id,'view_accounting'));

grant select on public.cash_register_accounting_accounts,public.cash_custody_account_config,
  public.cash_custody_transfers,public.cash_concentration_batches,public.cash_concentration_lines,
  public.accounting_location_corrections to authenticated;

revoke all on function public.resolve_accounting_source_location(uuid,text,uuid),
  public.cash_register_custody_balance_as_of(uuid,uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.configure_cash_custody_accounts(uuid,uuid,uuid,uuid,text,uuid),
  public.assign_expense_line_location(uuid,uuid,uuid,text,uuid),
  public.prepare_cash_transfer(uuid,text,uuid,uuid,numeric,date,uuid,text,text,jsonb,uuid),
  public.approve_cash_transfer(uuid,uuid,text,uuid),
  public.confirm_cash_transfer_dispatch(uuid,uuid,jsonb,uuid),
  public.confirm_cash_transfer(uuid,uuid,jsonb,uuid),
  public.reverse_cash_transfer(uuid,uuid,date,text,uuid),
  public.prepare_cash_concentration(uuid,date,text,uuid,uuid),
  public.set_cash_concentration_exception(uuid,uuid,boolean,numeric,text,jsonb,uuid),
  public.approve_cash_concentration(uuid,uuid,text,uuid),
  public.confirm_cash_concentration(uuid,uuid,uuid,text,text,jsonb,uuid),
  public.reverse_cash_concentration(uuid,uuid,date,text,uuid),
  public.correct_accounting_location(uuid,uuid,uuid,uuid,text,uuid),
  public.list_cash_custody(uuid,date,text,text,uuid,integer,integer),
  public.list_cash_transfers(uuid,text,uuid,date,date,integer,integer),
  public.list_cash_concentrations(uuid,text,integer,integer),
  public.list_cash_concentration_lines(uuid,uuid,integer,integer),
  public.list_unassigned_accounting_locations(uuid,date,date,integer,integer)
from public,anon;
grant execute on function public.configure_cash_custody_accounts(uuid,uuid,uuid,uuid,text,uuid),
  public.assign_expense_line_location(uuid,uuid,uuid,text,uuid),
  public.prepare_cash_transfer(uuid,text,uuid,uuid,numeric,date,uuid,text,text,jsonb,uuid),
  public.approve_cash_transfer(uuid,uuid,text,uuid),
  public.confirm_cash_transfer_dispatch(uuid,uuid,jsonb,uuid),
  public.confirm_cash_transfer(uuid,uuid,jsonb,uuid),
  public.reverse_cash_transfer(uuid,uuid,date,text,uuid),
  public.prepare_cash_concentration(uuid,date,text,uuid,uuid),
  public.set_cash_concentration_exception(uuid,uuid,boolean,numeric,text,jsonb,uuid),
  public.approve_cash_concentration(uuid,uuid,text,uuid),
  public.confirm_cash_concentration(uuid,uuid,uuid,text,text,jsonb,uuid),
  public.reverse_cash_concentration(uuid,uuid,date,text,uuid),
  public.correct_accounting_location(uuid,uuid,uuid,uuid,text,uuid),
  public.list_cash_custody(uuid,date,text,text,uuid,integer,integer),
  public.list_cash_transfers(uuid,text,uuid,date,date,integer,integer),
  public.list_cash_concentrations(uuid,text,integer,integer),
  public.list_cash_concentration_lines(uuid,uuid,integer,integer),
  public.list_unassigned_accounting_locations(uuid,date,date,integer,integer)
to authenticated;

commit;
