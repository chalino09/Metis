-- Satrapy · M3D completion: fiscal dossier, non-receipt obligations,
-- multi-currency snapshots and accounts-payable aging.
-- Payments, bank movements and accounting entries remain outside M3D.

insert into public.permissions(code,description) values
  ('manage_supplier_invoice_documents','Adjuntar y validar el expediente documental de facturas de proveedor.'),
  ('manage_supplier_expense_invoices','Capturar y aprobar facturas de gasto o servicio sin recepción.'),
  ('verify_supplier_invoice_cfdi','Registrar evidencia de verificación oficial de CFDI ante SAT.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'manage_supplier_invoice_documents','manage_supplier_expense_invoices','verify_supplier_invoice_cfdi'
) on conflict do nothing;

alter table public.companies
  add column if not exists tax_id text,
  add column if not exists base_currency_code text not null default 'MXN';
alter table public.companies drop constraint if exists companies_base_currency_code_check;
alter table public.companies add constraint companies_base_currency_code_check check(base_currency_code~'^[A-Z]{3}$');

alter table public.suppliers
  add column if not exists payable_term_days integer not null default 0;
alter table public.suppliers drop constraint if exists suppliers_payable_term_days_check;
alter table public.suppliers add constraint suppliers_payable_term_days_check check(payable_term_days between 0 and 3650);

alter table public.supplier_invoices
  add column if not exists source_kind text not null default 'receipt',
  add column if not exists exchange_rate numeric(18,6) not null default 1,
  add column if not exists base_currency_code text not null default 'MXN',
  add column if not exists base_total numeric(18,6) not null default 0,
  add column if not exists payment_method_code text,
  add column if not exists payment_form_code text,
  add column if not exists expense_approved_at timestamptz,
  add column if not exists expense_approved_by uuid references auth.users(id) on delete set null,
  add column if not exists expense_approval_reason text;

update public.supplier_invoices si set
  base_currency_code=coalesce(c.base_currency_code,'MXN'),
  exchange_rate=case when si.currency_code=coalesce(c.base_currency_code,'MXN') then 1 else si.exchange_rate end,
  base_total=round(si.total*case when si.currency_code=coalesce(c.base_currency_code,'MXN') then 1 else si.exchange_rate end,6)
from public.companies c where c.id=si.company_id;

alter table public.supplier_invoices drop constraint if exists supplier_invoices_source_kind_check;
alter table public.supplier_invoices add constraint supplier_invoices_source_kind_check check(source_kind in ('receipt','expense'));
alter table public.supplier_invoices drop constraint if exists supplier_invoices_exchange_rate_check;
alter table public.supplier_invoices add constraint supplier_invoices_exchange_rate_check check(exchange_rate>0);
alter table public.supplier_invoices drop constraint if exists supplier_invoices_base_currency_code_check;
alter table public.supplier_invoices add constraint supplier_invoices_base_currency_code_check check(base_currency_code~'^[A-Z]{3}$');
alter table public.supplier_invoices drop constraint if exists supplier_invoices_base_total_check;
alter table public.supplier_invoices add constraint supplier_invoices_base_total_check check(base_total>=0);

do $$
declare v_constraint record;
begin
  for v_constraint in
    select conname from pg_constraint
    where conrelid='public.supplier_invoices'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%document_type%'
      and pg_get_constraintdef(oid) ilike '%purchase_order_id%'
  loop
    execute format('alter table public.supplier_invoices drop constraint %I',v_constraint.conname);
  end loop;
end $$;

alter table public.supplier_invoices add constraint supplier_invoices_origin_check check(
  (document_type='invoice' and original_invoice_id is null and
    ((source_kind='receipt' and purchase_order_id is not null) or
     (source_kind='expense' and purchase_order_id is null)))
  or (document_type='credit_note' and original_invoice_id is not null)
);

alter table public.accounts_payable
  add column if not exists exchange_rate numeric(18,6) not null default 1,
  add column if not exists base_currency_code text not null default 'MXN',
  add column if not exists original_base_amount numeric(18,6) not null default 0,
  add column if not exists outstanding_base_amount numeric(18,6) not null default 0;

update public.accounts_payable ap set
  exchange_rate=si.exchange_rate,
  base_currency_code=si.base_currency_code,
  original_base_amount=si.base_total,
  outstanding_base_amount=round(ap.outstanding_amount*si.exchange_rate,6)
from public.supplier_invoices si where si.id=ap.supplier_invoice_id;

