"use client";

import {AlertTriangle,ArrowUpRight,Layers3,LoaderCircle,PackageSearch,Plus,Save,Truck,Warehouse,X} from "lucide-react";
import {useCallback,useEffect,useMemo,useRef,useState} from "react";
import {useRouter,useSearchParams} from "next/navigation";
import {DataPagination,PageHeading} from "@/app/components/ui/data";
import {Badge,Button,Input,Select} from "@/app/components/ui/primitives";
import {getSupabaseClient} from "@/app/lib/supabase";
import {useSatrapy} from "@/app/components/SatrapyProvider";

type NodeType="supplier"|"product"|"category";
type SupplierFilters={dateFrom:string;dateTo:string;locationId:string;categoryId:string;supplierId:string;productId:string;concentration:string};
type PeriodPreset="today"|"last7"|"last30"|"last90"|"thisMonth"|"previousMonth"|"thisQuarter"|"custom";
type NodeLabels={supplier:string;product:string;category:string};
type ProductExposure={product_id:string;label:string;sku:string|null;amount:number;concentration:number;supplier_count:number;metric_source:string};
type SupplierOverviewItem={supplier_id:string;label:string;code:string|null;total_amount:number;total_quantity:number;frequency:number;product_count:number;location_count:number;
  unique_product_count:number;high_dependency_product_count:number;max_concentration:number;top_products:ProductExposure[]};
type SupplierOverviewResult={items:SupplierOverviewItem[];pagination:{page:number;page_size:number;total:number};totals:{suppliers:number;amount:number;products:number;high_dependency_products:number;unique_supplier_products:number};
  currency_code:string|null;updated_at:string;period:{from:string;to:string};methodology:{amount:string;dependency:string;coverage:string};trace:Record<string,unknown>};

const PERIOD_OPTIONS=[
  {value:"today",label:"Hoy"},{value:"last7",label:"Últimos 7 días"},{value:"last30",label:"Últimos 30 días"},
  {value:"last90",label:"Últimos 90 días"},{value:"thisMonth",label:"Este mes"},{value:"previousMonth",label:"Mes anterior"},
  {value:"thisQuarter",label:"Este trimestre"},{value:"custom",label:"Periodo personalizado"},
] satisfies Array<{value:PeriodPreset;label:string}>;
const CONCENTRATION_LABELS:Record<string,string>={high:"Alta · ≥ 80%",medium:"Media · 50–79.9%",low:"Baja · < 50%"};

function iso(value:Date){return value.toISOString().slice(0,10);}
function emptyFilters():SupplierFilters{const to=new Date(),from=new Date(to);from.setDate(from.getDate()-89);return{dateFrom:iso(from),dateTo:iso(to),locationId:"",categoryId:"",supplierId:"",productId:"",concentration:""};}
function periodRange(preset:Exclude<PeriodPreset,"custom">){
  const today=new Date(),from=new Date(today),to=new Date(today);
  if(preset==="last7")from.setDate(from.getDate()-6);
  if(preset==="last30")from.setDate(from.getDate()-29);
  if(preset==="last90")from.setDate(from.getDate()-89);
  if(preset==="thisMonth")from.setDate(1);
  if(preset==="previousMonth"){from.setMonth(from.getMonth()-1,1);to.setDate(0);}
  if(preset==="thisQuarter")from.setMonth(Math.floor(from.getMonth()/3)*3,1);
  return{dateFrom:iso(from),dateTo:iso(to)};
}
function inferPeriod(filters:Pick<SupplierFilters,"dateFrom"|"dateTo">):PeriodPreset{
  const presets=(["today","last7","last30","last90","thisMonth","previousMonth","thisQuarter"]as const);
  return presets.find(preset=>{const range=periodRange(preset);return range.dateFrom===filters.dateFrom&&range.dateTo===filters.dateTo;})??"custom";
}
function overviewArgs(companyId:string,filters:SupplierFilters,page:number){return{
  p_company_id:companyId,p_date_from:filters.dateFrom,p_date_to:filters.dateTo,p_location_id:filters.locationId||null,p_category_id:filters.categoryId||null,
  p_supplier_id:filters.supplierId||null,p_product_id:filters.productId||null,p_concentration_level:filters.concentration||null,p_page:page,p_page_size:24,
};}
function money(value:number,currency:string|null){return currency?new Intl.NumberFormat("es-MX",{style:"currency",currency,maximumFractionDigits:0}).format(value):value.toLocaleString("es-MX",{maximumFractionDigits:1});}
function percentage(value:number){return new Intl.NumberFormat("es-MX",{style:"percent",maximumFractionDigits:0}).format(value);}

