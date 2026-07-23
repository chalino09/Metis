-- Satrapy · Bancos y conciliación.
-- Cuentas canónicas, staging masivo, movimientos inmutables y conciliación auditada.

insert into public.permissions(code,description) values
  ('view_banking','Consultar cuentas, estados, movimientos y conciliaciones bancarias.'),
  ('import_bank_statements','Importar estados bancarios desde el Centro de Migración.'),
  ('reconcile_banking','Confirmar candidatos bancarios y justificar diferencias.'),
  ('unreconcile_banking','Desconciliar movimientos conservando toda la evidencia.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in
  ('view_banking','import_bank_statements','reconcile_banking','unreconcile_banking')
on conflict do nothing;

create table public.financial_accounts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  legacy_paying_account_id uuid unique references public.supplier_paying_accounts(id) on delete restrict,
  institution_name text not null check(nullif(trim(institution_name),'') is not null),
  alias text not null check(nullif(trim(alias),'') is not null),
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  account_last4 text not null check(account_last4~'^[0-9A-Z]{4}$'),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,id)
);
create unique index financial_accounts_alias_uidx on public.financial_accounts(company_id,lower(alias));
create index financial_accounts_lookup_idx on public.financial_accounts(company_id,currency_code,account_last4,is_active);
create trigger financial_accounts_updated_at before update on public.financial_accounts for each row execute function public.set_updated_at();

insert into public.financial_accounts(id,company_id,legacy_paying_account_id,institution_name,alias,currency_code,account_last4,is_active,created_by,updated_by,created_at,updated_at)
select id,company_id,id,bank_name,alias,currency_code,account_last4,is_active,created_by,updated_by,created_at,updated_at
from public.supplier_paying_accounts
on conflict(id) do update set
  legacy_paying_account_id=excluded.legacy_paying_account_id,
  institution_name=excluded.institution_name,alias=excluded.alias,currency_code=excluded.currency_code,
  account_last4=excluded.account_last4,is_active=excluded.is_active,updated_by=excluded.updated_by,updated_at=excluded.updated_at;

create or replace function public.sync_paying_account_to_financial_account()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.financial_accounts(id,company_id,legacy_paying_account_id,institution_name,alias,currency_code,account_last4,is_active,created_by,updated_by,created_at,updated_at)
  values(new.id,new.company_id,new.id,new.bank_name,new.alias,new.currency_code,new.account_last4,new.is_active,new.created_by,new.updated_by,new.created_at,new.updated_at)
  on conflict(id) do update set institution_name=excluded.institution_name,alias=excluded.alias,currency_code=excluded.currency_code,account_last4=excluded.account_last4,is_active=excluded.is_active,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  return new;
end $$;
create trigger supplier_paying_accounts_financial_sync after insert or update on public.supplier_paying_accounts for each row execute function public.sync_paying_account_to_financial_account();

alter table public.supplier_payments add column financial_account_id uuid references public.financial_accounts(id) on delete restrict;
update public.supplier_payments set financial_account_id=paying_account_id where financial_account_id is null;
alter table public.supplier_payments alter column financial_account_id set not null;
create index supplier_payments_financial_reconciliation_idx on public.supplier_payments(company_id,financial_account_id,currency_code,effective_date,total_amount) where status='confirmed';

create or replace function public.sync_supplier_payment_financial_account()
returns trigger language plpgsql set search_path=public as $$
begin new.financial_account_id:=new.paying_account_id;return new;end $$;
create trigger supplier_payments_financial_account before insert or update of paying_account_id on public.supplier_payments for each row execute function public.sync_supplier_payment_financial_account();

-- Los cobros bancarios nuevos pueden aportar la evidencia que el dominio anterior no guardaba.
alter table public.receivable_payments add column financial_account_id uuid references public.financial_accounts(id) on delete restrict;
alter table public.receivable_payments add column currency_code text check(currency_code is null or currency_code~'^[A-Z]{3}$');
alter table public.receivable_payments add column bank_reference text;
create index receivable_payments_financial_reconciliation_idx on public.receivable_payments(company_id,financial_account_id,currency_code,received_at,amount) where settlement_kind='external';

