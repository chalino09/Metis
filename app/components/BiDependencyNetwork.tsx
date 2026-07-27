"use client";

import {
  ArrowUpRight,Box,Download,Expand,Focus,GitFork,ImageDown,Layers3,LoaderCircle,
  Maximize2,Minimize2,PackageSearch,Plus,Save,Search,Table2,Truck,Warehouse,X,ZoomIn,ZoomOut,
} from "lucide-react";
import {useCallback,useEffect,useMemo,useRef,useState} from "react";
import {useRouter,useSearchParams} from "next/navigation";
import {DataPagination,PageHeading,Table} from "@/app/components/ui/data";
import {Badge,Button,Input,Select} from "@/app/components/ui/primitives";
import {getSupabaseClient} from "@/app/lib/supabase";
import {useSatrapy} from "@/app/components/SatrapyProvider";

type NodeType="supplier"|"product"|"category"|"location";
type RelationType="supplier_product"|"product_category"|"product_location_assortment"|"product_location_availability";
type NetworkNode={id:string;type:NodeType;entity_id:string;label:string;secondary?:string|null;size_value:number;concentration:number;availability?:string|null;metrics:Record<string,number>};
type NetworkEdge={id:string;source:string;target:string;type:RelationType;direction:"outbound";amount:number;quantity:number;frequency:number;weight:number;
  period:{from:string|null;to:string|null};metric_source:string;source_counts:Record<string,number>;evidence:Array<Record<string,unknown>>;
  operational_state?:string|null;concentration_share:number;concentration_level:"low"|"medium"|"high"};
type NetworkResult={nodes:NetworkNode[];edges:NetworkEdge[];period:{from:string;to:string};currency_code:string|null;updated_at:string;
  limits:{nodes:number;edges:number;expansion_levels:number};totals:{nodes:number;edges:number};truncated:boolean;methodology:Record<string,string>};
type NetworkFilters={dateFrom:string;dateTo:string;locationId:string;categoryId:string;supplierId:string;productId:string;
  relationType:string;operationalState:string;concentration:string;sizeMetric:string;colorMetric:string;edgeMetric:string;perspective:string};
type Positioned=NetworkNode&{x:number;y:number};
type Drill={items:Array<{id:string;occurred_at?:string;evidence_type?:string;reference?:string;location_name?:string;amount?:number;quantity?:number}>;
  pagination:{page:number;page_size:number;total:number}};