alter table public.accounts_payable drop constraint if exists accounts_payable_exchange_rate_check;
alter table public.accounts_payable add constraint accounts_payable_exchange_rate_check check(exchange_rate>0);
alter table public.accounts_payable drop constraint if exists accounts_payable_base_currency_code_check;
alter table public.accounts_payable add constraint accounts_payable_base_currency_code_check check(base_currency_code~'^[A-Z]{3}$');
alter table public.accounts_payable drop constraint if exists accounts_payable_base_amounts_check;
alter table public.accounts_payable add constraint accounts_payable_base_amounts_check check(original_base_amount>=0 and outstanding_base_amount>=0);

create or replace function public.sync_accounts_payable_base_amounts()
returns trigger language plpgsql set search_path=public as $$
begin
  new.original_base_amount:=round(new.original_amount*new.exchange_rate,6);
  new.outstanding_base_amount:=round(new.outstanding_amount*new.exchange_rate,6);
  return new;
end $$;
create trigger sync_accounts_payable_base_amounts before insert or update of original_amount,outstanding_amount,exchange_rate on public.accounts_payable for each row execute function public.sync_accounts_payable_base_amounts();

create table public.supplier_invoice_expense_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  line_number integer not null check(line_number>0),
  description text not null check(length(trim(description))>0),
  subtotal numeric(18,6) not null check(subtotal>=0),
  discount_amount numeric(18,6) not null default 0 check(discount_amount>=0),
  tax_amount numeric(18,6) not null default 0 check(tax_amount>=0),
  total numeric(18,6) generated always as (round(subtotal-discount_amount+tax_amount,6)) stored,
  created_at timestamptz not null default now(),
  unique(supplier_invoice_id,line_number),
  check(discount_amount<=subtotal)
);

create table public.supplier_invoice_documents(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete restrict,
  document_role text not null check(document_role in ('cfdi_xml','representation_pdf','sat_verification')),
  original_file_name text not null check(length(trim(original_file_name))>0),
  storage_path text not null,
  mime_type text not null,
  size_bytes bigint not null check(size_bytes between 1 and 10485760),
  sha256 text not null check(sha256~'^[a-f0-9]{64}$'),
  extracted_data jsonb not null default '{}'::jsonb,
  validation_status text not null default 'not_applicable' check(validation_status in ('not_applicable','verified_local','mismatch','unreadable')),
  validation_issues jsonb not null default '[]'::jsonb check(jsonb_typeof(validation_issues)='array'),
  sat_status text not null default 'not_checked' check(sat_status in ('not_checked','valid','cancelled','not_found')),
  sat_checked_at timestamptz,
  sat_evidence jsonb,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,sha256),
  unique(company_id,storage_path)
);
create index supplier_invoice_documents_invoice_idx on public.supplier_invoice_documents(supplier_invoice_id,created_at,id);

create or replace function public.guard_supplier_invoice_expense_line_mutation()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;v_source text;
begin
  select status,source_kind into v_status,v_source from public.supplier_invoices where id=coalesce(new.supplier_invoice_id,old.supplier_invoice_id);
  if v_status is distinct from 'draft' or v_source is distinct from 'expense' then
    raise exception 'Las partidas de gasto sólo pueden modificarse en una factura de gasto en borrador.';
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger guard_supplier_invoice_expense_line_mutation before insert or update or delete on public.supplier_invoice_expense_lines for each row execute function public.guard_supplier_invoice_expense_line_mutation();

alter table public.supplier_invoice_expense_lines enable row level security;
alter table public.supplier_invoice_documents enable row level security;
create policy supplier_invoice_expense_lines_read on public.supplier_invoice_expense_lines for select to authenticated
using(public.has_company_permission(company_id,'view_supplier_invoices'));
create policy supplier_invoice_documents_read on public.supplier_invoice_documents for select to authenticated
using(public.has_company_permission(company_id,'view_supplier_invoices'));

do $$
begin
  -- Local validation deliberately runs with Storage disabled. Production Supabase
  -- has this schema and receives the private bucket plus company-scoped policies.
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    execute $sql$insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values('supplier-invoice-documents','supplier-invoice-documents',false,10485760,array['application/xml','text/xml','application/pdf'])
      on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types$sql$;
    execute $sql$create policy supplier_invoice_documents_storage_read on storage.objects for select to authenticated
      using(bucket_id='supplier-invoice-documents' and public.has_company_permission(((storage.foldername(name))[1])::uuid,'view_supplier_invoices'))$sql$;
    execute $sql$create policy supplier_invoice_documents_storage_insert on storage.objects for insert to authenticated
      with check(bucket_id='supplier-invoice-documents' and public.has_company_permission(((storage.foldername(name))[1])::uuid,'manage_supplier_invoice_documents'))$sql$;
  end if;
