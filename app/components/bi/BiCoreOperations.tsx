"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { ArrowUpRight, Building2, PackageSearch, ReceiptText, ShieldCheck, Truck } from "lucide-react";
import { getSupabaseClient } from "@/app/lib/supabase";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { OperationalButton as Button } from "@/app/components/reui/operational-controls";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/app/components/reui/tabs";
import { AnalyticsTable, BiState } from "@/app/components/ui/bi";
import { DataPagination } from "@/app/components/ui/data";
import { Badge } from "@/app/components/ui/primitives";

type Metric = { value: number | null; available: boolean; reason?: string | null; coverage?: number | null };
type ComparedMetric = { current: number | null; previous: number | null; change: number | null; change_percent: number | null };
type Profitability = {
  available: boolean; reason?: string;
  data?: { currency_code: string | null; metrics: { net_sales: number | null; net_cogs: number | null; gross_margin: number | null; operating_expenses: number | null; operating_contribution: number | null }; coverage: { recognized_cost_percent: number | null; sale_item_count: number; costed_sale_item_count: number }; limitations: string[] };
};
type LocationRow = { location_id: string; location_name: string; net_sales: ComparedMetric; gross_margin: ComparedMetric | null; gross_margin_quality?: string; gross_margin_reason?: string; profitability?: Profitability };
type InventoryPosition = { product_id: string; product_name: string; product_code: string; location_id: string; location_name: string; quantity_on_hand: number; unit: string; last_movement_at: string | null };
type ReplenishmentRow = { product_id: string; product_name: string; product_code: string; location_id: string; location_name: string; quantity_on_hand: number; minimum_quantity: number; suggested_quantity: number; unit: string; work_status: string; work_status_label: string };
type Operations = {
  contract: { generated_at: string };
  currency_code: string | null;
  locations: { items: LocationRow[]; pagination: { page: number; page_size: number; total: number }; partial: boolean; note: string };
  inventory: { replenishment_as_of: string; valuation_as_of: string; value: Metric; positions: { available?: boolean; reason?: string; items?: InventoryPosition[]; pagination?: {total: number} }; replenishment: { available?: boolean; reason?: string; total_below_minimum?: number; status_counts?: Record<string, number>; items?: ReplenishmentRow[] } };
  receivables: { as_of: string; open: Metric; overdue: Metric; note: string };
  supplier_signals: { available?: boolean; reason?: string; truncated?: boolean; items?: { supplier_id: string; supplier_name: string; purchase_signal_amount: number | null; connections: number }[] };
  quality: { partial: boolean; sources: Record<string, { available: boolean; reason?: string }> };
};

function money(value: number | null | undefined, currency: string | null) {
  if (value == null || !Number.isFinite(value)) return "—";
  return new Intl.NumberFormat("es-MX", currency ? { style: "currency", currency, maximumFractionDigits: 0 } : { maximumFractionDigits: 0 }).format(value);
}
const count = (value: number | undefined | null) => value == null ? "—" : value.toLocaleString("es-MX", { maximumFractionDigits: 2 });
const date = (value: string | null | undefined) => value ? new Date(value.length === 10 ? `${value}T12:00:00` : value).toLocaleDateString("es-MX") : "Fecha no disponible";

