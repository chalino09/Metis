-- Satrapy · M4A: base contable y apertura.
-- No genera contabilización operativa (M4B). El único asiento automático de este
-- alcance es la póliza inmutable de apertura promovida desde staging validado.

create extension if not exists btree_gist;

insert into public.permissions(code,description) values
  ('view_accounting','Consultar configuración, catálogo, periodos y pólizas.'),
  ('configure_accounting','Versionar y aprobar la configuración contable.'),
  ('import_accounting_opening','Preparar y promover catálogo/balanza de apertura.'),
  ('post_accounting_adjustments','Capturar y contabilizar ajustes manuales.'),
  ('close_accounting_periods','Cerrar periodos contables.'),
  ('reopen_accounting_periods','Reabrir periodos cerrados con motivo auditado.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_accounting','configure_accounting','import_accounting_opening',
  'post_accounting_adjustments','close_accounting_periods','reopen_accounting_periods'
) on conflict do nothing;

create table public.accounting_config_versions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  version integer not null check(version>0),
  status text not null default 'draft' check(status in ('draft','approved','superseded')),
  base_currency text not null check(base_currency~'^[A-Z]{3}$'),
  cutoff_date date not null,
  catalog_structure jsonb not null check(jsonb_typeof(catalog_structure)='object'),
  tax_treatment jsonb not null check(jsonb_typeof(tax_treatment)='object'),
  responsibilities jsonb not null check(jsonb_typeof(responsibilities)='object'),
  change_reason text not null check(nullif(trim(change_reason),'') is not null),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  approved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  unique(company_id,version),
  check((status='draft' and approved_at is null) or (status in ('approved','superseded') and approved_at is not null))
);
create unique index accounting_config_one_approved_idx on public.accounting_config_versions(company_id) where status='approved';

create table public.accounting_accounts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check(nullif(trim(code),'') is not null),
  name text not null check(nullif(trim(name),'') is not null),
  account_type text not null check(account_type in ('asset','liability','equity','revenue','expense','memorandum')),
  normal_balance text not null check(normal_balance in ('debit','credit')),
  parent_id uuid references public.accounting_accounts(id) on delete restrict,
  level integer not null check(level between 1 and 20),
  accepts_posting boolean not null default true,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,code),
  unique(company_id,id)
);
create index accounting_accounts_catalog_idx on public.accounting_accounts(company_id,is_active,code);
create trigger accounting_accounts_updated_at before update on public.accounting_accounts for each row execute function public.set_updated_at();

create table public.accounting_control_accounts(
  config_version_id uuid not null references public.accounting_config_versions(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  control_key text not null check(control_key in (
    'accounts_receivable','accounts_payable','inventory','cash','banks',
    'vat_pending','vat_collected','vat_paid','withholdings'
  )),
  account_id uuid not null,
  primary key(config_version_id,control_key),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict
);

create table public.accounting_periods(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_code text not null,
  starts_on date not null,
  ends_on date not null,
  status text not null default 'open' check(status in ('open','closed')),
  closed_by uuid references auth.users(id) on delete set null,
  closed_at timestamptz,
  reopened_by uuid references auth.users(id) on delete set null,
  reopened_at timestamptz,
  reopen_reason text,
  created_at timestamptz not null default now(),
  unique(company_id,period_code),
  exclude using gist(company_id with =,daterange(starts_on,ends_on,'[]') with &&),
  check(starts_on<=ends_on),
  check((status='closed')=(closed_at is not null))
);
create index accounting_periods_status_idx on public.accounting_periods(company_id,status,starts_on);

create table public.accounting_journal_entries(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_id uuid not null references public.accounting_periods(id) on delete restrict,
  entry_number bigint not null,
  entry_date date not null,
  description text not null check(nullif(trim(description),'') is not null),
  source_type text not null check(source_type in ('opening','manual_adjustment')),
  status text not null default 'draft' check(status in ('draft','posted','reversed')),
  immutable boolean not null default false,
  source_batch_id uuid,
  client_request_id uuid not null,
  content_sha256 text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  posted_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text,
  created_at timestamptz not null default now(),
  unique(company_id,entry_number),
  unique(company_id,client_request_id),
  check((status='draft' and posted_at is null) or (status in ('posted','reversed') and posted_at is not null)),
  check(source_type<>'opening' or status='draft' or immutable)
);

create table public.accounting_journal_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  journal_entry_id uuid not null references public.accounting_journal_entries(id) on delete cascade,
  line_number integer not null check(line_number>0),
  account_id uuid not null,
  description text,
  debit numeric(18,6) not null default 0 check(debit>=0),
  credit numeric(18,6) not null default 0 check(credit>=0),
  external_account_code text,
  created_at timestamptz not null default now(),
  unique(journal_entry_id,line_number),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict,
  check((debit>0 and credit=0) or (credit>0 and debit=0))
);
create index accounting_journal_lines_account_idx on public.accounting_journal_lines(company_id,account_id,journal_entry_id);

