"use client";

import { Activity, AlertCircle, ArrowDownRight, ArrowUpRight, ChevronLeft, ChevronRight, CircleHelp, Copy, Database, Download, GitFork, LayoutDashboard, LoaderCircle, Plus, RefreshCw, Save, Search, Target, Trash2, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { DataPagination, DataState, PageHeading, Table } from "@/app/components/ui/data";
import { Badge, Button, Input, Modal, Select } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { BiBudgetsModule } from "@/app/components/BiBudgetsModule";
import { BiDependencyNetwork } from "@/app/components/BiDependencyNetwork";

export type BiView = "summary" | "explorer" | "reports" | "budgets" | "network";

type FilterOption = { id: string; label: string; secondary?: string };
type FilterSelection = FilterOption | null;
type BiFilters = {
  dateFrom: string;
  dateTo: string;
  locationId: string;
  product: FilterSelection;
  customer: FilterSelection;
  supplier: FilterSelection;
};
type ExecutivePeriodPreset = "today" | "last7" | "last30" | "last90" | "thisMonth" | "previousMonth" | "thisQuarter" | "custom";
type BiMetric = { code: string; value: number | null; previous_value?: number | null; available: boolean; reason?: string | null; coverage?: number | null };
type BiChartPoint = { index?: number; date: string; value: number | null; previous_date?: string; previous_value?: number | null; period?: "current" | "previous" };
type BiChart = {
  code: "sales" | "gross_margin" | "cash_flow" | "receivables" | "payables" | "inventory";
  metric_code: string;
  kind: "Devengado" | "Efectivo" | "Operativo";
  visualization: "line" | "area" | "bars";
  available: boolean;
  reason?: string | null;
  points: BiChartPoint[];
};
type BiAnalytics = {
  period: BiSummary["period"];
  updated_at: string;
  currency_code: string | null;
  charts: BiChart[];
  comparisons: Record<string, Partial<BiMetric>>;
  trace: { query: string; sources: string[]; company_id: string };
};
type BiSummary = {
  period: { from: string; to: string; previous_from: string; previous_to: string; days: number };
  updated_at: string;
  currency_code: string | null;
  metrics: BiMetric[];
  series: Array<{ date: string; sales: number | null; collections: number | null; supplier_payments: number | null }>;
  locations: Array<{ location_id: string; location_name: string; sales: number; tickets: number }>;
  trace: { query: string; sources: string[]; company_id: string };
};
type ExecutiveBudgetSummary = {
  available:boolean;reason?:string|null;version_id?:string;name?:string;scope_type?:string;scope_label?:string;
  period_type?:string;period_start?:string;period_end?:string;unit_code?:string;budget_value?:number;actual_value?:number;
  attainment_percent?:number|null;remaining_value?:number;projection_value?:number;pace_percent?:number;
  status?:"on_track"|"behind";fallback_used?:boolean;monitored_count:number;late_count:number;updated_at:string;
  trace:{query:string;source:string};
};
type Drilldown = {
  items: Array<{ id: string; occurred_at: string; party?: string; location_name?: string; detail?: string; sale_type?: string; amount?: number }>;
  pagination: { page: number; page_size: number; total: number };
  source_path: string;
  metric_code: string;
  as_of?: string;
};
type DrillRequest = { code: string; dateFrom?: string; dateTo?: string; asOf?: string };
type ExplorerMetric = {
  code: string;name: string;module: string;formula:string;unit:"currency"|"count"|"quantity"|"percent"|"days";
  source:string;grain:string;dimensions:string[];kind:"accrual"|"cash"|"operational";
  visualizations:Array<"line"|"bar"|"area"|"scatter">;drilldown:boolean;available:boolean;
  unavailable_reason?:string|null;limitations:string;
};
type ExplorerCatalog = {
  updated_at:string;currency_code:string|null;
  dimensions:Array<{code:string;name:string}>;metrics:ExplorerMetric[];
};
type ExplorerRow = {
  metric_code:string;group_key:string;group_label:string;current_value:number|null;previous_value:number|null;available:boolean;reason?:string|null;
};
type ExplorerResult = {
  query:{metric_codes:string[];dimension:string;visualization:string};
  period:{from:string;to:string;previous_from:string;previous_to:string};
  currency_code:string|null;updated_at:string;chart:ExplorerRow[];items:ExplorerRow[];
  pagination:{page:number;page_size:number;total:number};trace:{query:string;company_id:string};
};
type ExplorerDrillRequest = { metricCode:string;dimension:string;groupKey:string;groupLabel:string };
type SavedView={id:string;owner_id:string;name:string;description?:string|null;visibility:"private"|"company";current_version:number;definition:Record<string,unknown>;availability:{available:boolean;warnings:string[]};updated_at:string};
type Dashboard={id:string;name:string;description?:string|null;revision:number;widget_count:number;default_filters?:Record<string,unknown>};
type DashboardWidget={id:string;dashboard_id:string;saved_view_id:string;widget_type:"kpi"|"chart"|"table"|"network";title?:string|null;filter_mode:"inherit"|"own";position:number;width:number;height:number;view_name:string;status:"ready"|"error";error?:string;definition?:Record<string,unknown>;result?:ExplorerResult};
type DashboardSnapshot={dashboard:Dashboard;widgets:DashboardWidget[];updated_at:string};

const METRICS: Record<string, { label: string; kind: "Devengado" | "Efectivo" | "Operativo" | "Control"; formula: string; source: string; format?: "integer" | "percent" }> = {
  net_sales: { label: "Ventas netas", kind: "Devengado", formula: "Σ subtotal − descuentos de ventas no canceladas", source: "Ventas y partidas canónicas" },
  gross_margin: { label: "Margen bruto", kind: "Devengado", formula: "Ventas netas − costo reconocido congelado por partida", source: "Ventas y partidas canónicas con costo reconocido" },
  tickets: { label: "Tickets", kind: "Operativo", formula: "Conteo de ventas completadas no canceladas", source: "Ventas canónicas", format: "integer" },
  average_ticket: { label: "Ticket promedio", kind: "Operativo", formula: "Ventas netas ÷ tickets", source: "Ventas canónicas" },
  collections: { label: "Cobranza", kind: "Efectivo", formula: "Σ cobros confirmados no revertidos", source: "CxC y aplicaciones de cobro" },
  supplier_payments: { label: "Pagos a proveedores", kind: "Efectivo", formula: "Σ pagos confirmados no revertidos", source: "CxP y pagos a proveedor" },
  bank_net_flow: { label: "Flujo bancario neto", kind: "Efectivo", formula: "Créditos bancarios − débitos bancarios", source: "Movimientos bancarios promovidos" },
  receivables: { label: "Saldo CxC", kind: "Devengado", formula: "Documentos emitidos − aplicaciones vigentes al corte", source: "Cuentas por cobrar" },
  overdue_receivables: { label: "CxC vencida", kind: "Devengado", formula: "Saldo CxC con vencimiento anterior al corte", source: "Cuentas por cobrar" },
  payables: { label: "Saldo CxP", kind: "Devengado", formula: "Saldo operativo vigente de documentos por pagar", source: "Cuentas por pagar" },
  inventory_value: { label: "Valor de inventario", kind: "Operativo", formula: "Cantidad disponible × costo vigente aprobado", source: "Inventario, costos y matriz contable" },
  payroll_accrued: { label: "Nómina aprobada", kind: "Devengado", formula: "Σ pago total de corridas aprobadas o pagadas", source: "Nómina interna" },
  bank_reconciliation: { label: "Conciliación bancaria", kind: "Control", formula: "Transacciones conciliadas ÷ transacciones del periodo", source: "Bancos y conciliaciones", format: "percent" },
};

const CHART_META: Record<BiChart["code"], { title: string; description: string }> = {
  sales: { title: "Ventas devengadas", description: "Ventas completadas sin impuestos, alineadas contra el periodo anterior." },
  gross_margin: { title: "Margen bruto", description: "Usa únicamente el costo congelado al confirmar cada partida; no reconstruye el pasado con costos vigentes." },
  cash_flow: { title: "Flujo bancario neto", description: "Créditos menos débitos bancarios; no equivale a utilidad devengada." },
  receivables: { title: "Cuentas por cobrar", description: "Saldo reconstruido al cierre de cada periodo comparable." },
  payables: { title: "Cuentas por pagar", description: "Saldo reconstruido desde facturas, notas y pagos efectivos." },
  inventory: { title: "Valor de inventario", description: "Existencia por costo aprobado vigente en cada fecha de corte." },
};

const CHART_FOR_METRIC: Record<string, BiChart["code"] | undefined> = {
  net_sales: "sales",
  gross_margin: "gross_margin",
  bank_net_flow: "cash_flow",
  receivables: "receivables",
  payables: "payables",
  inventory_value: "inventory",
};

function isoDate(date: Date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
function formatSourceDate(value: string) {
  return new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00` : value).toLocaleDateString("es-MX");
}
function initialFilters(search?: { get(name: string): string | null }): BiFilters {
  const to = new Date();
  const from = new Date(to);
  from.setDate(from.getDate() - 29);
  const defaultFrom=isoDate(from),defaultTo=isoDate(to);
  const queryFrom=search?.get("from"),queryTo=search?.get("to");
  const dateFrom=queryFrom&&/^\d{4}-\d{2}-\d{2}$/.test(queryFrom)?queryFrom:defaultFrom;
  const dateTo=queryTo&&/^\d{4}-\d{2}-\d{2}$/.test(queryTo)?queryTo:defaultTo;
  const selected=(dimension:"product"|"customer"|"supplier"):FilterSelection=>{
    const id=search?.get(dimension);return id?{id,label:search?.get(`${dimension}_label`)??"Selección conservada"}:null;
  };
  return { dateFrom, dateTo, locationId: search?.get("location") ?? "", product:selected("product"), customer:selected("customer"), supplier:selected("supplier") };
}
function executivePeriodRange(preset:Exclude<ExecutivePeriodPreset,"custom">){
  const today=new Date(),from=new Date(today),to=new Date(today);
  if(preset==="last7")from.setDate(from.getDate()-6);
  if(preset==="last30")from.setDate(from.getDate()-29);
  if(preset==="last90")from.setDate(from.getDate()-89);
  if(preset==="thisMonth")from.setDate(1);
  if(preset==="previousMonth"){
    from.setMonth(from.getMonth()-1,1);
    to.setDate(0);
  }
  if(preset==="thisQuarter"){
    from.setMonth(Math.floor(from.getMonth()/3)*3,1);
  }
  return{dateFrom:isoDate(from),dateTo:isoDate(to)};
}
function inferExecutivePeriod(filters:Pick<BiFilters,"dateFrom"|"dateTo">):ExecutivePeriodPreset{
  const presets=(["today","last7","last30","last90","thisMonth","previousMonth","thisQuarter"] as const);
  return presets.find(preset=>{const range=executivePeriodRange(preset);return range.dateFrom===filters.dateFrom&&range.dateTo===filters.dateTo;})??"custom";
}
const EXECUTIVE_PERIOD_OPTIONS=[
  {value:"today",label:"Hoy"},
  {value:"last7",label:"Últimos 7 días"},
  {value:"last30",label:"Últimos 30 días"},
  {value:"last90",label:"Últimos 90 días"},
  {value:"thisMonth",label:"Este mes"},
  {value:"previousMonth",label:"Mes anterior"},
  {value:"thisQuarter",label:"Este trimestre"},
  {value:"custom",label:"Periodo personalizado"},
] satisfies Array<{value:ExecutivePeriodPreset;label:string}>;
function formatMoney(value: number | null | undefined, currencyCode?: string | null) {
  if (value == null) return "—";
  if (!currencyCode) return value.toLocaleString("es-MX", { maximumFractionDigits: 0 });
  return new Intl.NumberFormat("es-MX", { style: "currency", currency: currencyCode, maximumFractionDigits: 0 }).format(value);
}
function formatMetric(metric: BiMetric, currencyCode?: string | null) {
  const meta = METRICS[metric.code];
  if (!metric.available || metric.value == null) return "—";
  if (meta?.format === "integer") return metric.value.toLocaleString("es-MX", { maximumFractionDigits: 0 });
  if (meta?.format === "percent") return `${metric.value.toLocaleString("es-MX", { maximumFractionDigits: 1 })}%`;
  return formatMoney(metric.value, currencyCode);
}
function comparison(metric: BiMetric) {
  if (!metric.available || metric.value == null || metric.previous_value == null) return null;
  const absolute=metric.value-metric.previous_value;
  return { absolute,percent:metric.previous_value===0?null:(absolute/Math.abs(metric.previous_value))*100 };
}
function formatDifference(metric: BiMetric, value: number, currencyCode?: string | null) {
  const meta=METRICS[metric.code];
  if(meta?.format==="integer")return `${value>=0?"+":""}${value.toLocaleString("es-MX",{maximumFractionDigits:0})}`;
  if(meta?.format==="percent")return `${value>=0?"+":""}${value.toLocaleString("es-MX",{maximumFractionDigits:1})} pp`;
  const formatted=formatMoney(Math.abs(value),currencyCode);
  return `${value>=0?"+":"−"}${formatted}`;
}
function fallbackCharts(summary: BiSummary): BiChart[] {
  const metric=(code:string)=>summary.metrics.find(item=>item.code===code);
  const comparisonPoints=(code:string):BiChartPoint[]=>{
    const item=metric(code);if(!item)return[];
    return [
      ...(item.previous_value==null?[]:[{date:summary.period.previous_to,period:"previous" as const,value:item.previous_value}]),
      {date:summary.period.to,period:"current" as const,value:item.value},
    ];
  };
  return [
    {code:"sales",metric_code:"net_sales",kind:"Devengado",visualization:"line",available:Boolean(metric("net_sales")?.available),reason:metric("net_sales")?.reason,
      points:summary.series.map((point,index)=>({index,date:point.date,value:point.sales}))},
    {code:"gross_margin",metric_code:"gross_margin",kind:"Devengado",visualization:"line",available:Boolean(metric("gross_margin")?.available),
      reason:metric("gross_margin")?.reason,points:comparisonPoints("gross_margin")},
    {code:"cash_flow",metric_code:"bank_net_flow",kind:"Efectivo",visualization:"bars",available:Boolean(metric("bank_net_flow")?.available),reason:metric("bank_net_flow")?.reason,points:comparisonPoints("bank_net_flow")},
    {code:"receivables",metric_code:"receivables",kind:"Devengado",visualization:"bars",available:Boolean(metric("receivables")?.available),reason:metric("receivables")?.reason,points:comparisonPoints("receivables")},
    {code:"payables",metric_code:"payables",kind:"Devengado",visualization:"bars",available:Boolean(metric("payables")?.available),reason:metric("payables")?.reason,points:comparisonPoints("payables")},
    {code:"inventory",metric_code:"inventory_value",kind:"Operativo",visualization:"bars",available:Boolean(metric("inventory_value")?.available),reason:metric("inventory_value")?.reason,points:comparisonPoints("inventory_value")},
  ];
}

export function BiModule({ companyId, view }: { companyId: string; view: BiView }) {
  if(view==="explorer")return <BiExplorer companyId={companyId}/>;
  if(view==="reports")return <BiWorkspace companyId={companyId}/>;
  if(view==="budgets")return <BiBudgetsModule companyId={companyId}/>;
  if(view==="network")return <BiDependencyNetwork companyId={companyId}/>;
  if (view !== "summary") return <section className="content-frame module-page bi-roadmap" />;
  return <BiExecutiveSummary companyId={companyId} />;
}

const EXPLORER_KIND={accrual:"Devengada",cash:"Efectiva",operational:"Operativa"} as const;
const EXPLORER_VIZ={line:"Línea",bar:"Barras",area:"Área",scatter:"Dispersión"} as const;
const EXPLORER_COLORS=["#1f5c53","#417ca0","#b8782d","#76568f"];

function explorerFilters(search:{get(name:string):string|null}):BiFilters{
  const base=initialFilters(search);
  return base;
}

function BiExplorer({companyId}:{companyId:string}){
  const {accessibleLocations,appState}=useSatrapy();const router=useRouter();const search=useSearchParams();
  const canSaveViews=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("manage_own_bi_views"));
  const [catalog,setCatalog]=useState<ExplorerCatalog|null>(null);
  const [catalogError,setCatalogError]=useState<string|null>(null);
  const [selected,setSelected]=useState<string[]>(()=>search.get("metrics")?.split(",").filter(Boolean).slice(0,4)??["net_sales"]);
  const [dimension,setDimension]=useState(search.get("dimension")??"period");
  const [visualization,setVisualization]=useState<"line"|"bar"|"area"|"scatter">((search.get("visualization")as "line"|"bar"|"area"|"scatter")??"line");
  const [filters,setFilters]=useState<BiFilters>(()=>explorerFilters(search));
  const [applied,setApplied]=useState<BiFilters>(filters);const [result,setResult]=useState<ExplorerResult|null>(null);
  const [loading,setLoading]=useState(false);const [error,setError]=useState<string|null>(null);const [page,setPage]=useState(1);
  const [definition,setDefinition]=useState<ExplorerMetric|null>(null);const [drill,setDrill]=useState<ExplorerDrillRequest|null>(null);
  const [saveOpen,setSaveOpen]=useState(false);const [saveName,setSaveName]=useState(search.get("view_name")??"");const[saveDescription,setSaveDescription]=useState(search.get("view_description")??"");
  const[saveVisibility,setSaveVisibility]=useState<"private"|"company">(search.get("view_visibility")==="company"?"company":"private");const[saving,setSaving]=useState(false);const[saveError,setSaveError]=useState<string|null>(null);

  useEffect(()=>{let cancelled=false;void Promise.resolve().then(async()=>{
    const response=await getSupabaseClient().rpc("bi_get_metric_catalog",{p_company_id:companyId});
    if(cancelled)return;if(response.error)setCatalogError(response.error.message);else setCatalog(response.data as ExplorerCatalog);
  });return()=>{cancelled=true;};},[companyId]);

  const selectedMetrics=useMemo(()=>selected.map(code=>catalog?.metrics.find(metric=>metric.code===code)).filter((metric):metric is ExplorerMetric=>Boolean(metric)),[catalog,selected]);
  const compatibleDimensions=useMemo(()=>{
    if(!selectedMetrics.length)return[];
    return selectedMetrics.slice(1).reduce((all,metric)=>all.filter(code=>metric.dimensions.includes(code)),[...selectedMetrics[0].dimensions]);
  },[selectedMetrics]);
  const effectiveDimension=compatibleDimensions.includes(dimension)?dimension:(compatibleDimensions[0]??dimension);
  const compatibleVisualizations=useMemo(()=>{
    if(!selectedMetrics.length)return[];
    const common=selectedMetrics.slice(1).reduce<ExplorerMetric["visualizations"]>((all,metric)=>all.filter(code=>metric.visualizations.includes(code)),[...selectedMetrics[0].visualizations]);
    return common.filter(code=>(effectiveDimension==="period"||!["line","area"].includes(code))&&(code!=="scatter"||selectedMetrics.length===2));
  },[effectiveDimension,selectedMetrics]);
  const effectiveVisualization=compatibleVisualizations.includes(visualization)?visualization:(compatibleVisualizations[0]??visualization);
  const mixedKinds=new Set(selectedMetrics.map(metric=>metric.kind)).size>1;

  const load=useCallback(async(nextPage:number,nextFilters=applied)=>{
    if(!catalog||!selected.length||!effectiveDimension||!effectiveVisualization)return;
    setLoading(true);setError(null);
    const response=await getSupabaseClient().rpc("bi_explorer_query",{
      p_company_id:companyId,p_metric_codes:selected,p_dimension:effectiveDimension,p_visualization:effectiveVisualization,
      p_date_from:nextFilters.dateFrom,p_date_to:nextFilters.dateTo,p_location_id:nextFilters.locationId||null,
      p_product_id:nextFilters.product?.id??null,p_customer_id:nextFilters.customer?.id??null,p_supplier_id:nextFilters.supplier?.id??null,
      p_compare_previous:true,p_page:nextPage,p_page_size:25,
    });
    if(response.error)setError(response.error.message);else setResult(response.data as ExplorerResult);setLoading(false);
  },[applied,catalog,companyId,effectiveDimension,effectiveVisualization,selected]);

  useEffect(()=>{if(catalog)void Promise.resolve().then(()=>load(page));},[catalog,page,load]);

  function toggleMetric(metric:ExplorerMetric){
    if(!metric.available)return;
    if(selected.includes(metric.code)){if(selected.length>1)setSelected(current=>current.filter(code=>code!==metric.code));return;}
    if(selected.length>=4)return;
    const first=selectedMetrics[0];
    if(first&&(first.grain!==metric.grain||first.unit!==metric.unit||!compatibleDimensions.some(code=>metric.dimensions.includes(code))))return;
    setSelected(current=>[...current,metric.code]);setPage(1);
  }
  function apply(){
    setApplied(filters);setPage(1);
    const query=new URLSearchParams();query.set("metrics",selected.join(","));query.set("dimension",effectiveDimension);query.set("visualization",effectiveVisualization);
    query.set("from",filters.dateFrom);query.set("to",filters.dateTo);
    if(filters.locationId)query.set("location",filters.locationId);
    for(const key of ["product","customer","supplier"]as const){const value=filters[key];if(value){query.set(key,value.id);query.set(`${key}_label`,value.label);}}
    router.replace(`/satrapy/bi/explorador?${query.toString()}`);void load(1,filters);
  }
  const firstMetric=selectedMetrics[0];
  const canAdd=(metric:ExplorerMetric)=>{
    if(metric.code==="gross_margin"||firstMetric?.code==="gross_margin")return !firstMetric||firstMetric.code===metric.code;
    return !firstMetric||(metric.grain===firstMetric.grain&&metric.unit===firstMetric.unit&&compatibleDimensions.some(code=>metric.dimensions.includes(code)));
  };

  return <section className="content-frame module-page bi-module bi-explorer">
    <PageHeading eyebrow="Business Intelligence · Fase 3" title="Explorador transversal" description="Compara métricas únicamente cuando comparten granularidad, unidad y dimensiones comprobadas. Toda agregación y paginación ocurre en servidor." action={<div className="bi-heading-actions"><Button variant="secondary" size="sm" onClick={()=>void load(page)} disabled={loading}><RefreshCw size={14}/>Actualizar</Button>{canSaveViews&&<Button size="sm" onClick={()=>setSaveOpen(true)} disabled={!result}><Save size={14}/>Guardar vista</Button>}</div>}/>
    {catalogError?<div className="bi-partial-state" role="alert"><AlertCircle size={16}/><span><strong>Catálogo no disponible</strong>{catalogError}</span></div>:!catalog?<div className="bi-refreshing"><LoaderCircle className="spin" size={15}/>Cargando catálogo de compatibilidad…</div>:<>
      <div className="bi-explorer-builder">
        <section className="bi-metric-picker"><header><div><span className="eyebrow">1 · Métricas</span><h2>¿Qué quieres comparar?</h2></div><Badge tone="neutral">{selected.length}/4</Badge></header>
          <div>{catalog.metrics.map(metric=>{const active=selected.includes(metric.code);const compatible=canAdd(metric);return <article key={metric.code} className={`${active?"is-selected":""} ${!metric.available?"is-unavailable":""}`}>
            <button type="button" className="bi-metric-picker__select" disabled={!metric.available||(!active&&!compatible)||(!active&&selected.length>=4)} onClick={()=>toggleMetric(metric)} aria-pressed={active}>
              <span><small>{metric.module} · {EXPLORER_KIND[metric.kind]}</small><strong>{metric.name}</strong></span><i>{active?"✓":"+"}</i>
            </button>
            <button type="button" className="bi-metric-picker__help" aria-label={`Definición de ${metric.name}`} onClick={()=>setDefinition(metric)}><CircleHelp size={14}/></button>
            {!metric.available&&<p>{metric.unavailable_reason}</p>}
            {metric.available&&!active&&!compatible&&<p>{metric.code==="gross_margin"||firstMetric?.code==="gross_margin"?"Margen se consulta individualmente para conservar la cobertura verificable.":"No comparte granularidad, unidad o dimensión con la selección."}</p>}
          </article>;})}</div>
        </section>
        <section className="bi-explorer-config"><span className="eyebrow">2 · Forma del análisis</span>
          <label><span>Dimensión compatible</span><Select ariaLabel="Dimensión compatible" value={effectiveDimension} onValueChange={setDimension} options={compatibleDimensions.map(code=>({value:code,label:catalog.dimensions.find(item=>item.code===code)?.name??code}))}/></label>
          <label><span>Visualización apropiada</span><Select ariaLabel="Visualización apropiada" value={effectiveVisualization} onValueChange={value=>setVisualization(value as typeof visualization)} options={compatibleVisualizations.map(code=>({value:code,label:EXPLORER_VIZ[code]}))}/></label>
          <div className="bi-compatibility-state"><Activity size={16}/><span><strong>Compatibilidad validada</strong>{selectedMetrics.length?`${selectedMetrics.map(metric=>metric.name).join(" + ")} · ${firstMetric?.grain==="position_cutoff"?"posición al corte":firstMetric?.grain==="payroll_period"?"periodo de nómina":"flujo diario"} · ${firstMetric?.unit==="currency"?(catalog.currency_code??"moneda base"):firstMetric?.unit}`:"Selecciona una métrica."}</span></div>
          {mixedKinds&&<div className="bi-accrual-warning"><AlertCircle size={15}/><span><strong>Series de naturaleza distinta</strong>Se muestran separadas: lo devengado describe efecto económico y lo efectivo describe movimiento de dinero. No se suman.</span></div>}
        </section>
      </div>
      <div className="bi-filters" aria-label="Filtros del Explorador">
        <label><span>Desde</span><Input type="date" value={filters.dateFrom} max={filters.dateTo} onChange={event=>setFilters(current=>({...current,dateFrom:event.target.value}))}/></label>
        <label><span>Hasta</span><Input type="date" value={filters.dateTo} min={filters.dateFrom} max={isoDate(new Date())} onChange={event=>setFilters(current=>({...current,dateTo:event.target.value}))}/></label>
        <label><span>Ubicación</span><Select ariaLabel="Filtrar por ubicación" value={filters.locationId||"__all__"} onValueChange={value=>setFilters(current=>({...current,locationId:value==="__all__"?"":value}))} options={[{value:"__all__",label:"Todas las accesibles"},...accessibleLocations.filter(location=>location.is_active).map(location=>({value:location.id,label:location.name}))]}/></label>
        <BiEntityFilter companyId={companyId} dimension="product" label="Producto" value={filters.product} onChange={value=>setFilters(current=>({...current,product:value}))}/>
        <BiEntityFilter companyId={companyId} dimension="customer" label="Cliente" value={filters.customer} onChange={value=>setFilters(current=>({...current,customer:value}))}/>
        <BiEntityFilter companyId={companyId} dimension="supplier" label="Proveedor" value={filters.supplier} onChange={value=>setFilters(current=>({...current,supplier:value}))}/>
        <div className="bi-filters__actions"><Button size="sm" onClick={apply} disabled={!selected.length||!compatibleVisualizations.length}>Ejecutar consulta</Button></div>
      </div>
      {result&&<div className="bi-query-status"><Database size={14}/><span>{result.trace.query} · actualizado {new Date(result.updated_at).toLocaleString("es-MX")}</span><Badge tone="neutral">{result.pagination.total.toLocaleString("es-MX")} agregados</Badge></div>}
      <DataState loading={loading&&!result} error={error} hasData={result?.chart.length??0} empty="No existen agregados para esta consulta compatible." errorAction={<Button size="sm" onClick={()=>void load(page)}>Reintentar</Button>}>
        {result&&<><ExplorerChart result={result} metrics={selectedMetrics} visualization={effectiveVisualization} dimension={effectiveDimension} onInspect={setDrill}/>
          <article className="bi-explorer-table"><header><div><span className="eyebrow">Respaldo analítico</span><h2>Agregados paginados</h2><p>Orden y paginación server-side; abre una fila para rastrear sus operaciones de origen.</p></div></header>
            <Table><thead><tr><th>Grupo</th><th>Métrica</th><th>Naturaleza</th><th className="number-cell">Periodo actual</th><th className="number-cell">Periodo anterior</th><th className="number-cell">Variación</th><th/></tr></thead>
              <tbody>{result.items.map(row=>{const metric=catalog.metrics.find(item=>item.code===row.metric_code);const delta=row.current_value!=null&&row.previous_value!=null?row.current_value-row.previous_value:null;return <tr key={`${row.metric_code}:${row.group_key}`}>
                <td><strong>{row.group_label}</strong></td><td>{metric?.name??row.metric_code}</td><td><Badge tone={metric?.kind==="cash"?"info":metric?.kind==="accrual"?"primary":"neutral"}>{metric?EXPLORER_KIND[metric.kind]:"—"}</Badge></td>
                <td className="number-cell">{formatExplorerValue(row.current_value,metric,result.currency_code)}</td><td className="number-cell">{formatExplorerValue(row.previous_value,metric,result.currency_code)}</td>
                <td className="number-cell">{delta==null?"—":formatExplorerValue(delta,metric,result.currency_code)}</td><td><button className="table-link" disabled={!metric?.drilldown} onClick={()=>metric&&setDrill({metricCode:metric.code,dimension:effectiveDimension,groupKey:row.group_key,groupLabel:row.group_label})}>Origen <ChevronRight size={13}/></button></td>
              </tr>;})}</tbody></Table>
            <DataPagination page={result.pagination.page} pageSize={result.pagination.page_size} total={result.pagination.total} onChange={setPage} label="agregados"/>
          </article>
        </>}
      </DataState>
      <ExplorerDefinition metric={definition} catalog={catalog} onClose={()=>setDefinition(null)}/>
      <ExplorerDrilldown companyId={companyId} request={drill} filters={applied} currencyCode={catalog.currency_code} onClose={()=>setDrill(null)}/>
      <Modal open={saveOpen} onOpenChange={open=>!open&&setSaveOpen(false)} eyebrow="Vista reutilizable" title={search.get("saved_view")?"Actualizar vista":"Guardar consulta"} description="Se guarda la configuración validada, nunca los resultados." footer={<><Button variant="secondary" onClick={()=>setSaveOpen(false)}>Cancelar</Button><Button disabled={saving||!saveName.trim()} onClick={async()=>{setSaving(true);setSaveError(null);const definition={metric_codes:selected,dimension:effectiveDimension,visualization:effectiveVisualization,date_from:applied.dateFrom,date_to:applied.dateTo,location_id:applied.locationId||null,product_id:applied.product?.id??null,customer_id:applied.customer?.id??null,supplier_id:applied.supplier?.id??null,compare_previous:true,order_by:"current_desc"};const response=await getSupabaseClient().rpc("bi_save_view",{p_company_id:companyId,p_view_id:search.get("saved_view"),p_name:saveName,p_description:saveDescription||null,p_visibility:saveVisibility,p_definition:definition,p_expected_version:search.get("view_version")?Number(search.get("view_version")):null,p_client_request_id:crypto.randomUUID()});if(response.error)setSaveError(response.error.message);else{setSaveOpen(false);router.push("/satrapy/bi/reportes");}setSaving(false);}}>{saving?<LoaderCircle className="spin" size={14}/>:<Save size={14}/>}Guardar</Button></>}>
        <div className="bi-save-form"><label><span>Nombre</span><Input value={saveName} onChange={event=>setSaveName(event.target.value)} maxLength={120}/></label><label><span>Descripción</span><Input value={saveDescription} onChange={event=>setSaveDescription(event.target.value)}/></label><label><span>Visibilidad</span><Select ariaLabel="Visibilidad de la vista" value={saveVisibility} onValueChange={value=>setSaveVisibility(value as "private"|"company")} options={[{value:"private",label:"Privada"},{value:"company",label:"Compartida con la empresa"}]}/></label>{saveError&&<p className="form-error">{saveError}</p>}</div>
      </Modal>
    </>}
  </section>;
}

function formatExplorerValue(value:number|null|undefined,metric:ExplorerMetric|undefined,currency:string|null){
  if(value==null)return"—";if(metric?.unit==="currency")return formatMoney(value,currency);
  if(metric?.unit==="percent")return`${value.toLocaleString("es-MX",{maximumFractionDigits:1})}%`;
  return value.toLocaleString("es-MX",{maximumFractionDigits:metric?.unit==="quantity"?3:0});
}

function ExplorerChart({result,metrics,visualization,dimension,onInspect}:{result:ExplorerResult;metrics:ExplorerMetric[];visualization:"line"|"bar"|"area"|"scatter";dimension:string;onInspect:(request:ExplorerDrillRequest)=>void}){
  const groups=useMemo(()=>{const map=new Map<string,{key:string;label:string;values:Record<string,ExplorerRow>}>();for(const row of result.chart){const group=map.get(row.group_key)??{key:row.group_key,label:row.group_label,values:{}};group.values[row.metric_code]=row;map.set(row.group_key,group);}return[...map.values()].sort((a,b)=>a.key.localeCompare(b.key));},[result.chart]);
  const values=result.chart.flatMap(row=>[row.current_value??0,row.previous_value??0]);const max=Math.max(...values.map(Math.abs),1);
  const width=760,height=260,pad=30;const x=(index:number)=>pad+index*Math.max(1,width-pad*2)/Math.max(groups.length-1,1);
  const minValue=Math.min(0,...values),maxValue=Math.max(1,...values),range=Math.max(maxValue-minValue,1);
  const y=(value:number)=>pad+(maxValue-value)*(height-pad*2)/range;
  if(visualization==="scatter"){const [a,b]=metrics;const points=groups.map(group=>({group,x:group.values[a.code]?.current_value??0,y:group.values[b.code]?.current_value??0}));const xmax=Math.max(...points.map(point=>Math.abs(point.x)),1),ymax=Math.max(...points.map(point=>Math.abs(point.y)),1);
    return <article className="bi-chart-card bi-explorer-chart"><header><div><span className="eyebrow">Dispersión · periodo actual</span><h2>{a.name} frente a {b.name}</h2><p>Cada punto es un grupo compartido; los ejes no mezclan importes.</p></div></header><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${a.name} frente a ${b.name}`}>
      <line x1={pad} y1={height-pad} x2={width-pad} y2={height-pad}/><line x1={pad} y1={pad} x2={pad} y2={height-pad}/>
      {points.map(point=><circle key={point.group.key} tabIndex={0} cx={pad+Math.abs(point.x)/xmax*(width-pad*2)} cy={height-pad-Math.abs(point.y)/ymax*(height-pad*2)} r="6"><title>{point.group.label}: {formatExplorerValue(point.x,a,result.currency_code)} · {formatExplorerValue(point.y,b,result.currency_code)}</title></circle>)}
    </svg></article>;
  }
  if(visualization==="bar")return <article className="bi-chart-card bi-explorer-chart"><header><div><span className="eyebrow">Barras · comparación</span><h2>{metrics.map(metric=>metric.name).join(" + ")}</h2><p>Periodo actual y anterior permanecen separados.</p></div></header><div className="bi-explorer-bars">{groups.slice(0,24).map(group=><section key={group.key}><strong>{group.label}</strong>{metrics.map((metric,index)=>{const row=group.values[metric.code];return <button type="button" key={metric.code} disabled={!metric.drilldown||!row} onClick={()=>row&&onInspect({metricCode:metric.code,dimension,groupKey:group.key,groupLabel:group.label})}><span>{metric.name}</span><i><b style={{width:`${Math.max(2,Math.abs(row?.current_value??0)/max*100)}%`,background:EXPLORER_COLORS[index]}}/></i><em>{formatExplorerValue(row?.current_value,metric,result.currency_code)}</em><small>Anterior {formatExplorerValue(row?.previous_value,metric,result.currency_code)}</small></button>;})}</section>)}</div></article>;
  const paths=metrics.map(metric=>groups.map((group,index)=>`${index?"L":"M"} ${x(index)} ${y(group.values[metric.code]?.current_value??0)}`).join(" "));
  return <article className="bi-chart-card bi-explorer-chart"><header><div><span className="eyebrow">{EXPLORER_VIZ[visualization]} · periodo actual</span><h2>{metrics.map(metric=>metric.name).join(" + ")}</h2><p>Series compatibles sobre un eje común; el periodo anterior permanece en la tabla.</p></div></header><div className="bi-chart-legend">{metrics.map((metric,index)=><span key={metric.code} style={{color:EXPLORER_COLORS[index]}}>{metric.name}</span>)}</div><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={metrics.map(metric=>metric.name).join(" y ")}>
    <line x1={pad} y1={y(0)} x2={width-pad} y2={y(0)}/>
    {paths.map((path,index)=><g key={metrics[index].code}>{visualization==="area"&&<path d={`${path} L ${x(groups.length-1)} ${y(0)} L ${x(0)} ${y(0)} Z`} fill={`${EXPLORER_COLORS[index]}18`} stroke="none"/>}<path d={path} fill="none" stroke={EXPLORER_COLORS[index]} strokeWidth="2.2"/>{groups.map((group,pointIndex)=><circle key={group.key} tabIndex={0} cx={x(pointIndex)} cy={y(group.values[metrics[index].code]?.current_value??0)} r="5" fill="white" stroke={EXPLORER_COLORS[index]} onClick={()=>{const row=group.values[metrics[index].code];if(row&&metrics[index].drilldown)onInspect({metricCode:metrics[index].code,dimension,groupKey:group.key,groupLabel:group.label});}}><title>{group.label}: {formatExplorerValue(group.values[metrics[index].code]?.current_value,metrics[index],result.currency_code)}</title></circle>)}</g>)}
  </svg></article>;
}

