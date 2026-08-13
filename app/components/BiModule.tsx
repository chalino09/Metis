"use client";

import { Activity, AlertCircle, ChevronLeft, ChevronRight, CircleHelp, Copy, Database, Download, GitFork, LayoutDashboard, LoaderCircle, Plus, RefreshCw, Save, Search, ShieldAlert, Target, Trash2, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Bar, BarChart, CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip as RechartsTooltip, XAxis, YAxis } from "recharts";
import { DataPagination, DataState, DataToolbar, PageHeading, Table } from "@/app/components/ui/data";
import { Badge, Button, Input, Modal, Select } from "@/app/components/ui/primitives";
import { AnalyticsCellBar, AnalyticsSortHeader, AnalyticsTable, AttentionItem, BiDrawer, BiFilterBar, BiState, ChartContainer, MetricCard, MetricDelta, type AnalyticsSortDirection } from "@/app/components/ui/bi";
import { getSupabaseClient } from "@/app/lib/supabase";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { BiBudgetsModule } from "@/app/components/BiBudgetsModule";
import { BiDependencyNetwork } from "@/app/components/BiDependencyNetwork";
import { neutralMetricValue, type NeutralValueState } from "@/app/lib/neutral-start";

export type BiView = "summary" | "alerts" | "explorer" | "reports" | "budgets" | "network";

type FilterOption = { id: string; label: string; secondary?: string };
type FilterSelection = FilterOption | null;
type BiFilters = {
  dateFrom: string;
  dateTo: string;
  locationId: string;
  product: FilterSelection;
  customer: FilterSelection;
  supplier: FilterSelection;
  comparisonMode: "previous_period" | "previous_year";
};
type ExecutivePeriodPreset = "today" | "last7" | "last30" | "last90" | "thisMonth" | "previousMonth" | "thisQuarter" | "custom";
type BiMetric = { code: string; value: number | null; previous_value?: number | null; available: boolean; reason?: string | null; coverage?: number | null; value_state?: NeutralValueState; comparison_available?: boolean };
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
  operational_rows?: Array<{ location_id: string; location_name: string; current_value: number; previous_value: number; share_percent: number; status: "declining" | "stable" | "new" }>;
  trace: { query: string; sources: string[]; company_id: string };
};
type BiSummary = {
  period: { from: string; to: string; previous_from: string; previous_to: string; days: number; comparison_mode?: "previous_period" | "previous_year" };
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
type BiOperationalAlert={
  id:string;condition_key:string;rule_code:string;rule_version:number;alert_type:string;metric_code:string;
  period_from:string;period_to:string;comparison_from?:string|null;comparison_to?:string|null;comparison_mode:"previous_period"|"previous_year";
  filters:Record<string,string>;dimension?:string|null;entity_id?:string|null;entity_label?:string|null;
  severity:"critical"|"warning"|"informational";observed_value?:number|null;comparison_value?:number|null;threshold_value?:number|null;
  impact_value?:number|null;impact_percent?:number|null;explanation:string;suggested_action:string;evidence:Record<string,unknown>;
  status:"active"|"reviewed"|"resolved";first_detected_at:string;last_detected_at:string;reviewed_at?:string|null;resolved_at?:string|null;resolution_reason?:string|null;
};
type MissingCostProduct={product_id:string;product_code:string;product_name:string;item_count:number;quantity:number;net_sales:number;first_sale_date:string;last_sale_date:string;current_cost?:number|null;currency_code?:string|null;period_scope:"current"|"comparison";period_from:string;period_to:string};
type Drilldown = {
  items: Array<{ id: string; occurred_at: string; party?: string; location_name?: string; detail?: string; sale_type?: string; amount?: number }>;
  pagination: { page: number; page_size: number; total: number };
  source_path: string;
  metric_code: string;
  as_of?: string;
};
type DrillRequest = { code: string; dateFrom?: string; dateTo?: string; asOf?: string; locationId?: string };
type InvestigationDimension = "location" | "category" | "product" | "customer" | "supplier";
type InvestigationCrumb = { dimension: InvestigationDimension; id: string; label: string };
export type BiInvestigationContext = {
  metricCode: string;
  dateFrom: string;
  dateTo: string;
  comparison: "previous_period" | "previous_year";
  filters: { locationId: string; productId: string; categoryId: string; customerId: string; supplierId: string };
  activeDimension: InvestigationDimension | null;
  path: InvestigationCrumb[];
  level: number;
  asOf?: string;
};
type InvestigationFactor = { group_key:string;group_label:string;current_value:number;previous_value:number;change_value:number;change_percent:number|null;current_share_percent:number|null;contribution_percent:number|null;status:"improved"|"deteriorated"|"stable" };
type InvestigationData = { metric:{code:string;name:string;formula:string;source:string;kind:string;limitations:string};period:BiSummary["period"];currency_code:string|null;dimension:InvestigationDimension;summary:{current_value:number;previous_value:number;change_value:number;change_percent:number|null};factors:InvestigationFactor[];chart:InvestigationFactor[];pagination:{page:number;page_size:number;total:number};reconciliation:{all_factors_change:number;total_change:number;visible_page_change:number;remaining_change:number;reconciled:boolean;note:string};trace:{query:string;sources:string;formula:string;server_side:boolean} };
type OperationalDimension = "location" | "category" | "product";
type OperationalSort = "negative_impact" | "positive_contribution" | "current_value" | "previous_value" | "change_value" | "change_percent" | "share_percent" | "contribution_percent" | "entity";
type OperationalRow = {
  group_key:string;group_label:string;ranking:number;current_value:number|null;previous_value:number|null;
  change_value:number|null;change_percent:number|null;share_percent:number|null;contribution_percent:number|null;
  status:"improved"|"deteriorated"|"neutral"|"partial"|"unavailable"|"no_comparison";
  comparison_state:"comparable"|"previous_zero"|"no_comparison"|"partial";available:boolean;reason?:string|null;
};
type OperationalResult = {
  metric:{code:string;name:string;unit:ExplorerMetric["unit"];formula:string;source:string;limitations:string};dimension:OperationalDimension;
  period:BiSummary["period"];currency_code:string|null;updated_at:string;items:OperationalRow[];
  pagination:{page:number;page_size:number;total:number};scope:{total_groups:number;partial_groups:number;current_total:number;previous_total:number;change_total:number};
  query:{search:string|null;sort_by:OperationalSort;sort_direction:AnalyticsSortDirection};partial:boolean;
  trace:{query:string;server_side:boolean;source:string;formula:string};
};
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

const INVESTIGATION_DIMENSIONS: Partial<Record<string, InvestigationDimension[]>> = {
  net_sales: ["location", "category", "product", "customer"],
  tickets: ["location", "customer"],
  gross_margin: ["location", "category", "product"],
  collections: ["customer"],
  supplier_payments: ["supplier"],
  receivables: ["location", "customer"],
  payables: ["supplier"],
  inventory_value: ["location", "category", "product"],
};
const INVESTIGATION_LABEL: Record<InvestigationDimension, string> = { location:"Sucursal",category:"Categoría",product:"Producto",customer:"Cliente",supplier:"Proveedor" };
const OPERATIONAL_DIMENSION_LABEL:Record<OperationalDimension,string>={location:"Sucursales",category:"Categorías",product:"Productos"};
const OPERATIONAL_METRICS:Record<OperationalDimension,string[]>={location:["net_sales","gross_margin","tickets"],category:["net_sales","gross_margin"],product:["net_sales","gross_margin"]};
const OPERATIONAL_PRIORITY=[
  {value:"negative_impact",label:"Atención",description:"Impacto negativo primero"},
  {value:"positive_contribution",label:"Oportunidad",description:"Contribución positiva primero"},
  {value:"share_percent",label:"Participación",description:"Mayor participación primero"},
] satisfies Array<{value:OperationalSort;label:string;description:string}>;

function nextInvestigationDimension(metricCode:string, dimension:InvestigationDimension):InvestigationDimension|null {
  const dimensions=INVESTIGATION_DIMENSIONS[metricCode]??[];
  if(metricCode==="net_sales"&&dimension==="location")return "category";
  if(metricCode==="net_sales"&&dimension==="category")return "product";
  if(metricCode==="net_sales"&&dimension==="product")return null;
  const index=dimensions.indexOf(dimension);
  return index>=0&&index+1<dimensions.length?dimensions[index+1]:null;
}

function createInvestigationContext(request:DrillRequest, filters:BiFilters):BiInvestigationContext {
  const metricCode=request.code;
  const inherited={locationId:request.locationId??filters.locationId,productId:filters.product?.id??"",categoryId:"",customerId:filters.customer?.id??"",supplierId:filters.supplier?.id??""};
  const path:InvestigationCrumb[]=request.locationId?[{dimension:"location",id:request.locationId,label:"Sucursal seleccionada"}]:[];
  const activeDimension=request.locationId?nextInvestigationDimension(metricCode,"location"):(INVESTIGATION_DIMENSIONS[metricCode]?.[0]??null);
  return {metricCode,dateFrom:request.dateFrom??filters.dateFrom,dateTo:request.dateTo??filters.dateTo,comparison:filters.comparisonMode,filters:inherited,activeDimension,path,level:path.length,asOf:request.asOf};
}
function createOperationalInvestigationContext(metricCode:string,dimension:OperationalDimension,row:OperationalRow,filters:BiFilters):BiInvestigationContext {
  const context=createInvestigationContext({code:metricCode},filters);
  const inherited={...context.filters};
  if(dimension==="location")inherited.locationId=row.group_key;
  if(dimension==="category"&&row.group_key!=="uncategorized")inherited.categoryId=row.group_key;
  if(dimension==="product")inherited.productId=row.group_key;
  return {...context,filters:inherited,path:[{dimension,id:row.group_key,label:row.group_label}],
    activeDimension:row.group_key==="uncategorized"?null:nextInvestigationDimension(metricCode,dimension),level:1};
}

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
  return { dateFrom, dateTo, locationId: search?.get("location") ?? "", product:selected("product"), customer:selected("customer"), supplier:selected("supplier"), comparisonMode:search?.get("comparison")==="previous_year"?"previous_year":"previous_period" };
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
  const neutralValue = neutralMetricValue(metric.value_state, meta?.format === "integer" ? "integer" : meta?.format === "percent" ? "percent" : "currency");
  if (neutralValue) return neutralValue;
  if (!metric.available || metric.value == null) return "No disponible";
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
const COMPARISON_OPTIONS=[
  {value:"previous_period",label:"Periodo anterior"},
  {value:"previous_year",label:"Mismo periodo del año pasado"},
];
function comparisonLabel(mode:"previous_period"|"previous_year"){return mode==="previous_year"?"Mismo periodo del año pasado":"Periodo anterior equivalente";}

function alertInvestigationContext(alert:BiOperationalAlert):BiInvestigationContext{
  const filters={locationId:"",productId:"",categoryId:"",customerId:"",supplierId:""};
  const path:InvestigationCrumb[]=[];
  if(alert.dimension&&alert.entity_id&&["location","category","product","customer","supplier"].includes(alert.dimension)){
    const dimension=alert.dimension as InvestigationDimension;filters[`${dimension}Id` as keyof typeof filters]=alert.entity_id;
    path.push({dimension,id:alert.entity_id,label:alert.entity_label??"Entidad afectada"});
  }
  // Una alerta de cobertura de margen no tiene un agregado confiable que
  // descomponer: abre directamente las partidas de respaldo.
  const activeDimension=alert.rule_code==="gross_margin_unreliable"?null:
    path.length?nextInvestigationDimension(alert.metric_code,path[0].dimension):(INVESTIGATION_DIMENSIONS[alert.metric_code]?.[0]??null);
  return{metricCode:alert.metric_code,dateFrom:alert.period_from,dateTo:alert.period_to,comparison:alert.comparison_mode,filters,activeDimension,path,level:path.length};
}

function alertSeverity(alert:BiOperationalAlert){
  if(alert.severity==="critical")return{label:"Crítica",tone:"danger" as const,icon:AlertCircle};
  if(alert.severity==="warning")return{label:"Advertencia",tone:"warning" as const,icon:ShieldAlert};
  return{label:"Informativa",tone:"neutral" as const,icon:AlertCircle};
}

function BiAlertsModule({companyId}:{companyId:string}){
  const{appState,accessibleLocations}=useSatrapy();
  const canManage=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("manage_bi_alerts"));
  const[status,setStatus]=useState("active");const[severity,setSeverity]=useState("all");const[metric,setMetric]=useState("all");const[location,setLocation]=useState("all");
  const[searchDraft,setSearchDraft]=useState("");const[search,setSearch]=useState("");const[page,setPage]=useState(1);const[items,setItems]=useState<BiOperationalAlert[]>([]);
  const[total,setTotal]=useState(0);const[loading,setLoading]=useState(true);const[error,setError]=useState<string|null>(null);const[selected,setSelected]=useState<BiOperationalAlert|null>(null);
  const[resolveAlert,setResolveAlert]=useState<BiOperationalAlert|null>(null);const[reason,setReason]=useState("");const[saving,setSaving]=useState(false);
  useEffect(()=>{const timer=window.setTimeout(()=>{setSearch(searchDraft.trim());setPage(1);},320);return()=>window.clearTimeout(timer);},[searchDraft]);
  const load=useCallback(async()=>{setLoading(true);setError(null);const response=await getSupabaseClient().rpc("bi_list_alerts",{p_company_id:companyId,p_status:status==="all"?null:status,p_severity:severity==="all"?null:severity,p_metric_code:metric==="all"?null:metric,p_location_id:location==="all"?null:location,p_date_from:null,p_date_to:null,p_search:search||null,p_page:page,p_page_size:25});
    if(response.error)setError(response.error.message);else{const result=response.data as{items:BiOperationalAlert[];pagination:{total:number}};setItems(result.items);setTotal(result.pagination.total);}setLoading(false);},[companyId,location,metric,page,search,severity,status]);
  useEffect(()=>{void Promise.resolve().then(load);},[load]);
  async function transition(alert:BiOperationalAlert,action:"review"|"resolve",resolutionReason?:string){setSaving(true);setError(null);const response=await getSupabaseClient().rpc("bi_transition_alert",{p_company_id:companyId,p_alert_id:alert.id,p_action:action,p_reason:resolutionReason??null});
    if(response.error)setError(response.error.message);else{setResolveAlert(null);setReason("");await load();}setSaving(false);}
  return<section className="content-frame module-page bi-module bi-alerts-page">
    <PageHeading eyebrow="Business Intelligence" title="Alertas operativas" description="Condiciones deterministas priorizadas por severidad e impacto. Cada alerta conserva regla, periodo y evidencia." action={<Button variant="secondary" size="sm" onClick={()=>void load()} disabled={loading}><RefreshCw size={14}/>Actualizar</Button>}/>
    <div className="bi-alerts-filters" aria-label="Filtros de alertas">
      <label><span>Estado</span><Select ariaLabel="Estado de alerta" value={status} onValueChange={value=>{setStatus(value);setPage(1);}} options={[{value:"active",label:"Activas"},{value:"reviewed",label:"Revisadas"},{value:"resolved",label:"Resueltas"},{value:"all",label:"Todas"}]}/></label>
      <label><span>Severidad</span><Select ariaLabel="Severidad de alerta" value={severity} onValueChange={value=>{setSeverity(value);setPage(1);}} options={[{value:"all",label:"Todas"},{value:"critical",label:"Crítica"},{value:"warning",label:"Advertencia"},{value:"informational",label:"Informativa"}]}/></label>
      <label><span>Métrica</span><Select ariaLabel="Métrica de alerta" value={metric} onValueChange={value=>{setMetric(value);setPage(1);}} options={[{value:"all",label:"Todas"},{value:"net_sales",label:"Ventas netas"},{value:"gross_margin",label:"Margen bruto"}]}/></label>
      <label><span>Ubicación</span><Select ariaLabel="Ubicación de alerta" value={location} onValueChange={value=>{setLocation(value);setPage(1);}} options={[{value:"all",label:"Todas"},...accessibleLocations.map(item=>({value:item.id,label:item.name}))]}/></label>
    </div>
    <DataToolbar search={searchDraft} onSearchChange={setSearchDraft} placeholder="Buscar alerta o entidad" activeFilters={[severity,metric,location].filter(value=>value!=="all").length} onClear={()=>{setSeverity("all");setMetric("all");setLocation("all");setSearchDraft("");setSearch("");setPage(1);}} results={total}/>
    {loading&&!items.length?<BiState kind="loading" title="Consultando alertas…" description="La prioridad y la página se calculan en servidor."/>:error&&!items.length?<BiState kind="error" title="No se pudieron cargar las alertas" description={error} action={<Button size="sm" onClick={()=>void load()}>Reintentar</Button>}/>:!items.length?<BiState kind="empty" title="No hay alertas en esta vista" description="Las evaluaciones programadas no encontraron condiciones con estos filtros."/>:<>
      {error&&<BiState kind="partial" compact title="No se pudo actualizar" description={`${error} Se conserva la última página confirmada.`}/>}<AnalyticsTable caption="Alertas operativas" ariaLabel="Alertas operativas ordenadas por prioridad" busy={loading} className="bi-alerts-table"><thead><tr><th>Prioridad</th><th>Alerta</th><th>Métrica</th><th>Impacto</th><th>Periodo</th><th>Actualizada</th><th>Estado</th><th><span className="sr-only">Acciones</span></th></tr></thead><tbody>{items.map(alert=>{const visual=alertSeverity(alert);const Icon=visual.icon;return<tr key={alert.id}><td><Badge tone={visual.tone}><Icon size={12} aria-hidden="true"/>{visual.label}</Badge></td><td><strong>{alert.entity_label??alert.explanation}</strong>{alert.entity_label&&<small>{alert.explanation}</small>}</td><td>{METRICS[alert.metric_code]?.label??alert.metric_code}</td><td className="number-cell">{alert.impact_percent!=null?`${alert.impact_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`:alert.impact_value!=null?formatMoney(alert.impact_value):"Cobertura incompleta"}</td><td>{formatSourceDate(alert.period_from)}–{formatSourceDate(alert.period_to)}</td><td>{new Date(alert.last_detected_at).toLocaleString("es-MX")}</td><td><Badge tone={alert.status==="resolved"?"success":alert.status==="reviewed"?"info":"neutral"}>{alert.status==="active"?"Activa":alert.status==="reviewed"?"Revisada":"Cerrada"}</Badge></td><td><div className="bi-alert-row-actions"><Button size="sm" variant="ghost" onClick={()=>setSelected(alert)}>Revisar <ChevronRight size={13}/></Button>{canManage&&alert.status==="active"&&<Button size="sm" variant="secondary" disabled={saving} onClick={()=>void transition(alert,"review")}>Marcar revisada</Button>}{canManage&&alert.status!=="resolved"&&<Button size="sm" variant="ghost" onClick={()=>setResolveAlert(alert)}>Cerrar como excepción</Button>}</div></td></tr>;})}</tbody></AnalyticsTable><DataPagination page={page} pageSize={25} total={total} onChange={setPage} label="alertas"/></>}
    <BiAlertDetail alert={selected} companyId={companyId} canManage={canManage} onClose={()=>setSelected(null)} onCorrected={async()=>{setSelected(null);await load();}} onReview={async alert=>{await transition(alert,"review");setSelected(current=>current?{...current,status:"reviewed"}:current);}} onResolve={alert=>setResolveAlert(alert)}/>
    <Modal open={Boolean(resolveAlert)} onOpenChange={open=>{if(!open&&!saving){setResolveAlert(null);setReason("");}}} eyebrow="Excepción manual" title="Cerrar como excepción" description="Esto oculta la alerta, pero no corrige los datos que la originaron. Úsalo sólo cuando la condición se acepte o no pueda corregirse; el motivo quedará auditado." footer={<><Button disabled={saving} onClick={()=>{setResolveAlert(null);setReason("");}}>Cancelar</Button><Button variant="primary" loading={saving} disabled={reason.trim().length<5} onClick={()=>resolveAlert&&void transition(resolveAlert,"resolve",reason)}>Cerrar como excepción</Button></>}><label className="bi-alert-resolution"><span>Justificación</span><Input value={reason} onChange={event=>setReason(event.target.value)} placeholder="Ej. Periodo histórico sin costo recuperable" aria-label="Justificación de la excepción"/></label></Modal>
  </section>;
}