const NODE_META:Record<NodeType,{label:string;color:string;icon:typeof Truck}>={
  supplier:{label:"Proveedor",color:"#27645a",icon:Truck},product:{label:"Producto",color:"#327a9b",icon:PackageSearch},
  category:{label:"Categoría",color:"#a66b29",icon:Layers3},location:{label:"Ubicación",color:"#76548d",icon:Warehouse},
};
const RELATION_META:Record<RelationType,{label:string;color:string;dash?:string}>={
  supplier_product:{label:"Abastecimiento comprobado",color:"#27645a"},
  product_category:{label:"Clasificación canónica",color:"#a66b29",dash:"4 4"},
  product_location_assortment:{label:"Surtido comercial",color:"#76548d"},
  product_location_availability:{label:"Disponibilidad operativa",color:"#327a9b",dash:"2 3"},
};
const emptyFilters=():NetworkFilters=>{
  const to=new Date(),from=new Date(to);from.setDate(from.getDate()-89);
  return{dateFrom:iso(from),dateTo:iso(to),locationId:"",categoryId:"",supplierId:"",productId:"",relationType:"",
    operationalState:"",concentration:"",sizeMetric:"purchases",colorMetric:"node_type",edgeMetric:"amount",perspective:"supplier_dependency"};
};
function iso(value:Date){return value.toISOString().slice(0,10);}
function hash(value:string){let h=2166136261;for(let i=0;i<value.length;i++)h=Math.imul(h^value.charCodeAt(i),16777619);return(h>>>0)/4294967295;}
function layout(nodes:NetworkNode[],edges:NetworkEdge[],width=980,height=560):Positioned[]{
  if(!nodes.length)return[];
  const points=nodes.map((node,index)=>({...node,x:width*(.12+.76*hash(`${node.id}:x:${index}`)),y:height*(.12+.76*hash(`${node.id}:y:${index}`)),vx:0,vy:0}));
  const byId=new Map(points.map((p,i)=>[p.id,i]));const links=edges.map(edge=>[byId.get(edge.source),byId.get(edge.target)]as const).filter(v=>v[0]!=null&&v[1]!=null)as Array<readonly[number,number]>;
  for(let step=0;step<150;step++){const alpha=(1-step/150)*.72;
    for(let i=0;i<points.length;i++)for(let j=i+1;j<points.length;j++){const a=points[i],b=points[j],dx=a.x-b.x||.01,dy=a.y-b.y||.01,d2=Math.max(dx*dx+dy*dy,100),f=5200/d2*alpha;a.vx+=dx*f;a.vy+=dy*f;b.vx-=dx*f;b.vy-=dy*f;}
    for(const[i,j]of links){const a=points[i],b=points[j],dx=b.x-a.x,dy=b.y-a.y,d=Math.max(Math.hypot(dx,dy),1),f=(d-115)/d*.035*alpha;a.vx+=dx*f;a.vy+=dy*f;b.vx-=dx*f;b.vy-=dy*f;}
    for(const p of points){p.vx+=(width/2-p.x)*.002*alpha;p.vy+=(height/2-p.y)*.002*alpha;p.vx*=.72;p.vy*=.72;p.x=Math.max(34,Math.min(width-34,p.x+p.vx));p.y=Math.max(34,Math.min(height-34,p.y+p.vy));}
  }
  return points.map(point=>({id:point.id,type:point.type,entity_id:point.entity_id,label:point.label,secondary:point.secondary,
    size_value:point.size_value,concentration:point.concentration,availability:point.availability,metrics:point.metrics,x:point.x,y:point.y}));
}
const NODE_RADIUS_MIN=7;
const NODE_RADIUS_MAX=18;
function nodeRadius(node:NetworkNode,max:number){
  const normalized=Math.sqrt(Math.max(node.size_value,0)/Math.max(max,1));
  return NODE_RADIUS_MIN+normalized*(NODE_RADIUS_MAX-NODE_RADIUS_MIN);
}
function nodeColor(node:NetworkNode,mode:string){
  if(mode==="concentration")return node.concentration>=.8?"#a94335":node.concentration>=.5?"#c58b2c":"#4d8b72";
  if(mode==="availability")return node.availability==="blocked_readiness"?"#a94335":node.availability==="out_of_stock"?"#c58b2c":node.availability==="available"?"#2d8567":"#7a8581";
  return NODE_META[node.type].color;
}
function money(value:number,currency:string|null){return currency?new Intl.NumberFormat("es-MX",{style:"currency",currency,maximumFractionDigits:0}).format(value):value.toLocaleString("es-MX",{maximumFractionDigits:1});}
function rpcArgs(companyId:string,f:NetworkFilters,anchor?:NetworkNode,levels=0){return{
  p_company_id:companyId,p_date_from:f.dateFrom,p_date_to:f.dateTo,p_location_id:f.locationId||null,p_category_id:f.categoryId||null,
  p_supplier_id:f.supplierId||null,p_product_id:f.productId||null,p_relation_types:f.relationType?[f.relationType]:null,
  p_operational_state:f.operationalState||null,p_concentration_level:f.concentration||null,p_size_metric:f.sizeMetric,p_color_metric:f.colorMetric,
  p_edge_metric:f.edgeMetric,p_perspective:f.perspective,p_anchor_type:anchor?.type??null,p_anchor_id:anchor?.entity_id??null,
  p_expansion_levels:levels,p_node_limit:120,p_edge_limit:240,
};}