function ExplorerDefinition({metric,catalog,onClose}:{metric:ExplorerMetric|null;catalog:ExplorerCatalog;onClose:()=>void}){
  return <Modal open={Boolean(metric)} onOpenChange={open=>!open&&onClose()} eyebrow={metric?.module} title={metric?.name??"Definición"} description="Catálogo explícito de compatibilidad">
    {metric&&<dl className="bi-definition"><div><dt>Fórmula</dt><dd>{metric.formula}</dd></div><div><dt>Unidad</dt><dd>{metric.unit==="currency"?catalog.currency_code??"Moneda base":metric.unit}</dd></div><div><dt>Fuente canónica</dt><dd>{metric.source}</dd></div><div><dt>Granularidad</dt><dd>{metric.grain}</dd></div><div><dt>Dimensiones</dt><dd>{metric.dimensions.map(code=>catalog.dimensions.find(item=>item.code===code)?.name??code).join(", ")}</dd></div><div><dt>Criterio</dt><dd>{EXPLORER_KIND[metric.kind]}</dd></div><div><dt>Visualizaciones</dt><dd>{metric.visualizations.map(code=>EXPLORER_VIZ[code]).join(", ")}</dd></div><div><dt>Drill-down</dt><dd>{metric.drilldown?"Sí":"No"}</dd></div><div><dt>Limitaciones</dt><dd>{metric.limitations}</dd></div><div><dt>Actualización</dt><dd>{new Date(catalog.updated_at).toLocaleString("es-MX")}</dd></div></dl>}
  </Modal>;
}

