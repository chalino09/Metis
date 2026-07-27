"use client";

import { AlertCircle,CheckCircle2,ChevronRight,LoaderCircle,Plus,RefreshCw } from "lucide-react";
import { useCallback,useEffect,useMemo,useState,type FormEvent } from "react";
import { DataPagination,DataState,PageHeading,Table } from "@/app/components/ui/data";
import { Badge,Button,Input,Modal,Select } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";
import { useSatrapy } from "@/app/components/SatrapyProvider";

type BudgetStatus="draft"|"approved"|"superseded";
type ScopeType="company"|"location"|"responsible"|"category"|"location_category"|"responsible_category";
type BudgetRow={
  id:string;name:string;description?:string|null;metric_code:"net_sales"|"gross_margin"|"units_sold";
  period_type:"monthly"|"quarterly"|"annual";period_start:string;period_end:string;scope_type:ScopeType;
  location_id?:string|null;collaborator_id?:string|null;category_id?:string|null;
  scope_label:string;value:number;unit_code:string;status:BudgetStatus;budget_kind:"independent"|"distribution";
  actual_available:boolean;actual_value:number|null;actual_reason?:string|null;attainment_percent:number|null;remaining_value:number|null;projected_value:number|null;
  assigned_value:number|null;pending_distribution:number|null;distribution_excess:number|null;parent_version_id?:string|null;
};
type PageResult={items:BudgetRow[];pagination:{page:number;page_size:number;total:number};updated_at:string};
type Option={id:string;label:string;secondary?:string};
type MonthlyAllocation={month:string;value:string};
type Detail={version:BudgetRow;actual:{available:boolean;value:number|null;reason?:string};previous_period:{available:boolean;value:number|null};series:Array<{date:string;actual:number|null;budget_pace:number}>;history:Array<{id:string;action:string;reason:string;occurred_at:string}>;distributions:BudgetRow[]};

const METRICS=[
  {value:"net_sales",label:"Venta neta"},{value:"gross_margin",label:"Margen"},{value:"units_sold",label:"Unidades vendidas"},
];
const PERIODS=[{value:"monthly",label:"Mensual"},{value:"quarterly",label:"Trimestral"},{value:"annual",label:"Anual"}];
const SCOPES=[
  {value:"company",label:"Empresa"},{value:"location",label:"Ubicación"},{value:"responsible",label:"Responsable"},
  {value:"category",label:"Categoría"},{value:"location_category",label:"Ubicación + categoría"},{value:"responsible_category",label:"Responsable + categoría"},
];
const METRIC_LABEL:Record<string,string>={net_sales:"Venta neta",gross_margin:"Margen",units_sold:"Unidades vendidas"};
const STATUS_LABEL:Record<BudgetStatus,string>={draft:"Borrador",approved:"Aprobado",superseded:"Sustituido"};