create table public.bank_statement_batches(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  financial_account_id uuid not null references public.financial_accounts(id) on delete restrict,
  content_sha256 text not null check(content_sha256~'^[a-f0-9]{64}$'),
  original_name text not null check(nullif(trim(original_name),'') is not null),
  period_start date not null,
  period_end date not null check(period_end>=period_start),
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  opening_balance numeric(18,6) not null,
  closing_balance numeric(18,6) not null,
  total_credits numeric(18,6) not null default 0 check(total_credits>=0),
  total_debits numeric(18,6) not null default 0 check(total_debits>=0),
  calculated_closing_balance numeric(18,6),
  balance_difference numeric(18,6),
  balance_valid boolean not null default false,
  status text not null default 'staging' check(status in ('staging','ready','promoted','rejected')),
  row_count integer not null default 0 check(row_count>=0),
  exception_count integer not null default 0 check(exception_count>=0),
  detection_evidence jsonb not null default '{}'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  imported_by uuid references auth.users(id) on delete set null default auth.uid(),
  promoted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  promoted_at timestamptz,
  unique(company_id,financial_account_id,content_sha256),
  check((status='promoted')=(promoted_at is not null))
);
create index bank_statement_batches_list_idx on public.bank_statement_batches(company_id,created_at desc,id desc);

create table public.bank_statement_staging_rows(
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.bank_statement_batches(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  row_number integer not null check(row_number>0),
  transaction_date date,
  value_date date,
  reference text,
  description text,
  credit numeric(18,6) not null default 0 check(credit>=0),
  debit numeric(18,6) not null default 0 check(debit>=0),
  running_balance numeric(18,6),
  row_sha256 text not null check(row_sha256~'^[a-f0-9]{64}$'),
  raw_data jsonb not null,
  validation_status text not null default 'pending' check(validation_status in ('pending','valid','error')),
  validation_issues jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  unique(batch_id,row_number),unique(batch_id,row_sha256),
  check(not(credit>0 and debit>0))
);
create index bank_statement_staging_page_idx on public.bank_statement_staging_rows(batch_id,row_number);

create table public.bank_transactions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  financial_account_id uuid not null references public.financial_accounts(id) on delete restrict,
  statement_batch_id uuid not null references public.bank_statement_batches(id) on delete restrict,
  source_row_id uuid not null unique references public.bank_statement_staging_rows(id) on delete restrict,
  transaction_date date not null,
  value_date date,
  reference text not null,
  description text,
  direction text not null check(direction in ('credit','debit')),
  amount numeric(18,6) not null check(amount>0),
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  running_balance numeric(18,6),
  row_sha256 text not null check(row_sha256~'^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  unique(financial_account_id,row_sha256)
);
create index bank_transactions_match_idx on public.bank_transactions(company_id,financial_account_id,currency_code,direction,transaction_date,amount);

create table public.bank_reconciliation_candidates(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_transaction_id uuid not null references public.bank_transactions(id) on delete cascade,
  source_type text not null check(source_type in ('receivable_payment','supplier_payment')),
  source_id uuid not null,
  match_quality text not null check(match_quality in ('exact','possible')),
  amount_difference numeric(18,6) not null,
  date_difference_days integer not null,
  account_matches boolean not null,
  currency_matches boolean not null,
  amount_matches boolean not null,
  date_matches boolean not null,
  reference_matches boolean not null,
  evidence jsonb not null,
  created_at timestamptz not null default now(),
  unique(bank_transaction_id,source_type,source_id)
);
create index bank_reconciliation_candidates_page_idx on public.bank_reconciliation_candidates(company_id,match_quality,created_at desc,id desc);

create table public.bank_reconciliations(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_transaction_id uuid not null references public.bank_transactions(id) on delete restrict,
  source_type text not null check(source_type in ('receivable_payment','supplier_payment')),
  source_id uuid not null,
  status text not null default 'confirmed' check(status in ('confirmed','disconnected')),
  match_quality text not null check(match_quality in ('exact','justified_difference')),
  amount_difference numeric(18,6) not null default 0,
  justification text,
  confirmed_by uuid references auth.users(id) on delete set null default auth.uid(),
  confirmed_at timestamptz not null default now(),
  disconnected_by uuid references auth.users(id) on delete set null,
  disconnected_at timestamptz,
  disconnection_reason text,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  check((status='disconnected')=(disconnected_at is not null)),
  check(match_quality='exact' or nullif(trim(coalesce(justification,'')),'') is not null),
  check(status='confirmed' or nullif(trim(coalesce(disconnection_reason,'')),'') is not null)
);
create unique index bank_reconciliations_active_transaction_uidx on public.bank_reconciliations(bank_transaction_id) where status='confirmed';
create unique index bank_reconciliations_active_source_uidx on public.bank_reconciliations(source_type,source_id) where status='confirmed';
create index bank_reconciliations_company_idx on public.bank_reconciliations(company_id,confirmed_at desc,id desc);

create table public.bank_reconciliation_exceptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_transaction_id uuid references public.bank_transactions(id) on delete restrict,
  statement_batch_id uuid references public.bank_statement_batches(id) on delete restrict,
  exception_code text not null,
  severity text not null check(severity in ('warning','error')),
  message text not null,
  status text not null default 'pending' check(status in ('pending','resolved')),
  evidence jsonb not null default '{}'::jsonb,
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  check((status='resolved')=(resolved_at is not null))
);
create index bank_reconciliation_exceptions_page_idx on public.bank_reconciliation_exceptions(company_id,status,created_at desc,id desc);
create unique index bank_reconciliation_exceptions_transaction_pending_uidx on public.bank_reconciliation_exceptions(bank_transaction_id,exception_code) where status='pending' and bank_transaction_id is not null;
create unique index bank_reconciliation_exceptions_batch_pending_uidx on public.bank_reconciliation_exceptions(statement_batch_id,exception_code) where status='pending' and statement_batch_id is not null and bank_transaction_id is null;