function ExplorerDrilldown({companyId,request,filters,currencyCode,onClose}:{companyId:string;request:ExplorerDrillRequest|null;filters:BiFilters;currencyCode:string|null;onClose:()=>void}){
  const router=useRouter();const[data,setData]=useState<Drilldown|null>(null);const[loading,setLoading]=useState(false);const[error,setError]=useState<string|null>(null);const[page,setPage]=useState(1);
  useEffect(()=>{if(!request)return;let cancelled=false;void Promise.resolve().then(async()=>{setLoading(true);setError(null);const response=await getSupabaseClient().rpc("bi_get_explorer_drilldown",{
    p_company_id:companyId,p_metric_code:request.metricCode,p_dimension:request.dimension,p_group_key:request.groupKey,p_date_from:filters.dateFrom,p_date_to:filters.dateTo,
    p_location_id:filters.locationId||null,p_product_id:filters.product?.id??null,p_customer_id:filters.customer?.id??null,p_supplier_id:filters.supplier?.id??null,p_page:page,p_page_size:25,
  });if(cancelled)return;if(response.error)setError(response.error.message);else setData(response.data as Drilldown);setLoading(false);});return()=>{cancelled=true;};},[companyId,filters,page,request]);
  return <Modal open={Boolean(request)} onOpenChange={open=>!open&&onClose()} eyebrow="Trazabilidad" title={request?`Origen · ${request.groupLabel}`:"Operaciones"} description="Página de operaciones canónicas que sustenta el agregado." footer={data?.source_path?<Button variant="secondary" onClick={()=>router.push(data.source_path)}>Abrir módulo de origen <ChevronRight size={14}/></Button>:undefined}>
    {loading&&!data?<div className="bi-drill-state"><LoaderCircle className="spin" size={18}/>Cargando operaciones…</div>:error?<div className="bi-drill-state is-error"><AlertCircle size={18}/>{error}</div>:data?<><Table className="bi-drill-table"><thead><tr><th>Fecha</th><th>Origen</th><th>Contexto</th><th className="number-cell">Valor</th></tr></thead><tbody>{data.items.map(item=><tr key={item.id}><td>{formatSourceDate(item.occurred_at)}</td><td>{item.party??item.location_name??"Operación"}</td><td>{item.detail??"—"}</td><td className="number-cell">{formatMoney(item.amount,currencyCode)}</td></tr>)}</tbody></Table><DataPagination page={data.pagination.page} pageSize={data.pagination.page_size} total={data.pagination.total} onChange={setPage} label="operaciones"/></>:null}
  </Modal>;
}

