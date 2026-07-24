-- Satrapy · corrección de condiciones de proveedor:
-- días de crédito + hasta tres descuentos por pronto pago.
-- La migración anterior pudo haberse aplicado; sus columnas de importes
-- posteriores se conservan por compatibilidad, pero dejan de usarse.

create table if not exists public.supplier_prompt_payment_terms(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  tier_number smallint not null check(tier_number between 1 and 3),
  term_days integer not null check(term_days between 0 and 3650),
  discount_components jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(supplier_id,tier_number)
);

create index if not exists supplier_prompt_payment_terms_company_supplier_idx
  on public.supplier_prompt_payment_terms(company_id,supplier_id,tier_number);

alter table public.supplier_prompt_payment_terms enable row level security;

create table if not exists public.supplier_invoice_prompt_payment_terms(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  tier_number smallint not null check(tier_number between 1 and 3),
  term_days integer not null check(term_days between 0 and 3650),
  discount_components jsonb not null,
  created_at timestamptz not null default now(),
  unique(supplier_invoice_id,tier_number)
);

create index if not exists supplier_invoice_prompt_terms_invoice_idx
  on public.supplier_invoice_prompt_payment_terms(company_id,supplier_invoice_id,tier_number);

alter table public.supplier_invoice_prompt_payment_terms enable row level security;

create or replace function public.prompt_payment_discount_expression(p_components jsonb)
returns text language sql immutable set search_path=public as $$
  select string_agg((value::numeric)::text||'%', '+')
  from jsonb_array_elements_text(p_components);
$$;

create or replace function public.prompt_payment_effective_discount(p_components jsonb)
returns numeric language plpgsql immutable set search_path=public as $$
declare
  v_component numeric;
  v_multiplier numeric:=1;
begin
  if jsonb_typeof(p_components)<>'array' or jsonb_array_length(p_components) not between 1 and 3 then
    raise exception 'El descuento requiere entre uno y tres componentes.';
  end if;
  for v_component in select value::numeric from jsonb_array_elements_text(p_components)
  loop
    if v_component<=0 or v_component>100 then
      raise exception 'Cada componente del descuento debe ser mayor a 0 y menor o igual a 100.';
    end if;
    v_multiplier:=v_multiplier*(1-v_component/100);
  end loop;
  return round((1-v_multiplier)*100,6);
end $$;

create or replace function public.save_supplier_prompt_payment_terms(
  p_company_id uuid,p_supplier_id uuid,p_terms jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_term jsonb;
  v_tier integer;
  v_days integer;
  v_components jsonb;
  v_before jsonb;
  v_after jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_suppliers') then
    raise exception 'No autorizado para administrar proveedores.';
  end if;
  if not exists(
    select 1 from public.suppliers
    where id=p_supplier_id and company_id=p_company_id
  ) then raise exception 'Proveedor no encontrado.';end if;
  if jsonb_typeof(coalesce(p_terms,'[]'::jsonb))<>'array'
    or jsonb_array_length(coalesce(p_terms,'[]'::jsonb))>3 then
    raise exception 'Configura como máximo tres plazos de pronto pago.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'tier_number',tier_number,'term_days',term_days,
    'discount_components',discount_components
  ) order by tier_number),'[]'::jsonb)
  into v_before
  from public.supplier_prompt_payment_terms
  where company_id=p_company_id and supplier_id=p_supplier_id;

  create temporary table if not exists pg_temp.validated_prompt_terms(
    tier_number smallint primary key,term_days integer,discount_components jsonb
  ) on commit drop;
  truncate pg_temp.validated_prompt_terms;

  for v_term in select value from jsonb_array_elements(coalesce(p_terms,'[]'::jsonb))
  loop
    v_tier:=(v_term->>'tier_number')::integer;
    v_days:=(v_term->>'term_days')::integer;
    v_components:=v_term->'discount_components';
    if v_tier not between 1 and 3 or v_days not between 0 and 3650 then
      raise exception 'Revisa el número y los días de cada plazo.';
    end if;
    perform public.prompt_payment_effective_discount(v_components);
    insert into pg_temp.validated_prompt_terms(tier_number,term_days,discount_components)
    values(v_tier,v_days,v_components);
  end loop;

  delete from public.supplier_prompt_payment_terms
  where company_id=p_company_id and supplier_id=p_supplier_id;
  insert into public.supplier_prompt_payment_terms(
    company_id,supplier_id,tier_number,term_days,discount_components
  )
  select p_company_id,p_supplier_id,tier_number,term_days,discount_components
  from pg_temp.validated_prompt_terms order by tier_number;

  select coalesce(jsonb_agg(jsonb_build_object(
    'tier_number',tier_number,'term_days',term_days,
    'discount_components',discount_components,
    'discount_expression',public.prompt_payment_discount_expression(discount_components),
    'effective_discount_percent',public.prompt_payment_effective_discount(discount_components)
  ) order by tier_number),'[]'::jsonb)
  into v_after
  from public.supplier_prompt_payment_terms
  where company_id=p_company_id and supplier_id=p_supplier_id;

  if v_before is distinct from v_after then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(
      p_company_id,auth.uid(),'supplier.prompt_payment_terms_updated','supplier',
      p_supplier_id,jsonb_build_object('before',v_before,'after',v_after)
    );
  end if;
  return jsonb_build_object('supplier_id',p_supplier_id,'terms',v_after);