create table public.bank_reconciliation_requests(
  company_id uuid not null references public.companies(id) on delete cascade,
  request_id uuid not null,
  operation text not null check(operation in ('promote','confirm','disconnect')),
  result jsonb not null,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key(company_id,request_id)
);

create or replace function public.guard_bank_evidence_immutable()
returns trigger language plpgsql set search_path=public as $$begin raise exception 'La evidencia bancaria es inmutable.';end$$;
create trigger bank_transactions_immutable before update or delete on public.bank_transactions for each row execute function public.guard_bank_evidence_immutable();
create trigger bank_reconciliation_candidates_immutable before update or delete on public.bank_reconciliation_candidates for each row execute function public.guard_bank_evidence_immutable();

alter table public.financial_accounts enable row level security;
alter table public.bank_statement_batches enable row level security;
alter table public.bank_statement_staging_rows enable row level security;
alter table public.bank_transactions enable row level security;
alter table public.bank_reconciliation_candidates enable row level security;
alter table public.bank_reconciliations enable row level security;
alter table public.bank_reconciliation_exceptions enable row level security;
alter table public.bank_reconciliation_requests enable row level security;

create policy financial_accounts_read on public.financial_accounts for select to authenticated using(public.has_company_permission(company_id,'view_banking') or public.has_company_permission(company_id,'manage_supplier_paying_accounts'));
create policy bank_statement_batches_read on public.bank_statement_batches for select to authenticated using(public.has_company_permission(company_id,'view_banking'));
create policy bank_statement_staging_rows_read on public.bank_statement_staging_rows for select to authenticated using(public.has_company_permission(company_id,'view_banking'));
create policy bank_transactions_read on public.bank_transactions for select to authenticated using(public.has_company_permission(company_id,'view_banking'));
create policy bank_reconciliation_candidates_read on public.bank_reconciliation_candidates for select to authenticated using(public.has_company_permission(company_id,'view_banking'));
create policy bank_reconciliations_read on public.bank_reconciliations for select to authenticated using(public.has_company_permission(company_id,'view_banking'));
create policy bank_reconciliation_exceptions_read on public.bank_reconciliation_exceptions for select to authenticated using(public.has_company_permission(company_id,'view_banking'));