function BiWorkspace({companyId}:{companyId:string}){
  const{accessibleLocations,appState}=useSatrapy();const router=useRouter();const[tab,setTab]=useState<"dashboards"|"views">("dashboards");
  const[views,setViews]=useState<SavedView[]>([]);const[dashboards,setDashboards]=useState<Dashboard[]>([]);const[selectedId,setSelectedId]=useState<string|null>(null);
  const[snapshot,setSnapshot]=useState<DashboardSnapshot|null>(null);const[loading,setLoading]=useState(true);const[error,setError]=useState<string|null>(null);const[notice,setNotice]=useState<string|null>(null);
  const[dialog,setDialog]=useState<"dashboard"|"widget"|null>(null);const[name,setName]=useState("");const[description,setDescription]=useState("");
  const[editingDashboard,setEditingDashboard]=useState<Dashboard|null>(null);
  const[widgetView,setWidgetView]=useState("");const[widgetType,setWidgetType]=useState<"kpi"|"chart"|"table"|"network">("chart");
  const[globalFrom,setGlobalFrom]=useState(()=>initialFilters().dateFrom);const[globalTo,setGlobalTo]=useState(()=>initialFilters().dateTo);const[globalLocation,setGlobalLocation]=useState("");
  const[exporting,setExporting]=useState<string|null>(null);
  const can=(code:string)=>Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes(code));
  const loadCatalog=useCallback(async()=>{setLoading(true);const[v,d]=await Promise.all([getSupabaseClient().rpc("bi_list_saved_views",{p_company_id:companyId,p_page:1,p_page_size:100}),getSupabaseClient().rpc("bi_list_dashboards",{p_company_id:companyId})]);if(v.error||d.error)setError(v.error?.message??d.error?.message??"No se pudo cargar BI.");else{setViews(((v.data as{items:SavedView[]}).items??[]));const next=(d.data as Dashboard[])??[];setDashboards(next);setSelectedId(current=>current&&next.some(item=>item.id===current)?current:next[0]?.id??null);}setLoading(false);},[companyId]);
  useEffect(()=>{void Promise.resolve().then(loadCatalog);},[loadCatalog]);
  const refreshDashboard=useCallback(async()=>{if(!selectedId)return;setLoading(true);const response=await getSupabaseClient().rpc("bi_get_dashboard_snapshot",{p_company_id:companyId,p_dashboard_id:selectedId,p_global_filters:{date_from:globalFrom,date_to:globalTo,location_id:globalLocation||null}});if(response.error)setError(response.error.message);else setSnapshot(response.data as DashboardSnapshot);setLoading(false);},[companyId,globalFrom,globalLocation,globalTo,selectedId]);
  useEffect(()=>{if(selectedId)void Promise.resolve().then(refreshDashboard);},[refreshDashboard,selectedId]);
  async function saveDashboard(){const response=await getSupabaseClient().rpc("bi_save_dashboard",{p_company_id:companyId,p_dashboard_id:editingDashboard?.id??null,p_name:name,p_description:description||null,p_expected_revision:editingDashboard?.revision??null});if(response.error)setError(response.error.message);else{setDialog(null);setEditingDashboard(null);setName("");setDescription("");await loadCatalog();}}
  async function addWidget(){if(!selectedId||!widgetView)return;const response=await getSupabaseClient().rpc("bi_add_dashboard_widget",{p_company_id:companyId,p_dashboard_id:selectedId,p_saved_view_id:widgetView,p_widget_type:widgetType,p_title:null,p_filter_mode:"inherit"});if(response.error)setError(response.error.message);else{setDialog(null);await loadCatalog();await refreshDashboard();}}
  async function updateLayout(widget:DashboardWidget,action:"left"|"right"|"size"|"height"|"filter"){
    if(!snapshot)return;
    const save=(current:DashboardSnapshot)=>{
      const ordered=[...current.widgets].sort((a,b)=>a.position-b.position);const index=ordered.findIndex(item=>item.id===widget.id);
      if(index<0)return null;
      if(action==="left"&&index>0)[ordered[index-1],ordered[index]]=[ordered[index],ordered[index-1]];
      if(action==="right"&&index<ordered.length-1)[ordered[index+1],ordered[index]]=[ordered[index],ordered[index+1]];
      const target=ordered.find(item=>item.id===widget.id)!;
      const updated=action==="size"?{...target,width:target.width>=4?1:target.width+1}:action==="height"?{...target,height:target.height>=3?1:target.height+1}:action==="filter"?{...target,filter_mode:target.filter_mode==="inherit"?"own":"inherit"}:target;
      return {dashboard:current.dashboard,payload:ordered.map((item,position)=>({id:item.id,position,width:item.id===updated.id?updated.width:item.width,height:item.id===updated.id?updated.height:item.height,filter_mode:item.id===updated.id?updated.filter_mode:item.filter_mode}))};
    };
    const persist=async(current:DashboardSnapshot)=>{const next=save(current);if(!next)return null;return getSupabaseClient().rpc("bi_save_dashboard_layout",{p_company_id:companyId,p_dashboard_id:next.dashboard.id,p_expected_revision:next.dashboard.revision,p_widgets:next.payload});};
    setError(null);setNotice(null);let response=await persist(snapshot);
    if(response?.error?.message.includes("El tablero cambió")){
      const latest=await getSupabaseClient().rpc("bi_get_dashboard_snapshot",{p_company_id:companyId,p_dashboard_id:snapshot.dashboard.id,p_global_filters:{date_from:globalFrom,date_to:globalTo,location_id:globalLocation||null}});
      if(latest.error){setError(latest.error.message);return;}
      const current=latest.data as DashboardSnapshot;setSnapshot(current);response=await persist(current);
      if(!response){setNotice("El componente ya no existe. El tablero se actualizó.");await loadCatalog();return;}
      if(!response.error)setNotice("El tablero se actualizó y se aplicó tu cambio.");
    }
    if(response?.error)setError(response.error.message);else{await loadCatalog();await refreshDashboard();}
  }
  async function exportTarget(targetType:"view"|"widget"|"dashboard",targetId:string,format:"csv"|"xlsx"|"pdf"){
    const key=`${targetId}:${format}`;setExporting(key);setError(null);try{const session=(await getSupabaseClient().auth.getSession()).data.session;if(!session)throw new Error("Sesión no válida.");const response=await fetch("/api/bi/export",{method:"POST",headers:{Authorization:`Bearer ${session.access_token}`,"content-type":"application/json"},body:JSON.stringify({companyId,targetType,targetId,format,filters:{date_from:globalFrom,date_to:globalTo,location_id:globalLocation||null}})});if(!response.ok){const body=await response.json().catch(()=>({}));throw new Error(body.message??"No se pudo exportar.");}const blob=await response.blob(),url=URL.createObjectURL(blob),anchor=document.createElement("a");anchor.href=url;anchor.download=response.headers.get("content-disposition")?.match(/filename="([^"]+)"/)?.[1]??`satrapy_bi.${format}`;anchor.click();URL.revokeObjectURL(url);}catch(value){setError(value instanceof Error?value.message:"No se pudo exportar.");}finally{setExporting(null);}}
  const active=dashboards.find(item=>item.id===selectedId);
  return <section className="content-frame module-page bi-module bi-workspace">
    <PageHeading eyebrow="Business Intelligence · Fase 4" title="Tableros y vistas" description="Organiza consultas validadas y genera reportes auditables sin almacenar resultados duplicados." action={<div className="bi-heading-actions">{tab==="dashboards"&&can("manage_bi_dashboards")&&<Button size="sm" onClick={()=>{setEditingDashboard(null);setName("");setDescription("");setDialog("dashboard");}}><Plus size={14}/>Nuevo tablero</Button>}</div>}/>
    <div className="bi-workspace-tabs"><button className={tab==="dashboards"?"is-active":""}onClick={()=>setTab("dashboards")}><LayoutDashboard size={15}/>Tableros</button><button className={tab==="views"?"is-active":""}onClick={()=>setTab("views")}><Save size={15}/>Vistas guardadas</button></div>
    {error&&<div className="bi-partial-state"><AlertCircle size={15}/><span><strong>No se completó la operación</strong>{error}</span></div>}
    {notice&&<div className="bi-success-state"><span>{notice}</span></div>}
    {tab==="views"?<div className="bi-saved-view-grid">{views.map(view=><article key={view.id}><header><div><Badge tone={view.visibility==="company"?"info":"neutral"}>{view.visibility==="company"?"Empresa":"Privada"}</Badge><small>v{view.current_version}</small></div><h2>{view.name}</h2><p>{view.description??"Sin descripción"}</p></header>{!view.availability.available&&<div className="bi-view-warning"><AlertCircle size={14}/>{view.availability.warnings.join(" ")}</div>}<footer><Button size="sm" variant="secondary" onClick={()=>{const d=view.definition as Record<string,unknown>;if(d.kind==="network"){const q=new URLSearchParams({from:String(d.date_from),to:String(d.date_to),saved_view:view.id,size:String(d.size_metric??"purchases"),color:String(d.color_metric??"node_type"),edge:String(d.edge_metric??"amount"),perspective:String(d.perspective??"supplier_dependency")});for(const[key,param]of Object.entries({location:"location_id",category:"category_id",supplier:"supplier_id",product:"product_id",state:"operational_state",concentration:"concentration_level"}))if(d[param])q.set(key,String(d[param]));const relation=(d.relation_types as string[]|undefined)?.[0];if(relation)q.set("relation",relation);router.push(`/satrapy/bi/red?${q}`);return;}const q=new URLSearchParams({metrics:((d.metric_codes as string[])??[]).join(","),dimension:String(d.dimension),visualization:String(d.visualization),from:String(d.date_from),to:String(d.date_to),saved_view:view.id,view_version:String(view.current_version),view_name:view.name,view_description:view.description??"",view_visibility:view.visibility});for(const key of["location_id","product_id","customer_id","supplier_id"])if(d[key])q.set(key.replace("_id",""),String(d[key]));router.push(`/satrapy/bi/explorador?${q}`);}}>Abrir</Button>{can("manage_own_bi_views")&&<Button size="sm" variant="ghost" onClick={async()=>{const response=await getSupabaseClient().rpc("bi_duplicate_view",{p_company_id:companyId,p_view_id:view.id,p_name:`Copia de ${view.name}`,p_client_request_id:crypto.randomUUID()});if(response.error)setError(response.error.message);else await loadCatalog();}}><Copy size={13}/></Button>}{view.owner_id===appState?.userId&&<Button size="sm" variant="ghost" onClick={async()=>{if(!window.confirm(`Eliminar ${view.name}?`))return;const response=await getSupabaseClient().rpc("bi_delete_view",{p_company_id:companyId,p_view_id:view.id});if(response.error)setError(response.error.message);else await loadCatalog();}}><Trash2 size={13}/></Button>}</footer></article>)}</div>:
      <div className={`bi-dashboard-shell${!dashboards.length&&!loading?" is-empty":""}`}><aside>{dashboards.map(item=><button key={item.id}className={item.id===selectedId?"is-active":""}onClick={()=>setSelectedId(item.id)}><strong>{item.name}</strong><small>{item.widget_count} componentes · revisión {item.revision}</small></button>)}</aside><main>{active?<><div className="bi-dashboard-toolbar"><div><h2>{active.name}</h2><p>{active.description??"Tablero interactivo"}</p></div><label>Desde<Input type="date"value={globalFrom}onChange={e=>setGlobalFrom(e.target.value)}/></label><label>Hasta<Input type="date"value={globalTo}onChange={e=>setGlobalTo(e.target.value)}/></label><label>Ubicación<Select ariaLabel="Ubicación global"value={globalLocation||"all"}onValueChange={value=>setGlobalLocation(value==="all"?"":value)}options={[{value:"all",label:"Todas"},...accessibleLocations.map(l=>({value:l.id,label:l.name}))]}/></label><Button size="sm"variant="secondary"onClick={()=>void refreshDashboard()}><RefreshCw size={13}/>Actualizar todo</Button>{can("manage_bi_dashboards")&&<><Button size="sm"variant="secondary"onClick={()=>{setEditingDashboard(active);setName(active.name);setDescription(active.description??"");setDialog("dashboard");}}><Save size={13}/>Renombrar</Button><Button size="sm"onClick={()=>setDialog("widget")}><Plus size={13}/>Componente</Button><Button size="sm"variant="ghost"onClick={async()=>{if(!window.confirm(`Eliminar ${active.name}?`))return;const response=await getSupabaseClient().rpc("bi_delete_dashboard",{p_company_id:companyId,p_dashboard_id:active.id});if(response.error)setError(response.error.message);else{setSnapshot(null);await loadCatalog();}}}><Trash2 size={13}/></Button></>}{can("export_bi_reports")&&<ExportButtons id={active.id}target="dashboard"exporting={exporting}onExport={exportTarget}/>}</div>{snapshot&&!snapshot.widgets.length?<div className="bi-dashboard-empty"><LayoutDashboard size={24}/><strong>Este tablero todavía está vacío</strong><p>Agrega KPI, gráficas o tablas desde una vista guardada del Explorador.</p><div>{can("manage_bi_dashboards")&&<Button size="sm"onClick={()=>setDialog("widget")}><Plus size={13}/>Agregar componente</Button>}<Button size="sm"variant="secondary"onClick={()=>router.push("/satrapy/bi/explorador")}>Ir al Explorador <ChevronRight size={13}/></Button></div></div>:<div className="bi-widget-grid">{snapshot?.widgets.map(widget=><article key={widget.id}style={{gridColumn:`span ${Math.min(widget.width,4)}`,minHeight:`${230+(widget.height-1)*90}px`}}className={`bi-dashboard-widget is-${widget.status}`}><header><div><small>{widget.widget_type} · {widget.filter_mode==="inherit"?"filtros globales":"filtros propios de la vista"}</small><h3>{widget.title??widget.view_name}</h3></div>{can("manage_bi_dashboards")&&<div className="bi-widget-controls"><button title={widget.filter_mode==="inherit"?"Usar filtros propios de la vista":"Usar filtros globales del tablero"}aria-label={widget.filter_mode==="inherit"?"Usar filtros propios de la vista":"Usar filtros globales del tablero"}onClick={()=>void updateLayout(widget,"filter")}>{widget.filter_mode==="inherit"?"Filtros: tablero":"Filtros: vista"}</button><button title="Mover a la izquierda"aria-label="Mover a la izquierda"onClick={()=>void updateLayout(widget,"left")}><ChevronLeft size={13}/></button><button title="Mover a la derecha"aria-label="Mover a la derecha"onClick={()=>void updateLayout(widget,"right")}><ChevronRight size={13}/></button><button title="Cambiar ancho"aria-label="Cambiar ancho"onClick={()=>void updateLayout(widget,"size")}>Ancho</button><button title="Cambiar alto"aria-label="Cambiar alto"onClick={()=>void updateLayout(widget,"height")}>Alto</button><button title="Eliminar componente"aria-label="Eliminar componente"onClick={async()=>{await getSupabaseClient().rpc("bi_remove_dashboard_widget",{p_company_id:companyId,p_widget_id:widget.id});await loadCatalog();await refreshDashboard();}}><X size={13}/></button></div>}</header>{widget.status==="error"?<div className="bi-widget-state"><AlertCircle size={16}/>{widget.error}</div>:<WidgetContent widget={widget}/>}<footer><button onClick={()=>{const d=widget.definition??{};const q=new URLSearchParams({metrics:String((d.metric_codes as string[]??[]).join(",")),dimension:String(d.dimension??""),visualization:String(d.visualization??""),from:String(d.date_from??globalFrom),to:String(d.date_to??globalTo)});router.push(`/satrapy/bi/explorador?${q}`);}}>Abrir en Explorador <ChevronRight size={13}/></button>{can("export_bi_reports")&&<ExportButtons id={widget.id}target="widget"exporting={exporting}onExport={exportTarget}/>}</footer></article>)}</div>}</>:!loading&&<div className="bi-dashboard-empty"><LayoutDashboard size={24}/><strong>Reúne tus indicadores en un tablero</strong><p>Organiza KPI, gráficas y tablas creados desde el Explorador y consúltalos con los mismos filtros.</p><div>{can("manage_bi_dashboards")&&<Button size="sm"onClick={()=>{setEditingDashboard(null);setName("");setDescription("");setDialog("dashboard");}}><Plus size={13}/>Crear tablero</Button>}<Button size="sm"variant="secondary"onClick={()=>router.push("/satrapy/bi/explorador")}>Ir al Explorador <ChevronRight size={13}/></Button></div></div>}</main></div>}
    <Modal open={dialog==="dashboard"}onOpenChange={open=>{if(!open){setDialog(null);setEditingDashboard(null);}}}eyebrow="Tablero" title={editingDashboard?"Editar tablero":"Crear tablero"}description={editingDashboard?"Actualiza el nombre y la descripción del tablero.":"Reúne y organiza KPI, gráficas y tablas del Explorador. Podrás agregar componentes después de crearlo."}footer={<><Button variant="secondary"onClick={()=>{setDialog(null);setEditingDashboard(null);}}>Cancelar</Button><Button disabled={!name.trim()}onClick={()=>void saveDashboard()}>{editingDashboard?"Guardar":"Crear"}</Button></>}><div className="bi-save-form"><label><span>Nombre</span><Input value={name}onChange={e=>setName(e.target.value)} placeholder="Ej. Seguimiento comercial mensual"/></label><label><span>Descripción</span><Input value={description}onChange={e=>setDescription(e.target.value)} placeholder="Indica qué decisiones apoyará este tablero"/></label></div></Modal>
    <Modal open={dialog==="widget"}onOpenChange={open=>!open&&setDialog(null)}eyebrow="Widget" title="Agregar desde una vista"description="El widget vuelve a consultar las fuentes canónicas. Las redes sólo se agregan cuando su vista está acotada."footer={<><Button variant="secondary"onClick={()=>setDialog(null)}>Cancelar</Button><Button disabled={!widgetView}onClick={()=>void addWidget()}>Agregar</Button></>}><div className="bi-save-form"><label><span>Vista guardada</span><Select ariaLabel="Vista guardada"value={widgetView||"none"}onValueChange={value=>{setWidgetView(value);const selected=views.find(v=>v.id===value);if(selected?.definition.kind==="network")setWidgetType("network");}}options={[{value:"none",label:"Selecciona una vista"},...views.filter(v=>v.availability.available).map(v=>({value:v.id,label:v.name}))]}/></label><label><span>Tipo</span><Select ariaLabel="Tipo de widget"value={widgetType}onValueChange={v=>setWidgetType(v as typeof widgetType)}options={[{value:"kpi",label:"KPI"},{value:"chart",label:"Gráfica"},{value:"table",label:"Tabla"},{value:"network",label:"Red acotada"}]}/></label></div></Modal>
  </section>;
}
function ExportButtons({id,target,exporting,onExport}:{id:string;target:"view"|"widget"|"dashboard";exporting:string|null;onExport:(target:"view"|"widget"|"dashboard",id:string,format:"csv"|"xlsx"|"pdf")=>Promise<void>}){
  return <span className="bi-export-buttons">{(["csv","xlsx","pdf"]as const).map(format=><button key={format}disabled={exporting===`${id}:${format}`}onClick={()=>void onExport(target,id,format)}>{exporting===`${id}:${format}`?<LoaderCircle className="spin"size={12}/>:<Download size={12}/>} {format.toUpperCase()}</button>)}</span>;
}
function WidgetContent({widget}:{widget:DashboardWidget}){if(widget.widget_type==="network")return<div className="bi-widget-state"><GitFork size={22}/><strong>Red de dependencias acotada</strong><span>Abre la vista para explorar, expandir y consultar evidencia sin cargar la red completa en el tablero.</span></div>;const result=widget.result;if(!result||!result.items.length)return<div className="bi-widget-state">Sin datos para los filtros.</div>;if(widget.widget_type==="kpi"){const row=result.items[0];return<div className="bi-widget-kpi"><strong>{Number(row.current_value??0).toLocaleString("es-MX",{maximumFractionDigits:2})}</strong><span>{row.group_label}</span><small>Anterior {Number(row.previous_value??0).toLocaleString("es-MX",{maximumFractionDigits:2})}</small></div>;}if(widget.widget_type==="table")return<Table><thead><tr><th>Grupo</th><th>Métrica</th><th className="number-cell">Actual</th></tr></thead><tbody>{result.items.slice(0,8).map(row=><tr key={`${row.metric_code}:${row.group_key}`}><td>{row.group_label}</td><td>{row.metric_code}</td><td className="number-cell">{Number(row.current_value??0).toLocaleString("es-MX",{maximumFractionDigits:2})}</td></tr>)}</tbody></Table>;return<DashboardChart rows={result.chart} visualization={String(widget.definition?.visualization??"bar")}/>;}

