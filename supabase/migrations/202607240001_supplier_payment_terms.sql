-- Satrapy · Condiciones de pago de proveedores y vencimiento automático.
-- La primera versión usa días naturales desde la emisión del CFDI.

alter table public.suppliers
  alter column payable_term_days drop not null,
  alter column payable_term_days drop default;
update public.suppliers set payable_term_days=null where payable_term_days=0;
alter table public.suppliers drop constraint if exists suppliers_payable_term_days_check;
alter table public.suppliers add constraint suppliers_payable_term_days_check
  check(payable_term_days is null or payable_term_days between 0 and 3650);

alter table public.supplier_invoices
  add column if not exists supplier_payable_term_days_snapshot integer,
  add column if not exists due_date_source text not null default 'legacy',
  add column if not exists due_date_override_reason text,
  add column if not exists on_time_total_snapshot numeric(18,6),
  add column if not exists late_payment_total numeric(18,6),
  add column if not exists payment_terms_evidence text;
alter table public.supplier_invoices drop constraint if exists supplier_invoices_term_snapshot_check;
alter table public.supplier_invoices add constraint supplier_invoices_term_snapshot_check
  check(supplier_payable_term_days_snapshot is null or supplier_payable_term_days_snapshot between 0 and 3650);
alter table public.supplier_invoices drop constraint if exists supplier_invoices_due_date_source_check;
alter table public.supplier_invoices add constraint supplier_invoices_due_date_source_check
  check(due_date_source in ('supplier_terms','manual_override','legacy'));
alter table public.supplier_invoices drop constraint if exists supplier_invoices_due_override_reason_check;
alter table public.supplier_invoices add constraint supplier_invoices_due_override_reason_check
  check(
    due_date_source<>'manual_override'
    or nullif(trim(coalesce(due_date_override_reason,'')),'') is not null
  );
alter table public.supplier_invoices drop constraint if exists supplier_invoices_conditional_total_check;
alter table public.supplier_invoices add constraint supplier_invoices_conditional_total_check
  check(
    (late_payment_total is null and payment_terms_evidence is null)
    or (
      on_time_total_snapshot is not null
      and late_payment_total>on_time_total_snapshot
      and nullif(trim(coalesce(payment_terms_evidence,'')),'') is not null
    )
  );

insert into public.permissions(code,description) values
  ('recognize_supplier_late_payment_charges','Reconocer el total contractual posterior al plazo con evidencia auditada.')
on conflict(code) do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin')
  and p.code='recognize_supplier_late_payment_charges'
on conflict do nothing;

alter table public.accounts_payable_adjustments
  drop constraint if exists accounts_payable_adjustments_supplier_invoice_id_key;
alter table public.accounts_payable_adjustments
  drop constraint if exists accounts_payable_adjustments_adjustment_type_check;
alter table public.accounts_payable_adjustments
  add constraint accounts_payable_adjustments_adjustment_type_check
  check(adjustment_type in ('credit_note','invoice_reversal','late_payment_charge'));
create unique index if not exists accounts_payable_adjustments_invoice_kind_uidx
  on public.accounts_payable_adjustments(supplier_invoice_id,adjustment_type);