create or replace function public.create_bank_statement_staging(
  p_company_id uuid,p_account_last4 text,p_currency_code text,p_original_name text,p_content_sha256 text,
  p_period_start date,p_period_end date,p_opening_balance numeric,p_closing_balance numeric,p_detection_evidence jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_account public.financial_accounts%rowtype;v_batch public.bank_statement_batches%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_bank_statements') then raise exception 'No autorizado para importar estados bancarios.';end if;
  if lower(coalesce(p_content_sha256,''))!~'^[a-f0-9]{64}$' or p_period_start is null or p_period_end is null or p_period_end<p_period_start or p_opening_balance is null or p_closing_balance is null then raise exception 'Metadatos del estado bancario incompletos.';end if;
  select * into v_account from public.financial_accounts where company_id=p_company_id and account_last4=upper(trim(coalesce(p_account_last4,''))) and currency_code=upper(trim(coalesce(p_currency_code,''))) and is_active;
  if not found then raise exception 'No existe una cuenta financiera activa que coincida con terminación y moneda detectadas.';end if;
  if exists(select 1 from public.financial_accounts where company_id=p_company_id and id<>v_account.id and account_last4=v_account.account_last4 and currency_code=v_account.currency_code and is_active) then raise exception 'La cuenta detectada es ambigua; corrige el catálogo financiero antes de volver a cargar.';end if;
  insert into public.bank_statement_batches(company_id,financial_account_id,content_sha256,original_name,period_start,period_end,currency_code,opening_balance,closing_balance,detection_evidence)
  values(p_company_id,v_account.id,lower(p_content_sha256),trim(p_original_name),p_period_start,p_period_end,v_account.currency_code,p_opening_balance,p_closing_balance,coalesce(p_detection_evidence,'{}'::jsonb))
  on conflict(company_id,financial_account_id,content_sha256) do nothing returning * into v_batch;
  if not found then select * into v_batch from public.bank_statement_batches where company_id=p_company_id and financial_account_id=v_account.id and content_sha256=lower(p_content_sha256);return to_jsonb(v_batch)||jsonb_build_object('idempotent',true);end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'bank_statement.staging_created','bank_statement_batch',v_batch.id,jsonb_build_object('sha256',v_batch.content_sha256,'financial_account_id',v_account.id,'period_start',p_period_start,'period_end',p_period_end));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false);
end$$;

create or replace function public.stage_bank_statement_rows(p_batch_id uuid,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.bank_statement_batches%rowtype;v_inserted integer;
begin
  select * into v_batch from public.bank_statement_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_bank_statements') then raise exception 'Lote bancario no disponible.';end if;
  if v_batch.status<>'staging' then raise exception 'El lote ya no admite staging.';end if;
  if jsonb_array_length(coalesce(p_rows,'[]'::jsonb))>2000 then raise exception 'Cada bloque admite hasta 2000 movimientos.';end if;
  insert into public.bank_statement_staging_rows(batch_id,company_id,row_number,transaction_date,value_date,reference,description,credit,debit,running_balance,row_sha256,raw_data,validation_status,validation_issues)
  select p_batch_id,v_batch.company_id,r.row_number,r.transaction_date,r.value_date,nullif(trim(r.reference),''),nullif(trim(r.description),''),coalesce(r.credit,0),coalesce(r.debit,0),r.running_balance,lower(r.row_sha256),coalesce(r.raw_data,'{}'::jsonb),
    case when r.transaction_date is null or nullif(trim(r.reference),'') is null or (coalesce(r.credit,0)>0)=(coalesce(r.debit,0)>0) or greatest(coalesce(r.credit,0),coalesce(r.debit,0))<=0 then 'error' else 'valid' end,
    case when r.transaction_date is null then '["MISSING_DATE"]'::jsonb when nullif(trim(r.reference),'') is null then '["MISSING_REFERENCE"]'::jsonb when (coalesce(r.credit,0)>0)=(coalesce(r.debit,0)>0) then '["INVALID_DIRECTION"]'::jsonb else '[]'::jsonb end
  from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) r(row_number integer,transaction_date date,value_date date,reference text,description text,credit numeric,debit numeric,running_balance numeric,row_sha256 text,raw_data jsonb)
  on conflict(batch_id,row_number) do update set transaction_date=excluded.transaction_date,value_date=excluded.value_date,reference=excluded.reference,description=excluded.description,credit=excluded.credit,debit=excluded.debit,running_balance=excluded.running_balance,row_sha256=excluded.row_sha256,raw_data=excluded.raw_data,validation_status=excluded.validation_status,validation_issues=excluded.validation_issues;
  get diagnostics v_inserted=row_count;return jsonb_build_object('batch_id',p_batch_id,'rows_staged',v_inserted);
end$$;

