-- Satrapy · M3D closure: CFDI 4.0 concepts for expense/service invoices.
-- XML remains the authoritative fiscal source; manual entry is an exceptional fallback.

alter table public.supplier_invoices
  add column if not exists withholding_total numeric(18,6) not null default 0;
alter table public.supplier_invoices drop constraint if exists supplier_invoices_withholding_total_check;
alter table public.supplier_invoices add constraint supplier_invoices_withholding_total_check check(withholding_total>=0);

alter table public.supplier_invoice_expense_lines
  add column if not exists product_service_code text,
  add column if not exists identification_number text,
  add column if not exists quantity numeric(18,6) not null default 1,
  add column if not exists unit_code text,
  add column if not exists unit_name text,
  add column if not exists unit_value numeric(18,6) not null default 0,
  add column if not exists tax_object_code text,
  add column if not exists withheld_tax_amount numeric(18,6) not null default 0,
  add column if not exists tax_details jsonb not null default '[]'::jsonb,
  add column if not exists expense_category text,
  add column if not exists cost_center_reference text,
  add column if not exists project_reference text;

update public.supplier_invoice_expense_lines
set unit_value=case when quantity>0 then round(subtotal/quantity,6) else subtotal end
where unit_value=0 and subtotal>0;

alter table public.supplier_invoice_expense_lines drop constraint if exists supplier_invoice_expense_lines_quantity_check;
alter table public.supplier_invoice_expense_lines add constraint supplier_invoice_expense_lines_quantity_check check(quantity>0);
alter table public.supplier_invoice_expense_lines drop constraint if exists supplier_invoice_expense_lines_unit_value_check;
alter table public.supplier_invoice_expense_lines add constraint supplier_invoice_expense_lines_unit_value_check check(unit_value>=0);
alter table public.supplier_invoice_expense_lines drop constraint if exists supplier_invoice_expense_lines_withheld_tax_check;
alter table public.supplier_invoice_expense_lines add constraint supplier_invoice_expense_lines_withheld_tax_check check(withheld_tax_amount>=0);
alter table public.supplier_invoice_expense_lines drop constraint if exists supplier_invoice_expense_lines_tax_details_check;
alter table public.supplier_invoice_expense_lines add constraint supplier_invoice_expense_lines_tax_details_check check(jsonb_typeof(tax_details)='array');
alter table public.supplier_invoice_expense_lines drop column total;
alter table public.supplier_invoice_expense_lines add column total numeric(18,6)
  generated always as (round(subtotal-discount_amount+tax_amount-withheld_tax_amount,6)) stored;

