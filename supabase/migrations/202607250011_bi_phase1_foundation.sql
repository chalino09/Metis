-- Satrapy BI · Fase 1.
-- Agregaciones server-side sobre fuentes canónicas, filtros por UUID, trazabilidad
-- y detalle paginado. BI no persiste ni replica hechos operativos.

insert into public.permissions(code,description) values
  ('view_bi','Consultar indicadores y trazabilidad transversal de BI.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code='view_bi'
on conflict do nothing;

create or replace function public.bi_search_filter_options(
  p_company_id uuid,
  p_dimension text,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 20
) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_dimension text:=lower(trim(coalesce(p_dimension,'')));
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,20),1),50);
  v_total bigint;
  v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then
    raise exception 'No autorizado para consultar BI.';
  end if;
  if v_dimension not in ('product','customer','supplier') then raise exception 'Dimensión de BI inválida.';end if;

  if v_dimension='product' then
    select count(*) into v_total from public.products p
    where p.company_id=p_company_id and p.is_active
      and (v_query='' or lower(p.name) like '%'||v_query||'%' or lower(p.alpha_sku) like '%'||v_query||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.alpha_sku) order by x.name,x.id),'[]'::jsonb)
    into v_items from (
      select p.id,p.name,p.alpha_sku from public.products p
      where p.company_id=p_company_id and p.is_active
        and (v_query='' or lower(p.name) like '%'||v_query||'%' or lower(p.alpha_sku) like '%'||v_query||'%')
      order by p.name,p.id limit v_size offset (v_page-1)*v_size
    )x;
  elsif v_dimension='customer' then
    select count(*) into v_total from public.customers c
    where c.company_id=p_company_id and c.is_active
      and (v_query='' or lower(c.display_name) like '%'||v_query||'%' or lower(c.code) like '%'||v_query||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.display_name,'secondary',x.code) order by x.display_name,x.id),'[]'::jsonb)
    into v_items from (
      select c.id,c.display_name,c.code from public.customers c
      where c.company_id=p_company_id and c.is_active
        and (v_query='' or lower(c.display_name) like '%'||v_query||'%' or lower(c.code) like '%'||v_query||'%')
      order by c.display_name,c.id limit v_size offset (v_page-1)*v_size
    )x;
  else
    select count(*) into v_total from public.suppliers s
    where s.company_id=p_company_id and s.is_active
      and (v_query='' or lower(s.display_name) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.display_name,'secondary',x.code) order by x.display_name,x.id),'[]'::jsonb)
    into v_items from (
      select s.id,s.display_name,s.code from public.suppliers s
      where s.company_id=p_company_id and s.is_active
        and (v_query='' or lower(s.display_name) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%')
      order by s.display_name,s.id limit v_size offset (v_page-1)*v_size
    )x;
  end if;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.bi_get_executive_summary(
  p_company_id uuid,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_days integer;
  v_currency text;
  v_previous_from date;
  v_previous_to date;
  v_sales numeric:=0;v_sales_previous numeric:=0;v_tickets bigint:=0;v_tickets_previous bigint:=0;
  v_collections numeric:=0;v_collections_previous numeric:=0;v_supplier_payments numeric:=0;v_supplier_payments_previous numeric:=0;
  v_bank_flow numeric:=0;v_bank_flow_previous numeric:=0;v_cxc numeric:=0;v_cxc_overdue numeric:=0;v_cxp numeric:=0;v_cxp_overdue numeric:=0;
  v_inventory_value numeric:=0;v_inventory_missing_cost bigint:=0;v_inventory_rows bigint:=0;
  v_payroll_accrued numeric:=0;v_payroll_paid numeric:=0;v_bank_total bigint:=0;v_bank_reconciled bigint:=0;
  v_series jsonb;v_locations jsonb;v_metrics jsonb;
  v_sales_available boolean:=p_supplier_id is null;
  v_collections_available boolean:=p_supplier_id is null;
  v_supplier_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null;
  v_bank_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null;
  v_cxc_available boolean:=p_supplier_id is null;
  v_cxp_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null and p_date_to=current_date;
  v_inventory_available boolean:=p_customer_id is null and p_supplier_id is null and p_date_to=current_date;
  v_payroll_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from then raise exception 'Periodo de BI inválido.';end if;
  v_days:=p_date_to-p_date_from+1;
  if v_days>366 then raise exception 'El Resumen ejecutivo admite periodos de hasta 366 días.';end if;
  v_previous_to:=p_date_from-1;v_previous_from:=v_previous_to-v_days+1;
  if p_location_id is not null and not exists(
    select 1 from public.locations l where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.';end if;
  if p_product_id is not null and not exists(select 1 from public.products p where p.id=p_product_id and p.company_id=p_company_id) then raise exception 'Producto no disponible.';end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id) then raise exception 'Cliente no disponible.';end if;
  if p_supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id) then raise exception 'Proveedor no disponible.';end if;
  select c.base_currency into v_currency from public.accounting_config_versions c where c.company_id=p_company_id and c.status='approved';

  if v_sales_available then
    select coalesce(sum(case when s.completed_at::date between p_date_from and p_date_to then
      case when p_product_id is null then s.subtotal_amount-s.discount_amount else
        (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id) end else 0 end),0),
      coalesce(sum(case when s.completed_at::date between v_previous_from and v_previous_to then
      case when p_product_id is null then s.subtotal_amount-s.discount_amount else
        (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id) end else 0 end),0),
      count(*) filter(where s.completed_at::date between p_date_from and p_date_to),
      count(*) filter(where s.completed_at::date between v_previous_from and v_previous_to)
    into v_sales,v_sales_previous,v_tickets,v_tickets_previous
    from public.sales s
    where s.company_id=p_company_id and public.can_access_location(s.location_id)
      and s.completed_at::date between v_previous_from and p_date_to
      and (v_currency is null or s.currency_code=v_currency)
      and (p_location_id is null or s.location_id=p_location_id)
      and (p_customer_id is null or s.customer_id=p_customer_id)
      and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id);
  end if;

  if v_collections_available then
    select coalesce(sum(case when rp.received_at::date between p_date_from and p_date_to then rp.amount else 0 end),0),
      coalesce(sum(case when rp.received_at::date between v_previous_from and v_previous_to then rp.amount else 0 end),0)
    into v_collections,v_collections_previous
    from public.receivable_payments rp
    where rp.company_id=p_company_id and rp.received_at::date between v_previous_from and p_date_to
      and v_currency is not null
      and (p_customer_id is null or rp.customer_id=p_customer_id)
      and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id)
      and exists(
        select 1 from public.receivable_payment_applications rpa
        join public.customer_receivables cr on cr.id=rpa.receivable_id
        join public.sales s on s.id=cr.sale_id
        where rpa.receivable_payment_id=rp.id and public.can_access_location(s.location_id)
          and s.currency_code=v_currency and (p_location_id is null or s.location_id=p_location_id)
          and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
      );
  end if;

  if v_supplier_available then
    select coalesce(sum(case when sp.effective_date between p_date_from and p_date_to then sp.total_amount else 0 end),0),
      coalesce(sum(case when sp.effective_date between v_previous_from and v_previous_to then sp.total_amount else 0 end),0)
    into v_supplier_payments,v_supplier_payments_previous
    from public.supplier_payments sp where sp.company_id=p_company_id and sp.status='confirmed'
      and sp.effective_date between v_previous_from and p_date_to and sp.currency_code=v_currency and (p_supplier_id is null or sp.supplier_id=p_supplier_id);
  end if;

  if v_bank_available then
    select coalesce(sum(case when bt.transaction_date between p_date_from and p_date_to then case when bt.direction='credit' then bt.amount else -bt.amount end else 0 end),0),
      coalesce(sum(case when bt.transaction_date between v_previous_from and v_previous_to then case when bt.direction='credit' then bt.amount else -bt.amount end else 0 end),0),
      count(*) filter(where bt.transaction_date between p_date_from and p_date_to),
      count(*) filter(where bt.transaction_date between p_date_from and p_date_to and exists(select 1 from public.bank_reconciliations br where br.bank_transaction_id=bt.id and br.status='confirmed'))
    into v_bank_flow,v_bank_flow_previous,v_bank_total,v_bank_reconciled
    from public.bank_transactions bt where bt.company_id=p_company_id and bt.currency_code=v_currency and bt.transaction_date between v_previous_from and p_date_to;
  end if;

  if v_cxc_available then
    select coalesce(sum(greatest(cr.original_amount-coalesce((
      select sum(rpa.amount) from public.receivable_payment_applications rpa
      join public.receivable_payments rp on rp.id=rpa.receivable_payment_id
      where rpa.receivable_id=cr.id and rp.received_at<(p_date_to+1)::timestamptz
        and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(p_date_to+1)::timestamptz)
    ),0),0)),0),
    coalesce(sum(case when cr.due_date<p_date_to then greatest(cr.original_amount-coalesce((
      select sum(rpa.amount) from public.receivable_payment_applications rpa join public.receivable_payments rp on rp.id=rpa.receivable_payment_id
      where rpa.receivable_id=cr.id and rp.received_at<(p_date_to+1)::timestamptz
        and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(p_date_to+1)::timestamptz)
    ),0),0) else 0 end),0)
    into v_cxc,v_cxc_overdue
    from public.customer_receivables cr join public.sales s on s.id=cr.sale_id
    where cr.company_id=p_company_id and s.currency_code=v_currency and cr.issued_at<(p_date_to+1)::timestamptz and public.can_access_location(s.location_id)
      and (p_location_id is null or s.location_id=p_location_id) and (p_customer_id is null or cr.customer_id=p_customer_id)
      and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id and sc.cancelled_at<(p_date_to+1)::timestamptz);
  end if;

  if v_cxp_available then
    select coalesce(sum(ap.outstanding_amount),0),coalesce(sum(ap.outstanding_amount) filter(where ap.due_date<current_date),0)
    into v_cxp,v_cxp_overdue from public.accounts_payable ap
    where ap.company_id=p_company_id and ap.currency_code=v_currency and ap.reversed_at is null and (p_supplier_id is null or ap.supplier_id=p_supplier_id);
  end if;

  if v_inventory_available then
    select coalesce(sum(ib.quantity_on_hand*pc.amount),0),count(*) filter(where ib.quantity_on_hand<>0 and pc.amount is null),count(*) filter(where ib.quantity_on_hand<>0)
    into v_inventory_value,v_inventory_missing_cost,v_inventory_rows
    from public.inventory_balances ib
    left join lateral(
      select c.amount from public.product_costs c
      left join public.accounting_event_rule_sets rs on rs.company_id=c.company_id and rs.status='approved'
      where c.company_id=p_company_id and c.product_id=ib.product_id and c.currency_code=v_currency and c.cost_type=coalesce(rs.cost_method,'replacement_cost')
        and c.valid_from<=now() and (c.valid_to is null or c.valid_to>now()) order by c.valid_from desc,c.id desc limit 1
    )pc on true
    where ib.company_id=p_company_id and public.can_access_location(ib.location_id)
      and (p_location_id is null or ib.location_id=p_location_id) and (p_product_id is null or ib.product_id=p_product_id);
  end if;

  if v_payroll_available then
    select coalesce(sum(l.total_pay) filter(where p.status in('approved','paid')),0),
      coalesce(sum(l.total_pay) filter(where p.status='paid'),0)
    into v_payroll_accrued,v_payroll_paid
    from public.payroll_periods p join public.payroll_period_lines l on l.payroll_period_id=p.id
    where p.company_id=p_company_id and p.payment_date between p_date_from and p_date_to;
  end if;

  with series_dates as (
    select generated_at::date as series_date
    from generate_series(
      p_date_from::timestamp,
      p_date_to::timestamp,
      interval '1 day'
    ) as generated_dates(generated_at)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date',d.series_date,
    'sales',case when v_sales_available and v_currency is not null then coalesce((select sum(case when p_product_id is null then s.subtotal_amount-s.discount_amount else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id) end) from public.sales s where s.company_id=p_company_id and s.currency_code=v_currency and s.completed_at::date=d.series_date and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id) and (p_customer_id is null or s.customer_id=p_customer_id) and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)) and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)),0) end,
    'collections',case when v_collections_available and v_currency is not null then coalesce((select sum(rp.amount) from public.receivable_payments rp where rp.company_id=p_company_id and rp.received_at::date=d.series_date and (p_customer_id is null or rp.customer_id=p_customer_id) and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id) and exists(select 1 from public.receivable_payment_applications rpa join public.customer_receivables cr on cr.id=rpa.receivable_id join public.sales s on s.id=cr.sale_id where rpa.receivable_payment_id=rp.id and s.currency_code=v_currency and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id) and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)))),0) end,
    'supplier_payments',case when v_supplier_available and v_currency is not null then coalesce((select sum(sp.total_amount) from public.supplier_payments sp where sp.company_id=p_company_id and sp.currency_code=v_currency and sp.status='confirmed' and sp.effective_date=d.series_date and (p_supplier_id is null or sp.supplier_id=p_supplier_id)),0) end
  ) order by d.series_date),'[]'::jsonb) into v_series from series_dates d;

  select coalesce(jsonb_agg(jsonb_build_object('location_id',x.id,'location_name',x.name,'sales',x.sales,'tickets',x.tickets) order by x.sales desc,x.name),'[]'::jsonb)
  into v_locations from(
    select l.id,l.name,coalesce(sum(case when s.id is not null then case when p_product_id is null then s.subtotal_amount-s.discount_amount else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id) end end),0) sales,count(s.id) tickets
    from public.locations l left join public.sales s on s.location_id=l.id and s.completed_at::date between p_date_from and p_date_to
      and (p_customer_id is null or s.customer_id=p_customer_id) and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
      and s.currency_code=v_currency and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id) and v_sales_available and (p_location_id is null or l.id=p_location_id)
    group by l.id,l.name order by sales desc,l.name limit 12
  )x;

  v_metrics:=jsonb_build_array(
    jsonb_build_object('code','net_sales','value',v_sales,'previous_value',v_sales_previous,'available',v_sales_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_sales_available then 'Proveedor no es una dimensión comprobada de ventas.' end),
    jsonb_build_object('code','tickets','value',v_tickets,'previous_value',v_tickets_previous,'available',v_sales_available,'reason',case when not v_sales_available then 'Proveedor no es una dimensión comprobada de ventas.' end),
    jsonb_build_object('code','average_ticket','value',case when v_tickets>0 then round(v_sales/v_tickets,2) end,'previous_value',case when v_tickets_previous>0 then round(v_sales_previous/v_tickets_previous,2) end,'available',v_sales_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_sales_available then 'Proveedor no es una dimensión comprobada de ventas.' end),
    jsonb_build_object('code','collections','value',v_collections,'previous_value',v_collections_previous,'available',v_collections_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_collections_available then 'Proveedor no es una dimensión comprobada de cobranza.' end),
    jsonb_build_object('code','supplier_payments','value',v_supplier_payments,'previous_value',v_supplier_payments_previous,'available',v_supplier_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_supplier_available then 'Pagos a proveedor no se atribuyen a esta dimensión sin una relación única.' end),
    jsonb_build_object('code','bank_net_flow','value',v_bank_flow,'previous_value',v_bank_flow_previous,'available',v_bank_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_bank_available then 'El movimiento bancario requiere conciliación antes de atribuir esta dimensión.' end),
    jsonb_build_object('code','receivables','value',v_cxc,'available',v_cxc_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end),
    jsonb_build_object('code','overdue_receivables','value',v_cxc_overdue,'available',v_cxc_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end),
    jsonb_build_object('code','payables','value',v_cxp,'available',v_cxp_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxp_available then 'CxP histórica o esta dimensión requieren una reconstrucción no disponible en Fase 1.' end),
    jsonb_build_object('code','inventory_value','value',v_inventory_value,'available',v_inventory_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_inventory_available then 'Inventario es una posición actual por producto y ubicación.' end,'coverage',case when v_inventory_rows=0 then null else round(100.0*(v_inventory_rows-v_inventory_missing_cost)/v_inventory_rows,1) end),
    jsonb_build_object('code','payroll_accrued','value',v_payroll_accrued,'available',false,'reason','Nómina todavía no conserva moneda canónica en sus corridas.'),
    jsonb_build_object('code','bank_reconciliation','value',case when v_bank_total>0 then round(100.0*v_bank_reconciled/v_bank_total,1) end,'available',v_bank_available and v_currency is not null,'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_bank_available then 'La conciliación bancaria no se atribuye a esta dimensión.' end)
  );

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.executive_summary_queried','bi_query',jsonb_build_object('date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id));

  return jsonb_build_object(
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to,'previous_from',v_previous_from,'previous_to',v_previous_to,'days',v_days),'currency_code',v_currency,
    'updated_at',now(),'metrics',v_metrics,'series',v_series,'locations',v_locations,
    'trace',jsonb_build_object('query','bi_get_executive_summary','sources',jsonb_build_array('sales','receivable_payments','supplier_payments','bank_transactions','customer_receivables','accounts_payable','inventory_balances','product_costs','payroll_periods'),'company_id',p_company_id)
  );