create or replace function public.finalize_bank_statement_staging(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.bank_statement_batches%rowtype;v_credits numeric;v_debits numeric;v_rows int;v_errors int;v_calculated numeric;v_difference numeric;
begin
  select * into v_batch from public.bank_statement_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_bank_statements') then raise exception 'Lote bancario no disponible.';end if;
  select count(*),coalesce(sum(credit),0),coalesce(sum(debit),0),count(*) filter(where validation_status='error') into v_rows,v_credits,v_debits,v_errors from public.bank_statement_staging_rows where batch_id=p_batch_id;
  v_calculated:=round(v_batch.opening_balance+v_credits-v_debits,6);v_difference:=round(v_calculated-v_batch.closing_balance,6);
  update public.bank_statement_batches set row_count=v_rows,total_credits=v_credits,total_debits=v_debits,calculated_closing_balance=v_calculated,balance_difference=v_difference,balance_valid=(v_difference=0),exception_count=v_errors+(case when v_difference=0 then 0 else 1 end),status=case when v_rows>0 and v_errors=0 and v_difference=0 then 'ready' else 'rejected' end,summary=jsonb_build_object('formula','saldo inicial + abonos - cargos = saldo final','opening_balance',opening_balance,'credits',v_credits,'debits',v_debits,'calculated_closing_balance',v_calculated,'reported_closing_balance',closing_balance,'difference',v_difference) where id=p_batch_id returning * into v_batch;
  if v_difference<>0 then insert into public.bank_reconciliation_exceptions(company_id,statement_batch_id,exception_code,severity,message,evidence) values(v_batch.company_id,p_batch_id,'STATEMENT_BALANCE_MISMATCH','error','El saldo inicial más abonos menos cargos no coincide con el saldo final.',v_batch.summary);end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'bank_statement.staging_finalized','bank_statement_batch',p_batch_id,jsonb_build_object('status',v_batch.status,'row_count',v_rows,'balance_valid',v_batch.balance_valid,'balance_difference',v_difference));
  return to_jsonb(v_batch);
end$$;

