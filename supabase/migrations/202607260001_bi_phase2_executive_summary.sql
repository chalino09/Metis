-- Satrapy BI · Fase 2: Resumen Ejecutivo avanzado.
-- Complementa el resumen canónico con comparaciones y visualizaciones agregadas.
-- No persiste hechos ni sustituye auxiliares contables.

create or replace function public.bi_get_executive_charts(
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
  v_cxc numeric:=0;
  v_cxc_previous numeric:=0;
  v_cxc_overdue numeric:=0;
  v_cxc_overdue_previous numeric:=0;
  v_cxp numeric:=0;
  v_cxp_previous numeric:=0;
  v_inventory numeric:=0;
  v_inventory_previous numeric:=0;
  v_inventory_rows bigint:=0;
  v_inventory_missing_cost bigint:=0;
  v_inventory_previous_rows bigint:=0;
  v_inventory_previous_missing_cost bigint:=0;
  v_charts jsonb;
  v_comparisons jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then
    raise exception 'No autorizado para consultar BI.';
  end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from then
    raise exception 'Periodo de BI inválido.';
  end if;
  v_days:=p_date_to-p_date_from+1;
  if v_days>366 then raise exception 'El Resumen ejecutivo admite periodos de hasta 366 días.';end if;
  v_previous_to:=p_date_from-1;
  v_previous_from:=v_previous_to-v_days+1;

  if p_location_id is not null and not exists(
    select 1 from public.locations l
    where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.';end if;
  if p_product_id is not null and not exists(select 1 from public.products p where p.id=p_product_id and p.company_id=p_company_id) then raise exception 'Producto no disponible.';end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id) then raise exception 'Cliente no disponible.';end if;
  if p_supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id) then raise exception 'Proveedor no disponible.';end if;

  select c.base_currency into v_currency
  from public.accounting_config_versions c
  where c.company_id=p_company_id and c.status='approved';

  if v_sales_available and v_currency is not null then
    with day_axis as (
      select day_index,
        p_date_from+day_index as current_date,
        v_previous_from+day_index as previous_date
      from generate_series(0,v_days-1) as indices(day_index)
    ), sale_facts as materialized (
      select s.completed_at::date occurred_on,
        case when p_product_id is null then s.subtotal_amount-s.discount_amount
          else (select coalesce(sum(si.taxable_amount),0) from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id)
        end amount
      from public.sales s
      where s.company_id=p_company_id and s.currency_code=v_currency
        and s.completed_at::date between v_previous_from and p_date_to
        and public.can_access_location(s.location_id)
        and (p_location_id is null or s.location_id=p_location_id)
        and (p_customer_id is null or s.customer_id=p_customer_id)
        and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
        and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    ), daily as (
      select occurred_on,sum(amount) amount from sale_facts group by occurred_on
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'index',d.day_index,'date',d.current_date,'value',coalesce(c.amount,0),
      'previous_date',d.previous_date,'previous_value',coalesce(p.amount,0)
    ) order by d.day_index),'[]'::jsonb)
    into v_sales_points
    from day_axis d
    left join daily c on c.occurred_on=d.current_date
    left join daily p on p.occurred_on=d.previous_date;
  end if;

  if v_bank_available and v_currency is not null then
    with day_axis as (
      select day_index,
        p_date_from+day_index as current_date,
        v_previous_from+day_index as previous_date
      from generate_series(0,v_days-1) as indices(day_index)
    ), daily as materialized (
      select bt.transaction_date occurred_on,
        sum(case when bt.direction='credit' then bt.amount else -bt.amount end) amount
      from public.bank_transactions bt
      where bt.company_id=p_company_id and bt.currency_code=v_currency
        and bt.transaction_date between v_previous_from and p_date_to
      group by bt.transaction_date
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'index',d.day_index,'date',d.current_date,'value',coalesce(c.amount,0),
      'previous_date',d.previous_date,'previous_value',coalesce(p.amount,0)
    ) order by d.day_index),'[]'::jsonb)
    into v_bank_points
    from day_axis d
    left join daily c on c.occurred_on=d.current_date
    left join daily p on p.occurred_on=d.previous_date;
  end if;

  if v_cxc_available and v_currency is not null then
    with receivable_positions as materialized (
      select cr.id,cr.issued_at,cr.due_date,
        case when cr.issued_at<(p_date_to+1)::timestamptz
          and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=cr.sale_id and sc.cancelled_at<(p_date_to+1)::timestamptz)
          then greatest(cr.original_amount-coalesce((
            select sum(a.amount)
            from public.receivable_payment_applications a
            join public.receivable_payments rp on rp.id=a.receivable_payment_id
            where a.receivable_id=cr.id and a.created_at<(p_date_to+1)::timestamptz and rp.received_at<(p_date_to+1)::timestamptz
              and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(p_date_to+1)::timestamptz)
          ),0),0) else 0 end current_balance,
        case when cr.issued_at<(v_previous_to+1)::timestamptz
          and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=cr.sale_id and sc.cancelled_at<(v_previous_to+1)::timestamptz)
          then greatest(cr.original_amount-coalesce((
            select sum(a.amount)
            from public.receivable_payment_applications a
            join public.receivable_payments rp on rp.id=a.receivable_payment_id
            where a.receivable_id=cr.id and a.created_at<(v_previous_to+1)::timestamptz and rp.received_at<(v_previous_to+1)::timestamptz
              and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(v_previous_to+1)::timestamptz)
          ),0),0) else 0 end previous_balance
      from public.customer_receivables cr
      join public.sales s on s.id=cr.sale_id
      where cr.company_id=p_company_id and s.currency_code=v_currency
        and public.can_access_location(s.location_id)
        and (p_location_id is null or s.location_id=p_location_id)
        and (p_customer_id is null or cr.customer_id=p_customer_id)
        and (p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
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
        select ap.id,
          greatest(0,ap.original_base_amount
            -coalesce((select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)
              from public.supplier_invoices cn where cn.original_invoice_id=ap.supplier_invoice_id and cn.company_id=p_company_id
                and cn.document_type='credit_note' and cn.confirmed_at<(p_date_to+1)::timestamptz and cn.issued_date<=p_date_to
                and (cn.reversed_at is null or cn.reversed_at>=(p_date_to+1)::timestamptz)),0)
            -coalesce((select sum(pa.amount*ap.exchange_rate)
              from public.supplier_payment_applications pa join public.supplier_payments sp on sp.id=pa.payment_id
              where pa.accounts_payable_id=ap.id and pa.applied_at<(p_date_to+1)::timestamptz and sp.effective_date<=p_date_to
                and sp.confirmed_at<(p_date_to+1)::timestamptz and (sp.reversed_at is null or sp.reversed_at>=(p_date_to+1)::timestamptz)),0)
          ) current_balance,
          greatest(0,ap.original_base_amount
            -coalesce((select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)
              from public.supplier_invoices cn where cn.original_invoice_id=ap.supplier_invoice_id and cn.company_id=p_company_id
                and cn.document_type='credit_note' and cn.confirmed_at<(v_previous_to+1)::timestamptz and cn.issued_date<=v_previous_to
                and (cn.reversed_at is null or cn.reversed_at>=(v_previous_to+1)::timestamptz)),0)
            -coalesce((select sum(pa.amount*ap.exchange_rate)
              from public.supplier_payment_applications pa join public.supplier_payments sp on sp.id=pa.payment_id
              where pa.accounts_payable_id=ap.id and pa.applied_at<(v_previous_to+1)::timestamptz and sp.effective_date<=v_previous_to
                and sp.confirmed_at<(v_previous_to+1)::timestamptz and (sp.reversed_at is null or sp.reversed_at>=(v_previous_to+1)::timestamptz)),0)
          ) previous_balance
        from public.accounts_payable ap
        join public.supplier_invoices si on si.id=ap.supplier_invoice_id
        where ap.company_id=p_company_id and ap.supplier_id=p_supplier_id
          and ap.issued_date<=p_date_to and si.confirmed_at<(p_date_to+1)::timestamptz
      )
      select coalesce(sum(current_balance),0),coalesce(sum(previous_balance),0)
      into v_cxp,v_cxp_previous from payable_positions;
    end if;
  end if;

  if v_inventory_available and v_currency is not null then
    with quantities as materialized (
      select il.location_id,il.product_id,
        coalesce(sum(il.quantity_delta) filter(where il.occurred_at<(p_date_to+1)::timestamptz),0) current_quantity,
        coalesce(sum(il.quantity_delta) filter(where il.occurred_at<(v_previous_to+1)::timestamptz),0) previous_quantity
      from public.inventory_ledger il
      where il.company_id=p_company_id and il.occurred_at<(p_date_to+1)::timestamptz
        and public.can_access_location(il.location_id)
        and (p_location_id is null or il.location_id=p_location_id)
        and (p_product_id is null or il.product_id=p_product_id)
      group by il.location_id,il.product_id
    ), valued as (
      select q.*,
        cc.amount current_cost,pc.amount previous_cost
      from quantities q
      left join lateral(
        select c.amount from public.product_costs c
        left join public.accounting_event_rule_sets rs on rs.company_id=c.company_id and rs.status='approved'
        where c.company_id=p_company_id and c.product_id=q.product_id and c.currency_code=v_currency
          and c.cost_type=coalesce(rs.cost_method,'replacement_cost')
          and c.valid_from<(p_date_to+1)::timestamptz and(c.valid_to is null or c.valid_to>p_date_to::timestamptz)
        order by c.valid_from desc,c.id desc limit 1
      )cc on true
      left join lateral(
        select c.amount from public.product_costs c
        left join public.accounting_event_rule_sets rs on rs.company_id=c.company_id and rs.status='approved'
        where c.company_id=p_company_id and c.product_id=q.product_id and c.currency_code=v_currency
          and c.cost_type=coalesce(rs.cost_method,'replacement_cost')
          and c.valid_from<(v_previous_to+1)::timestamptz and(c.valid_to is null or c.valid_to>v_previous_to::timestamptz)
        order by c.valid_from desc,c.id desc limit 1
      )pc on true
    )
    select coalesce(sum(current_quantity*coalesce(current_cost,0)),0),
      coalesce(sum(previous_quantity*coalesce(previous_cost,0)),0),
      count(*) filter(where current_quantity<>0),
      count(*) filter(where current_quantity<>0 and current_cost is null),
      count(*) filter(where previous_quantity<>0),
      count(*) filter(where previous_quantity<>0 and previous_cost is null)
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
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.'
        when not v_inventory_available then 'Inventario no se atribuye a cliente o proveedor.'
        when v_inventory_missing_cost>0 or v_inventory_previous_missing_cost>0 then 'Hay saldos sin costo aprobado en el periodo actual o comparable.' end)
  );

  v_charts:=jsonb_build_array(
    jsonb_build_object('code','sales','metric_code','net_sales','kind','Devengado','visualization','line',
      'available',v_sales_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_sales_available then 'Proveedor no es una dimensión comprobada de ventas.' end,
      'points',v_sales_points),
    jsonb_build_object('code','gross_margin','metric_code','gross_margin','kind','Devengado','visualization','line','available',false,
      'reason','No existe costo reconocido por partida vendida y fecha; usar costo vigente inventaría margen histórico.','points','[]'::jsonb),
    jsonb_build_object('code','cash_flow','metric_code','bank_net_flow','kind','Efectivo','visualization','area',
      'available',v_bank_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_bank_available then 'El flujo bancario no se atribuye a estas dimensiones sin conciliación comprobada.' end,
      'points',v_bank_points),
    jsonb_build_object('code','receivables','metric_code','receivables','kind','Devengado','visualization','bars',
      'available',v_cxc_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxc_available then 'Proveedor no es una dimensión de CxC.' end,
      'points',jsonb_build_array(
        jsonb_build_object('date',v_previous_to,'period','previous','value',v_cxc_previous),
        jsonb_build_object('date',p_date_to,'period','current','value',v_cxc)
      )),
    jsonb_build_object('code','payables','metric_code','payables','kind','Devengado','visualization','bars',
      'available',v_cxp_available and v_currency is not null,
      'reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' when not v_cxp_available then 'CxP no se atribuye a ubicación, producto o cliente sin una relación única.' end,
      'points',jsonb_build_array(
        jsonb_build_object('date',v_previous_to,'period','previous','value',v_cxp_previous),
        jsonb_build_object('date',p_date_to,'period','current','value',v_cxp)
      )),
    jsonb_build_object('code','inventory','metric_code','inventory_value','kind','Operativo','visualization','bars',
      'available',v_inventory_available and v_currency is not null and v_inventory_missing_cost=0 and v_inventory_previous_missing_cost=0,
      'reason',v_comparisons->'inventory_value'->>'reason',
      'points',jsonb_build_array(
        jsonb_build_object('date',v_previous_to,'period','previous','value',v_inventory_previous),
        jsonb_build_object('date',p_date_to,'period','current','value',v_inventory)
      ))
  );

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.executive_charts_queried','bi_query',
    jsonb_build_object('date_from',p_date_from,'date_to',p_date_to,'location_id',p_location_id,'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id));

  return jsonb_build_object(
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to,'previous_from',v_previous_from,'previous_to',v_previous_to,'days',v_days),
    'updated_at',now(),'currency_code',v_currency,'charts',v_charts,'comparisons',v_comparisons,
    'trace',jsonb_build_object('query','bi_get_executive_charts',
      'sources',jsonb_build_array('sales','sale_items','bank_transactions','customer_receivables','receivable_payment_applications','accounts_payable','supplier_payment_applications','inventory_ledger','product_costs','canonical_accounting_auxiliaries'),
      'company_id',p_company_id)
  );
