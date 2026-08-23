"use client";

import { ArrowLeft, ChefHat, PackageSearch, Plus, Search, Trash2 } from "lucide-react";
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { Badge, Button, Field, Input, Modal, Select, useToast } from "@/app/components/ui/primitives";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { getSupabaseClient } from "@/app/lib/supabase";

type ProductRef = { id:string; name:string };
type Candidate = { id:string; internal_sku:string; name:string; unit:string|null; is_inventory_tracked:boolean; recipe_kind:"preparation"|null; catalog_role:"ingredient"|"preparation"; usage_count:number };
type Line = { productId:string; productName:string; productCode:string; quantity:string; unitCode:string; baseUnitCode:string; recipeKind:"dish"|"preparation"|null };
type Version = { id:string; version_number:number; status:string; yield_quantity:number; yield_unit_code:string; portion_count:number; waste_percent:number; components?:Array<{product_id:string;product_name:string;product_code:string;entered_quantity:number;entered_unit_code:string;base_unit_code:string;recipe_kind:"dish"|"preparation"|null;catalog_role:"dish"|"ingredient"|"preparation"|null}>; cost?:{allowed:boolean;total_cost:number|null;cost_per_portion:number|null;currency_code:string;blockers:Array<{message:string}>} };
type Context = { product:ProductRef&{code:string}; recipe_id:string|null; draft:Version|null; active:Version|null; sale_price:number|null; currency_code:string };
type EditorStep = "components"|"yield";

const units = [
  {value:"mg",label:"mg"},{value:"g",label:"g"},{value:"kg",label:"kg"},
  {value:"ml",label:"ml"},{value:"l",label:"l"},{value:"piece",label:"pieza"},
];
const unitCode=(value:string|null)=>{const normalized=(value??"").trim().toLowerCase();return normalized==="pza"||normalized==="pieza"?"piece":units.some(unit=>unit.value===normalized)?normalized:"piece";};
const numberValue=(value:string)=>Number(value.replace(",","."));
const money=(value:number|null|undefined,currency:string)=>value==null?"Pendiente":new Intl.NumberFormat("es-MX",{style:"currency",currency,maximumFractionDigits:2}).format(value);
const message=(error:{message?:string}|null,fallback:string)=>error?.message?.includes("schema cache")?"Falta instalar la migración más reciente de recetas. Ejecuta las migraciones pendientes y vuelve a intentarlo.":error?.message?.replace(/^.*?error:\s*/i,"").trim()||fallback;

