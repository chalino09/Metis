-- Satrapy · Module 3 discovery boundary: Alpha suppliers, purchase orders,
-- payable balances and supplier-payment evidence. This migration stages source
-- evidence only; it never invents receipts or posts operational/AP movements.

create table public.alpha_purchasing_import_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cutoff_date date not null,
  content_sha256 text not null,
  status text not null default 'loading' check (status in ('loading','staged','validation_failed','failed')),
  records_received integer not null default 0,
  imported_by uuid not null references auth.users(id) on delete restrict,
  summary jsonb not null default '{}'::jsonb,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(company_id, content_sha256)
);

create table public.alpha_purchasing_import_files (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  report_type text not null check (report_type in ('suppliers','purchase_orders','payable_documents','supplier_payments')),
  original_name text not null,
  file_sha256 text not null,
  snapshot_date date not null,
  row_count integer not null check (row_count >= 0),
  created_at timestamptz not null default now(),
  unique(batch_id, report_type),
  unique(batch_id, original_name)
);

create table public.alpha_purchasing_import_suppliers (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  external_code text not null,
  display_name text not null,
  counterparty_kind text,
  supplier_type text,
  tax_id text,
  address_line text,
  neighborhood text,
  municipality text,
  state_name text,
  phone text,
  source_row_number integer not null,
  source_row_hash text not null,
  unique(batch_id, external_code),
  unique(batch_id, source_row_hash)
);

create table public.alpha_purchasing_import_orders (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  source_order_key text not null,
  order_number text not null,
  branch_code text not null,
  supplier_external_code text not null,
  supplier_name text not null,
  warehouse_name text,
  ordered_date date not null,
  currency_code text,
  source_currency text,
  source_status text not null,
  source_approval_status text not null,
  exchange_rate numeric(18,6),
  discount_percent numeric(9,4),
  source_row_number integer not null,
  source_row_hash text not null,
  unique(batch_id, source_order_key),
  unique(batch_id, source_row_hash)
);

create table public.alpha_purchasing_import_order_lines (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  source_order_key text not null,
  line_number integer not null check (line_number > 0),
  alpha_class text,
  alpha_sku text not null,
  description text not null,
  unit text,
  attribute text,
  quantity numeric(18,6) not null,
  unit_cost_mxn numeric(18,6) not null,
  discount_1 numeric(9,4),
  discount_2 numeric(9,4),
  expected_date date,
  requisition_reference text,
  source_row_number integer not null,
  source_row_hash text not null,
  unique(batch_id, source_order_key, line_number),
  unique(batch_id, source_row_hash),
  foreign key(batch_id, source_order_key) references public.alpha_purchasing_import_orders(batch_id, source_order_key) on delete cascade
);

create table public.alpha_purchasing_import_payable_documents (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  source_document_key text not null,
  folio text not null,
  supplier_external_code text not null,
  supplier_name text not null,
  issued_date date not null,
  due_date date not null,
  source_concept text,
  outstanding_amount numeric(18,2) not null,
  currency_code text,
  source_currency text,
  source_row_number integer not null,
  source_row_hash text not null,
  unique(batch_id, source_document_key),
  unique(batch_id, source_row_hash)
);

create table public.alpha_purchasing_import_payment_evidence (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  source_payment_key text not null,
  application_folio text,
  branch_code text,
  payment_date date,
  document_type text,
  document_folio text not null,
  supplier_name text not null,
  matched_supplier_external_code text,
  amount_mxn numeric(18,2) not null,
  payment_method text,
  source_currency text,
  exchange_rate numeric(18,6),
  bank_reference text,
  source_row_number integer not null,
  source_row_hash text not null,
  unique(batch_id, source_payment_key),
  unique(batch_id, source_row_hash)
);