export function BiDependencyNetwork({companyId}:{companyId:string}){
  const {accessibleLocations,appState}=useSatrapy(),router=useRouter(),search=useSearchParams();
  const initial=useMemo(()=>{const f=emptyFilters();return{...f,dateFrom:search.get("from")??f.dateFrom,dateTo:search.get("to")??f.dateTo,
    locationId:search.get("location")??"",categoryId:search.get("category")??"",supplierId:search.get("supplier")??"",productId:search.get("product")??"",
    relationType:search.get("relation")??"",operationalState:search.get("state")??"",concentration:search.get("concentration")??"",
    sizeMetric:search.get("size")??f.sizeMetric,colorMetric:search.get("color")??f.colorMetric,edgeMetric:search.get("edge")??f.edgeMetric,
    perspective:search.get("perspective")??f.perspective};},[search]);
  const [filters,setFilters]=useState<NetworkFilters>(initial),[applied,setApplied]=useState<NetworkFilters>(initial);
  const [result,setResult]=useState<NetworkResult|null>(null),[loading,setLoading]=useState(false),[error,setError]=useState<string|null>(null);
  const [selectedNode,setSelectedNode]=useState<NetworkNode|null>(null),[selectedEdge,setSelectedEdge]=useState<NetworkEdge|null>(null);
  const [drill,setDrill]=useState<Drill|null>(null),[drillPage,setDrillPage]=useState(1),[tab,setTab]=useState<"graph"|"table">("graph");
  const [query,setQuery]=useState(""),[zoom,setZoom]=useState(1),[pan,setPan]=useState({x:0,y:0}),[fullscreen,setFullscreen]=useState(false);
  const [saving,setSaving]=useState(false),[exporting,setExporting]=useState<string|null>(null);
  const requestRef=useRef<AbortController|null>(null),shellRef=useRef<HTMLDivElement>(null),dragRef=useRef<{x:number;y:number;panX:number;panY:number}|null>(null);
  const can=(permission:string)=>Boolean(appState?.membership.permissions.includes("*")||appState?.membership.permissions.includes(permission));

  const load=useCallback(async(next=applied,anchor?:NetworkNode,levels=0)=>{
    requestRef.current?.abort();const controller=new AbortController();requestRef.current=controller;setLoading(true);setError(null);
    const response=await getSupabaseClient().rpc("bi_dependency_network_query",rpcArgs(companyId,next,anchor,levels)).abortSignal(controller.signal);
    if(controller.signal.aborted)return;
    if(response.error)setError(response.error.message.includes("bi_dependency_network_query")&&response.error.message.includes("schema cache")
      ?"La migración BI Fase 6 aún no está aplicada en este entorno.":response.error.message);
    else{setResult(response.data as NetworkResult);setSelectedNode(anchor??null);setSelectedEdge(null);setDrill(null);}
    setLoading(false);
  },[applied,companyId]);
  useEffect(()=>{void Promise.resolve().then(()=>load(initial));return()=>requestRef.current?.abort();},[companyId]); // eslint-disable-line react-hooks/exhaustive-deps

  const positions=useMemo(()=>layout(result?.nodes??[],result?.edges??[]),[result]);
  const posMap=useMemo(()=>new Map(positions.map(node=>[node.id,node])),[positions]);
  const maxSize=Math.max(1,...positions.map(node=>node.size_value));
  const visibleIds=useMemo(()=>new Set(!query.trim()?positions.map(n=>n.id):positions.filter(n=>`${n.label} ${n.secondary??""}`.toLowerCase().includes(query.toLowerCase())).map(n=>n.id)),[positions,query]);
  const focusNode=(node:NetworkNode)=>{setSelectedNode(node);setSelectedEdge(null);setDrill(null);const p=posMap.get(node.id);if(p){setZoom(1.55);setPan({x:490-p.x*1.55,y:280-p.y*1.55});}};
  const apply=()=>{const next={...filters};setApplied(next);setSelectedNode(null);setSelectedEdge(null);setPan({x:0,y:0});setZoom(1);void load(next);
    const params=new URLSearchParams({from:next.dateFrom,to:next.dateTo,size:next.sizeMetric,color:next.colorMetric,edge:next.edgeMetric,perspective:next.perspective});
    for(const[key,value]of Object.entries({location:next.locationId,category:next.categoryId,supplier:next.supplierId,product:next.productId,relation:next.relationType,state:next.operationalState,concentration:next.concentration}))if(value)params.set(key,value);
    router.replace(`/satrapy/bi/red?${params}`);};
  const reset=()=>{const next=emptyFilters();setFilters(next);setApplied(next);void load(next);};
  const inspectEdge=async(edge:NetworkEdge,page=1)=>{setSelectedEdge(edge);setSelectedNode(null);setDrillPage(page);
    const response=await getSupabaseClient().rpc("bi_dependency_network_drilldown",{p_company_id:companyId,p_relation_type:edge.type,
      p_source_id:edge.source.split(":")[1],p_target_id:edge.target.split(":")[1],p_date_from:applied.dateFrom,p_date_to:applied.dateTo,p_page:page,p_page_size:20});
    if(response.error)setError(response.error.message);else setDrill(response.data as Drill);
  };
  const save=async()=>{const name=window.prompt("Nombre de la vista de red");if(!name)return;setSaving(true);
    const definition={kind:"network",date_from:applied.dateFrom,date_to:applied.dateTo,location_id:applied.locationId||null,category_id:applied.categoryId||null,
      supplier_id:applied.supplierId||null,product_id:applied.productId||null,relation_types:applied.relationType?[applied.relationType]:[],
      operational_state:applied.operationalState||null,concentration_level:applied.concentration||null,size_metric:applied.sizeMetric,color_metric:applied.colorMetric,
      edge_metric:applied.edgeMetric,perspective:applied.perspective};
    const response=await getSupabaseClient().rpc("bi_save_view",{p_company_id:companyId,p_view_id:null,p_name:name,p_description:"Red de dependencias",
      p_visibility:"private",p_definition:definition,p_expected_version:null,p_client_request_id:crypto.randomUUID()});
    if(response.error)setError(response.error.message);setSaving(false);
  };
  const exportNetwork=async(format:"csv"|"xlsx"|"pdf"|"png")=>{setExporting(format);
    try{const session=(await getSupabaseClient().auth.getSession()).data.session;if(!session)throw new Error("Sesión no válida.");
      const response=await fetch("/api/bi/network/export",{method:"POST",headers:{Authorization:`Bearer ${session.access_token}`,"content-type":"application/json"},body:JSON.stringify({companyId,format,filters:applied})});
      if(!response.ok)throw new Error((await response.json()).message??"No se pudo exportar.");const blob=await response.blob(),url=URL.createObjectURL(blob),a=document.createElement("a");
      a.href=url;a.download=`satrapy_red_dependencias_${applied.dateFrom}_${applied.dateTo}.${format}`;a.click();URL.revokeObjectURL(url);
    }catch(e){setError(e instanceof Error?e.message:"No se pudo exportar.");}finally{setExporting(null);}};

  return <section className={`content-frame module-page bi-network${fullscreen?" is-fullscreen":""}`} ref={shellRef}>
    <PageHeading eyebrow="Business Intelligence · Red de dependencias" title="Red de abastecimiento"
      description="Explora evidencia canónica de proveedor → producto → categoría → ubicación. La cercanía visual no implica causalidad."
      action={<div className="bi-network__heading-actions">
        {can("manage_own_bi_views")&&<Button variant="secondary" onClick={()=>void save()} disabled={saving}>{saving?<LoaderCircle className="spin" size={14}/>:<Save size={14}/>}Guardar vista</Button>}
        {can("export_bi_reports")&&<><Button variant="secondary" onClick={()=>void exportNetwork("xlsx")} disabled={Boolean(exporting)}><Download size={14}/>XLSX</Button><Button variant="secondary" onClick={()=>void exportNetwork("pdf")} disabled={Boolean(exporting)}><ImageDown size={14}/>PDF</Button><Button variant="secondary" onClick={()=>void exportNetwork("png")} disabled={Boolean(exporting)}><ImageDown size={14}/>PNG</Button></>}
      </div>}/>

    <div className="bi-network__filters">
      <label>Desde<Input type="date" value={filters.dateFrom} onChange={e=>setFilters(v=>({...v,dateFrom:e.target.value}))}/></label>
      <label>Hasta<Input type="date" value={filters.dateTo} onChange={e=>setFilters(v=>({...v,dateTo:e.target.value}))}/></label>
      <label>Ubicación<Select ariaLabel="Ubicación de la red" value={filters.locationId||"all"} onValueChange={v=>setFilters(f=>({...f,locationId:v==="all"?"":v}))}
        options={[{value:"all",label:"Todas las permitidas"},...accessibleLocations.map(l=>({value:l.id,label:l.name}))]}/></label>
      <label>Relación<Select ariaLabel="Tipo de relación" value={filters.relationType||"all"} onValueChange={v=>setFilters(f=>({...f,relationType:v==="all"?"":v}))}
        options={[{value:"all",label:"Todas"},...Object.entries(RELATION_META).map(([value,m])=>({value,label:m.label}))]}/></label>
      <label>Estado operativo<Select ariaLabel="Estado operativo" value={filters.operationalState||"all"} onValueChange={v=>setFilters(f=>({...f,operationalState:v==="all"?"":v}))}
        options={[{value:"all",label:"Todos"},{value:"available",label:"Disponible"},{value:"out_of_stock",label:"Sin existencia"},{value:"blocked_readiness",label:"Bloqueado por readiness"}]}/></label>
      <label>Concentración<Select ariaLabel="Nivel de concentración" value={filters.concentration||"all"} onValueChange={v=>setFilters(f=>({...f,concentration:v==="all"?"":v}))}
        options={[{value:"all",label:"Todos los niveles"},{value:"high",label:"Alta · ≥ 80%"},{value:"medium",label:"Media · 50–79.9%"},{value:"low",label:"Baja · < 50%"}]}/></label>
      <NodeFilter companyId={companyId} type="supplier" label="Proveedor" value={filters.supplierId} onChange={supplierId=>setFilters(f=>({...f,supplierId}))}/>
      <NodeFilter companyId={companyId} type="product" label="Producto" value={filters.productId} onChange={productId=>setFilters(f=>({...f,productId}))}/>
      <NodeFilter companyId={companyId} type="category" label="Categoría" value={filters.categoryId} onChange={categoryId=>setFilters(f=>({...f,categoryId}))}/>
      <label>Perspectiva<Select ariaLabel="Perspectiva" value={filters.perspective} onValueChange={v=>setFilters(f=>({...f,perspective:v}))}
        options={[{value:"supplier_dependency",label:"Dependencia por proveedor"},{value:"location_coverage",label:"Cobertura por ubicación"},{value:"supply_concentration",label:"Concentración de abastecimiento"},{value:"unique_supplier",label:"Productos con proveedor único"},{value:"selected_impact",label:"Impacto potencial"}]}/></label>
      <label>Tamaño<Select ariaLabel="Métrica de tamaño" value={filters.sizeMetric} onValueChange={v=>setFilters(f=>({...f,sizeMetric:v}))}
        options={[{value:"purchases",label:"Compras comprobadas"},{value:"sales",label:"Ventas"},{value:"inventory",label:"Inventario"},{value:"connections",label:"Conexiones"}]}/></label>
      <label>Color<Select ariaLabel="Métrica de color" value={filters.colorMetric} onValueChange={v=>setFilters(f=>({...f,colorMetric:v}))}
        options={[{value:"node_type",label:"Tipo de nodo"},{value:"concentration",label:"Concentración"},{value:"availability",label:"Disponibilidad"}]}/></label>
      <label>Grosor<Select ariaLabel="Métrica de grosor" value={filters.edgeMetric} onValueChange={v=>setFilters(f=>({...f,edgeMetric:v}))}
        options={[{value:"amount",label:"Importe"},{value:"quantity",label:"Cantidad"},{value:"frequency",label:"Frecuencia"}]}/></label>
      <div className="bi-network__filter-actions"><Button variant="ghost" onClick={reset}>Restablecer</Button><Button onClick={apply}>Aplicar filtros</Button></div>
    </div>

    {error&&<div className="data-state data-state--error" role="alert"><strong>No se pudo consultar la red.</strong><span>{error}</span></div>}
    <div className="bi-network__toolbar">
      <div className="bi-network__search"><Search size={14}/><Input aria-label="Buscar nodo cargado" placeholder="Buscar en esta subred…" value={query} onChange={e=>setQuery(e.target.value)}/></div>
      <div className="bi-network__tabs"><button className={tab==="graph"?"is-active":""} onClick={()=>setTab("graph")}><GitFork size={14}/>Grafo</button><button className={tab==="table"?"is-active":""} onClick={()=>setTab("table")}><Table2 size={14}/>Tabla accesible</button></div>
      <div className="bi-network__controls"><button aria-label="Alejar" onClick={()=>setZoom(v=>Math.max(.45,v-.2))}><ZoomOut size={15}/></button><span>{Math.round(zoom*100)}%</span><button aria-label="Acercar" onClick={()=>setZoom(v=>Math.min(2.5,v+.2))}><ZoomIn size={15}/></button><button aria-label="Centrar red" onClick={()=>{setZoom(1);setPan({x:0,y:0});}}><Focus size={15}/></button><button aria-label={fullscreen?"Salir de pantalla completa":"Pantalla completa"} onClick={()=>setFullscreen(v=>!v)}>{fullscreen?<Minimize2 size={15}/>:<Maximize2 size={15}/>}</button></div>
    </div>

    {result?.truncated&&<div className="bi-network__truncated"><Box size={15}/><span>Subred truncada: se muestran {result.nodes.length} de {result.totals.nodes} nodos y {result.edges.length} de {result.totals.edges} relaciones. Reduce periodo, ubicación o tipo de relación.</span></div>}
    <div className="bi-network__workspace">
      <main>
        {loading&&!result?<div className="data-state data-state--loading"><LoaderCircle className="spin" size={20}/><span>Construyendo subred dentro de tu alcance autorizado…</span></div>:
        tab==="graph"?<div className="bi-network__canvas" onPointerDown={e=>{if((e.target as Element).closest("[data-node],[data-edge]"))return;dragRef.current={x:e.clientX,y:e.clientY,panX:pan.x,panY:pan.y};}}
          onPointerMove={e=>{if(dragRef.current)setPan({x:dragRef.current.panX+e.clientX-dragRef.current.x,y:dragRef.current.panY+e.clientY-dragRef.current.y});}}
          onPointerUp={()=>{dragRef.current=null;}} onPointerLeave={()=>{dragRef.current=null;}}>
          <svg viewBox="0 0 980 560" role="img" aria-label={`Red con ${result?.nodes.length??0} nodos y ${result?.edges.length??0} relaciones`}>
            <defs><marker id="network-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z"/></marker></defs>
            <g transform={`translate(${pan.x} ${pan.y}) scale(${zoom})`}>
              {result?.edges.map(edge=>{const a=posMap.get(edge.source),b=posMap.get(edge.target);if(!a||!b)return null;const meta=RELATION_META[edge.type],dim=query&&!visibleIds.has(a.id)&&!visibleIds.has(b.id);
                return <line key={edge.id} data-edge x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke={meta.color} strokeWidth={1+Math.min(7,Math.sqrt(Math.max(edge.weight,0)/Math.max(...result.edges.map(e=>e.weight),1))*7)}
                  strokeDasharray={meta.dash} opacity={dim?.15:selectedEdge?.id===edge.id?1:.55} markerEnd="url(#network-arrow)" tabIndex={0} role="button"
                  aria-label={`${meta.label}: ${a.label} a ${b.label}`} onClick={()=>void inspectEdge(edge)} onKeyDown={e=>{if(e.key==="Enter"||e.key===" ")void inspectEdge(edge);}}><title>{meta.label} · {edge.metric_source} · {money(edge.amount,result.currency_code)}</title></line>;})}
              {positions.map(node=>{const radius=nodeRadius(node,maxSize),meta=NODE_META[node.type],active=selectedNode?.id===node.id,dim=query&&!visibleIds.has(node.id);
                return <g key={node.id} data-node transform={`translate(${node.x} ${node.y})`} role="button" tabIndex={0} aria-label={`${meta.label}: ${node.label}`}
                  opacity={dim?.18:1} onClick={()=>focusNode(node)} onKeyDown={e=>{if(e.key==="Enter"||e.key===" ")focusNode(node);}}>
                  <circle r={radius} fill={nodeColor(node,applied.colorMetric)} stroke={active?"#102a25":"#fff"} strokeWidth={active?4:2}/><text y={radius+13} textAnchor="middle">{node.label.length>24?`${node.label.slice(0,22)}…`:node.label}</text>
                  <title>{node.label} · {meta.label} · {applied.sizeMetric}: {node.size_value.toLocaleString("es-MX")} · actualizado {result?.updated_at?new Date(result.updated_at).toLocaleString("es-MX"):"—"}</title>
                </g>;})}
            </g>
          </svg>
          <div className="bi-network__legend">{applied.colorMetric==="node_type"?Object.entries(NODE_META).map(([key,m])=><span key={key}><i style={{background:m.color}}/>{m.label}</span>):applied.colorMetric==="concentration"?<><span><i style={{background:"#a94335"}}/>Alta ≥80%</span><span><i style={{background:"#c58b2c"}}/>Media 50–79.9%</span><span><i style={{background:"#4d8b72"}}/>Baja &lt;50%</span></>:<><span><i style={{background:"#2d8567"}}/>Disponible</span><span><i style={{background:"#c58b2c"}}/>Sin existencia</span><span><i style={{background:"#a94335"}}/>Readiness bloqueado</span></>}{Object.entries(RELATION_META).map(([key,m])=><span key={key}><b style={{borderColor:m.color,borderStyle:m.dash?"dashed":"solid"}}/>{m.label}</span>)}</div>
        </div>:<NetworkTables result={result} onNode={focusNode} onEdge={edge=>void inspectEdge(edge)}/>}
      </main>
      <aside className="bi-network__detail">
        <header><div><small>Detalle y evidencia</small><h2>{selectedNode?.label??(selectedEdge?RELATION_META[selectedEdge.type].label:"Selecciona un nodo o conexión")}</h2></div>{(selectedNode||selectedEdge)&&<button aria-label="Cerrar detalle" onClick={()=>{setSelectedNode(null);setSelectedEdge(null);setDrill(null);}}><X size={15}/></button>}</header>
        {!selectedNode&&!selectedEdge?<p className="bi-network__detail-empty">La selección muestra identidad canónica, métricas, fórmula, fuente, periodo y operaciones paginadas.</p>:selectedNode?<NodeDetail node={selectedNode} currency={result?.currency_code??null} period={`${applied.dateFrom} — ${applied.dateTo}`} onExpand={level=>void load(applied,selectedNode,level)} onOpen={()=>router.push(entityHref(selectedNode))}/>:<EdgeDetail edge={selectedEdge!} currency={result?.currency_code??null} drill={drill} page={drillPage} onPage={p=>void inspectEdge(selectedEdge!,p)} onOpenExplorer={()=>router.push(`/satrapy/bi/explorador?from=${applied.dateFrom}&to=${applied.dateTo}`)}/>}
      </aside>
    </div>
    {result&&<footer className="bi-network__method"><strong>Metodología</strong><span>{result.methodology.concentration}</span><span>{result.methodology.warning}</span><small>Actualizado {new Date(result.updated_at).toLocaleString("es-MX")} · periodo {result.period.from} a {result.period.to}</small></footer>}
  </section>;
}

