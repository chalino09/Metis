-- Satrapy · Alpha customer and receivables migration.
-- Alpha remains at the import boundary. No historic sale or payment is invented.

alter table public.customers
  add column if not exists alpha_external_code text,
  add column if not exists alpha_source_row_hash text,
  add column if not exists address_line text,
  add column if not exists neighborhood text,
  add column if not exists municipality text,
  add column if not exists state_name text,
  add column if not exists postal_code text,
  add column if not exists contact_name text,
  add column if not exists bank_reference text,
  add column if not exists payment_manager text,
  add column if not exists sales_agent text,
  add column if not exists migration_status text not null default 'manual';

alter table public.customers drop constraint if exists customers_migration_status_check;
alter table public.customers add constraint customers_migration_status_check
  check (migration_status in ('manual', 'promoted', 'adjustment_pending'));
create unique index if not exists customers_alpha_external_code_key
  on public.customers(company_id, alpha_external_code) where alpha_external_code is not null;

alter table public.customer_receivables
  alter column sale_id drop not null,
  add column if not exists source_kind text not null default 'sale',
  add column if not exists source_document_key text,
  add column if not exists source_row_hash text,
  add column if not exists source_reference text,
  add column if not exists source_cutoff_date date;

alter table public.customer_receivables drop constraint if exists customer_receivables_source_kind_check;
alter table public.customer_receivables add constraint customer_receivables_source_kind_check
  check (source_kind in ('sale', 'alpha_document', 'alpha_opening_balance'));
alter table public.customer_receivables drop constraint if exists customer_receivables_source_shape_check;
alter table public.customer_receivables add constraint customer_receivables_source_shape_check
  check (
    (source_kind = 'sale' and sale_id is not null and source_document_key is null)
    or (source_kind = 'alpha_document' and sale_id is null and source_document_key is not null and source_row_hash is not null and source_cutoff_date is not null)
    or (source_kind = 'alpha_opening_balance' and sale_id is null and source_document_key is not null and source_row_hash is not null and source_cutoff_date is not null)
  );
create unique index if not exists customer_receivables_alpha_document_key
  on public.customer_receivables(company_id, source_document_key)
  where source_kind in ('alpha_document', 'alpha_opening_balance');

-- A receivable document remains immutable after promotion. Only its outstanding
-- balance may move through a recorded payment or an approved migration adjustment.
create or replace function public.prevent_receivable_document_mutation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'El documento por cobrar es inmutable; solo su saldo puede cambiar mediante un abono o ajuste aprobado.';
  end if;
  if new.company_id is distinct from old.company_id
    or new.customer_id is distinct from old.customer_id
    or new.sale_id is distinct from old.sale_id
    or new.issued_at is distinct from old.issued_at
    or new.due_date is distinct from old.due_date
    or new.original_amount is distinct from old.original_amount
    or new.source_kind is distinct from old.source_kind
    or new.source_document_key is distinct from old.source_document_key
    or new.source_row_hash is distinct from old.source_row_hash
    or new.source_reference is distinct from old.source_reference
    or new.source_cutoff_date is distinct from old.source_cutoff_date
    or new.created_at is distinct from old.created_at then
    raise exception 'El documento por cobrar es inmutable; solo su saldo puede cambiar mediante un abono o ajuste aprobado.';
  end if;
  return new;
end $$;

create table if not exists public.alpha_customer_migration_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cutoff_date date not null,
  content_sha256 text not null,
  status text not null default 'loading' check (status in ('loading','staged','reconciling','ready_to_promote','promoting','completed','completed_with_discrepancies','failed')),
  records_received integer not null default 0,
  records_promoted integer not null default 0,
  imported_by uuid not null references auth.users(id) on delete restrict,
  completed_at timestamptz,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, content_sha256)
);

create table if not exists public.alpha_customer_migration_files (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  report_type text not null check (report_type in ('customers','credit_terms','ledger','collections')),
  original_name text not null,
  file_sha256 text not null,
  logical_sha256 text,
  snapshot_date date not null,
  duplicate_group text,
  row_count integer not null default 0,
  created_at timestamptz not null default now(),
  unique (batch_id, original_name)
);

create table if not exists public.alpha_customer_migration_customers (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  external_code text not null,
  display_name text not null,
  tax_id text,
  address_line text,
  neighborhood text,
  municipality text,
  state_name text,
  postal_code text,
  phone text,
  contact_name text,
  bank_reference text,
  commercial_name text,
  commercial_type text,
  credit_limit numeric(18,2),
  credit_term_days integer,
  payment_manager text,
  sales_agent text,
  catalog_present boolean not null default true,
  terms_present boolean not null default false,
  source_row_hash text not null,
  reported_open_amount numeric(18,2) not null default 0,
  opening_balance_amount numeric(18,2),
  opening_balance_source_hash text,
  opening_balance_reference text,
  document_mode text not null default 'none' check (document_mode in ('none','documents','opening_balance')),
  status text not null default 'staged' check (status in ('staged','reconciled','discrepancy','promoted')),
  discrepancy jsonb not null default '[]'::jsonb,
  promoted_customer_id uuid references public.customers(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, external_code)
);

create table if not exists public.alpha_customer_migration_documents (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  customer_external_code text not null,
  source_code text not null,
  folio text not null,
  document_date date not null,
  currency_code text not null check (length(currency_code) = 3),
  original_amount numeric(18,2) not null check (original_amount >= 0),
  outstanding_amount numeric(18,2) not null check (outstanding_amount >= 0),
  source_row_hash text not null,
  source_document_key text not null,
  raw_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (batch_id, source_row_hash)
);
create index if not exists alpha_customer_migration_documents_key_idx
  on public.alpha_customer_migration_documents(batch_id, customer_external_code, source_document_key);