function firstOfMonth(){const d=new Date();return`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}-01`;}
function periodStart(value:string,period:"monthly"|"quarterly"|"annual"){const date=new Date(`${value}T12:00:00`);if(period==="annual")date.setMonth(0);if(period==="quarterly")date.setMonth(Math.floor(date.getMonth()/3)*3);date.setDate(1);return date.toISOString().slice(0,10);}
function allocationMonths(period:"monthly"|"quarterly"|"annual",start:string){const count=period==="annual"?12:period==="quarterly"?3:1;const first=new Date(`${periodStart(start,period)}T12:00:00`);return Array.from({length:count},(_,index)=>{const date=new Date(first);date.setMonth(first.getMonth()+index);return date.toISOString().slice(0,10);});}
function monthLabel(value:string){return new Intl.DateTimeFormat("es-MX",{month:"long",year:"numeric"}).format(new Date(`${value}T12:00:00`));}
function parseAmountInput(value:string){return Number(value.replace(/,/g,""))||0;}
function normalizeAmountInput(value:string){const cleaned=value.replace(/,/g,"").replace(/[^\d.]/g,"");if(!cleaned)return"";const hasDecimal=cleaned.includes(".");const[whole,...fractionParts]=cleaned.split(".");const normalizedWhole=(whole.replace(/^0+(?=\d)/,"")||"0");const fraction=fractionParts.join("").slice(0,6);return hasDecimal?`${normalizedWhole}.${fraction}`:normalizedWhole;}
function formatAmountInput(value:string){if(!value)return"";const hasDecimal=value.includes(".");const[whole="0",fraction=""]=value.split(".");const grouped=(whole||"0").replace(/\B(?=(\d{3})+(?!\d))/g,",");return hasDecimal?`${grouped}.${fraction}`:grouped;}
function evenAllocations(period:"monthly"|"quarterly"|"annual",start:string,total:string){const months=allocationMonths(period,start),amount=parseAmountInput(total),base=Math.floor(amount/months.length*100)/100;return months.map((month,index)=>({month,value:String(index===months.length-1?Math.round((amount-base*(months.length-1))*100)/100:base)}));}
function amount(value:number|null|undefined,unit:string){if(value==null)return"—";return unit==="unit"?value.toLocaleString("es-MX",{maximumFractionDigits:2}):new Intl.NumberFormat("es-MX",{style:"currency",currency:unit,maximumFractionDigits:0}).format(value);}
function percent(value:number|null|undefined){return value==null?"—":`${value.toLocaleString("es-MX",{maximumFractionDigits:1})}%`;}

function AmountInput({value,onValueChange,required=false,ariaLabel}:{value:string;onValueChange:(next:string)=>void;required?:boolean;ariaLabel:string}){return <Input type="text" inputMode="decimal" value={formatAmountInput(value)} onChange={event=>onValueChange(normalizeAmountInput(event.target.value))} required={required} aria-label={ariaLabel}/>;}