export function BiDependencyNetwork({companyId}:{companyId:string}){
  const {accessibleLocations,appState}=useSatrapy(),router=useRouter(),search=useSearchParams();
  const initial=useMemo(()=>{const filters=emptyFilters();return{...filters,dateFrom:search.get("from")??filters.dateFrom,dateTo:search.get("to")??filters.dateTo,
    locationId:search.get("location")??"",categoryId:search.get("category")??"",supplierId:search.get("supplier")??"",productId:search.get("product")??"",concentration:search.get("concentration")??""};},[search]);
  const [filters,setFilters]=useState<SupplierFilters>(initial),[applied,setApplied]=useState<SupplierFilters>(initial);
  const [result,setResult]=useState<SupplierOverviewResult|null>(null),[loading,setLoading]=useState(false),[error,setError]=useState<string|null>(null);
  const [selectedSupplier,setSelectedSupplier]=useState<SupplierOverviewItem|null>(null),[periodPreset,setPeriodPreset]=useState<PeriodPreset>(()=>inferPeriod(initial));
  const [advancedFiltersOpen,setAdvancedFiltersOpen]=useState(false),[nodeLabels,setNodeLabels]=useState<NodeLabels>({supplier:"",product:"",category:""});
  const [appliedNodeLabels,setAppliedNodeLabels]=useState<NodeLabels>({supplier:"",product:"",category:""}),[saving,setSaving]=useState(false);
  const requestRef=useRef<AbortController|null>(null);
  const can=(permission:string)=>Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes(permission));

  const load=useCallback(async(next=applied,page=1)=>{
    requestRef.current?.abort();const controller=new AbortController();requestRef.current=controller;setLoading(true);setError(null);
    const response=await getSupabaseClient().rpc("bi_supplier_dependency_overview",overviewArgs(companyId,next,page)).abortSignal(controller.signal);
    if(controller.signal.aborted)return;
    if(response.error)setError(response.error.message.includes("bi_supplier_dependency_overview")&&response.error.message.includes("schema cache")
      ?"La migración del panorama por proveedor aún no está aplicada en este entorno.":response.error.message);
    else{setResult(response.data as SupplierOverviewResult);setSelectedSupplier(null);}
    setLoading(false);
  },[applied,companyId]);
  useEffect(()=>{void Promise.resolve().then(()=>load(initial));return()=>requestRef.current?.abort();},[companyId]); // eslint-disable-line react-hooks/exhaustive-deps

  const dirty=JSON.stringify(filters)!==JSON.stringify(applied);
  const filterChips=useMemo(()=>{
    const chips:Array<{key:keyof SupplierFilters;label:string;empty:string}>=[];const location=accessibleLocations.find(item=>item.id===applied.locationId);
    if(applied.locationId)chips.push({key:"locationId",label:`Ubicación: ${location?.name??"Selección"}`,empty:""});
    if(applied.concentration)chips.push({key:"concentration",label:`Concentración: ${CONCENTRATION_LABELS[applied.concentration]??applied.concentration}`,empty:""});
    if(applied.supplierId)chips.push({key:"supplierId",label:`Proveedor: ${appliedNodeLabels.supplier||"seleccionado"}`,empty:""});
    if(applied.productId)chips.push({key:"productId",label:`Producto: ${appliedNodeLabels.product||"seleccionado"}`,empty:""});
    if(applied.categoryId)chips.push({key:"categoryId",label:`Categoría: ${appliedNodeLabels.category||"seleccionada"}`,empty:""});
    return chips;
  },[accessibleLocations,applied,appliedNodeLabels]);
  const advancedFilterCount=filterChips.filter(chip=>chip.key!=="locationId").length;
  const commitFilters=(next:SupplierFilters,labels=nodeLabels)=>{setFilters(next);setApplied(next);setAppliedNodeLabels(labels);setSelectedSupplier(null);void load(next,1);
    const params=new URLSearchParams({from:next.dateFrom,to:next.dateTo});for(const[key,value]of Object.entries({location:next.locationId,category:next.categoryId,supplier:next.supplierId,product:next.productId,concentration:next.concentration}))if(value)params.set(key,value);
    router.replace(`/satrapy/bi/red?${params}`);
  };
  const apply=()=>commitFilters({...filters});
  const reset=()=>{const next=emptyFilters(),labels={supplier:"",product:"",category:""};setNodeLabels(labels);setPeriodPreset("last90");setAdvancedFiltersOpen(false);commitFilters(next,labels);};
  const changePeriod=(value:string)=>{const preset=value as PeriodPreset;setPeriodPreset(preset);if(preset!=="custom")setFilters(current=>({...current,...periodRange(preset)}));};
  const removeAppliedFilter=(key:keyof SupplierFilters,empty:string)=>{const next={...applied,[key]:empty};const labels={...appliedNodeLabels};
    if(key==="supplierId")labels.supplier="";if(key==="productId")labels.product="";if(key==="categoryId")labels.category="";setNodeLabels(labels);commitFilters(next,labels);
  };
  const save=async()=>{const name=window.prompt("Nombre de la vista por proveedor");if(!name)return;setSaving(true);
    const definition={kind:"network",date_from:applied.dateFrom,date_to:applied.dateTo,location_id:applied.locationId||null,category_id:applied.categoryId||null,
      supplier_id:applied.supplierId||null,product_id:applied.productId||null,relation_types:[],operational_state:null,concentration_level:applied.concentration||null,
      size_metric:"purchases",color_metric:"node_type",edge_metric:"amount",perspective:"supplier_dependency"};
    const response=await getSupabaseClient().rpc("bi_save_view",{p_company_id:companyId,p_view_id:null,p_name:name,p_description:"Dependencia de abastecimiento por proveedor",
      p_visibility:"private",p_definition:definition,p_expected_version:null,p_client_request_id:crypto.randomUUID()});if(response.error)setError(response.error.message);setSaving(false);
  };
  return <section className="content-frame module-page bi-network bi-supplier-overview">
    <PageHeading eyebrow="Business Intelligence · Abastecimiento" title="Dependencia por proveedor"
      description="Prioriza el riesgo real por proveedor: importe comprobado, productos dependientes, proveedor único y cobertura comercial."
      action={can("manage_own_bi_views")?<Button variant="secondary" onClick={()=>void save()} disabled={saving}>{saving?<LoaderCircle className="spin" size={14}/>:<Save size={14}/>}Guardar vista</Button>:undefined}/>

    <section className={`bi-network__filterbar bi-executive-filterbar${dirty?" has-pending":""}`} aria-label="Filtros de dependencia por proveedor">
      <div className="bi-executive-filterbar__primary">
        <label><span>Periodo</span><Select ariaLabel="Periodo de dependencia" value={periodPreset} onValueChange={changePeriod} options={PERIOD_OPTIONS}/></label>
        <label><span>Ubicación</span><Select ariaLabel="Ubicación de dependencia" value={filters.locationId||"all"} onValueChange={value=>setFilters(current=>({...current,locationId:value==="all"?"":value}))}
          options={[{value:"all",label:"Todas las ubicaciones"},...accessibleLocations.map(location=>({value:location.id,label:location.name}))]}/></label>
        <Button className="bi-executive-filterbar__more" variant="secondary" size="sm" aria-expanded={advancedFiltersOpen} aria-controls="bi-supplier-advanced-filters" onClick={()=>setAdvancedFiltersOpen(current=>!current)}><Plus size={14}/>Más filtros{advancedFilterCount?` · ${advancedFilterCount}`:""}</Button>
        <div className="bi-executive-filterbar__actions">
          {(filterChips.length>0||dirty)&&<Button variant="ghost" size="sm" onClick={reset}>Restablecer</Button>}
          <Button variant={dirty?"primary":"secondary"} size="sm" disabled={!dirty||!filters.dateFrom||!filters.dateTo} onClick={apply}>Aplicar cambios</Button>
        </div>
      </div>
      {periodPreset==="custom"&&<div className="bi-executive-filterbar__custom"><span>Periodo personalizado</span>
        <label><span>Desde</span><Input type="date" value={filters.dateFrom} max={filters.dateTo} onChange={event=>setFilters(current=>({...current,dateFrom:event.target.value}))} aria-label="Periodo desde"/></label>
        <label><span>Hasta</span><Input type="date" value={filters.dateTo} min={filters.dateFrom} max={iso(new Date())} onChange={event=>setFilters(current=>({...current,dateTo:event.target.value}))} aria-label="Periodo hasta"/></label>
      </div>}
      {advancedFiltersOpen&&<div id="bi-supplier-advanced-filters" className="bi-executive-filterbar__advanced bi-network__advanced">
        <header><div><strong>Alcance del análisis</strong><span>Acota proveedores, productos y categorías canónicas antes de comparar dependencia.</span></div><button type="button" aria-label="Cerrar filtros" onClick={()=>setAdvancedFiltersOpen(false)}><X size={15}/></button></header>
        <div className="bi-network__filter-groups bi-supplier-overview__filter-groups"><section><header><strong>Dependencia comprobada</strong><span>El resumen agrupa toda la evidencia del servidor, no una subred visible.</span></header><div>
          <label><span>Concentración</span><Select ariaLabel="Nivel de concentración" value={filters.concentration||"all"} onValueChange={value=>setFilters(current=>({...current,concentration:value==="all"?"":value}))}
            options={[{value:"all",label:"Todos los niveles"},...Object.entries(CONCENTRATION_LABELS).map(([value,label])=>({value,label}))]}/></label>
          <NodeFilter key={`supplier:${filters.supplierId}`} companyId={companyId} type="supplier" label="Proveedor" value={filters.supplierId} selectedLabel={nodeLabels.supplier} onChange={(supplierId,label="")=>{setFilters(current=>({...current,supplierId}));setNodeLabels(current=>({...current,supplier:label}));}}/>
          <NodeFilter key={`product:${filters.productId}`} companyId={companyId} type="product" label="Producto" value={filters.productId} selectedLabel={nodeLabels.product} onChange={(productId,label="")=>{setFilters(current=>({...current,productId}));setNodeLabels(current=>({...current,product:label}));}}/>
          <NodeFilter key={`category:${filters.categoryId}`} companyId={companyId} type="category" label="Categoría" value={filters.categoryId} selectedLabel={nodeLabels.category} onChange={(categoryId,label="")=>{setFilters(current=>({...current,categoryId}));setNodeLabels(current=>({...current,category:label}));}}/>
        </div></section></div>
      </div>}
      <div className="bi-executive-filterbar__applied"><div className="bi-executive-filterbar__context"><span className="bi-executive-filterbar__status" aria-live="polite">{dirty?<><i/>Cambios sin aplicar</>:<><i/>Contexto aplicado</>}</span>
        <strong>{PERIOD_OPTIONS.find(option=>option.value===inferPeriod(applied))?.label??"Periodo personalizado"}</strong>
        <small>{new Date(`${applied.dateFrom}T00:00:00`).toLocaleDateString("es-MX")}–{new Date(`${applied.dateTo}T00:00:00`).toLocaleDateString("es-MX")}{result?` · ${result.totals.suppliers} proveedores`:""}</small>
      </div><div className="bi-executive-filterbar__chips" aria-label="Filtros aplicados">{filterChips.slice(0,5).map(chip=><button type="button" key={chip.key} onClick={()=>removeAppliedFilter(chip.key,chip.empty)}>{chip.label}<X size={12}/></button>)}{filterChips.length>5&&<span>+{filterChips.length-5} filtros</span>}{!filterChips.length&&<span>Sin filtros adicionales</span>}</div></div>
    </section>

    {error&&<div className="data-state data-state--error" role="alert"><strong>No se pudo consultar la dependencia por proveedor.</strong><span>{error}</span></div>}
    {loading&&!result?<div className="data-state data-state--loading"><LoaderCircle className="spin" size={20}/><span>Calculando dependencias completas por proveedor…</span></div>:result?<section className="bi-supplier-overview__surface">
      <header className="bi-supplier-overview__intro"><div><small>Mapa ejecutivo de dependencia</small><h2>Qué proveedor concentra el riesgo</h2><p>Ordenado por productos con proveedor único, dependencia alta y después importe comprobado.</p></div>{loading&&<span><LoaderCircle className="spin" size={14}/>Actualizando</span>}</header>
      <div className="bi-supplier-overview__kpis"><Metric icon={<Truck size={16}/>} label="Proveedores" value={result.totals.suppliers.toLocaleString("es-MX")} detail="con evidencia dentro del filtro"/><Metric icon={<Layers3 size={16}/>} label="Productos cubiertos" value={result.totals.products.toLocaleString("es-MX")} detail="relaciones proveedor-producto"/><Metric icon={<AlertTriangle size={16}/>} label="Dependencia alta" value={result.totals.high_dependency_products.toLocaleString("es-MX")} detail="productos con ≥80% por proveedor"/><Metric icon={<PackageSearch size={16}/>} label="Proveedor único" value={result.totals.unique_supplier_products.toLocaleString("es-MX")} detail="productos sin alternativa comprobada"/></div>
      {!result.items.length?<div className="data-state data-state--empty"><strong>No hay dependencia comprobada bajo estos filtros.</strong><span>Amplía el periodo o retira filtros. Satrapy no infiere proveedores cuando falta evidencia.</span></div>:<div className="bi-supplier-overview__workspace"><main><div className="bi-supplier-overview__list" aria-label="Proveedores priorizados">{result.items.map((supplier,index)=><SupplierCard key={supplier.supplier_id} supplier={supplier} rank={(result.pagination.page-1)*result.pagination.page_size+index+1} currency={result.currency_code} active={selectedSupplier?.supplier_id===supplier.supplier_id} onClick={()=>setSelectedSupplier(supplier)}/>)}</div><DataPagination page={result.pagination.page} pageSize={result.pagination.page_size} total={result.pagination.total} onChange={page=>void load(applied,page)}/></main><SupplierDetail supplier={selectedSupplier} currency={result.currency_code} onClose={()=>setSelectedSupplier(null)} onOpenExplorer={()=>selectedSupplier&&router.push(`/satrapy/bi/explorador?from=${applied.dateFrom}&to=${applied.dateTo}&supplier=${selectedSupplier.supplier_id}`)}/></div>}
      <footer className="bi-supplier-overview__method"><strong>Lectura</strong><span>{result.methodology.amount}</span><span>{result.methodology.coverage}</span><small>Actualizado {new Date(result.updated_at).toLocaleString("es-MX")}</small></footer>
    </section>:null}
  </section>;
}