create table if not exists public.alpha_customer_migration_collections (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  customer_external_code text not null,
  payment_subtype text,
  folio text,
  branch_code text,
  issued_date date,
  applied_date date,
  due_date date,
  document_type text,
  reference text,
  amount numeric(18,2),
  currency_code text,
  account_number text,
  source_row_hash text not null,
  raw_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (batch_id, source_row_hash)
);

create table if not exists public.alpha_customer_migration_differences (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  customer_external_code text,
  severity text not null check (severity in ('error','warning')),
  difference_code text not null,
  message text not null,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists alpha_customer_migration_differences_batch_idx
  on public.alpha_customer_migration_differences(batch_id, severity, customer_external_code);

create table if not exists public.alpha_customer_migration_adjustments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  receivable_id uuid references public.customer_receivables(id) on delete restrict,
  field_name text not null check (field_name in ('display_name','tax_id','phone','address_line','contact_name','bank_reference','credit_limit','credit_term_days','outstanding_amount')),
  previous_value jsonb not null,
  proposed_value jsonb not null,
  reason text not null check (length(trim(reason)) > 0),
  evidence text not null check (length(trim(evidence)) > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid not null references auth.users(id) on delete restrict,
  requested_at timestamptz not null default now(),
  decided_by uuid references auth.users(id) on delete restrict,
  decided_at timestamptz,
  decision_reason text
);
create index if not exists alpha_customer_migration_adjustments_pending_idx
  on public.alpha_customer_migration_adjustments(company_id, status, customer_id);

create or replace function public.alpha_customer_migration_touch()
returns trigger language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists alpha_customer_migration_batches_touch on public.alpha_customer_migration_batches;
create trigger alpha_customer_migration_batches_touch before update on public.alpha_customer_migration_batches for each row execute function public.alpha_customer_migration_touch();
drop trigger if exists alpha_customer_migration_customers_touch on public.alpha_customer_migration_customers;
create trigger alpha_customer_migration_customers_touch before update on public.alpha_customer_migration_customers for each row execute function public.alpha_customer_migration_touch();

alter table public.alpha_customer_migration_batches enable row level security;
alter table public.alpha_customer_migration_files enable row level security;
alter table public.alpha_customer_migration_customers enable row level security;
alter table public.alpha_customer_migration_documents enable row level security;
alter table public.alpha_customer_migration_collections enable row level security;
alter table public.alpha_customer_migration_differences enable row level security;
alter table public.alpha_customer_migration_adjustments enable row level security;

create policy alpha_customer_batches_read on public.alpha_customer_migration_batches for select to authenticated using (public.has_company_permission(company_id, 'import_data') or public.has_company_permission(company_id, 'view_import_audit'));
create policy alpha_customer_files_read on public.alpha_customer_migration_files for select to authenticated using (exists (select 1 from public.alpha_customer_migration_batches b where b.id = batch_id and (public.has_company_permission(b.company_id, 'import_data') or public.has_company_permission(b.company_id, 'view_import_audit'))));
create policy alpha_customer_staging_read on public.alpha_customer_migration_customers for select to authenticated using (exists (select 1 from public.alpha_customer_migration_batches b where b.id = batch_id and (public.has_company_permission(b.company_id, 'import_data') or public.has_company_permission(b.company_id, 'view_import_audit'))));
create policy alpha_customer_documents_read on public.alpha_customer_migration_documents for select to authenticated using (exists (select 1 from public.alpha_customer_migration_batches b where b.id = batch_id and (public.has_company_permission(b.company_id, 'import_data') or public.has_company_permission(b.company_id, 'view_import_audit'))));
create policy alpha_customer_collections_read on public.alpha_customer_migration_collections for select to authenticated using (exists (select 1 from public.alpha_customer_migration_batches b where b.id = batch_id and (public.has_company_permission(b.company_id, 'import_data') or public.has_company_permission(b.company_id, 'view_import_audit'))));
create policy alpha_customer_differences_read on public.alpha_customer_migration_differences for select to authenticated using (exists (select 1 from public.alpha_customer_migration_batches b where b.id = batch_id and (public.has_company_permission(b.company_id, 'import_data') or public.has_company_permission(b.company_id, 'view_import_audit'))));
create policy alpha_customer_adjustments_read on public.alpha_customer_migration_adjustments for select to authenticated using (public.has_company_permission(company_id, 'import_data') or public.has_company_permission(company_id, 'view_import_audit'));

create or replace function public.begin_alpha_customer_migration(
  p_company_id uuid, p_cutoff_date date, p_content_sha256 text, p_files jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch_id uuid; v_existing uuid; v_required text[] := array['customers','credit_terms','ledger','collections'];
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'import_data') then raise exception 'No autorizado para preparar migraciones de clientes.'; end if;
  if p_cutoff_date is null or nullif(trim(coalesce(p_content_sha256, '')), '') is null then raise exception 'La fecha de corte y la huella de contenido son obligatorias.'; end if;
  if exists (select 1 from jsonb_to_recordset(coalesce(p_files, '[]'::jsonb)) f(report_type text, snapshot_date date) where f.snapshot_date is distinct from p_cutoff_date) then raise exception 'Todos los archivos deben tener la misma fecha de corte.'; end if;
  if exists (select 1 from unnest(v_required) required where not exists (select 1 from jsonb_to_recordset(coalesce(p_files, '[]'::jsonb)) f(report_type text) where f.report_type = required)) then raise exception 'Faltan archivos requeridos de Clientes/CxC.'; end if;
  select id into v_existing from public.alpha_customer_migration_batches where company_id = p_company_id and content_sha256 = p_content_sha256 limit 1;
  if v_existing is not null then return jsonb_build_object('status','duplicate','batch_id',v_existing); end if;
  insert into public.alpha_customer_migration_batches(company_id, cutoff_date, content_sha256, imported_by) values(p_company_id,p_cutoff_date,p_content_sha256,auth.uid()) returning id into v_batch_id;
  insert into public.alpha_customer_migration_files(batch_id, report_type, original_name, file_sha256, logical_sha256, snapshot_date, duplicate_group, row_count)
  select v_batch_id, f.report_type, f.original_name, f.file_sha256, nullif(f.logical_sha256,''), f.snapshot_date, nullif(f.duplicate_group,''), coalesce(f.row_count,0)
  from jsonb_to_recordset(coalesce(p_files,'[]'::jsonb)) f(report_type text, original_name text, file_sha256 text, logical_sha256 text, snapshot_date date, duplicate_group text, row_count integer);
  return jsonb_build_object('status','loading','batch_id',v_batch_id);
end $$;

create or replace function public.stage_alpha_customer_migration_rows(p_batch_id uuid, p_kind text, p_rows jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_count integer := 0;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para cargar staging de clientes.'; end if;
  if v_batch.status <> 'loading' then raise exception 'El lote ya no acepta filas.'; end if;
  if p_kind = 'customers' then
    insert into public.alpha_customer_migration_customers(batch_id,external_code,display_name,tax_id,address_line,neighborhood,municipality,state_name,postal_code,phone,contact_name,bank_reference,commercial_name,commercial_type,credit_limit,credit_term_days,payment_manager,sales_agent,catalog_present,terms_present,source_row_hash)
    select p_batch_id, trim(r.external_code), trim(r.display_name), nullif(trim(r.tax_id),''), nullif(trim(r.address_line),''), nullif(trim(r.neighborhood),''), nullif(trim(r.municipality),''), nullif(trim(r.state_name),''), nullif(trim(r.postal_code),''), nullif(trim(r.phone),''), nullif(trim(r.contact_name),''), nullif(trim(r.bank_reference),''), nullif(trim(r.commercial_name),''), nullif(trim(r.commercial_type),''), r.credit_limit, r.credit_term_days, nullif(trim(r.payment_manager),''), nullif(trim(r.sales_agent),''), coalesce(r.catalog_present,true), coalesce(r.terms_present,false), trim(r.source_row_hash)
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) r(external_code text,display_name text,tax_id text,address_line text,neighborhood text,municipality text,state_name text,postal_code text,phone text,contact_name text,bank_reference text,commercial_name text,commercial_type text,credit_limit numeric,credit_term_days integer,payment_manager text,sales_agent text,catalog_present boolean,terms_present boolean,source_row_hash text)
    on conflict (batch_id,external_code) do update set display_name=excluded.display_name,tax_id=excluded.tax_id,address_line=excluded.address_line,neighborhood=excluded.neighborhood,municipality=excluded.municipality,state_name=excluded.state_name,postal_code=excluded.postal_code,phone=excluded.phone,contact_name=excluded.contact_name,bank_reference=excluded.bank_reference,commercial_name=excluded.commercial_name,commercial_type=excluded.commercial_type,credit_limit=excluded.credit_limit,credit_term_days=excluded.credit_term_days,payment_manager=excluded.payment_manager,sales_agent=excluded.sales_agent,catalog_present=excluded.catalog_present,terms_present=excluded.terms_present,source_row_hash=excluded.source_row_hash;
  elsif p_kind = 'documents' then
    insert into public.alpha_customer_migration_documents(batch_id,customer_external_code,source_code,folio,document_date,currency_code,original_amount,outstanding_amount,source_row_hash,source_document_key,raw_data)
    select p_batch_id,trim(r.customer_external_code),trim(r.source_code),trim(r.folio),r.document_date,upper(trim(r.currency_code)),round(r.original_amount,2),round(r.outstanding_amount,2),trim(r.source_row_hash),encode(digest(concat_ws('|',trim(r.customer_external_code),trim(r.source_code),trim(r.folio),r.document_date::text,upper(trim(r.currency_code)),(round(r.original_amount,2) * 100)::bigint::text),'sha256'),'hex'),coalesce(r.raw_data,'{}'::jsonb)
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) r(customer_external_code text,source_code text,folio text,document_date date,currency_code text,original_amount numeric,outstanding_amount numeric,source_row_hash text,raw_data jsonb)
    on conflict (batch_id,source_row_hash) do nothing;
  elsif p_kind = 'collections' then
    insert into public.alpha_customer_migration_collections(batch_id,customer_external_code,payment_subtype,folio,branch_code,issued_date,applied_date,due_date,document_type,reference,amount,currency_code,account_number,source_row_hash,raw_data)
    select p_batch_id,trim(r.customer_external_code),nullif(trim(r.payment_subtype),''),nullif(trim(r.folio),''),nullif(trim(r.branch_code),''),r.issued_date,r.applied_date,r.due_date,nullif(trim(r.document_type),''),nullif(trim(r.reference),''),r.amount,nullif(upper(trim(r.currency_code)),''),nullif(trim(r.account_number),''),trim(r.source_row_hash),coalesce(r.raw_data,'{}'::jsonb)
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) r(customer_external_code text,payment_subtype text,folio text,branch_code text,issued_date date,applied_date date,due_date date,document_type text,reference text,amount numeric,currency_code text,account_number text,source_row_hash text,raw_data jsonb)
    on conflict (batch_id,source_row_hash) do nothing;
  else raise exception 'Tipo de fila de migración inválido.'; end if;
  get diagnostics v_count = row_count;
  update public.alpha_customer_migration_batches set records_received = records_received + v_count where id=p_batch_id;
  return v_count;