export function BiBudgetsModule({companyId}:{companyId:string}){
  const{appState}=useSatrapy();const permissions=appState?.membership.permissions??[];const has=(code:string)=>permissions.includes("*")||permissions.includes(code);
  const[status,setStatus]=useState<BudgetStatus|"all">("approved");
  const[page,setPage]=useState(1);const[data,setData]=useState<PageResult|null>(null);const[loading,setLoading]=useState(false);const[error,setError]=useState<string|null>(null);
  const[editor,setEditor]=useState<{row?:BudgetRow;parent?:BudgetRow;replace?:BudgetRow}|null>(null);const[selected,setSelected]=useState<string|null>(null);
  const[detail,setDetail]=useState<Detail|null>(null);const[detailLoading,setDetailLoading]=useState(false);
  const[approve,setApprove]=useState<BudgetRow|null>(null);const[approvalReason,setApprovalReason]=useState("");const[actionLoading,setActionLoading]=useState(false);

  const load=useCallback(async(nextPage=page)=>{
    setLoading(true);setError(null);
    const{data:result,error:rpcError}=await getSupabaseClient().rpc("bi_list_budget_performance",{
      p_company_id:companyId,p_status:status==="all"?null:status,p_from:null,p_to:null,p_page:nextPage,p_page_size:25,
    });
    if(rpcError)setError(rpcError.message);else setData(result as PageResult);setLoading(false);
  },[companyId,page,status]);
  useEffect(()=>{let active=true;void Promise.resolve().then(()=>{if(active)return load();});return()=>{active=false;};},[load]);
  useEffect(()=>{if(!selected)return;let active=true;void Promise.resolve().then(async()=>{if(!active)return;setDetailLoading(true);const{data:result,error:rpcError}=await getSupabaseClient().rpc("bi_get_budget_detail",{p_company_id:companyId,p_version_id:selected});if(active){setDetailLoading(false);if(!rpcError)setDetail(result as Detail);}});return()=>{active=false;};},[companyId,selected]);
  async function approveVersion(event:FormEvent){event.preventDefault();if(!approve)return;setActionLoading(true);const{error:rpcError}=await getSupabaseClient().rpc("bi_approve_budget_version",{p_company_id:companyId,p_version_id:approve.id,p_reason:approvalReason});setActionLoading(false);if(rpcError){setError(rpcError.message);return;}setApprove(null);setApprovalReason("");await load();}

  return <section className="content-frame module-page bi-budgets">
    <PageHeading eyebrow="Business Intelligence" title="Metas y presupuestos" description="Objetivos comerciales versionados contra resultados canónicos. Las distribuciones conservan su jerarquía y nunca se suman dos veces con el presupuesto superior." action={<div className="bi-heading-actions">{has("create_bi_budget_drafts")&&<Button variant="primary" size="sm" onClick={()=>setEditor({})}><Plus size={14}/> Nuevo presupuesto</Button>}<Button size="sm" onClick={()=>void load()}><RefreshCw size={14}/> Actualizar</Button></div>}/>
    <div className="bi-budget-toolbar"><Select ariaLabel="Estado del presupuesto" value={status} onValueChange={value=>{setStatus(value as BudgetStatus|"all");setPage(1);}} options={[{value:"approved",label:"Aprobados"},{value:"draft",label:"Borradores"},{value:"superseded",label:"Sustituidos"},{value:"all",label:"Todos"}]}/><span>{data?.pagination.total.toLocaleString("es-MX")??0} versiones dentro de tu alcance</span></div>
    <DataState loading={loading&&!data} error={error} hasData={data?.items.length??0} empty="Aún no hay presupuestos en este estado y alcance." emptyAction={has("create_bi_budget_drafts")?<Button size="sm" onClick={()=>setEditor({})}>Crear primer presupuesto</Button>:undefined}>
        <Table className="bi-budget-table"><thead><tr><th>Presupuesto</th><th>Alcance</th><th>Periodo</th><th>Presupuesto</th><th>Resultado</th><th>Cumplimiento</th><th>Proyección</th><th>Distribución</th><th>Estado</th><th/></tr></thead><tbody>{data?.items.map(row=><tr key={row.id}>
          <td><button className="table-link" onClick={()=>setSelected(row.id)}><strong>{row.name}</strong><small>{METRIC_LABEL[row.metric_code]} · v{String((row as BudgetRow&{version?:number}).version??1)}</small></button></td>
          <td>{row.scope_label}<small>{row.budget_kind==="distribution"?"Distribución":"Independiente"}</small></td>
          <td>{row.period_start}<small>al {row.period_end}</small></td><td><strong>{amount(row.value,row.unit_code)}</strong></td>
          <td>{row.actual_available?amount(row.actual_value,row.unit_code):<span title={row.actual_reason??undefined}>No disponible</span>}</td>
          <td><strong>{percent(row.attainment_percent)}</strong><small>Pendiente {amount(row.remaining_value,row.unit_code)}</small></td><td>{amount(row.projected_value,row.unit_code)}</td>
          <td>{row.budget_kind==="independent"?<><span>Asignado {amount(row.assigned_value,row.unit_code)}</span><small className={Number(row.distribution_excess)>0?"is-danger":""}>{Number(row.distribution_excess)>0?`Excedente ${amount(row.distribution_excess,row.unit_code)}`:`Pendiente ${amount(row.pending_distribution,row.unit_code)}`}</small></>:"—"}</td>
          <td><Badge tone={row.status==="approved"?"success":row.status==="draft"?"warning":"neutral"}>{STATUS_LABEL[row.status]}</Badge></td>
          <td><div className="table-actions">{row.status==="draft"&&has("create_bi_budget_drafts")&&<Button size="sm" variant="ghost" onClick={()=>setEditor({row})}>Editar</Button>}{row.status==="draft"&&has("approve_bi_budgets")&&<Button size="sm" variant="ghost" onClick={()=>setApprove(row)}>Aprobar</Button>}{row.status==="approved"&&has("create_bi_budget_drafts")&&<Button size="sm" variant="ghost" onClick={()=>setEditor({replace:row})}>Sustituir</Button>}<button type="button" className="table-link" aria-label={`Abrir ${row.name}`} onClick={()=>setSelected(row.id)}><ChevronRight size={15}/></button></div></td>
        </tr>)}</tbody></Table>
    </DataState>
    {data&&<DataPagination page={page} total={data.pagination.total} pageSize={25} label="versiones" onChange={next=>{setPage(next);void load(next);}}/>}
    {editor&&<BudgetEditor key={`${editor.row?.id??editor.replace?.id??"new"}:${editor.parent?.id??"root"}`} companyId={companyId} state={editor} onClose={()=>setEditor(null)} onSaved={()=>{setEditor(null);setStatus("draft");void load(1);}}/>}
    <Modal open={Boolean(approve)} onOpenChange={open=>!open&&setApprove(null)} eyebrow="Aprobación inmutable" title={`Aprobar ${approve?.name??"presupuesto"}`} description="Una versión aprobada no se edita destructivamente; cualquier cambio posterior crea una sustitución.">
      <form className="bi-save-form" onSubmit={approveVersion}><label>Motivo obligatorio<Input value={approvalReason} onChange={event=>setApprovalReason(event.target.value)} minLength={5} required/></label><Button type="submit" variant="primary" loading={actionLoading} disabled={approvalReason.trim().length<5}><CheckCircle2 size={15}/> Aprobar versión</Button></form>
    </Modal>
    <BudgetDetail detail={detail} loading={detailLoading} companyId={companyId} open={Boolean(selected)} canDistribute={has("manage_bi_budget_distributions")} onClose={()=>setSelected(null)} onDistribute={row=>{setSelected(null);setEditor({parent:row});}}/>
  </section>;
}

