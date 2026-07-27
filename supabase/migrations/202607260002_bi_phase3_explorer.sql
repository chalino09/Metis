-- Satrapy BI · Fase 3: Explorador transversal.
-- Continúa el motor de BI existente: no replica hechos y sólo devuelve agregados/páginas.

create or replace function public.bi_get_metric_catalog(p_company_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_currency text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then
    raise exception 'No autorizado para consultar BI.';
  end if;
  select c.base_currency into v_currency
  from public.accounting_config_versions c
  where c.company_id=p_company_id and c.status='approved';

  return jsonb_build_object(
    'updated_at',now(),'currency_code',v_currency,
    'dimensions',jsonb_build_array(
      jsonb_build_object('code','period','name','Periodo'),
      jsonb_build_object('code','location','name','Ubicación'),
      jsonb_build_object('code','product','name','Producto'),
      jsonb_build_object('code','category','name','Categoría'),
      jsonb_build_object('code','customer','name','Cliente'),
      jsonb_build_object('code','supplier','name','Proveedor'),
      jsonb_build_object('code','financial_account','name','Cuenta bancaria'),
      jsonb_build_object('code','account','name','Cuenta contable')
    ),
    'metrics',jsonb_build_array(
      jsonb_build_object('code','net_sales','name','Ventas netas','module','Ventas',
        'formula','Σ importe gravable de partidas de ventas completadas no canceladas','unit','currency',
        'source','sales + sale_items + sale_cancellations','grain','flow_day','dimensions',jsonb_build_array('period','location','product','category','customer'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Excluye impuestos. Producto y categoría usan partidas, sin multiplicar encabezados.'),
      jsonb_build_object('code','tickets','name','Tickets completados','module','Ventas',
        'formula','Conteo distinto de ventas completadas no canceladas','unit','count',
        'source','sales + sale_cancellations','grain','flow_day','dimensions',jsonb_build_array('period','location','customer'),
        'kind','operational','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',true,
        'limitations','No se agrupa por producto: un ticket multiproducto no es aditivo entre partidas.'),
      jsonb_build_object('code','gross_margin','name','Margen bruto','module','Margen',
        'formula','Ventas netas − costo reconocido de partidas vendidas','unit','currency',
        'source','Pendiente de costo reconocido por partida y fecha','grain','flow_day','dimensions',jsonb_build_array('period','location','product','category'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',false,'available',false,
        'unavailable_reason','No existe costo reconocido por partida vendida y fecha; el costo vigente no prueba margen histórico.',
        'limitations','No se sustituye con costo actual ni con costo de reemplazo.'),
      jsonb_build_object('code','cash_net','name','Flujo neto de caja','module','Caja',
        'formula','Σ movimientos de caja; entradas positivas y salidas negativas','unit','currency',
        'source','cash_movements + cash_sessions','grain','flow_day','dimensions',jsonb_build_array('period','location'),
        'kind','cash','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Caja no incluye bancos y conserva la ubicación de la sesión.'),
      jsonb_build_object('code','collections','name','Cobranza efectiva','module','CxC',
        'formula','Σ cobros confirmados no revertidos','unit','currency',
        'source','receivable_payments + reversals','grain','flow_day','dimensions',jsonb_build_array('period','customer'),
        'kind','cash','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','No se reparte a producto o ubicación cuando un cobro tiene varias aplicaciones.'),
      jsonb_build_object('code','receivables','name','Saldo CxC al corte','module','CxC',
        'formula','Documentos emitidos − aplicaciones efectivas vigentes al corte','unit','currency',
        'source','customer_receivables + applications + reversals','grain','position_cutoff','dimensions',jsonb_build_array('location','customer'),
        'kind','accrual','visualizations',jsonb_build_array('bar','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Posición al corte; no se suma entre fechas ni se distribuye entre productos.'),
      jsonb_build_object('code','supplier_payments','name','Pagos a proveedores','module','CxP',
        'formula','Σ pagos confirmados no revertidos','unit','currency',
        'source','supplier_payments','grain','flow_day','dimensions',jsonb_build_array('period','supplier'),
        'kind','cash','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','No representa compra devengada ni se atribuye a ubicación/producto.'),
      jsonb_build_object('code','payables','name','Saldo CxP al corte','module','CxP',
        'formula','Factura base − notas de crédito − pagos efectivos vigentes al corte','unit','currency',
        'source','accounts_payable + supplier invoices + payment applications','grain','position_cutoff','dimensions',jsonb_build_array('supplier'),
        'kind','accrual','visualizations',jsonb_build_array('bar','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Posición al corte; no se reparte a ubicación o producto.'),
      jsonb_build_object('code','purchases_accrued','name','Compras devengadas netas','module','Compras',
        'formula','Σ subtotal de partidas facturadas − descuento de partida','unit','currency',
        'source','supplier_invoices + lines + purchase_receipts','grain','flow_day','dimensions',jsonb_build_array('period','location','product','category','supplier'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','Sólo facturas confirmadas en moneda base; excluye impuestos y documentos revertidos.'),
      jsonb_build_object('code','purchase_quantity','name','Cantidad comprada','module','Compras',
        'formula','Σ cantidad de partidas facturadas y recibidas','unit','quantity',
        'source','supplier_invoice_lines + purchase_receipt_lines','grain','flow_day','dimensions',jsonb_build_array('period','location','product','category','supplier'),
        'kind','operational','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',true,
        'limitations','Sólo es comparable para el mismo producto/categoría; unidades heterogéneas no forman un total financiero.'),
      jsonb_build_object('code','inventory_quantity','name','Existencia al corte','module','Inventario',
        'formula','Σ quantity_delta del ledger hasta el corte','unit','quantity',
        'source','inventory_ledger','grain','position_cutoff','dimensions',jsonb_build_array('location','product','category'),
        'kind','operational','visualizations',jsonb_build_array('bar','scatter'),'drilldown',true,'available',true,
        'limitations','Posición al corte; no sumar entre periodos ni entre unidades heterogéneas.'),
      jsonb_build_object('code','inventory_value','name','Valor de inventario','module','Inventario',
        'formula','Existencia al corte × costo aprobado vigente al corte','unit','currency',
        'source','inventory_ledger + product_costs + accounting rule set','grain','position_cutoff','dimensions',jsonb_build_array('location','product','category'),
        'kind','operational','visualizations',jsonb_build_array('bar','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','La consulta queda no disponible si algún saldo agrupado carece de costo aprobado.'),
      jsonb_build_object('code','bank_net_flow','name','Flujo bancario neto','module','Bancos',
        'formula','Σ créditos bancarios − débitos bancarios','unit','currency',
        'source','bank_transactions','grain','flow_day','dimensions',jsonb_build_array('period','financial_account'),
        'kind','cash','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','No se atribuye a ubicación, cliente o proveedor sin conciliación comprobada.'),
      jsonb_build_object('code','accounting_debits','name','Débitos contabilizados','module','Contabilidad',
        'formula','Σ débitos de pólizas contabilizadas','unit','currency',
        'source','accounting_journal_entries + accounting_journal_lines','grain','flow_day','dimensions',jsonb_build_array('period','account'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area','scatter'),'drilldown',true,'available',v_currency is not null,
        'unavailable_reason',case when v_currency is null then 'Falta una moneda base contable aprobada.' end,
        'limitations','No equivale a gasto ni utilidad; incluye únicamente pólizas posted del dominio actual.'),
      jsonb_build_object('code','payroll_runs','name','Corridas de nómina aprobadas','module','Nómina',
        'formula','Conteo de periodos de nómina aprobados o pagados','unit','count',
        'source','payroll_periods','grain','payroll_period','dimensions',jsonb_build_array('period'),
        'kind','operational','visualizations',jsonb_build_array('line','bar','area'),'drilldown',true,'available',true,
        'limitations','Conteo operativo; no representa importe de nómina.'),
      jsonb_build_object('code','payroll_accrued','name','Nómina aprobada','module','Nómina',
        'formula','Σ total_pay de corridas aprobadas o pagadas','unit','currency',
        'source','payroll_periods + payroll_period_lines','grain','payroll_period','dimensions',jsonb_build_array('period'),
        'kind','accrual','visualizations',jsonb_build_array('line','bar','area'),'drilldown',false,'available',false,
        'unavailable_reason','Las corridas no conservan moneda canónica; el importe no es transversalmente comparable.',
        'limitations','No se infiere moneda desde la empresa ni desde compensaciones actuales.')
    )
  );
end $$;

revoke all on function public.bi_get_metric_catalog(uuid) from public;
grant execute on function public.bi_get_metric_catalog(uuid) to authenticated;

create or replace function public.bi_explorer_query(
  p_company_id uuid,
  p_metric_codes text[],
  p_dimension text,
  p_visualization text,
  p_date_from date,
  p_date_to date,
  p_location_id uuid default null,
  p_product_id uuid default null,
  p_customer_id uuid default null,
  p_supplier_id uuid default null,
  p_compare_previous boolean default true,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_catalog jsonb;v_metrics jsonb;v_metric jsonb;v_code text;v_grain text;v_unit text;
  v_first_grain text;v_first_unit text;v_days integer;v_previous_from date;v_previous_to date;
  v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_total bigint;v_items jsonb;v_chart jsonb;v_currency text;v_missing_cost bigint:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from then raise exception 'Periodo de BI inválido.';end if;
  v_days:=p_date_to-p_date_from+1;
  if v_days>366 then raise exception 'El Explorador admite periodos de hasta 366 días.';end if;
  if coalesce(array_length(p_metric_codes,1),0)<1 or array_length(p_metric_codes,1)>4 then raise exception 'Selecciona entre una y cuatro métricas.';end if;
  if exists(select 1 from unnest(p_metric_codes) c group by c having count(*)>1) then raise exception 'No repitas métricas en una consulta.';end if;
  if p_visualization not in('line','bar','area','scatter') then raise exception 'Visualización no disponible.';end if;
  v_previous_to:=p_date_from-1;v_previous_from:=v_previous_to-v_days+1;

  if p_location_id is not null and not exists(
    select 1 from public.locations l where l.id=p_location_id and l.company_id=p_company_id and public.can_access_location(l.id)
  ) then raise exception 'Ubicación no disponible.';end if;
  if p_product_id is not null and not exists(select 1 from public.products p where p.id=p_product_id and p.company_id=p_company_id) then raise exception 'Producto no disponible.';end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.company_id=p_company_id) then raise exception 'Cliente no disponible.';end if;
  if p_supplier_id is not null and not exists(select 1 from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id) then raise exception 'Proveedor no disponible.';end if;

  v_catalog:=public.bi_get_metric_catalog(p_company_id);v_metrics:=v_catalog->'metrics';v_currency:=v_catalog->>'currency_code';
  foreach v_code in array p_metric_codes loop
    select value into v_metric from jsonb_array_elements(v_metrics) where value->>'code'=v_code;
    if v_metric is null then raise exception 'Métrica de BI inválida: %.',v_code;end if;
    if not (v_metric->>'available')::boolean then raise exception '%',v_metric->>'unavailable_reason';end if;
    if not (v_metric->'dimensions' ? p_dimension) then raise exception 'La dimensión % no es válida para %.',p_dimension,v_metric->>'name';end if;
    if not (v_metric->'visualizations' ? p_visualization) then raise exception 'La visualización no es válida para %.',v_metric->>'name';end if;
    v_grain:=v_metric->>'grain';v_unit:=v_metric->>'unit';
    if v_first_grain is null then v_first_grain:=v_grain;v_first_unit:=v_unit;
    elsif v_first_grain<>v_grain then raise exception 'Las métricas no comparten granularidad comprobada.';
    elsif v_first_unit<>v_unit then raise exception 'Las métricas no comparten unidad; no se superponen en el mismo eje.';end if;
  end loop;
  if p_visualization='scatter' and array_length(p_metric_codes,1)<>2 then raise exception 'Dispersión requiere exactamente dos métricas.';end if;
  if p_visualization in('line','area') and p_dimension<>'period' then raise exception 'Línea y área requieren la dimensión periodo.';end if;
  if v_first_grain='position_cutoff' and p_dimension='period' then raise exception 'Las posiciones no se suman en el tiempo.';end if;

  drop table if exists pg_temp.bi_explorer_result;
  create temporary table bi_explorer_result(
    metric_code text not null,group_key text not null,group_label text not null,
    current_value numeric,previous_value numeric,available boolean not null default true,reason text,
    primary key(metric_code,group_key)
  ) on commit drop;

  foreach v_code in array p_metric_codes loop
    if v_code='net_sales' then
      insert into bi_explorer_result
      select v_code,
        case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'YYYY-MM-DD') when 'location' then s.location_id::text
          when 'product' then si.product_id::text when 'category' then coalesce(p.category_id::text,'uncategorized')
          else coalesce(s.customer_id::text,'walk-in') end,
        case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'DD Mon') when 'location' then l.name
          when 'product' then p.name when 'category' then coalesce(pc.name,'Sin categoría')
          else coalesce(c.display_name,'Público general') end,
        sum(si.taxable_amount) filter(where s.completed_at::date between p_date_from and p_date_to),
        sum(si.taxable_amount) filter(where s.completed_at::date between v_previous_from and v_previous_to),true,null
      from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
      join public.locations l on l.id=s.location_id left join public.product_categories pc on pc.id=p.category_id left join public.customers c on c.id=s.customer_id
      where s.company_id=p_company_id and s.currency_code=v_currency and public.can_access_location(s.location_id)
        and s.completed_at::date between v_previous_from and p_date_to and not exists(select 1 from public.sale_cancellations x where x.sale_id=s.id)
        and(p_location_id is null or s.location_id=p_location_id)and(p_product_id is null or si.product_id=p_product_id)
        and(p_customer_id is null or s.customer_id=p_customer_id)and p_supplier_id is null
      group by 2,3;
    elsif v_code='tickets' then
      insert into bi_explorer_result
      select v_code,case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'YYYY-MM-DD') when 'location' then s.location_id::text else coalesce(s.customer_id::text,'walk-in') end,
        case p_dimension when 'period' then to_char(case when s.completed_at::date<p_date_from then s.completed_at::date+v_days else s.completed_at::date end,'DD Mon') when 'location' then l.name else coalesce(c.display_name,'Público general') end,
        count(distinct s.id) filter(where s.completed_at::date between p_date_from and p_date_to),
        count(distinct s.id) filter(where s.completed_at::date between v_previous_from and v_previous_to),true,null
      from public.sales s join public.locations l on l.id=s.location_id left join public.customers c on c.id=s.customer_id
      where s.company_id=p_company_id and public.can_access_location(s.location_id)and s.completed_at::date between v_previous_from and p_date_to
        and not exists(select 1 from public.sale_cancellations x where x.sale_id=s.id)
        and(p_location_id is null or s.location_id=p_location_id)and(p_customer_id is null or s.customer_id=p_customer_id)
        and p_product_id is null and p_supplier_id is null group by 2,3;
    elsif v_code='cash_net' then
      insert into bi_explorer_result
      select v_code,case when p_dimension='period' then to_char(case when cm.occurred_at::date<p_date_from then cm.occurred_at::date+v_days else cm.occurred_at::date end,'YYYY-MM-DD')else cs.location_id::text end,
        case when p_dimension='period' then to_char(case when cm.occurred_at::date<p_date_from then cm.occurred_at::date+v_days else cm.occurred_at::date end,'DD Mon')else l.name end,
        sum(cm.amount)filter(where cm.occurred_at::date between p_date_from and p_date_to),
        sum(cm.amount)filter(where cm.occurred_at::date between v_previous_from and v_previous_to),true,null
      from public.cash_movements cm join public.cash_sessions cs on cs.id=cm.cash_session_id join public.locations l on l.id=cs.location_id
      where cm.company_id=p_company_id and public.can_access_location(cs.location_id)and cm.occurred_at::date between v_previous_from and p_date_to
        and(p_location_id is null or cs.location_id=p_location_id)and p_product_id is null and p_customer_id is null and p_supplier_id is null group by 2,3;
    elsif v_code='collections' then
      insert into bi_explorer_result
      select v_code,case when p_dimension='period' then to_char(case when rp.received_at::date<p_date_from then rp.received_at::date+v_days else rp.received_at::date end,'YYYY-MM-DD')else rp.customer_id::text end,
        case when p_dimension='period' then to_char(case when rp.received_at::date<p_date_from then rp.received_at::date+v_days else rp.received_at::date end,'DD Mon')else c.display_name end,
        sum(rp.amount)filter(where rp.received_at::date between p_date_from and p_date_to),
        sum(rp.amount)filter(where rp.received_at::date between v_previous_from and v_previous_to),true,null
      from public.receivable_payments rp join public.customers c on c.id=rp.customer_id
      where rp.company_id=p_company_id and rp.received_at::date between v_previous_from and p_date_to
        and not exists(select 1 from public.receivable_payment_reversals x where x.receivable_payment_id=rp.id)
        and(p_customer_id is null or rp.customer_id=p_customer_id)and p_location_id is null and p_product_id is null and p_supplier_id is null group by 2,3;
    elsif v_code='supplier_payments' then
      insert into bi_explorer_result
      select v_code,case when p_dimension='period' then to_char(case when sp.effective_date<p_date_from then sp.effective_date+v_days else sp.effective_date end,'YYYY-MM-DD')else sp.supplier_id::text end,
        case when p_dimension='period' then to_char(case when sp.effective_date<p_date_from then sp.effective_date+v_days else sp.effective_date end,'DD Mon')else s.display_name end,
        sum(sp.total_amount)filter(where sp.effective_date between p_date_from and p_date_to),
        sum(sp.total_amount)filter(where sp.effective_date between v_previous_from and v_previous_to),true,null
      from public.supplier_payments sp join public.suppliers s on s.id=sp.supplier_id
      where sp.company_id=p_company_id and sp.currency_code=v_currency and sp.status='confirmed' and sp.reversed_at is null
        and sp.effective_date between v_previous_from and p_date_to and(p_supplier_id is null or sp.supplier_id=p_supplier_id)
        and p_location_id is null and p_product_id is null and p_customer_id is null group by 2,3;
    elsif v_code in('purchases_accrued','purchase_quantity') then
      insert into bi_explorer_result
      select v_code,case p_dimension when 'period' then to_char(case when inv.issued_date<p_date_from then inv.issued_date+v_days else inv.issued_date end,'YYYY-MM-DD')when 'location' then pr.location_id::text
        when 'product' then il.product_id::text when 'category' then coalesce(p.category_id::text,'uncategorized')else inv.supplier_id::text end,
        case p_dimension when 'period' then to_char(case when inv.issued_date<p_date_from then inv.issued_date+v_days else inv.issued_date end,'DD Mon')when 'location' then l.name when 'product' then p.name
        when 'category' then coalesce(pc.name,'Sin categoría')else sup.display_name end,
        sum(case when v_code='purchase_quantity' then il.quantity else il.line_subtotal-il.invoice_discount_amount end)
          filter(where inv.issued_date between p_date_from and p_date_to),
        sum(case when v_code='purchase_quantity' then il.quantity else il.line_subtotal-il.invoice_discount_amount end)
          filter(where inv.issued_date between v_previous_from and v_previous_to),true,null
      from public.supplier_invoices inv join public.supplier_invoice_lines il on il.supplier_invoice_id=inv.id
      join public.purchase_receipt_lines prl on prl.id=il.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id
      join public.locations l on l.id=pr.location_id join public.products p on p.id=il.product_id left join public.product_categories pc on pc.id=p.category_id
      join public.suppliers sup on sup.id=inv.supplier_id
      where inv.company_id=p_company_id and inv.document_type='invoice'and inv.status='confirmed'and inv.reversed_at is null
        and inv.issued_date between v_previous_from and p_date_to and(v_code='purchase_quantity'or inv.currency_code=v_currency)
        and public.can_access_location(pr.location_id)and(p_location_id is null or pr.location_id=p_location_id)
        and(p_product_id is null or il.product_id=p_product_id)and(p_supplier_id is null or inv.supplier_id=p_supplier_id)and p_customer_id is null group by 2,3;
    elsif v_code='bank_net_flow' then
      insert into bi_explorer_result
      select v_code,case when p_dimension='period'then to_char(case when bt.transaction_date<p_date_from then bt.transaction_date+v_days else bt.transaction_date end,'YYYY-MM-DD')else bt.financial_account_id::text end,
        case when p_dimension='period'then to_char(case when bt.transaction_date<p_date_from then bt.transaction_date+v_days else bt.transaction_date end,'DD Mon')else fa.alias end,
        sum(case when bt.direction='credit'then bt.amount else -bt.amount end)filter(where bt.transaction_date between p_date_from and p_date_to),
        sum(case when bt.direction='credit'then bt.amount else -bt.amount end)filter(where bt.transaction_date between v_previous_from and v_previous_to),true,null
      from public.bank_transactions bt join public.financial_accounts fa on fa.id=bt.financial_account_id
      where bt.company_id=p_company_id and bt.currency_code=v_currency and bt.transaction_date between v_previous_from and p_date_to
        and p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null group by 2,3;
    elsif v_code='accounting_debits' then
      insert into bi_explorer_result
      select v_code,case when p_dimension='period'then to_char(case when e.entry_date<p_date_from then e.entry_date+v_days else e.entry_date end,'YYYY-MM-DD')else jl.account_id::text end,
        case when p_dimension='period'then to_char(case when e.entry_date<p_date_from then e.entry_date+v_days else e.entry_date end,'DD Mon')else a.code||' · '||a.name end,
        sum(jl.debit)filter(where e.entry_date between p_date_from and p_date_to),
        sum(jl.debit)filter(where e.entry_date between v_previous_from and v_previous_to),true,null
      from public.accounting_journal_entries e join public.accounting_journal_lines jl on jl.journal_entry_id=e.id
      join public.accounting_accounts a on a.id=jl.account_id and a.company_id=jl.company_id
      where e.company_id=p_company_id and e.status='posted'and e.entry_date between v_previous_from and p_date_to
        and p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null group by 2,3;
    elsif v_code='payroll_runs' then
      insert into bi_explorer_result
      select v_code,to_char(case when pp.payment_date<p_date_from then pp.payment_date+v_days else pp.payment_date end,'YYYY-MM-DD'),
        to_char(case when pp.payment_date<p_date_from then pp.payment_date+v_days else pp.payment_date end,'DD Mon'),
        count(*)filter(where pp.payment_date between p_date_from and p_date_to),
        count(*)filter(where pp.payment_date between v_previous_from and v_previous_to),true,null
      from public.payroll_periods pp where pp.company_id=p_company_id and pp.status in('approved','paid')
        and pp.payment_date between v_previous_from and p_date_to and p_location_id is null and p_product_id is null and p_customer_id is null and p_supplier_id is null group by 2,3;
    elsif v_code in('receivables','payables','inventory_quantity','inventory_value') then
      -- Las posiciones se calculan por entidad al corte, nunca por una unión uno-a-muchos.
      if v_code='receivables' then
        insert into bi_explorer_result
        select v_code,case when p_dimension='location'then s.location_id::text else cr.customer_id::text end,
          case when p_dimension='location'then l.name else c.display_name end,
          sum(case when not exists(select 1 from public.sale_cancellations sc where sc.sale_id=cr.sale_id and sc.cancelled_at<(p_date_to+1)::timestamptz)
            then greatest(cr.original_amount-coalesce((select sum(a.amount)from public.receivable_payment_applications a join public.receivable_payments rp on rp.id=a.receivable_payment_id where a.receivable_id=cr.id and rp.received_at<(p_date_to+1)::timestamptz and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(p_date_to+1)::timestamptz)),0),0)else 0 end),
          sum(case when cr.issued_at<(v_previous_to+1)::timestamptz and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=cr.sale_id and sc.cancelled_at<(v_previous_to+1)::timestamptz)
            then greatest(cr.original_amount-coalesce((select sum(a.amount)from public.receivable_payment_applications a join public.receivable_payments rp on rp.id=a.receivable_payment_id where a.receivable_id=cr.id and rp.received_at<(v_previous_to+1)::timestamptz and not exists(select 1 from public.receivable_payment_reversals rr where rr.receivable_payment_id=rp.id and rr.reversed_at<(v_previous_to+1)::timestamptz)),0),0)else 0 end),true,null
        from public.customer_receivables cr join public.sales s on s.id=cr.sale_id join public.locations l on l.id=s.location_id join public.customers c on c.id=cr.customer_id
        where cr.company_id=p_company_id and cr.issued_at<(p_date_to+1)::timestamptz and public.can_access_location(s.location_id)
          and(p_location_id is null or s.location_id=p_location_id)and(p_customer_id is null or cr.customer_id=p_customer_id)
          and p_product_id is null and p_supplier_id is null group by 2,3;
      elsif v_code='payables' then
        insert into bi_explorer_result
        select v_code,ap.supplier_id::text,s.display_name,
          sum(greatest(0,ap.original_base_amount
            -coalesce((select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)from public.supplier_invoices cn
              where cn.original_invoice_id=ap.supplier_invoice_id and cn.company_id=p_company_id and cn.document_type='credit_note'
                and cn.confirmed_at<(p_date_to+1)::timestamptz and cn.issued_date<=p_date_to and(cn.reversed_at is null or cn.reversed_at>=(p_date_to+1)::timestamptz)),0)
            -coalesce((select sum(pa.amount*ap.exchange_rate)from public.supplier_payment_applications pa join public.supplier_payments sp on sp.id=pa.payment_id
              where pa.accounts_payable_id=ap.id and pa.applied_at<(p_date_to+1)::timestamptz and sp.effective_date<=p_date_to
                and sp.confirmed_at<(p_date_to+1)::timestamptz and(sp.reversed_at is null or sp.reversed_at>=(p_date_to+1)::timestamptz)),0))),
          sum(case when ap.issued_date<=v_previous_to then greatest(0,ap.original_base_amount
            -coalesce((select sum(case when cn.base_total>0 then cn.base_total else cn.total*cn.exchange_rate end)from public.supplier_invoices cn
              where cn.original_invoice_id=ap.supplier_invoice_id and cn.company_id=p_company_id and cn.document_type='credit_note'
                and cn.confirmed_at<(v_previous_to+1)::timestamptz and cn.issued_date<=v_previous_to and(cn.reversed_at is null or cn.reversed_at>=(v_previous_to+1)::timestamptz)),0)
            -coalesce((select sum(pa.amount*ap.exchange_rate)from public.supplier_payment_applications pa join public.supplier_payments sp on sp.id=pa.payment_id
              where pa.accounts_payable_id=ap.id and pa.applied_at<(v_previous_to+1)::timestamptz and sp.effective_date<=v_previous_to
                and sp.confirmed_at<(v_previous_to+1)::timestamptz and(sp.reversed_at is null or sp.reversed_at>=(v_previous_to+1)::timestamptz)),0))else 0 end),true,null
        from public.accounts_payable ap join public.suppliers s on s.id=ap.supplier_id join public.supplier_invoices si on si.id=ap.supplier_invoice_id
        where ap.company_id=p_company_id and ap.issued_date<=p_date_to and si.confirmed_at<(p_date_to+1)::timestamptz
          and(p_supplier_id is null or ap.supplier_id=p_supplier_id)and p_location_id is null and p_product_id is null and p_customer_id is null group by 2,3;
      else
        insert into bi_explorer_result
        with q as(
          select il.location_id,il.product_id,sum(il.quantity_delta)filter(where il.occurred_at<(p_date_to+1)::timestamptz) cq,
            sum(il.quantity_delta)filter(where il.occurred_at<(v_previous_to+1)::timestamptz) pq
          from public.inventory_ledger il where il.company_id=p_company_id and il.occurred_at<(p_date_to+1)::timestamptz and public.can_access_location(il.location_id)
            and(p_location_id is null or il.location_id=p_location_id)and(p_product_id is null or il.product_id=p_product_id) group by il.location_id,il.product_id
        ),v as(select q.*,p.name product_name,p.category_id,pc.name category_name,l.name location_name,
          cc.amount ccost,pp.amount pcost from q join public.products p on p.id=q.product_id join public.locations l on l.id=q.location_id left join public.product_categories pc on pc.id=p.category_id
          left join lateral(select x.amount from public.product_costs x left join public.accounting_event_rule_sets rs on rs.company_id=x.company_id and rs.status='approved'
            where x.company_id=p_company_id and x.product_id=q.product_id and x.currency_code=v_currency and x.cost_type=coalesce(rs.cost_method,'replacement_cost')
              and x.valid_from<(p_date_to+1)::timestamptz and(x.valid_to is null or x.valid_to>p_date_to::timestamptz)order by x.valid_from desc limit 1)cc on true
          left join lateral(select x.amount from public.product_costs x left join public.accounting_event_rule_sets rs on rs.company_id=x.company_id and rs.status='approved'
            where x.company_id=p_company_id and x.product_id=q.product_id and x.currency_code=v_currency and x.cost_type=coalesce(rs.cost_method,'replacement_cost')
              and x.valid_from<(v_previous_to+1)::timestamptz and(x.valid_to is null or x.valid_to>v_previous_to::timestamptz)order by x.valid_from desc limit 1)pp on true)
        select v_code,case p_dimension when'location'then location_id::text when'product'then product_id::text else coalesce(category_id::text,'uncategorized')end,
          case p_dimension when'location'then location_name when'product'then product_name else coalesce(category_name,'Sin categoría')end,
          sum(case when v_code='inventory_value'then cq*ccost else cq end),sum(case when v_code='inventory_value'then pq*pcost else pq end),
          not(v_code='inventory_value'and count(*)filter(where(cq<>0 and ccost is null)or(pq<>0 and pp is null))>0),
          case when v_code='inventory_value'and count(*)filter(where(cq<>0 and ccost is null)or(pq<>0 and pp is null))>0 then 'Hay saldos sin costo aprobado en el corte actual o comparable.'end
        from v group by 2,3;
      end if;
    end if;
  end loop;

  select count(*) into v_total from bi_explorer_result;
  select coalesce(jsonb_agg(to_jsonb(x)order by x.metric_code,x.current_value desc nulls last,x.group_label),'[]'::jsonb)into v_items
  from(select * from bi_explorer_result order by metric_code,current_value desc nulls last,group_label limit v_size offset(v_page-1)*v_size)x;
  select coalesce(jsonb_agg(to_jsonb(x)order by x.group_key,x.metric_code),'[]'::jsonb)into v_chart
  from(select * from bi_explorer_result where available order by abs(coalesce(current_value,0))desc limit 120)x;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(
    p_company_id,auth.uid(),'bi.explorer_queried','bi_query',
    jsonb_build_object('metrics',p_metric_codes,'dimension',p_dimension,'visualization',p_visualization,'date_from',p_date_from,'date_to',p_date_to,
      'location_id',p_location_id,'product_id',p_product_id,'customer_id',p_customer_id,'supplier_id',p_supplier_id,'page',v_page,'page_size',v_size));

  return jsonb_build_object('query',jsonb_build_object('metric_codes',p_metric_codes,'dimension',p_dimension,'visualization',p_visualization),
    'period',jsonb_build_object('from',p_date_from,'to',p_date_to,'previous_from',v_previous_from,'previous_to',v_previous_to),
    'currency_code',v_currency,'updated_at',now(),'chart',v_chart,'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'trace',jsonb_build_object('query','bi_explorer_query','company_id',p_company_id));
end $$;

revoke all on function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer) from public;
grant execute on function public.bi_explorer_query(uuid,text[],text,text,date,date,uuid,uuid,uuid,uuid,boolean,integer,integer) to authenticated;

create or replace function public.bi_get_explorer_drilldown(
  p_company_id uuid,p_metric_code text,p_dimension text,p_group_key text,
  p_date_from date,p_date_to date,p_location_id uuid default null,p_product_id uuid default null,
  p_customer_id uuid default null,p_supplier_id uuid default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_code text:=lower(trim(p_metric_code));v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint:=0;v_items jsonb:='[]'::jsonb;v_path text;
  v_group_uuid uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_bi') then raise exception 'No autorizado para consultar BI.';end if;
  if p_date_from is null or p_date_to is null or p_date_to<p_date_from or p_date_to-p_date_from+1>366 then raise exception 'Periodo de BI inválido.';end if;
  if p_dimension<>'period' and p_group_key not in('walk-in','uncategorized') then
    begin v_group_uuid:=p_group_key::uuid;exception when invalid_text_representation then raise exception 'Grupo de BI inválido.';end;
  end if;
  if p_dimension='period' then p_date_from:=p_group_key::date;p_date_to:=p_group_key::date;end if;

  -- Las métricas ya cubiertas conservan el drill-down canónico de Fases 1/2.
  if v_code in('net_sales','tickets','collections','supplier_payments','receivables','payables') then
    return public.bi_get_drilldown_v2(
      p_company_id,v_code,p_date_from,p_date_to,
      case when p_dimension='location'then v_group_uuid else p_location_id end,
      case when p_dimension='product'then v_group_uuid else p_product_id end,
      case when p_dimension='customer'and p_group_key<>'walk-in'then v_group_uuid else p_customer_id end,
      case when p_dimension='supplier'then v_group_uuid else p_supplier_id end,
      case when v_code in('receivables','payables')then p_date_to else null end,v_page,v_size
    );
  end if;

  if v_code='cash_net' then
    with filtered as materialized(
      select cm.id,cm.occurred_at, l.name party,cm.movement_type||coalesce(' · '||cm.reason,'') detail,cm.amount
      from public.cash_movements cm join public.cash_sessions cs on cs.id=cm.cash_session_id join public.locations l on l.id=cs.location_id
      where cm.company_id=p_company_id and cm.occurred_at::date between p_date_from and p_date_to and public.can_access_location(cs.location_id)
        and(case when p_dimension='location'then cs.location_id=v_group_uuid else p_location_id is null or cs.location_id=p_location_id end)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/ventas/caja';
  elsif v_code in('purchases_accrued','purchase_quantity') then
    with filtered as materialized(
      select il.id,inv.issued_date occurred_at,s.display_name party,inv.folio||' · '||p.name detail,
        case when v_code='purchase_quantity'then il.quantity else il.line_subtotal-il.invoice_discount_amount end amount
      from public.supplier_invoices inv join public.supplier_invoice_lines il on il.supplier_invoice_id=inv.id
      join public.purchase_receipt_lines prl on prl.id=il.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id
      join public.products p on p.id=il.product_id join public.suppliers s on s.id=inv.supplier_id
      where inv.company_id=p_company_id and inv.status='confirmed'and inv.document_type='invoice'and inv.reversed_at is null
        and inv.issued_date between p_date_from and p_date_to and public.can_access_location(pr.location_id)
        and(case p_dimension when'location'then pr.location_id=v_group_uuid when'product'then il.product_id=v_group_uuid
          when'category'then p.category_id is not distinct from v_group_uuid when'supplier'then inv.supplier_id=v_group_uuid else true end)
        and(p_location_id is null or pr.location_id=p_location_id)and(p_product_id is null or il.product_id=p_product_id)
        and(p_supplier_id is null or inv.supplier_id=p_supplier_id)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/compras/facturas';
  elsif v_code in('inventory_quantity','inventory_value') then
    with filtered as materialized(
      select il.id,il.occurred_at,l.name party,p.name||' · '||il.movement_type detail,
        case when v_code='inventory_quantity'then il.quantity_delta else il.quantity_delta*coalesce(pc.amount,0)end amount
      from public.inventory_ledger il join public.products p on p.id=il.product_id join public.locations l on l.id=il.location_id
      left join lateral(select c.amount from public.product_costs c where c.company_id=p_company_id and c.product_id=il.product_id
        and c.valid_from<=il.occurred_at and(c.valid_to is null or c.valid_to>il.occurred_at)order by c.valid_from desc limit 1)pc on true
      where il.company_id=p_company_id and il.occurred_at<(p_date_to+1)::timestamptz and public.can_access_location(il.location_id)
        and(case p_dimension when'location'then il.location_id=v_group_uuid when'product'then il.product_id=v_group_uuid
          when'category'then p.category_id is not distinct from v_group_uuid else true end)
        and(p_location_id is null or il.location_id=p_location_id)and(p_product_id is null or il.product_id=p_product_id)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/inventario/existencias';
  elsif v_code='bank_net_flow' then
    with filtered as materialized(
      select bt.id,bt.transaction_date occurred_at,fa.alias party,coalesce(bt.description,bt.reference)detail,
        case when bt.direction='credit'then bt.amount else -bt.amount end amount
      from public.bank_transactions bt join public.financial_accounts fa on fa.id=bt.financial_account_id
      where bt.company_id=p_company_id and bt.transaction_date between p_date_from and p_date_to
        and(p_dimension<>'financial_account'or bt.financial_account_id=v_group_uuid)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/contabilidad/bancos';
  elsif v_code='accounting_debits' then
    with filtered as materialized(
      select jl.id,e.entry_date occurred_at,a.code||' · '||a.name party,e.description detail,jl.debit amount
      from public.accounting_journal_entries e join public.accounting_journal_lines jl on jl.journal_entry_id=e.id
      join public.accounting_accounts a on a.id=jl.account_id and a.company_id=jl.company_id
      where e.company_id=p_company_id and e.status='posted'and e.entry_date between p_date_from and p_date_to
        and(p_dimension<>'account'or jl.account_id=v_group_uuid)
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/contabilidad/polizas';
  elsif v_code='payroll_runs' then
    with filtered as materialized(
      select pp.id,pp.payment_date occurred_at,pp.payment_frequency party,pp.status detail,1::numeric amount
      from public.payroll_periods pp where pp.company_id=p_company_id and pp.status in('approved','paid')and pp.payment_date between p_date_from and p_date_to
    ),paged as(select * from filtered order by occurred_at desc,id desc limit v_size offset(v_page-1)*v_size)
    select(select count(*)from filtered),coalesce(jsonb_agg(to_jsonb(paged)order by occurred_at desc,id desc),'[]')into v_total,v_items from paged;
    v_path:='/satrapy/colaboradores/nomina';
  else raise exception 'Métrica sin drill-down disponible.';end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'bi.explorer_drilldown_queried','bi_query',jsonb_build_object('metric_code',v_code,'dimension',p_dimension,'group_key',p_group_key,'page',v_page));
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),
    'source_path',v_path,'metric_code',v_code);
end $$;

revoke all on function public.bi_get_explorer_drilldown(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) from public;
grant execute on function public.bi_get_explorer_drilldown(uuid,text,text,text,date,date,uuid,uuid,uuid,uuid,integer,integer) to authenticated;