function Metric({icon,label,value,detail}:{icon:React.ReactNode;label:string;value:string;detail:string}){return <article><span>{icon}{label}</span><strong>{value}</strong><small>{detail}</small></article>;}
function SupplierCard({supplier,rank,currency,active,onClick}:{supplier:SupplierOverviewItem;rank:number;currency:string|null;active:boolean;onClick:()=>void}){return <button type="button" className={`bi-supplier-overview__supplier${active?" is-active":""}`} onClick={onClick} aria-pressed={active}>
  <header><span>#{rank}{supplier.code?` · ${supplier.code}`:""}</span><strong>{supplier.label}</strong><em>{money(supplier.total_amount,currency)}</em></header><div className="bi-supplier-overview__supplier-metrics"><span><PackageSearch size={13}/>{supplier.product_count} productos</span><span><Warehouse size={13}/>{supplier.location_count} ubicaciones</span><span><Layers3 size={13}/>{percentage(supplier.max_concentration)} máximo</span></div>
  <footer><Badge tone={supplier.unique_product_count?"danger":"neutral"}>{supplier.unique_product_count} proveedor único</Badge><Badge tone={supplier.high_dependency_product_count?"warning":"neutral"}>{supplier.high_dependency_product_count} alta dependencia</Badge></footer>
</button>;}
function SupplierDetail({supplier,currency,onClose,onOpenExplorer}:{supplier:SupplierOverviewItem|null;currency:string|null;onClose:()=>void;onOpenExplorer:()=>void}){return <aside className="bi-supplier-overview__detail"><header><div><small>Detalle del proveedor</small><h2>{supplier?.label??"Selecciona un proveedor"}</h2></div>{supplier&&<button aria-label="Cerrar detalle" onClick={onClose}><X size={15}/></button>}</header>{!supplier?<p>Selecciona una tarjeta para revisar concentración, productos prioritarios y cobertura comercial sin abrir un grafo masivo.</p>:<><div className="bi-supplier-overview__identity"><Truck size={18}/><div><Badge tone="info">Proveedor</Badge><small>{supplier.code??supplier.supplier_id}</small></div></div><dl><div><dt>Importe comprobado</dt><dd>{money(supplier.total_amount,currency)}</dd></div><div><dt>Frecuencia</dt><dd>{supplier.frequency.toLocaleString("es-MX")}</dd></div><div><dt>Productos</dt><dd>{supplier.product_count}</dd></div><div><dt>Ubicaciones con surtido</dt><dd>{supplier.location_count}</dd></div><div><dt>Proveedor único</dt><dd>{supplier.unique_product_count}</dd></div><div><dt>Concentración máxima</dt><dd>{percentage(supplier.max_concentration)}</dd></div></dl><section><h3>Productos de mayor exposición</h3><ul>{supplier.top_products.map(product=><li key={product.product_id}><div><strong>{product.label}</strong><small>{product.sku??"Sin SKU"} · {product.metric_source}</small></div><span><b>{money(product.amount,currency)}</b><small>{percentage(product.concentration)} · {product.supplier_count} proveedores</small></span></li>)}</ul></section><Button size="sm" variant="secondary" onClick={onOpenExplorer}>Abrir en Explorador <ArrowUpRight size={13}/></Button></>}</aside>;}