create table public.alpha_purchasing_import_differences (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.alpha_purchasing_import_batches(id) on delete cascade,
  severity text not null check (severity in ('error','warning')),
  difference_code text not null,
  message text not null,
  source_file text,
  source_row_number integer,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index alpha_purchasing_batches_company_created_idx on public.alpha_purchasing_import_batches(company_id, created_at desc);
create index alpha_purchasing_orders_supplier_idx on public.alpha_purchasing_import_orders(batch_id, supplier_external_code, ordered_date);
create index alpha_purchasing_lines_sku_idx on public.alpha_purchasing_import_order_lines(batch_id, alpha_sku);
create index alpha_purchasing_payables_supplier_idx on public.alpha_purchasing_import_payable_documents(batch_id, supplier_external_code, due_date);
create index alpha_purchasing_differences_batch_idx on public.alpha_purchasing_import_differences(batch_id, severity, difference_code);

alter table public.alpha_purchasing_import_batches enable row level security;
alter table public.alpha_purchasing_import_files enable row level security;
alter table public.alpha_purchasing_import_suppliers enable row level security;
alter table public.alpha_purchasing_import_orders enable row level security;
alter table public.alpha_purchasing_import_order_lines enable row level security;
alter table public.alpha_purchasing_import_payable_documents enable row level security;
alter table public.alpha_purchasing_import_payment_evidence enable row level security;
alter table public.alpha_purchasing_import_differences enable row level security;

create or replace function public.can_access_alpha_purchasing_import(p_batch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.alpha_purchasing_import_batches b
    where b.id=p_batch_id and (
      public.has_company_permission(b.company_id,'import_data')
      or public.has_company_permission(b.company_id,'view_import_audit')
    )
  )
$$;

create policy alpha_purchasing_batches_read on public.alpha_purchasing_import_batches for select to authenticated
  using (public.has_company_permission(company_id,'import_data') or public.has_company_permission(company_id,'view_import_audit'));
create policy alpha_purchasing_files_read on public.alpha_purchasing_import_files for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_suppliers_read on public.alpha_purchasing_import_suppliers for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_orders_read on public.alpha_purchasing_import_orders for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_order_lines_read on public.alpha_purchasing_import_order_lines for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_payables_read on public.alpha_purchasing_import_payable_documents for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_payment_evidence_read on public.alpha_purchasing_import_payment_evidence for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));
create policy alpha_purchasing_differences_read on public.alpha_purchasing_import_differences for select to authenticated using (public.can_access_alpha_purchasing_import(batch_id));

create or replace function public.begin_alpha_purchasing_import(
  p_company_id uuid, p_cutoff_date date, p_content_sha256 text, p_files jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch_id uuid; v_existing public.alpha_purchasing_import_batches%rowtype; v_received integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_data') then raise exception 'No autorizado para preparar Compras/CxP.'; end if;
  select * into v_existing from public.alpha_purchasing_import_batches where company_id=p_company_id and content_sha256=p_content_sha256;
  if found then return jsonb_build_object('status','duplicate','batch_id',v_existing.id,'message','Este paquete de Compras/CxP ya fue preparado.'); end if;
  if jsonb_typeof(coalesce(p_files,'null'::jsonb))<>'array' or jsonb_array_length(p_files)=0 then raise exception 'El paquete no contiene archivos.'; end if;
  select coalesce(sum(row_count),0) into v_received from jsonb_to_recordset(p_files) as f(row_count integer);
  insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,records_received,imported_by)
  values(p_company_id,p_cutoff_date,p_content_sha256,v_received,auth.uid()) returning id into v_batch_id;
  insert into public.alpha_purchasing_import_files(batch_id,report_type,original_name,file_sha256,snapshot_date,row_count)
  select v_batch_id,report_type,original_name,file_sha256,snapshot_date,row_count
  from jsonb_to_recordset(p_files) as f(report_type text,original_name text,file_sha256 text,snapshot_date date,row_count integer);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'alpha_purchasing.staging_started','alpha_purchasing_import_batch',v_batch_id,jsonb_build_object('cutoff_date',p_cutoff_date,'records_received',v_received));
  return jsonb_build_object('status','loading','batch_id',v_batch_id);
end $$;