create or replace function public.refresh_bank_reconciliation_candidates(p_company_id uuid,p_financial_account_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_created integer:=0;v_receivable_created integer:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reconcile_banking') then raise exception 'No autorizado para preparar conciliación.';end if;
  if not exists(select 1 from public.financial_accounts where id=p_financial_account_id and company_id=p_company_id) then raise exception 'Cuenta financiera no disponible.';end if;
  insert into public.bank_reconciliation_candidates(company_id,bank_transaction_id,source_type,source_id,match_quality,amount_difference,date_difference_days,account_matches,currency_matches,amount_matches,date_matches,reference_matches,evidence)
  select p_company_id,t.id,'supplier_payment',p.id,
    case when t.amount=p.total_amount and t.transaction_date=p.effective_date and lower(trim(t.reference))=lower(trim(p.reference)) then 'exact' else 'possible' end,
    round(t.amount-p.total_amount,6),abs(t.transaction_date-p.effective_date),true,true,t.amount=p.total_amount,t.transaction_date=p.effective_date,lower(trim(t.reference))=lower(trim(p.reference)),
    jsonb_build_object('account_id',t.financial_account_id,'currency',t.currency_code,'bank_amount',t.amount,'source_amount',p.total_amount,'bank_date',t.transaction_date,'source_date',p.effective_date,'bank_reference',t.reference,'source_reference',p.reference)
  from public.bank_transactions t join public.supplier_payments p on p.company_id=t.company_id and p.financial_account_id=t.financial_account_id and p.currency_code=t.currency_code and p.status='confirmed' and p.total_amount between t.amount-1 and t.amount+1 and p.effective_date between t.transaction_date-3 and t.transaction_date+3
  where t.company_id=p_company_id and t.financial_account_id=p_financial_account_id and t.direction='debit' and not exists(select 1 from public.bank_reconciliations r where r.bank_transaction_id=t.id and r.status='confirmed')
  on conflict(bank_transaction_id,source_type,source_id) do nothing;
  get diagnostics v_created=row_count;
  insert into public.bank_reconciliation_candidates(company_id,bank_transaction_id,source_type,source_id,match_quality,amount_difference,date_difference_days,account_matches,currency_matches,amount_matches,date_matches,reference_matches,evidence)
  select p_company_id,t.id,'receivable_payment',p.id,
    case when t.amount=p.amount and t.transaction_date=p.received_at::date and lower(trim(t.reference))=lower(trim(p.bank_reference)) then 'exact' else 'possible' end,
    round(t.amount-p.amount,6),abs(t.transaction_date-p.received_at::date),true,true,t.amount=p.amount,t.transaction_date=p.received_at::date,lower(trim(t.reference))=lower(trim(p.bank_reference)),
    jsonb_build_object('account_id',t.financial_account_id,'currency',t.currency_code,'bank_amount',t.amount,'source_amount',p.amount,'bank_date',t.transaction_date,'source_date',p.received_at::date,'bank_reference',t.reference,'source_reference',p.bank_reference)
  from public.bank_transactions t join public.receivable_payments p on p.company_id=t.company_id and p.financial_account_id=t.financial_account_id and p.currency_code=t.currency_code and p.settlement_kind='external' and p.amount between t.amount-1 and t.amount+1 and p.received_at::date between t.transaction_date-3 and t.transaction_date+3 and p.bank_reference is not null
  where t.company_id=p_company_id and t.financial_account_id=p_financial_account_id and t.direction='credit' and not exists(select 1 from public.receivable_payment_reversals rv where rv.receivable_payment_id=p.id) and not exists(select 1 from public.bank_reconciliations r where r.bank_transaction_id=t.id and r.status='confirmed')
  on conflict(bank_transaction_id,source_type,source_id) do nothing;
  get diagnostics v_receivable_created=row_count;v_created:=v_created+v_receivable_created;
  insert into public.bank_reconciliation_exceptions(company_id,bank_transaction_id,exception_code,severity,message,evidence)
  select p_company_id,t.id,case when count(c.id)=0 then 'NO_CANDIDATE' else 'AMBIGUOUS_CANDIDATE' end,'warning',case when count(c.id)=0 then 'No existe un cobro o pago con evidencia suficiente.' else 'Existen varios candidatos o diferencias por revisar.' end,jsonb_build_object('candidate_count',count(c.id))
  from public.bank_transactions t left join public.bank_reconciliation_candidates c on c.bank_transaction_id=t.id
  where t.company_id=p_company_id and t.financial_account_id=p_financial_account_id and not exists(select 1 from public.bank_reconciliations r where r.bank_transaction_id=t.id and r.status='confirmed')
  group by t.id having count(c.id)<>1 or count(c.id) filter(where c.match_quality='exact')<>1
  on conflict do nothing;
  return jsonb_build_object('candidates_created',v_created);
end$$;

create or replace function public.promote_bank_statement(p_batch_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.bank_statement_batches%rowtype;v_existing jsonb;v_count int;v_result jsonb;
begin
  select * into v_batch from public.bank_statement_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_bank_statements') then raise exception 'Lote bancario no disponible.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(v_batch.company_id::text||p_client_request_id::text,0));
  select result into v_existing from public.bank_reconciliation_requests where company_id=v_batch.company_id and request_id=p_client_request_id and operation='promote';if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  if v_batch.status='promoted' then return jsonb_build_object('batch_id',p_batch_id,'status','promoted','idempotent',true);end if;
  if v_batch.status<>'ready' or not v_batch.balance_valid then raise exception 'Sólo un estado validado y balanceado puede promoverse.';end if;
  insert into public.bank_transactions(company_id,financial_account_id,statement_batch_id,source_row_id,transaction_date,value_date,reference,description,direction,amount,currency_code,running_balance,row_sha256)
  select v_batch.company_id,v_batch.financial_account_id,p_batch_id,s.id,s.transaction_date,s.value_date,s.reference,s.description,case when s.credit>0 then 'credit' else 'debit' end,greatest(s.credit,s.debit),v_batch.currency_code,s.running_balance,s.row_sha256 from public.bank_statement_staging_rows s where s.batch_id=p_batch_id and s.validation_status='valid' order by s.row_number;
  get diagnostics v_count=row_count;
  update public.bank_statement_batches set status='promoted',promoted_by=auth.uid(),promoted_at=clock_timestamp() where id=p_batch_id;
  v_result:=jsonb_build_object('batch_id',p_batch_id,'status','promoted','transactions_created',v_count,'idempotent',false);
  insert into public.bank_reconciliation_requests(company_id,request_id,operation,result) values(v_batch.company_id,p_client_request_id,'promote',v_result);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'bank_statement.promoted','bank_statement_batch',p_batch_id,v_result);
  perform public.refresh_bank_reconciliation_candidates(v_batch.company_id,v_batch.financial_account_id);return v_result;