create table public.accounting_period_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_id uuid not null references public.accounting_periods(id) on delete restrict,
  action text not null check(action in ('closed','reopened')),
  reason text not null,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  occurred_at timestamptz not null default now()
);

create table public.accounting_import_batches(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  import_type text not null check(import_type in ('chart_of_accounts','trial_balance')),
  cutoff_date date not null,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  original_name text not null,
  content_sha256 text not null check(content_sha256~'^[0-9a-f]{64}$'),
  status text not null default 'loading' check(status in ('loading','staged','validation_failed','promoted','failed')),
  row_count integer not null default 0 check(row_count>=0),
  error_count integer not null default 0 check(error_count>=0),
  warning_count integer not null default 0 check(warning_count>=0),
  summary jsonb not null default '{}'::jsonb,
  promoted_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  promoted_at timestamptz,
  unique(company_id,import_type,content_sha256)
);
alter table public.accounting_journal_entries add constraint accounting_journal_source_batch_fk
  foreign key(source_batch_id) references public.accounting_import_batches(id) on delete restrict;

create table public.accounting_import_rows(
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.accounting_import_batches(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  row_number integer not null check(row_number>0),
  external_account_code text not null,
  account_name text,
  parent_external_code text,
  account_type text,
  normal_balance text,
  accepts_posting boolean,
  debit numeric(18,6) not null default 0 check(debit>=0),
  credit numeric(18,6) not null default 0 check(credit>=0),
  mapped_account_id uuid,
  status text not null default 'pending' check(status in ('pending','valid','warning','error')),
  issues jsonb not null default '[]'::jsonb check(jsonb_typeof(issues)='array'),
  raw_data jsonb not null default '{}'::jsonb,
  unique(batch_id,row_number),
  foreign key(company_id,mapped_account_id) references public.accounting_accounts(company_id,id) on delete restrict
);
create index accounting_import_rows_review_idx on public.accounting_import_rows(batch_id,status,row_number);

create table public.accounting_external_account_mappings(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  source_system text not null,
  external_account_code text not null,
  account_id uuid not null,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,source_system,external_account_code),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict
);

create table public.accounting_import_exceptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  batch_id uuid not null references public.accounting_import_batches(id) on delete cascade,
  row_id uuid references public.accounting_import_rows(id) on delete cascade,
  exception_code text not null,
  severity text not null check(severity in ('warning','error')),
  message text not null,
  status text not null default 'pending' check(status in ('pending','resolved')),
  resolution text,
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index accounting_import_exceptions_inbox_idx on public.accounting_import_exceptions(company_id,status,created_at,id);

create table public.accounting_auxiliary_comparisons(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  batch_id uuid not null references public.accounting_import_batches(id) on delete cascade,
  control_key text not null,
  ledger_amount numeric(18,6) not null,
  auxiliary_amount numeric(18,6) not null,
  difference numeric(18,6) generated always as (round(ledger_amount-auxiliary_amount,6)) stored,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(batch_id,control_key)
);

create sequence public.accounting_entry_number_seq;

create or replace function public.accounting_config_is_complete(p_config_id uuid)
returns boolean language sql stable set search_path=public as $$
  select exists(
    select 1 from public.accounting_config_versions c
    where c.id=p_config_id
      and c.catalog_structure ? 'format'
      and c.tax_treatment ?& array['vat_pending','vat_collected','vat_paid','withholdings']
      and c.responsibilities ?& array['adjustments','close','reopen']
      and (select count(*) from public.accounting_control_accounts x where x.config_version_id=c.id)=9
  )
$$;