function BiAlertDetail({alert,companyId,canManage,onClose,onCorrected,onReview,onResolve}:{alert:BiOperationalAlert|null;companyId:string;canManage:boolean;onClose:()=>void;onCorrected:()=>Promise<void>;onReview:(alert:BiOperationalAlert)=>Promise<void>;onResolve:(alert:BiOperationalAlert)=>void}){
  const[history,setHistory]=useState<Array<{id:string;event_type:string;actor_name?:string|null;reason?:string|null;created_at:string}>>([]);const[showEvidence,setShowEvidence]=useState(false);
  useEffect(()=>{if(!alert)return;void getSupabaseClient().rpc("bi_get_alert_history",{p_company_id:companyId,p_alert_id:alert.id,p_page:1,p_page_size:10}).then(response=>{if(!response.error)setHistory((response.data as{items:typeof history}).items);});},[alert,companyId]);
  if(!alert)return null;const visual=alertSeverity(alert);const context=alertInvestigationContext(alert);
  return<><BiDrawer open={!showEvidence} onOpenChange={open=>!open&&onClose()} eyebrow="Alerta operativa" title={alert.entity_label??(METRICS[alert.metric_code]?.label??alert.metric_code)} description={alert.explanation} footer={<>{canManage&&alert.status==="active"&&<Button variant="secondary" onClick={()=>void onReview(alert)}>Marcar revisada</Button>}{canManage&&alert.status!=="resolved"&&<Button variant="secondary" onClick={()=>onResolve(alert)}>Cerrar como excepción</Button>}<Button variant="primary" onClick={()=>setShowEvidence(true)}>Ver evidencia <ChevronRight size={14}/></Button></>}>
    <div className="bi-alert-detail"><div className="bi-alert-detail__meta"><Badge tone={visual.tone}>{visual.label}</Badge><Badge tone="neutral">{alert.status==="active"?"Activa":alert.status==="reviewed"?"Revisada":"Cerrada"}</Badge></div><dl><div><dt>Métrica</dt><dd>{METRICS[alert.metric_code]?.label??alert.metric_code}</dd></div><div><dt>Valor observado</dt><dd>{alert.observed_value==null?"No disponible":formatMoney(alert.observed_value)}</dd></div><div><dt>Comparación o umbral</dt><dd>{alert.comparison_value!=null?formatMoney(alert.comparison_value):alert.threshold_value!=null?alert.threshold_value.toLocaleString("es-MX"):"Cobertura completa requerida"}</dd></div><div><dt>Impacto</dt><dd>{alert.impact_percent!=null?`${alert.impact_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`:alert.impact_value!=null?formatMoney(alert.impact_value):"Confianza limitada"}</dd></div><div><dt>Periodo evaluado</dt><dd>{formatSourceDate(alert.period_from)}–{formatSourceDate(alert.period_to)}</dd></div><div><dt>Última evaluación</dt><dd>{new Date(alert.last_detected_at).toLocaleString("es-MX")}</dd></div></dl><section><span className="eyebrow">Regla determinista</span><strong>{alert.rule_code} · versión {alert.rule_version}</strong><p>{alert.suggested_action}</p></section>{alert.rule_code==="gross_margin_unreliable"&&alert.status!=="resolved"&&<MissingCostRemediation alert={alert} companyId={companyId} onCorrected={onCorrected}/>}<section><span className="eyebrow">Historial</span>{history.length?<ul>{history.map(event=><li key={event.id}><strong>{event.event_type==="detected"?"Detectada":event.event_type==="updated"?"Actualizada":event.event_type==="reviewed"?"Revisada":"Cerrada"}</strong><span>{new Date(event.created_at).toLocaleString("es-MX")}{event.actor_name?` · ${event.actor_name}`:" · Evaluación automática"}</span>{event.reason&&<small>{event.reason}</small>}</li>)}</ul>:<p>Sin cambios adicionales.</p>}</section></div>
  </BiDrawer>{showEvidence&&<BiDrilldown companyId={companyId} context={context} currencyCode={null} onClose={()=>setShowEvidence(false)}/>}</>;
}