create or replace function public.search_suppliers(
  p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 50,
  p_is_active boolean default null,p_origin text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page int:=greatest(coalesce(p_page,1),1);
  v_size int:=least(greatest(coalesce(p_page_size,50),1),100);
  v_q text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_suppliers') then
    raise exception 'No autorizado para consultar proveedores.';
  end if;
  with filtered as materialized(
    select s.* from public.suppliers s
    where s.company_id=p_company_id
      and (p_is_active is null or s.is_active=p_is_active)
      and (
        v_q=''
        or lower(s.code) like '%'||v_q||'%'
        or lower(s.display_name) like '%'||v_q||'%'
        or lower(coalesce(s.legal_name,'')) like '%'||v_q||'%'
        or lower(coalesce(s.tax_id,'')) like '%'||v_q||'%'
        or lower(coalesce(s.phone_e164,s.phone,'')) like '%'||v_q||'%'
      )
  ), counted as(
    select count(*) total from filtered
  ), paged as(
    select * from filtered order by display_name,id limit v_size offset(v_page-1)*v_size
  )
  select
    (select total from counted),
    coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'code',code,'display_name',display_name,'legal_name',legal_name,
      'legal_entity_type',legal_entity_type,'tax_id',tax_id,'tax_regime',tax_regime,
      'fiscal_postal_code',fiscal_postal_code,'country_code',country_code,
      'contact_name',contact_name,'email',email,'phone',coalesce(phone_e164,phone),
      'phone_extension',phone_extension,'phone_status',phone_status,
      'supplier_category',supplier_category,'address_line',address_line,
      'neighborhood',neighborhood,'municipality',municipality,'state_name',state_name,
      'postal_code',postal_code,'payable_term_days',payable_term_days,
      'is_active',is_active,'updated_at',updated_at
    ) order by display_name,id),'[]'::jsonb)
  into v_total,v_items from paged;
  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0))
  );
end $$;

create or replace function public.search_supplier_options(
  p_company_id uuid,p_query text default null,p_limit integer default 30
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_limit integer:=least(greatest(coalesce(p_limit,30),1),50);
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_suppliers') then
    raise exception 'No autorizado para consultar proveedores.';
  end if;
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',x.id,'code',x.code,'display_name',x.display_name,'tax_id',x.tax_id,
      'payable_term_days',x.payable_term_days
    ) order by x.rank,x.display_name,x.id
  ),'[]'::jsonb)
  into v_items
  from (
    select s.id,s.code,s.display_name,s.tax_id,s.payable_term_days,
      case
        when v_query<>'' and lower(s.code)=v_query then 0
        when v_query<>'' and lower(coalesce(s.tax_id,''))=v_query then 0
        else 1
      end rank
    from public.suppliers s
    where s.company_id=p_company_id and s.is_active=true
      and (
        v_query=''
        or lower(s.code) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
        or lower(coalesce(s.tax_id,'')) like '%'||v_query||'%'
      )
    order by rank,s.display_name,s.id
    limit v_limit
  ) x;
  return jsonb_build_object('items',v_items);
end $$;

create or replace function public.search_invoiceable_receipts(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,
  p_purchase_order_id uuid default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page int:=greatest(coalesce(p_page,1),1);
  v_size int:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'view_supplier_invoices')
    or public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts')
  ) then raise exception 'No autorizado para consultar recepciones facturables.';end if;
  with candidates as (
    select pr.id,pr.folio receipt_folio,pr.receipt_date,po.id purchase_order_id,
      po.folio purchase_order_folio,po.currency_code,s.id supplier_id,s.code supplier_code,
      s.display_name supplier_name,s.payable_term_days
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id=pr.purchase_order_id
    join public.suppliers s on s.id=pr.supplier_id
    where pr.company_id=p_company_id and pr.status='confirmed'
      and po.status='approved' and po.origin='operational'
      and (p_supplier_id is null or s.id=p_supplier_id)
      and (p_purchase_order_id is null or po.id=p_purchase_order_id)
      and (
        v_query='' or lower(pr.folio) like '%'||v_query||'%'
        or lower(po.folio) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
      )
      and exists(
        select 1 from public.purchase_receipt_lines prl
        where prl.purchase_receipt_id=pr.id
          and prl.quantity>coalesce((
            select sum(sil.quantity)
            from public.supplier_invoice_lines sil
            join public.supplier_invoices si on si.id=sil.supplier_invoice_id
            where sil.purchase_receipt_line_id=prl.id and si.status='confirmed'
          ),0)
      )
  )
  select count(*) into v_total from candidates;
  with candidates as (
    select pr.id,pr.folio receipt_folio,pr.receipt_date,po.id purchase_order_id,
      po.folio purchase_order_folio,po.currency_code,s.id supplier_id,s.code supplier_code,
      s.display_name supplier_name,s.payable_term_days
    from public.purchase_receipts pr
    join public.purchase_orders po on po.id=pr.purchase_order_id
    join public.suppliers s on s.id=pr.supplier_id
    where pr.company_id=p_company_id and pr.status='confirmed'
      and po.status='approved' and po.origin='operational'
      and (p_supplier_id is null or s.id=p_supplier_id)
      and (p_purchase_order_id is null or po.id=p_purchase_order_id)
      and (
        v_query='' or lower(pr.folio) like '%'||v_query||'%'
        or lower(po.folio) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
      )
      and exists(
        select 1 from public.purchase_receipt_lines prl
        where prl.purchase_receipt_id=pr.id
          and prl.quantity>coalesce((
            select sum(sil.quantity)
            from public.supplier_invoice_lines sil
            join public.supplier_invoices si on si.id=sil.supplier_invoice_id
            where sil.purchase_receipt_line_id=prl.id and si.status='confirmed'
          ),0)
      )
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.receipt_date,x.id),'[]'::jsonb)
  into v_items
  from (
    select * from candidates order by receipt_date,id limit v_size offset(v_page-1)*v_size
  ) x;
  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total)
  );