export function RecipeEditorModal({companyId,product,recipeKind="dish",open,onOpenChange,onCreateIngredient}:{companyId:string;product:ProductRef|null;recipeKind?:"dish"|"preparation";open:boolean;onOpenChange:(open:boolean)=>void;onCreateIngredient?:()=>void}) {
  const {toast}=useToast();
  const keys=useRef(new OperationIdempotencyKeys()).current;
  const searchId=useId();
  const yieldErrorId=useId();
  const wasteErrorId=useId();
  const searchInputRef=useRef<HTMLInputElement|null>(null);
  const searchPickerRef=useRef<HTMLDivElement|null>(null);
  const bodyRef=useRef<HTMLDivElement|null>(null);
  const [context,setContext]=useState<Context|null>(null);
  const [loading,setLoading]=useState(false);
  const [saving,setSaving]=useState(false);
  const [activating,setActivating]=useState(false);
  const [step,setStep]=useState<EditorStep>("components");
  const [yieldQuantity,setYieldQuantity]=useState("1");
  const [yieldUnit,setYieldUnit]=useState("ml");
  const [waste,setWaste]=useState("0");
  const [lines,setLines]=useState<Line[]>([]);
  const [query,setQuery]=useState("");
  const [searchOpen,setSearchOpen]=useState(false);
  const [candidates,setCandidates]=useState<Candidate[]>([]);
  const [searching,setSearching]=useState(false);
  const [searchError,setSearchError]=useState<string|null>(null);
  const [formError,setFormError]=useState<string|null>(null);

  const hydrate=useCallback((next:Context)=>{
    const version=next.draft??next.active;
    const divisor=recipeKind==="dish"?Math.max(Number(version?.portion_count??1),1):1;
    setContext(next);
    setYieldQuantity(recipeKind==="dish"?"1":String(version?.yield_quantity??1));
    setYieldUnit(recipeKind==="dish"?"piece":version?.yield_unit_code??"ml");
    setWaste(String(version?.waste_percent??0));
    setLines((version?.components??[]).map(item=>({productId:item.product_id,productName:item.product_name,productCode:item.product_code,quantity:String(Number(item.entered_quantity)/divisor),unitCode:item.entered_unit_code,baseUnitCode:item.base_unit_code,recipeKind:item.catalog_role==="dish"?"dish":item.catalog_role==="preparation"?"preparation":item.recipe_kind})));
  },[recipeKind]);
  const load=useCallback(async()=>{
    if(!product)return;
    setLoading(true);setFormError(null);
    const {data,error}=await getSupabaseClient().rpc("get_culinary_recipe_context",{p_company_id:companyId,p_product_id:product.id});
    setLoading(false);
    if(error){setFormError(message(error,"No se pudo abrir la receta. Actualiza e intenta nuevamente."));return;}
    hydrate(data as Context);
  },[companyId,hydrate,product]);

  useEffect(()=>{
    if(!open||!product)return;
    void Promise.resolve().then(()=>{setStep("components");setQuery("");setSearchOpen(false);setCandidates([]);setSearchError(null);setContext(null);setLines([]);setFormError(null);void load();});
  },[load,open,product]);
  useEffect(()=>{
    if(!searchOpen)return;
    const closeOnOutsidePress=(event:PointerEvent)=>{if(!searchPickerRef.current?.contains(event.target as Node))setSearchOpen(false);};
    document.addEventListener("pointerdown",closeOnOutsidePress);
    return()=>document.removeEventListener("pointerdown",closeOnOutsidePress);
  },[searchOpen]);
  useEffect(()=>{
    const trimmed=query.trim();
    if(!open)return;
    let active=true;
    const timer=window.setTimeout(async()=>{
      setSearching(true);setSearchError(null);
      const {data,error}=await getSupabaseClient().rpc("search_restaurant_recipe_components",{p_company_id:companyId,p_query:trimmed||null,p_page:1,p_page_size:20});
      if(!active)return;
      setSearching(false);
      if(error){setCandidates([]);setSearchError("No se pudieron cargar los insumos. Actualiza e intenta nuevamente.");return;}
      setCandidates(((data as {items?:Candidate[]}|null)?.items??[]).filter(item=>item.id!==product?.id&&!lines.some(line=>line.productId===item.id)));
    },trimmed?250:0);
    return()=>{active=false;window.clearTimeout(timer);};
  },[companyId,lines,open,product?.id,query]);

  const numeric=useMemo(()=>({yield:numberValue(yieldQuantity),waste:numberValue(waste)}),[waste,yieldQuantity]);
  const lineError=(line:Line)=>line.recipeKind==="dish"?"Un platillo no puede formar parte de otra receta. Quítalo y agrega sus insumos o una base.":numberValue(line.quantity)>0?null:"Escribe una cantidad mayor que cero.";
  const validLines=lines.length>0&&lines.every(line=>!lineError(line));
  const validDetails=numeric.waste>=0&&numeric.waste<100&&(recipeKind==="dish"||numeric.yield>0);
  const valid=validLines&&validDetails;
  const cost=context?.draft?.cost??context?.active?.cost;
  const stateLabel=context?.draft?"Borrador":context?.active?"Receta activa":"Sin receta";
  const stateTone=context?.draft?"warning":context?.active?"success":"neutral";

  function focusAfterRender(selector:string){window.requestAnimationFrame(()=>bodyRef.current?.querySelector<HTMLElement>(selector)?.focus());}
  function add(item:Candidate){const base=unitCode(item.unit);setLines(current=>[...current,{productId:item.id,productName:item.name,productCode:item.internal_sku,quantity:"1",unitCode:base,baseUnitCode:base,recipeKind:item.recipe_kind}]);setQuery("");setSearchOpen(false);setFormError(null);}
  function validateComponents(){
    if(!lines.length){setFormError("Agrega al menos un insumo o una base.");searchInputRef.current?.focus();return false;}
    if(!validLines){setFormError("Corrige los componentes marcados antes de continuar.");focusAfterRender('[data-recipe-line-invalid="true"] input, [data-recipe-line-invalid="true"] button');return false;}
    setFormError(null);return true;
  }
  function continueToYield(){if(validateComponents())setStep("yield");}
  function showValidation(){
    if(!validateComponents()){setStep("components");return;}
    if(recipeKind==="preparation")setStep("yield");
    setFormError(recipeKind==="preparation"?"Indica cuánto produce la tanda y revisa la merma.":"Revisa el ajuste de merma.");
    focusAfterRender('[data-recipe-detail][aria-invalid="true"]');
  }
  async function saveDraft(announce=true){
    if(!product)return null;
    if(!valid){showValidation();return null;}
    setSaving(true);setFormError(null);
    const components=lines.map((line,index)=>({product_id:line.productId,quantity:numberValue(line.quantity),unit_code:line.unitCode,base_unit_code:line.baseUnitCode,sort_order:index}));
    const recipeValues=recipeKind==="dish"?{yield:1,yieldUnit:"piece",portions:1}:{yield:numeric.yield,yieldUnit,portions:1};
    const fingerprint=JSON.stringify({product:product.id,recipeKind,recipeValues,waste:numeric.waste,components});
    const {data,error}=await getSupabaseClient().rpc("save_culinary_recipe_draft",{p_company_id:companyId,p_product_id:product.id,p_recipe_kind:recipeKind,p_yield_quantity:recipeValues.yield,p_yield_unit_code:recipeValues.yieldUnit,p_portion_count:recipeValues.portions,p_waste_percent:numeric.waste,p_components:components,p_client_request_id:keys.get("save-recipe",fingerprint),p_duplicate_from_version_id:context?.active?.id??null});
    setSaving(false);
    if(error){setFormError(message(error,"Revisa la receta e intenta guardarla nuevamente."));return null;}
    keys.clear("save-recipe");await load();
    if(announce)toast({title:"Borrador guardado",description:"La receta activa no cambia hasta que actives esta versión.",tone:"success"});
    return data as {version_id:string};
  }
  async function activate(){
    const saved=await saveDraft(false);if(!saved?.version_id)return;
    setActivating(true);
    const {error}=await getSupabaseClient().rpc("activate_culinary_recipe_version",{p_version_id:saved.version_id,p_expected_status:"draft"});
    setActivating(false);
    if(error){setFormError(message(error,"Corrige los pendientes e intenta activar de nuevo."));return;}
    await load();toast({title:"Receta activada",description:recipeKind==="dish"?"Las próximas ventas consumirán esta receta por porción.":"La base ya puede agregarse a otras recetas.",tone:"success"});
  }

  const saveActions=<><Button variant="secondary" loading={saving} disabled={activating} onClick={()=>void saveDraft()}>Guardar borrador</Button><Button variant="primary" loading={activating} disabled={saving} onClick={()=>void activate()}>Activar receta</Button></>;
  const footer=recipeKind==="preparation"&&step==="components"?<><Button variant="secondary" disabled={saving||activating} onClick={()=>onOpenChange(false)}>Cerrar</Button><Button variant="primary" disabled={saving||activating} onClick={continueToYield}>Continuar al rendimiento</Button></>:<>{recipeKind==="preparation"?<Button variant="secondary" disabled={saving||activating} onClick={()=>{setFormError(null);setStep("components");}}><ArrowLeft size={16} aria-hidden="true"/> Volver a componentes</Button>:<Button variant="secondary" disabled={saving||activating} onClick={()=>onOpenChange(false)}>Cerrar</Button>}{saveActions}</>;

  const summary=recipeKind==="dish"?<section className="recipe-editor__summary" aria-live="polite"><div><small>Costo por porción</small><strong>{money(cost?.cost_per_portion,context?.currency_code??"MXN")}</strong></div><div><small>Precio de venta</small><strong>{money(context?.sale_price,context?.currency_code??"MXN")}</strong></div><div><small>Margen estimado</small><strong>{context?.sale_price!=null&&cost?.cost_per_portion!=null?money(context.sale_price-cost.cost_per_portion,context.currency_code):"Pendiente"}</strong></div><small className="recipe-editor__summary-note">El costo se actualiza al guardar.</small>{cost&&!cost.allowed&&<p>{cost.blockers?.[0]?.message??"Completa el costo de los insumos para calcular el margen."}</p>}</section>:<section className="recipe-editor__summary recipe-editor__summary--preparation" aria-live="polite"><div><small>Costo de la tanda</small><strong>{money(cost?.total_cost,context?.currency_code??"MXN")}</strong></div><div><small>Rendimiento</small><strong>{yieldQuantity||"—"} {units.find(unit=>unit.value===yieldUnit)?.label??yieldUnit}</strong></div><div><small>Componentes</small><strong>{lines.length}</strong></div><small className="recipe-editor__summary-note">El costo se actualiza al guardar.</small>{cost&&!cost.allowed&&<p>{cost.blockers?.[0]?.message??"Completa el costo de los insumos para calcular esta base."}</p>}</section>;

  return <Modal open={open} onOpenChange={value=>{if(!saving&&!activating)onOpenChange(value);}} eyebrow={recipeKind==="preparation"?"Base reutilizable":"Platillo"} title={product?.name??(recipeKind==="preparation"?"Nueva base":"Nuevo platillo")} description={recipeKind==="preparation"?"Define qué lleva una tanda y cuánto produce.":"Captura únicamente lo que consume una porción."} className="recipe-editor" closeDisabled={saving||activating} footer={footer}>
    {loading?<p className="recipe-editor__loading" role="status">Cargando receta…</p>:<div ref={bodyRef} className="recipe-editor__body">
      {recipeKind==="preparation"?<div className="recipe-editor__progress"><ol aria-label="Pasos para armar la receta"><li aria-current={step==="components"?"step":undefined} className={step==="components"?"is-current":"is-complete"}><span>1</span><strong>Componentes</strong></li><li aria-current={step==="yield"?"step":undefined} className={step==="yield"?"is-current":undefined}><span>2</span><strong>Rendimiento</strong></li></ol><Badge tone={stateTone}>{stateLabel}</Badge></div>:<div className="recipe-editor__single-header"><Badge tone={stateTone}>{stateLabel}</Badge><span>Las cantidades siempre corresponden a una porción.</span></div>}
      {formError&&<p className="recipe-editor__error" role="alert">{formError}</p>}
      {step==="components"?<section className="recipe-editor__ingredients" aria-labelledby="recipe-ingredients-title">
        <header><div>{recipeKind==="preparation"&&<span className="recipe-editor__step-label">Paso 1 de 2</span>}<h3 id="recipe-ingredients-title">{recipeKind==="preparation"?"¿Qué lleva una tanda?":"Receta por porción"}</h3><p>{recipeKind==="preparation"?"Agrega insumos u otras bases que ya tengan una receta activa.":"Agrega insumos o bases activas. No agregues otros platillos."}</p></div><Badge tone={lines.length?"success":"warning"}>{lines.length} {lines.length===1?"componente":"componentes"}</Badge></header>
        <div ref={searchPickerRef} className="recipe-editor__component-search"><label htmlFor={searchId}>Buscar insumo o base</label><div className="recipe-editor__search"><Search size={17} aria-hidden="true"/><Input ref={searchInputRef} id={searchId} autoFocus value={query} onFocus={()=>setSearchOpen(true)} onChange={event=>{setQuery(event.target.value);setSearchOpen(true);}} onKeyDown={event=>{if(event.key==="Escape"){event.preventDefault();setSearchOpen(false);}}} placeholder="Ej. pollo, jitomate o salsa roja" aria-describedby={`${searchId}-hint`} aria-expanded={searchOpen} aria-controls={`${searchId}-results`} aria-haspopup="listbox"/></div><small id={`${searchId}-hint`}>Los insumos aparecen automáticamente. Las bases aparecen cuando su receta está activa.</small>{searchOpen&&<div id={`${searchId}-results`} className="recipe-editor__results" aria-label="Insumos y bases disponibles" aria-live="polite">{searching?<p role="status">Cargando insumos…</p>:searchError?<div className="recipe-editor__no-results" role="alert"><p>{searchError}</p></div>:candidates.length?candidates.map(item=><button type="button" key={item.id} onClick={()=>add(item)}><span><strong>{item.name}</strong><small>{item.internal_sku} · {item.recipe_kind==="preparation"?"Base reutilizable":item.unit??"Sin unidad"}{item.usage_count>0?` · ${item.usage_count} ${item.usage_count===1?"receta":"recetas"}`:""}</small></span><Plus size={17} aria-hidden="true"/></button>):<div className="recipe-editor__no-results"><p>{query.trim()?"No hay un insumo o base activa con ese nombre.":"Aún no hay insumos disponibles para esta receta."}</p>{onCreateIngredient&&lines.length===0&&<Button type="button" size="sm" variant="secondary" onClick={onCreateIngredient}><Plus size={15} aria-hidden="true"/> Crear insumo</Button>}</div>}</div>}</div>
        <div className="recipe-editor__lines">{lines.length?<><div className="recipe-editor__line-head" aria-hidden="true"><span>Insumo o base</span><span>Cantidad</span><span>Unidad</span><span/></div>{lines.map((line,index)=>{const currentError=lineError(line);const errorId=`recipe-line-error-${line.productId}`;return <article key={line.productId} data-recipe-line-invalid={currentError?"true":undefined} className={currentError?"is-invalid":undefined}><div className="recipe-editor__line-name">{line.recipeKind==="preparation"?<ChefHat size={17} aria-hidden="true"/>:<PackageSearch size={17} aria-hidden="true"/>}<span><strong>{line.productName}</strong><small>{line.productCode}{line.recipeKind==="preparation"?" · Base reutilizable":line.recipeKind==="dish"?" · Platillo no permitido":" · Insumo"}</small>{line.recipeKind==="dish"&&<small id={errorId} className="recipe-editor__line-error">{currentError}</small>}</span></div><label className="recipe-editor__line-control"><span className="sr-only">Cantidad de {line.productName}</span><Input data-recipe-quantity inputMode="decimal" aria-label={`Cantidad de ${line.productName}`} aria-invalid={Boolean(currentError)||undefined} aria-describedby={currentError?errorId:undefined} value={line.quantity} onChange={event=>setLines(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,quantity:event.target.value}:item))}/>{currentError&&line.recipeKind!=="dish"&&<small id={errorId} className="ui-field__error">{currentError}</small>}</label><div className="recipe-editor__line-control"><Select value={line.unitCode} onValueChange={value=>setLines(current=>current.map((item,itemIndex)=>itemIndex===index?{...item,unitCode:value}:item))} ariaLabel={`Unidad de ${line.productName}`} options={units}/></div><Button size="icon" variant="ghost" aria-label={`Quitar ${line.productName}`} onClick={()=>setLines(current=>current.filter(item=>item.productId!==line.productId))}><Trash2 size={16} aria-hidden="true"/></Button></article>;})}</>:<div className="recipe-editor__empty"><ChefHat size={22} aria-hidden="true"/><strong>Aún no agregas componentes</strong><p>{candidates.length?"Selecciona un insumo o una base de la lista para comenzar.":"Busca un insumo o crea el primero para comenzar."}</p>{onCreateIngredient&&!candidates.length&&!searching&&!searchError&&<Button type="button" size="sm" variant="secondary" onClick={onCreateIngredient}><Plus size={15} aria-hidden="true"/> Crear primer insumo</Button>}</div>}</div>
        {recipeKind==="dish"&&<><details className="recipe-editor__advanced"><summary>Ajuste opcional de merma</summary><p>Déjalo en 0 si todavía no has medido una merma general.</p><Field label="Merma porcentual"><Input data-recipe-detail inputMode="decimal" aria-invalid={(numeric.waste<0||numeric.waste>=100)||undefined} aria-describedby={numeric.waste<0||numeric.waste>=100?wasteErrorId:undefined} value={waste} onChange={event=>setWaste(event.target.value)}/>{(numeric.waste<0||numeric.waste>=100)&&<small id={wasteErrorId} className="ui-field__error">Usa un porcentaje entre 0 y 99.99.</small>}</Field></details>{summary}</>}
      </section>:<section className="recipe-editor__details" aria-labelledby="recipe-yield-title">
        <header><span className="recipe-editor__step-label">Paso 2 de 2</span><h3 id="recipe-yield-title">¿Cuánto produce una tanda?</h3><p>Este rendimiento permite usar la cantidad correcta de la base en otros platillos.</p></header>
        <div className="recipe-editor__setup-fields recipe-editor__setup-fields--primary"><Field label="Cantidad producida"><Input data-recipe-detail inputMode="decimal" aria-invalid={numeric.yield<=0||undefined} aria-describedby={numeric.yield<=0?yieldErrorId:undefined} value={yieldQuantity} onChange={event=>setYieldQuantity(event.target.value)}/>{numeric.yield<=0&&<small id={yieldErrorId} className="ui-field__error">Escribe una cantidad mayor que cero.</small>}</Field><Field label="Unidad del rendimiento"><Select value={yieldUnit} onValueChange={setYieldUnit} ariaLabel="Unidad del rendimiento" options={units}/></Field></div>
        <details className="recipe-editor__advanced"><summary>Ajuste opcional de merma</summary><p>Déjalo en 0 si el rendimiento capturado ya es el rendimiento final.</p><Field label="Merma porcentual"><Input data-recipe-detail inputMode="decimal" aria-invalid={(numeric.waste<0||numeric.waste>=100)||undefined} aria-describedby={numeric.waste<0||numeric.waste>=100?wasteErrorId:undefined} value={waste} onChange={event=>setWaste(event.target.value)}/>{(numeric.waste<0||numeric.waste>=100)&&<small id={wasteErrorId} className="ui-field__error">Usa un porcentaje entre 0 y 99.99.</small>}</Field></details>
        <section className="recipe-editor__review" aria-labelledby="recipe-review-title"><div><h4 id="recipe-review-title">Revisión de la tanda</h4><p>{lines.length} {lines.length===1?"componente":"componentes"} · {yieldQuantity||"—"} {units.find(unit=>unit.value===yieldUnit)?.label??yieldUnit}</p></div><Badge tone={valid?"success":"warning"}>{valid?"Lista para guardar":"Revisa los datos"}</Badge></section>
        {summary}
      </section>}
    </div>}
  </Modal>;
}
