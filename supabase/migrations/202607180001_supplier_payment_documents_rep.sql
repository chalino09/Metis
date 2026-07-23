-- Satrapy · M3E3: comprobantes bancarios y REP recibido.
-- La evidencia se adjunta a pagos M3E2; nunca crea, revierte ni reaplica pagos.

insert into public.permissions(code,description) values
  ('manage_supplier_payment_documents','Adjuntar comprobantes bancarios y REP a pagos confirmados.'),
  ('verify_supplier_payment_rep_sat','Registrar verificaciones oficiales SAT de REP sin sustituir la validación local.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'manage_supplier_payment_documents','verify_supplier_payment_rep_sat'
) on conflict do nothing;

alter table public.supplier_payments
  add column rep_status text not null default 'not_required'
  check(rep_status in ('not_required','pending','received','differences'));

alter table public.supplier_payments
  add column payment_form_code text
  check(payment_form_code is null or payment_form_code~'^[0-9]{2}$');

update public.supplier_payments
set payment_form_code=substring(trim(payment_method) from '^([0-9]{2})')
where trim(payment_method)~'^[0-9]{2}';

create table public.supplier_payment_documents(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payment_id uuid not null references public.supplier_payments(id) on delete restrict,
  document_role text not null check(document_role in ('bank_receipt','rep_xml')),
  original_file_name text not null check(nullif(trim(original_file_name),'') is not null),
  storage_path text not null,
  mime_type text not null,
  size_bytes bigint not null check(size_bytes between 1 and 10485760),
  sha256 text not null check(sha256~'^[a-f0-9]{64}$'),
  fiscal_uuid text,
  extracted_data jsonb not null default '{}'::jsonb,
  local_validation_status text not null check(local_validation_status in ('not_applicable','verified_local','mismatch','unreadable')),
  local_validation_issues jsonb not null default '[]'::jsonb check(jsonb_typeof(local_validation_issues)='array'),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,sha256),
  unique(company_id,storage_path)
);
create unique index supplier_payment_rep_uuid_uidx on public.supplier_payment_documents(company_id,lower(fiscal_uuid)) where document_role='rep_xml';
create index supplier_payment_documents_payment_idx on public.supplier_payment_documents(payment_id,created_at,id);