end $$;

-- Exceptional, low-volume path for one customer whose lis_sal history cannot be
-- represented document by document. It records a sourced opening balance, never a payment.
create or replace function public.declare_alpha_customer_opening_balance(
  p_batch_id uuid, p_external_code text, p_amount numeric, p_source_row_hash text, p_source_reference text
) returns void language plpgsql security definer set search_path = public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para declarar saldo de apertura Alpha.';
  end if;
  if v_batch.status <> 'loading' then raise exception 'El saldo de apertura se declara antes de conciliar el lote.'; end if;
  if round(coalesce(p_amount,0),2) <= 0 or nullif(trim(coalesce(p_source_row_hash,'')),'') is null or nullif(trim(coalesce(p_source_reference,'')),'') is null then
    raise exception 'El saldo de apertura requiere importe positivo, huella de fuente y referencia.';
  end if;
  update public.alpha_customer_migration_customers
    set opening_balance_amount=round(p_amount,2), opening_balance_source_hash=trim(p_source_row_hash), opening_balance_reference=trim(p_source_reference)
    where batch_id=p_batch_id and external_code=trim(p_external_code);
  if not found then raise exception 'Cliente no encontrado en staging.'; end if;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.opening_balance_declared','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('customer_external_code',trim(p_external_code),'amount',round(p_amount,2),'source_reference',trim(p_source_reference)));