end$$;

create or replace function public.confirm_bank_reconciliations(p_company_id uuid,p_candidate_ids uuid[],p_justifications jsonb,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing jsonb;v_count int;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reconcile_banking') then raise exception 'No autorizado para conciliar.';end if;
  if p_client_request_id is null or coalesce(array_length(p_candidate_ids,1),0)=0 or array_length(p_candidate_ids,1)>500 then raise exception 'Selecciona entre 1 y 500 candidatos y usa una llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));select result into v_existing from public.bank_reconciliation_requests where company_id=p_company_id and request_id=p_client_request_id and operation='confirm';if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  if exists(select 1 from public.bank_reconciliation_candidates c where c.id=any(p_candidate_ids) and c.company_id=p_company_id group by c.bank_transaction_id having count(*)>1) then raise exception 'No se pueden confirmar dos candidatos del mismo movimiento.';end if;
  if exists(select 1 from public.bank_reconciliation_candidates c where c.id=any(p_candidate_ids) and c.company_id=p_company_id and c.match_quality='possible' and nullif(trim(coalesce(p_justifications->>c.id::text,'')),'') is null) then raise exception 'Toda diferencia requiere justificación por candidato.';end if;
  insert into public.bank_reconciliations(company_id,bank_transaction_id,source_type,source_id,match_quality,amount_difference,justification,evidence)
  select p_company_id,c.bank_transaction_id,c.source_type,c.source_id,case when c.match_quality='exact' then 'exact' else 'justified_difference' end,c.amount_difference,nullif(trim(p_justifications->>c.id::text),''),c.evidence from public.bank_reconciliation_candidates c where c.company_id=p_company_id and c.id=any(p_candidate_ids);
  get diagnostics v_count=row_count;if v_count<>array_length(p_candidate_ids,1) then raise exception 'Uno o más candidatos no están disponibles.';end if;
  update public.bank_reconciliation_exceptions e set status='resolved',resolved_by=auth.uid(),resolved_at=clock_timestamp() where e.company_id=p_company_id and e.bank_transaction_id in(select c.bank_transaction_id from public.bank_reconciliation_candidates c where c.id=any(p_candidate_ids)) and e.status='pending';
  update public.supplier_payments p set reconciliation_status='reconciled' where p.id in(select c.source_id from public.bank_reconciliation_candidates c where c.id=any(p_candidate_ids) and c.source_type='supplier_payment');
  v_result:=jsonb_build_object('confirmed',v_count,'idempotent',false);insert into public.bank_reconciliation_requests(company_id,request_id,operation,result) values(p_company_id,p_client_request_id,'confirm',v_result);insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'bank_reconciliation.bulk_confirmed','bank_reconciliation',v_result);return v_result;
end$$;

alter table public.supplier_payments drop constraint supplier_payments_reconciliation_status_check;
alter table public.supplier_payments add constraint supplier_payments_reconciliation_status_check check(reconciliation_status in ('unreconciled','reconciled'));

create or replace function public.disconnect_bank_reconciliations(p_company_id uuid,p_reconciliation_ids uuid[],p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing jsonb;v_count int;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'unreconcile_banking') then raise exception 'No autorizado para desconciliar.';end if;
  if p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null or coalesce(array_length(p_reconciliation_ids,1),0)=0 or array_length(p_reconciliation_ids,1)>500 then raise exception 'Motivo, selección masiva y llave son obligatorios.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));select result into v_existing from public.bank_reconciliation_requests where company_id=p_company_id and request_id=p_client_request_id and operation='disconnect';if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  update public.bank_reconciliations set status='disconnected',disconnected_by=auth.uid(),disconnected_at=clock_timestamp(),disconnection_reason=trim(p_reason) where company_id=p_company_id and id=any(p_reconciliation_ids) and status='confirmed';get diagnostics v_count=row_count;
  if v_count<>array_length(p_reconciliation_ids,1) then raise exception 'Una o más conciliaciones ya no están activas.';end if;
  update public.supplier_payments p set reconciliation_status='unreconciled' where exists(select 1 from public.bank_reconciliations r where r.id=any(p_reconciliation_ids) and r.source_type='supplier_payment' and r.source_id=p.id);
  v_result:=jsonb_build_object('disconnected',v_count,'reason',trim(p_reason),'idempotent',false);insert into public.bank_reconciliation_requests(company_id,request_id,operation,result) values(p_company_id,p_client_request_id,'disconnect',v_result);insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'bank_reconciliation.bulk_disconnected','bank_reconciliation',v_result);return v_result;