end $$;

create or replace function public.save_supplier_v2(
  p_company_id uuid,p_supplier_id uuid,p_display_name text,p_legal_name text default null,
  p_legal_entity_type text default null,p_tax_id text default null,p_tax_regime text default null,
  p_fiscal_postal_code text default null,p_country_code text default 'MX',p_contact_name text default null,
  p_email text default null,p_phone text default null,p_phone_extension text default null,
  p_supplier_category text default null,p_address_line text default null,p_neighborhood text default null,
  p_municipality text default null,p_state_name text default null,p_postal_code text default null,
  p_payable_term_days integer default null,p_is_active boolean default true,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_result jsonb;
  v_id uuid;
  v_before_days integer;
begin
  if p_payable_term_days is not null and p_payable_term_days not between 0 and 3650 then
    raise exception 'El plazo debe estar entre 0 y 3650 días.';
  end if;
  if p_supplier_id is not null then
    select payable_term_days into v_before_days
    from public.suppliers where id=p_supplier_id and company_id=p_company_id;
  end if;
  v_result:=public.save_supplier(
    p_company_id,p_supplier_id,p_display_name,p_legal_name,p_legal_entity_type,p_tax_id,
    p_tax_regime,p_fiscal_postal_code,p_country_code,p_contact_name,p_email,p_phone,
    p_phone_extension,p_supplier_category,p_address_line,p_neighborhood,p_municipality,
    p_state_name,p_postal_code,p_is_active,p_expected_updated_at
  );
  v_id:=(v_result->>'id')::uuid;
  update public.suppliers
    set payable_term_days=p_payable_term_days,updated_by=auth.uid()
  where id=v_id and company_id=p_company_id;
  if v_before_days is distinct from p_payable_term_days then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(
      p_company_id,auth.uid(),'supplier.payment_terms_updated','supplier',v_id,
      jsonb_build_object(
        'before_days',v_before_days,'after_days',p_payable_term_days,
        'basis','invoice_issue_date','day_kind','calendar'
      )
    );
  end if;
  return (select to_jsonb(s) from public.suppliers s where s.id=v_id);
end $$;

create or replace function public.bulk_assign_supplier_payable_terms(
  p_company_id uuid,p_supplier_ids uuid[],p_payable_term_days integer,p_reason text,
  p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_count integer;
  v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());
  v_existing jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_suppliers') then
    raise exception 'No autorizado para administrar proveedores.';
  end if;
  if p_payable_term_days not between 0 and 3650 then
    raise exception 'El plazo debe estar entre 0 y 3650 días.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'El motivo de la asignación es obligatorio.';
  end if;
  if coalesce(cardinality(p_supplier_ids),0)=0 or cardinality(p_supplier_ids)>1000 then
    raise exception 'Selecciona entre 1 y 1000 proveedores.';
  end if;
  select metadata into v_existing from public.audit_log
  where company_id=p_company_id and action='supplier.payment_terms_bulk_updated'
    and metadata->>'request_id'=v_request::text
  order by created_at desc limit 1;
  if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  if (
    select count(distinct s.id) from public.suppliers s
    where s.company_id=p_company_id and s.id=any(p_supplier_ids)
  )<>cardinality(p_supplier_ids) then
    raise exception 'La selección contiene proveedores inválidos o duplicados.';
  end if;
  update public.suppliers
    set payable_term_days=p_payable_term_days,updated_by=auth.uid()
  where company_id=p_company_id and id=any(p_supplier_ids);
  get diagnostics v_count=row_count;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(
    p_company_id,auth.uid(),'supplier.payment_terms_bulk_updated','supplier',
    jsonb_build_object(
      'request_id',v_request,'supplier_ids',p_supplier_ids,'supplier_count',v_count,
      'payable_term_days',p_payable_term_days,'basis','invoice_issue_date',
      'day_kind','calendar','reason',trim(p_reason)
    )
  );
  return jsonb_build_object(
    'request_id',v_request,'supplier_count',v_count,
    'payable_term_days',p_payable_term_days,'idempotent',false
  );
end $$;

create or replace function public.resolve_supplier_invoice_due_date(
  p_company_id uuid,p_supplier_id uuid,p_issued_date date,
  p_requested_due_date date default null,p_override_reason text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_days integer;
  v_calculated date;
  v_requested date:=p_requested_due_date;
begin
  if p_issued_date is null then raise exception 'La fecha de emisión es obligatoria.';end if;
  select payable_term_days into v_days
  from public.suppliers
  where id=p_supplier_id and company_id=p_company_id and is_active;
  if not found then raise exception 'Proveedor activo no encontrado.';end if;
  if v_days is null then
    if v_requested is null then
      raise exception 'Configura el plazo del proveedor o captura una excepción motivada.';
    end if;
    if v_requested<p_issued_date then raise exception 'El vencimiento no puede ser anterior a la emisión.';end if;
    if nullif(trim(coalesce(p_override_reason,'')),'') is null then
      raise exception 'El proveedor no tiene plazo configurado; documenta el motivo del vencimiento manual.';
    end if;
    return jsonb_build_object(
      'due_date',v_requested,'source','manual_override','term_days',null,
      'override_reason',trim(p_override_reason)
    );
  end if;
  v_calculated:=p_issued_date+v_days;
  if v_requested is null or v_requested=v_calculated then
    return jsonb_build_object(
      'due_date',v_calculated,'source','supplier_terms','term_days',v_days,
      'override_reason',null
    );
  end if;
  if v_requested<p_issued_date then raise exception 'El vencimiento no puede ser anterior a la emisión.';end if;
  if nullif(trim(coalesce(p_override_reason,'')),'') is null then
    raise exception 'Un vencimiento distinto al plazo del proveedor requiere motivo.';
  end if;
  return jsonb_build_object(
    'due_date',v_requested,'source','manual_override','term_days',v_days,
    'override_reason',trim(p_override_reason)
  );
end $$;

create or replace function public.save_supplier_invoice_v3(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_purchase_order_id uuid,
  p_series text,p_folio text,p_fiscal_uuid text,p_issued_date date,
  p_requested_due_date date,p_currency_code text,p_exchange_rate numeric,
  p_supplier_reference text,p_payment_method_code text,p_payment_form_code text,p_lines jsonb,
  p_late_payment_total numeric default null,p_payment_terms_evidence text default null,
  p_due_date_override_reason text default null,p_client_request_id uuid default null,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_terms jsonb;
  v_result jsonb;
  v_id uuid;
begin
  v_terms:=public.resolve_supplier_invoice_due_date(
    p_company_id,p_supplier_id,p_issued_date,p_requested_due_date,p_due_date_override_reason
  );
  v_result:=public.save_supplier_invoice_v2(
    p_company_id,p_invoice_id,p_supplier_id,p_purchase_order_id,p_series,p_folio,p_fiscal_uuid,
    p_issued_date,(v_terms->>'due_date')::date,p_currency_code,p_exchange_rate,
    p_supplier_reference,p_payment_method_code,p_payment_form_code,p_lines,
    p_client_request_id,p_expected_updated_at
  );
  if v_result->>'status'='draft' then
    v_id:=(v_result->>'id')::uuid;
    update public.supplier_invoices set
      supplier_payable_term_days_snapshot=(v_terms->>'term_days')::integer,
      due_date_source=v_terms->>'source',
      due_date_override_reason=v_terms->>'override_reason',
      on_time_total_snapshot=total,
      late_payment_total=p_late_payment_total,
      payment_terms_evidence=nullif(trim(p_payment_terms_evidence),''),
      updated_by=auth.uid()
    where id=v_id and company_id=p_company_id;
    if p_late_payment_total is not null and (
      p_late_payment_total<=(select total from public.supplier_invoices where id=v_id)
      or nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is null
    ) then
      raise exception 'El total posterior debe superar el total dentro del plazo y requiere evidencia.';
    end if;
    if p_late_payment_total is null and nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is not null then
      raise exception 'Captura el total posterior asociado a la evidencia.';
    end if;
    if v_terms->>'source'='manual_override' then
      insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
      values(
        p_company_id,auth.uid(),'supplier_invoice.due_date_overridden','supplier_invoice',v_id,
        jsonb_build_object(
          'issued_date',p_issued_date,'due_date',v_terms->>'due_date',
          'supplier_term_days',v_terms->'term_days','reason',v_terms->>'override_reason'
        )
      );
    end if;
  end if;
  return v_result||v_terms;
end $$;

create or replace function public.save_supplier_expense_invoice_v2(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_series text,p_folio text,
  p_fiscal_uuid text,p_issued_date date,p_requested_due_date date,p_currency_code text,
  p_exchange_rate numeric,p_supplier_reference text,p_payment_method_code text,
  p_payment_form_code text,p_lines jsonb,p_late_payment_total numeric default null,
  p_payment_terms_evidence text default null,p_due_date_override_reason text default null,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_terms jsonb;
  v_result jsonb;
  v_id uuid;
begin
  v_terms:=public.resolve_supplier_invoice_due_date(
    p_company_id,p_supplier_id,p_issued_date,p_requested_due_date,p_due_date_override_reason
  );
  v_result:=public.save_supplier_expense_invoice(
    p_company_id,p_invoice_id,p_supplier_id,p_series,p_folio,p_fiscal_uuid,p_issued_date,
    (v_terms->>'due_date')::date,p_currency_code,p_exchange_rate,p_supplier_reference,
    p_payment_method_code,p_payment_form_code,p_lines,p_expected_updated_at
  );
  if v_result->>'status'='draft' then
    v_id:=(v_result->>'id')::uuid;
    update public.supplier_invoices set
      supplier_payable_term_days_snapshot=(v_terms->>'term_days')::integer,
      due_date_source=v_terms->>'source',
      due_date_override_reason=v_terms->>'override_reason',
      on_time_total_snapshot=total,
      late_payment_total=p_late_payment_total,
      payment_terms_evidence=nullif(trim(p_payment_terms_evidence),''),
      updated_by=auth.uid()
    where id=v_id and company_id=p_company_id;
    if p_late_payment_total is not null and (
      p_late_payment_total<=(select total from public.supplier_invoices where id=v_id)
      or nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is null
    ) then
      raise exception 'El total posterior debe superar el total dentro del plazo y requiere evidencia.';
    end if;
    if p_late_payment_total is null and nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is not null then
      raise exception 'Captura el total posterior asociado a la evidencia.';
    end if;
    if v_terms->>'source'='manual_override' then
      insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
      values(
        p_company_id,auth.uid(),'supplier_invoice.due_date_overridden','supplier_invoice',v_id,
        jsonb_build_object(
          'issued_date',p_issued_date,'due_date',v_terms->>'due_date',
          'supplier_term_days',v_terms->'term_days','reason',v_terms->>'override_reason'
        )
      );
    end if;
  end if;
  return v_result||v_terms;
end $$;

create or replace function public.recognize_supplier_late_payment_charge(
  p_company_id uuid,p_invoice_id uuid,p_charge_evidence text,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.supplier_invoices%rowtype;
  v_payable public.accounts_payable%rowtype;
  v_delta numeric;
  v_base_delta numeric;
  v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());
  v_existing jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'recognize_supplier_late_payment_charges') then
    raise exception 'No autorizado para reconocer el total posterior al plazo.';
  end if;
  if nullif(trim(coalesce(p_charge_evidence,'')),'') is null
    or nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'La evidencia del cargo y el motivo son obligatorios.';
  end if;
  select metadata into v_existing from public.audit_log
  where company_id=p_company_id and action='supplier_invoice.late_payment_charge_recognized'
    and metadata->>'request_id'=v_request::text
  order by created_at desc limit 1;
  if found then return v_existing||jsonb_build_object('idempotent',true);end if;
  select * into v_invoice from public.supplier_invoices
  where id=p_invoice_id and company_id=p_company_id for update;
  if not found or v_invoice.status<>'confirmed' or v_invoice.document_type<>'invoice' then
    raise exception 'Factura confirmada no disponible.';
  end if;
  if v_invoice.late_payment_total is null or v_invoice.on_time_total_snapshot is null then
    raise exception 'La factura no tiene un total posterior al plazo.';
  end if;
  if current_date<=v_invoice.due_date then
    raise exception 'El total posterior sólo puede reconocerse después de la fecha límite.';
  end if;
  select * into v_payable from public.accounts_payable
  where supplier_invoice_id=v_invoice.id and company_id=p_company_id for update;
  if not found or v_payable.reversed_at is not null or v_payable.outstanding_amount<=0 then
    raise exception 'La cuenta por pagar ya no admite el cargo.';
  end if;
  if exists(
    select 1 from public.accounts_payable_adjustments
    where supplier_invoice_id=v_invoice.id and adjustment_type='late_payment_charge'
  ) then raise exception 'El total posterior ya fue reconocido.';end if;
  v_delta:=round(v_invoice.late_payment_total-v_invoice.on_time_total_snapshot,6);
  v_base_delta:=round(v_delta*v_invoice.exchange_rate,6);
  update public.accounts_payable set
    original_amount=original_amount+v_delta,
    outstanding_amount=outstanding_amount+v_delta,
    original_base_amount=original_base_amount+v_base_delta,
    outstanding_base_amount=outstanding_base_amount+v_base_delta
  where id=v_payable.id;
  insert into public.accounts_payable_adjustments(
    company_id,accounts_payable_id,supplier_invoice_id,adjustment_type,amount,reason
  ) values(
    p_company_id,v_payable.id,v_invoice.id,'late_payment_charge',v_delta,
    trim(p_reason)||' · Evidencia: '||trim(p_charge_evidence)
  );
  v_existing:=jsonb_build_object(
    'request_id',v_request,'invoice_id',v_invoice.id,'payable_id',v_payable.id,
    'previous_total',v_invoice.on_time_total_snapshot,'late_payment_total',v_invoice.late_payment_total,
    'charge_amount',v_delta,'charge_evidence',trim(p_charge_evidence),'reason',trim(p_reason)
  );
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),'supplier_invoice.late_payment_charge_recognized',
    'supplier_invoice',v_invoice.id,v_existing
  );
  return v_existing||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.search_supplier_payable_due_inbox_v2(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,
  p_currency_code text default null,p_due_bucket text default null,p_due_from date default null,
  p_due_to date default null,p_min_balance numeric default null,p_max_balance numeric default null,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_result jsonb;
  v_items jsonb;
begin
  v_result:=public.search_supplier_payable_due_inbox(
    p_company_id,p_query,p_supplier_id,p_currency_code,p_due_bucket,p_due_from,p_due_to,
    p_min_balance,p_max_balance,p_page,p_page_size
  );
  select coalesce(jsonb_agg(
    entry.item||jsonb_build_object(
      'on_time_total',si.on_time_total_snapshot,
      'late_payment_total',si.late_payment_total,
      'payment_terms_evidence',si.payment_terms_evidence,
      'late_charge_recognized',coalesce(charge.recognized,false),
      'pending_late_charge',case
        when si.late_payment_total is not null
          and current_date>si.due_date
          and not coalesce(charge.recognized,false)
        then round(si.late_payment_total-si.on_time_total_snapshot,6)
        else 0
      end
    ) order by entry.ordinality
  ),'[]'::jsonb)
  into v_items
  from jsonb_array_elements(v_result->'items') with ordinality entry(item,ordinality)
  join public.supplier_invoices si on si.id=(entry.item->>'supplier_invoice_id')::uuid
  left join lateral(
    select true recognized
    from public.accounts_payable_adjustments adjustment
    where adjustment.supplier_invoice_id=si.id
      and adjustment.adjustment_type='late_payment_charge'
    limit 1
  ) charge on true;
  return jsonb_set(v_result,'{items}',v_items);
end $$;

create or replace function public.reverse_supplier_invoice(
  p_company_id uuid,p_invoice_id uuid,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_invoice public.supplier_invoices%rowtype;
  v_payable public.accounts_payable%rowtype;
  v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());
  v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reverse_supplier_invoices') then raise exception 'No autorizado para revertir facturas.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La reversa requiere motivo.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found then raise exception 'Factura no encontrada.';end if;
  if v_invoice.status='reversed' and v_invoice.reverse_request_id=v_request then return jsonb_build_object('invoice_id',v_invoice.id,'status','reversed','idempotent',true);end if;
  if v_invoice.status<>'confirmed' or v_invoice.document_type<>'invoice' then raise exception 'Sólo una factura confirmada puede revertirse.';end if;
  select * into v_payable from public.accounts_payable where supplier_invoice_id=v_invoice.id for update;
  if v_payable.outstanding_amount<>v_payable.original_amount then raise exception 'La factura tiene aplicaciones o notas de crédito; no puede revertirse directamente.';end if;
  update public.accounts_payable set outstanding_amount=0,reversed_at=v_now where id=v_payable.id;
  insert into public.accounts_payable_adjustments(company_id,accounts_payable_id,supplier_invoice_id,adjustment_type,amount,reason)
  values(p_company_id,v_payable.id,v_invoice.id,'invoice_reversal',v_payable.original_amount,trim(p_reason));
  update public.supplier_invoices set status='reversed',reversed_at=v_now,reversed_by=auth.uid(),reversal_reason=trim(p_reason),reverse_request_id=v_request,updated_by=auth.uid() where id=v_invoice.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'supplier_invoice.reversed','supplier_invoice',v_invoice.id,jsonb_build_object('payable_id',v_payable.id,'amount',v_payable.original_amount,'reason',trim(p_reason),'client_request_id',v_request));
  return jsonb_build_object('invoice_id',v_invoice.id,'status','reversed','idempotent',false);
end $$;

revoke all on function public.save_supplier_v2(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,integer,boolean,timestamptz) from public,anon;
revoke all on function public.bulk_assign_supplier_payable_terms(uuid,uuid[],integer,text,uuid) from public,anon;
revoke all on function public.resolve_supplier_invoice_due_date(uuid,uuid,date,date,text) from public,anon;
revoke all on function public.save_supplier_invoice_v3(uuid,uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,uuid,timestamptz) from public,anon;
revoke all on function public.save_supplier_expense_invoice_v2(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,timestamptz) from public,anon;
revoke all on function public.recognize_supplier_late_payment_charge(uuid,uuid,text,text,uuid) from public,anon;
revoke all on function public.search_supplier_payable_due_inbox_v2(uuid,text,uuid,text,text,date,date,numeric,numeric,integer,integer) from public,anon;
grant execute on function public.save_supplier_v2(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,integer,boolean,timestamptz) to authenticated;
grant execute on function public.bulk_assign_supplier_payable_terms(uuid,uuid[],integer,text,uuid) to authenticated;
grant execute on function public.save_supplier_invoice_v3(uuid,uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,uuid,timestamptz) to authenticated;
grant execute on function public.save_supplier_expense_invoice_v2(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,timestamptz) to authenticated;
grant execute on function public.recognize_supplier_late_payment_charge(uuid,uuid,text,text,uuid) to authenticated;
grant execute on function public.search_supplier_payable_due_inbox_v2(uuid,text,uuid,text,text,date,date,numeric,numeric,integer,integer) to authenticated;