end $$;

create or replace function public.snapshot_supplier_prompt_payment_terms(
  p_company_id uuid,p_supplier_id uuid,p_invoice_id uuid
) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(
    select 1 from public.supplier_invoices
    where id=p_invoice_id and company_id=p_company_id and supplier_id=p_supplier_id
  ) then raise exception 'La factura no corresponde al proveedor.';end if;
  delete from public.supplier_invoice_prompt_payment_terms
  where company_id=p_company_id and supplier_invoice_id=p_invoice_id;
  insert into public.supplier_invoice_prompt_payment_terms(
    company_id,supplier_invoice_id,tier_number,term_days,discount_components
  )
  select p_company_id,p_invoice_id,tier_number,term_days,discount_components
  from public.supplier_prompt_payment_terms
  where company_id=p_company_id and supplier_id=p_supplier_id
  order by tier_number;
end $$;

create or replace function public.save_supplier_v3(
  p_company_id uuid,p_supplier_id uuid,p_display_name text,p_legal_name text default null,
  p_legal_entity_type text default null,p_tax_id text default null,p_tax_regime text default null,
  p_fiscal_postal_code text default null,p_country_code text default 'MX',p_contact_name text default null,
  p_email text default null,p_phone text default null,p_phone_extension text default null,
  p_supplier_category text default null,p_address_line text default null,p_neighborhood text default null,
  p_municipality text default null,p_state_name text default null,p_postal_code text default null,
  p_payable_term_days integer default null,p_prompt_payment_terms jsonb default '[]'::jsonb,
  p_is_active boolean default true,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_supplier jsonb;
begin
  v_supplier:=public.save_supplier_v2(
    p_company_id,p_supplier_id,p_display_name,p_legal_name,p_legal_entity_type,p_tax_id,
    p_tax_regime,p_fiscal_postal_code,p_country_code,p_contact_name,p_email,p_phone,
    p_phone_extension,p_supplier_category,p_address_line,p_neighborhood,p_municipality,
    p_state_name,p_postal_code,p_payable_term_days,p_is_active,p_expected_updated_at
  );
  perform public.save_supplier_prompt_payment_terms(
    p_company_id,(v_supplier->>'id')::uuid,coalesce(p_prompt_payment_terms,'[]'::jsonb)
  );
  return v_supplier;
end $$;

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
        v_q='' or lower(s.code) like '%'||v_q||'%'
        or lower(s.display_name) like '%'||v_q||'%'
        or lower(coalesce(s.legal_name,'')) like '%'||v_q||'%'
        or lower(coalesce(s.tax_id,'')) like '%'||v_q||'%'
        or lower(coalesce(s.phone_e164,s.phone,'')) like '%'||v_q||'%'
      )
  ), counted as(select count(*) total from filtered),
  paged as(select * from filtered order by display_name,id limit v_size offset(v_page-1)*v_size)
  select (select total from counted),coalesce(jsonb_agg(
    to_jsonb(paged)||jsonb_build_object(
      'phone',coalesce(phone_e164,phone),
      'prompt_payment_terms',coalesce((
        select jsonb_agg(jsonb_build_object(
          'tier_number',t.tier_number,'term_days',t.term_days,
          'discount_components',t.discount_components,
          'discount_expression',public.prompt_payment_discount_expression(t.discount_components),
          'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components)
        ) order by t.tier_number)
        from public.supplier_prompt_payment_terms t where t.supplier_id=paged.id
      ),'[]'::jsonb)
    ) order by display_name,id
  ),'[]'::jsonb)
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
      'payable_term_days',x.payable_term_days,
      'prompt_payment_terms',coalesce((
        select jsonb_agg(jsonb_build_object(
          'tier_number',t.tier_number,'term_days',t.term_days,
          'discount_components',t.discount_components,
          'discount_expression',public.prompt_payment_discount_expression(t.discount_components),
          'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components)
        ) order by t.tier_number)
        from public.supplier_prompt_payment_terms t where t.supplier_id=x.id
      ),'[]'::jsonb)
    ) order by x.rank,x.display_name,x.id
  ),'[]'::jsonb) into v_items
  from (
    select s.id,s.code,s.display_name,s.tax_id,s.payable_term_days,
      case when v_query<>'' and (lower(s.code)=v_query or lower(coalesce(s.tax_id,''))=v_query) then 0 else 1 end rank
    from public.suppliers s
    where s.company_id=p_company_id and s.is_active=true
      and (v_query='' or lower(s.code) like '%'||v_query||'%'
        or lower(s.display_name) like '%'||v_query||'%'
        or lower(coalesce(s.tax_id,'')) like '%'||v_query||'%')
    order by rank,s.display_name,s.id limit v_limit
  ) x;
  return jsonb_build_object('items',v_items);