function MissingCostRemediation({alert,companyId,onCorrected}:{alert:BiOperationalAlert;companyId:string;onCorrected:()=>Promise<void>}){
  const{appState}=useSatrapy();const canCorrect=Boolean(appState?.membership.permissions.includes("*")||(appState?.membership.permissions.includes("import_costs")&&appState?.membership.permissions.includes("manage_bi_alerts")));
  const[items,setItems]=useState<MissingCostProduct[]>([]);const[loading,setLoading]=useState(true);const[error,setError]=useState<string|null>(null);const[target,setTarget]=useState<MissingCostProduct|null>(null);const[amount,setAmount]=useState("");const[reason,setReason]=useState("");const[saving,setSaving]=useState(false);
  useEffect(()=>{let cancelled=false;const periods=[{scope:"current" as const,from:alert.period_from,to:alert.period_to},...(alert.comparison_from&&alert.comparison_to?[{scope:"comparison" as const,from:alert.comparison_from,to:alert.comparison_to}]:[])];void Promise.all(periods.map(async period=>{const response=await getSupabaseClient().rpc("bi_list_missing_cost_products",{p_company_id:companyId,p_date_from:period.from,p_date_to:period.to,p_page:1,p_page_size:25});if(response.error)throw response.error;return(response.data as{items:Omit<MissingCostProduct,"period_scope"|"period_from"|"period_to">[]}).items.map(item=>({...item,period_scope:period.scope,period_from:period.from,period_to:period.to}));})).then(groups=>{if(!cancelled)setItems(groups.flat());}).catch(cause=>{if(!cancelled)setError(cause instanceof Error?cause.message:"No fue posible consultar las partidas sin costo.");}).finally(()=>{if(!cancelled)setLoading(false);});return()=>{cancelled=true;};},[alert.comparison_from,alert.comparison_to,alert.period_from,alert.period_to,companyId]);
  async function apply(){if(!target)return;setSaving(true);setError(null);const response=await getSupabaseClient().rpc("bi_apply_missing_sale_cost",{p_company_id:companyId,p_product_id:target.product_id,p_date_from:target.period_from,p_date_to:target.period_to,p_unit_cost:Number(amount.replace(",",".")),p_reason:reason.trim(),p_comparison_mode:alert.comparison_mode,p_evaluation_from:alert.period_from,p_evaluation_to:alert.period_to});if(response.error){setError(response.error.message);setSaving(false);return;}setTarget(null);setAmount("");setReason("");setSaving(false);await onCorrected();}
  return<section className="bi-alert-remediation"><header><span className="eyebrow">Acción correctiva</span><strong>Completar costo reconocido</strong><p>Corrige únicamente partidas sin costo del periodo actual o comparable. Al guardar, Satrapy vuelve a evaluar la alerta.</p></header>{loading?<span role="status">Buscando productos afectados…</span>:error?<BiState kind="partial" compact title="Corrección no disponible" description={error}/>:items.length?<div className="bi-alert-remediation__list">{items.map(item=><article key={`${item.period_scope}-${item.product_id}`}><div className="bi-alert-remediation__product"><strong>{item.product_name}</strong><div className="bi-alert-remediation__meta"><span>{item.period_scope==="current"?"Periodo actual":"Periodo comparable"}</span><span>{formatSourceDate(item.period_from)}–{formatSourceDate(item.period_to)}</span></div><div className="bi-alert-remediation__facts"><span><b>Código</b>{item.product_code}</span><span><b>Partidas</b>{item.item_count.toLocaleString("es-MX")}</span><span><b>Unidades</b>{item.quantity.toLocaleString("es-MX")}</span><span><b>Ventas afectadas</b>{formatMoney(item.net_sales,item.currency_code)}</span></div></div><div className="bi-alert-remediation__action">{canCorrect?<Button size="sm" variant="secondary" onClick={()=>{setTarget(item);setAmount(item.current_cost?.toString()??"");}}>Corregir costo</Button>:<Badge tone="neutral">Sin permiso para corregir</Badge>}</div></article>)}</div>:<BiState kind="empty" compact title="Sin partidas pendientes" description="La próxima evaluación cerrará la alerta automáticamente."/>}<Modal open={Boolean(target)} onOpenChange={open=>{if(!open&&!saving){setTarget(null);setAmount("");setReason("");}}} eyebrow="Corrección histórica" title={target?.product_name??"Completar costo"} description={target?`Aplicará el costo sólo a partidas sin costo entre ${formatSourceDate(target.period_from)} y ${formatSourceDate(target.period_to)}. No modifica ventas, cantidades, costos vigentes ni partidas ya valorizadas.`:""} footer={<><Button disabled={saving} onClick={()=>setTarget(null)}>Cancelar</Button><Button variant="primary" loading={saving} disabled={!(Number(amount.replace(",","."))>0)||reason.trim().length<10} onClick={()=>void apply()}>Aplicar y reevaluar</Button></>}><div className="bi-alert-remediation__form"><label><span>Costo unitario reconocido</span><Input inputMode="decimal" value={amount} onChange={event=>setAmount(event.target.value)} aria-label="Costo unitario reconocido"/></label><label><span>Justificación</span><Input maxLength={240} value={reason} onChange={event=>setReason(event.target.value)} placeholder="Ej. Costo validado contra recepción y factura" aria-label="Justificación de la corrección"/></label>{target?.current_cost!=null&&<small>Costo vigente de referencia: {formatMoney(target.current_cost,target.currency_code)}. Confirma que también corresponde al periodo histórico.</small>}</div></Modal></section>;
}