function DashboardChart({rows,visualization}:{rows:ExplorerRow[];visualization:string}){
  const chart=rows.slice(0,10),width=320,height=145,pad=18,values=chart.map(row=>Number(row.current_value??0));
  const min=Math.min(0,...values),max=Math.max(0,...values,1),range=max-min||1;
  const x=(index:number)=>chart.length<2?width/2:pad+index*((width-pad*2)/(chart.length-1));
  const y=(value:number)=>pad+(max-value)*(height-pad*2)/range;
  const baseline=y(0),mode=visualization==="area"?"area":visualization==="line"?"line":"bar";
  const points=chart.map((row,index)=>`${x(index)},${y(Number(row.current_value??0))}`).join(" ");
  return <div className={`bi-widget-chart is-${mode}`}><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${mode} de ${chart.map(row=>row.group_label).join(", ")}`}><line x1={pad} y1={baseline} x2={width-pad} y2={baseline}/>{mode==="area"&&<polygon points={`${pad},${baseline} ${points} ${width-pad},${baseline}`} />}{mode==="bar"?chart.map((row,index)=>{const value=Number(row.current_value??0),top=Math.min(y(value),baseline),barHeight=Math.max(2,Math.abs(baseline-y(value)));return <rect key={`${row.metric_code}:${row.group_key}`} x={x(index)-Math.min(18,110/chart.length)} y={top} width={Math.min(36,220/chart.length)} height={barHeight}><title>{`${row.group_label}: ${value.toLocaleString("es-MX",{maximumFractionDigits:2})}`}</title></rect>;}):<><polyline points={points}/>{chart.map((row,index)=><circle key={`${row.metric_code}:${row.group_key}`} cx={x(index)} cy={y(Number(row.current_value??0))} r="3.5"><title>{`${row.group_label}: ${Number(row.current_value??0).toLocaleString("es-MX",{maximumFractionDigits:2})}`}</title></circle>)}</>}</svg><div>{chart.map(row=><span key={`${row.metric_code}:${row.group_key}`}><b>{row.group_label}</b><em>{Number(row.current_value??0).toLocaleString("es-MX",{maximumFractionDigits:1})}</em></span>)}</div></div>;
}

function BiExecutiveSummary({ companyId }: { companyId: string }) {
  const { accessibleLocations,appState } = useSatrapy();
  const router=useRouter();
  const searchParams=useSearchParams();
  const [filters, setFilters] = useState<BiFilters>(()=>initialFilters(searchParams));
  const [applied, setApplied] = useState<BiFilters>(filters);
  const [summary, setSummary] = useState<BiSummary | null>(null);
  const [analytics,setAnalytics]=useState<BiAnalytics|null>(null);
  const [analyticsError,setAnalyticsError]=useState<string|null>(null);
  const [budgetSummary,setBudgetSummary]=useState<ExecutiveBudgetSummary|null>(null);
  const [budgetSummaryError,setBudgetSummaryError]=useState<string|null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedMetric, setSelectedMetric] = useState<DrillRequest | null>(null);
  const [definitionMetric, setDefinitionMetric] = useState<string | null>(null);
  const [activeChart,setActiveChart]=useState<BiChart["code"]>("sales");
  const [periodPreset,setPeriodPreset]=useState<ExecutivePeriodPreset>(()=>inferExecutivePeriod(filters));
  const [advancedFiltersOpen,setAdvancedFiltersOpen]=useState(false);
  const canViewBudgets=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("view_bi_budgets"));

  const load = useCallback(async (next: BiFilters) => {
    setLoading(true);setError(null);
    const args={
      p_company_id: companyId,p_date_from: next.dateFrom,p_date_to: next.dateTo,p_location_id: next.locationId || null,
      p_product_id: next.product?.id ?? null,p_customer_id: next.customer?.id ?? null,p_supplier_id: next.supplier?.id ?? null,
    };
    const budgetPromise=canViewBudgets?getSupabaseClient().rpc("bi_get_executive_budget_summary",args):Promise.resolve({data:null,error:null});
    const [summaryResult,analyticsResult,budgetResult]=await Promise.all([
      getSupabaseClient().rpc("bi_get_executive_summary",args),
      getSupabaseClient().rpc("bi_get_executive_charts",args),
      budgetPromise,
    ]);
    if (summaryResult.error) setError(summaryResult.error.message);
    else setSummary(summaryResult.data as BiSummary);
    if(analyticsResult.error){
      setAnalytics(null);
      setAnalyticsError("Las comparaciones históricas avanzadas aún no están disponibles en esta base. Se muestran los agregados confirmados de Fase 1.");
    }else{
      setAnalytics(analyticsResult.data as BiAnalytics);
      setAnalyticsError(null);
    }
    if(budgetResult.error){
      setBudgetSummary(null);
      setBudgetSummaryError("No se pudo consultar el seguimiento de metas.");
    }else{
      setBudgetSummary(budgetResult.data as ExecutiveBudgetSummary|null);
      setBudgetSummaryError(null);
    }
    setLoading(false);
  }, [canViewBudgets,companyId]);

  useEffect(() => { void Promise.resolve().then(() => load(applied)); }, [applied, load]);
  const activeFilterCount = [applied.locationId, applied.product, applied.customer, applied.supplier].filter(Boolean).length;
  const advancedFilterCount = [applied.product, applied.customer, applied.supplier].filter(Boolean).length;
  const dirty = JSON.stringify(filters) !== JSON.stringify(applied);
  const metrics=useMemo(()=>summary?.metrics.map(metric=>({...metric,...(analytics?.comparisons?.[metric.code]??{})}))??[],[analytics,summary]);
  const charts=useMemo(()=>analytics?.charts??(summary?fallbackCharts({...summary,metrics}):[]),[analytics,metrics,summary]);

  function applyFilters(next:BiFilters){
    setFilters(next);setApplied(next);
    const query=new URLSearchParams();
    query.set("from",next.dateFrom);query.set("to",next.dateTo);
    if(next.locationId)query.set("location",next.locationId);
    for(const [dimension,selection] of Object.entries({product:next.product,customer:next.customer,supplier:next.supplier})){
      if(selection){query.set(dimension,selection.id);query.set(`${dimension}_label`,selection.label);}
    }
    router.replace(`/satrapy/bi?${query.toString()}`);
  }
  function changePeriod(value:string){
    const preset=value as ExecutivePeriodPreset;setPeriodPreset(preset);
    if(preset==="custom")return;
    const range=executivePeriodRange(preset);
    setFilters(current=>({...current,...range}));
  }
  function resetFilters(){
    const next=initialFilters();setPeriodPreset("last30");setAdvancedFiltersOpen(false);applyFilters(next);
  }
  function removeAppliedFilter(key:"locationId"|"product"|"customer"|"supplier"){
    const next={...applied,[key]:key==="locationId"?"":null};applyFilters(next);setFilters(next);
  }
  function focusMetric(code:string){
    const chart=CHART_FOR_METRIC[code];if(chart)setActiveChart(chart);
  }

  return <section className="content-frame module-page bi-module">
    <PageHeading eyebrow="Business Intelligence" title="Resumen ejecutivo" description="Lectura transversal con distinción entre devengado, efectivo y operación. Cada cifra conserva fórmula, fuente y acceso al origen." action={<Button variant="secondary" size="sm" onClick={() => void load(applied)} disabled={loading}><RefreshCw size={14} /> Actualizar</Button>} />
    <section className={`bi-executive-filterbar${dirty?" has-pending":""}`} aria-label="Filtros del Resumen ejecutivo">
      <div className="bi-executive-filterbar__primary">
        <label><span>Periodo</span><Select ariaLabel="Periodo del resumen" value={periodPreset} onValueChange={changePeriod} options={EXECUTIVE_PERIOD_OPTIONS} /></label>
        <label><span>Ubicación</span><Select ariaLabel="Filtrar por ubicación" value={filters.locationId || "__all__"} onValueChange={value => setFilters(current => ({ ...current, locationId: value === "__all__" ? "" : value }))} options={[{ value: "__all__", label: "Todas las ubicaciones" }, ...accessibleLocations.filter(location => location.is_active).map(location => ({ value: location.id, label: location.name }))]} /></label>
        <Button className="bi-executive-filterbar__more" variant="secondary" size="sm" aria-expanded={advancedFiltersOpen} aria-controls="bi-executive-advanced-filters" onClick={()=>setAdvancedFiltersOpen(current=>!current)}><Plus size={14}/><span>Más filtros{advancedFilterCount>0?` · ${advancedFilterCount}`:""}</span></Button>
        <div className="bi-executive-filterbar__actions">
          {(activeFilterCount>0||dirty)&&<Button variant="ghost" size="sm" onClick={resetFilters}>Restablecer</Button>}
          <Button variant={dirty?"primary":"secondary"} size="sm" disabled={!dirty||!filters.dateFrom||!filters.dateTo} onClick={()=>applyFilters(filters)}>Aplicar cambios</Button>
        </div>
      </div>
      {periodPreset==="custom"&&<div className="bi-executive-filterbar__custom">
        <span>Periodo personalizado</span>
        <label><span>Desde</span><Input type="date" value={filters.dateFrom} max={filters.dateTo} onChange={event=>setFilters(current=>({...current,dateFrom:event.target.value}))} aria-label="Periodo desde"/></label>
        <label><span>Hasta</span><Input type="date" value={filters.dateTo} min={filters.dateFrom} max={isoDate(new Date())} onChange={event=>setFilters(current=>({...current,dateTo:event.target.value}))} aria-label="Periodo hasta"/></label>
      </div>}
      {advancedFiltersOpen&&<div id="bi-executive-advanced-filters" className="bi-executive-filterbar__advanced">
        <header><div><strong>Filtros de detalle</strong><span>Las opciones se consultan conforme escribes; no se cargan catálogos completos.</span></div><button type="button" aria-label="Cerrar filtros de detalle" onClick={()=>setAdvancedFiltersOpen(false)}><X size={15}/></button></header>
        <div>
          <BiEntityFilter companyId={companyId} dimension="product" label="Producto" value={filters.product} onChange={value=>setFilters(current=>({...current,product:value}))}/>
          <BiEntityFilter companyId={companyId} dimension="customer" label="Cliente" value={filters.customer} onChange={value=>setFilters(current=>({...current,customer:value}))}/>
          <BiEntityFilter companyId={companyId} dimension="supplier" label="Proveedor" value={filters.supplier} onChange={value=>setFilters(current=>({...current,supplier:value}))}/>
        </div>
      </div>}
      <div className="bi-executive-filterbar__applied">
        <div className="bi-executive-filterbar__context">
          <span className="bi-executive-filterbar__status" aria-live="polite">{dirty?<><i/>Cambios sin aplicar</>:<><i/>Contexto aplicado</>}</span>
          <strong>{EXECUTIVE_PERIOD_OPTIONS.find(option=>option.value===inferExecutivePeriod(applied))?.label??"Periodo personalizado"}</strong>
          <small>{formatSourceDate(applied.dateFrom)}–{formatSourceDate(applied.dateTo)}{summary?` · actualizado ${new Date(summary.updated_at).toLocaleString("es-MX")}`:""}</small>
        </div>
        <div className="bi-executive-filterbar__chips" aria-label="Filtros aplicados">
          {applied.locationId&&<button type="button" onClick={()=>removeAppliedFilter("locationId")}>Ubicación: {accessibleLocations.find(location=>location.id===applied.locationId)?.name??"Selección"}<X size={12}/></button>}
          {(["product","customer","supplier"] as const).map(key=>applied[key]&&<button type="button" key={key} onClick={()=>removeAppliedFilter(key)}>{key==="product"?"Producto":key==="customer"?"Cliente":"Proveedor"}: {applied[key]?.label}<X size={12}/></button>)}
          {!activeFilterCount&&<span>Sin dimensiones adicionales</span>}
        </div>
      </div>
    </section>
    {analyticsError&&summary&&<div className="bi-partial-state" role="status"><AlertCircle size={15}/><span><strong>Datos parciales</strong>{analyticsError}</span></div>}
    <DataState loading={loading && !summary} error={error} hasData={summary?.metrics.length ?? 0} empty="No hay métricas disponibles para este acceso." errorAction={<Button size="sm" onClick={() => void load(applied)}>Reintentar</Button>}>
      {summary && <>
        {loading && <div className="bi-refreshing"><LoaderCircle className="spin" size={14} /> Actualizando indicadores…</div>}
        <div className="bi-kpi-grid">{metrics.map(metric => <BiKpiCard key={metric.code} metric={metric} currencyCode={summary.currency_code} active={CHART_FOR_METRIC[metric.code]===activeChart} onFocus={() => focusMetric(metric.code)} onOpen={() => metric.available && setSelectedMetric({code:metric.code})} onDefinition={() => setDefinitionMetric(metric.code)} />)}</div>
        {canViewBudgets&&<ExecutiveBudgetPanel data={budgetSummary} error={budgetSummaryError} currencyCode={summary.currency_code} onOpen={()=>router.push("/satrapy/bi/metas-presupuestos")}/>}
        <div className="bi-chart-section">
          <header><div><span className="eyebrow">Análisis visual</span><h2>Actual contra periodo anterior</h2><p>Selecciona un KPI o un punto para mantener la misma trazabilidad y filtros.</p></div><div className="bi-chart-tabs" aria-label="Métricas visualizadas">{charts.map(chart=><button type="button" key={chart.code} className={activeChart===chart.code?"is-active":""} onClick={()=>setActiveChart(chart.code)}>{CHART_META[chart.code].title}</button>)}</div></header>
          <div className="bi-chart-grid">
            {charts.map(chart=><BiExecutiveChart key={chart.code} chart={chart} active={activeChart===chart.code} currencyCode={summary.currency_code} period={summary.period} updatedAt={analytics?.updated_at??summary.updated_at} onDefinition={()=>setDefinitionMetric(chart.metric_code)} onInspect={request=>setSelectedMetric(request)}/>)}
          </div>
        </div>
        <BiLocationChart locations={summary.locations} currencyCode={summary.currency_code} onInspect={() => setSelectedMetric({code:"net_sales"})} />
        <article className="bi-accrual-note"><AlertCircle size={18} /><div><strong>Devengado no es efectivo</strong><p>Ventas reconoce la operación cuando se completa; cobranza, pagos y bancos reconocen movimientos efectivos. El margen histórico aún no se publica porque la partida vendida no conserva el costo reconocido. No se sustituye con una estimación.</p></div></article>
        <div className="bi-trace"><Database size={15} /><span><strong>Trazabilidad de consulta</strong>{summary.trace.query}{analytics?` + ${analytics.trace.query}`:""} · {[...summary.trace.sources,...(analytics?.trace.sources??[])].filter((source,index,all)=>all.indexOf(source)===index).join(", ")}</span></div>
      </>}
    </DataState>
    <MetricDefinition code={definitionMetric} summary={summary} onClose={() => setDefinitionMetric(null)} />
    <BiDrilldown key={selectedMetric?`${selectedMetric.code}:${selectedMetric.dateFrom??selectedMetric.asOf??"all"}`:"closed"} companyId={companyId} request={selectedMetric} currencyCode={summary?.currency_code} filters={applied} onClose={() => setSelectedMetric(null)} />
  </section>;
}

function BiEntityFilter({ companyId, dimension, label, value, onChange }: { companyId: string; dimension: "product" | "customer" | "supplier"; label: string; value: FilterSelection; onChange: (value: FilterSelection) => void }) {
  const [query, setQuery] = useState("");
  const [options, setOptions] = useState<FilterOption[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  useEffect(() => {
    if (!open) return;
    const timer = window.setTimeout(async () => {
      setLoading(true);
      const { data } = await getSupabaseClient().rpc("bi_search_filter_options", { p_company_id: companyId, p_dimension: dimension, p_query: query || null, p_page: 1, p_page_size: 20 });
      setOptions(((data as { items?: FilterOption[] } | null)?.items ?? []));setLoading(false);
    }, 180);
    return () => window.clearTimeout(timer);
  }, [companyId, dimension, open, query]);
  return <label className="bi-entity-filter"><span>{label}</span><div onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false); }}>
    <Search size={14} />
    <input aria-label={`Filtrar por ${label.toLowerCase()}`} value={value ? value.label : query} placeholder={`Todos · buscar ${label.toLowerCase()}`} onFocus={() => setOpen(true)} onChange={event => { onChange(null);setQuery(event.target.value);setOpen(true); }} />
    {value && <button type="button" aria-label={`Quitar ${label.toLowerCase()}`} onClick={() => { onChange(null);setQuery(""); }}><X size={13} /></button>}
    {open && !value && <div className="bi-entity-filter__menu">{loading ? <span><LoaderCircle className="spin" size={14} /> Buscando…</span> : options.length ? options.map(option => <button type="button" key={option.id} onMouseDown={event => event.preventDefault()} onClick={() => { onChange(option);setQuery("");setOpen(false); }}><strong>{option.label}</strong><small>{option.secondary}</small></button>) : <span>Sin coincidencias</span>}</div>}
  </div></label>;
}

function BiKpiCard({ metric, currencyCode, active, onFocus, onOpen, onDefinition }: { metric: BiMetric; currencyCode?: string | null; active: boolean; onFocus: () => void; onOpen: () => void; onDefinition: () => void }) {
  const meta = METRICS[metric.code];if (!meta) return null;
  const delta = comparison(metric);
  return <article className={`bi-kpi ${metric.available ? "" : "is-unavailable"} ${active?"is-active":""}`}>
    <header><Badge tone={meta.kind === "Efectivo" ? "info" : meta.kind === "Devengado" ? "primary" : "neutral"}>{meta.kind}</Badge><button type="button" aria-label={`Definición de ${meta.label}`} onClick={onDefinition}><CircleHelp size={15} /></button></header>
    <button type="button" className="bi-kpi__focus" onClick={onFocus} disabled={!CHART_FOR_METRIC[metric.code]}><span>{meta.label}</span><strong>{formatMetric(metric, currencyCode)}</strong></button>
    {delta == null ? <small>{metric.available ? "Comparación no disponible" : metric.reason}</small> : <div className="bi-kpi__comparison">
      <span>Anterior <b>{formatMetric({...metric,value:metric.previous_value??null},currencyCode)}</b></span>
      <span>Diferencia <b className={delta.absolute>=0?"is-positive":"is-negative"}>{formatDifference(metric,delta.absolute,currencyCode)}</b></span>
      <small className={delta.absolute>=0?"is-positive":"is-negative"}>{delta.absolute>=0?<ArrowUpRight size={12}/>:<ArrowDownRight size={12}/>} {delta.percent==null?"Base anterior en cero":`${Math.abs(delta.percent).toLocaleString("es-MX",{maximumFractionDigits:1})}%`}</small>
    </div>}
    {(metric.code === "inventory_value" || metric.code === "gross_margin") && metric.coverage != null && <small>Cobertura de costo: {metric.coverage}%</small>}
    <button type="button" className="bi-kpi__drill" disabled={!metric.available} onClick={onOpen}>Ver operaciones <ChevronRight size={14} /></button>
  </article>;
}

function ExecutiveBudgetPanel({data,error,currencyCode,onOpen}:{data:ExecutiveBudgetSummary|null;error:string|null;currencyCode?:string|null;onOpen:()=>void}){
  if(error)return <div className="bi-partial-state" role="status"><AlertCircle size={15}/><span><strong>Seguimiento de metas no disponible</strong>{error}</span></div>;
  if(!data)return null;
  if(!data.available)return <section className="bi-budget-executive is-empty">
    <header><div><span className="eyebrow">Meta comercial</span><h2>Presupuesto contra resultado</h2></div>{data.late_count>0&&<Badge tone="warning">{data.late_count} atrasada{data.late_count===1?"":"s"}</Badge>}</header>
    <div className="bi-budget-executive__empty"><Target size={22}/><div><strong>No hay una meta única para estos filtros</strong><p>{data.reason}</p><small>{data.monitored_count} meta{data.monitored_count===1?"":"s"} independiente{data.monitored_count===1?"":"s"} activa{data.monitored_count===1?"":"s"} dentro de tu alcance.</small></div><Button size="sm" variant="secondary" onClick={onOpen}>Abrir metas y presupuestos</Button></div>
  </section>;
  const attainment=Number(data.attainment_percent??0),pace=Number(data.pace_percent??0);
  const cards=[
    {label:"Presupuesto",value:formatMoney(data.budget_value,currencyCode),note:`${data.period_start} al ${data.period_end}`},
    {label:"Resultado acumulado",value:formatMoney(data.actual_value,currencyCode),note:"Desde operaciones canónicas"},
    {label:"Cumplimiento",value:`${attainment.toLocaleString("es-MX",{maximumFractionDigits:1})}%`,note:`Ritmo esperado ${pace.toLocaleString("es-MX",{maximumFractionDigits:1})}%`},
    {label:"Pendiente",value:formatMoney(data.remaining_value,currencyCode),note:"Presupuesto − resultado"},
    {label:"Proyección al cierre",value:formatMoney(data.projection_value,currencyCode),note:data.status==="behind"?"Por debajo de la meta":"En línea con la meta"},
  ];
  return <section className={`bi-budget-executive is-${data.status}`}>
    <header><div><span className="eyebrow">Meta comercial</span><h2>{data.name}</h2><p>{data.scope_label} · seguimiento de venta neta{data.fallback_used?" · única meta visible":""}</p></div><div>{data.late_count>0&&<Badge tone="warning">{data.late_count} atrasada{data.late_count===1?"":"s"}</Badge>}<Badge tone={data.status==="behind"?"danger":"success"}>{data.status==="behind"?"Proyección bajo meta":"En línea"}</Badge><Button size="sm" variant="ghost" onClick={onOpen}>Ver detalle <ChevronRight size={13}/></Button></div></header>
    <div className="bi-budget-executive__progress" aria-label={`Cumplimiento ${attainment}%`}><span style={{width:`${Math.min(Math.max(attainment,0),100)}%`}}/><i style={{left:`${Math.min(Math.max(pace,0),100)}%`}}/></div>
    <div className="bi-budget-executive__metrics">{cards.map(card=><article key={card.label}><span>{card.label}</span><strong>{card.value}</strong><small>{card.note}</small></article>)}</div>
  </section>;
}

function MetricDefinition({ code, summary, onClose }: { code: string | null; summary: BiSummary | null; onClose: () => void }) {
  const meta = code ? METRICS[code] : null;
  return <Modal open={Boolean(code && meta)} onOpenChange={open => !open && onClose()} eyebrow={meta?.kind} title={meta?.label ?? "Definición"} description="Contrato visible del KPI">
    {meta && <dl className="bi-definition"><div><dt>Definición y fórmula</dt><dd>{meta.formula}</dd></div><div><dt>Fuente canónica</dt><dd>{meta.source}</dd></div><div><dt>Periodo</dt><dd>{summary ? `${summary.period.from} a ${summary.period.to}` : "—"}</dd></div><div><dt>Actualización</dt><dd>{summary ? new Date(summary.updated_at).toLocaleString("es-MX") : "—"}</dd></div><div><dt>Trazabilidad</dt><dd>{summary?.trace.query ?? "—"}</dd></div></dl>}
  </Modal>;
}

function BiExecutiveChart({chart,active,currencyCode,period,updatedAt,onDefinition,onInspect}:{chart:BiChart;active:boolean;currencyCode?:string|null;period:BiSummary["period"];updatedAt:string;onDefinition:()=>void;onInspect:(request:DrillRequest)=>void}){
  const [hovered,setHovered]=useState<{point:BiChartPoint;previous:boolean}|null>(null);
  const meta=METRICS[chart.metric_code];const copy=CHART_META[chart.code];
  const width=620,height=210,pad=24;
  const values=chart.points.flatMap(point=>[point.value??0,...(point.previous_value==null?[]:[point.previous_value])]);
  const minimum=Math.min(0,...values),maximum=Math.max(1,...values),range=Math.max(maximum-minimum,1);
  const x=(index:number)=>pad+(index*Math.max(1,width-pad*2))/Math.max(chart.points.length-1,1);
  const y=(value:number|null|undefined)=>pad+((maximum-(value??0))/range)*(height-pad*2);
  const path=(previous=false)=>chart.points.map((point,index)=>`${index?"L":"M"} ${x(index)} ${y(previous?point.previous_value:point.value)}`).join(" ");
  const inspect=(point:BiChartPoint,previous=false)=>{
    const date=previous?point.previous_date:point.date;
    if(!date||!chart.available)return;
    onInspect(chart.visualization==="bars"?{code:chart.metric_code,asOf:date}:{code:chart.metric_code,dateFrom:date,dateTo:date});
  };
  const tooltip=hovered?<div className="bi-chart-tooltip" role="status">
    <header><strong>{meta?.label??copy.title}</strong><span>{formatSourceDate(hovered.previous?hovered.point.previous_date??hovered.point.date:hovered.point.date)}</span></header>
    <b>{formatMoney(hovered.previous?hovered.point.previous_value:hovered.point.value,currencyCode)}</b>
    <dl><div><dt>Fórmula</dt><dd>{meta?.formula}</dd></div><div><dt>Fuente</dt><dd>{meta?.source}</dd></div><div><dt>Periodo</dt><dd>{period.from} a {period.to}</dd></div><div><dt>Actualización</dt><dd>{new Date(updatedAt).toLocaleString("es-MX")}</dd></div></dl>
  </div>:null;
  return <article className={`bi-chart-card bi-executive-chart ${active?"is-active":""} ${chart.available?"":"is-unavailable"}`}>
    <header><div><span className="eyebrow">{chart.kind} · {chart.visualization==="area"?"Área":chart.visualization==="bars"?"Barras":"Línea"}</span><h2>{copy.title}</h2><p>{copy.description}</p></div><button type="button" aria-label={`Definición de ${copy.title}`} onClick={onDefinition}><CircleHelp size={15}/></button></header>
    {!chart.available?<div className="bi-chart-unavailable"><AlertCircle size={17}/><strong>No disponible</strong><p>{chart.reason}</p></div>:chart.points.length===0?<div className="bi-chart-empty">No hay datos para los filtros seleccionados.</div>:chart.visualization==="bars"?<div className="bi-comparison-bars">
      {chart.points.map((point,index)=>{const max=Math.max(...chart.points.map(item=>Math.abs(item.value??0)),1);const previous=point.period==="previous";return <button type="button" key={`${point.date}:${index}`} onMouseEnter={()=>setHovered({point,previous:false})} onMouseLeave={()=>setHovered(null)} onFocus={()=>setHovered({point,previous:false})} onBlur={()=>setHovered(null)} onClick={()=>inspect(point)}>
        <span>{previous?"Periodo anterior":"Periodo actual"}<small>{formatSourceDate(point.date)}</small></span><i><b style={{width:`${Math.max(3,100*Math.abs(point.value??0)/max)}%`}}/></i><strong>{formatMoney(point.value,currencyCode)}</strong>
      </button>;})}
    </div>:<div className="bi-line-chart"><div className="bi-chart-legend"><span className="sales">Periodo actual</span><span className="previous">Periodo anterior</span></div><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${copy.title}, periodo actual contra anterior`}>
      <line x1={pad} y1={y(0)} x2={width-pad} y2={y(0)}/>
      {chart.visualization==="area"&&<path className="area" d={`${path(false)} L ${x(chart.points.length-1)} ${y(0)} L ${x(0)} ${y(0)} Z`}/>}
      <path className="previous" d={path(true)}/><path className="sales" d={path(false)}/>
      {chart.points.map((point,index)=><g key={`${point.date}:${index}`}>
        {point.previous_value!=null&&<circle className="previous" tabIndex={0} cx={x(index)} cy={y(point.previous_value)} r="7" onMouseEnter={()=>setHovered({point,previous:true})} onMouseLeave={()=>setHovered(null)} onFocus={()=>setHovered({point,previous:true})} onBlur={()=>setHovered(null)} onClick={()=>inspect(point,true)} onKeyDown={event=>{if(event.key==="Enter"||event.key===" "){event.preventDefault();inspect(point,true);}}}/>}
        <circle className="sales" tabIndex={0} cx={x(index)} cy={y(point.value)} r="7" onMouseEnter={()=>setHovered({point,previous:false})} onMouseLeave={()=>setHovered(null)} onFocus={()=>setHovered({point,previous:false})} onBlur={()=>setHovered(null)} onClick={()=>inspect(point)} onKeyDown={event=>{if(event.key==="Enter"||event.key===" "){event.preventDefault();inspect(point);}}}/>
      </g>)}
    </svg></div>}
    {tooltip}
  </article>;
}