create or replace function public.stage_alpha_purchasing_import_rows(p_batch_id uuid,p_kind text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_company uuid; v_inserted integer:=0;
begin
  select company_id into v_company from public.alpha_purchasing_import_batches where id=p_batch_id and status='loading' for update;
  if not found then raise exception 'Lote de Compras/CxP no disponible para staging.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_company,'import_data') then raise exception 'No autorizado.'; end if;
  if p_kind='suppliers' then
    insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,counterparty_kind,supplier_type,tax_id,address_line,neighborhood,municipality,state_name,phone,source_row_number,source_row_hash)
    select p_batch_id,external_code,display_name,counterparty_kind,supplier_type,tax_id,address_line,neighborhood,municipality,state_name,phone,source_row_number,source_row_hash
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) as r(external_code text,display_name text,counterparty_kind text,supplier_type text,tax_id text,address_line text,neighborhood text,municipality text,state_name text,phone text,source_row_number integer,source_row_hash text);
  elsif p_kind='purchase_orders' then
    insert into public.alpha_purchasing_import_orders(batch_id,source_order_key,order_number,branch_code,supplier_external_code,supplier_name,warehouse_name,ordered_date,currency_code,source_currency,source_status,source_approval_status,exchange_rate,discount_percent,source_row_number,source_row_hash)
    select p_batch_id,source_order_key,order_number,branch_code,supplier_external_code,supplier_name,warehouse_name,ordered_date,currency_code,source_currency,source_status,source_approval_status,exchange_rate,discount_percent,source_row_number,source_row_hash
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) as r(source_order_key text,order_number text,branch_code text,supplier_external_code text,supplier_name text,warehouse_name text,ordered_date date,currency_code text,source_currency text,source_status text,source_approval_status text,exchange_rate numeric,discount_percent numeric,source_row_number integer,source_row_hash text);
  elsif p_kind='purchase_order_lines' then
    insert into public.alpha_purchasing_import_order_lines(batch_id,source_order_key,line_number,alpha_class,alpha_sku,description,unit,attribute,quantity,unit_cost_mxn,discount_1,discount_2,expected_date,requisition_reference,source_row_number,source_row_hash)
    select p_batch_id,source_order_key,line_number,alpha_class,alpha_sku,description,unit,attribute,quantity,unit_cost_mxn,discount_1,discount_2,expected_date,requisition_reference,source_row_number,source_row_hash
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) as r(source_order_key text,line_number integer,alpha_class text,alpha_sku text,description text,unit text,attribute text,quantity numeric,unit_cost_mxn numeric,discount_1 numeric,discount_2 numeric,expected_date date,requisition_reference text,source_row_number integer,source_row_hash text);
  elsif p_kind='payable_documents' then
    insert into public.alpha_purchasing_import_payable_documents(batch_id,source_document_key,folio,supplier_external_code,supplier_name,issued_date,due_date,source_concept,outstanding_amount,currency_code,source_currency,source_row_number,source_row_hash)
    select p_batch_id,source_document_key,folio,supplier_external_code,supplier_name,issued_date,due_date,source_concept,outstanding_amount,currency_code,source_currency,source_row_number,source_row_hash
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) as r(source_document_key text,folio text,supplier_external_code text,supplier_name text,issued_date date,due_date date,source_concept text,outstanding_amount numeric,currency_code text,source_currency text,source_row_number integer,source_row_hash text);
  elsif p_kind='supplier_payments' then
    insert into public.alpha_purchasing_import_payment_evidence(batch_id,source_payment_key,application_folio,branch_code,payment_date,document_type,document_folio,supplier_name,matched_supplier_external_code,amount_mxn,payment_method,source_currency,exchange_rate,bank_reference,source_row_number,source_row_hash)
    select p_batch_id,source_payment_key,application_folio,branch_code,payment_date,document_type,document_folio,supplier_name,matched_supplier_external_code,amount_mxn,payment_method,source_currency,exchange_rate,bank_reference,source_row_number,source_row_hash
    from jsonb_to_recordset(coalesce(p_rows,'[]'::jsonb)) as r(source_payment_key text,application_folio text,branch_code text,payment_date date,document_type text,document_folio text,supplier_name text,matched_supplier_external_code text,amount_mxn numeric,payment_method text,source_currency text,exchange_rate numeric,bank_reference text,source_row_number integer,source_row_hash text);
  else raise exception 'Tipo de fila de Compras/CxP no permitido.';
  end if;
  get diagnostics v_inserted=row_count;
  return jsonb_build_object('status','loading','inserted',v_inserted);
end $$;