end $$;

create or replace function public.reconcile_alpha_customer_migration(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_errors integer; v_reconciled integer; v_source_total numeric; v_reconciled_total numeric;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para conciliar clientes.'; end if;
  if v_batch.status <> 'loading' then raise exception 'El lote no está disponible para conciliación.'; end if;
  update public.alpha_customer_migration_batches set status='reconciling' where id=p_batch_id;
  delete from public.alpha_customer_migration_differences where batch_id=p_batch_id;
  update public.alpha_customer_migration_customers set status='staged', discrepancy='[]'::jsonb, reported_open_amount=0, document_mode='none' where batch_id=p_batch_id;

  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  select p_batch_id,c.external_code,'error','TERMS_MISSING','El cliente no tiene condiciones comerciales en cat_ctee.' from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and not c.terms_present;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  select p_batch_id,c.external_code,'error','CATALOG_CUSTOMER_MISSING','Las condiciones comerciales no tienen cliente en cata_cte.' from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and not c.catalog_present;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message,evidence)
  select p_batch_id,c.external_code,'error','CUSTOMER_NAME_MISMATCH','El nombre del catálogo y las condiciones comerciales no coincide.',jsonb_build_object('catalog_name',c.display_name,'commercial_name',c.commercial_name)
  from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and c.terms_present and lower(regexp_replace(c.display_name,'\\s+',' ','g')) <> lower(regexp_replace(coalesce(c.commercial_name,''),'\\s+',' ','g'));
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  select p_batch_id,d.customer_external_code,'error','DOCUMENT_CUSTOMER_MISSING','Un documento de lis_sal no tiene cliente en cata_cte.' from public.alpha_customer_migration_documents d left join public.alpha_customer_migration_customers c on c.batch_id=d.batch_id and c.external_code=d.customer_external_code where d.batch_id=p_batch_id and c.id is null group by d.customer_external_code;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message,evidence)
  select p_batch_id,d.customer_external_code,'error','DOCUMENT_KEY_HASH_CONFLICT','La misma clave documental tiene más de una fila fuente; no se puede promover ni sustituir silenciosamente.',jsonb_build_object('document_key',d.source_document_key,'rows',count(*))
  from public.alpha_customer_migration_documents d where d.batch_id=p_batch_id group by d.customer_external_code,d.source_document_key having count(*) > 1;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message,evidence)
  select p_batch_id,d.customer_external_code,'error','DOCUMENT_BALANCE_EXCEEDS_ORIGINAL','El saldo abierto de un documento excede su cargo original; la diferencia, incluso de $0.01, bloquea la conciliación.',jsonb_build_object('folio',d.folio,'original_amount',d.original_amount,'outstanding_amount',d.outstanding_amount)
  from public.alpha_customer_migration_documents d where d.batch_id=p_batch_id and (round(d.outstanding_amount,2) * 100)::bigint > (round(d.original_amount,2) * 100)::bigint;
  insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message)
  select p_batch_id,e.customer_external_code,'warning','COLLECTION_CUSTOMER_NOT_IN_CATALOG','Cobranza sin cliente de catálogo; se conserva como evidencia y no genera abono.' from public.alpha_customer_migration_collections e left join public.alpha_customer_migration_customers c on c.batch_id=e.batch_id and c.external_code=e.customer_external_code where e.batch_id=p_batch_id and c.id is null group by e.customer_external_code;

  update public.alpha_customer_migration_customers c set
    reported_open_amount = coalesce((select round(sum(d.outstanding_amount),2) from public.alpha_customer_migration_documents d where d.batch_id=c.batch_id and d.customer_external_code=c.external_code),c.opening_balance_amount,0),
    document_mode = case when exists (select 1 from public.alpha_customer_migration_documents d where d.batch_id=c.batch_id and d.customer_external_code=c.external_code) then 'documents' when c.opening_balance_amount > 0 then 'opening_balance' else 'none' end
  where c.batch_id=p_batch_id;
  update public.alpha_customer_migration_customers c set status=case when exists (select 1 from public.alpha_customer_migration_differences x where x.batch_id=c.batch_id and x.customer_external_code=c.external_code and x.severity='error') then 'discrepancy' else 'reconciled' end,
    discrepancy=coalesce((select jsonb_agg(jsonb_build_object('code',x.difference_code,'message',x.message,'severity',x.severity)) from public.alpha_customer_migration_differences x where x.batch_id=c.batch_id and x.customer_external_code=c.external_code), '[]'::jsonb)
  where c.batch_id=p_batch_id;
  select count(*) filter(where status='discrepancy'),count(*) filter(where status='reconciled') into v_errors,v_reconciled from public.alpha_customer_migration_customers where batch_id=p_batch_id;
  select (coalesce((select sum((round(outstanding_amount,2) * 100)::bigint) from public.alpha_customer_migration_documents where batch_id=p_batch_id),0) + coalesce((select sum((round(c.opening_balance_amount,2) * 100)::bigint) from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and not exists (select 1 from public.alpha_customer_migration_documents d where d.batch_id=p_batch_id and d.customer_external_code=c.external_code)),0))::numeric / 100 into v_source_total;
  select coalesce(sum((round(reported_open_amount,2) * 100)::bigint),0)::numeric / 100 into v_reconciled_total from public.alpha_customer_migration_customers where batch_id=p_batch_id and status='reconciled';
  if (v_source_total * 100)::bigint <> (
    (v_reconciled_total * 100)::bigint + coalesce((select sum((round(c.reported_open_amount,2) * 100)::bigint) from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and c.status='discrepancy'),0)
  ) then raise exception 'La conciliación global no cuadra a centavos (tolerancia $0.00 MXN).'; end if;
  update public.alpha_customer_migration_batches set status='ready_to_promote', summary=jsonb_build_object('reconciled_customers',v_reconciled,'customers_with_differences',v_errors,'source_open_total',v_source_total,'tolerance_mxn',0) where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.reconciled','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('reconciled_customers',v_reconciled,'customers_with_differences',v_errors,'source_open_total',v_source_total));
  return jsonb_build_object('batch_id',p_batch_id,'status','ready_to_promote','reconciled_customers',v_reconciled,'customers_with_differences',v_errors,'source_open_total',v_source_total,'tolerance_mxn',0);