function BiLocationChart({ locations, currencyCode, onInspect }: { locations: BiSummary["locations"]; currencyCode?: string | null; onInspect: () => void }) {
  const max=Math.max(...locations.map(location => location.sales),1);
  return <article className="bi-chart-card"><header><div><span className="eyebrow">Comparación</span><h2>Ventas por ubicación</h2><p>Únicamente ubicaciones autorizadas.</p></div><button onClick={onInspect}>Abrir detalle <ChevronRight size={14} /></button></header>
    <div className="bi-location-bars">{locations.length ? locations.map(location => <button type="button" key={location.location_id} onClick={onInspect} title={`${location.location_name}: ${formatMoney(location.sales,currencyCode)}`}><span>{location.location_name}</span><i><b style={{ width: `${Math.max(2,100*location.sales/max)}%` }} /></i><strong>{formatMoney(location.sales,currencyCode)}</strong><small>{location.tickets} tickets</small></button>) : <p>Sin ventas por ubicación para este periodo.</p>}</div>
  </article>;
}

function BiDrilldown({ companyId, request, currencyCode, filters, onClose }: { companyId: string; request: DrillRequest | null; currencyCode?: string | null; filters: BiFilters; onClose: () => void }) {
  const router=useRouter();const [data,setData]=useState<Drilldown|null>(null);const [loading,setLoading]=useState(false);const [error,setError]=useState<string|null>(null);const [page,setPage]=useState(1);
  useEffect(() => {
    if (!request) return;
    let cancelled=false;
    void Promise.resolve().then(async() => {
      setLoading(true);setError(null);
      const args={p_company_id:companyId,p_metric_code:request.code,p_date_from:request.dateFrom??filters.dateFrom,p_date_to:request.dateTo??filters.dateTo,p_location_id:filters.locationId||null,p_product_id:filters.product?.id??null,p_customer_id:filters.customer?.id??null,p_supplier_id:filters.supplier?.id??null,p_as_of_date:request.asOf??null,p_page:page,p_page_size:25};
      let response=await getSupabaseClient().rpc("bi_get_drilldown_v2",args);
      if(response.error&&/bi_get_drilldown_v2|schema cache|could not find/i.test(response.error.message)){
        const {p_as_of_date:_,...legacyArgs}=args;void _;
        response=await getSupabaseClient().rpc("bi_get_drilldown",legacyArgs);
      }
      if(cancelled)return;if(response.error)setError(response.error.message);else setData(response.data as Drilldown);setLoading(false);
    });
    return()=>{cancelled=true;};
  },[request,companyId,filters,page]);
  const meta=request?METRICS[request.code]:null;
  return <Modal open={Boolean(request)} onOpenChange={open => !open&&onClose()} eyebrow="Trazabilidad" title={meta ? `Origen · ${meta.label}` : "Operaciones de origen"} description={request?.asOf?`Posición reconstruida al ${formatSourceDate(request.asOf)}; detalle paginado desde las fuentes canónicas.`:"Detalle paginado desde las mismas fuentes canónicas del indicador."} footer={data?.source_path?<Button variant="secondary" onClick={() => router.push(data.source_path)}>Abrir módulo de origen <ChevronRight size={14}/></Button>:undefined}>
    {loading&&!data?<div className="bi-drill-state"><LoaderCircle className="spin" size={18}/> Cargando operaciones…</div>:error?<div className="bi-drill-state is-error"><AlertCircle size={18}/>{error}</div>:data?<><Table className="bi-drill-table"><thead><tr><th>Fecha</th><th>Origen</th><th>Contexto</th><th className="number-cell">Importe</th></tr></thead><tbody>{data.items.map(item=><tr key={item.id}><td>{formatSourceDate(item.occurred_at)}</td><td><strong>{item.party??item.location_name??"Operación"}</strong></td><td>{item.detail??item.sale_type??item.location_name??"—"}</td><td className="number-cell">{formatMoney(item.amount,currencyCode)}</td></tr>)}</tbody></Table><DataPagination page={data.pagination.page} pageSize={data.pagination.page_size} total={data.pagination.total} onChange={setPage} label="operaciones"/></>:null}
  </Modal>;
}