create or replace function public.canonical_accounting_auxiliaries(p_company_id uuid,p_as_of date)
returns table(control_key text,amount numeric,detail jsonb)
language sql stable security definer set search_path=public as $$
  select 'accounts_receivable',coalesce(sum(r.outstanding_amount),0),jsonb_build_object('documents',count(*),'reconcilable',true)
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 and r.issued_at::date<=p_as_of
  union all
  select 'accounts_payable',coalesce(sum(a.outstanding_amount),0),jsonb_build_object('documents',count(*),'reconcilable',true)
    from public.accounts_payable a where a.company_id=p_company_id and a.outstanding_amount>0 and a.issued_date<=p_as_of
  union all
  select 'inventory',coalesce(sum(b.quantity_on_hand*coalesce(c.amount,0)),0),jsonb_build_object('balances',count(*),'valuation','latest replacement cost at cutoff','missing_cost_balances',count(*) filter(where b.quantity_on_hand>0 and c.amount is null),'reconcilable',count(*) filter(where b.quantity_on_hand>0 and c.amount is null)=0)
    from public.inventory_balances b left join lateral(
      select pc.amount from public.product_costs pc where pc.company_id=b.company_id and pc.product_id=b.product_id
        and pc.cost_type='replacement_cost' and pc.valid_from::date<=p_as_of order by pc.valid_from desc limit 1
    ) c on true where b.company_id=p_company_id
  union all
  select 'cash',coalesce(sum(m.amount),0),jsonb_build_object('movements',count(*),'reconcilable',true)
    from public.cash_movements m where m.company_id=p_company_id and m.created_at::date<=p_as_of
  union all
  select 'banks',0,jsonb_build_object('confirmed_supplier_payment_outflows',coalesce(sum(p.total_amount) filter(where p.status='confirmed'),0),'paying_accounts',(select count(*) from public.supplier_paying_accounts a where a.company_id=p_company_id and a.is_active),'coverage','paying accounts and payment outflows; no canonical bank balance','reconcilable',false)
    from public.supplier_payments p where p.company_id=p_company_id and p.effective_date<=p_as_of
$$;

create or replace function public.save_accounting_config(
  p_company_id uuid,p_base_currency text,p_cutoff_date date,p_catalog_structure jsonb,
  p_tax_treatment jsonb,p_responsibilities jsonb,p_change_reason text,p_control_accounts jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;v_version integer;v_key text;v_account uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para configurar contabilidad.';end if;
  if upper(trim(coalesce(p_base_currency,'')))!~'^[A-Z]{3}$' or p_cutoff_date is null then raise exception 'Moneda base y fecha de corte son obligatorias.';end if;
  if not (coalesce(p_catalog_structure,'{}') ? 'format') then raise exception 'Declara la estructura/formato del catálogo.';end if;
  if not (coalesce(p_tax_treatment,'{}') ?& array['vat_pending','vat_collected','vat_paid','withholdings']) then raise exception 'Declara el tratamiento completo de IVA y retenciones.';end if;
  if not (coalesce(p_responsibilities,'{}') ?& array['adjustments','close','reopen']) then raise exception 'Declara responsables de ajustes, cierre y reapertura.';end if;
  if nullif(trim(coalesce(p_change_reason,'')),'') is null then raise exception 'El motivo de la versión es obligatorio.';end if;
  select coalesce(max(version),0)+1 into v_version from public.accounting_config_versions where company_id=p_company_id;
  insert into public.accounting_config_versions(company_id,version,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason)
  values(p_company_id,v_version,upper(trim(p_base_currency)),p_cutoff_date,p_catalog_structure,p_tax_treatment,p_responsibilities,trim(p_change_reason)) returning * into v_config;
  for v_key,v_account in select key,value::text::uuid from jsonb_each_text(coalesce(p_control_accounts,'{}')) loop
    insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) values(v_config.id,p_company_id,v_key,v_account);
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.config_version_created','accounting_config_version',v_config.id,jsonb_build_object('version',v_version,'cutoff_date',p_cutoff_date));
  return to_jsonb(v_config)||jsonb_build_object('complete',public.accounting_config_is_complete(v_config.id));
end $$;

create or replace function public.approve_accounting_config(p_config_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;
begin
  select * into v_config from public.accounting_config_versions where id=p_config_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_config.company_id,'configure_accounting') then raise exception 'Configuración no disponible.';end if;
  if v_config.status<>'draft' then return to_jsonb(v_config)||jsonb_build_object('idempotent',true);end if;
  if not public.accounting_config_is_complete(v_config.id) then raise exception 'La configuración no está completa: faltan decisiones o cuentas de control.';end if;
  update public.accounting_config_versions set status='superseded' where company_id=v_config.company_id and status='approved';
  update public.accounting_config_versions set status='approved',approved_by=auth.uid(),approved_at=now() where id=v_config.id returning * into v_config;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_config.company_id,auth.uid(),'accounting.config_approved','accounting_config_version',v_config.id,jsonb_build_object('version',v_config.version));
  return to_jsonb(v_config)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.create_accounting_period(p_company_id uuid,p_code text,p_starts_on date,p_ends_on date)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.accounting_periods%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado.';end if;
  insert into public.accounting_periods(company_id,period_code,starts_on,ends_on) values(p_company_id,trim(p_code),p_starts_on,p_ends_on) returning * into v_period;
  return to_jsonb(v_period);
