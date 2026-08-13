-- Historical sales make the former per-day correlated executive series exceed
-- the interactive statement budget. Keep BI as a read-only projection: scan
-- each canonical source once, aggregate by day server-side and reuse the
-- existing timestamp index through half-open ranges.

create index if not exists sales_company_currency_completed_idx
  on public.sales(company_id,currency_code,completed_at,location_id)
  include(customer_id,subtotal_amount,discount_amount);

create or replace function public.bi_get_executive_summary_before_recognized_cost(
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

  -- Totals and the daily series share one bounded scan per source. Location
  -- authorization is evaluated per location, not once per historical sale.
  with accessible_locations as materialized (
    select l.id
    from public.locations l
    where l.company_id=p_company_id
      and public.can_access_location(l.id)
      and (p_location_id is null or l.id=p_location_id)
  ), selected_sale_items as materialized (
    select item.sale_id,sum(item.taxable_amount) amount
    from public.sale_items item
    where p_product_id is not null and item.product_id=p_product_id
    group by item.sale_id
  ), sales_daily as materialized (
    select sale_data.completed_at::date occurred_on,
      sum(case when p_product_id is null
        then sale_data.subtotal_amount-sale_data.discount_amount
        else selected_item.amount end) amount,
      count(*)::bigint ticket_count
    from public.sales sale_data
    join accessible_locations location_access on location_access.id=sale_data.location_id
    left join selected_sale_items selected_item on selected_item.sale_id=sale_data.id
    left join public.sale_cancellations cancellation on cancellation.sale_id=sale_data.id
    where v_sales_available
      and sale_data.company_id=p_company_id
      and sale_data.completed_at>=v_previous_from::timestamptz
      and sale_data.completed_at<(p_date_to+1)::timestamptz
      and (v_currency is null or sale_data.currency_code=v_currency)
      and (p_customer_id is null or sale_data.customer_id=p_customer_id)
      and (p_product_id is null or selected_item.sale_id is not null)
      and cancellation.sale_id is null
    group by sale_data.completed_at::date
  ), collections_daily as materialized (
    select payment.received_at::date occurred_on,sum(payment.amount) amount
    from public.receivable_payments payment
    left join public.receivable_payment_reversals reversal
      on reversal.receivable_payment_id=payment.id
    where v_collections_available and v_currency is not null
      and payment.company_id=p_company_id
      and payment.received_at>=v_previous_from::timestamptz
      and payment.received_at<(p_date_to+1)::timestamptz
      and (p_customer_id is null or payment.customer_id=p_customer_id)
      and reversal.receivable_payment_id is null
      and exists(
        select 1
        from public.receivable_payment_applications application
        join public.customer_receivables receivable on receivable.id=application.receivable_id
        join public.sales sale_data on sale_data.id=receivable.sale_id
        join accessible_locations location_access on location_access.id=sale_data.location_id
        left join selected_sale_items selected_item on selected_item.sale_id=sale_data.id
        where application.receivable_payment_id=payment.id
          and sale_data.currency_code=v_currency
          and (p_product_id is null or selected_item.sale_id is not null)
      )
    group by payment.received_at::date
  ), supplier_payments_daily as materialized (
    select payment.effective_date occurred_on,sum(payment.total_amount) amount
    from public.supplier_payments payment
    where v_supplier_available and v_currency is not null
      and payment.company_id=p_company_id
      and payment.status='confirmed'
      and payment.currency_code=v_currency
      and payment.effective_date between v_previous_from and p_date_to
      and (p_supplier_id is null or payment.supplier_id=p_supplier_id)
    group by payment.effective_date
  ), totals as (
    select
      coalesce((select sum(amount) from sales_daily where occurred_on between p_date_from and p_date_to),0) sales,
      coalesce((select sum(amount) from sales_daily where occurred_on between v_previous_from and v_previous_to),0) sales_previous,
      coalesce((select sum(ticket_count) from sales_daily where occurred_on between p_date_from and p_date_to),0)::bigint tickets,
      coalesce((select sum(ticket_count) from sales_daily where occurred_on between v_previous_from and v_previous_to),0)::bigint tickets_previous,
      coalesce((select sum(amount) from collections_daily where occurred_on between p_date_from and p_date_to),0) collections,
      coalesce((select sum(amount) from collections_daily where occurred_on between v_previous_from and v_previous_to),0) collections_previous,
      coalesce((select sum(amount) from supplier_payments_daily where occurred_on between p_date_from and p_date_to),0) supplier_payments,
      coalesce((select sum(amount) from supplier_payments_daily where occurred_on between v_previous_from and v_previous_to),0) supplier_payments_previous
  ), series_dates as (
    select generated_at::date series_date
    from generate_series(p_date_from::timestamp,p_date_to::timestamp,interval '1 day') generated(generated_at)
  ), series_payload as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'date',day_data.series_date,
      'sales',case when v_sales_available and v_currency is not null then coalesce(sales.amount,0) end,
      'collections',case when v_collections_available and v_currency is not null then coalesce(collections.amount,0) end,
      'supplier_payments',case when v_supplier_available and v_currency is not null then coalesce(supplier_payments.amount,0) end
    ) order by day_data.series_date),'[]'::jsonb) payload
    from series_dates day_data
    left join sales_daily sales on sales.occurred_on=day_data.series_date
    left join collections_daily collections on collections.occurred_on=day_data.series_date
    left join supplier_payments_daily supplier_payments on supplier_payments.occurred_on=day_data.series_date
  )
  select totals.sales,totals.sales_previous,totals.tickets,totals.tickets_previous,
    totals.collections,totals.collections_previous,
    totals.supplier_payments,totals.supplier_payments_previous,series_payload.payload
  into v_sales,v_sales_previous,v_tickets,v_tickets_previous,
    v_collections,v_collections_previous,v_supplier_payments,v_supplier_payments_previous,v_series
  from totals cross join series_payload;

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

  with accessible_locations as materialized (
    select location_data.id,location_data.name
    from public.locations location_data
    where location_data.company_id=p_company_id and location_data.is_active
      and public.can_access_location(location_data.id)
      and (p_location_id is null or location_data.id=p_location_id)
  ), selected_sale_items as materialized (
    select item.sale_id,sum(item.taxable_amount) amount
    from public.sale_items item
    where p_product_id is not null and item.product_id=p_product_id
    group by item.sale_id
  ), location_sales as materialized (
    select sale_data.location_id,
      sum(case when p_product_id is null
        then sale_data.subtotal_amount-sale_data.discount_amount
        else selected_item.amount end) sales,
      count(*)::bigint tickets
    from public.sales sale_data
    join accessible_locations location_access on location_access.id=sale_data.location_id
    left join selected_sale_items selected_item on selected_item.sale_id=sale_data.id
    left join public.sale_cancellations cancellation on cancellation.sale_id=sale_data.id
    where v_sales_available and v_currency is not null
      and sale_data.company_id=p_company_id and sale_data.currency_code=v_currency
      and sale_data.completed_at>=p_date_from::timestamptz
      and sale_data.completed_at<(p_date_to+1)::timestamptz
      and (p_customer_id is null or sale_data.customer_id=p_customer_id)
      and (p_product_id is null or selected_item.sale_id is not null)
      and cancellation.sale_id is null
    group by sale_data.location_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'location_id',ranked.id,'location_name',ranked.name,
    'sales',ranked.sales,'tickets',ranked.tickets
  ) order by ranked.sales desc,ranked.name),'[]'::jsonb)
  into v_locations
  from (
    select location_data.id,location_data.name,
      coalesce(location_sales.sales,0) sales,coalesce(location_sales.tickets,0) tickets
    from accessible_locations location_data
    left join location_sales on location_sales.location_id=location_data.id
    order by sales desc,location_data.name
    limit 12
  ) ranked;

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