create table public.supplier_payment_rep_sat_verifications(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payment_document_id uuid not null references public.supplier_payment_documents(id) on delete restrict,
  sat_status text not null check(sat_status in ('valid','cancelled','not_found')),
  checked_at timestamptz not null,
  evidence jsonb not null check(jsonb_typeof(evidence)='object'),
  checked_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index supplier_payment_rep_sat_latest_idx on public.supplier_payment_rep_sat_verifications(payment_document_id,checked_at desc,id desc);

create or replace function public.guard_supplier_payment_evidence_immutable()
returns trigger language plpgsql set search_path=public as $$
begin
  raise exception 'Los comprobantes y REP de pagos confirmados son inmutables.';
end $$;
create trigger supplier_payment_documents_immutable before update or delete on public.supplier_payment_documents for each row execute function public.guard_supplier_payment_evidence_immutable();
create trigger supplier_payment_rep_sat_immutable before update or delete on public.supplier_payment_rep_sat_verifications for each row execute function public.guard_supplier_payment_evidence_immutable();

create or replace function public.capture_supplier_payment_form_code()
returns trigger language plpgsql set search_path=public as $$
begin
  new.payment_form_code:=substring(trim(new.payment_method) from '^([0-9]{2})');
  return new;
end $$;
create trigger supplier_payment_capture_form before insert on public.supplier_payments for each row execute function public.capture_supplier_payment_form_code();

create or replace function public.supplier_rep_numeric(p_value text)
returns numeric language sql immutable set search_path=public as $$
  select case when trim(coalesce(p_value,''))~'^[-+]?[0-9]+([.][0-9]+)?$' then trim(p_value)::numeric else null end
$$;
create or replace function public.supplier_rep_integer(p_value text)
returns integer language sql immutable set search_path=public as $$
  select case when trim(coalesce(p_value,''))~'^[0-9]+$' and length(trim(p_value))<=9 then trim(p_value)::integer else null end
$$;
create or replace function public.supplier_rep_date(p_value text)
returns date language plpgsql immutable set search_path=public as $$
begin
  if left(coalesce(p_value,''),10)!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return null;end if;
  begin return left(p_value,10)::date;exception when others then return null;end;
end $$;

alter table public.supplier_payment_documents enable row level security;
alter table public.supplier_payment_rep_sat_verifications enable row level security;
create policy supplier_payment_documents_read on public.supplier_payment_documents for select to authenticated
using(public.has_company_permission(company_id,'view_supplier_payments'));
create policy supplier_payment_rep_sat_read on public.supplier_payment_rep_sat_verifications for select to authenticated
using(public.has_company_permission(company_id,'view_supplier_payments'));

do $$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    execute $sql$insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values('supplier-payment-documents','supplier-payment-documents',false,10485760,array['application/xml','text/xml','application/pdf','image/jpeg','image/png'])
      on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types$sql$;
    execute $sql$create policy supplier_payment_documents_storage_read on storage.objects for select to authenticated
      using(bucket_id='supplier-payment-documents' and public.has_company_permission(((storage.foldername(name))[1])::uuid,'view_supplier_payments'))$sql$;
    execute $sql$create policy supplier_payment_documents_storage_insert on storage.objects for insert to authenticated
      with check(bucket_id='supplier-payment-documents' and public.has_company_permission(((storage.foldername(name))[1])::uuid,'manage_supplier_payment_documents'))$sql$;
  end if;
end $$;

create or replace function public.set_supplier_payment_rep_pending()
returns trigger language plpgsql set search_path=public as $$
begin
  if exists(select 1 from public.supplier_invoices where id=new.supplier_invoice_id and payment_method_code='PPD') then
    update public.supplier_payments set rep_status='pending' where id=new.payment_id and rep_status='not_required';
  end if;
  return new;
end $$;
create trigger supplier_payment_application_rep_pending after insert on public.supplier_payment_applications for each row execute function public.set_supplier_payment_rep_pending();

update public.supplier_payments p set rep_status='pending'
where exists(
  select 1 from public.supplier_payment_applications a join public.supplier_invoices i on i.id=a.supplier_invoice_id
  where a.payment_id=p.id and i.payment_method_code='PPD'
);

create or replace function public.check_supplier_payment_document_duplicate(p_company_id uuid,p_sha256 text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_document public.supplier_payment_documents%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_payment_documents') then raise exception 'No autorizado para administrar comprobantes de pago.';end if;
  if p_document_role='rep_xml' and coalesce(current_setting('satrapy.rep_server_validated',true),'')<>'on' then raise exception 'El REP debe validarse desde el XML original en servidor.';end if;
  if lower(trim(coalesce(p_sha256,'')))!~'^[a-f0-9]{64}$' then raise exception 'SHA-256 inválido.';end if;
  select * into v_document from public.supplier_payment_documents where company_id=p_company_id and sha256=lower(trim(p_sha256));
  if not found then return jsonb_build_object('duplicate',false);end if;
  return jsonb_build_object('duplicate',true,'document_id',v_document.id,'payment_id',v_document.payment_id,'document_role',v_document.document_role);
end $$;

create or replace function public.register_supplier_payment_rep_xml(
  p_company_id uuid,p_payment_id uuid,p_original_file_name text,p_storage_path text,p_mime_type text,
  p_size_bytes bigint,p_sha256 text,p_file_base64 text
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_bytes bytea;v_xml xml;v_ns text[][]:=array[
    array['cfdi','http://www.sat.gob.mx/cfd/4'],array['pago20','http://www.sat.gob.mx/Pagos20'],array['tfd','http://www.sat.gob.mx/TimbreFiscalDigital']
  ];v_extracted jsonb;v_payment_nodes xml[];v_payment xml;v_related jsonb;v_doc xml;
  v_text text;v_actual_hash text;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_payment_documents') then raise exception 'No autorizado para administrar comprobantes de pago.';end if;
  if lower(trim(coalesce(p_mime_type,''))) not in ('application/xml','text/xml') or coalesce(p_size_bytes,0) not between 1 and 5242880 then raise exception 'El REP debe ser XML y pesar hasta 5 MB.';end if;
  begin v_bytes:=decode(coalesce(p_file_base64,''),'base64');exception when others then raise exception 'El contenido base64 del REP es inválido.';end;
  if octet_length(v_bytes)<>p_size_bytes then raise exception 'El tamaño del REP no coincide con el archivo recibido.';end if;
  v_actual_hash:=encode(digest(v_bytes,'sha256'),'hex');
  if v_actual_hash<>lower(trim(coalesce(p_sha256,''))) then raise exception 'El SHA-256 del REP no coincide con su contenido.';end if;
  begin v_text:=convert_from(v_bytes,'UTF8');v_xml:=xmlparse(document v_text);exception when others then raise exception 'El XML del REP no es legible o no está codificado en UTF-8.';end;
  v_payment_nodes:=xpath('/cfdi:Comprobante/cfdi:Complemento/pago20:Pagos/pago20:Pago',v_xml,v_ns);
  if coalesce(array_length(v_payment_nodes,1),0)<>1 then raise exception 'El REP debe contener exactamente un evento Pago 2.0.';end if;
  v_payment:=v_payment_nodes[1];v_related:='[]'::jsonb;
  foreach v_doc in array xpath('/pago20:Pago/pago20:DoctoRelacionado',v_payment,v_ns) loop
    v_related:=v_related||jsonb_build_array(jsonb_build_object(
      'document_uuid',(xpath('string(/pago20:DoctoRelacionado/@IdDocumento)',v_doc,v_ns))[1]::text,
      'currency',(xpath('string(/pago20:DoctoRelacionado/@MonedaDR)',v_doc,v_ns))[1]::text,
      'equivalence',(xpath('string(/pago20:DoctoRelacionado/@EquivalenciaDR)',v_doc,v_ns))[1]::text,
      'partiality',(xpath('string(/pago20:DoctoRelacionado/@NumParcialidad)',v_doc,v_ns))[1]::text,
      'previous_balance',(xpath('string(/pago20:DoctoRelacionado/@ImpSaldoAnt)',v_doc,v_ns))[1]::text,
      'paid_amount',(xpath('string(/pago20:DoctoRelacionado/@ImpPagado)',v_doc,v_ns))[1]::text,
      'remaining_balance',(xpath('string(/pago20:DoctoRelacionado/@ImpSaldoInsoluto)',v_doc,v_ns))[1]::text
    ));
  end loop;
  v_extracted:=jsonb_build_object(
    'cfdi_version',(xpath('string(/cfdi:Comprobante/@Version)',v_xml,v_ns))[1]::text,
    'complement_version',(xpath('string(/cfdi:Comprobante/cfdi:Complemento/pago20:Pagos/@Version)',v_xml,v_ns))[1]::text,
    'document_type',(xpath('string(/cfdi:Comprobante/@TipoDeComprobante)',v_xml,v_ns))[1]::text,
    'currency',(xpath('string(/cfdi:Comprobante/@Moneda)',v_xml,v_ns))[1]::text,
    'total',(xpath('string(/cfdi:Comprobante/@Total)',v_xml,v_ns))[1]::text,
    'issued_at',(xpath('string(/cfdi:Comprobante/@Fecha)',v_xml,v_ns))[1]::text,
    'uuid',(xpath('string(/cfdi:Comprobante/cfdi:Complemento/tfd:TimbreFiscalDigital/@UUID)',v_xml,v_ns))[1]::text,
    'issuer_rfc',(xpath('string(/cfdi:Comprobante/cfdi:Emisor/@Rfc)',v_xml,v_ns))[1]::text,
    'receiver_rfc',(xpath('string(/cfdi:Comprobante/cfdi:Receptor/@Rfc)',v_xml,v_ns))[1]::text,
    'payment',jsonb_build_object(
      'date',(xpath('string(/pago20:Pago/@FechaPago)',v_payment,v_ns))[1]::text,
      'payment_form',(xpath('string(/pago20:Pago/@FormaDePagoP)',v_payment,v_ns))[1]::text,
      'currency',(xpath('string(/pago20:Pago/@MonedaP)',v_payment,v_ns))[1]::text,
      'exchange_rate',(xpath('string(/pago20:Pago/@TipoCambioP)',v_payment,v_ns))[1]::text,
      'amount',(xpath('string(/pago20:Pago/@Monto)',v_payment,v_ns))[1]::text
    ),'related_documents',v_related
  );
  perform set_config('satrapy.rep_server_validated','on',true);
  v_result:=public.register_supplier_payment_document(p_company_id,p_payment_id,'rep_xml',p_original_file_name,p_storage_path,p_mime_type,p_size_bytes,p_sha256,v_extracted);
  perform set_config('satrapy.rep_server_validated','off',true);
  return v_result;
end $$;

create or replace function public.register_supplier_payment_document(
  p_company_id uuid,p_payment_id uuid,p_document_role text,p_original_file_name text,p_storage_path text,
  p_mime_type text,p_size_bytes bigint,p_sha256 text,p_extracted_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_payment public.supplier_payments%rowtype;v_supplier public.suppliers%rowtype;v_company public.companies%rowtype;
  v_existing public.supplier_payment_documents%rowtype;v_id uuid;v_status text:='not_applicable';v_issues jsonb:='[]'::jsonb;
  v_uuid text;v_event jsonb;v_docs jsonb;v_doc jsonb;v_app record;v_match jsonb;v_expected_partiality integer;
  v_mime text:=lower(trim(coalesce(p_mime_type,'')));v_hash text:=lower(trim(coalesce(p_sha256,'')));
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_payment_documents') then raise exception 'No autorizado para administrar comprobantes de pago.';end if;
  if p_document_role not in ('bank_receipt','rep_xml') or nullif(trim(coalesce(p_storage_path,'')),'') is null or v_hash!~'^[a-f0-9]{64}$' or coalesce(p_size_bytes,0) not between 1 and 10485760 then raise exception 'Metadatos de documento inválidos.';end if;
  if p_document_role='rep_xml' and v_mime not in ('application/xml','text/xml') then raise exception 'El REP debe recibirse como XML.';end if;
  if p_document_role='bank_receipt' and v_mime not in ('application/pdf','image/jpeg','image/png') then raise exception 'El comprobante bancario debe ser PDF, JPEG o PNG.';end if;
  select * into v_payment from public.supplier_payments where id=p_payment_id and company_id=p_company_id for update;
  if not found or v_payment.status<>'confirmed' then raise exception 'Sólo se puede adjuntar evidencia a un pago confirmado.';end if;
  select * into v_supplier from public.suppliers where id=v_payment.supplier_id;
  select * into v_company from public.companies where id=p_company_id;
  select * into v_existing from public.supplier_payment_documents where company_id=p_company_id and sha256=v_hash;
  if found then
    if v_existing.payment_id=p_payment_id and v_existing.document_role=p_document_role then return jsonb_build_object('id',v_existing.id,'status',v_existing.local_validation_status,'issues',v_existing.local_validation_issues,'idempotent',true);end if;
    raise exception 'El mismo archivo ya pertenece a otro expediente de pago.';
  end if;

  if p_document_role='rep_xml' then
    v_status:='verified_local';v_uuid:=lower(trim(coalesce(p_extracted_data->>'uuid','')));v_event:=p_extracted_data->'payment';v_docs:=p_extracted_data->'related_documents';
    if coalesce(p_extracted_data->>'cfdi_version','')<>'4.0' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','cfdi_version','expected','4.0','actual',p_extracted_data->>'cfdi_version'));end if;
    if coalesce(p_extracted_data->>'complement_version','')<>'2.0' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','complement_version','expected','2.0','actual',p_extracted_data->>'complement_version'));end if;
    if coalesce(p_extracted_data->>'document_type','')<>'P' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','document_type','expected','P','actual',p_extracted_data->>'document_type'));end if;
    if upper(coalesce(p_extracted_data->>'currency',''))<>'XXX' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','cfdi_currency','expected','XXX','actual',p_extracted_data->>'currency'));end if;
    if abs(coalesce(public.supplier_rep_numeric(p_extracted_data->>'total'),-1))>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','cfdi_total','expected',0,'actual',p_extracted_data->>'total'));end if;
    if public.supplier_rep_date(p_extracted_data->>'issued_at') is null or public.supplier_rep_date(p_extracted_data->>'issued_at')<v_payment.effective_date then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','issued_at','expected','Fecha válida igual o posterior al pago','actual',p_extracted_data->>'issued_at'));end if;
    if v_uuid!~'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','uuid','expected','UUID fiscal válido','actual',nullif(v_uuid,'')));end if;
    if upper(coalesce(p_extracted_data->>'issuer_rfc',''))!~'^[A-Z&Ñ]{3,4}[0-9]{6}[A-Z0-9]{3}$' or (v_supplier.tax_id is not null and upper(p_extracted_data->>'issuer_rfc')<>upper(v_supplier.tax_id)) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','issuer_rfc','expected',v_supplier.tax_id,'actual',p_extracted_data->>'issuer_rfc'));end if;
    if upper(coalesce(p_extracted_data->>'receiver_rfc',''))!~'^[A-Z&Ñ]{3,4}[0-9]{6}[A-Z0-9]{3}$' or (v_company.tax_id is not null and upper(p_extracted_data->>'receiver_rfc')<>upper(v_company.tax_id)) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','receiver_rfc','expected',v_company.tax_id,'actual',p_extracted_data->>'receiver_rfc'));end if;
    if jsonb_typeof(v_event) is distinct from 'object' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','payment','expected','Un pago en complemento 2.0','actual',null));v_event:='{}'::jsonb;end if;
    if left(coalesce(v_event->>'date',''),10) is distinct from v_payment.effective_date::text then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','payment_date','expected',v_payment.effective_date,'actual',v_event->>'date'));end if;
    if upper(coalesce(v_event->>'currency',''))<>v_payment.currency_code then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','payment_currency','expected',v_payment.currency_code,'actual',v_event->>'currency'));end if;
    if abs(coalesce(public.supplier_rep_numeric(v_event->>'amount'),-1)-v_payment.total_amount)>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','payment_amount','expected',v_payment.total_amount,'actual',v_event->>'amount'));end if;
    if coalesce(v_event->>'payment_form','')!~'^[0-9]{2}$' or v_payment.payment_form_code is null or v_event->>'payment_form'<>v_payment.payment_form_code then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','payment_form','expected',v_payment.payment_form_code,'actual',v_event->>'payment_form'));end if;
    if jsonb_typeof(v_docs) is distinct from 'array' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','related_documents','expected','Arreglo no vacío','actual',jsonb_typeof(v_docs)));v_docs:='[]'::jsonb;end if;
    if coalesce((select sum(coalesce(public.supplier_rep_numeric(d->>'paid_amount'),0)) from jsonb_array_elements(v_docs)d),0)<>v_payment.total_amount then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','related_paid_total','expected',v_payment.total_amount,'actual',(select coalesce(sum(coalesce(public.supplier_rep_numeric(d->>'paid_amount'),0)),0) from jsonb_array_elements(v_docs)d)));end if;

    for v_app in
      select a.*,i.fiscal_uuid invoice_uuid,i.currency_code invoice_currency,i.payment_method_code,
        (select count(*) from public.supplier_payment_applications pa join public.supplier_payments pp on pp.id=pa.payment_id where pa.supplier_invoice_id=a.supplier_invoice_id and pp.status='confirmed' and (pp.confirmed_at< v_payment.confirmed_at or (pp.confirmed_at=v_payment.confirmed_at and pp.id<=v_payment.id))) expected_partiality
      from public.supplier_payment_applications a join public.supplier_invoices i on i.id=a.supplier_invoice_id where a.payment_id=p_payment_id order by a.id
    loop
      if v_app.payment_method_code is distinct from 'PPD' then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','invoice_payment_method','invoice_id',v_app.supplier_invoice_id,'expected','PPD','actual',v_app.payment_method_code));end if;
      if v_app.invoice_uuid is null then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','invoice_uuid','invoice_id',v_app.supplier_invoice_id,'expected','UUID fiscal de factura','actual',null));continue;end if;
      select d into v_match from jsonb_array_elements(v_docs)d where lower(coalesce(d->>'document_uuid',''))=lower(v_app.invoice_uuid) limit 1;
      if v_match is null then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','related_document','invoice_uuid',v_app.invoice_uuid,'expected','Documento relacionado','actual',null));continue;end if;
      if (select count(*) from jsonb_array_elements(v_docs)d where lower(coalesce(d->>'document_uuid',''))=lower(v_app.invoice_uuid))<>1 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','related_document_duplicate','invoice_uuid',v_app.invoice_uuid,'expected',1,'actual',(select count(*) from jsonb_array_elements(v_docs)d where lower(coalesce(d->>'document_uuid',''))=lower(v_app.invoice_uuid))));end if;
      v_expected_partiality:=v_app.expected_partiality;
      if upper(coalesce(v_match->>'currency',''))<>v_app.invoice_currency then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','document_currency','invoice_uuid',v_app.invoice_uuid,'expected',v_app.invoice_currency,'actual',v_match->>'currency'));end if;
      if abs(coalesce(public.supplier_rep_numeric(v_match->>'equivalence'),-1)-1)>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','equivalence','invoice_uuid',v_app.invoice_uuid,'expected',1,'actual',v_match->>'equivalence'));end if;
      if coalesce(public.supplier_rep_integer(v_match->>'partiality'),0)<>v_expected_partiality then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','partiality','invoice_uuid',v_app.invoice_uuid,'expected',v_expected_partiality,'actual',v_match->>'partiality'));end if;
      if abs(coalesce(public.supplier_rep_numeric(v_match->>'previous_balance'),-1)-v_app.balance_before)>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','previous_balance','invoice_uuid',v_app.invoice_uuid,'expected',v_app.balance_before,'actual',v_match->>'previous_balance'));end if;
      if abs(coalesce(public.supplier_rep_numeric(v_match->>'paid_amount'),-1)-v_app.amount)>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','paid_amount','invoice_uuid',v_app.invoice_uuid,'expected',v_app.amount,'actual',v_match->>'paid_amount'));end if;
      if abs(coalesce(public.supplier_rep_numeric(v_match->>'remaining_balance'),-1)-v_app.balance_after)>0.000001 then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','remaining_balance','invoice_uuid',v_app.invoice_uuid,'expected',v_app.balance_after,'actual',v_match->>'remaining_balance'));end if;
    end loop;
    for v_doc in select * from jsonb_array_elements(v_docs) loop
      if not exists(select 1 from public.supplier_payment_applications a join public.supplier_invoices i on i.id=a.supplier_invoice_id where a.payment_id=p_payment_id and lower(i.fiscal_uuid)=lower(v_doc->>'document_uuid')) then v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','unexpected_related_document','actual',v_doc->>'document_uuid'));end if;
    end loop;
    if jsonb_array_length(v_issues)>0 then v_status:='mismatch';end if;
  end if;

  insert into public.supplier_payment_documents(company_id,payment_id,document_role,original_file_name,storage_path,mime_type,size_bytes,sha256,fiscal_uuid,extracted_data,local_validation_status,local_validation_issues)
  values(p_company_id,p_payment_id,p_document_role,trim(p_original_file_name),trim(p_storage_path),v_mime,p_size_bytes,v_hash,case when p_document_role='rep_xml' then nullif(v_uuid,'') else null end,coalesce(p_extracted_data,'{}'::jsonb),v_status,v_issues) returning id into v_id;
  if p_document_role='rep_xml' then update public.supplier_payments set rep_status=case when v_status='verified_local' then 'received' else 'differences' end where id=p_payment_id;end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_document_role='rep_xml' then 'supplier_payment.rep_received' else 'supplier_payment.bank_receipt_attached' end,'supplier_payment',p_payment_id,jsonb_build_object('document_id',v_id,'sha256',v_hash,'local_validation_status',v_status,'local_validation_issues',v_issues));
  return jsonb_build_object('id',v_id,'status',v_status,'issues',v_issues,'rep_status',case when p_document_role='rep_xml' then case when v_status='verified_local' then 'received' else 'differences' end else v_payment.rep_status end,'idempotent',false);
exception when unique_violation then raise exception 'El archivo o UUID fiscal ya fue registrado.';
end $$;

create or replace function public.record_supplier_payment_rep_sat_verification(
  p_company_id uuid,p_document_id uuid,p_status text,p_checked_at timestamptz,p_evidence jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_document public.supplier_payment_documents%rowtype;v_id uuid;v_rep_status text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'verify_supplier_payment_rep_sat') then raise exception 'No autorizado para registrar verificación SAT.';end if;
  if p_status not in ('valid','cancelled','not_found') or p_checked_at is null or jsonb_typeof(p_evidence) is distinct from 'object' or p_evidence='{}'::jsonb then raise exception 'La verificación SAT requiere estado, fecha y evidencia.';end if;
  select * into v_document from public.supplier_payment_documents where id=p_document_id and company_id=p_company_id and document_role='rep_xml';
  if not found then raise exception 'REP no encontrado.';end if;
  insert into public.supplier_payment_rep_sat_verifications(company_id,payment_document_id,sat_status,checked_at,evidence) values(p_company_id,p_document_id,p_status,p_checked_at,p_evidence) returning id into v_id;
  v_rep_status:=case when p_status='valid' and v_document.local_validation_status='verified_local' then 'received' else 'differences' end;
  update public.supplier_payments set rep_status=v_rep_status where id=v_document.payment_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_payment.rep_sat_verification_recorded','supplier_payment',v_document.payment_id,jsonb_build_object('document_id',p_document_id,'verification_id',v_id,'sat_status',p_status,'checked_at',p_checked_at,'rep_status',v_rep_status));
  return jsonb_build_object('id',v_id,'document_id',p_document_id,'sat_status',p_status,'rep_status',v_rep_status);
end $$;

create or replace function public.search_supplier_payments(
  p_company_id uuid,p_query text default null,p_status text default null,p_supplier_id uuid default null,p_currency_code text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_payments') then raise exception 'No autorizado para consultar pagos.';end if;
  if p_status is not null and p_status not in ('confirmed','reversed') then raise exception 'Estado de pago inválido.';end if;
  select count(*) into v_total from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code))) and (v_query='' or lower(p.reference) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.effective_date desc,x.id desc),'[]'::jsonb) into v_items from (
    select p.id,p.proposal_id,p.supplier_id,s.code supplier_code,s.display_name supplier_name,p.currency_code,p.effective_date,p.payment_method,p.payment_form_code,p.reference,p.total_amount,p.status,p.rep_status,p.reconciliation_status,p.confirmed_at,p.reversed_at,a.alias account_alias,a.bank_name,'•••• '||a.account_last4 masked_ending,count(pa.id) application_count
    from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id join public.supplier_paying_accounts a on a.id=p.paying_account_id left join public.supplier_payment_applications pa on pa.payment_id=p.id
    where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code))) and (v_query='' or lower(p.reference) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
    group by p.id,s.id,a.id order by p.effective_date desc,p.id desc limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_supplier_payment_detail(p_company_id uuid,p_payment_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_payments') then raise exception 'No autorizado para consultar pagos.';end if;
  select to_jsonb(p)||jsonb_build_object(
    'supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name,'tax_id',s.tax_id),
    'paying_account',jsonb_build_object('id',a.id,'bank_name',a.bank_name,'alias',a.alias,'currency_code',a.currency_code,'masked_ending','•••• '||a.account_last4),
    'applications',(select coalesce(jsonb_agg(to_jsonb(pa)||jsonb_build_object('invoice_number',concat_ws('-',si.series,si.folio),'invoice_uuid',si.fiscal_uuid,'payment_method_code',si.payment_method_code,'due_date',ap.due_date,'current_balance',ap.outstanding_amount) order by ap.due_date,pa.id),'[]'::jsonb) from public.supplier_payment_applications pa join public.accounts_payable ap on ap.id=pa.accounts_payable_id join public.supplier_invoices si on si.id=pa.supplier_invoice_id where pa.payment_id=p.id),
    'documents',(select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('download_path',d.storage_path,'sat_verification',(select to_jsonb(v) from public.supplier_payment_rep_sat_verifications v where v.payment_document_id=d.id order by v.checked_at desc,v.id desc limit 1)) order by d.created_at,d.id),'[]'::jsonb) from public.supplier_payment_documents d where d.payment_id=p.id),
    'audit',(select coalesce(jsonb_agg(to_jsonb(al) order by al.created_at,al.id),'[]'::jsonb) from public.audit_log al where al.company_id=p_company_id and al.entity_type='supplier_payment' and al.entity_id=p.id)
  ) into v_result from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id join public.supplier_paying_accounts a on a.id=p.paying_account_id where p.id=p_payment_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Pago no encontrado.';end if;
  return v_result;
end $$;

revoke all on table public.supplier_payment_documents,public.supplier_payment_rep_sat_verifications from anon,authenticated;
grant select on table public.supplier_payment_documents,public.supplier_payment_rep_sat_verifications to authenticated;
revoke all on function public.check_supplier_payment_document_duplicate(uuid,text) from public;
revoke all on function public.register_supplier_payment_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) from public;
revoke all on function public.register_supplier_payment_rep_xml(uuid,uuid,text,text,text,bigint,text,text) from public;
revoke all on function public.record_supplier_payment_rep_sat_verification(uuid,uuid,text,timestamptz,jsonb) from public;
grant execute on function public.check_supplier_payment_document_duplicate(uuid,text) to authenticated;
grant execute on function public.register_supplier_payment_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) to authenticated;
grant execute on function public.register_supplier_payment_rep_xml(uuid,uuid,text,text,text,bigint,text,text) to authenticated;
grant execute on function public.record_supplier_payment_rep_sat_verification(uuid,uuid,text,timestamptz,jsonb) to authenticated;