end $$;

revoke all on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) from public;
grant execute on function public.bi_get_executive_charts(uuid,date,date,uuid,uuid,uuid,uuid) to authenticated;

create or replace function public.bi_get_drilldown_v2(
  p_company_id uuid,
  p_metric_code text,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null,
  p_as_of_date date default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_code text:=lower(trim(coalesce(p_metric_code,'')));
  v_as_of date:=coalesce(p_as_of_date,p_date_to);
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint:=0;
  v_items jsonb:='[]'::jsonb;
  v_source_path text;
  v_currency text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from+1>366 then raise exception 'Periodo de BI inválido.';end if;
  if p_location_id is not null and not exists(
    select 1 from public.locations l where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.';end if;
  select c.base_currency into v_currency from public.accounting_config_versions c where c.company_id=p_company_id and c.status='approved';
  if v_currency is null and v_code<>'tickets' then raise exception 'Falta una moneda base contable aprobada.';end if;

  if v_code not in('receivables','overdue_receivables','payables','inventory_value') then
    return public.bi_get_drilldown(
      p_company_id,v_code,p_date_from,p_date_to,p_location_id,p_product_id,p_customer_id,p_supplier_id,v_page,v_size
    );
  end if;

  if v_code in('receivables','overdue_receivables') then
    if p_supplier_id is not null then raise exception 'Proveedor no es una dimensión de CxC.';end if;
    with balances as materialized (
      select cr.id,cr.issued_at occurred_at,c.display_name party,'Vence '||cr.due_date::text detail,cr.due_date,
        greatest(cr.original_amount-coalesce((
          select sum(a.amount)
          from public.receivable_payment_applications a
          join public.receivable_payments rp on rp.id=a.receivable_payment_id
          where a.receivable_id=cr.id and a.created_at<(v_as_of+1)::timestamptz and rp.received_at<(v_as_of+1)::timestamptz
            and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(v_as_of+1)::timestamptz)
        ),0),0) amount
      from public.customer_receivables cr
      join public.customers c on c.id=cr.customer_id
      join public.sales s on s.id=cr.sale_id
      where cr.company_id=p_company_id and s.currency_code=v_currency and cr.issued_at<(v_as_of+1)::timestamptz
        and public.can_access_location(s.location_id) and(p_location_id is null or s.location_id=p_location_id)
        and(p_customer_id is null or cr.customer_id=p_customer_id)
        and(p_product_id is null or exists(select 1 from public.sale_items si where si.sale_id=s.id and si.product_id=p_product_id))
        and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id and sc.cancelled_at<(v_as_of+1)::timestamptz)
    ),filtered as materialized (
      select id,occurred_at,party,detail,amount from balances
      where amount>0 and(v_code<>'overdue_receivables' or due_date<v_as_of)
    ),paged as(
      select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size
    )
    select (select count(*) from filtered),
      coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb)
    into v_total,v_items from paged;
    v_source_path:='/satrapy/ventas/cuentas-por-cobrar';
  elsif v_code='payables' then
    if p_location_id is not null or p_product_id is not null or p_customer_id is not null then
      raise exception 'CxP no se atribuye a ubicación, producto o cliente sin una relación única.';
    end if;
    with balances as materialized (
      select ap.id,ap.issued_date occurred_at,s.display_name party,'Vence '||ap.due_date::text detail,
        greatest(0,ap.original_base_amount
          -coalesce((select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)
            from public.supplier_invoices cn where cn.original_invoice_id=ap.supplier_invoice_id and cn.company_id=p_company_id
              and cn.document_type='credit_note' and cn.confirmed_at<(v_as_of+1)::timestamptz and cn.issued_date<=v_as_of
              and(cn.reversed_at is null or cn.reversed_at>=(v_as_of+1)::timestamptz)),0)
          -coalesce((select sum(pa.amount*ap.exchange_rate)
            from public.supplier_payment_applications pa join public.supplier_payments sp on sp.id=pa.payment_id
            where pa.accounts_payable_id=ap.id and pa.applied_at<(v_as_of+1)::timestamptz and sp.effective_date<=v_as_of
              and sp.confirmed_at<(v_as_of+1)::timestamptz and(sp.reversed_at is null or sp.reversed_at>=(v_as_of+1)::timestamptz)),0)
        ) amount
      from public.accounts_payable ap
      join public.supplier_invoices si on si.id=ap.supplier_invoice_id
      join public.suppliers s on s.id=ap.supplier_id
      where ap.company_id=p_company_id and ap.issued_date<=v_as_of and si.confirmed_at<(v_as_of+1)::timestamptz
        and(si.reversed_at is null or si.reversed_at>=(v_as_of+1)::timestamptz)
        and(p_supplier_id is null or ap.supplier_id=p_supplier_id)
    ),filtered as materialized(
      select id,occurred_at,party,detail,amount from balances where amount>0
    ),paged as(
      select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size
    )
    select (select count(*) from filtered),
      coalesce(jsonb_agg(to_jsonb(paged) order by occurred_at desc,id desc),'[]'::jsonb)
    into v_total,v_items from paged;
    v_source_path:='/satrapy/compras/facturas';
  else
    if p_customer_id is not null or p_supplier_id is not null then
      raise exception 'Inventario no se atribuye a cliente o proveedor.';
    end if;
    with quantities as materialized(
      select il.location_id,il.product_id,max(il.occurred_at) occurred_at,sum(il.quantity_delta) quantity
      from public.inventory_ledger il
      where il.company_id=p_company_id and il.occurred_at<(v_as_of+1)::timestamptz
        and public.can_access_location(il.location_id)
        and(p_location_id is null or il.location_id=p_location_id)
        and(p_product_id is null or il.product_id=p_product_id)
      group by il.location_id,il.product_id
    ),filtered as materialized(
      select q.product_id::text||':'||q.location_id::text id,q.occurred_at,p.name party,l.name detail,
        q.quantity*pc.amount amount
      from quantities q
      join public.products p on p.id=q.product_id
      join public.locations l on l.id=q.location_id
      left join lateral(
        select c.amount from public.product_costs c
        left join public.accounting_event_rule_sets rs on rs.company_id=c.company_id and rs.status='approved'
        where c.company_id=p_company_id and c.product_id=q.product_id and c.currency_code=v_currency
          and c.cost_type=coalesce(rs.cost_method,'replacement_cost')
          and c.valid_from<(v_as_of+1)::timestamptz and(c.valid_to is null or c.valid_to>v_as_of::timestamptz)
        order by c.valid_from desc,c.id desc limit 1
      )pc on true
      where q.quantity<>0 and pc.amount is not null
    ),paged as(
      select * from filtered order by amount desc,id limit v_size offset(v_page-1)*v_size
    )
    select (select count(*) from filtered),
      coalesce(jsonb_agg(to_jsonb(paged) order by amount desc,id),'[]'::jsonb)
    into v_total,v_items from paged;
    v_source_path:='/satrapy/inventario/existencias';
  end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.drilldown_v2_queried','bi_query',
    jsonb_build_object('metric_code',v_code,'as_of',v_as_of,'page',v_page,'page_size',v_size));

  return jsonb_build_object(
    'items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)),
    'source_path',v_source_path,'metric_code',v_code,'as_of',v_as_of
  );
end $$;

revoke all on function public.bi_get_drilldown_v2(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer) from public;
grant execute on function public.bi_get_drilldown_v2(uuid,text,date,date,uuid,uuid,uuid,uuid,date,integer,integer) to authenticated;