revoke all on function public.bi_get_executive_summary_before_recognized_cost(uuid,date,date,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;

create or replace function public.bi_get_executive_charts_before_recognized_cost(
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
  v_previous_from date;
  v_previous_to date;
  v_currency text;
  v_sales_available boolean:=p_supplier_id is null;
  v_bank_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null;
  v_cxc_available boolean:=p_supplier_id is null;
  v_cxp_available boolean:=p_location_id is null and p_product_id is null and p_customer_id is null;
  v_inventory_available boolean:=p_customer_id is null and p_supplier_id is null;
  v_sales_points jsonb:='[]'::jsonb;
  v_bank_points jsonb:='[]'::jsonb;
  v_cxc numeric:=0;v_cxc_previous numeric:=0;v_cxc_overdue numeric:=0;v_cxc_overdue_previous numeric:=0;
  v_cxp numeric:=0;v_cxp_previous numeric:=0;
  v_inventory numeric:=0;v_inventory_previous numeric:=0;
  v_inventory_rows bigint:=0;v_inventory_missing_cost bigint:=0;
  v_inventory_previous_rows bigint:=0;v_inventory_previous_missing_cost bigint:=0;
  v_charts jsonb;v_comparisons jsonb;
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

  if v_sales_available and v_currency is not null then
    with accessible_locations as materialized (
      select location_data.id
      from public.locations location_data
      where location_data.company_id=p_company_id
        and public.can_access_location(location_data.id)
        and (p_location_id is null or location_data.id=p_location_id)
    ), selected_sale_items as materialized (
      select item.sale_id,sum(item.taxable_amount) amount
      from public.sale_items item
      where p_product_id is not null and item.product_id=p_product_id
      group by item.sale_id
    ), daily as materialized (
      select sale_data.completed_at::date occurred_on,
        sum(case when p_product_id is null
          then sale_data.subtotal_amount-sale_data.discount_amount
          else selected_item.amount end) amount
      from public.sales sale_data
      join accessible_locations location_access on location_access.id=sale_data.location_id
      left join selected_sale_items selected_item on selected_item.sale_id=sale_data.id
      left join public.sale_cancellations cancellation on cancellation.sale_id=sale_data.id
      where sale_data.company_id=p_company_id and sale_data.currency_code=v_currency
        and sale_data.completed_at>=v_previous_from::timestamptz
        and sale_data.completed_at<(p_date_to+1)::timestamptz
        and (p_customer_id is null or sale_data.customer_id=p_customer_id)
        and (p_product_id is null or selected_item.sale_id is not null)
        and cancellation.sale_id is null
      group by sale_data.completed_at::date
    ), day_axis as (
      select day_index,p_date_from+day_index current_date,v_previous_from+day_index previous_date
      from generate_series(0,v_days-1) indices(day_index)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'index',day_data.day_index,'date',day_data.current_date,'value',coalesce(current_day.amount,0),
      'previous_date',day_data.previous_date,'previous_value',coalesce(previous_day.amount,0)
    ) order by day_data.day_index),'[]'::jsonb)
    into v_sales_points
    from day_axis day_data
    left join daily current_day on current_day.occurred_on=day_data.current_date
    left join daily previous_day on previous_day.occurred_on=day_data.previous_date;
  end if;

  if v_bank_available and v_currency is not null then
    with day_axis as (
      select day_index,p_date_from+day_index current_date,v_previous_from+day_index previous_date
      from generate_series(0,v_days-1) indices(day_index)
    ), daily as materialized (
      select transaction_data.transaction_date occurred_on,
        sum(case when transaction_data.direction='credit' then transaction_data.amount else -transaction_data.amount end) amount
      from public.bank_transactions transaction_data
      where transaction_data.company_id=p_company_id and transaction_data.currency_code=v_currency
        and transaction_data.transaction_date between v_previous_from and p_date_to
      group by transaction_data.transaction_date
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'index',day_data.day_index,'date',day_data.current_date,'value',coalesce(current_day.amount,0),
      'previous_date',day_data.previous_date,'previous_value',coalesce(previous_day.amount,0)
    ) order by day_data.day_index),'[]'::jsonb)
    into v_bank_points
    from day_axis day_data
    left join daily current_day on current_day.occurred_on=day_data.current_date
    left join daily previous_day on previous_day.occurred_on=day_data.previous_date;
  end if;

  if v_cxc_available and v_currency is not null then
    with receivable_positions as materialized (
      select receivable.id,receivable.issued_at,receivable.due_date,
        case when receivable.issued_at<(p_date_to+1)::timestamptz
          and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=receivable.sale_id and cancellation.cancelled_at<(p_date_to+1)::timestamptz)
          then greatest(receivable.original_amount-coalesce((
            select sum(application.amount)
            from public.receivable_payment_applications application
            join public.receivable_payments payment on payment.id=application.receivable_payment_id
            where application.receivable_id=receivable.id and application.created_at<(p_date_to+1)::timestamptz and payment.received_at<(p_date_to+1)::timestamptz
              and not exists(select 1 from public.receivable_payment_reversals reversal where reversal.receivable_payment_id=payment.id and reversal.reversed_at<(p_date_to+1)::timestamptz)
          ),0),0) else 0 end current_balance,
        case when receivable.issued_at<(v_previous_to+1)::timestamptz
          and not exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=receivable.sale_id and cancellation.cancelled_at<(v_previous_to+1)::timestamptz)
          then greatest(receivable.original_amount-coalesce((
            select sum(application.amount)
            from public.receivable_payment_applications application
            join public.receivable_payments payment on payment.id=application.receivable_payment_id
            where application.receivable_id=receivable.id and application.created_at<(v_previous_to+1)::timestamptz and payment.received_at<(v_previous_to+1)::timestamptz
              and not exists(select 1 from public.receivable_payment_reversals reversal where reversal.receivable_payment_id=payment.id and reversal.reversed_at<(v_previous_to+1)::timestamptz)
          ),0),0) else 0 end previous_balance
      from public.customer_receivables receivable
      join public.sales sale_data on sale_data.id=receivable.sale_id
      where receivable.company_id=p_company_id and sale_data.currency_code=v_currency
        and public.can_access_location(sale_data.location_id)
        and (p_location_id is null or sale_data.location_id=p_location_id)
        and (p_customer_id is null or receivable.customer_id=p_customer_id)
        and (p_product_id is null or exists(select 1 from public.sale_items item where item.sale_id=sale_data.id and item.product_id=p_product_id))
    )
    select coalesce(sum(current_balance),0),coalesce(sum(previous_balance),0),
      coalesce(sum(current_balance) filter(where due_date<p_date_to),0),
      coalesce(sum(previous_balance) filter(where due_date<v_previous_to),0)
    into v_cxc,v_cxc_previous,v_cxc_overdue,v_cxc_overdue_previous
    from receivable_positions;
  end if;

  if v_cxp_available and v_currency is not null then
    if p_supplier_id is null then
      select amount into v_cxp from public.canonical_accounting_auxiliaries(p_company_id,p_date_to) where control_key='accounts_payable';
      select amount into v_cxp_previous from public.canonical_accounting_auxiliaries(p_company_id,v_previous_to) where control_key='accounts_payable';
    else
      with payable_positions as materialized (
        select payable.id,
          greatest(0,payable.original_base_amount
            -coalesce((select sum(case when credit_note.base_total>0 then credit_note.base_total else credit_note.total*credit_note.exchange_rate end)
              from public.supplier_invoices credit_note where credit_note.original_invoice_id=payable.supplier_invoice_id and credit_note.company_id=p_company_id
                and credit_note.document_type='credit_note' and credit_note.confirmed_at<(p_date_to+1)::timestamptz and credit_note.issued_date<=p_date_to
                and (credit_note.reversed_at is null or credit_note.reversed_at>=(p_date_to+1)::timestamptz)),0)
            -coalesce((select sum(application.amount*payable.exchange_rate)
              from public.supplier_payment_applications application join public.supplier_payments payment on payment.id=application.payment_id
              where application.accounts_payable_id=payable.id and application.applied_at<(p_date_to+1)::timestamptz and payment.effective_date<=p_date_to
                and payment.confirmed_at<(p_date_to+1)::timestamptz and (payment.reversed_at is null or payment.reversed_at>=(p_date_to+1)::timestamptz)),0)
          ) current_balance,
          greatest(0,payable.original_base_amount
            -coalesce((select sum(case when credit_note.base_total>0 then credit_note.base_total else credit_note.total*credit_note.exchange_rate end)
              from public.supplier_invoices credit_note where credit_note.original_invoice_id=payable.supplier_invoice_id and credit_note.company_id=p_company_id
                and credit_note.document_type='credit_note' and credit_note.confirmed_at<(v_previous_to+1)::timestamptz and credit_note.issued_date<=v_previous_to
                and (credit_note.reversed_at is null or credit_note.reversed_at>=(v_previous_to+1)::timestamptz)),0)
            -coalesce((select sum(application.amount*payable.exchange_rate)
              from public.supplier_payment_applications application join public.supplier_payments payment on payment.id=application.payment_id
              where application.accounts_payable_id=payable.id and application.applied_at<(v_previous_to+1)::timestamptz and payment.effective_date<=v_previous_to
                and payment.confirmed_at<(v_previous_to+1)::timestamptz and (payment.reversed_at is null or payment.reversed_at>=(v_previous_to+1)::timestamptz)),0)
          ) previous_balance
        from public.accounts_payable payable
        join public.supplier_invoices invoice on invoice.id=payable.supplier_invoice_id
        where payable.company_id=p_company_id and payable.supplier_id=p_supplier_id
          and payable.issued_date<=p_date_to and invoice.confirmed_at<(p_date_to+1)::timestamptz
      )
      select coalesce(sum(current_balance),0),coalesce(sum(previous_balance),0)
      into v_cxp,v_cxp_previous from payable_positions;
    end if;
  end if;

  if v_inventory_available and v_currency is not null then
    with quantities as materialized (
      select ledger.location_id,ledger.product_id,
        coalesce(sum(ledger.quantity_delta) filter(where ledger.occurred_at<(p_date_to+1)::timestamptz),0) current_quantity,
        coalesce(sum(ledger.quantity_delta) filter(where ledger.occurred_at<(v_previous_to+1)::timestamptz),0) previous_quantity
      from public.inventory_ledger ledger
      where ledger.company_id=p_company_id and ledger.occurred_at<(p_date_to+1)::timestamptz
        and public.can_access_location(ledger.location_id)
        and (p_location_id is null or ledger.location_id=p_location_id)
        and (p_product_id is null or ledger.product_id=p_product_id)
      group by ledger.location_id,ledger.product_id
    ), valued as (
      select quantity_data.*,current_cost.amount current_cost,previous_cost.amount previous_cost
      from quantities quantity_data
      left join lateral(
        select cost.amount from public.product_costs cost
        left join public.accounting_event_rule_sets rule_set on rule_set.company_id=cost.company_id and rule_set.status='approved'
        where cost.company_id=p_company_id and cost.product_id=quantity_data.product_id and cost.currency_code=v_currency
          and cost.cost_type=coalesce(rule_set.cost_method,'replacement_cost')
          and cost.valid_from<(p_date_to+1)::timestamptz and(cost.valid_to is null or cost.valid_to>p_date_to::timestamptz)
        order by cost.valid_from desc,cost.id desc limit 1
      )current_cost on true
      left join lateral(
        select cost.amount from public.product_costs cost
        left join public.accounting_event_rule_sets rule_set on rule_set.company_id=cost.company_id and rule_set.status='approved'
        where cost.company_id=p_company_id and cost.product_id=quantity_data.product_id and cost.currency_code=v_currency
          and cost.cost_type=coalesce(rule_set.cost_method,'replacement_cost')
          and cost.valid_from<(v_previous_to+1)::timestamptz and(cost.valid_to is null or cost.valid_to>v_previous_to::timestamptz)
        order by cost.valid_from desc,cost.id desc limit 1
      )previous_cost on true
    )
    select coalesce(sum(current_quantity*coalesce(current_cost,0)),0),
      coalesce(sum(previous_quantity*coalesce(previous_cost,0)),0),
      count(*) filter(where current_quantity<>0),count(*) filter(where current_quantity<>0 and current_cost is null),
      count(*) filter(where previous_quantity<>0),count(*) filter(where previous_quantity<>0 and previous_cost is null)
    into v_inventory,v_inventory_previous,v_inventory_rows,v_inventory_missing_cost,v_inventory_previous_rows,v_inventory_previous_missing_cost
    from valued;
  end if;

  v_comparisons:=jsonb_build_object(
    'receivables',jsonb_build_object('value',v_cxc,'previous_value',v_cxc_previous,'available',v_cxc_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end),
    'overdue_receivables',jsonb_build_object('value',v_cxc_overdue,'previous_value',v_cxc_overdue_previous,'available',v_cxc_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end),
    'payables',jsonb_build_object('value',v_cxp,'previous_value',v_cxp_previous,'available',v_cxp_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxp_available then 'CxP no se atribuye a ubicación, producto o cliente sin una relación única.' end),
    'inventory_value',jsonb_build_object('value',v_inventory,'previous_value',v_inventory_previous,
      'available',v_inventory_available and v_currency is not null and v_inventory_missing_cost=0 and v_inventory_previous_missing_cost=0,
      'coverage',case when v_inventory_rows=0 then null else round(100.0*(v_inventory_rows-v_inventory_missing_cost)/v_inventory_rows,1) end,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_inventory_available then 'Inventario no se atribuye a cliente o proveedor.'
        when v_inventory_missing_cost>0 or v_inventory_previous_missing_cost>0 then 'Hay saldos sin costo aprobado en el periodo actual o comparable.' end)
  );

  v_charts:=jsonb_build_array(
    jsonb_build_object('code','sales','metric_code','net_sales','kind','Devengado','visualization','line','available',v_sales_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_sales_available then 'Proveedor no es una dimensión comprobada de ventas.' end,'points',v_sales_points),
    jsonb_build_object('code','gross_margin','metric_code','gross_margin','kind','Devengado','visualization','line','available',false,
      'reason','No existe costo reconocido por partida vendida y fecha; usar costo vigente inventaría margen histórico.','points','[]'::jsonb),
    jsonb_build_object('code','cash_flow','metric_code','bank_net_flow','kind','Efectivo','visualization','area','available',v_bank_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_bank_available then 'El flujo bancario no se atribuye a estas dimensiones sin conciliación comprobada.' end,'points',v_bank_points),
    jsonb_build_object('code','receivables','metric_code','receivables','kind','Devengado','visualization','bars','available',v_cxc_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end,
      'points',jsonb_build_array(jsonb_build_object('date',v_previous_to,'period','previous','value',v_cxc_previous),jsonb_build_object('date',p_date_to,'period','current','value',v_cxc))),
    jsonb_build_object('code','payables','metric_code','payables','kind','Devengado','visualization','bars','available',v_cxp_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxp_available then 'CxP no se atribuye a ubicación, producto o cliente sin una relación única.' end,
      'points',jsonb_build_array(jsonb_build_object('date',v_previous_to,'period','previous','value',v_cxp_previous),jsonb_build_object('date',p_date_to,'period','current','value',v_cxp))),
    jsonb_build_object('code','inventory','metric_code','inventory_value','kind','Operativo','visualization','bars',
      'available',v_inventory_available and v_currency is not null and v_inventory_missing_cost=0 and v_inventory_previous_missing_cost=0,
      'reason',v_comparisons->'inventory_value'->>'reason','points',jsonb_build_array(
        jsonb_build_object('date',v_previous_to,'period','previous','value',v_inventory_previous),jsonb_build_object('date',p_date_to,'period','current','value',v_inventory)))
  );

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.executive_charts_queried','bi_query',jsonb_build_object(
    'date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id));
  return jsonb_build_object(
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to,'previous_from',v_previous_from,'previous_to',v_previous_to,'days',v_days),
    'updated_at',now(),'currency_code',v_currency,'charts',v_charts,'comparisons',v_comparisons,
    'trace',jsonb_build_object('query','bi_get_executive_charts','sources',jsonb_build_array(
      'sales','sale_items','bank_transactions','customer_receivables','receivable_payment_applications','accounts_payable','supplier_payment_applications','inventory_ledger','product_costs','canonical_accounting_auxiliaries'),'company_id',p_company_id)
  );