end$$;

create or replace function public.list_banking_workspace(p_company_id uuid,p_account_id uuid default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_account uuid;v_total bigint;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_banking') then raise exception 'No autorizado para consultar Bancos.';end if;
  select id into v_account from public.financial_accounts where company_id=p_company_id and (p_account_id is null or id=p_account_id) order by is_active desc,alias,id limit 1;
  select count(*) into v_total from public.bank_transactions t where t.company_id=p_company_id and (v_account is null or t.financial_account_id=v_account);
  return jsonb_build_object(
    'accounts',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'alias',a.alias,'institution_name',a.institution_name,'currency_code',a.currency_code,'masked_ending','•••• '||a.account_last4,'is_active',a.is_active) order by a.is_active desc,a.alias) from public.financial_accounts a where a.company_id=p_company_id),'[]'::jsonb),
    'selected_account_id',v_account,
    'batches',coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from(select * from public.bank_statement_batches where company_id=p_company_id and (v_account is null or financial_account_id=v_account) order by created_at desc limit 20)b),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('active_reconciliation_id',r.id) order by t.transaction_date desc,t.id desc) from(select * from public.bank_transactions where company_id=p_company_id and (v_account is null or financial_account_id=v_account) order by transaction_date desc,id desc limit v_size offset(v_page-1)*v_size)t left join public.bank_reconciliations r on r.bank_transaction_id=t.id and r.status='confirmed'),'[]'::jsonb),
    'candidates',coalesce((select jsonb_agg(to_jsonb(c) order by c.match_quality,c.created_at) from public.bank_reconciliation_candidates c join public.bank_transactions t on t.id=c.bank_transaction_id where c.company_id=p_company_id and (v_account is null or t.financial_account_id=v_account) and not exists(select 1 from public.bank_reconciliations r where r.bank_transaction_id=c.bank_transaction_id and r.status='confirmed')),'[]'::jsonb),
    'exceptions',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.bank_reconciliation_exceptions e left join public.bank_transactions t on t.id=e.bank_transaction_id where e.company_id=p_company_id and e.status='pending' and (v_account is null or t.financial_account_id=v_account or e.statement_batch_id in(select id from public.bank_statement_batches where financial_account_id=v_account))),'[]'::jsonb),
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total,'pages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end)
  );
end$$;

revoke all on function public.create_bank_statement_staging(uuid,text,text,text,text,date,date,numeric,numeric,jsonb),public.stage_bank_statement_rows(uuid,jsonb),public.finalize_bank_statement_staging(uuid),public.promote_bank_statement(uuid,uuid),public.refresh_bank_reconciliation_candidates(uuid,uuid),public.confirm_bank_reconciliations(uuid,uuid[],jsonb,uuid),public.disconnect_bank_reconciliations(uuid,uuid[],text,uuid),public.list_banking_workspace(uuid,uuid,integer,integer) from public;
grant execute on function public.create_bank_statement_staging(uuid,text,text,text,text,date,date,numeric,numeric,jsonb),public.stage_bank_statement_rows(uuid,jsonb),public.finalize_bank_statement_staging(uuid),public.promote_bank_statement(uuid,uuid),public.refresh_bank_reconciliation_candidates(uuid,uuid),public.confirm_bank_reconciliations(uuid,uuid[],jsonb,uuid),public.disconnect_bank_reconciliations(uuid,uuid[],text,uuid),public.list_banking_workspace(uuid,uuid,integer,integer) to authenticated;

-- Escrituras directas quedan cerradas; sólo RPC transaccionales pueden mutar el dominio.
revoke insert,update,delete on public.financial_accounts,public.bank_statement_batches,public.bank_statement_staging_rows,public.bank_transactions,public.bank_reconciliation_candidates,public.bank_reconciliations,public.bank_reconciliation_exceptions,public.bank_reconciliation_requests from authenticated,anon;