end $$;

create or replace function public.change_accounting_period_status(p_period_id uuid,p_action text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.accounting_periods%rowtype;v_permission text;
begin
  select * into v_period from public.accounting_periods where id=p_period_id for update;
  if not found or auth.uid() is null then raise exception 'Periodo no disponible.';end if;
  v_permission:=case p_action when 'close' then 'close_accounting_periods' when 'reopen' then 'reopen_accounting_periods' else null end;
  if v_permission is null or not public.has_company_permission(v_period.company_id,v_permission) then raise exception 'No autorizado para cambiar el periodo.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_action='close' then
    if v_period.status='closed' then return to_jsonb(v_period)||jsonb_build_object('idempotent',true);end if;
    if exists(select 1 from public.accounting_journal_entries where period_id=v_period.id and status='draft') then raise exception 'Existen pólizas en borrador.';end if;
    update public.accounting_periods set status='closed',closed_by=auth.uid(),closed_at=now(),reopened_by=null,reopened_at=null,reopen_reason=null where id=v_period.id returning * into v_period;
  else
    if v_period.status='open' then return to_jsonb(v_period)||jsonb_build_object('idempotent',true);end if;
    if v_period.closed_by=auth.uid() then raise exception 'La reapertura requiere una persona distinta de quien cerró.';end if;
    update public.accounting_periods set status='open',closed_at=null,reopened_by=auth.uid(),reopened_at=now(),reopen_reason=trim(p_reason) where id=v_period.id returning * into v_period;
  end if;
  insert into public.accounting_period_events(company_id,period_id,action,reason) values(v_period.company_id,v_period.id,case p_action when 'close' then 'closed' else 'reopened' end,trim(p_reason));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_period.company_id,auth.uid(),'accounting.period_'||case p_action when 'close' then 'closed' else 'reopened' end,'accounting_period',v_period.id,jsonb_build_object('reason',trim(p_reason)));
  return to_jsonb(v_period)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.create_accounting_import_batch(p_company_id uuid,p_import_type text,p_cutoff_date date,p_currency_code text,p_original_name text,p_content_sha256 text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_accounting_opening') then raise exception 'No autorizado para importar apertura.';end if;
  select * into v_batch from public.accounting_import_batches where company_id=p_company_id and import_type=p_import_type and content_sha256=lower(p_content_sha256);
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true);end if;
  insert into public.accounting_import_batches(company_id,import_type,cutoff_date,currency_code,original_name,content_sha256)
  values(p_company_id,p_import_type,p_cutoff_date,upper(trim(p_currency_code)),p_original_name,lower(p_content_sha256)) returning * into v_batch;
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.stage_accounting_import_rows(p_batch_id uuid,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;v_count integer;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  if v_batch.status not in ('loading','validation_failed') then raise exception 'El lote ya no admite staging.';end if;
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>5000 then raise exception 'Cada página debe contener entre 1 y 5000 filas.';end if;
  insert into public.accounting_import_rows(batch_id,company_id,row_number,external_account_code,account_name,parent_external_code,account_type,normal_balance,accepts_posting,debit,credit,raw_data)
  select v_batch.id,v_batch.company_id,x.row_number,trim(x.external_account_code),nullif(trim(x.account_name),''),nullif(trim(x.parent_external_code),''),nullif(lower(trim(x.account_type)),''),nullif(lower(trim(x.normal_balance)),''),x.accepts_posting,coalesce(x.debit,0),coalesce(x.credit,0),coalesce(x.raw_data,'{}'::jsonb)
  from jsonb_to_recordset(p_rows) x(row_number integer,external_account_code text,account_name text,parent_external_code text,account_type text,normal_balance text,accepts_posting boolean,debit numeric,credit numeric,raw_data jsonb)
  on conflict(batch_id,row_number) do update set external_account_code=excluded.external_account_code,account_name=excluded.account_name,parent_external_code=excluded.parent_external_code,account_type=excluded.account_type,normal_balance=excluded.normal_balance,accepts_posting=excluded.accepts_posting,debit=excluded.debit,credit=excluded.credit,raw_data=excluded.raw_data,status='pending',issues='[]';
  select count(*) into v_count from public.accounting_import_rows where batch_id=v_batch.id;
  update public.accounting_import_batches set row_count=v_count where id=v_batch.id;
  return jsonb_build_object('batch_id',v_batch.id,'rows_staged',v_count);
end $$;

create or replace function public.validate_accounting_import(p_batch_id uuid,p_source_system text default 'external')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;v_errors integer;v_warnings integer;v_config public.accounting_config_versions%rowtype;v_cmp record;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  delete from public.accounting_import_exceptions where batch_id=v_batch.id;
  delete from public.accounting_auxiliary_comparisons where batch_id=v_batch.id;
  update public.accounting_import_rows r set mapped_account_id=coalesce(
      (select m.account_id from public.accounting_external_account_mappings m where m.company_id=v_batch.company_id and m.source_system=p_source_system and m.external_account_code=r.external_account_code),
      (select a.id from public.accounting_accounts a where a.company_id=v_batch.company_id and a.code=r.external_account_code)
    ),status='valid',issues='[]' where r.batch_id=v_batch.id;
  if v_batch.import_type='chart_of_accounts' then
    update public.accounting_import_rows set status='error',issues=issues||jsonb_build_array(jsonb_build_object('code','INVALID_ACCOUNT','message','Código, nombre, tipo y naturaleza son obligatorios.'))
    where batch_id=v_batch.id and (nullif(external_account_code,'') is null or account_name is null or account_type not in ('asset','liability','equity','revenue','expense','memorandum') or normal_balance not in ('debit','credit'));
    update public.accounting_import_rows r set status='error',issues=issues||jsonb_build_array(jsonb_build_object('code','MISSING_PARENT','message','La cuenta padre no existe en el archivo ni en Satrapy.'))
    where r.batch_id=v_batch.id and r.parent_external_code is not null and not exists(select 1 from public.accounting_import_rows p where p.batch_id=v_batch.id and p.external_account_code=r.parent_external_code) and not exists(select 1 from public.accounting_accounts a where a.company_id=v_batch.company_id and a.code=r.parent_external_code);
  else
    update public.accounting_import_rows set status='error',issues=issues||jsonb_build_array(jsonb_build_object('code','UNMAPPED_ACCOUNT','message','Mapea la cuenta externa a una cuenta canónica.')) where batch_id=v_batch.id and mapped_account_id is null;
    update public.accounting_import_rows set status='error',issues=issues||jsonb_build_array(jsonb_build_object('code','INVALID_BALANCE','message','Débito y crédito no pueden coexistir ni ambos ser cero.')) where batch_id=v_batch.id and ((debit>0 and credit>0) or (debit=0 and credit=0));
    if round((select coalesce(sum(debit-credit),0) from public.accounting_import_rows where batch_id=v_batch.id),6)<>0 then
      insert into public.accounting_import_exceptions(company_id,batch_id,exception_code,severity,message) values(v_batch.company_id,v_batch.id,'UNBALANCED_TRIAL_BALANCE','error','La balanza no cumple doble entrada.');
    end if;
    select * into v_config from public.accounting_config_versions where company_id=v_batch.company_id and status='approved';
    if not found or v_config.cutoff_date<>v_batch.cutoff_date or v_config.base_currency<>v_batch.currency_code then
      insert into public.accounting_import_exceptions(company_id,batch_id,exception_code,severity,message) values(v_batch.company_id,v_batch.id,'CONFIG_MISMATCH','error','No existe configuración aprobada con la misma fecha de corte y moneda.');
    else
      for v_cmp in select a.control_key,a.amount,a.detail,c.account_id from public.canonical_accounting_auxiliaries(v_batch.company_id,v_batch.cutoff_date) a join public.accounting_control_accounts c on c.config_version_id=v_config.id and c.control_key=a.control_key loop
        insert into public.accounting_auxiliary_comparisons(company_id,batch_id,control_key,ledger_amount,auxiliary_amount,detail)
        select v_batch.company_id,v_batch.id,v_cmp.control_key,coalesce(sum(case when r.debit>0 then r.debit else -r.credit end),0),v_cmp.amount,v_cmp.detail from public.accounting_import_rows r where r.batch_id=v_batch.id and r.mapped_account_id=v_cmp.account_id;
      end loop;
      insert into public.accounting_import_exceptions(company_id,batch_id,exception_code,severity,message)
      select v_batch.company_id,v_batch.id,'AUXILIARY_DIFFERENCE','error','Diferencia en '||control_key||': '||difference from public.accounting_auxiliary_comparisons where batch_id=v_batch.id and difference<>0 and coalesce((detail->>'reconcilable')::boolean,true);
      insert into public.accounting_import_exceptions(company_id,batch_id,exception_code,severity,message)
      select v_batch.company_id,v_batch.id,'AUXILIARY_NOT_RECONCILABLE','warning','El auxiliar '||control_key||' no tiene cobertura canónica completa; revisa el detalle antes de promover.' from public.accounting_auxiliary_comparisons where batch_id=v_batch.id and not coalesce((detail->>'reconcilable')::boolean,true);
    end if;
  end if;
  insert into public.accounting_import_exceptions(company_id,batch_id,row_id,exception_code,severity,message)
  select v_batch.company_id,v_batch.id,r.id,i->>'code','error',i->>'message' from public.accounting_import_rows r cross join lateral jsonb_array_elements(r.issues)i where r.batch_id=v_batch.id;
  select count(*) into v_errors from public.accounting_import_exceptions where batch_id=v_batch.id and severity='error' and status='pending';
  select count(*) into v_warnings from public.accounting_import_exceptions where batch_id=v_batch.id and severity='warning' and status='pending';
  update public.accounting_import_batches set status=case when v_errors=0 then 'staged' else 'validation_failed' end,error_count=v_errors,warning_count=v_warnings,summary=jsonb_build_object('debit_total',(select coalesce(sum(debit),0) from public.accounting_import_rows where batch_id=v_batch.id),'credit_total',(select coalesce(sum(credit),0) from public.accounting_import_rows where batch_id=v_batch.id),'auxiliary_comparisons',(select coalesce(jsonb_agg(to_jsonb(c) order by c.control_key),'[]') from public.accounting_auxiliary_comparisons c where c.batch_id=v_batch.id)) where id=v_batch.id returning * into v_batch;
  return to_jsonb(v_batch);
end $$;

create or replace function public.map_accounting_external_account(p_batch_id uuid,p_external_code text,p_account_id uuid,p_source_system text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or not exists(select 1 from public.accounting_accounts where id=p_account_id and company_id=v_batch.company_id) then raise exception 'Cuenta o motivo inválido.';end if;
  insert into public.accounting_external_account_mappings(company_id,source_system,external_account_code,account_id) values(v_batch.company_id,p_source_system,trim(p_external_code),p_account_id)
  on conflict(company_id,source_system,external_account_code) do update set account_id=excluded.account_id,created_by=auth.uid(),created_at=now();
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'accounting.external_account_mapped','accounting_import_batch',v_batch.id,jsonb_build_object('external_code',p_external_code,'account_id',p_account_id,'reason',trim(p_reason)));
  return public.validate_accounting_import(v_batch.id,p_source_system);
end $$;

create or replace function public.post_accounting_adjustment(p_company_id uuid,p_entry_date date,p_description text,p_lines jsonb,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;v_count integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'post_accounting_adjustments') then raise exception 'No autorizado para contabilizar ajustes.';end if;
  if nullif(trim(coalesce(p_description,'')),'') is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<2 or jsonb_array_length(p_lines)>5000 then raise exception 'Descripción y al menos dos partidas son obligatorias.';end if;
  select * into v_entry from public.accounting_journal_entries where company_id=p_company_id and client_request_id=p_client_request_id;
  if found then return to_jsonb(v_entry)||jsonb_build_object('idempotent',true);end if;
  select * into v_period from public.accounting_periods where company_id=p_company_id and p_entry_date between starts_on and ends_on for update;
  if not found or v_period.status<>'open' then raise exception 'La fecha no pertenece a un periodo abierto.';end if;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id)
  values(p_company_id,v_period.id,nextval('public.accounting_entry_number_seq'),p_entry_date,trim(p_description),'manual_adjustment','draft',p_client_request_id) returning * into v_entry;
  insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit)
  select p_company_id,v_entry.id,x.line_number,x.account_id,nullif(trim(x.description),''),coalesce(x.debit,0),coalesce(x.credit,0)
  from jsonb_to_recordset(p_lines)x(line_number integer,account_id uuid,description text,debit numeric,credit numeric);
  select count(*) into v_count from public.accounting_journal_lines where journal_entry_id=v_entry.id;
  if v_count<>jsonb_array_length(p_lines) or round((select coalesce(sum(debit-credit),0) from public.accounting_journal_lines where journal_entry_id=v_entry.id),6)<>0 then raise exception 'El ajuste no cumple doble entrada.';end if;
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),content_sha256=encode(digest((select jsonb_agg(to_jsonb(l) order by line_number)::text from public.accounting_journal_lines l where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id returning * into v_entry;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.adjustment_posted','accounting_journal_entry',v_entry.id,jsonb_build_object('lines',v_count,'content_sha256',v_entry.content_sha256));
  return to_jsonb(v_entry)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.promote_accounting_import(p_batch_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_batch public.accounting_import_batches%rowtype;v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;v_parent uuid;v_line_count integer;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  if v_batch.status='promoted' then return jsonb_build_object('batch_id',v_batch.id,'entry_id',v_batch.promoted_entry_id,'idempotent',true);end if;
  if v_batch.status<>'staged' or exists(select 1 from public.accounting_import_exceptions where batch_id=v_batch.id and severity='error' and status='pending') then raise exception 'La importación conserva excepciones bloqueantes.';end if;
  if v_batch.import_type='chart_of_accounts' then
    insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,level,accepts_posting)
    select v_batch.company_id,r.external_account_code,r.account_name,r.account_type,r.normal_balance,1,coalesce(r.accepts_posting,true) from public.accounting_import_rows r where r.batch_id=v_batch.id
    on conflict(company_id,code) do update set name=excluded.name,account_type=excluded.account_type,normal_balance=excluded.normal_balance,accepts_posting=excluded.accepts_posting,is_active=true;
    update public.accounting_accounts a set parent_id=p.id,level=p.level+1 from public.accounting_import_rows r join public.accounting_accounts p on p.company_id=v_batch.company_id and p.code=r.parent_external_code where a.company_id=v_batch.company_id and a.code=r.external_account_code and r.batch_id=v_batch.id and r.parent_external_code is not null;
    insert into public.accounting_external_account_mappings(company_id,source_system,external_account_code,account_id)
    select v_batch.company_id,'external',a.code,a.id from public.accounting_accounts a join public.accounting_import_rows r on r.batch_id=v_batch.id and r.external_account_code=a.code where a.company_id=v_batch.company_id on conflict do nothing;
    update public.accounting_import_batches set status='promoted',promoted_at=now() where id=v_batch.id;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'accounting.chart_promoted','accounting_import_batch',v_batch.id,jsonb_build_object('rows',v_batch.row_count));
    return jsonb_build_object('batch_id',v_batch.id,'accounts_promoted',v_batch.row_count,'idempotent',false);
  end if;
  select * into v_period from public.accounting_periods where company_id=v_batch.company_id and v_batch.cutoff_date between starts_on and ends_on for update;
  if not found or v_period.status<>'open' then raise exception 'La fecha de corte no pertenece a un periodo abierto.';end if;
  select * into v_entry from public.accounting_journal_entries where company_id=v_batch.company_id and client_request_id=p_client_request_id;
  if found then return jsonb_build_object('batch_id',v_batch.id,'entry_id',v_entry.id,'idempotent',true);end if;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,immutable,source_batch_id,client_request_id)
  values(v_batch.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),v_batch.cutoff_date,'Póliza de apertura','opening','draft',false,v_batch.id,p_client_request_id) returning * into v_entry;
  insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit,external_account_code)
  select v_batch.company_id,v_entry.id,r.row_number,r.mapped_account_id,r.account_name,r.debit,r.credit,r.external_account_code from public.accounting_import_rows r where r.batch_id=v_batch.id order by r.row_number;
  select count(*) into v_line_count from public.accounting_journal_lines where journal_entry_id=v_entry.id;
  if v_line_count<2 or round((select sum(debit-credit) from public.accounting_journal_lines where journal_entry_id=v_entry.id),6)<>0 then raise exception 'La póliza de apertura no cumple doble entrada.';end if;
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),content_sha256=encode(digest((select jsonb_agg(to_jsonb(l) order by line_number)::text from public.accounting_journal_lines l where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id returning * into v_entry;
  update public.accounting_import_batches set status='promoted',promoted_entry_id=v_entry.id,promoted_at=now() where id=v_batch.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'accounting.opening_posted','accounting_journal_entry',v_entry.id,jsonb_build_object('batch_id',v_batch.id,'lines',v_line_count,'content_sha256',v_entry.content_sha256));
  return jsonb_build_object('batch_id',v_batch.id,'entry_id',v_entry.id,'lines',v_line_count,'idempotent',false);
end $$;

create or replace function public.guard_accounting_immutable_mutation()
returns trigger language plpgsql set search_path=public as $$
declare v_entry public.accounting_journal_entries%rowtype;v_period_status text;
begin
  if tg_table_name='accounting_journal_entries' then v_entry:=old; else select * into v_entry from public.accounting_journal_entries where id=coalesce(new.journal_entry_id,old.journal_entry_id);end if;
  select status into v_period_status from public.accounting_periods where id=v_entry.period_id;
  if v_entry.immutable or v_entry.status in ('posted','reversed') or v_period_status='closed' then raise exception 'La póliza contabilizada, de apertura o de periodo cerrado es inmutable.';end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger accounting_journal_entries_guard before update or delete on public.accounting_journal_entries for each row execute function public.guard_accounting_immutable_mutation();
create trigger accounting_journal_lines_guard before insert or update or delete on public.accounting_journal_lines for each row execute function public.guard_accounting_immutable_mutation();

alter table public.accounting_config_versions enable row level security;
alter table public.accounting_accounts enable row level security;
alter table public.accounting_control_accounts enable row level security;
alter table public.accounting_periods enable row level security;
alter table public.accounting_journal_entries enable row level security;
alter table public.accounting_journal_lines enable row level security;
alter table public.accounting_period_events enable row level security;
alter table public.accounting_import_batches enable row level security;
alter table public.accounting_import_rows enable row level security;
alter table public.accounting_external_account_mappings enable row level security;
alter table public.accounting_import_exceptions enable row level security;
alter table public.accounting_auxiliary_comparisons enable row level security;

create policy accounting_config_read on public.accounting_config_versions for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_accounts_read on public.accounting_accounts for select to authenticated using(public.has_company_permission(company_id,'view_accounting') or public.has_company_permission(company_id,'import_accounting_opening'));
create policy accounting_controls_read on public.accounting_control_accounts for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_periods_read on public.accounting_periods for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_entries_read on public.accounting_journal_entries for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_lines_read on public.accounting_journal_lines for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_period_events_read on public.accounting_period_events for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_batches_read on public.accounting_import_batches for select to authenticated using(public.has_company_permission(company_id,'import_accounting_opening') or public.has_company_permission(company_id,'view_accounting'));
create policy accounting_rows_read on public.accounting_import_rows for select to authenticated using(public.has_company_permission(company_id,'import_accounting_opening'));
create policy accounting_mappings_read on public.accounting_external_account_mappings for select to authenticated using(public.has_company_permission(company_id,'import_accounting_opening'));
create policy accounting_exceptions_read on public.accounting_import_exceptions for select to authenticated using(public.has_company_permission(company_id,'import_accounting_opening'));
create policy accounting_comparisons_read on public.accounting_auxiliary_comparisons for select to authenticated using(public.has_company_permission(company_id,'import_accounting_opening') or public.has_company_permission(company_id,'view_accounting'));

revoke all on public.accounting_config_versions,public.accounting_accounts,public.accounting_control_accounts,
  public.accounting_periods,public.accounting_journal_entries,public.accounting_journal_lines,public.accounting_period_events,
  public.accounting_import_batches,public.accounting_import_rows,public.accounting_external_account_mappings,
  public.accounting_import_exceptions,public.accounting_auxiliary_comparisons from anon,authenticated;
grant select on public.accounting_config_versions,public.accounting_accounts,public.accounting_control_accounts,
  public.accounting_periods,public.accounting_journal_entries,public.accounting_journal_lines,public.accounting_period_events,
  public.accounting_import_batches,public.accounting_import_rows,public.accounting_external_account_mappings,
  public.accounting_import_exceptions,public.accounting_auxiliary_comparisons to authenticated;
revoke all on function public.save_accounting_config(uuid,text,date,jsonb,jsonb,jsonb,text,jsonb),public.approve_accounting_config(uuid),
  public.create_accounting_period(uuid,text,date,date),public.change_accounting_period_status(uuid,text,text),
  public.create_accounting_import_batch(uuid,text,date,text,text,text),public.stage_accounting_import_rows(uuid,jsonb),
  public.validate_accounting_import(uuid,text),public.map_accounting_external_account(uuid,text,uuid,text,text),
  public.post_accounting_adjustment(uuid,date,text,jsonb,uuid),public.promote_accounting_import(uuid,uuid) from public,anon;
grant execute on function public.save_accounting_config(uuid,text,date,jsonb,jsonb,jsonb,text,jsonb),public.approve_accounting_config(uuid),
  public.create_accounting_period(uuid,text,date,date),public.change_accounting_period_status(uuid,text,text),
  public.create_accounting_import_batch(uuid,text,date,text,text,text),public.stage_accounting_import_rows(uuid,jsonb),
  public.validate_accounting_import(uuid,text),public.map_accounting_external_account(uuid,text,uuid,text,text),
  public.post_accounting_adjustment(uuid,date,text,jsonb,uuid),public.promote_accounting_import(uuid,uuid) to authenticated;