end $$;

-- Reutiliza los wrappers ya instalados, pero elimina el concepto incorrecto
-- de total posterior y conserva una copia de los descuentos vigentes al crear
-- el borrador. Las firmas no cambian para no romper clientes ya desplegados.
create or replace function public.save_supplier_invoice_v3(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_purchase_order_id uuid,
  p_series text,p_folio text,p_fiscal_uuid text,p_issued_date date,
  p_requested_due_date date,p_currency_code text,p_exchange_rate numeric,
  p_supplier_reference text,p_payment_method_code text,p_payment_form_code text,p_lines jsonb,
  p_late_payment_total numeric default null,p_payment_terms_evidence text default null,
  p_due_date_override_reason text default null,p_client_request_id uuid default null,
  p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_terms jsonb;v_result jsonb;v_id uuid;
begin
  if p_late_payment_total is not null or nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is not null then
    raise exception 'El total posterior fue retirado. Configura descuentos por pronto pago en el proveedor.';
  end if;
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
      due_date_source=v_terms->>'source',due_date_override_reason=v_terms->>'override_reason',
      on_time_total_snapshot=null,late_payment_total=null,payment_terms_evidence=null,
      updated_by=auth.uid()
    where id=v_id and company_id=p_company_id;
    perform public.snapshot_supplier_prompt_payment_terms(p_company_id,p_supplier_id,v_id);
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
declare v_terms jsonb;v_result jsonb;v_id uuid;
begin
  if p_late_payment_total is not null or nullif(trim(coalesce(p_payment_terms_evidence,'')),'') is not null then
    raise exception 'El total posterior fue retirado. Configura descuentos por pronto pago en el proveedor.';
  end if;
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
      due_date_source=v_terms->>'source',due_date_override_reason=v_terms->>'override_reason',
      on_time_total_snapshot=null,late_payment_total=null,payment_terms_evidence=null,
      updated_by=auth.uid()
    where id=v_id and company_id=p_company_id;
    perform public.snapshot_supplier_prompt_payment_terms(p_company_id,p_supplier_id,v_id);
  end if;
  return v_result||v_terms;
end $$;

create or replace function public.recognize_supplier_late_payment_charge(
  p_company_id uuid,p_invoice_id uuid,p_charge_evidence text,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  raise exception 'Esta operación fue retirada: el acuerdo confirmado es descuento por pronto pago, no aumento por atraso.';
end $$;

delete from public.role_permissions
where permission_id in(
  select id from public.permissions where code='recognize_supplier_late_payment_charges'
);
delete from public.permissions where code='recognize_supplier_late_payment_charges';

create or replace function public.search_supplier_payable_due_inbox_v2(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,
  p_currency_code text default null,p_due_bucket text default null,p_due_from date default null,
  p_due_to date default null,p_min_balance numeric default null,p_max_balance numeric default null,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;v_items jsonb;
begin
  v_result:=public.search_supplier_payable_due_inbox(
    p_company_id,p_query,p_supplier_id,p_currency_code,p_due_bucket,p_due_from,p_due_to,
    p_min_balance,p_max_balance,p_page,p_page_size
  );
  select coalesce(jsonb_agg(entry.item||jsonb_build_object(
    'prompt_payment_terms',coalesce(terms.options,'[]'::jsonb),
    'eligible_prompt_payment',terms.eligible
  ) order by entry.ordinality),'[]'::jsonb)
  into v_items
  from jsonb_array_elements(v_result->'items') with ordinality entry(item,ordinality)
  join public.supplier_invoices si on si.id=(entry.item->>'supplier_invoice_id')::uuid
  left join lateral(
    select
      jsonb_agg(option order by (option->>'term_days')::integer) options,
      (jsonb_agg(option order by (option->>'effective_discount_percent')::numeric desc,
        (option->>'term_days')::integer)->0) eligible
    from(
      select jsonb_build_object(
        'tier_number',t.tier_number,'term_days',t.term_days,
        'deadline',si.issued_date+t.term_days,
        'discount_expression',public.prompt_payment_discount_expression(t.discount_components),
        'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components),
        'estimated_total',round((entry.item->>'outstanding_amount')::numeric*
          (1-public.prompt_payment_effective_discount(t.discount_components)/100),6)
      ) option
      from public.supplier_invoice_prompt_payment_terms t
      where t.supplier_invoice_id=si.id and current_date<=si.issued_date+t.term_days
    ) eligible_options
  ) terms on true;
  return jsonb_set(v_result,'{items}',v_items);
end $$;

create or replace function public.search_supplier_payment_calendar(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,
  p_currency_code text default null,p_due_from date default null,p_due_to date default null,
  p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_result jsonb;v_can_proposals boolean;v_can_payments boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then
    raise exception 'No autorizado para consultar la agenda de pagos.';
  end if;
  if p_due_from is null or p_due_to is null or p_due_from>p_due_to or p_due_to-p_due_from>366 then
    raise exception 'La agenda requiere un rango válido de hasta 366 días.';
  end if;
  v_can_proposals:=public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals')
    or public.has_company_permission(p_company_id,'approve_supplier_payment_proposals');
  v_can_payments:=public.has_company_permission(p_company_id,'view_supplier_payments');
  with calendar_base as materialized(
    select ap.id,ap.supplier_id,s.code supplier_code,s.display_name supplier_name,ap.supplier_invoice_id,
      concat_ws('-',si.series,si.folio) invoice_number,ap.currency_code,ap.original_amount,ap.outstanding_amount,
      ap.issued_date,ap.due_date,
      case when proposal.proposal_id is not null or payment.payment_id is not null then 'scheduled'
        when ap.due_date<current_date then 'overdue' when ap.due_date=current_date then 'due_today'
        when ap.due_date<=current_date+15 then 'upcoming' else 'future' end state,
      proposal.proposal_id,proposal.proposal_status,payment.payment_id,payment.payment_reference,
      prompt.eligible_prompt_payment
    from public.accounts_payable ap
    join public.supplier_invoices si on si.id=ap.supplier_invoice_id
    join public.suppliers s on s.id=ap.supplier_id
    left join lateral(
      select pp.id proposal_id,pp.status proposal_status
      from public.supplier_payment_proposal_lines pl
      join public.supplier_payment_proposals pp on pp.id=pl.proposal_id
      where v_can_proposals and pl.company_id=p_company_id and pl.accounts_payable_id=ap.id
        and pp.status in('draft','submitted','approved')
      order by case pp.status when 'approved' then 1 when 'submitted' then 2 else 3 end,pp.updated_at desc limit 1
    ) proposal on true
    left join lateral(
      select p.id payment_id,p.reference payment_reference
      from public.supplier_payment_applications pa join public.supplier_payments p on p.id=pa.payment_id
      where v_can_payments and pa.company_id=p_company_id and pa.accounts_payable_id=ap.id and p.status='confirmed'
      order by p.effective_date desc,p.confirmed_at desc limit 1
    ) payment on true
    left join lateral(
      select jsonb_build_object(
        'tier_number',t.tier_number,'term_days',t.term_days,'deadline',si.issued_date+t.term_days,
        'discount_expression',public.prompt_payment_discount_expression(t.discount_components),
        'effective_discount_percent',public.prompt_payment_effective_discount(t.discount_components),
        'estimated_total',round(ap.outstanding_amount*
          (1-public.prompt_payment_effective_discount(t.discount_components)/100),6),
        'estimated_savings',round(ap.outstanding_amount*
          public.prompt_payment_effective_discount(t.discount_components)/100,6)
      ) eligible_prompt_payment
      from public.supplier_invoice_prompt_payment_terms t
      where t.supplier_invoice_id=si.id and current_date<=si.issued_date+t.term_days
      order by public.prompt_payment_effective_discount(t.discount_components) desc,t.term_days limit 1
    ) prompt on true
    where ap.company_id=p_company_id and ap.reversed_at is null
      and ap.due_date between p_due_from and p_due_to
      and (ap.outstanding_amount>0 or payment.payment_id is not null)
      and (p_supplier_id is null or ap.supplier_id=p_supplier_id)
      and (p_currency_code is null or ap.currency_code=upper(trim(p_currency_code)))
      and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%'
        or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
  ),paged as(
    select * from calendar_base order by due_date,supplier_name,invoice_number,id
    limit v_size offset(v_page-1)*v_size
  ),day_totals as(
    select due_date,currency_code,count(*) document_count,round(sum(outstanding_amount),6) outstanding_amount
    from calendar_base group by due_date,currency_code
  )
  select jsonb_build_object(
    'items',(select coalesce(jsonb_agg(to_jsonb(p) order by p.due_date,p.supplier_name,p.invoice_number,p.id),'[]'::jsonb) from paged p),
    'totals',(select coalesce(jsonb_agg(to_jsonb(t) order by t.due_date,t.currency_code),'[]'::jsonb) from day_totals t),
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from calendar_base)),
    'range',jsonb_build_object('from',p_due_from,'to',p_due_to)
  ) into v_result;
  return v_result;
end $$;

comment on column public.supplier_invoices.late_payment_total is
  'LEGACY: retirado en 202607240002; no usar para nuevas operaciones.';
comment on column public.supplier_invoices.payment_terms_evidence is
  'LEGACY: retirado en 202607240002; los descuentos se configuran por proveedor.';

revoke all on function public.save_supplier_prompt_payment_terms(uuid,uuid,jsonb) from public,anon;
revoke all on function public.snapshot_supplier_prompt_payment_terms(uuid,uuid,uuid) from public,anon;
revoke all on function public.save_supplier_v3(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,integer,jsonb,boolean,timestamptz) from public,anon;
revoke all on function public.recognize_supplier_late_payment_charge(uuid,uuid,text,text,uuid) from authenticated;
grant execute on function public.save_supplier_prompt_payment_terms(uuid,uuid,jsonb) to authenticated;
grant execute on function public.save_supplier_v3(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,text,integer,jsonb,boolean,timestamptz) to authenticated;
grant execute on function public.search_suppliers(uuid,text,integer,integer,boolean,text) to authenticated;
grant execute on function public.search_supplier_options(uuid,text,integer) to authenticated;
grant execute on function public.save_supplier_invoice_v3(uuid,uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,uuid,timestamptz) to authenticated;
grant execute on function public.save_supplier_expense_invoice_v2(uuid,uuid,uuid,text,text,text,date,date,text,numeric,text,text,text,jsonb,numeric,text,text,timestamptz) to authenticated;
grant execute on function public.search_supplier_payable_due_inbox_v2(uuid,text,uuid,text,text,date,date,numeric,numeric,integer,integer) to authenticated;
grant execute on function public.search_supplier_payment_calendar(uuid,text,uuid,text,date,date,integer,integer) to authenticated;