function BudgetEditor({companyId,state,onClose,onSaved}:{companyId:string;state:{row?:BudgetRow;parent?:BudgetRow;replace?:BudgetRow};onClose:()=>void;onSaved:()=>void}){
  const row=state.row,parent=state.parent,base=row??state.replace;const[metric,setMetric]=useState(base?.metric_code??parent?.metric_code??"net_sales");
  const[period,setPeriod]=useState(base?.period_type??parent?.period_type??"monthly");const[start,setStart]=useState(base?.period_start??parent?.period_start??firstOfMonth());
  const[scope,setScope]=useState<ScopeType>(base?.scope_type??(parent?.scope_type==="company"?"location":parent?"location_category":"company"));
  const[name,setName]=useState(base?.name??"");const[description,setDescription]=useState(base?.description??"");const[value,setValue]=useState(String(base?.value??""));
  const[unit,setUnit]=useState(base?.unit_code??parent?.unit_code??"MXN");const[reason,setReason]=useState("");const[location,setLocation]=useState<Option|null>(base?.location_id?{id:base.location_id,label:base.scope_label}:null);const[responsible,setResponsible]=useState<Option|null>(base?.collaborator_id?{id:base.collaborator_id,label:base.scope_label}:null);const[category,setCategory]=useState<Option|null>(base?.category_id?{id:base.category_id,label:base.scope_label}:null);
  const[saving,setSaving]=useState(false);const[error,setError]=useState<string|null>(null);
  const[allocations,setAllocations]=useState<MonthlyAllocation[]>(()=>evenAllocations(period,start,String(base?.value??"")));
  useEffect(()=>{const versionId=row?.id??state.replace?.id;if(!versionId)return;let active=true;void getSupabaseClient().rpc("bi_get_budget_monthly_allocations",{p_company_id:companyId,p_version_id:versionId}).then(({data})=>{const items=(data??[])as Array<{month_start:string;value:number}>;if(active&&items.length)setAllocations(items.map(item=>({month:item.month_start,value:String(item.value)})));});return()=>{active=false;};},[companyId,row?.id,state.replace?.id]);
  const allowedScopes=parent?(parent.scope_type==="company"?SCOPES.filter(item=>item.value==="location"):SCOPES.filter(item=>["location_category","responsible"].includes(item.value))):SCOPES;
  const needsLocation=scope==="location"||scope==="location_category",needsResponsible=scope==="responsible"||scope==="responsible_category",needsCategory=scope==="category"||scope==="location_category"||scope==="responsible_category";
  const hasMonthlyBreakdown=!parent&&period!=="monthly";const allocated=allocations.reduce((sum,item)=>sum+parseAmountInput(item.value),0),total=parseAmountInput(value),difference=total-allocated;
  function changePeriod(next:"monthly"|"quarterly"|"annual"){const nextStart=periodStart(start,next);setPeriod(next);setStart(nextStart);setAllocations(evenAllocations(next,nextStart,value));}
  function updateAllocation(index:number,next:string){setAllocations(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,value:next}:item));}
  function copyPrevious(index:number,increase=false){if(index===0)return;const previous=parseAmountInput(allocations[index-1]?.value??"");updateAllocation(index,String(Math.round(previous*(increase?1.1:1)*100)/100));}
  async function save(event:FormEvent){event.preventDefault();setSaving(true);setError(null);const{error:rpcError}=await getSupabaseClient().rpc("bi_save_budget_draft",{
    p_company_id:companyId,p_version_id:row?.id??null,p_name:name,p_description:description,p_metric_code:metric,p_period_type:period,p_period_start:start,
    p_scope_type:scope,p_location_id:scope==="location_category"&&parent?.scope_type==="location"?parent.location_id:location?.id??null,p_collaborator_id:responsible?.id??null,p_category_id:category?.id??null,
    p_value:parseAmountInput(value),p_unit_code:metric==="units_sold"?"unit":unit,p_owner_user_id:null,p_parent_version_id:parent?.id??null,p_replace_version_id:state.replace?.id??null,p_reason:reason,
    p_monthly_allocations:hasMonthlyBreakdown?allocations.map(item=>({month_start:item.month,value:parseAmountInput(item.value)})):[],
  });setSaving(false);if(rpcError){setError(rpcError.message);return;}onSaved();}
  return <Modal open onOpenChange={open=>!open&&onClose()} eyebrow={parent?"Distribución jerárquica":state.replace?"Nueva versión de sustitución":"Meta comercial"} title={row?"Modificar borrador":parent?`Distribuir ${parent.name}`:state.replace?`Sustituir ${state.replace.name}`:"Crear meta o presupuesto"} description="Elige qué medir, a quién asignarlo y cómo distribuirlo. Todo queda como borrador auditable antes de aprobarse.">
    <form className="bi-budget-form" onSubmit={save}><section className="bi-budget-step span-2"><span>1. Definición de la meta</span><div><label>Métrica<Select ariaLabel="Métrica" value={metric} onValueChange={next=>{setMetric(next as typeof metric);if(next==="units_sold")setUnit("unit");}} options={METRICS} disabled={Boolean(parent)}/></label><label>Nombre de la meta<Input value={name} onChange={event=>setName(event.target.value)} placeholder="Ej. Meta anual de ventas" required maxLength={140}/></label></div></section>
      <section className="bi-budget-step span-2"><span>2. Asignación</span><div className="bi-assignment-options">{allowedScopes.map(item=><button key={item.value} type="button" className={scope===item.value?"is-active":""} onClick={()=>{setScope(item.value as ScopeType);setLocation(null);setResponsible(null);setCategory(null);}} disabled={Boolean(row)}>{item.value==="company"?"Empresa completa":item.value==="location"?"Sucursal":item.value==="responsible"?"Ingeniero de campo":item.value==="category"?"Categoría":item.label}</button>)}</div></section>
      {needsLocation&&<ScopePicker companyId={companyId} type="location" label="Selecciona sucursal" value={location} onChange={setLocation}/>}
      {needsResponsible&&<ScopePicker companyId={companyId} type="responsible" label="Selecciona ingeniero de campo" value={responsible} onChange={setResponsible}/>}
      {needsCategory&&<ScopePicker companyId={companyId} type="category" label="Selecciona categoría" value={category} onChange={setCategory}/>}
      <section className="bi-budget-step span-2"><span>3. Periodo y monto</span><div><label>Periodo<div className="bi-period-options">{PERIODS.map(item=><button key={item.value} type="button" className={period===item.value?"is-active":""} onClick={()=>changePeriod(item.value as typeof period)} disabled={Boolean(parent)}>{item.label}</button>)}</div></label><label>Inicio<Input type="date" value={start} onChange={event=>{const next=periodStart(event.target.value,period);setStart(next);setAllocations(evenAllocations(period,next,value));}} required disabled={Boolean(parent)}/><small>Aplica desde {monthLabel(periodStart(start,period))}.</small></label></div></section>
      <label>Meta total<AmountInput value={value} onValueChange={next=>{setValue(next);if(allocations.every(item=>parseAmountInput(item.value)===0))setAllocations(evenAllocations(period,start,next));}} required ariaLabel="Meta total"/></label><label>Moneda o unidad<Input value={metric==="units_sold"?"unit":unit} onChange={event=>setUnit(event.target.value.toUpperCase())} maxLength={3} disabled={metric==="units_sold"} required/></label>
      {hasMonthlyBreakdown&&<section className="bi-allocation-editor span-2"><header><div><strong>Distribución por mes</strong><small>Parte de una distribución uniforme y ajusta la estacionalidad.</small></div><Button size="sm" type="button" variant="secondary" onClick={()=>setAllocations(evenAllocations(period,start,value))}>Distribuir por igual</Button></header><div className="bi-allocation-grid">{allocations.map((item,index)=><label key={item.month}><span>{monthLabel(item.month)}</span><AmountInput value={item.value} onValueChange={next=>updateAllocation(index,next)} ariaLabel={`Importe para ${monthLabel(item.month)}`}/>{index>0&&<div><button type="button" onClick={()=>copyPrevious(index)}>Copiar anterior</button><button type="button" onClick={()=>copyPrevious(index,true)}>+10%</button></div>}</label>)}</div><footer className={Math.abs(difference)<0.005?"is-balanced":""}><span>{Math.abs(difference)<0.005?"Distribución completa":difference>0?`Faltan ${amount(difference,metric==="units_sold"?"unit":unit)} por distribuir`:`Excedente de ${amount(Math.abs(difference),metric==="units_sold"?"unit":unit)}: reduce meses o actualiza la meta total`}</span><strong>{amount(allocated,metric==="units_sold"?"unit":unit)} de {amount(total,metric==="units_sold"?"unit":unit)}</strong></footer></section>}
      <label className="span-2">Descripción opcional<Input value={description} onChange={event=>setDescription(event.target.value)} placeholder="Qué decisión comercial apoya esta meta"/></label>
      <label className="span-2">Motivo obligatorio<Input value={reason} onChange={event=>setReason(event.target.value)} minLength={5} required/></label>{error&&<div className="form-error span-2">{error}</div>}<div className="drawer-actions span-2"><Button onClick={onClose}>Cancelar</Button><Button type="submit" variant="primary" loading={saving} disabled={hasMonthlyBreakdown&&Math.abs(difference)>=0.005}>Guardar borrador</Button></div>
    </form>
  </Modal>;
}