export function BiCoreOperations({ companyId, dateFrom, dateTo, locationId, comparisonMode, hasDetailFilters, refreshKey, onClearDetailFilters, onInspect, onInventory }: {
  companyId: string; dateFrom: string; dateTo: string; locationId: string; comparisonMode: "previous_period" | "previous_year"; hasDetailFilters: boolean; refreshKey: string;
  onClearDetailFilters: () => void; onInspect: (metricCode: string, locationId?: string) => void; onInventory: (metric: Metric, asOf: string) => void;
}) {
  const { appState } = useSatrapy();
  const permissions = appState?.membership.permissions ?? [];
  const can = (permission: string) => permissions.includes("*") || permissions.includes(permission);
  const [tab, setTab] = useState("profitability");
  const [page, setPage] = useState(1);
  const [retry, setRetry] = useState(0);
  const [data, setData] = useState<Operations | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    if (hasDetailFilters) return;
    const abort = new AbortController();
    void (async () => {
      setLoading(true); setError(null); setData(null);
      try {
        const { data: session } = await getSupabaseClient().auth.getSession();
        if (!session.session) throw new Error("La sesión venció. Vuelve a iniciar sesión para consultar la operación.");
        const params = new URLSearchParams({ company_id: companyId, date_from: dateFrom, date_to: dateTo, page: String(page), page_size: "5", comparison_mode: comparisonMode });
        if (locationId) params.set("location_id", locationId);
        const response = await fetch(`/api/bi/operations?${params}`, { headers: { authorization: `Bearer ${session.session.access_token}` }, cache: "no-store", signal: abort.signal });
        const result = await response.json();
        if (!response.ok) throw new Error(result.error ?? "No se pudo consultar la operación.");
        if (!abort.signal.aborted) { setData(result as Operations); onInventory((result as Operations).inventory.value, (result as Operations).inventory.valuation_as_of.slice(0,10)); }
      } catch (cause) {
        if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : "No se pudo consultar la operación.");
      } finally { if (!abort.signal.aborted) setLoading(false); }
    })();
    return () => abort.abort();
  }, [companyId, dateFrom, dateTo, locationId, comparisonMode, hasDetailFilters, page, retry, refreshKey, onInventory]);

  const queue = data?.inventory.replenishment;
  return <section className="bi-core-operations" id="bi-core-operations" aria-labelledby="bi-core-operations-title">
    <header><div><span className="eyebrow">De los resultados a la acción</span><h2 id="bi-core-operations-title">Resultados por área</h2><p>Rentabilidad por sucursal, faltantes por atender y dinero por cobrar.</p></div>{data && <span className="bi-core-timestamp"><ShieldCheck size={14} aria-hidden="true" /> Consultado {new Date(data.contract.generated_at).toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" })}</span>}</header>
    {hasDetailFilters ? <BiState kind="partial" title="Consulta la operación por sucursal" description="Los filtros de producto, cliente o proveedor se aplican al análisis de arriba. Para ver gastos, reposición y cartera juntos, conserva el periodo y la sucursal." action={<Button size="sm" onClick={onClearDetailFilters}>Quitar filtros de detalle</Button>} /> : <Tabs value={tab} onValueChange={setTab} className="bi-core-tabs">
      <TabsList variant="line" aria-label="Áreas de resultados">
        <TabsTrigger value="profitability"><Building2 size={15} aria-hidden="true" /> Rentabilidad</TabsTrigger>
        <TabsTrigger value="inventory"><PackageSearch size={15} aria-hidden="true" /> Inventario y compras</TabsTrigger>
        <TabsTrigger value="receivables"><ReceiptText size={15} aria-hidden="true" /> Cartera</TabsTrigger>
      </TabsList>
      {loading ? <BiState kind="loading" title="Consultando la operación…" description="Reuniendo resultados y pendientes de las sucursales autorizadas." /> : error ? <BiState kind="error" title="No se pudieron actualizar los resultados" description={error} action={<Button onClick={() => setRetry(value => value + 1)}>Reintentar</Button>} /> : data && <>
        <TabsContent value="profitability">
          <div className="bi-core-panel-intro"><div><h3>Resultado por sucursal</h3><p>{date(dateFrom)}–{date(dateTo)} · La contribución descuenta los gastos contabilizados y atribuidos a cada sucursal.</p></div><span className="bi-core-label">{data.currency_code ?? "Moneda no configurada"}</span></div>
          {data.quality.sources.net_sales_by_location?.available === false ? <BiState kind="partial" title="Rentabilidad no disponible" description={data.quality.sources.net_sales_by_location.reason ?? "No se pudo consultar el resultado de las sucursales."} /> : !data.locations.items.length ? <BiState kind="empty" title="Sin sucursales con ventas en este periodo" description="Amplía el periodo o consulta otra sucursal para revisar su resultado." /> : <AnalyticsTable caption="Rentabilidad por sucursal" className="bi-core-profitability-table"><thead><tr><th>Sucursal</th><th className="number-cell">Ventas netas</th><th className="number-cell">Margen bruto</th><th className="number-cell">Gastos atribuidos</th><th className="number-cell">Contribución</th><th>Costo reconocido</th><th><span className="sr-only">Detalle</span></th></tr></thead><tbody>{data.locations.items.map(row => {
            const result = row.profitability?.available ? row.profitability.data : undefined;
            const currency = result?.currency_code ?? data.currency_code;
            const coverage = result?.coverage.recognized_cost_percent;
            return <tr key={row.location_id}><td><strong>{row.location_name}</strong>{row.profitability?.reason && <small>{row.profitability.reason}</small>}</td><td className="number-cell">{money(result ? result.metrics.net_sales : row.net_sales?.current, currency)}</td><td className="number-cell">{money(result ? result.metrics.gross_margin : row.gross_margin?.current, currency)}</td><td className="number-cell">{money(result?.metrics.operating_expenses, currency)}</td><td className="number-cell"><strong className={result?.metrics.operating_contribution != null && result.metrics.operating_contribution < 0 ? "is-negative" : ""}>{money(result?.metrics.operating_contribution, currency)}</strong></td><td><Badge tone={coverage == null || coverage < 100 ? "warning" : "neutral"}>{coverage == null ? "Sin cobertura" : `${count(coverage)}%`}</Badge></td><td><Button variant="ghost" size="sm" aria-label={`Ver ventas de ${row.location_name}`} onClick={() => onInspect("net_sales", row.location_id)}>Ver ventas <ArrowUpRight size={14} /></Button></td></tr>;
          })}</tbody></AnalyticsTable>}
          <DataPagination page={data.locations.pagination.page} pageSize={data.locations.pagination.page_size} total={data.locations.pagination.total} onChange={setPage} label="sucursales" />
          <p className="bi-core-footnote">Contribución operativa: margen bruto menos gastos atribuidos. Quedan fuera gastos compartidos sin asignar. Un costo faltante deja el resultado sin calcular.</p>
          <details className="bi-core-coverage"><summary>Ver cobertura y alcance</summary><p>{data.locations.note}</p>{Object.entries(data.quality.sources).filter(([, source]) => !source.available).map(([key, source]) => <p key={key}>{source.reason ?? "Una fuente no está disponible con este acceso."}</p>)}<p>El margen comercial del análisis y este resultado pueden diferir por el tratamiento de devoluciones. El detalle de sucursal usa el costo reconocido de cada operación.</p></details>
        </TabsContent>
        <TabsContent value="inventory">
          <div className="bi-core-panel-intro"><div><h3>Qué necesita reposición</h3><p>Existencias y seguimiento actuales · {date(data.inventory.replenishment_as_of)}. La valuación también corresponde a las existencias actuales.</p></div>{(can("view_inventory") || can("manage_inventory_replenishment")) && <Link className="bi-core-action-link" href="/satrapy/inventario/reabastecimiento">Abrir reabastecimiento <ArrowUpRight size={14} /></Link>}</div>
          <div className="bi-core-stats"><article><span>Valor de inventario al {date(data.inventory.valuation_as_of)}</span><strong>{data.inventory.value.available ? money(data.inventory.value.value, data.currency_code) : "No disponible"}</strong><small>{data.inventory.value.reason ?? (data.inventory.value.coverage != null ? `Cobertura de costo: ${count(data.inventory.value.coverage)}%` : "Existencias y costos vigentes al consultar")}</small></article><article><span>Productos por ubicación bajo mínimo</span><strong>{count(queue?.total_below_minimum)}</strong><small>Únicamente productos con política de reposición</small></article><article><span>Faltantes sin atender</span><strong>{count(queue?.status_counts?.unattended)}</strong><small>Sin una gestión de abastecimiento activa</small></article></div>
          {queue?.available === false ? <BiState kind="partial" title="Reposición no disponible" description={queue.reason ?? "Revisa tus permisos de inventario."} /> : !queue?.items?.length ? <BiState kind="empty" title="Sin faltantes bajo mínimo en esta consulta" description="El resultado cubre los productos con políticas configuradas. Consulta Inventario para revisar el resto de las existencias." /> : <AnalyticsTable caption="Faltantes y cantidades sugeridas"><thead><tr><th>Producto / ubicación</th><th className="number-cell">Existencia</th><th className="number-cell">Mínimo</th><th className="number-cell">Reposición sugerida</th><th>Seguimiento</th></tr></thead><tbody>{queue.items.map(item => <tr key={`${item.location_id}:${item.product_id}`}><td><strong>{item.product_name}</strong><small>{item.product_code} · {item.location_name}</small></td><td className="number-cell">{count(item.quantity_on_hand)} {item.unit}</td><td className="number-cell">{count(item.minimum_quantity)} {item.unit}</td><td className="number-cell">{count(item.suggested_quantity)} {item.unit}</td><td><Badge tone={item.work_status === "unattended" ? "warning" : "neutral"}>{item.work_status_label}</Badge></td></tr>)}</tbody></AnalyticsTable>}
          {(queue?.total_below_minimum ?? 0) > (queue?.items?.length ?? 0) && <p className="bi-core-footnote">Mostrando {queue?.items?.length ?? 0} de {count(queue?.total_below_minimum)} faltantes. Continúa en Reabastecimiento para verlos y gestionarlos.</p>}
          <details className="bi-core-coverage bi-core-stock"><summary>Ver existencias registradas · {count(data.inventory.positions.pagination?.total)} productos por ubicación</summary>
            <p>Saldo operativo actual. La exactitud física se comprueba mediante conteos y conciliación de movimientos.</p>
            {data.inventory.positions.available === false ? <BiState kind="partial" title="Existencias no disponibles" description={data.inventory.positions.reason} /> : data.inventory.positions.items?.length ? <AnalyticsTable caption="Existencias actuales por producto y ubicación"><thead><tr><th>Producto</th><th>Ubicación</th><th className="number-cell">Existencia</th><th>Último movimiento</th></tr></thead><tbody>{data.inventory.positions.items.map(item => <tr key={`${item.location_id}:${item.product_id}`}><td><strong>{item.product_name}</strong><small>{item.product_code}</small></td><td>{item.location_name}</td><td className="number-cell">{count(item.quantity_on_hand)} {item.unit}</td><td>{date(item.last_movement_at)}</td></tr>)}</tbody></AnalyticsTable> : <p>Sin saldos operativos registrados para este alcance.</p>}
            {can("view_inventory") && <Link className="bi-core-action-link" href="/satrapy/inventario/existencias">Ver todo el inventario <ArrowUpRight size={14} /></Link>}
          </details>
          <div className="bi-core-supplier"><header><Truck size={17} aria-hidden="true" /><h3>Dependencia de proveedores</h3>{can("view_bi_dependency_network") && <Link className="bi-core-action-link" href={`/satrapy/bi/red?from=${dateFrom}&to=${dateTo}${locationId ? `&location=${locationId}` : ""}`}>Explorar red <ArrowUpRight size={14} /></Link>}</header><p>Compras observadas o comprometidas en el periodo. La concentración indica dependencia; no mide puntualidad ni calidad.</p>{data.supplier_signals.available === false ? <p>{data.supplier_signals.reason}</p> : data.supplier_signals.items?.length ? <ul>{data.supplier_signals.items.slice(0, 5).map(item => <li key={item.supplier_id}><span>{item.supplier_name}</span><strong>{money(item.purchase_signal_amount, data.currency_code)}</strong></li>)}</ul> : <p>Sin relaciones de abastecimiento comprobadas en el periodo.</p>}{data.supplier_signals.truncated && <small>Vista acotada. Abre la red para investigar las relaciones restantes.</small>}</div>
        </TabsContent>
        <TabsContent value="receivables">
          <div className="bi-core-panel-intro"><div><h3>Dinero por cobrar</h3><p>Saldos al {date(data.receivables.as_of)} para el alcance seleccionado.</p></div>{can("view_customer_credit") && can("record_receivable_payment") && <Link className="bi-core-action-link" href="/satrapy/ventas/cuentas-por-cobrar">Abrir cuentas por cobrar <ArrowUpRight size={14} /></Link>}</div>
          <div className="bi-core-stats bi-core-stats--two"><article><span>Cartera pendiente</span><strong>{data.receivables.open.available ? money(data.receivables.open.value, data.currency_code) : "No disponible"}</strong><small>{data.receivables.open.reason ?? "Documentos y aplicaciones de cobro al corte"}</small><Button variant="ghost" size="sm" disabled={!data.receivables.open.available} onClick={() => onInspect("receivables")}>Revisar clientes <ArrowUpRight size={14} /></Button></article><article><span>Cartera vencida</span><strong className={(data.receivables.overdue.value ?? 0) > 0 ? "is-negative" : ""}>{data.receivables.overdue.available ? money(data.receivables.overdue.value, data.currency_code) : "No disponible"}</strong><small>{data.receivables.overdue.reason ?? "Saldo con fecha de vencimiento anterior al corte"}</small><Button variant="ghost" size="sm" disabled={!data.receivables.overdue.available} onClick={() => onInspect("overdue_receivables")}>Revisar vencimientos <ArrowUpRight size={14} /></Button></article></div>
          <p className="bi-core-footnote">{data.receivables.note}</p>
        </TabsContent>
      </>}
    </Tabs>}
  </section>;
}