create or replace function public.save_supplier_expense_invoice(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_series text,p_folio text,p_fiscal_uuid text,
  p_issued_date date,p_due_date date,p_currency_code text,p_exchange_rate numeric,p_supplier_reference text,
  p_payment_method_code text,p_payment_form_code text,p_lines jsonb,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.supplier_invoices%rowtype;v_supplier public.suppliers%rowtype;v_line jsonb;v_id uuid;
  v_subtotal numeric:=0;v_discount numeric:=0;v_transferred numeric:=0;v_withheld numeric:=0;v_total numeric:=0;
  v_line_subtotal numeric;v_line_discount numeric;v_line_transferred numeric;v_line_withheld numeric;v_tax_details jsonb;
  v_base text;v_rate numeric;v_duplicate uuid;v_number int:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_expense_invoices') then raise exception 'No autorizado para administrar facturas de gasto.';end if;
  if nullif(trim(coalesce(p_folio,'')),'') is null or p_due_date<p_issued_date or upper(trim(coalesce(p_currency_code,'')))!~'^[A-Z]{3}$' then raise exception 'Identidad, fechas o moneda inválidas.';end if;
  if trim(coalesce(p_payment_method_code,'')) not in ('PUE','PPD') or trim(coalesce(p_payment_form_code,''))!~'^[0-9]{2}$' then raise exception 'Método o forma CFDI inválidos.';end if;
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
    if trim(coalesce(v_line->>'product_service_code',''))!~'^[0-9]{8}$'
      or nullif(trim(coalesce(v_line->>'unit_code','')),'') is null
      or nullif(trim(coalesce(v_line->>'description','')),'') is null
      or trim(coalesce(v_line->>'tax_object_code',''))!~'^[0-9]{2}$'
      or coalesce((v_line->>'quantity')::numeric,0)<=0
      or coalesce((v_line->>'unit_value')::numeric,-1)<0
      or jsonb_typeof(coalesce(v_line->'tax_details','[]'::jsonb))<>'array'
    then raise exception 'Cada concepto requiere clave SAT, cantidad, unidad, descripción, valor unitario y objeto de impuesto.';end if;
    v_line_subtotal:=coalesce((v_line->>'subtotal')::numeric,round((v_line->>'quantity')::numeric*(v_line->>'unit_value')::numeric,6));
    v_line_discount:=coalesce((v_line->>'discount_amount')::numeric,0);
    v_line_transferred:=coalesce((v_line->>'transferred_tax_amount')::numeric,(v_line->>'tax_amount')::numeric,0);
    v_line_withheld:=coalesce((v_line->>'withheld_tax_amount')::numeric,0);
    v_tax_details:=coalesce(v_line->'tax_details','[]'::jsonb);
    if v_line_subtotal<0 or v_line_discount<0 or v_line_transferred<0 or v_line_withheld<0 or v_line_discount>v_line_subtotal then raise exception 'Importes fiscales de concepto inválidos.';end if;
    if coalesce((select sum((tax->>'amount')::numeric) from jsonb_array_elements(v_tax_details) tax where tax->>'kind'='transferred'),0)<>v_line_transferred
      or coalesce((select sum((tax->>'amount')::numeric) from jsonb_array_elements(v_tax_details) tax where tax->>'kind'='withheld'),0)<>v_line_withheld
      or exists(select 1 from jsonb_array_elements(v_tax_details) tax where tax->>'kind' not in ('transferred','withheld') or coalesce(tax->>'tax_code','')!~'^[0-9]{3}$' or tax->>'factor_type' not in ('Tasa','Cuota','Exento') or coalesce((tax->>'base')::numeric,-1)<0 or coalesce((tax->>'amount')::numeric,-1)<0)
    then raise exception 'El desglose de impuestos no coincide con los importes del concepto.';end if;
    v_subtotal:=v_subtotal+v_line_subtotal;v_discount:=v_discount+v_line_discount;v_transferred:=v_transferred+v_line_transferred;v_withheld:=v_withheld+v_line_withheld;
  end loop;
  v_total:=round(v_subtotal-v_discount+v_transferred-v_withheld,6);
  if v_total<0 then raise exception 'El total de la factura no puede ser negativo.';end if;
  select id into v_duplicate from public.supplier_invoices where company_id=p_company_id and supplier_id=p_supplier_id and document_type='invoice' and id<>v_id and ((nullif(trim(coalesce(p_fiscal_uuid,'')),'') is not null and lower(fiscal_uuid)=lower(trim(p_fiscal_uuid))) or (nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null and fiscal_uuid is null and lower(coalesce(series,''))=lower(coalesce(trim(p_series),'')) and lower(folio)=lower(trim(p_folio)) and issued_date=p_issued_date and total=v_total)) limit 1;
  if v_duplicate is not null then
    insert into public.supplier_invoice_exceptions(company_id,supplier_id,kind,evidence) values(p_company_id,p_supplier_id,case when nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null then 'duplicate_identity' else 'duplicate_uuid' end,jsonb_build_object('candidate_invoice_id',v_duplicate,'series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid,'issued_date',p_issued_date,'total',v_total,'source_kind','expense'));
    return jsonb_build_object('status','exception','kind',case when nullif(trim(coalesce(p_fiscal_uuid,'')),'') is null then 'duplicate_identity' else 'duplicate_uuid' end,'duplicate_invoice_id',v_duplicate);
  end if;
  if p_invoice_id is null then
    insert into public.supplier_invoices(id,company_id,supplier_id,source_kind,series,folio,fiscal_uuid,issued_date,due_date,currency_code,exchange_rate,base_currency_code,supplier_reference,payment_method_code,payment_form_code,subtotal,discount_total,tax_total,withholding_total,total,base_total)
    values(v_id,p_company_id,p_supplier_id,'expense',nullif(trim(p_series),''),trim(p_folio),nullif(lower(trim(p_fiscal_uuid)),''),p_issued_date,p_due_date,upper(trim(p_currency_code)),v_rate,v_base,nullif(trim(p_supplier_reference),''),trim(p_payment_method_code),trim(p_payment_form_code),v_subtotal,v_discount,v_transferred,v_withheld,v_total,round(v_total*v_rate,6));
  else
    delete from public.supplier_invoice_expense_lines where supplier_invoice_id=v_id;
    update public.supplier_invoices set supplier_id=p_supplier_id,series=nullif(trim(p_series),''),folio=trim(p_folio),fiscal_uuid=nullif(lower(trim(p_fiscal_uuid)),''),issued_date=p_issued_date,due_date=p_due_date,currency_code=upper(trim(p_currency_code)),exchange_rate=v_rate,base_currency_code=v_base,supplier_reference=nullif(trim(p_supplier_reference),''),payment_method_code=trim(p_payment_method_code),payment_form_code=trim(p_payment_form_code),subtotal=v_subtotal,discount_total=v_discount,tax_total=v_transferred,withholding_total=v_withheld,total=v_total,base_total=round(v_total*v_rate,6),expense_approved_at=null,expense_approved_by=null,expense_approval_reason=null,updated_by=auth.uid() where id=v_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_number:=v_number+1;
    v_line_subtotal:=coalesce((v_line->>'subtotal')::numeric,round((v_line->>'quantity')::numeric*(v_line->>'unit_value')::numeric,6));
    v_line_discount:=coalesce((v_line->>'discount_amount')::numeric,0);
    v_line_transferred:=coalesce((v_line->>'transferred_tax_amount')::numeric,(v_line->>'tax_amount')::numeric,0);
    v_line_withheld:=coalesce((v_line->>'withheld_tax_amount')::numeric,0);
    insert into public.supplier_invoice_expense_lines(company_id,supplier_invoice_id,line_number,product_service_code,identification_number,quantity,unit_code,unit_name,description,unit_value,subtotal,discount_amount,tax_amount,withheld_tax_amount,tax_object_code,tax_details,expense_category,cost_center_reference,project_reference)
    values(p_company_id,v_id,v_number,trim(v_line->>'product_service_code'),nullif(trim(v_line->>'identification_number'),''),(v_line->>'quantity')::numeric,trim(v_line->>'unit_code'),nullif(trim(v_line->>'unit_name'),''),trim(v_line->>'description'),(v_line->>'unit_value')::numeric,v_line_subtotal,v_line_discount,v_line_transferred,v_line_withheld,trim(v_line->>'tax_object_code'),coalesce(v_line->'tax_details','[]'::jsonb),nullif(trim(v_line->>'expense_category'),''),nullif(trim(v_line->>'cost_center_reference'),''),nullif(trim(v_line->>'project_reference'),''));
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_invoice_id is null then 'supplier_expense_invoice.draft_created' else 'supplier_expense_invoice.draft_updated' end,'supplier_invoice',v_id,jsonb_build_object('line_count',jsonb_array_length(p_lines),'subtotal',v_subtotal,'transferred_tax',v_transferred,'withheld_tax',v_withheld,'total',v_total,'exchange_rate',v_rate));
  return jsonb_build_object('id',v_id,'status','draft','source_kind','expense','total',v_total,'base_total',round(v_total*v_rate,6));
end $$;

create or replace function public.register_supplier_invoice_document(
  p_company_id uuid,p_invoice_id uuid,p_document_role text,p_original_file_name text,p_storage_path text,
  p_mime_type text,p_size_bytes bigint,p_sha256 text,p_extracted_data jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.supplier_invoices%rowtype;v_supplier public.suppliers%rowtype;v_company public.companies%rowtype;v_existing public.supplier_invoice_documents%rowtype;
  v_issues jsonb:='[]'::jsonb;v_status text:='not_applicable';v_id uuid;v_uuid text;v_concepts jsonb;v_line record;v_concept jsonb;
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
    v_status:='verified_local';v_uuid:=nullif(lower(trim(p_extracted_data->>'uuid')),'');v_concepts:=coalesce(p_extracted_data->'concepts','[]'::jsonb);
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
    if v_invoice.source_kind='expense' then
      if jsonb_typeof(v_concepts)<>'array' or jsonb_array_length(v_concepts)<>(select count(*) from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice.id) then
        v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','concept_count','expected',(select count(*) from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice.id),'actual',case when jsonb_typeof(v_concepts)='array' then jsonb_array_length(v_concepts) else null end));
      else
        for v_line in select * from public.supplier_invoice_expense_lines where supplier_invoice_id=v_invoice.id order by line_number loop
          v_concept:=v_concepts->(v_line.line_number-1);
          if coalesce(v_concept->>'product_service_code','')<>coalesce(v_line.product_service_code,'') or coalesce((v_concept->>'quantity')::numeric,-1)<>v_line.quantity or coalesce(v_concept->>'unit_code','')<>coalesce(v_line.unit_code,'') or coalesce((v_concept->>'subtotal')::numeric,-1)<>v_line.subtotal or coalesce((v_concept->>'discount_amount')::numeric,0)<>v_line.discount_amount or coalesce((v_concept->>'transferred_tax_amount')::numeric,0)<>v_line.tax_amount or coalesce((v_concept->>'withheld_tax_amount')::numeric,0)<>v_line.withheld_tax_amount or coalesce(v_concept->>'tax_object_code','')<>coalesce(v_line.tax_object_code,'') then
            v_issues:=v_issues||jsonb_build_array(jsonb_build_object('field','concept','line_number',v_line.line_number,'expected',jsonb_build_object('product_service_code',v_line.product_service_code,'quantity',v_line.quantity,'unit_code',v_line.unit_code,'subtotal',v_line.subtotal,'discount_amount',v_line.discount_amount,'transferred_tax_amount',v_line.tax_amount,'withheld_tax_amount',v_line.withheld_tax_amount,'tax_object_code',v_line.tax_object_code),'actual',v_concept));
          end if;
        end loop;
      end if;
    end if;
    if jsonb_array_length(v_issues)>0 then v_status:='mismatch';
    elsif v_invoice.fiscal_uuid is null and v_invoice.status='draft' then update public.supplier_invoices set fiscal_uuid=v_uuid,updated_by=auth.uid() where id=v_invoice.id;end if;
  end if;
  insert into public.supplier_invoice_documents(company_id,supplier_invoice_id,document_role,original_file_name,storage_path,mime_type,size_bytes,sha256,extracted_data,validation_status,validation_issues)
  values(p_company_id,p_invoice_id,p_document_role,trim(p_original_file_name),trim(p_storage_path),p_mime_type,p_size_bytes,lower(trim(p_sha256)),coalesce(p_extracted_data,'{}'::jsonb),v_status,v_issues) returning id into v_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.document_attached','supplier_invoice',p_invoice_id,jsonb_build_object('document_id',v_id,'document_role',p_document_role,'sha256',lower(trim(p_sha256)),'validation_status',v_status,'validation_issues',v_issues));
  return jsonb_build_object('id',v_id,'status',v_status,'issues',v_issues,'idempotent',false);
end $$;

create or replace function public.require_expense_cfdi_before_confirmation()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='confirmed' and old.status is distinct from 'confirmed' and new.source_kind='expense'
    and exists(select 1 from public.suppliers s where s.id=new.supplier_id and coalesce(s.country_code,'MX')='MX')
    and not exists(select 1 from public.supplier_invoice_documents d where d.supplier_invoice_id=new.id and d.document_role='cfdi_xml' and d.validation_status='verified_local')
  then raise exception 'La factura mexicana de gasto requiere un XML CFDI 4.0 coincidente antes de crear CxP.';end if;
  return new;
end $$;
drop trigger if exists require_expense_cfdi_before_confirmation on public.supplier_invoices;
create trigger require_expense_cfdi_before_confirmation before update of status on public.supplier_invoices for each row execute function public.require_expense_cfdi_before_confirmation();

revoke all on function public.save_supplier_expense_invoice(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,timestamptz) from public;
revoke all on function public.register_supplier_invoice_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) from public;
grant execute on function public.save_supplier_expense_invoice(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,timestamptz) to authenticated;
grant execute on function public.register_supplier_invoice_document(uuid,uuid,text,text,text,text,bigint,text,jsonb) to authenticated;