function ScopePicker({companyId,type,label,value,onChange}:{companyId:string;type:"location"|"responsible"|"category";label:string;value:Option|null;onChange:(value:Option|null)=>void}){
  const[query,setQuery]=useState("");const[options,setOptions]=useState<Option[]>([]);const[loading,setLoading]=useState(false);
  useEffect(()=>{const timer=window.setTimeout(async()=>{setLoading(true);const{data}=await getSupabaseClient().rpc("bi_search_budget_scope_options",{p_company_id:companyId,p_scope:type,p_query:query||null,p_page:1,p_page_size:20});setOptions(((data as{items?:Option[]}|null)?.items??[]));setLoading(false);},180);return()=>window.clearTimeout(timer);},[companyId,query,type]);
  return <label>{label}<div className="bi-budget-picker"><Input value={value?.label??query} onChange={event=>{onChange(null);setQuery(event.target.value);}} placeholder={`Buscar ${label.toLowerCase()}`} required/><div>{loading?<span><LoaderCircle className="spin" size={13}/> Buscando…</span>:!value&&options.map(option=><button type="button" key={option.id} onClick={()=>{onChange(option);setQuery("");}}><strong>{option.label}</strong><small>{option.secondary}</small></button>)}</div></div></label>;
}

function BudgetDetail({detail,loading,companyId,open,canDistribute,onClose,onDistribute}:{detail:Detail|null;loading:boolean;companyId:string;open:boolean;canDistribute:boolean;onClose:()=>void;onDistribute:(row:BudgetRow)=>void}){
  const[drill,setDrill]=useState<Array<{id:string;completed_at:string;location_name:string;responsible_name:string;value:number}>|null>(null);
  async function loadDrill(){if(!detail)return;const{data}=await getSupabaseClient().rpc("bi_budget_drilldown",{p_company_id:companyId,p_version_id:detail.version.id,p_page:1,p_page_size:25});setDrill(((data as{items?:typeof drill}|null)?.items??[])as NonNullable<typeof drill>);}
  const max=useMemo(()=>Math.max(...(detail?.series.map(point=>Math.max(point.actual??0,point.budget_pace))??[1]),1),[detail]);
  return <Modal open={open} onOpenChange={value=>!value&&onClose()} eyebrow="Presupuesto contra resultado" title={detail?.version.name??"Detalle"} description="El resultado se recalcula desde el catálogo BI y conserva acceso a las operaciones que lo explican.">
    {loading?<div className="bi-drill-state"><LoaderCircle className="spin" size={16}/> Calculando…</div>:detail&&<div className="bi-budget-detail">
      <div className="bi-budget-kpis"><article><span>Presupuesto</span><strong>{amount(detail.version.value,detail.version.unit_code)}</strong></article><article><span>Resultado</span><strong>{detail.actual.available?amount(detail.actual.value,detail.version.unit_code):"—"}</strong></article><article><span>Periodo anterior</span><strong>{amount(detail.previous_period.value,detail.version.unit_code)}</strong></article></div>
      {!detail.actual.available&&<div className="bi-partial-state"><AlertCircle size={15}/><span>{detail.actual.reason}</span></div>}
      <div className="bi-budget-series">{detail.series.map(point=><div key={point.date} title={`${point.date}: ${amount(point.actual,detail.version.unit_code)}`}><i style={{height:`${((point.actual??0)/max)*100}%`}}/><b style={{height:`${(point.budget_pace/max)*100}%`}}/></div>)}</div>
      {detail.version.budget_kind==="independent"&&canDistribute&&detail.version.status==="approved"&&<Button size="sm" onClick={()=>onDistribute(detail.version)}>Distribuir presupuesto</Button>}
      <section><header><h3>Historial inmutable</h3></header><ul className="history-list">{detail.history.map(event=><li key={event.id}><strong>{event.action}</strong><span>{new Date(event.occurred_at).toLocaleString("es-MX")}</span><small>{event.reason}</small></li>)}</ul></section>
      <Button size="sm" onClick={()=>void loadDrill()} disabled={!detail.actual.available}>Ver operaciones que explican el resultado</Button>
      {drill&&<Table><thead><tr><th>Fecha</th><th>Ubicación</th><th>Responsable</th><th>Resultado</th></tr></thead><tbody>{drill.map(item=><tr key={item.id}><td>{new Date(item.completed_at).toLocaleString("es-MX")}</td><td>{item.location_name}</td><td>{item.responsible_name}</td><td>{amount(item.value,detail.version.unit_code)}</td></tr>)}</tbody></Table>}
    </div>}
  </Modal>;
}