function NodeFilter({companyId,type,label,value,selectedLabel,onChange}:{companyId:string;type:NodeType;label:string;value:string;selectedLabel:string;onChange:(id:string,label?:string)=>void}){
  const [text,setText]=useState(selectedLabel),[options,setOptions]=useState<Array<{id:string;label:string;secondary?:string}>>([]);
  useEffect(()=>{if(text.trim().length<2)return;let cancelled=false;const timer=setTimeout(()=>{void getSupabaseClient().rpc("bi_search_dependency_nodes",{p_company_id:companyId,p_query:text,p_node_type:type,p_page:1,p_page_size:8}).then(response=>{if(!cancelled&&!response.error)setOptions(((response.data as{items:typeof options})?.items)??[]);});},220);return()=>{cancelled=true;clearTimeout(timer);};},[companyId,text,type]);
  return <label className="bi-network__node-filter"><span>{label}</span><div><Input value={text} placeholder={value?"Filtro seleccionado":"Buscar…"} onChange={event=>{setText(event.target.value);if(!event.target.value)onChange("");}}/>{value&&<button type="button" aria-label={`Quitar ${label}`} onClick={()=>{onChange("");setText("");}}><X size={12}/></button>}</div>{text.trim().length>=2&&options.length>0&&<ul>{options.map(option=><li key={option.id}><button type="button" onClick={()=>{onChange(option.id,option.label);setText(option.label);setOptions([]);}}><strong>{option.label}</strong><small>{option.secondary}</small></button></li>)}</ul>}</label>;
}