export function BiModule({ companyId, view }: { companyId: string; view: BiView }) {
  if(view==="alerts")return <BiAlertsModule companyId={companyId}/>;
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
    <PageHeading eyebrow="Business Intelligence" title="Análisis comparativo" description="Compara métricas compatibles por periodo y dimensión. Los resultados se calculan y paginan en servidor." action={<div className="bi-heading-actions"><Button variant="secondary" size="sm" onClick={()=>void load(page)} disabled={loading}><RefreshCw size={14}/>Actualizar</Button>{canSaveViews&&<Button size="sm" onClick={()=>setSaveOpen(true)} disabled={!result}><Save size={14}/>Guardar vista</Button>}</div>}/>
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
      <div className="bi-filters" aria-label="Filtros del análisis">
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
    <PageHeading eyebrow="Business Intelligence" title="Vistas y reportes" description="Organiza análisis guardados, crea tableros y genera reportes auditables." action={<div className="bi-heading-actions">{tab==="dashboards"&&can("manage_bi_dashboards")&&<Button size="sm" onClick={()=>{setEditingDashboard(null);setName("");setDescription("");setDialog("dashboard");}}><Plus size={14}/>Nuevo tablero</Button>}</div>}/>
    <div className="bi-workspace-tabs"><button className={tab==="dashboards"?"is-active":""}onClick={()=>setTab("dashboards")}><LayoutDashboard size={15}/>Tableros</button><button className={tab==="views"?"is-active":""}onClick={()=>setTab("views")}><Save size={15}/>Vistas guardadas</button></div>
    {error&&<div className="bi-partial-state"><AlertCircle size={15}/><span><strong>No se completó la operación</strong>{error}</span></div>}
    {notice&&<div className="bi-success-state"><span>{notice}</span></div>}
    {tab==="views"?<div className="bi-saved-view-grid">{views.map(view=><article key={view.id}><header><div><Badge tone={view.visibility==="company"?"info":"neutral"}>{view.visibility==="company"?"Empresa":"Privada"}</Badge><small>v{view.current_version}</small></div><h2>{view.name}</h2><p>{view.description??"Sin descripción"}</p></header>{!view.availability.available&&<div className="bi-view-warning"><AlertCircle size={14}/>{view.availability.warnings.join(" ")}</div>}<footer><Button size="sm" variant="secondary" onClick={()=>{const d=view.definition as Record<string,unknown>;if(d.kind==="network"){const q=new URLSearchParams({from:String(d.date_from),to:String(d.date_to),saved_view:view.id,size:String(d.size_metric??"purchases"),color:String(d.color_metric??"node_type"),edge:String(d.edge_metric??"amount"),perspective:String(d.perspective??"supplier_dependency")});for(const[key,param]of Object.entries({location:"location_id",category:"category_id",supplier:"supplier_id",product:"product_id",state:"operational_state",concentration:"concentration_level"}))if(d[param])q.set(key,String(d[param]));const relation=(d.relation_types as string[]|undefined)?.[0];if(relation)q.set("relation",relation);router.push(`/satrapy/bi/red?${q}`);return;}const q=new URLSearchParams({metrics:((d.metric_codes as string[])??[]).join(","),dimension:String(d.dimension),visualization:String(d.visualization),from:String(d.date_from),to:String(d.date_to),saved_view:view.id,view_version:String(view.current_version),view_name:view.name,view_description:view.description??"",view_visibility:view.visibility});for(const key of["location_id","product_id","customer_id","supplier_id"])if(d[key])q.set(key.replace("_id",""),String(d[key]));router.push(`/satrapy/bi/explorador?${q}`);}}>Abrir</Button>{can("manage_own_bi_views")&&<Button size="sm" variant="ghost" onClick={async()=>{const response=await getSupabaseClient().rpc("bi_duplicate_view",{p_company_id:companyId,p_view_id:view.id,p_name:`Copia de ${view.name}`,p_client_request_id:crypto.randomUUID()});if(response.error)setError(response.error.message);else await loadCatalog();}}><Copy size={13}/></Button>}{view.owner_id===appState?.userId&&<Button size="sm" variant="ghost" onClick={async()=>{if(!window.confirm(`Eliminar ${view.name}?`))return;const response=await getSupabaseClient().rpc("bi_delete_view",{p_company_id:companyId,p_view_id:view.id});if(response.error)setError(response.error.message);else await loadCatalog();}}><Trash2 size={13}/></Button>}</footer></article>)}</div>:
      <div className={`bi-dashboard-shell${!dashboards.length&&!loading?" is-empty":""}`}><aside>{dashboards.map(item=><button key={item.id}className={item.id===selectedId?"is-active":""}onClick={()=>setSelectedId(item.id)}><strong>{item.name}</strong><small>{item.widget_count} componentes · revisión {item.revision}</small></button>)}</aside><main>{active?<><div className="bi-dashboard-toolbar"><div><h2>{active.name}</h2><p>{active.description??"Tablero interactivo"}</p></div><label>Desde<Input type="date"value={globalFrom}onChange={e=>setGlobalFrom(e.target.value)}/></label><label>Hasta<Input type="date"value={globalTo}onChange={e=>setGlobalTo(e.target.value)}/></label><label>Ubicación<Select ariaLabel="Ubicación global"value={globalLocation||"all"}onValueChange={value=>setGlobalLocation(value==="all"?"":value)}options={[{value:"all",label:"Todas"},...accessibleLocations.map(l=>({value:l.id,label:l.name}))]}/></label><Button size="sm"variant="secondary"onClick={()=>void refreshDashboard()}><RefreshCw size={13}/>Actualizar todo</Button>{can("manage_bi_dashboards")&&<><Button size="sm"variant="secondary"onClick={()=>{setEditingDashboard(active);setName(active.name);setDescription(active.description??"");setDialog("dashboard");}}><Save size={13}/>Renombrar</Button><Button size="sm"onClick={()=>setDialog("widget")}><Plus size={13}/>Componente</Button><Button size="sm"variant="ghost"onClick={async()=>{if(!window.confirm(`Eliminar ${active.name}?`))return;const response=await getSupabaseClient().rpc("bi_delete_dashboard",{p_company_id:companyId,p_dashboard_id:active.id});if(response.error)setError(response.error.message);else{setSnapshot(null);await loadCatalog();}}}><Trash2 size={13}/></Button></>}{can("export_bi_reports")&&<ExportButtons id={active.id}target="dashboard"exporting={exporting}onExport={exportTarget}/>}</div>{snapshot&&!snapshot.widgets.length?<div className="bi-dashboard-empty"><LayoutDashboard size={24}/><strong>Este tablero todavía está vacío</strong><p>Agrega KPI, gráficas o tablas desde un análisis guardado.</p><div>{can("manage_bi_dashboards")&&<Button size="sm"onClick={()=>setDialog("widget")}><Plus size={13}/>Agregar componente</Button>}<Button size="sm"variant="secondary"onClick={()=>router.push("/satrapy/bi/explorador")}>Abrir análisis <ChevronRight size={13}/></Button></div></div>:<div className="bi-widget-grid">{snapshot?.widgets.map(widget=><article key={widget.id}style={{gridColumn:`span ${Math.min(widget.width,4)}`,minHeight:`${230+(widget.height-1)*90}px`}}className={`bi-dashboard-widget is-${widget.status}`}><header><div><small>{widget.widget_type} · {widget.filter_mode==="inherit"?"filtros globales":"filtros propios de la vista"}</small><h3>{widget.title??widget.view_name}</h3></div>{can("manage_bi_dashboards")&&<div className="bi-widget-controls"><button title={widget.filter_mode==="inherit"?"Usar filtros propios de la vista":"Usar filtros globales del tablero"}aria-label={widget.filter_mode==="inherit"?"Usar filtros propios de la vista":"Usar filtros globales del tablero"}onClick={()=>void updateLayout(widget,"filter")}>{widget.filter_mode==="inherit"?"Filtros: tablero":"Filtros: vista"}</button><button title="Mover a la izquierda"aria-label="Mover a la izquierda"onClick={()=>void updateLayout(widget,"left")}><ChevronLeft size={13}/></button><button title="Mover a la derecha"aria-label="Mover a la derecha"onClick={()=>void updateLayout(widget,"right")}><ChevronRight size={13}/></button><button title="Cambiar ancho"aria-label="Cambiar ancho"onClick={()=>void updateLayout(widget,"size")}>Ancho</button><button title="Cambiar alto"aria-label="Cambiar alto"onClick={()=>void updateLayout(widget,"height")}>Alto</button><button title="Eliminar componente"aria-label="Eliminar componente"onClick={async()=>{await getSupabaseClient().rpc("bi_remove_dashboard_widget",{p_company_id:companyId,p_widget_id:widget.id});await loadCatalog();await refreshDashboard();}}><X size={13}/></button></div>}</header>{widget.status==="error"?<div className="bi-widget-state"><AlertCircle size={16}/>{widget.error}</div>:<WidgetContent widget={widget}/>}<footer><button onClick={()=>{const d=widget.definition??{};const q=new URLSearchParams({metrics:String((d.metric_codes as string[]??[]).join(",")),dimension:String(d.dimension??""),visualization:String(d.visualization??""),from:String(d.date_from??globalFrom),to:String(d.date_to??globalTo)});router.push(`/satrapy/bi/explorador?${q}`);}}>Abrir análisis <ChevronRight size={13}/></button>{can("export_bi_reports")&&<ExportButtons id={widget.id}target="widget"exporting={exporting}onExport={exportTarget}/>}</footer></article>)}</div>}</>:!loading&&<div className="bi-dashboard-empty"><LayoutDashboard size={24}/><strong>Reúne tus indicadores en un tablero</strong><p>Organiza KPI, gráficas y tablas creados desde Análisis y consúltalos con los mismos filtros.</p><div>{can("manage_bi_dashboards")&&<Button size="sm"onClick={()=>{setEditingDashboard(null);setName("");setDescription("");setDialog("dashboard");}}><Plus size={13}/>Crear tablero</Button>}<Button size="sm"variant="secondary"onClick={()=>router.push("/satrapy/bi/explorador")}>Abrir análisis <ChevronRight size={13}/></Button></div></div>}</main></div>}
    <Modal open={dialog==="dashboard"}onOpenChange={open=>{if(!open){setDialog(null);setEditingDashboard(null);}}}eyebrow="Tablero" title={editingDashboard?"Editar tablero":"Crear tablero"}description={editingDashboard?"Actualiza el nombre y la descripción del tablero.":"Reúne y organiza KPI, gráficas y tablas de Análisis. Podrás agregar componentes después de crearlo."}footer={<><Button variant="secondary"onClick={()=>{setDialog(null);setEditingDashboard(null);}}>Cancelar</Button><Button disabled={!name.trim()}onClick={()=>void saveDashboard()}>{editingDashboard?"Guardar":"Crear"}</Button></>}><div className="bi-save-form"><label><span>Nombre</span><Input value={name}onChange={e=>setName(e.target.value)} placeholder="Ej. Seguimiento comercial mensual"/></label><label><span>Descripción</span><Input value={description}onChange={e=>setDescription(e.target.value)} placeholder="Indica qué decisiones apoyará este tablero"/></label></div></Modal>
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
  const isRestaurant=appState?.membership.productExperience==="restaurant";
  const router=useRouter();
  const searchParams=useSearchParams();
  const [filters, setFilters] = useState<BiFilters>(()=>initialFilters(searchParams));
  const [applied, setApplied] = useState<BiFilters>(filters);
  const [summary, setSummary] = useState<BiSummary | null>(null);
  const [analytics,setAnalytics]=useState<BiAnalytics|null>(null);
  const [analyticsError,setAnalyticsError]=useState<string|null>(null);
  const [budgetSummary,setBudgetSummary]=useState<ExecutiveBudgetSummary|null>(null);
  const [budgetSummaryError,setBudgetSummaryError]=useState<string|null>(null);
  const [attentionAlerts,setAttentionAlerts]=useState<BiOperationalAlert[]>([]);
  const [attentionError,setAttentionError]=useState<string|null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedMetric, setSelectedMetric] = useState<BiInvestigationContext | null>(null);
  const [definitionMetric, setDefinitionMetric] = useState<string | null>(null);
  const [activeChart,setActiveChart]=useState<BiChart["code"]>("sales");
  const [periodPreset,setPeriodPreset]=useState<ExecutivePeriodPreset>(()=>inferExecutivePeriod(filters));
  const [advancedFiltersOpen,setAdvancedFiltersOpen]=useState(false);
  const canViewBudgets=!isRestaurant&&Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("view_bi_budgets"));
  const canViewAlerts=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("view_bi_alerts"));
  const canManageAlerts=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("manage_bi_alerts"));
  const canExport=Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes("export_bi_reports"));

  const load = useCallback(async (next: BiFilters) => {
    setLoading(true);setError(null);
    const args={
      p_company_id: companyId,p_date_from: next.dateFrom,p_date_to: next.dateTo,p_location_id: next.locationId || null,
      p_product_id: next.product?.id ?? null,p_customer_id: next.customer?.id ?? null,p_supplier_id: next.supplier?.id ?? null,
    };
    const budgetPromise=canViewBudgets?getSupabaseClient().rpc("bi_get_executive_budget_summary",args):Promise.resolve({data:null,error:null});
    const alertsPromise=canViewAlerts?getSupabaseClient().rpc("bi_get_attention_alerts",{p_company_id:companyId,p_limit:5}):Promise.resolve({data:[],error:null});
    const [summaryResult,analyticsResult,budgetResult,alertsResult]=await Promise.all([
      getSupabaseClient().rpc("bi_get_executive_summary_compared",{...args,p_comparison_mode:next.comparisonMode}),
      getSupabaseClient().rpc("bi_get_executive_charts",args),
      budgetPromise,
      alertsPromise,
    ]);
    if (summaryResult.error) setError(summaryResult.error.message);
    else setSummary(summaryResult.data as BiSummary);
    if(analyticsResult.error){
      setAnalytics(null);
      setAnalyticsError("Las comparaciones históricas avanzadas aún no están disponibles. Se muestran los agregados confirmados.");
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
    if(alertsResult.error){setAttentionError("No se pudieron consultar las alertas persistentes.");}
    else{setAttentionAlerts((alertsResult.data??[]) as BiOperationalAlert[]);setAttentionError(null);}
    setLoading(false);
  }, [canViewAlerts,canViewBudgets,companyId]);

  useEffect(() => { void Promise.resolve().then(() => load(applied)); }, [applied, load]);
  const activeFilterCount = [applied.locationId, applied.product, applied.customer, applied.supplier].filter(Boolean).length;
  const advancedFilterCount = [applied.product, applied.customer, applied.supplier].filter(Boolean).length;
  const dirty = JSON.stringify(filters) !== JSON.stringify(applied);
  const metrics=useMemo(()=>{const all=summary?.metrics.map(metric=>({...(analytics?.comparisons?.[metric.code]??{}),...metric}))??[];return isRestaurant?all.filter(metric=>["net_sales","tickets","average_ticket","gross_margin"].includes(metric.code)):all;},[analytics,isRestaurant,summary]);
  const charts=useMemo(()=>{const all=analytics?.charts??(summary?fallbackCharts({...summary,metrics}):[]);return isRestaurant?all.filter(chart=>chart.code==="sales"||chart.code==="gross_margin"):all;},[analytics,isRestaurant,metrics,summary]);
  const heroMetric=metrics.find(metric=>metric.code==="net_sales")??metrics[0];
  const secondaryMetrics=metrics.filter(metric=>metric.code!==heroMetric?.code&&["tickets","average_ticket","gross_margin","collections","receivables"].includes(metric.code)&&metric.available).slice(0,3);
  const selectedMetricCodes=new Set([heroMetric?.code,...secondaryMetrics.map(metric=>metric.code)]);
  const remainingMetrics=metrics.filter(metric=>!selectedMetricCodes.has(metric.code));
  const salesChart=charts.find(chart=>chart.code==="sales")??charts[0];
  const operationalRows=analytics?.operational_rows??summary?.locations.map(location=>({location_id:location.location_id,location_name:location.location_name,current_value:location.sales,previous_value:0,share_percent:0,status:"stable" as const}))??[];

  function applyFilters(next:BiFilters){
    setFilters(next);setApplied(next);
    const query=new URLSearchParams();
    query.set("from",next.dateFrom);query.set("to",next.dateTo);
    query.set("comparison",next.comparisonMode);
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
  function openInvestigation(request:DrillRequest){
    const context=createInvestigationContext(request,applied);
    if(request.locationId) context.path[0]={dimension:"location",id:request.locationId,label:accessibleLocations.find(location=>location.id===request.locationId)?.name??"Sucursal seleccionada"};
    setSelectedMetric(context);
  }
  async function reviewAttention(alert:BiOperationalAlert){
    if(alert.status!=="active"||!canManageAlerts)return;
    const response=await getSupabaseClient().rpc("bi_transition_alert",{p_company_id:companyId,p_alert_id:alert.id,p_action:"review",p_reason:null});
    if(response.error){setAttentionError(response.error.message);return;}
    setAttentionAlerts(current=>current.map(item=>item.id===alert.id?{...item,status:"reviewed",reviewed_at:new Date().toISOString()}:item));
  }

  return <section className="content-frame module-page bi-module">
    <PageHeading eyebrow={isRestaurant?"Operación del restaurante":"Business Intelligence"} title={isRestaurant?"Indicadores":"Resumen ejecutivo"} description={isRestaurant?"Ventas, tickets, ticket promedio y margen para dar seguimiento al piloto.":"Lectura transversal con distinción entre devengado, efectivo y operación. Cada cifra conserva fórmula, fuente y acceso al origen."} action={<Button variant="secondary" size="sm" onClick={() => void load(applied)} disabled={loading}><RefreshCw size={14} /> Actualizar</Button>} />
    <BiFilterBar className="bi-executive-filterbar" pending={dirty} ariaLabel="Filtros del Resumen ejecutivo">
      <div className="bi-executive-filterbar__primary">
        <label><span>Periodo</span><Select ariaLabel="Periodo del resumen" value={periodPreset} onValueChange={changePeriod} options={EXECUTIVE_PERIOD_OPTIONS} /></label>
        <label><span>Comparar con</span><Select ariaLabel="Periodo de comparación" value={filters.comparisonMode} onValueChange={value=>setFilters(current=>({...current,comparisonMode:value as BiFilters["comparisonMode"]}))} options={COMPARISON_OPTIONS}/></label>
        <label><span>Ubicación</span><Select ariaLabel="Filtrar por ubicación" value={filters.locationId || "__all__"} onValueChange={value => setFilters(current => ({ ...current, locationId: value === "__all__" ? "" : value }))} options={[{ value: "__all__", label: "Todas las ubicaciones" }, ...accessibleLocations.filter(location => location.is_active).map(location => ({ value: location.id, label: location.name }))]} /></label>
        {!isRestaurant&&<Button className="bi-executive-filterbar__more" variant="secondary" size="sm" aria-expanded={advancedFiltersOpen} aria-controls="bi-executive-advanced-filters" onClick={()=>setAdvancedFiltersOpen(current=>!current)}><Plus size={14}/><span>Más filtros{advancedFilterCount>0?` · ${advancedFilterCount}`:""}</span></Button>}
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
      {!isRestaurant&&advancedFiltersOpen&&<div id="bi-executive-advanced-filters" className="bi-executive-filterbar__advanced">
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
          <small>{formatSourceDate(applied.dateFrom)}–{formatSourceDate(applied.dateTo)}{summary?` · contra ${formatSourceDate(summary.period.previous_from)}–${formatSourceDate(summary.period.previous_to)} · actualizado ${new Date(summary.updated_at).toLocaleString("es-MX")}`:""}</small>
        </div>
        <div className="bi-executive-filterbar__chips" aria-label="Filtros aplicados">
          {applied.locationId&&<button type="button" onClick={()=>removeAppliedFilter("locationId")}>Ubicación: {accessibleLocations.find(location=>location.id===applied.locationId)?.name??"Selección"}<X size={12}/></button>}
          {(["product","customer","supplier"] as const).map(key=>applied[key]&&<button type="button" key={key} onClick={()=>removeAppliedFilter(key)}>{key==="product"?"Producto":key==="customer"?"Cliente":"Proveedor"}: {applied[key]?.label}<X size={12}/></button>)}
          {!activeFilterCount&&<span>Sin dimensiones adicionales</span>}
        </div>
      </div>
    </BiFilterBar>
    {analyticsError&&summary&&<BiState kind="partial" compact title="Datos parciales" description={analyticsError}/>}
    <DataState loading={loading && !summary} error={error} hasData={summary?.metrics.length ?? 0} empty="No hay métricas disponibles para este acceso." errorAction={<Button size="sm" onClick={() => void load(applied)}>Reintentar</Button>}>
      {summary && <>
        {loading && <div className="bi-refreshing"><LoaderCircle className="spin" size={14} /> Actualizando indicadores…</div>}
        {canViewAlerts&&<ExecutiveAttention items={attentionAlerts} error={attentionError} canManage={canManageAlerts} onReview={reviewAttention} onInspect={alert=>setSelectedMetric(alertInvestigationContext(alert))} onOpenAll={()=>router.push("/satrapy/bi/alertas")}/>}
        <section className="bi-executive-kpis" aria-labelledby="bi-executive-kpis-title">
          <header><div><span className="eyebrow">Qué está pasando</span><h2 id="bi-executive-kpis-title">Lectura del periodo</h2><p>Actual: {formatSourceDate(summary.period.from)}–{formatSourceDate(summary.period.to)} · {comparisonLabel(applied.comparisonMode)}: {formatSourceDate(summary.period.previous_from)}–{formatSourceDate(summary.period.previous_to)}.</p></div></header>
          <div className="bi-executive-kpis__primary">{heroMetric&&<BiKpiCard metric={heroMetric} currencyCode={summary.currency_code} active={CHART_FOR_METRIC[heroMetric.code]===activeChart} featured onFocus={() => focusMetric(heroMetric.code)} onOpen={() => heroMetric.available && openInvestigation({code:heroMetric.code})} onDefinition={() => setDefinitionMetric(heroMetric.code)} />}
            <div className="bi-executive-kpis__secondary">{secondaryMetrics.map(metric=><BiKpiCard key={metric.code} metric={metric} currencyCode={summary.currency_code} active={CHART_FOR_METRIC[metric.code]===activeChart} onFocus={()=>focusMetric(metric.code)} onOpen={()=>metric.available&&openInvestigation({code:metric.code})} onDefinition={()=>setDefinitionMetric(metric.code)}/>)}</div>
          </div>
          {remainingMetrics.length>0&&<details className="bi-secondary-metrics"><summary>Métricas secundarias <span>{remainingMetrics.length}</span></summary><div>{remainingMetrics.map(metric=><BiKpiCard key={metric.code} metric={metric} compact currencyCode={summary.currency_code} active={CHART_FOR_METRIC[metric.code]===activeChart} onFocus={()=>focusMetric(metric.code)} onOpen={()=>metric.available&&openInvestigation({code:metric.code})} onDefinition={()=>setDefinitionMetric(metric.code)}/>)}</div></details>}
        </section>
        {canViewBudgets&&<ExecutiveBudgetPanel data={budgetSummary} error={budgetSummaryError} currencyCode={summary.currency_code} onOpen={()=>router.push("/satrapy/bi/metas-presupuestos")}/>}
        <div className="bi-chart-section">
          <header><div><span className="eyebrow">Análisis visual</span><h2>Actual contra periodo anterior</h2><p>Selecciona un punto o barra para preparar una investigación con el mismo contexto.</p></div><div className="bi-chart-tabs" aria-label="Métricas visualizadas">{charts.map(chart=><button type="button" key={chart.code} className={activeChart===chart.code?"is-active":""} onClick={()=>setActiveChart(chart.code)}>{CHART_META[chart.code].title}</button>)}</div></header>
          <div className="bi-chart-grid">
            {salesChart&&<ExecutiveTrendChart chart={salesChart} currencyCode={summary.currency_code} period={summary.period} onInspect={openInvestigation} onDefinition={()=>setDefinitionMetric(salesChart.metric_code)}/>}
            {charts.filter(chart=>chart.code!=="sales"&&chart.code===activeChart).map(chart=><BiExecutiveChart key={chart.code} chart={chart} active currencyCode={summary.currency_code} period={summary.period} updatedAt={analytics?.updated_at??summary.updated_at} onDefinition={()=>setDefinitionMetric(chart.metric_code)} onInspect={openInvestigation}/>)}
          </div>
        </div>
        <ExecutiveOperationalSummary rows={operationalRows} currencyCode={summary.currency_code} onInspect={openInvestigation} />
        <OperationalAnalyticsSection companyId={companyId} filters={applied} currencyCode={summary.currency_code} canExport={canExport} onInspect={setSelectedMetric}/>
        {!isRestaurant&&<article className="bi-accrual-note"><AlertCircle size={18} /><div><strong>Devengado no es efectivo</strong><p>Ventas reconoce la operación cuando se completa; cobranza, pagos y bancos reconocen movimientos efectivos. El margen usa sólo el costo reconocido congelado por partida; una comparación sin base histórica queda “No disponible” y nunca se sustituye con una estimación.</p></div></article>}
        {!isRestaurant&&<div className="bi-trace"><Database size={15} /><span><strong>Trazabilidad de consulta</strong>{summary.trace.query}{analytics?` + ${analytics.trace.query}`:""} · {[...summary.trace.sources,...(analytics?.trace.sources??[])].filter((source,index,all)=>all.indexOf(source)===index).join(", ")}</span></div>}
      </>}
    </DataState>
    <MetricDefinition code={definitionMetric} summary={summary} onClose={() => setDefinitionMetric(null)} />
    <BiDrilldown key={selectedMetric?`${selectedMetric.metricCode}:${selectedMetric.level}:${selectedMetric.activeDimension??"records"}`:"closed"} companyId={companyId} context={selectedMetric} currencyCode={summary?.currency_code} onClose={() => setSelectedMetric(null)} />
  </section>;
}

function ExecutiveAttention({items,error,canManage,onReview,onInspect,onOpenAll}:{items:BiOperationalAlert[];error:string|null;canManage:boolean;onReview:(alert:BiOperationalAlert)=>Promise<void>;onInspect:(alert:BiOperationalAlert)=>void;onOpenAll:()=>void}) {
  return <section className="bi-executive-attention" aria-labelledby="bi-executive-attention-title"><header><div><span className="eyebrow">Qué necesita atención</span><h2 id="bi-executive-attention-title">Alertas operativas</h2></div><Button size="sm" variant="ghost" onClick={onOpenAll}>Ver todas <ChevronRight size={13}/></Button></header>{error&&<BiState kind="partial" compact title="Alertas temporalmente no disponibles" description={error}/>} {items.length?<div>{items.map(alert=>{const visual=alertSeverity(alert);return <AttentionItem key={alert.id} tone={visual.tone==="danger"?"danger":visual.tone==="warning"?"warning":"accent"} title={alert.entity_label??(METRICS[alert.metric_code]?.label??alert.metric_code)} description={alert.explanation} action={<div className="bi-attention-actions">{canManage&&alert.status==="active"&&<Button size="sm" variant="ghost" onClick={()=>void onReview(alert)}>Marcar revisada</Button>}<Button size="sm" variant="secondary" onClick={()=>onInspect(alert)}>Revisar <ChevronRight size={13}/></Button></div>}/>;})}</div>:!error?<BiState kind="empty" compact title="Sin alertas activas" description="La última evaluación programada no encontró condiciones prioritarias."></BiState>:null}</section>;
}

function ExecutiveTrendChart({ chart, currencyCode, period, onInspect, onDefinition }: { chart: BiChart; currencyCode?: string | null; period: BiSummary["period"]; onInspect: (request: DrillRequest) => void; onDefinition: () => void }) {
  const copy=CHART_META[chart.code], points=chart.points.map(point=>({...point,label:formatSourceDate(point.date),current:point.value??0,previous:point.previous_value??0}));
  const inspect=(point:BiChartPoint)=>onInspect({code:chart.metric_code,dateFrom:point.date,dateTo:point.date});
  const tooltip=(props:unknown)=>{const {active,payload}=props as {active?:boolean;payload?:ReadonlyArray<{payload?:BiChartPoint&{label:string;current:number;previous:number}}>} ;const point=payload?.[0]?.payload;if(!active||!point)return null;return <div className="bi-recharts-tooltip"><strong>{point.label}</strong><span>Actual <b>{formatMoney(point.current,currencyCode)}</b></span><span>Anterior <b>{formatMoney(point.previous,currencyCode)}</b></span><small>Haz clic para investigar este día.</small></div>;};
  return <ChartContainer className="bi-chart-card bi-executive-trend" eyebrow="Devengado · línea" title={copy.title} description="Serie diaria contra el periodo equivalente anterior." action={<button type="button" aria-label={`Definición de ${copy.title}`} onClick={onDefinition}><CircleHelp size={15}/></button>}>
    {!chart.available?<BiState kind="partial" compact title="Serie no disponible" description={chart.reason??"No hay una serie comparable para estos filtros."}/>:points.length===0?<BiState kind="empty" compact title="Sin datos para graficar" description="No hay operaciones que mostrar con esta selección."/>:<><div className="bi-recharts-chart" aria-label={`${copy.title}: periodo actual y periodo anterior`}><ResponsiveContainer width="100%" height={268}><LineChart data={points} margin={{top:8,right:8,left:0,bottom:0}} onClick={(event:unknown)=>{const point=(event as {activePayload?:Array<{payload?:BiChartPoint}>})?.activePayload?.[0]?.payload;if(point)inspect(point);}}><CartesianGrid vertical={false} stroke="var(--bi-border)"/><XAxis dataKey="label" minTickGap={34} tickLine={false} axisLine={false}/><YAxis tickFormatter={value=>formatMoney(Number(value),currencyCode)} width={72} tickLine={false} axisLine={false}/><RechartsTooltip content={tooltip}/><Line type="monotone" dataKey="previous" name="Periodo anterior" stroke="#a0aaa6" strokeDasharray="5 5" strokeWidth={2} dot={false} activeDot={{r:5}} isAnimationActive={false}/><Line type="monotone" dataKey="current" name="Periodo actual" stroke="var(--accent)" strokeWidth={2.5} dot={false} activeDot={{r:5}} isAnimationActive={false}/></LineChart></ResponsiveContainer></div><div className="bi-trend-points" aria-label="Investigar día de ventas">{points.slice(-7).map(point=><button type="button" key={point.date} onClick={()=>inspect(point)}><span>{point.label}</span><b>{formatMoney(point.current,currencyCode)}</b></button>)}</div><p className="bi-chart-period">Comparación equivalente: {formatSourceDate(period.previous_from)}–{formatSourceDate(period.previous_to)}.</p></>}
  </ChartContainer>;
}

function ExecutiveOperationalSummary({ rows, currencyCode, onInspect }: { rows: NonNullable<BiAnalytics["operational_rows"]>; currencyCode?: string | null; onInspect: (request: DrillRequest) => void }) {
  const visible=rows.slice(0,8), chartRows=visible.slice(0,6);
  return <section className="bi-operational-summary" aria-labelledby="bi-operational-summary-title"><header><div><span className="eyebrow">Dónde comenzar</span><h2 id="bi-operational-summary-title">Sucursales con mayor impacto</h2><p>Ordenadas primero por disminución y luego por valor actual. El detalle conserva los filtros de la pantalla.</p></div></header>{visible.length?<div className="bi-operational-summary__grid"><ChartContainer className="bi-chart-card bi-operational-ranking" eyebrow="Ranking" title="Ventas por sucursal" description="Haz clic en una barra para investigar la sucursal."><div className="bi-recharts-ranking"><ResponsiveContainer width="100%" height={Math.max(210,chartRows.length*42)}><BarChart data={chartRows} layout="vertical" margin={{top:2,right:8,left:4,bottom:2}} onClick={(event:unknown)=>{const row=(event as {activePayload?:Array<{payload?:{location_id:string}}>})?.activePayload?.[0]?.payload;if(row)onInspect({code:"net_sales",locationId:row.location_id});}}><CartesianGrid horizontal={false} stroke="var(--bi-border)"/><XAxis type="number" hide/><YAxis dataKey="location_name" type="category" width={106} tickLine={false} axisLine={false}/><RechartsTooltip formatter={(value)=>formatMoney(Number(value),currencyCode)}/><Bar dataKey="current_value" name="Ventas" fill="var(--accent)" radius={3} isAnimationActive={false}/></BarChart></ResponsiveContainer></div></ChartContainer><AnalyticsTable caption="Resumen operativo por sucursal" className="bi-operational-table"><thead><tr><th>Sucursal</th><th>Actual</th><th>Anterior</th><th>Variación</th><th>Participación</th><th>Estado</th><th><span className="sr-only">Acción</span></th></tr></thead><tbody>{visible.map(row=>{const difference=row.current_value-row.previous_value;return <tr key={row.location_id}><td><strong>{row.location_name}</strong></td><td>{formatMoney(row.current_value,currencyCode)}</td><td>{row.previous_value===0?"—":formatMoney(row.previous_value,currencyCode)}</td><td className={difference<0?"is-negative":""}>{row.previous_value===0?"Sin base":formatDifference({code:"net_sales",available:true,value:row.current_value},difference,currencyCode)}</td><td>{row.share_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%</td><td><Badge tone={row.status==="declining"?"warning":"neutral"}>{row.status==="declining"?"Disminución":row.status==="new"?"Sin base":"Estable"}</Badge></td><td><Button size="sm" variant="ghost" onClick={()=>onInspect({code:"net_sales",locationId:row.location_id})}>Revisar <ChevronRight size={13}/></Button></td></tr>;})}</tbody></AnalyticsTable></div>:<BiState kind="empty" compact title="Sin sucursales para comparar" description="No hay ventas por sucursal dentro de los filtros aplicados."/>}</section>;
}

function formatOperationalValue(value:number|null,unit:ExplorerMetric["unit"],currencyCode?:string|null){
  if(value==null)return "—";
  if(unit==="currency")return formatMoney(value,currencyCode);
  if(unit==="percent")return `${value.toLocaleString("es-MX",{maximumFractionDigits:1})}%`;
  return value.toLocaleString("es-MX",{maximumFractionDigits:unit==="count"?0:2});
}
function formatOperationalPercent(value:number|null){return value==null?"—":`${value>0?"+":""}${value.toLocaleString("es-MX",{maximumFractionDigits:1})}%`;}
function operationalStatus(status:OperationalRow["status"]){
  if(status==="improved")return{label:"Mejora",tone:"success" as const};
  if(status==="deteriorated")return{label:"Deterioro",tone:"warning" as const};
  if(status==="partial")return{label:"Dato parcial",tone:"warning" as const};
  if(status==="unavailable")return{label:"No disponible",tone:"neutral" as const};
  if(status==="no_comparison")return{label:"Sin comparación",tone:"neutral" as const};
  return{label:"Neutro",tone:"neutral" as const};
}

function OperationalAnalyticsSection({companyId,filters,currencyCode,canExport,onInspect}:{companyId:string;filters:BiFilters;currencyCode?:string|null;canExport:boolean;onInspect:(context:BiInvestigationContext)=>void}){
  const filterKey=`${filters.dateFrom}:${filters.dateTo}:${filters.comparisonMode}:${filters.locationId}:${filters.product?.id??""}:${filters.customer?.id??""}:${filters.supplier?.id??""}`;
  const [catalog,setCatalog]=useState<ExplorerCatalog|null>(null);
  const [catalogError,setCatalogError]=useState<string|null>(null);
  const [dimension,setDimension]=useState<OperationalDimension>("location");
  const [metricCode,setMetricCode]=useState("net_sales");
  const [searchDraft,setSearchDraft]=useState("");
  const [search,setSearch]=useState("");
  const [sortBy,setSortBy]=useState<OperationalSort>("negative_impact");
  const [sortDirection,setSortDirection]=useState<AnalyticsSortDirection>("desc");
  const [pagination,setPagination]=useState({key:filterKey,page:1});
  const [result,setResult]=useState<OperationalResult|null>(null);
  const [loading,setLoading]=useState(false);
  const [error,setError]=useState<string|null>(null);
  const [exporting,setExporting]=useState(false);

  useEffect(()=>{let cancelled=false;void Promise.resolve().then(async()=>{
    const response=await getSupabaseClient().rpc("bi_get_metric_catalog",{p_company_id:companyId});
    if(cancelled)return;if(response.error)setCatalogError(response.error.message);else setCatalog(response.data as ExplorerCatalog);
  });return()=>{cancelled=true;};},[companyId]);
  const metrics=useMemo(()=>catalog?.metrics.filter(metric=>OPERATIONAL_METRICS[dimension].includes(metric.code)&&metric.available)??[],[catalog,dimension]);
  const effectiveMetricCode=metrics.some(metric=>metric.code===metricCode)?metricCode:(metrics[0]?.code??metricCode);
  const page=pagination.key===filterKey?pagination.page:1;
  const setPage=(next:number)=>setPagination({key:filterKey,page:next});
  useEffect(()=>{const timer=window.setTimeout(()=>{const next=searchDraft.trim();setSearch(current=>{if(current===next)return current;setPagination({key:filterKey,page:1});return next;});},320);return()=>window.clearTimeout(timer);},[filterKey,searchDraft]);

  const load=useCallback(async()=>{
    if(!catalog||!metrics.some(metric=>metric.code===effectiveMetricCode))return;
    setLoading(true);setError(null);
    const response=await getSupabaseClient().rpc("bi_get_operational_table",{
      p_company_id:companyId,p_metric_code:effectiveMetricCode,p_dimension:dimension,p_date_from:filters.dateFrom,p_date_to:filters.dateTo,
      p_location_id:filters.locationId||null,p_product_id:filters.product?.id??null,p_customer_id:filters.customer?.id??null,
      p_supplier_id:filters.supplier?.id??null,p_search:search||null,p_sort_by:sortBy,p_sort_direction:sortDirection,p_page:page,p_page_size:25,p_comparison_mode:filters.comparisonMode,
    });
    if(response.error)setError(response.error.message);else setResult(response.data as OperationalResult);setLoading(false);
  },[catalog,companyId,dimension,effectiveMetricCode,filters.comparisonMode,filters.customer?.id,filters.dateFrom,filters.dateTo,filters.locationId,filters.product?.id,filters.supplier?.id,metrics,page,search,sortBy,sortDirection]);
  useEffect(()=>{void Promise.resolve().then(load);},[load]);

  function changeDimension(next:OperationalDimension){setDimension(next);setResult(null);setPage(1);const allowed=catalog?.metrics.filter(metric=>OPERATIONAL_METRICS[next].includes(metric.code)&&metric.available)??[];if(!allowed.some(metric=>metric.code===metricCode))setMetricCode(allowed[0]?.code??"net_sales");}
  function changeMetric(next:string){setMetricCode(next);setResult(null);setPage(1);}
  function changePriority(next:string){setSortBy(next as OperationalSort);setSortDirection("desc");setPage(1);}
  function changeSort(next:string,direction:AnalyticsSortDirection){setSortBy(next as OperationalSort);setSortDirection(direction);setPage(1);}
  function resetTable(){setDimension("location");setMetricCode("net_sales");setSearchDraft("");setSearch("");setSortBy("negative_impact");setSortDirection("desc");setPage(1);setResult(null);}
  async function exportTable(){
    setExporting(true);setError(null);
    try{
      const session=(await getSupabaseClient().auth.getSession()).data.session;if(!session)throw new Error("Sesión no válida.");
      const response=await fetch("/api/bi/export",{method:"POST",headers:{Authorization:`Bearer ${session.access_token}`,"content-type":"application/json"},body:JSON.stringify({
        companyId,targetType:"operational_table",format:"csv",definition:{metric_code:effectiveMetricCode,dimension,date_from:filters.dateFrom,date_to:filters.dateTo,
          location_id:filters.locationId||null,product_id:filters.product?.id??null,customer_id:filters.customer?.id??null,supplier_id:filters.supplier?.id??null,
          search:search||null,sort_by:sortBy,sort_direction:sortDirection,comparison_mode:filters.comparisonMode},
      })});
      if(!response.ok){const body=await response.json().catch(()=>({}));throw new Error(body.message??"No se pudo exportar la tabla.");}
      const blob=await response.blob(),url=URL.createObjectURL(blob),anchor=document.createElement("a");anchor.href=url;
      anchor.download=response.headers.get("content-disposition")?.match(/filename="([^"]+)"/)?.[1]??`satrapy_bi_${dimension}.csv`;anchor.click();URL.revokeObjectURL(url);
    }catch(value){setError(value instanceof Error?value.message:"No se pudo exportar la tabla.");}finally{setExporting(false);}
  }

  const selectedMetric=metrics.find(metric=>metric.code===effectiveMetricCode);
  const activePriority=OPERATIONAL_PRIORITY.find(item=>item.value===sortBy);
  const sortLabel=activePriority?.description??({entity:"Entidad",current_value:"Valor actual",previous_value:"Valor anterior",change_value:"Variación absoluta",change_percent:"Variación porcentual",contribution_percent:"Contribución al cambio"} as Record<string,string>)[sortBy]??"Orden personalizado";
  const contributionMax=Math.max(1,...(result?.items.map(row=>Math.abs(row.contribution_percent??0))??[]));
  const tableDirty=dimension!=="location"||effectiveMetricCode!=="net_sales"||Boolean(search)||sortBy!=="negative_impact"||sortDirection!=="desc";
  return <section className="bi-operational-analytics" aria-labelledby="bi-operational-analytics-title">
    <header><div><span className="eyebrow">Priorizar y actuar</span><h2 id="bi-operational-analytics-title">Tablas analíticas operativas</h2><p>Compara agregados reales por dimensión sin descargar transacciones. “Revisar” continúa en la investigación contextual.</p></div>{canExport&&<Button variant="secondary" size="sm" disabled={!result||exporting} onClick={()=>void exportTable()}>{exporting?<LoaderCircle className="spin" size={14}/>:<Download size={14}/>} Exportar CSV</Button>}</header>
    <div className="bi-operational-analytics__controls">
      <div className="bi-operational-analytics__dimensions" aria-label="Dimensión de la tabla">{(Object.keys(OPERATIONAL_DIMENSION_LABEL) as OperationalDimension[]).map(item=><button type="button" key={item} aria-pressed={dimension===item} onClick={()=>changeDimension(item)}>{OPERATIONAL_DIMENSION_LABEL[item]}</button>)}</div>
      <label><span>Métrica</span><Select ariaLabel="Métrica de la tabla operativa" value={effectiveMetricCode} onValueChange={changeMetric} options={metrics.map(metric=>({value:metric.code,label:metric.name}))}/></label>
      <label><span>Prioridad</span><Select ariaLabel="Criterio de prioridad" value={OPERATIONAL_PRIORITY.some(item=>item.value===sortBy)?sortBy:"custom"} onValueChange={changePriority} options={[...OPERATIONAL_PRIORITY.map(item=>({value:item.value,label:item.label})),...(!OPERATIONAL_PRIORITY.some(item=>item.value===sortBy)?[{value:"custom",label:"Orden de columna"}]:[])]}/></label>
      {tableDirty&&<Button variant="ghost" size="sm" onClick={resetTable}>Restablecer tabla</Button>}
    </div>
    <div className="bi-operational-analytics__context"><span>Contexto heredado</span><strong>{formatSourceDate(filters.dateFrom)}–{formatSourceDate(filters.dateTo)}</strong><small>{result?`${comparisonLabel(filters.comparisonMode)} ${formatSourceDate(result.period.previous_from)}–${formatSourceDate(result.period.previous_to)}`:comparisonLabel(filters.comparisonMode)} · filtros globales y alcance empresarial aplicados</small></div>
    <DataToolbar search={searchDraft} onSearchChange={setSearchDraft} placeholder={`Buscar ${OPERATIONAL_DIMENSION_LABEL[dimension].toLowerCase()}`} activeFilters={search?1:0} onClear={()=>{setSearchDraft("");setSearch("");setPage(1);}} results={result?.pagination.total}/>
    <div className="bi-operational-analytics__status" role="status" aria-live="polite"><span>Orden activo: <strong>{sortLabel}</strong>{!activePriority&&` · ${sortDirection==="asc"?"ascendente":"descendente"}`}</span>{searchDraft.trim()!==search&&<small>Aplicando búsqueda…</small>}</div>
    {!catalog&&!catalogError?<BiState kind="loading" title="Cargando métricas compatibles…" description="Se valida disponibilidad y permiso antes de consultar la tabla."/>:catalogError?<BiState kind="error" title="No se pudieron cargar las métricas" description={catalogError}/>:!metrics.length?<BiState kind="partial" title="Sin métricas compatibles" description="No hay una métrica operativa disponible para esta dimensión y este acceso."/>:loading&&!result?<BiState kind="loading" title={`Consultando ${OPERATIONAL_DIMENSION_LABEL[dimension].toLowerCase()}…`} description="La agregación, el orden y la página se calculan en servidor."/>:error&&!result?<BiState kind="error" title="No se pudo cargar la tabla" description={error} action={<Button size="sm" onClick={()=>void load()}>Reintentar</Button>}/>:result?<>
      {error&&<BiState kind="partial" compact title="No se pudo actualizar la tabla" description={`${error} Se conserva la última página confirmada.`}/>}
      {result.partial&&<BiState kind="partial" compact title="Datos parciales" description={`${result.scope.partial_groups.toLocaleString("es-MX")} agregado${result.scope.partial_groups===1?"":"s"} no tiene cobertura completa. No se estiman valores faltantes.`}/>}
      {!result.items.length?<BiState kind="empty" title={search?`Sin resultados para “${search}”`:"Sin agregados para analizar"} description={search?"Prueba otra búsqueda o restablece la tabla.":"No hay operaciones dentro del periodo y los filtros aplicados."} action={search?<Button size="sm" variant="secondary" onClick={()=>{setSearchDraft("");setSearch("");setPage(1);}}>Limpiar búsqueda</Button>:undefined}/>:<AnalyticsTable caption={`${OPERATIONAL_DIMENSION_LABEL[dimension]} por ${selectedMetric?.name??metricCode}`} ariaLabel={`Tabla de ${OPERATIONAL_DIMENSION_LABEL[dimension].toLowerCase()} ordenada por ${sortLabel}`} className="bi-operational-analytics__table" busy={loading}>
        <thead><tr>
          <AnalyticsSortHeader label="Entidad" sortKey="entity" activeSort={sortBy} direction={sortDirection} onSort={changeSort}/>
          <AnalyticsSortHeader label="Valor actual" sortKey="current_value" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <AnalyticsSortHeader label="Valor anterior" sortKey="previous_value" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <AnalyticsSortHeader label="Variación" sortKey="change_value" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <AnalyticsSortHeader label="Variación %" sortKey="change_percent" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <AnalyticsSortHeader label="Participación" sortKey="share_percent" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <AnalyticsSortHeader label="Contribución" sortKey="contribution_percent" activeSort={sortBy} direction={sortDirection} onSort={changeSort} numeric/>
          <th scope="col" className="number-cell">Ranking</th><th scope="col">Estado</th><th scope="col"><span className="sr-only">Acción</span></th>
        </tr></thead>
        <tbody>{result.items.map(row=>{const state=operationalStatus(row.status);const reviewable=row.group_key!=="uncategorized";return <tr key={row.group_key}>
          <td><strong title={row.group_label}>{row.group_label}</strong>{row.reason&&<small>{row.reason}</small>}</td>
          <td className="number-cell">{row.available?formatOperationalValue(row.current_value,result.metric.unit,result.currency_code??currencyCode):"—"}</td>
          <td className="number-cell">{row.available?formatOperationalValue(row.previous_value??0,result.metric.unit,result.currency_code??currencyCode):"—"}</td>
          <td className={`number-cell is-${row.status}`}>{row.change_value==null?"—":formatDifference({code:effectiveMetricCode,available:true,value:row.current_value},row.change_value,result.currency_code??currencyCode)}</td>
          <td className="number-cell">{row.comparison_state==="previous_zero"?"Base anterior en cero":formatOperationalPercent(row.change_percent)}</td>
          <td className="number-cell"><AnalyticsCellBar value={row.share_percent}>{row.share_percent==null?"—":`${row.share_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`}</AnalyticsCellBar></td>
          <td className="number-cell"><AnalyticsCellBar value={row.contribution_percent} max={contributionMax}>{formatOperationalPercent(row.contribution_percent)}</AnalyticsCellBar></td>
          <td className="number-cell">#{row.ranking.toLocaleString("es-MX")}</td><td><Badge tone={state.tone}>{state.label}</Badge></td>
          <td>{reviewable?<Button size="sm" variant="ghost" onClick={()=>onInspect(createOperationalInvestigationContext(effectiveMetricCode,dimension,row,filters))}>Revisar <ChevronRight size={13}/></Button>:<span className="bi-operational-analytics__unavailable" title="No existe una categoría canónica para continuar el recorrido">No disponible</span>}</td>
        </tr>;})}</tbody>
      </AnalyticsTable>}
      <DataPagination page={result.pagination.page} pageSize={result.pagination.page_size} total={result.pagination.total} onChange={setPage} label="agregados"/>
      <footer><span>{result.pagination.total.toLocaleString("es-MX")} de {result.scope.total_groups.toLocaleString("es-MX")} agregados en el alcance</span><span><Database size={13} aria-hidden="true"/>{result.trace.query}</span></footer>
    </>:null}
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

function BiKpiCard({ metric, currencyCode, active, featured=false, compact=false, onFocus, onOpen, onDefinition }: { metric: BiMetric; currencyCode?: string | null; active: boolean; featured?: boolean; compact?: boolean; onFocus: () => void; onOpen: () => void; onDefinition: () => void }) {
  const meta = METRICS[metric.code];if (!meta) return null;
  const delta = comparison(metric);
  return <MetricCard className={`bi-kpi${compact?" is-compact":""}`} label={meta.label} value={formatMetric(metric,currencyCode)} selected={active} unavailable={!metric.available} featured={featured} onSelect={CHART_FOR_METRIC[metric.code]?onFocus:undefined}
    eyebrow={<Badge tone={meta.kind === "Efectivo" ? "info" : meta.kind === "Devengado" ? "primary" : "neutral"}>{meta.kind}</Badge>}
    headerAction={<button type="button" aria-label={`Definición de ${meta.label}`} onClick={onDefinition}><CircleHelp size={15} /></button>}
    description={delta == null ? <small>{metric.reason ?? (metric.available ? "Comparación no disponible" : "No disponible")}</small> : <div className="bi-kpi__comparison">
      <span>Anterior <b>{formatMetric({...metric,value:metric.previous_value??null},currencyCode)}</b></span>
      <span>Diferencia <b>{formatDifference(metric,delta.absolute,currencyCode)}</b></span>
      <MetricDelta direction={delta.absolute>=0?"up":"down"} value={delta.percent==null?"Base anterior en cero":`${Math.abs(delta.percent).toLocaleString("es-MX",{maximumFractionDigits:1})}%`}/>
    </div>}
    delta={(metric.code === "inventory_value" || metric.code === "gross_margin") && metric.coverage != null ? <small>Cobertura de costo: {metric.coverage}%</small> : undefined}
    footerAction={<button type="button" className="bi-kpi__drill" disabled={!metric.available} onClick={onOpen}>Ver operaciones <ChevronRight size={14} /></button>}
  />;
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
  return <ChartContainer className={`bi-chart-card bi-executive-chart ${chart.available?"":"is-unavailable"}`} selected={active} eyebrow={`${chart.kind} · ${chart.visualization==="area"?"Área":chart.visualization==="bars"?"Barras":"Línea"}`} title={copy.title} description={copy.description} action={<button type="button" aria-label={`Definición de ${copy.title}`} onClick={onDefinition}><CircleHelp size={15}/></button>}>
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
  </ChartContainer>;
}

function BiDrilldown({ companyId, context, currencyCode, onClose }: { companyId: string; context: BiInvestigationContext | null; currencyCode?: string | null; onClose: () => void }) {
  const router=useRouter();const [current,setCurrent]=useState<BiInvestigationContext|null>(context);const [investigation,setInvestigation]=useState<InvestigationData|null>(null);const [analysisLoading,setAnalysisLoading]=useState(false);const [analysisError,setAnalysisError]=useState<string|null>(null);const [records,setRecords]=useState<Drilldown|null>(null);const [recordsLoading,setRecordsLoading]=useState(false);const [recordsError,setRecordsError]=useState<string|null>(null);const [page,setPage]=useState(1);
  useEffect(()=>{
    if(!current?.activeDimension)return;
    let cancelled=false;void Promise.resolve().then(async()=>{setAnalysisLoading(true);setAnalysisError(null);setInvestigation(null);
      const response=await getSupabaseClient().rpc("bi_get_metric_investigation",{
        p_company_id:companyId,p_metric_code:current.metricCode,p_dimension:current.activeDimension,p_date_from:current.dateFrom,p_date_to:current.dateTo,
        p_location_id:current.filters.locationId||null,p_product_id:current.filters.productId||null,p_category_id:current.filters.categoryId||null,
        p_customer_id:current.filters.customerId||null,p_supplier_id:current.filters.supplierId||null,p_page:page,p_page_size:25,
      });if(cancelled)return;if(response.error){setAnalysisError(response.error.message);}else setInvestigation(response.data as InvestigationData);setAnalysisLoading(false);});
    return()=>{cancelled=true;};
  },[companyId,current?.activeDimension,current?.dateFrom,current?.dateTo,current?.filters.locationId,current?.filters.productId,current?.filters.categoryId,current?.filters.customerId,current?.filters.supplierId,current?.metricCode,page]);
  useEffect(()=>{
    if(!current||current.activeDimension)return;
    let cancelled=false;const request={asOf:current.asOf};const args={p_company_id:companyId,p_metric_code:current.metricCode,p_date_from:current.dateFrom,p_date_to:current.dateTo,p_location_id:current.filters.locationId||null,p_product_id:current.filters.productId||null,p_customer_id:current.filters.customerId||null,p_supplier_id:current.filters.supplierId||null,p_as_of_date:request.asOf??null,p_page:page,p_page_size:25};
    void Promise.resolve().then(async()=>{setRecordsLoading(true);setRecordsError(null);setRecords(null);let response=await getSupabaseClient().rpc("bi_get_drilldown_v2",args);
      if(response.error&&/bi_get_drilldown_v2|schema cache|could not find/i.test(response.error.message)){
        const {p_as_of_date:_,...legacyArgs}=args;void _;response=await getSupabaseClient().rpc("bi_get_drilldown",legacyArgs);
      }if(cancelled)return;if(response.error)setRecordsError(response.error.message);else setRecords(response.data as Drilldown);setRecordsLoading(false);});
    return()=>{cancelled=true;};
  },[companyId,current,page]);
  const meta=current?METRICS[current.metricCode]:null;
  const sourceCurrency=investigation?.currency_code??currencyCode;
  const advance=(factor:InvestigationFactor)=>{
    if(!current?.activeDimension)return;
    const dimension=current.activeDimension;const filters={...current.filters};
    if(dimension==="location")filters.locationId=factor.group_key;
    if(dimension==="category"){
      if(factor.group_key==="uncategorized"){setCurrent({...current,activeDimension:null,path:[...current.path,{dimension,id:factor.group_key,label:factor.group_label}],level:current.level+1});return;}
      filters.categoryId=factor.group_key;
    }
    if(dimension==="product")filters.productId=factor.group_key;
    if(dimension==="customer")filters.customerId=factor.group_key;
    if(dimension==="supplier")filters.supplierId=factor.group_key;
    setPage(1);setCurrent({...current,filters,path:[...current.path,{dimension,id:factor.group_key,label:factor.group_label}],activeDimension:nextInvestigationDimension(current.metricCode,dimension),level:current.level+1});
  };
  const backTo=(index:number)=>{
    if(!current)return;const path=current.path.slice(0,index);const filters={...current.filters,locationId:"",categoryId:"",productId:"",customerId:"",supplierId:""};
    path.forEach(crumb=>{if(crumb.dimension==="location")filters.locationId=crumb.id;if(crumb.dimension==="category")filters.categoryId=crumb.id;if(crumb.dimension==="product")filters.productId=crumb.id;if(crumb.dimension==="customer")filters.customerId=crumb.id;if(crumb.dimension==="supplier")filters.supplierId=crumb.id;});
    setPage(1);setCurrent({...current,filters,path,activeDimension:path.length?nextInvestigationDimension(current.metricCode,path[path.length-1].dimension):(INVESTIGATION_DIMENSIONS[current.metricCode]?.[0]??null),level:path.length});
  };
  return <BiDrawer open={Boolean(context)} onOpenChange={open=>!open&&onClose()} className="bi-investigation-drawer" eyebrow="Investigación contextual" title={meta?`Explicar · ${meta.label}`:"Investigación de métrica"} description="Evidencia descriptiva: los factores muestran cómo se distribuye el cambio; no prueban causalidad." footer={records?.source_path?<Button variant="secondary" onClick={()=>router.push(records.source_path)}>Abrir módulo de origen <ChevronRight size={14}/></Button>:undefined}>
    {!current?null:<div className="bi-investigation">
      <nav className="bi-investigation__breadcrumbs" aria-label="Ruta de investigación"><button type="button" onClick={()=>backTo(0)}>{meta?.label??current.metricCode}</button>{current.path.map((crumb,index)=><span key={`${crumb.dimension}:${crumb.id}`}><ChevronRight size={13}/><button type="button" onClick={()=>backTo(index+1)}>{crumb.label}</button></span>)}</nav>
      <div className="bi-investigation__context" role="status"><span>Periodo {formatSourceDate(current.dateFrom)}–{formatSourceDate(current.dateTo)}</span><span>Comparación equivalente anterior</span>{current.path.length>0&&<span>{current.path.length} filtro{current.path.length===1?"":"s"} heredado{current.path.length===1?"":"s"}</span>}</div>
      {current.activeDimension?<>
        {analysisLoading?<BiState kind="loading" title="Calculando contribuciones…" description="La agregación y la reconciliación se hacen en servidor."/>:analysisError?<><BiState kind="partial" title="Desglose no disponible" description={`${analysisError} Puedes continuar con los registros canónicos mientras se aplica la ampliación de BI.`}/><Button variant="secondary" size="sm" onClick={()=>{setPage(1);setCurrent({...current,activeDimension:null});}}>Ver registros de respaldo <ChevronRight size={13}/></Button></>:investigation&&<>
          <section className="bi-investigation__summary" aria-label="Resumen de variación"><div><span>Actual</span><strong>{formatMetric({code:current.metricCode,available:true,value:investigation.summary.current_value},sourceCurrency)}</strong></div><div><span>Anterior</span><strong>{formatMetric({code:current.metricCode,available:true,value:investigation.summary.previous_value},sourceCurrency)}</strong></div><div><span>Variación</span><strong className={investigation.summary.change_value<0?"is-negative":"is-positive"}>{formatDifference({code:current.metricCode,available:true,value:investigation.summary.current_value},investigation.summary.change_value,sourceCurrency)}</strong></div></section>
          <section className="bi-investigation__definition"><strong>{investigation.metric.name} · evidencia y método</strong><p>{investigation.metric.formula}</p><small>{investigation.metric.source} · {investigation.metric.limitations}</small></section>
          <ContributionChart factors={investigation.chart} metricCode={current.metricCode} currencyCode={sourceCurrency} dimension={current.activeDimension} onSelect={advance}/>
          <section className="bi-investigation__factors" aria-labelledby="bi-investigation-factors-title"><header><div><span className="eyebrow">Desglose por {INVESTIGATION_LABEL[current.activeDimension].toLowerCase()}</span><h2 id="bi-investigation-factors-title">Factores de mayor impacto</h2><p>Ordenados por impacto absoluto. “Mejoró” y “deterioró” describen el movimiento de la métrica, no una causa comprobada.</p></div></header><AnalyticsTable caption="Contribuciones al cambio de la métrica"><thead><tr><th>Factor</th><th>Actual</th><th>Anterior</th><th>Variación</th><th>Participación</th><th>Contribución</th><th>Estado</th><th><span className="sr-only">Avanzar</span></th></tr></thead><tbody>{investigation.factors.map(factor=><tr key={factor.group_key}><td><strong>{factor.group_label}</strong></td><td>{formatMetric({code:current.metricCode,available:true,value:factor.current_value},sourceCurrency)}</td><td>{formatMetric({code:current.metricCode,available:true,value:factor.previous_value},sourceCurrency)}</td><td className={factor.change_value<0?"is-negative":"is-positive"}>{formatDifference({code:current.metricCode,available:true,value:factor.current_value},factor.change_value,sourceCurrency)}</td><td>{factor.current_share_percent==null?"—":`${factor.current_share_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`}</td><td>{factor.contribution_percent==null?"—":`${factor.contribution_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`}</td><td><Badge tone={factor.status==="deteriorated"?"warning":factor.status==="improved"?"success":"neutral"}>{factor.status==="deteriorated"?"Deterioró":factor.status==="improved"?"Mejoró":"Sin cambio significativo"}</Badge></td><td><Button size="sm" variant="ghost" onClick={()=>advance(factor)}>{nextInvestigationDimension(current.metricCode,current.activeDimension!)?"Desglosar":"Ver registros"} <ChevronRight size={13}/></Button></td></tr>)}</tbody></AnalyticsTable><DataPagination page={investigation.pagination.page} pageSize={investigation.pagination.page_size} total={investigation.pagination.total} onChange={setPage} label="factores"/><p className="bi-investigation__reconciliation"><strong>{investigation.reconciliation.reconciled?"Reconciliado":"Pendiente de reconciliar"}.</strong> Variación total {formatDifference({code:current.metricCode,available:true,value:investigation.summary.current_value},investigation.reconciliation.total_change,sourceCurrency)}; todos los factores suman el mismo valor. Esta página representa {formatDifference({code:current.metricCode,available:true,value:investigation.summary.current_value},investigation.reconciliation.visible_page_change,sourceCurrency)}.</p></section>
          <section className="bi-investigation__trace"><Database size={15}/><span><strong>Trazabilidad</strong>{investigation.trace.query} · {investigation.trace.sources} · cálculo server-side.</span></section>
        </>}
      </>:recordsLoading?<BiState kind="loading" title="Cargando registros de respaldo…"/>:recordsError?<BiState kind="partial" title="Evidencia parcial" description={recordsError}/>:records?.items.length?<section className="bi-investigation__records"><header><span className="eyebrow">Evidencia</span><h2>Registros de respaldo</h2><p>Operaciones canónicas, ordenadas y paginadas en servidor.</p></header><AnalyticsTable className="bi-drill-table" caption="Registros que respaldan la métrica"><thead><tr><th>Fecha</th><th>Origen</th><th>Contexto</th><th className="number-cell">Importe</th></tr></thead><tbody>{records.items.map(item=><tr key={item.id}><td>{formatSourceDate(item.occurred_at)}</td><td><strong>{item.party??item.location_name??"Operación"}</strong></td><td>{item.detail??item.sale_type??item.location_name??"—"}</td><td className="number-cell">{formatMoney(item.amount,sourceCurrency)}</td></tr>)}</tbody></AnalyticsTable><DataPagination page={records.pagination.page} pageSize={records.pagination.page_size} total={records.pagination.total} onChange={setPage} label="registros"/></section>:records?<BiState kind="empty" title="Sin registros de respaldo" description="No hay operaciones canónicas con este contexto."/>:null}
      {current.activeDimension&&<aside className="bi-investigation__next"><strong>Siguiente paso</strong><span>Selecciona un factor para añadirlo al contexto y seguir hasta los registros de respaldo.</span></aside>}
    </div>}
  </BiDrawer>;
}

function ContributionChart({ factors, metricCode, currencyCode, dimension, onSelect }: { factors: InvestigationFactor[]; metricCode:string; currencyCode?:string|null; dimension:InvestigationDimension; onSelect:(factor:InvestigationFactor)=>void }) {
  const data=factors.map(factor=>({...factor,label:factor.group_label}));
  const tooltip=(props:unknown)=>{const {active,payload}=props as {active?:boolean;payload?:ReadonlyArray<{payload?:InvestigationFactor}>};const factor=payload?.[0]?.payload;if(!active||!factor)return null;return <div className="bi-recharts-tooltip"><strong>{factor.group_label}</strong><span>Actual <b>{formatMetric({code:metricCode,available:true,value:factor.current_value},currencyCode)}</b></span><span>Anterior <b>{formatMetric({code:metricCode,available:true,value:factor.previous_value},currencyCode)}</b></span><span>Contribución <b>{factor.contribution_percent==null?"—":`${factor.contribution_percent.toLocaleString("es-MX",{maximumFractionDigits:1})}%`}</b></span><small>Selecciona para desglosar o ver evidencia.</small></div>;};
  const chartHeight=Math.min(264,Math.max(152,data.length*34+28));
  return <ChartContainer className="bi-chart-card bi-contribution-chart" eyebrow="Explicación descriptiva" title={`Contribución por ${INVESTIGATION_LABEL[dimension].toLowerCase()}`} description="Barras divergentes: arriba mejora la métrica; abajo la deteriora."><div className="bi-recharts-ranking"><ResponsiveContainer width="100%" height={chartHeight}><BarChart data={data} layout="vertical" margin={{top:4,right:30,left:4,bottom:8}} onClick={(event:unknown)=>{const factor=(event as {activePayload?:Array<{payload?:InvestigationFactor}>})?.activePayload?.[0]?.payload;if(factor)onSelect(factor);}}><CartesianGrid horizontal={false} stroke="var(--bi-border)"/><XAxis type="number" tickCount={4} tickMargin={8} tickFormatter={value=>formatDifference({code:metricCode,available:true,value:Number(value)},Number(value),currencyCode)} tickLine={false} axisLine={false}/><YAxis dataKey="label" type="category" width={118} tickLine={false} axisLine={false}/><RechartsTooltip content={tooltip}/><Bar dataKey="change_value" name="Variación" fill="var(--accent)" maxBarSize={24} radius={3} isAnimationActive={false}/></BarChart></ResponsiveContainer></div></ChartContainer>;
}