function NetworkTables({result,onNode,onEdge}:{result:NetworkResult|null;onNode:(n:NetworkNode)=>void;onEdge:(e:NetworkEdge)=>void}){
  if(!result?.nodes.length)return <div className="data-state data-state--empty"><strong>No hay conexiones comprobadas.</strong><span>Amplía el periodo o retira filtros. Satrapy no inventa relaciones cuando falta evidencia.</span></div>;
  const byId=new Map(result.nodes.map(n=>[n.id,n]));
  return <div className="bi-network__tables"><section><h2>Nodos</h2><Table><thead><tr><th>Identidad</th><th>Tipo</th><th>Tamaño</th><th>Conexiones</th></tr></thead><tbody>{result.nodes.map(n=><tr key={n.id}><td><button className="table-link" onClick={()=>onNode(n)}>{n.label}</button><small>{n.secondary}</small></td><td>{NODE_META[n.type].label}</td><td>{n.size_value.toLocaleString("es-MX")}</td><td>{n.metrics.connections}</td></tr>)}</tbody></Table></section>
    <section><h2>Relaciones</h2><Table><thead><tr><th>Origen → destino</th><th>Tipo</th><th>Fuente métrica</th><th>Valor</th></tr></thead><tbody>{result.edges.map(e=><tr key={e.id}><td><button className="table-link" onClick={()=>onEdge(e)}>{byId.get(e.source)?.label} → {byId.get(e.target)?.label}</button></td><td>{RELATION_META[e.type].label}</td><td>{e.metric_source}</td><td>{e.weight.toLocaleString("es-MX")}</td></tr>)}</tbody></Table></section></div>;
}
function NodeDetail({node,currency,period,onExpand,onOpen}:{node:NetworkNode;currency:string|null;period:string;onExpand:(level:number)=>void;onOpen:()=>void}){
  const Icon=NODE_META[node.type].icon;
  return <><div className="bi-network__identity"><Icon size={18}/><div><Badge tone="info">{NODE_META[node.type].label}</Badge><small>{node.secondary} · {node.entity_id}</small></div></div>
    <dl><div><dt>Compras</dt><dd>{money(node.metrics.purchases,currency)}</dd></div><div><dt>Ventas</dt><dd>{money(node.metrics.sales,currency)}</dd></div><div><dt>Inventario</dt><dd>{node.metrics.inventory.toLocaleString("es-MX")}</dd></div><div><dt>Conexiones</dt><dd>{node.metrics.connections}</dd></div><div><dt>Concentración máxima</dt><dd>{(node.concentration*100).toFixed(1)}%</dd></div><div><dt>Periodo</dt><dd>{period}</dd></div></dl>
    {node.availability&&<p><strong>Estado operativo:</strong> {node.availability}. Esta señal no modifica la pertenencia al surtido.</p>}
    <div className="bi-network__detail-actions"><Button size="sm" onClick={()=>onExpand(1)}><Plus size={13}/>Expandir 1 nivel</Button><Button size="sm" variant="secondary" onClick={()=>onExpand(2)}><Expand size={13}/>2 niveles</Button><Button size="sm" variant="ghost" onClick={onOpen}>Abrir registro <ArrowUpRight size={13}/></Button></div></>;
}
function EdgeDetail({edge,currency,drill,page,onPage,onOpenExplorer}:{edge:NetworkEdge;currency:string|null;drill:Drill|null;page:number;onPage:(p:number)=>void;onOpenExplorer:()=>void}){
  return <><dl><div><dt>Dirección</dt><dd>Origen → destino</dd></div><div><dt>Importe</dt><dd>{money(edge.amount,currency)}</dd></div><div><dt>Cantidad</dt><dd>{edge.quantity.toLocaleString("es-MX")}</dd></div><div><dt>Frecuencia</dt><dd>{edge.frequency}</dd></div><div><dt>Concentración</dt><dd>{(edge.concentration_share*100).toFixed(1)}% · {edge.concentration_level}</dd></div><div><dt>Periodo evidencia</dt><dd>{edge.period.from??"Vigencia actual"} — {edge.period.to??"actual"}</dd></div></dl>
    <div className="bi-network__source"><strong>Fuente usada para la métrica</strong><span>{edge.metric_source}</span><small>Recepciones {edge.source_counts.receipts??0} · órdenes {edge.source_counts.orders??0} · adjudicaciones {edge.source_counts.awards??0} · cotizaciones {edge.source_counts.quotes??0}</small></div>
    {edge.operational_state&&<p><strong>Estado operativo:</strong> {edge.operational_state}. Surtido y readiness permanecen separados.</p>}
    <Button size="sm" variant="secondary" onClick={onOpenExplorer}>Abrir en Explorador <ArrowUpRight size={13}/></Button>
    <section className="bi-network__evidence"><h3>Operaciones que explican la relación</h3>{!drill?<LoaderCircle className="spin" size={16}/>:drill.items.length?<><ul>{drill.items.map(item=><li key={item.id}><strong>{item.reference??item.evidence_type}</strong><span>{item.location_name??""} {item.occurred_at?`· ${item.occurred_at}`:""}</span><small>{item.amount!=null?money(item.amount,currency):""}{item.quantity!=null?` · ${item.quantity} unidades`:""}</small></li>)}</ul><DataPagination page={page} pageSize={drill.pagination.page_size} total={drill.pagination.total} onChange={onPage}/></>:<p>Sin operaciones paginables adicionales.</p>}</section></>;
}
function entityHref(node:NetworkNode){return node.type==="supplier"?"/satrapy/compras/proveedores":node.type==="product"?"/satrapy/productos":node.type==="location"?"/satrapy/configuracion/ubicaciones":"/satrapy/productos";}