create or replace function public.finish_alpha_purchasing_import(p_batch_id uuid,p_summary jsonb,p_differences jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.alpha_purchasing_import_batches%rowtype; v_errors integer; v_warnings integer;
begin
  select * into v_batch from public.alpha_purchasing_import_batches where id=p_batch_id and status='loading' for update;
  if not found then raise exception 'Lote de Compras/CxP no disponible para finalizar.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado.'; end if;
  insert into public.alpha_purchasing_import_differences(batch_id,severity,difference_code,message,source_file,source_row_number,evidence)
  select p_batch_id,severity,difference_code,message,source_file,source_row_number,coalesce(evidence,'{}'::jsonb)
  from jsonb_to_recordset(coalesce(p_differences,'[]'::jsonb)) as d(severity text,difference_code text,message text,source_file text,source_row_number integer,evidence jsonb);
  select count(*) filter(where severity='error'),count(*) filter(where severity='warning') into v_errors,v_warnings
  from public.alpha_purchasing_import_differences where batch_id=p_batch_id;
  update public.alpha_purchasing_import_batches set status=case when v_errors>0 then 'validation_failed' else 'staged' end,
    summary=coalesce(p_summary,'{}'::jsonb)||jsonb_build_object('error_count',v_errors,'warning_count',v_warnings,'operational_import_ready',false),completed_at=now()
  where id=p_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_batch.company_id,auth.uid(),'alpha_purchasing.staged','alpha_purchasing_import_batch',p_batch_id,jsonb_build_object('errors',v_errors,'warnings',v_warnings,'operational_import_ready',false));
  return jsonb_build_object('status',case when v_errors>0 then 'validation_failed' else 'staged' end,'batch_id',p_batch_id,'errors',v_errors,'warnings',v_warnings,'message','Evidencia de Compras/CxP preparada; no se han creado operaciones ni saldos canónicos.');
end $$;

create or replace function public.fail_alpha_purchasing_import(p_batch_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_company uuid;
begin
  select company_id into v_company from public.alpha_purchasing_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_company,'import_data') then raise exception 'No autorizado.'; end if;
  update public.alpha_purchasing_import_batches set status='failed',summary=summary||jsonb_build_object('failure_reason',p_reason),completed_at=now() where id=p_batch_id and status='loading';
end $$;

create or replace function public.list_alpha_purchasing_import_batches(p_company_id uuid,p_page integer default 1,p_page_size integer default 20)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,20),1),100); v_total integer; v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'import_data') or public.has_company_permission(p_company_id,'view_import_audit')) then raise exception 'No autorizado.'; end if;
  select count(*) into v_total from public.alpha_purchasing_import_batches where company_id=p_company_id;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_items from (
    select b.id,b.cutoff_date,b.status,b.records_received,b.summary,b.completed_at,b.created_at,
      (select count(*) from public.alpha_purchasing_import_differences d where d.batch_id=b.id) differences,
      (select coalesce(jsonb_agg(jsonb_build_object('report_type',f.report_type,'original_name',f.original_name,'row_count',f.row_count) order by f.report_type),'[]'::jsonb) from public.alpha_purchasing_import_files f where f.batch_id=b.id) files
    from public.alpha_purchasing_import_batches b where b.company_id=p_company_id order by b.created_at desc limit v_size offset (v_page-1)*v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

revoke all on function public.can_access_alpha_purchasing_import(uuid) from public;
revoke all on function public.begin_alpha_purchasing_import(uuid,date,text,jsonb) from public;
revoke all on function public.stage_alpha_purchasing_import_rows(uuid,text,jsonb) from public;
revoke all on function public.finish_alpha_purchasing_import(uuid,jsonb,jsonb) from public;
revoke all on function public.fail_alpha_purchasing_import(uuid,text) from public;
revoke all on function public.list_alpha_purchasing_import_batches(uuid,integer,integer) from public;
grant execute on function public.can_access_alpha_purchasing_import(uuid) to authenticated;
grant execute on function public.begin_alpha_purchasing_import(uuid,date,text,jsonb) to authenticated;
grant execute on function public.stage_alpha_purchasing_import_rows(uuid,text,jsonb) to authenticated;
grant execute on function public.finish_alpha_purchasing_import(uuid,jsonb,jsonb) to authenticated;
grant execute on function public.fail_alpha_purchasing_import(uuid,text) to authenticated;
grant execute on function public.list_alpha_purchasing_import_batches(uuid,integer,integer) to authenticated;