end $$;

create or replace function public.promote_alpha_customer_migration(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_stage public.alpha_customer_migration_customers%rowtype; v_customer public.customers%rowtype; v_doc record; v_customer_id uuid; v_promoted integer:=0; v_blocked integer:=0; v_opening_key text;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para promover clientes.'; end if;
  if v_batch.status <> 'ready_to_promote' then raise exception 'El lote debe conciliarse antes de promoverse.'; end if;
  update public.alpha_customer_migration_batches set status='promoting' where id=p_batch_id;
  for v_stage in select * from public.alpha_customer_migration_customers where batch_id=p_batch_id and status='reconciled' order by external_code for update loop
    begin
      select * into v_customer from public.customers where company_id=v_batch.company_id and code=v_stage.external_code for update;
      if found then
        if v_customer.alpha_external_code is distinct from v_stage.external_code or v_customer.alpha_source_row_hash is distinct from v_stage.source_row_hash then raise exception 'Existe un cliente con la misma clave que no coincide con la fuente Alpha.'; end if;
        v_customer_id := v_customer.id;
      else
        insert into public.customers(company_id,code,display_name,tax_id,phone,credit_enabled,credit_limit,credit_term_days,is_active,created_by,alpha_external_code,alpha_source_row_hash,address_line,neighborhood,municipality,state_name,postal_code,contact_name,bank_reference,payment_manager,sales_agent,migration_status)
        values(v_batch.company_id,v_stage.external_code,v_stage.display_name,v_stage.tax_id,v_stage.phone,lower(coalesce(v_stage.commercial_type,'')) in ('credito','crédito'),coalesce(v_stage.credit_limit,0),coalesce(v_stage.credit_term_days,0),true,auth.uid(),v_stage.external_code,v_stage.source_row_hash,v_stage.address_line,v_stage.neighborhood,v_stage.municipality,v_stage.state_name,v_stage.postal_code,v_stage.contact_name,v_stage.bank_reference,v_stage.payment_manager,v_stage.sales_agent,'promoted') returning id into v_customer_id;
      end if;
      if v_stage.document_mode='documents' then
        for v_doc in select * from public.alpha_customer_migration_documents where batch_id=p_batch_id and customer_external_code=v_stage.external_code and outstanding_amount > 0 order by document_date,folio loop
          if exists (select 1 from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_document_key=v_doc.source_document_key and r.source_row_hash is distinct from v_doc.source_row_hash) then raise exception 'La clave de documento ya existe con una huella distinta.'; end if;
          insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
          values(v_batch.company_id,v_customer_id,null,v_doc.document_date,v_doc.document_date,v_doc.original_amount,v_doc.outstanding_amount,'alpha_document',v_doc.source_document_key,v_doc.source_row_hash,v_doc.folio,v_batch.cutoff_date)
          on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
        end loop;
      elsif v_stage.document_mode='opening_balance' and v_stage.reported_open_amount > 0 then
        v_opening_key := encode(digest(concat_ws('|','alpha_opening_balance',v_stage.external_code,v_batch.cutoff_date::text,v_stage.reported_open_amount::text),'sha256'),'hex');
        insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
        values(v_batch.company_id,v_customer_id,null,v_batch.cutoff_date,v_batch.cutoff_date,v_stage.reported_open_amount,v_stage.reported_open_amount,'alpha_opening_balance',v_opening_key,v_stage.opening_balance_source_hash,v_stage.opening_balance_reference,v_batch.cutoff_date)
        on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
      end if;
      update public.alpha_customer_migration_customers set status='promoted',promoted_customer_id=v_customer_id where id=v_stage.id;
      v_promoted:=v_promoted+1;
    exception when others then
      update public.alpha_customer_migration_customers set status='discrepancy',discrepancy=discrepancy || jsonb_build_array(jsonb_build_object('code','PROMOTION_FAILED','message',sqlerrm,'severity','error')) where id=v_stage.id;
      insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message) values(p_batch_id,v_stage.external_code,'error','PROMOTION_FAILED',sqlerrm);
      v_blocked:=v_blocked+1;
    end;
  end loop;
  select count(*) filter(where status='discrepancy') into v_blocked from public.alpha_customer_migration_customers where batch_id=p_batch_id;
  if v_promoted=0 and v_blocked>0 then update public.alpha_customer_migration_batches set status='failed',completed_at=now(),summary=summary || jsonb_build_object('promoted_customers',0,'blocked_customers',v_blocked) where id=p_batch_id;
  else update public.alpha_customer_migration_batches set status=case when v_blocked>0 then 'completed_with_discrepancies' else 'completed' end,records_promoted=v_promoted,completed_at=now(),summary=summary || jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked) where id=p_batch_id; end if;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.promoted','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked));
  return jsonb_build_object('batch_id',p_batch_id,'status',(select status from public.alpha_customer_migration_batches where id=p_batch_id),'promoted_customers',v_promoted,'blocked_customers',v_blocked);