function NodeFilter({companyId,type,label,value,onChange}:{companyId:string;type:NodeType;label:string;value:string;onChange:(id:string)=>void}){
  const [text,setText]=useState(""),[options,setOptions]=useState<Array<{id:string;label:string;secondary?:string}>>([]);
  useEffect(()=>{if(text.trim().length<2)return;let cancelled=false;const timer=setTimeout(()=>{void getSupabaseClient().rpc("bi_search_dependency_nodes",
    {p_company_id:companyId,p_query:text,p_node_type:type,p_page:1,p_page_size:8}).then(response=>{if(!cancelled&&!response.error)setOptions(((response.data as{items:typeof options})?.items)??[]);});},220);
    return()=>{cancelled=true;clearTimeout(timer);};},[companyId,text,type]);
  return <label className="bi-network__node-filter">{label}<div><Input value={text} placeholder={value?"Filtro seleccionado":"Buscar…"} onChange={e=>{setText(e.target.value);if(!e.target.value)onChange("");}}/>{value&&<button type="button" aria-label={`Quitar ${label}`} onClick={()=>{onChange("");setText("");}}><X size={12}/></button>}</div>
    {text.trim().length>=2&&options.length>0&&<ul>{options.map(option=><li key={option.id}><button type="button" onClick={()=>{onChange(option.id);setText(option.label);setOptions([]);}}><strong>{option.label}</strong><small>{option.secondary}</small></button></li>)}</ul>}</label>;
}