end $$;

revoke all on function public.bi_get_executive_charts_before_recognized_cost(uuid,date,date,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;

-- Preserve the decision-summary wrapper contract while replacing its
-- location comparison with one grouped scan.
create or replace function public.bi_get_executive_charts(
  p_company_id uuid,p_date_from date,p_date_to date,p_location_id uuid default null,
  p_product_id uuid default null,p_customer_id uuid default null,p_supplier_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payload jsonb;
  v_currency text;
  v_days integer;
  v_previous_from date;
  v_previous_to date;
  v_rows jsonb:='[]'::jsonb;
begin
  v_payload:=public.bi_get_executive_charts_before_decision_summary(
    p_company_id,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id
  );
  v_currency:=v_payload->>'currency_code';
  v_days:=p_date_to-p_date_from+1;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;

  if v_currency is not null and p_supplier_id is null then
    with accessible_locations as materialized (
      select location_data.id,location_data.name
      from public.locations location_data
      where location_data.company_id=p_company_id and location_data.is_active
        and public.can_access_location(location_data.id)
        and (p_location_id is null or location_data.id=p_location_id)
    ), selected_sale_items as materialized (
      select item.sale_id,sum(item.taxable_amount) amount
      from public.sale_items item
      where p_product_id is not null and item.product_id=p_product_id
      group by item.sale_id
    ), location_values as materialized (
      select location_data.id location_id,location_data.name location_name,
        coalesce(sum(case when sale_data.completed_at>=p_date_from::timestamptz
          then case when p_product_id is null
            then sale_data.subtotal_amount-sale_data.discount_amount
            else selected_item.amount end else 0 end),0) current_value,
        coalesce(sum(case when sale_data.completed_at<p_date_from::timestamptz
          then case when p_product_id is null
            then sale_data.subtotal_amount-sale_data.discount_amount
            else selected_item.amount end else 0 end),0) previous_value
      from accessible_locations location_data
      left join public.sales sale_data on sale_data.location_id=location_data.id
        and sale_data.company_id=p_company_id and sale_data.currency_code=v_currency
        and sale_data.completed_at>=v_previous_from::timestamptz
        and sale_data.completed_at<(p_date_to+1)::timestamptz
        and (p_customer_id is null or sale_data.customer_id=p_customer_id)
      left join selected_sale_items selected_item on selected_item.sale_id=sale_data.id
      left join public.sale_cancellations cancellation on cancellation.sale_id=sale_data.id
      where (p_product_id is null or selected_item.sale_id is not null)
        and cancellation.sale_id is null
      group by location_data.id,location_data.name
    ), ranked as (
      select *,sum(current_value) over() current_total
      from location_values
    ), ordered as (
      select *,case when previous_value>0 and current_value<previous_value then 'declining'
        when previous_value=0 and current_value>0 then 'new' else 'stable' end status
      from ranked
      order by case when previous_value>0 and current_value<previous_value then 0 else 1 end,
        abs(current_value-previous_value) desc,location_name
      limit 12
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'location_id',location_id,'location_name',location_name,
      'current_value',current_value,'previous_value',previous_value,
      'share_percent',case when current_total=0 then 0 else round(100.0*current_value/current_total,1) end,
      'status',status
    )),'[]'::jsonb) into v_rows
    from ordered;
  end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.executive_operational_summary_queried','bi_query',jsonb_build_object(
    'date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,
    'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id,'row_limit',12
  ));

  return jsonb_set(v_payload,'{operational_rows}',v_rows,true);
end $$;

revoke all on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid)
  from public,anon;
grant execute on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid)
  to authenticated;