end $$;

create or replace function public.save_supplier_invoice_v2(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_purchase_order_id uuid,p_series text,p_folio text,
  p_fiscal_uuid text,p_issued_date date,p_due_date date,p_currency_code text,p_exchange_rate numeric,
  p_supplier_reference text,p_payment_method_code text,p_payment_form_code text,p_lines jsonb,
  p_client_request_id uuid default null,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;v_invoice_id uuid;v_base_currency text;v_rate numeric;
begin
  select base_currency_code into v_base_currency from public.companies where id=p_company_id;
  if not found then raise exception 'Empresa no encontrada.';end if;
  v_rate:=case when upper(trim(p_currency_code))=v_base_currency then 1 else p_exchange_rate end;
  if coalesce(v_rate,0)<=0 then raise exception 'Captura un tipo de cambio mayor a cero.';end if;
  v_result:=public.save_supplier_invoice(p_company_id,p_invoice_id,p_supplier_id,p_purchase_order_id,p_series,p_folio,p_fiscal_uuid,p_issued_date,p_due_date,upper(trim(p_currency_code)),p_supplier_reference,p_lines,p_client_request_id,p_expected_updated_at);
  if v_result->>'status'='draft' then
    v_invoice_id:=(v_result->>'id')::uuid;
    update public.supplier_invoices set exchange_rate=v_rate,base_currency_code=v_base_currency,
      base_total=round(total*v_rate,6),payment_method_code=nullif(trim(p_payment_method_code),''),
      payment_form_code=nullif(trim(p_payment_form_code),'')
    where id=v_invoice_id and company_id=p_company_id;
    v_result:=v_result||jsonb_build_object('exchange_rate',v_rate,'base_currency_code',v_base_currency,'base_total',(select base_total from public.supplier_invoices where id=v_invoice_id));
  end if;
  return v_result;
end $$;

create or replace function public.save_supplier_expense_invoice(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_series text,p_folio text,p_fiscal_uuid text,
  p_issued_date date,p_due_date date,p_currency_code text,p_exchange_rate numeric,p_supplier_reference text,
  p_payment_method_code text,p_payment_form_code text,p_lines jsonb,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_supplier public.suppliers%rowtype;v_line jsonb;v_id uuid;
  v_subtotal numeric:=0;v_discount numeric:=0;v_tax numeric:=0;v_total numeric:=0;v_base text;v_rate numeric;v_duplicate uuid;v_number int:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_expense_invoices') then raise exception 'No autorizado para administrar facturas de gasto.';end if;
  if nullif(trim(coalesce(p_folio,'')),'') is null or p_due_date<p_issued_date or upper(trim(coalesce(p_currency_code,'')))!~'^[A-Z]{3}$' then raise exception 'Identidad, fechas o moneda inválidas.';end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La factura de gasto requiere al menos un concepto.';end if;
  select * into v_supplier from public.suppliers where id=p_supplier_id and company_id=p_company_id and is_active for update;
  if not found then raise exception 'Proveedor activo no encontrado.';end if;
  select base_currency_code into v_base from public.companies where id=p_company_id;
  v_rate:=case when upper(trim(p_currency_code))=v_base then 1 else p_exchange_rate end;
  if coalesce(v_rate,0)<=0 then raise exception 'Captura un tipo de cambio mayor a cero.';end if;
  if p_invoice_id is null then v_id:=gen_random_uuid(); else
    select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
    if not found or v_invoice.status<>'draft' or v_invoice.document_type<>'invoice' or v_invoice.source_kind<>'expense' then raise exception 'Borrador de gasto no disponible.';end if;
    if p_expected_updated_at is not null and v_invoice.updated_at<>p_expected_updated_at then raise exception 'El borrador cambió; recargue antes de guardar.';end if;
    v_id:=v_invoice.id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    if nullif(trim(coalesce(v_line->>'description','')),'') is null or coalesce((v_line->>'subtotal')::numeric,0)<0 or coalesce((v_line->>'discount_amount')::numeric,0)<0 or coalesce((v_line->>'tax_amount')::numeric,0)<0 or coalesce((v_line->>'discount_amount')::numeric,0)>coalesce((v_line->>'subtotal')::numeric,0) then raise exception 'Concepto o importes de gasto inválidos.';end if;
    v_subtotal:=v_subtotal+(v_line->>'subtotal')::numeric;v_discount:=v_discount+coalesce((v_line->>'discount_amount')::numeric,0);v_tax:=v_tax+coalesce((v_line->>'tax_amount')::numeric,0);
  end loop;
  v_total:=round(v_subtotal-v_discount+v_tax,6);
  select id into v_duplicate from public.supplier_invoices where company_id=p_company_id and supplier_id=p_supplier_id and document_type='invoice' and id<>v_id and ((nullif(trim(coalesce(p_fiscal_uuid,'')),'') is not null and lower(fiscal_uuid)=lower(trim(p_fiscal_uuid))) or (nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null and fiscal_uuid is null and lower(coalesce(series,''))=lower(coalesce(trim(p_series),'')) and lower(folio)=lower(trim(p_folio)) and issued_date=p_issued_date and total=v_total)) limit 1;
  if v_duplicate is not null then
    insert into public.supplier_invoice_exceptions(company_id,supplier_id,kind,evidence) values(p_company_id,p_supplier_id,case when nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null then 'duplicate_identity' else 'duplicate_uuid' end,jsonb_build_object('candidate_invoice_id',v_duplicate,'series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid,'issued_date',p_issued_date,'total',v_total,'source_kind','expense'));
    return jsonb_build_object('status','exception','kind',case when nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null then 'duplicate_identity' else 'duplicate_uuid' end,'duplicate_invoice_id',v_duplicate);
  end if;
  if p_invoice_id is null then
    insert into public.supplier_invoices(id,company_id,supplier_id,source_kind,series,folio,fiscal_uuid,issued_date,due_date,currency_code,exchange_rate,base_currency_code,supplier_reference,payment_method_code,payment_form_code,subtotal,discount_total,tax_total,total,base_total)
    values(v_id,p_company_id,p_supplier_id,'expense',nullif(trim(p_series),''),trim(p_folio),nullif(lower(trim(p_fiscal_uuid)),''),p_issued_date,p_due_date,upper(trim(p_currency_code)),v_rate,v_base,nullif(trim(p_supplier_reference),''),nullif(trim(p_payment_method_code),''),nullif(trim(p_payment_form_code),''),v_subtotal,v_discount,v_tax,v_total,round(v_total*v_rate,6));
  else
    delete from public.supplier_invoice_expense_lines where supplier_invoice_id=v_id;
    update public.supplier_invoices set supplier_id=p_supplier_id,series=nullif(trim(p_series),''),folio=trim(p_folio),fiscal_uuid=nullif(lower(trim(p_fiscal_uuid)),''),issued_date=p_issued_date,due_date=p_due_date,currency_code=upper(trim(p_currency_code)),exchange_rate=v_rate,base_currency_code=v_base,supplier_reference=nullif(trim(p_supplier_reference),''),payment_method_code=nullif(trim(p_payment_method_code),''),payment_form_code=nullif(trim(p_payment_form_code),''),subtotal=v_subtotal,discount_total=v_discount,tax_total=v_tax,total=v_total,base_total=round(v_total*v_rate,6),expense_approved_at=null,expense_approved_by=null,expense_approval_reason=null,updated_by=auth.uid() where id=v_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_number:=v_number+1;
    insert into public.supplier_invoice_expense_lines(company_id,supplier_invoice_id,line_number,description,subtotal,discount_amount,tax_amount)
    values(p_company_id,v_id,v_number,trim(v_line->>'description'),(v_line->>'subtotal')::numeric,coalesce((v_line->>'discount_amount')::numeric,0),coalesce((v_line->>'tax_amount')::numeric,0));
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_invoice_id is null then 'supplier_expense_invoice.draft_created' else 'supplier_expense_invoice.draft_updated' end,'supplier_invoice',v_id,jsonb_build_object('line_count',jsonb_array_length(p_lines),'total',v_total,'exchange_rate',v_rate));
  return jsonb_build_object('id',v_id,'status','draft','source_kind','expense','total',v_total,'base_total',round(v_total*v_rate,6));
end $$;

create or replace function public.approve_supplier_expense_invoice(p_company_id uuid,p_invoice_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_expense_invoices') then raise exception 'No autorizado para aprobar facturas de gasto.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo de aprobación es obligatorio.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found or v_invoice.status<>'draft' or v_invoice.source_kind<>'expense' then raise exception 'Factura de gasto en borrador no encontrada.';end if;
  update public.supplier_invoices set expense_approved_at=clock_timestamp(),expense_approved_by=auth.uid(),expense_approval_reason=trim(p_reason),updated_by=auth.uid() where id=p_invoice_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_expense_invoice.approved','supplier_invoice',p_invoice_id,jsonb_build_object('reason',trim(p_reason),'total',v_invoice.total));
  return jsonb_build_object('id',p_invoice_id,'approved',true);
end $$;

create or replace function public.register_supplier_invoice_document(
  p_company_id uuid,p_invoice_id uuid,p_document_role text,p_original_file_name text,p_storage_path text,
  p_mime_type text,p_size_bytes bigint,p_sha256 text,p_extracted_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_supplier public.suppliers%rowtype;v_company public.companies%rowtype;v_existing public.supplier_invoice_documents%rowtype;v_issues jsonb:='[]'::jsonb;v_status text:='not_applicable';v_id uuid;v_uuid text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_invoice_documents') then raise exception 'No autorizado para administrar expedientes de factura.';end if;
  if p_document_role not in ('cfdi_xml','representation_pdf') or nullif(trim(coalesce(p_storage_path,'')),'') is null or lower(trim(coalesce(p_sha256,'')))!~'^[a-f0-9]{64}$' then raise exception 'Metadatos de documento inválidos.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found then raise exception 'Factura no encontrada.';end if;
  select * into v_supplier from public.suppliers where id=v_invoice.supplier_id;
  select * into v_company from public.companies where id=p_company_id;
  select * into v_existing from public.supplier_invoice_documents where company_id=p_company_id and sha256=lower(trim(p_sha256));
  if found then
    if v_existing.supplier_invoice_id=p_invoice_id then return jsonb_build_object('id',v_existing.id,'status',v_existing.validation_status,'idempotent',true);end if;
    raise exception 'El mismo archivo ya pertenece a otra factura.';
  end if;
  if p_document_role='cfdi_xml' then
    v_status:='verified_local';v_uuid:=nullif(lower(trim(p_extracted_data->>'uuid')),'');
    if p_extracted_data->>'version' is distinct from '4.0' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','version','expected','4.0','actual',p_extracted_data->>'version'));end if;
    if coalesce(v_supplier.country_code,'MX')='MX' and v_supplier.tax_id is not null and upper(coalesce(p_extracted_data->>'issuer_rfc',''))<>upper(v_supplier.tax_id) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','issuer_rfc','expected',v_supplier.tax_id,'actual',p_extracted_data->>'issuer_rfc'));end if;
    if v_company.tax_id is not null and upper(coalesce(p_extracted_data->>'receiver_rfc',''))<>upper(v_company.tax_id) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','receiver_rfc','expected',v_company.tax_id,'actual',p_extracted_data->>'receiver_rfc'));end if;
    if v_invoice.fiscal_uuid is not null and v_uuid is distinct from lower(v_invoice.fiscal_uuid) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','uuid','expected',v_invoice.fiscal_uuid,'actual',v_uuid));end if;
    if upper(coalesce(p_extracted_data->>'currency',''))<>v_invoice.currency_code then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','currency','expected',v_invoice.currency_code,'actual',p_extracted_data->>'currency'));end if;
    if coalesce((p_extracted_data->>'total')::numeric,-1)<>v_invoice.total then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','total','expected',v_invoice.total,'actual',p_extracted_data->>'total'));end if;
    if nullif(left(coalesce(p_extracted_data->>'issued_at',''),10),'')::date is distinct from v_invoice.issued_date then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','issued_date','expected',v_invoice.issued_date,'actual',left(coalesce(p_extracted_data->>'issued_at',''),10)));end if;
    if v_invoice.document_type='invoice' and p_extracted_data->>'document_type' is distinct from 'I' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','document_type','expected','I','actual',p_extracted_data->>'document_type'));end if;
    if v_invoice.document_type='credit_note' and p_extracted_data->>'document_type' is distinct from 'E' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','document_type','expected','E','actual',p_extracted_data->>'document_type'));end if;
    if v_uuid is null then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','uuid','expected','UUID timbrado','actual',null));end if;
    if jsonb_array_length(v_issues)>0 then v_status:='mismatch';
    elsif v_invoice.fiscal_uuid is null and v_invoice.status='draft' then update public.supplier_invoices set fiscal_uuid=v_uuid,updated_by=auth.uid() where id=v_invoice.id;end if;
  end if;
  insert into public.supplier_invoice_documents(company_id,supplier_invoice_id,document_role,original_file_name,storage_path,mime_type,size_bytes,sha256,extracted_data,validation_status,validation_issues)
  values(p_company_id,p_invoice_id,p_document_role,trim(p_original_file_name),trim(p_storage_path),p_mime_type,p_size_bytes,lower(trim(p_sha256)),coalesce(p_extracted_data,'{}'::jsonb),v_status,v_issues) returning id into v_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.document_attached','supplier_invoice',p_invoice_id,jsonb_build_object('document_id',v_id,'document_role',p_document_role,'sha256',lower(trim(p_sha256)),'validation_status',v_status,'validation_issues',v_issues));
  return jsonb_build_object('id',v_id,'status',v_status,'issues',v_issues,'idempotent',false);
end $$;

create or replace function public.record_supplier_invoice_sat_verification(
  p_company_id uuid,p_invoice_id uuid,p_status text,p_checked_at timestamptz,p_evidence jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_document uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'verify_supplier_invoice_cfdi') then raise exception 'No autorizado para registrar verificaciones SAT.';end if;
  if p_status not in ('valid','cancelled','not_found') or p_checked_at is null or coalesce(p_evidence,'{}'::jsonb)='{}'::jsonb then raise exception 'La verificación SAT requiere resultado, fecha y evidencia.';end if;
  select id into v_document from public.supplier_invoice_documents where company_id=p_company_id and supplier_invoice_id=p_invoice_id and document_role='cfdi_xml' order by created_at desc limit 1 for update;
  if not found then raise exception 'Adjunta primero el XML CFDI.';end if;
  update public.supplier_invoice_documents set sat_status=p_status,sat_checked_at=p_checked_at,sat_evidence=p_evidence where id=v_document;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.sat_verification_recorded','supplier_invoice',p_invoice_id,jsonb_build_object('document_id',v_document,'status',p_status,'checked_at',p_checked_at,'evidence',p_evidence));
  return jsonb_build_object('document_id',v_document,'sat_status',p_status,'checked_at',p_checked_at);
end $$;

create or replace function public.confirm_supplier_invoice(p_company_id uuid,p_invoice_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_available numeric;v_payable uuid;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_supplier_invoices') then raise exception 'No autorizado para confirmar facturas.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found or v_invoice.document_type<>'invoice' then raise exception 'Factura no encontrada.';end if;
  if v_invoice.status='confirmed' and v_invoice.confirm_request_id=v_request then return jsonb_build_object('invoice_id',v_invoice.id,'payable_id',(select id from public.accounts_payable where supplier_invoice_id=v_invoice.id),'status','confirmed','idempotent',true);end if;
  if v_invoice.status<>'draft' then raise exception 'Sólo puede confirmarse una factura en borrador.';end if;
  if jsonb_array_length(v_invoice.differences)>0 and v_invoice.differences_authorized_at is null then raise exception 'Las diferencias requieren autorización explícita.';end if;
  if exists(select 1 from public.supplier_invoice_documents where supplier_invoice_id=v_invoice.id and document_role='cfdi_xml' and validation_status in ('mismatch','unreadable')) then raise exception 'El XML adjunto presenta diferencias; corrige el expediente antes de confirmar.';end if;
  if v_invoice.source_kind='receipt' then
    select * into v_order from public.purchase_orders where id=v_invoice.purchase_order_id and company_id=p_company_id for update;
    if not found or v_order.status<>'approved' or v_order.origin<>'operational' or v_order.supplier_id<>v_invoice.supplier_id then raise exception 'La OC ya no es facturable.';end if;
    for v_line in select sil.*,pr.status receipt_status,pr.supplier_id receipt_supplier_id,pr.purchase_order_id receipt_order_id from public.supplier_invoice_lines sil join public.purchase_receipt_lines prl on prl.id=sil.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id where sil.supplier_invoice_id=v_invoice.id order by sil.purchase_receipt_line_id for update of prl loop
      if v_line.receipt_status<>'confirmed' or v_line.receipt_supplier_id<>v_invoice.supplier_id or v_line.receipt_order_id<>v_invoice.purchase_order_id then raise exception 'La recepción ya no es facturable.';end if;
      select v_line.received_quantity-coalesce(sum(sil.quantity),0) into v_available from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=v_line.purchase_receipt_line_id and si.status='confirmed';
      if v_line.quantity>v_available then raise exception 'Confirmación concurrente: cantidad recibida ya facturada.';end if;
    end loop;
  else
    if v_invoice.expense_approved_at is null then raise exception 'La factura de gasto requiere aprobación antes de crear CxP.';end if;
    if not exists(select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice.id) then raise exception 'La factura de gasto no tiene conceptos.';end if;
  end if;
  update public.supplier_invoices set status='confirmed',confirmed_at=v_now,confirmed_by=auth.uid(),confirm_request_id=v_request,updated_by=auth.uid() where id=v_invoice.id;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,exchange_rate,base_currency_code,original_amount,outstanding_amount,original_base_amount,outstanding_base_amount,issued_date,due_date)
  values(p_company_id,v_invoice.supplier_id,v_invoice.id,v_invoice.currency_code,v_invoice.exchange_rate,v_invoice.base_currency_code,v_invoice.total,v_invoice.total,v_invoice.base_total,v_invoice.base_total,v_invoice.issued_date,v_invoice.due_date) returning id into v_payable;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.confirmed','supplier_invoice',v_invoice.id,jsonb_build_object('source_kind',v_invoice.source_kind,'purchase_order_id',v_invoice.purchase_order_id,'payable_id',v_payable,'total',v_invoice.total,'base_total',v_invoice.base_total,'client_request_id',v_request));
  return jsonb_build_object('invoice_id',v_invoice.id,'payable_id',v_payable,'status','confirmed','idempotent',false);
end $$;

create or replace function public.get_accounts_payable_aging(p_company_id uuid,p_as_of_date date default current_date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then raise exception 'No autorizado para consultar antigüedad de CxP.';end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.currency_code),'[]'::jsonb) into v_items from (
    select currency_code,count(*) document_count,round(sum(outstanding_amount),6) total,
      round(sum(outstanding_amount) filter(where due_date>=p_as_of_date),6) not_due,
      round(sum(outstanding_amount) filter(where p_as_of_date-due_date between 1 and 30),6) days_1_30,
      round(sum(outstanding_amount) filter(where p_as_of_date-due_date between 31 and 60),6) days_31_60,
      round(sum(outstanding_amount) filter(where p_as_of_date-due_date between 61 and 90),6) days_61_90,
      round(sum(outstanding_amount) filter(where p_as_of_date-due_date>90),6) days_over_90
    from public.accounts_payable where company_id=p_company_id and reversed_at is null and outstanding_amount>0 group by currency_code
  ) x;
  return jsonb_build_object('as_of_date',p_as_of_date,'items',v_items);
end $$;

create or replace function public.get_supplier_invoice_detail(p_company_id uuid,p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_invoices') then raise exception 'No autorizado para consultar facturas.';end if;
  select to_jsonb(si)||jsonb_build_object(
    'supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name,'tax_id',s.tax_id,'country_code',s.country_code),
    'purchase_order',case when po.id is null then null else jsonb_build_object('id',po.id,'folio',po.folio,'status',po.status) end,
    'receipts',(select coalesce(jsonb_agg(jsonb_build_object('id',pr.id,'folio',pr.folio,'status',pr.status,'receipt_date',pr.receipt_date) order by pr.receipt_date,pr.id),'[]'::jsonb) from public.supplier_invoice_receipts sir join public.purchase_receipts pr on pr.id=sir.purchase_receipt_id where sir.supplier_invoice_id=si.id),
    'lines',(select coalesce(jsonb_agg(to_jsonb(sil)||jsonb_build_object('purchase_receipt_folio',pr.folio,'line_number',pol.line_number,'description',pol.description,'previously_invoiced',coalesce((select sum(x.quantity) from public.supplier_invoice_lines x join public.supplier_invoices xi on xi.id=x.supplier_invoice_id where x.purchase_receipt_line_id=sil.purchase_receipt_line_id and xi.status='confirmed' and xi.id<>si.id),0),'available_quantity',sil.received_quantity-coalesce((select sum(x.quantity) from public.supplier_invoice_lines x join public.supplier_invoices xi on xi.id=x.supplier_invoice_id where x.purchase_receipt_line_id=sil.purchase_receipt_line_id and xi.status='confirmed'),0)) order by pol.line_number,pr.id),'[]'::jsonb) from public.supplier_invoice_lines sil join public.purchase_receipt_lines prl on prl.id=sil.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id join public.purchase_order_lines pol on pol.id=sil.purchase_order_line_id where sil.supplier_invoice_id=si.id),
    'expense_lines',(select coalesce(jsonb_agg(to_jsonb(el) order by el.line_number),'[]'::jsonb) from public.supplier_invoice_expense_lines el where el.supplier_invoice_id=si.id),
    'documents',(select coalesce(jsonb_agg(to_jsonb(d)-'storage_path'||jsonb_build_object('download_path',d.storage_path) order by d.created_at,d.id),'[]'::jsonb) from public.supplier_invoice_documents d where d.supplier_invoice_id=si.id),
    'payable',(select to_jsonb(ap)||jsonb_build_object('is_overdue',ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date,'days_overdue',greatest(current_date-ap.due_date,0),'condition',case when ap.reversed_at is not null then 'reversed' when ap.outstanding_amount=0 then 'settled' when ap.due_date<current_date then 'overdue' else 'not_due' end,'adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.occurred_at,a.id),'[]'::jsonb) from public.accounts_payable_adjustments a where a.accounts_payable_id=ap.id)) from public.accounts_payable ap where ap.supplier_invoice_id=si.id),
    'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at,a.id),'[]'::jsonb) from public.audit_log a where a.company_id=p_company_id and (a.entity_id=si.id or a.metadata->>'original_invoice_id'=si.id::text))
  ) into v_result from public.supplier_invoices si join public.suppliers s on s.id=si.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id where si.id=p_invoice_id and si.company_id=p_company_id;
  if v_result is null then raise exception 'Factura no encontrada.';end if;return v_result;
end $$;

create or replace function public.search_accounts_payable(p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_purchase_order_id uuid default null,p_receipt_id uuid default null,p_due_condition text default null,p_date_from date default null,p_date_to date default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then raise exception 'No autorizado para consultar CxP.';end if;
  with filtered as materialized(select ap.*,si.series,si.folio,si.purchase_order_id,si.source_kind,po.folio purchase_order_folio,s.display_name supplier_name from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id where ap.company_id=p_company_id and (p_supplier_id is null or ap.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or ap.issued_date>=p_date_from) and (p_date_to is null or ap.issued_date<=p_date_to) and (p_due_condition is null or p_due_condition='overdue' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date or p_due_condition='not_due' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date>=current_date) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(po.folio,'')) like '%'||v_query||'%')) select count(*) into v_total from filtered;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date,x.id),'[]'::jsonb) into v_items from (select ap.id,ap.supplier_id,ap.supplier_name,ap.supplier_invoice_id,concat_ws('-',ap.series,ap.folio) invoice_number,ap.purchase_order_id,ap.purchase_order_folio,ap.source_kind,ap.currency_code,ap.exchange_rate,ap.base_currency_code,ap.original_amount,ap.outstanding_amount,ap.original_base_amount,ap.outstanding_base_amount,ap.issued_date,ap.due_date,ap.reversed_at,greatest(current_date-ap.due_date,0) days_overdue,case when ap.reversed_at is not null then 'reversed' when ap.outstanding_amount=0 then 'settled' when ap.due_date<current_date then 'overdue' else 'not_due' end condition from (select ap.*,si.series,si.folio,si.purchase_order_id,si.source_kind,po.folio purchase_order_folio,s.display_name supplier_name from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id where ap.company_id=p_company_id and (p_supplier_id is null or ap.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or ap.issued_date>=p_date_from) and (p_date_to is null or ap.issued_date<=p_date_to) and (p_due_condition is null or p_due_condition='overdue' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date or p_due_condition='not_due' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date>=current_date) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(po.folio,'')) like '%'||v_query||'%'))ap order by ap.due_date,ap.id limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

revoke all on function public.save_supplier_invoice_v2(uuid,uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,uuid,timestamptz) from public;
revoke all on function public.save_supplier_expense_invoice(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,timestamptz) from public;
revoke all on function public.approve_supplier_expense_invoice(uuid,uuid,text) from public;
revoke all on function public.register_supplier_invoice_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) from public;
revoke all on function public.record_supplier_invoice_sat_verification(uuid,uuid,text,timestamptz,jsonb) from public;
revoke all on function public.get_accounts_payable_aging(uuid,date) from public;
grant execute on function public.save_supplier_invoice_v2(uuid,uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,uuid,timestamptz) to authenticated;
grant execute on function public.save_supplier_expense_invoice(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,timestamptz) to authenticated;
grant execute on function public.approve_supplier_expense_invoice(uuid,uuid,text) to authenticated;
grant execute on function public.register_supplier_invoice_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) to authenticated;
grant execute on function public.record_supplier_invoice_sat_verification(uuid,uuid,text,timestamptz,jsonb) to authenticated;
grant execute on function public.get_accounts_payable_aging(uuid,date) to authenticated;