end $$;

create or replace function public.bi_get_drilldown(
  p_company_id uuid,
  p_metric_code text,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_code text:=lower(trim(coalesce(p_metric_code,'')));v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint:=0;v_items jsonb:='[]'::jsonb;v_source_path text;v_currency text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from+1>366 then raise exception 'Periodo de BI inválido.';end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then raise exception 'Ubicación no disponible.';end if;
  select c.base_currency into v_currency from public.accounting_config_versions c where c.company_id=p_company_id and c.status='approved';
  if v_currency is null and v_code<>'tickets' then raise exception 'Falta una moneda base contable aprobada.';end if;

  if v_code in('net_sales','tickets','average_ticket') then
    with filtered as materialized(
      select s.id,s.completed_at occurred_at,l.name location_name,coalesce(c.display_name,'Público general') party,s.sale_type,
        case when p_product_id is null then s.subtotal_amount-s.discount_amount else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id) end amount
      from public.sales s join public.locations l on l.id=s.location_id left join public.customers c on c.id=s.customer_id
      where s.company_id=p_company_id and (v_code='tickets' or s.currency_code=v_currency) and s.completed_at::date between p_date_from and p_date_to and public.can_access_location(s.location_id)
        and (p_location_id is null or s.location_id=p_location_id) and (p_customer_id is null or s.customer_id=p_customer_id) and p_supplier_id is null
        and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
        and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/ventas/historial';
  elsif v_code='collections' then
    with filtered as materialized(
      select rp.id,rp.received_at occurred_at,c.display_name party,rp.payment_method_code detail,rp.amount
      from public.receivable_payments rp join public.customers c on c.id=rp.customer_id
      where rp.company_id=p_company_id and rp.received_at::date between p_date_from and p_date_to and (p_customer_id is null or rp.customer_id=p_customer_id) and p_supplier_id is null
        and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id)
        and exists(select 1 from public.receivable_payment_applications a join public.customer_receivables cr on cr.id=a.receivable_id join public.sales s on s.id=cr.sale_id where a.receivable_payment_id=rp.id and s.currency_code=v_currency and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id) and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)))
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/ventas/cuentas-por-cobrar';
  elsif v_code='supplier_payments' then
    with filtered as materialized(
      select sp.id,sp.effective_date occurred_at,s.display_name party,sp.reference detail,sp.total_amount amount
      from public.supplier_payments sp join public.suppliers s on s.id=sp.supplier_id
      where sp.company_id=p_company_id and sp.currency_code=v_currency and sp.status='confirmed' and sp.effective_date between p_date_from and p_date_to and (p_supplier_id is null or sp.supplier_id=p_supplier_id)
        and p_location_id is null and p_product_id is null and p_customer_id is null
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/compras/facturas';
  elsif v_code in('bank_net_flow','bank_reconciliation') then
    with filtered as materialized(
      select bt.id,bt.transaction_date occurred_at,fa.alias party,coalesce(bt.description,bt.reference) detail,case when bt.direction='credit' then bt.amount else -bt.amount end amount
      from public.bank_transactions bt join public.financial_accounts fa on fa.id=bt.financial_account_id
      where bt.company_id=p_company_id and bt.currency_code=v_currency and bt.transaction_date between p_date_from and p_date_to and p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/contabilidad/bancos';
  elsif v_code in('receivables','overdue_receivables') then
    with filtered as materialized(
      select cr.id,cr.issued_at occurred_at,c.display_name party,'Vence '||cr.due_date::text detail,cr.outstanding_amount amount
      from public.customer_receivables cr join public.customers c on c.id=cr.customer_id join public.sales s on s.id=cr.sale_id
      where cr.company_id=p_company_id and s.currency_code=v_currency and cr.outstanding_amount>0 and public.can_access_location(s.location_id) and (p_location_id is null or s.location_id=p_location_id)
        and (p_customer_id is null or cr.customer_id=p_customer_id) and p_supplier_id is null and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
        and (v_code<>'overdue_receivables' or cr.due_date<current_date)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/ventas/cuentas-por-cobrar';
  elsif v_code='payables' then
    with filtered as materialized(
      select ap.id,ap.issued_date occurred_at,s.display_name party,'Vence '||ap.due_date::text detail,ap.outstanding_amount amount
      from public.accounts_payable ap join public.suppliers s on s.id=ap.supplier_id
      where ap.company_id=p_company_id and ap.currency_code=v_currency and ap.outstanding_amount>0 and ap.reversed_at is null and (p_supplier_id is null or ap.supplier_id=p_supplier_id)
        and p_location_id is null and p_product_id is null and p_customer_id is null
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/compras/facturas';
  elsif v_code='inventory_value' then
    with filtered as materialized(
      select p.id,ib.updated_at occurred_at,p.name party,l.name detail,ib.quantity_on_hand*coalesce(pc.amount,0) amount
      from public.inventory_balances ib join public.products p on p.id=ib.product_id join public.locations l on l.id=ib.location_id
      left join lateral(select c.amount from public.product_costs c left join public.accounting_event_rule_sets rs on rs.company_id=c.company_id and rs.status='approved' where c.company_id=p_company_id and c.product_id=ib.product_id and c.currency_code=v_currency and c.cost_type=coalesce(rs.cost_method,'replacement_cost') and c.valid_from<=now() and(c.valid_to is null or c.valid_to>now()) order by c.valid_from desc,c.id desc limit 1)pc on true
      where ib.company_id=p_company_id and ib.quantity_on_hand<>0 and public.can_access_location(ib.location_id) and(p_location_id is null or ib.location_id=p_location_id) and(p_product_id is null or ib.product_id=p_product_id) and p_customer_id is null and p_supplier_id is null
    ),paged as(select * from filtered order by amount desc,id limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by amount desc,id),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/inventario/existencias';
  elsif v_code='payroll_accrued' then
    with filtered as materialized(
      select p.id,p.payment_date occurred_at,p.payment_frequency party,p.status detail,sum(l.total_pay) amount
      from public.payroll_periods p join public.payroll_period_lines l on l.payroll_period_id=p.id
      where p.company_id=p_company_id and p.status in('approved','paid') and p.payment_date between p_date_from and p_date_to
        and p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null group by p.id
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
    v_source_path:='/satrapy/colaboradores/nomina';
  else raise exception 'KPI de BI no disponible para detalle.';end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.drilldown_queried','bi_query',jsonb_build_object('metric_code',v_code,'page',v_page,'page_size',v_size));
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)),'source_path',v_source_path,'metric_code',v_code);
end $$;

revoke all on function public.bi_search_filter_options(uuid,text,text,integer,integer) from public;
revoke all on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) from public;
revoke all on function public.bi_get_drilldown(uuid,text,date,date,uuid,uuid,uuid,uuid,integer,integer) from public;
grant execute on function public.bi_search_filter_options(uuid,text,text,integer,integer) to authenticated;
grant execute on function public.bi_get_executive_summary(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.bi_get_drilldown(uuid,text,date,date,uuid,uuid,uuid,uuid,integer,integer) to authenticated;