end $$;

create or replace function public.request_alpha_customer_migration_adjustment(p_company_id uuid,p_customer_id uuid,p_receivable_id uuid,p_field_name text,p_proposed_value jsonb,p_reason text,p_evidence text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_customer public.customers%rowtype; v_previous jsonb; v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_data') then raise exception 'No autorizado para solicitar ajustes de migración.'; end if;
  select * into v_customer from public.customers where id=p_customer_id and company_id=p_company_id for update;
  if not found or v_customer.alpha_external_code is null then raise exception 'El ajuste aplica únicamente a clientes promovidos desde Alpha.'; end if;
  if p_field_name not in ('display_name','tax_id','phone','address_line','contact_name','bank_reference','credit_limit','credit_term_days','outstanding_amount') or nullif(trim(coalesce(p_reason,'')),'') is null or nullif(trim(coalesce(p_evidence,'')),'') is null then raise exception 'Solicitud de ajuste incompleta.'; end if;
  if p_field_name='outstanding_amount' then select to_jsonb(outstanding_amount) into v_previous from public.customer_receivables where id=p_receivable_id and customer_id=p_customer_id and company_id=p_company_id and source_kind in ('alpha_document','alpha_opening_balance') for update; if v_previous is null or coalesce((p_proposed_value #>> '{}')::numeric,-1) < 0 then raise exception 'Saldo propuesto inválido.'; end if;
  else v_previous := case p_field_name when 'display_name' then to_jsonb(v_customer.display_name) when 'tax_id' then to_jsonb(v_customer.tax_id) when 'phone' then to_jsonb(v_customer.phone) when 'address_line' then to_jsonb(v_customer.address_line) when 'contact_name' then to_jsonb(v_customer.contact_name) when 'bank_reference' then to_jsonb(v_customer.bank_reference) when 'credit_limit' then to_jsonb(v_customer.credit_limit) when 'credit_term_days' then to_jsonb(v_customer.credit_term_days) end; end if;
  insert into public.alpha_customer_migration_adjustments(company_id,customer_id,receivable_id,field_name,previous_value,proposed_value,reason,evidence,requested_by) values(p_company_id,p_customer_id,p_receivable_id,p_field_name,v_previous,p_proposed_value,trim(p_reason),trim(p_evidence),auth.uid()) returning id into v_id;
  update public.customers set migration_status='adjustment_pending' where id=p_customer_id;
  perform public.write_sales_audit(p_company_id,'alpha_customer_migration.adjustment_requested','alpha_customer_migration_adjustments',v_id,jsonb_build_object('customer_id',p_customer_id,'field_name',p_field_name));
  return v_id;
end $$;

create or replace function public.decide_alpha_customer_migration_adjustment(p_adjustment_id uuid,p_approve boolean,p_decision_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.alpha_customer_migration_adjustments%rowtype;
begin
  select * into v from public.alpha_customer_migration_adjustments where id=p_adjustment_id for update;
  if not found or v.status <> 'pending' then raise exception 'Ajuste de migración no disponible.'; end if;
  if auth.uid()=v.requested_by or not public.is_super_admin() then raise exception 'La aprobación requiere un super administrador distinto al solicitante.'; end if;
  if p_approve then
    if v.field_name='outstanding_amount' then update public.customer_receivables set outstanding_amount=(v.proposed_value #>> '{}')::numeric where id=v.receivable_id;
    elsif v.field_name='display_name' then update public.customers set display_name=v.proposed_value #>> '{}' where id=v.customer_id;
    elsif v.field_name='tax_id' then update public.customers set tax_id=nullif(v.proposed_value #>> '{}','') where id=v.customer_id;
    elsif v.field_name='phone' then update public.customers set phone=nullif(v.proposed_value #>> '{}','') where id=v.customer_id;
    elsif v.field_name='address_line' then update public.customers set address_line=nullif(v.proposed_value #>> '{}','') where id=v.customer_id;
    elsif v.field_name='contact_name' then update public.customers set contact_name=nullif(v.proposed_value #>> '{}','') where id=v.customer_id;
    elsif v.field_name='bank_reference' then update public.customers set bank_reference=nullif(v.proposed_value #>> '{}','') where id=v.customer_id;
    elsif v.field_name='credit_limit' then update public.customers set credit_limit=(v.proposed_value #>> '{}')::numeric where id=v.customer_id;
    elsif v.field_name='credit_term_days' then update public.customers set credit_term_days=(v.proposed_value #>> '{}')::integer where id=v.customer_id; end if;
  end if;
  update public.alpha_customer_migration_adjustments set status=case when p_approve then 'approved' else 'rejected' end,decided_by=auth.uid(),decided_at=now(),decision_reason=nullif(trim(p_decision_reason),'') where id=v.id;
  update public.customers set migration_status=case when exists(select 1 from public.alpha_customer_migration_adjustments a where a.customer_id=v.customer_id and a.status='pending' and a.id<>v.id) then 'adjustment_pending' else 'promoted' end where id=v.customer_id;
  perform public.write_sales_audit(v.company_id,'alpha_customer_migration.adjustment_' || case when p_approve then 'approved' else 'rejected' end,'alpha_customer_migration_adjustments',v.id,jsonb_build_object('customer_id',v.customer_id,'field_name',v.field_name));
  return jsonb_build_object('adjustment_id',v.id,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;

create or replace function public.fail_alpha_customer_migration(p_batch_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para cerrar la migración fallida.';
  end if;
  if v_batch.status in ('loading','reconciling') then
    update public.alpha_customer_migration_batches
      set status='failed', completed_at=now(), summary=summary || jsonb_build_object('failure_reason', left(coalesce(nullif(trim(p_reason),''),'Error de staging o conciliación.'), 500))
      where id=p_batch_id;
    perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.failed','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('reason',left(coalesce(nullif(trim(p_reason),''),'Error de staging o conciliación.'),500)));
  end if;
end $$;

create or replace function public.list_alpha_customer_migration_batches(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'import_data') or public.has_company_permission(p_company_id,'view_import_audit')) then raise exception 'No autorizado para consultar migraciones de clientes.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'cutoff_date',b.cutoff_date,'status',b.status,'records_received',b.records_received,'records_promoted',b.records_promoted,'summary',b.summary,'created_at',b.created_at,'differences',(select count(*) from public.alpha_customer_migration_differences d where d.batch_id=b.id and d.severity='error')) order by b.created_at desc) from public.alpha_customer_migration_batches b where b.company_id=p_company_id), '[]'::jsonb);
end $$;

create or replace function public.assert_alpha_customer_credit_eligibility()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.sale_type='credit' and new.customer_id is not null and exists(select 1 from public.customers c where c.id=new.customer_id and c.alpha_external_code is not null and c.migration_status <> 'promoted') then raise exception 'El cliente Alpha debe estar promovido y sin ajuste pendiente para vender a crédito.'; end if;
  return new;
end $$;
drop trigger if exists sales_alpha_customer_credit_eligibility on public.sales;
create trigger sales_alpha_customer_credit_eligibility before insert on public.sales for each row execute function public.assert_alpha_customer_credit_eligibility();

create or replace function public.upsert_sale_customer(
  p_company_id uuid,p_customer_id uuid default null,p_code text default null,p_display_name text default null,p_tax_id text default null,p_email text default null,p_phone text default null,p_price_list_id uuid default null,p_credit_enabled boolean default false,p_credit_limit numeric default 0,p_credit_term_days integer default 0
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_customer_id uuid; v_can_manage_credit boolean; v_existing public.customers%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_customers') then raise exception 'No autorizado para administrar clientes.'; end if;
  v_can_manage_credit:=public.has_company_permission(p_company_id,'view_customer_credit');
  if nullif(trim(coalesce(p_display_name,'')),'') is null then raise exception 'El nombre del cliente es obligatorio.'; end if;
  if p_price_list_id is not null and not exists(select 1 from public.price_lists p where p.id=p_price_list_id and p.company_id=p_company_id and p.is_active and p.status='active') then raise exception 'Lista de precio no disponible.'; end if;
  if p_credit_enabled and (coalesce(p_credit_limit,0)<=0 or coalesce(p_credit_term_days,0)<=0) then raise exception 'El crédito requiere límite y plazo mayores a cero.'; end if;
  if p_customer_id is null then insert into public.customers(company_id,code,display_name,tax_id,email,phone,price_list_id,credit_enabled,credit_limit,credit_term_days,created_by) values(p_company_id,coalesce(nullif(trim(p_code),''),'CLI-'||upper(substr(gen_random_uuid()::text,1,8))),trim(p_display_name),nullif(trim(p_tax_id),''),nullif(trim(p_email),''),nullif(trim(p_phone),''),p_price_list_id,coalesce(p_credit_enabled,false),coalesce(p_credit_limit,0),coalesce(p_credit_term_days,0),auth.uid()) returning id into v_customer_id;
  else select * into v_existing from public.customers where id=p_customer_id and company_id=p_company_id for update; if not found then raise exception 'Cliente no encontrado.'; end if; if v_existing.alpha_external_code is not null then raise exception 'Los clientes importados de Alpha solo se corrigen mediante un ajuste auditado.'; end if; update public.customers set code=coalesce(nullif(trim(p_code),''),code),display_name=trim(p_display_name),tax_id=nullif(trim(p_tax_id),''),email=nullif(trim(p_email),''),phone=nullif(trim(p_phone),''),price_list_id=p_price_list_id,credit_enabled=case when v_can_manage_credit then coalesce(p_credit_enabled,false) else credit_enabled end,credit_limit=case when v_can_manage_credit then coalesce(p_credit_limit,0) else credit_limit end,credit_term_days=case when v_can_manage_credit then coalesce(p_credit_term_days,0) else credit_term_days end where id=p_customer_id returning id into v_customer_id; end if;
  perform public.write_sales_audit(p_company_id,case when p_customer_id is null then 'customer.created' else 'customer.updated' end,'customers',v_customer_id,jsonb_build_object('credit_enabled',coalesce(p_credit_enabled,false),'price_list_id',p_price_list_id)); return v_customer_id;
end $$;

create or replace function public.search_sale_customers(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'use_pos') then raise exception 'No autorizado.'; end if;
  with filtered as (select c.id,c.code,c.display_name,c.credit_enabled,c.price_list_id,c.migration_status,c.alpha_external_code from public.customers c where c.company_id=p_company_id and c.is_active and (v_query='' or lower(c.code) like '%'||v_query||'%' or lower(c.display_name) like '%'||v_query||'%' or lower(coalesce(c.tax_id,'')) like '%'||v_query||'%' or lower(coalesce(c.phone,'')) like '%'||v_query||'%')) select count(*) into v_total from filtered;
  with filtered as (select c.id,c.code,c.display_name,c.credit_enabled,c.price_list_id,c.migration_status,c.alpha_external_code from public.customers c where c.company_id=p_company_id and c.is_active and (v_query='' or lower(c.code) like '%'||v_query||'%' or lower(c.display_name) like '%'||v_query||'%' or lower(coalesce(c.tax_id,'')) like '%'||v_query||'%' or lower(coalesce(c.phone,'')) like '%'||v_query||'%')) select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'display_name',display_name,'credit_enabled',credit_enabled,'price_list_id',price_list_id,'migration_status',migration_status,'alpha_external_code',alpha_external_code) order by display_name),'[]'::jsonb) into v_items from (select * from filtered order by display_name limit v_size offset (v_page-1)*v_size) p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

create or replace function public.search_sale_customers_credit(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,30),1),100); v_query text:=lower(trim(coalesce(p_query,''))); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar crédito de clientes.'; end if;
  with filtered as (select c.id,c.code,c.display_name,(c.credit_enabled and (c.alpha_external_code is null or c.migration_status='promoted')) as credit_enabled,c.price_list_id,c.credit_limit,c.credit_term_days,c.migration_status,c.alpha_external_code,coalesce((select sum(r.outstanding_amount) from public.customer_receivables r where r.customer_id=c.id),0) outstanding_amount from public.customers c where c.company_id=p_company_id and c.is_active and (v_query='' or lower(c.code) like '%'||v_query||'%' or lower(c.display_name) like '%'||v_query||'%' or lower(coalesce(c.tax_id,'')) like '%'||v_query||'%' or lower(coalesce(c.phone,'')) like '%'||v_query||'%')) select count(*) into v_total from filtered;
  with filtered as (select c.id,c.code,c.display_name,(c.credit_enabled and (c.alpha_external_code is null or c.migration_status='promoted')) as credit_enabled,c.price_list_id,c.credit_limit,c.credit_term_days,c.migration_status,c.alpha_external_code,coalesce((select sum(r.outstanding_amount) from public.customer_receivables r where r.customer_id=c.id),0) outstanding_amount from public.customers c where c.company_id=p_company_id and c.is_active and (v_query='' or lower(c.code) like '%'||v_query||'%' or lower(c.display_name) like '%'||v_query||'%' or lower(coalesce(c.tax_id,'')) like '%'||v_query||'%' or lower(coalesce(c.phone,'')) like '%'||v_query||'%')) select coalesce(jsonb_agg(jsonb_build_object('id',id,'code',code,'display_name',display_name,'credit_enabled',credit_enabled,'price_list_id',price_list_id,'credit_limit',credit_limit,'credit_term_days',credit_term_days,'outstanding_amount',outstanding_amount,'available_credit',greatest(credit_limit-outstanding_amount,0),'migration_status',migration_status,'alpha_external_code',alpha_external_code) order by display_name),'[]'::jsonb) into v_items from (select * from filtered order by display_name limit v_size offset (v_page-1)*v_size) p;
  return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end $$;

revoke all on public.alpha_customer_migration_batches,public.alpha_customer_migration_files,public.alpha_customer_migration_customers,public.alpha_customer_migration_documents,public.alpha_customer_migration_collections,public.alpha_customer_migration_differences,public.alpha_customer_migration_adjustments from authenticated;
grant select on public.alpha_customer_migration_batches,public.alpha_customer_migration_files,public.alpha_customer_migration_customers,public.alpha_customer_migration_documents,public.alpha_customer_migration_collections,public.alpha_customer_migration_differences,public.alpha_customer_migration_adjustments to authenticated;
revoke all on function public.begin_alpha_customer_migration(uuid,date,text,jsonb),public.stage_alpha_customer_migration_rows(uuid,text,jsonb),public.declare_alpha_customer_opening_balance(uuid,text,numeric,text,text),public.reconcile_alpha_customer_migration(uuid),public.promote_alpha_customer_migration(uuid),public.request_alpha_customer_migration_adjustment(uuid,uuid,uuid,text,jsonb,text,text),public.decide_alpha_customer_migration_adjustment(uuid,boolean,text),public.fail_alpha_customer_migration(uuid,text),public.list_alpha_customer_migration_batches(uuid),public.search_sale_customers(uuid,text,integer,integer),public.search_sale_customers_credit(uuid,text,integer,integer) from public;
grant execute on function public.begin_alpha_customer_migration(uuid,date,text,jsonb),public.stage_alpha_customer_migration_rows(uuid,text,jsonb),public.declare_alpha_customer_opening_balance(uuid,text,numeric,text,text),public.reconcile_alpha_customer_migration(uuid),public.promote_alpha_customer_migration(uuid),public.request_alpha_customer_migration_adjustment(uuid,uuid,uuid,text,jsonb,text,text),public.decide_alpha_customer_migration_adjustment(uuid,boolean,text),public.fail_alpha_customer_migration(uuid,text),public.list_alpha_customer_migration_batches(uuid),public.search_sale_customers(uuid,text,integer,integer),public.search_sale_customers_credit(uuid,text,integer,integer) to authenticated;
