"use client";

import { ChefHat, Plus, RefreshCw } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ProductCommercializationModal } from "@/app/components/ProductCommercializationModal";
import { RecipeEditorModal } from "@/app/components/RecipeEditorModal";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Drawer, Field, Input, Select, useToast } from "@/app/components/ui/primitives";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { productReadinessSummary } from "@/app/lib/product-readiness";
import { productVocabulary, type ProductExperience } from "@/app/lib/product-experience";
import { getSupabaseClient } from "@/app/lib/supabase";

const PAGE_SIZE = 50;
type RestaurantCatalogRole = "dish" | "ingredient" | "preparation";
type ProductListRow = { id:string; internal_sku:string; alpha_sku:string|null; name:string; attribute:string|null; barcode:string|null; unit:string|null; product_group:string|null; inventory_policy:"tracked"|"not_required"|"unclassified"; is_active:boolean; is_sellable:boolean; is_inventory_tracked:boolean; price:number|null; currency_code:string|null; pos_ready:boolean; blockers?:string[]; catalog_role?:RestaurantCatalogRole; is_preparation?:boolean };
type TaxCategory = { id:string; code:string; name:string; rate:number|null; is_active:boolean };
type ProductCostContext = { product:{id:string;name:string}; cost_method:"replacement_cost"|"standard_cost"|"average_cost"|null; currency_code:string|null; matrix_ready:boolean; current_cost:{id:string;amount:number;valid_from:string}|null };
type ProductPurchaseUnit = { base_unit:string|null; purchase_unit:string|null; base_units_per_purchase_unit:number };
type ProductDraft = { id:string|null; internalSku:string; name:string; barcode:string; unit:string; productGroup:string; taxCategoryId:string; inventoryPolicy:"tracked"|"not_required"|"unclassified"; lotControlled:boolean; sellable:boolean; active:boolean; reason:string; updatedAt:string|null; sourceReference:string|null };
const emptyDraft = (): ProductDraft => ({ id:null, internalSku:"", name:"", barcode:"", unit:"", productGroup:"", taxCategoryId:"", inventoryPolicy:"tracked", lotControlled:false, sellable:true, active:true, reason:"",updatedAt:null,sourceReference:null });
function errorMessage(error:{message?:string}|null, fallback:string) { return error?.message?.replace(/^.*?error:\s*/i, "").trim() || fallback; }
function catalogLoadError(error:{message?:string}|null, label:string) {
  const raw=error?.message?.toLowerCase()??"";
  return raw.includes("schema cache")||raw.includes("does not exist")||raw.includes("could not find the function")
    ? `Falta instalar la migración de catálogo culinario (202608170006) para cargar ${label}.`
    : `No se pudieron cargar los ${label}.`;
}
function numberFormat(value:number) { return new Intl.NumberFormat("es-MX", { maximumFractionDigits:3 }).format(value); }
function costMethodLabel(value:ProductCostContext["cost_method"]) { return value==="replacement_cost"?"Costo de reposición":value==="standard_cost"?"Costo estándar":value==="average_cost"?"Costo promedio":"Sin método activo"; }

export function ProductCatalogView({ companyId, permissions, experience="core" }: { companyId:string; permissions:string[]; experience?:ProductExperience }) {
  const words = productVocabulary(experience);
  const router = useRouter();
  const searchParams = useSearchParams();
  const catalogRole: RestaurantCatalogRole = experience === "restaurant" && searchParams.get("seccion") === "preparaciones" ? "preparation" : experience === "restaurant" && searchParams.get("seccion") === "insumos" ? "ingredient" : "dish";
  const catalogPlural = experience === "restaurant" ? (catalogRole === "ingredient" ? "insumos" : catalogRole === "preparation" ? "preparaciones" : "platillos") : words.plural;
  const catalogSingular = experience === "restaurant" ? (catalogRole === "ingredient" ? "insumo" : catalogRole === "preparation" ? "preparación" : "platillo") : words.singular;
  const catalogPluralTitle = experience === "restaurant" ? (catalogRole === "ingredient" ? "Insumos" : catalogRole === "preparation" ? "Preparaciones" : "Platillos") : words.pluralTitle;
  const catalogSingularTitle = experience === "restaurant" ? (catalogRole === "ingredient" ? "Insumo" : catalogRole === "preparation" ? "Preparación" : "Platillo") : words.singularTitle;
  const catalogAllLabel = catalogRole === "preparation" ? "Todas las preparaciones" : `Todos los ${catalogPlural}`;
  const catalogSmallQuantity = catalogRole === "preparation" ? "pocas preparaciones" : `pocos ${catalogPlural}`;
  const catalogGuidance = catalogRole === "ingredient"
    ? {title:"Materia prima e inventario",description:"Los insumos son lo que compras, recibes y controlas en existencia para usar en recetas."}
    : catalogRole === "preparation"
      ? {title:"Bases internas reutilizables",description:"Las preparaciones son bases como salsas o caldos: se hacen con insumos y se usan dentro de platillos."}
      : {title:"Lo que vendes al cliente",description:"Los platillos son los artículos del punto de venta; su receta puede incluir insumos y preparaciones."};
  const catalogInformationTitle = catalogRole === "preparation" ? "Información de la preparación" : experience === "restaurant" ? `Información del ${catalogSingular}` : "Información básica";
  const catalogNameLabel = catalogRole === "preparation" ? "Nombre de la preparación" : experience === "restaurant" ? `Nombre del ${catalogSingular}` : "Nombre del producto";
  const canManage = permissions.includes("manage_products");
  const canManageAssortments = permissions.includes("manage_assortments");
  const canManageCosts = permissions.includes("import_costs");
  const canManageRecipes = experience==="restaurant"&&permissions.includes("manage_recipes");
  const { queryCache } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const requestId = useRef(0);
  const [rows,setRows] = useState<ProductListRow[]>([]); const [loading,setLoading] = useState(true); const [error,setError] = useState<string|null>(null);
  const [search,setSearch] = useState(""); const [debouncedSearch,setDebouncedSearch] = useState(""); const [saleFilter,setSaleFilter] = useState("all"); const [page,setPage] = useState(1); const [total,setTotal] = useState(0);
  const [draft,setDraft] = useState<ProductDraft|null>(null); const [detailLoading,setDetailLoading] = useState(false); const [saving,setSaving] = useState(false);
  const [commercialProduct,setCommercialProduct] = useState<{id:string;name:string}|null>(null);
  const [recipeProduct,setRecipeProduct] = useState<{id:string;name:string;recipeKind:"dish"|"preparation"}|null>(null);
  const [commercialReason,setCommercialReason] = useState("");
  const [costContext,setCostContext] = useState<ProductCostContext|null>(null);
  const [costDraft,setCostDraft] = useState({amount:"",reason:""});
  const [savingCost,setSavingCost] = useState(false);
  const [purchaseUnit,setPurchaseUnit] = useState({code:"",factor:"1"});
  const [taxCategories,setTaxCategories] = useState<TaxCategory[]>([]); const [taxDraft,setTaxDraft] = useState<{code:string;name:string;rate:string;reason:string}>({code:"",name:"",rate:"16",reason:""}); const [savingTax,setSavingTax] = useState(false);
  const [taxEditorOpen,setTaxEditorOpen] = useState(false);
  const catalogFormTitle = draft?.id ? `Editar ${catalogSingular}` : catalogRole === "preparation" ? "Nueva preparación" : `Nuevo ${catalogSingular}`;

  useEffect(() => { const timer=window.setTimeout(() => { setDebouncedSearch(search.trim()); setPage(1); },280); return () => window.clearTimeout(timer); },[search]);
  const load = useCallback(async (force=false) => {
    const isSellable=saleFilter==="sellable"?true:saleFilter==="not_sellable"?false:null;
    const key=`products:${companyId}:${catalogRole}:${debouncedSearch}:${saleFilter}:${page}`;
    const cached=!force?queryCache.get<{rows:ProductListRow[];total:number}>(key):null;
    if(cached){setRows(cached.rows);setTotal(cached.total);setLoading(false);setError(null);return;}
    const current=++requestId.current; setLoading(true);setError(null);
    const response=experience === "restaurant"
      ? await getSupabaseClient().rpc("search_restaurant_catalog",{p_company_id:companyId,p_role:catalogRole,p_query:debouncedSearch||null,p_page:page,p_page_size:PAGE_SIZE,p_is_sellable:isSellable})
      : await getSupabaseClient().rpc("search_products",{p_company_id:companyId,p_query:debouncedSearch||null,p_page:page,p_page_size:PAGE_SIZE,p_is_sellable:isSellable});
    const {data,error:queryError}=response;
    if(current!==requestId.current)return;
    const result=data as {items?:ProductListRow[];total?:number}|null; const next={rows:result?.items??[],total:result?.total??0};
    queryCache.set(key,next);setRows(next.rows);setTotal(next.total);setError(queryError?catalogLoadError(queryError,catalogPlural):null);setLoading(false);
  },[catalogPlural,catalogRole,companyId,debouncedSearch,experience,page,queryCache,saleFilter]);
  useEffect(() => { void Promise.resolve().then(() => load()); },[load]);
  const loadTaxCategories = useCallback(async () => {
    const {data,error:taxError}=await getSupabaseClient().rpc("list_tax_categories_admin",{p_company_id:companyId});
    if(taxError){toast({title:"No se pudieron cargar las categorías fiscales",description:errorMessage(taxError,"Actualiza e intenta de nuevo."),tone:"error"});return;}
    setTaxCategories((data??[]) as TaxCategory[]);
  },[companyId,toast]);
  async function refresh(){queryCache.invalidate(`products:${companyId}:`);await load(true);}
  async function openEdit(row:ProductListRow){
    if(!canManage)return; setDetailLoading(true);
    setTaxEditorOpen(false);
    if(experience === "restaurant" && row.catalog_role) {
      router.replace(row.catalog_role === "ingredient" ? "/satrapy/inventario/productos?seccion=insumos" : row.catalog_role === "preparation" ? "/satrapy/inventario/productos?seccion=preparaciones" : "/satrapy/inventario/productos");
    }
    const client=getSupabaseClient();
    const [{data,error:detailError},costResult,purchaseResult]=await Promise.all([
      client.from("products").select("id, internal_sku, alpha_sku, name, barcode, unit, product_group, tax_category_id, inventory_policy, is_inventory_tracked, lot_controlled, is_sellable, is_active, updated_at").eq("company_id",companyId).eq("id",row.id).single(),
      canManageCosts?client.rpc("get_product_cost_admin_context",{p_company_id:companyId,p_product_id:row.id}):Promise.resolve({data:null,error:null}),
      client.rpc("get_product_purchase_unit",{p_company_id:companyId,p_product_id:row.id}),
    ]);
    setDetailLoading(false);
    if(detailError||!data){toast({title:`No se pudo abrir el ${words.singular}`,description:errorMessage(detailError,"Actualiza la lista e intenta nuevamente."),tone:"error"});return;}
    if(costResult.error){toast({title:"No se pudo consultar el costo",description:errorMessage(costResult.error,`Puedes editar el ${words.singular}, pero no su valuación.`),tone:"error"});}
    const nextCost=(costResult.data??null) as ProductCostContext|null;
    setCostContext(nextCost);
    setCostDraft({amount:nextCost?.current_cost?.amount?.toString()??"",reason:""});
    const nextPurchase=(purchaseResult.data??null) as ProductPurchaseUnit|null;
    setPurchaseUnit({code:nextPurchase?.purchase_unit??data.unit??"",factor:String(nextPurchase?.base_units_per_purchase_unit??1)});
    await loadTaxCategories();
    setDraft({id:data.id,internalSku:data.internal_sku,name:data.name,barcode:data.barcode??"",unit:data.unit??"",productGroup:data.product_group??"",taxCategoryId:data.tax_category_id??"",inventoryPolicy:data.inventory_policy==="tracked"||data.inventory_policy==="not_required"?data.inventory_policy:"unclassified",lotControlled:data.lot_controlled,sellable:data.is_sellable,active:data.is_active,reason:"",updatedAt:data.updated_at,sourceReference:data.alpha_sku});
  }
  async function openNew(role:RestaurantCatalogRole=catalogRole){await loadTaxCategories();setTaxEditorOpen(false);setCostContext(null);setCostDraft({amount:"",reason:""});setPurchaseUnit({code:"",factor:"1"});setDraft({...emptyDraft(),inventoryPolicy:experience==="restaurant"&&role!=="ingredient"?"not_required":"tracked",sellable:experience!=="restaurant"||role==="dish"});}
  async function saveCurrentCost(){
    if(!draft?.id||!costContext)return;
    const amount=Number(costDraft.amount.replace(",","."));
    if(!Number.isFinite(amount)||amount<=0||!costDraft.reason.trim())return;
    setSavingCost(true);
    const {data,error:costError}=await getSupabaseClient().rpc("set_product_current_cost",{p_company_id:companyId,p_product_id:draft.id,p_amount:amount,p_reason:costDraft.reason.trim(),p_expected_cost_id:costContext.current_cost?.id??null});
    if(costError)toast({title:"No se pudo guardar el costo",description:errorMessage(costError,"Verifica los datos e intenta nuevamente."),tone:"error"});
    else{
      const next=data as ProductCostContext;
      setCostContext(next);
      setCostDraft({amount:next.current_cost?.amount?.toString()??"",reason:""});
      toast({title:"Costo vigente actualizado",description:"La valuación quedó registrada con método, moneda, vigencia y motivo.",tone:"success"});
    }
    setSavingCost(false);
  }
  async function saveTaxCategory(){
    if(!draft)return; const rate=Number(taxDraft.rate.replace(",","."));
    if(!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()||!Number.isFinite(rate)||rate<0||rate>100)return;
    const fingerprint=JSON.stringify(taxDraft);setSavingTax(true);
    const {data,error:taxError}=await getSupabaseClient().rpc("save_tax_category",{p_company_id:companyId,p_code:taxDraft.code.trim().toUpperCase(),p_name:taxDraft.name.trim(),p_rate:rate/100,p_reason:taxDraft.reason.trim(),p_client_request_id:idempotency.get("save-tax-category",fingerprint)});
    if(taxError)toast({title:"No se pudo guardar la categoría fiscal",description:errorMessage(taxError,"Verifica los datos e intenta nuevamente."),tone:"error"});
    else {
      const category=data as TaxCategory;
      if(!category?.id){
        toast({title:"No se pudo seleccionar la categoría fiscal",description:"La categoría se creó, pero el servidor no devolvió su identificador. Actualiza e intenta de nuevo.",tone:"error"});
      }else{
        idempotency.clear("save-tax-category");
        setTaxCategories(current=>current.some(item=>item.id===category.id)?current:[...current,category]);
        setDraft(current=>current?{...current,taxCategoryId:category.id}:current);
        setTaxDraft({code:"",name:"",rate:"16",reason:""});
        await loadTaxCategories();
        toast({title:"Categoría fiscal seleccionada",description:`Guarda los cambios del ${words.singular} para aplicar ${category.name}.`,tone:"success"});
      }
    }
    setSavingTax(false);
  }
  async function saveProduct(event:FormEvent){
    event.preventDefault();if(!draft)return;
    const normalized={...draft,internalSku:draft.internalSku.trim().toUpperCase(),name:draft.name.trim(),reason:draft.reason.trim()};
    if(!normalized.name||!normalized.reason)return;
    const selectedTaxCategoryId=normalized.taxCategoryId||null;
    const fingerprint=JSON.stringify(normalized);setSaving(true);
    const client=getSupabaseClient();
    const {data,error:saveError}=await client.rpc("save_product",{p_company_id:companyId,p_product_id:normalized.id,p_internal_sku:normalized.internalSku,p_name:normalized.name,p_barcode:normalized.barcode.trim()||null,p_unit:normalized.unit.trim()||null,p_product_group:normalized.productGroup.trim()||null,p_inventory_policy:normalized.inventoryPolicy,p_is_sellable:normalized.sellable,p_is_active:normalized.active,p_tax_category_id:selectedTaxCategoryId,p_reason:normalized.reason,p_expected_updated_at:normalized.updatedAt,p_client_request_id:idempotency.get("save-product",fingerprint)});
    if(saveError)toast({title:`No se pudo guardar el ${catalogSingular}`,description:errorMessage(saveError,"Verifica los datos e intenta nuevamente."),tone:"error"});
    else{
      const saved=data as {id:string;name:string;tax_category_id:string|null;updated_at:string}|null;
      if(saved?.id){
        const {data:confirmed,error:verificationError}=await client.from("products").select("id, tax_category_id, updated_at").eq("company_id",companyId).eq("id",saved.id).single();
        if(verificationError||confirmed.tax_category_id!==selectedTaxCategoryId){
          idempotency.clear("save-product");
          setDraft(current=>current?{...current,updatedAt:confirmed?.updated_at??saved.updated_at??current.updatedAt}:current);
          setSaving(false);
          toast({title:`El ${catalogSingular} se guardó sin el IVA seleccionado`,description:"El formulario quedó abierto. Vuelve a seleccionar la categoría fiscal e intenta guardar de nuevo.",tone:"error"});
          return;
        }
      }
      const purchaseCode=(purchaseUnit.code.trim()||normalized.unit.trim()).toUpperCase();
      const purchaseFactor=Number(purchaseUnit.factor.replace(",","."));
      if(normalized.inventoryPolicy==="tracked"&&purchaseCode&&Number.isFinite(purchaseFactor)&&purchaseFactor>0&&saved?.id){
        const purchaseFingerprint=JSON.stringify({productId:saved.id,purchaseCode,purchaseFactor,reason:normalized.reason});
        const {error:purchaseError}=await getSupabaseClient().rpc("set_product_purchase_unit",{p_company_id:companyId,p_product_id:saved.id,p_purchase_unit_code:purchaseCode,p_base_units_per_purchase_unit:purchaseFactor,p_reason:normalized.reason,p_client_request_id:idempotency.get("save-product-purchase-unit",purchaseFingerprint)});
        if(purchaseError){setSaving(false);toast({title:`${catalogSingularTitle} guardado; falta la conversión`,description:errorMessage(purchaseError,"Corrige la unidad de compra e intenta nuevamente."),tone:"error"});return;}
        idempotency.clear("save-product-purchase-unit");
      }
      if(saved?.id&&(normalized.id!==null||normalized.lotControlled)){
        const lotFingerprint=JSON.stringify({productId:saved.id,lotControlled:normalized.lotControlled,reason:normalized.reason});
        const {error:lotError}=await getSupabaseClient().rpc("set_product_lot_controlled",{p_company_id:companyId,p_product_id:saved.id,p_lot_controlled:normalized.inventoryPolicy==="tracked"&&normalized.lotControlled,p_reason:normalized.reason,p_client_request_id:idempotency.get("save-product-lot-control",lotFingerprint)});
        if(lotError){setSaving(false);toast({title:`${catalogSingularTitle} guardado; falta el control de lote`,description:errorMessage(lotError,"Vuelve a guardar para aplicar la configuración de lotes."),tone:"error"});return;}
        idempotency.clear("save-product-lot-control");
      }
      idempotency.clear("save-product");setDraft(null);setPage(1);await refresh();
      const opensRecipe=experience==="restaurant"&&(catalogRole==="dish"||catalogRole==="preparation")&&!normalized.id&&Boolean(saved?.id)&&canManageRecipes;
      toast({title:normalized.id?`${catalogSingularTitle} actualizado`:`${catalogSingularTitle} creado`,description:opensRecipe?"Ahora agrega los insumos y activa la receta.":!normalized.id&&normalized.sellable&&canManageAssortments?"Ahora define en qué surtidos se ofrecerá.":"El cambio quedó registrado en auditoría.",tone:"success"});
      if(opensRecipe&&saved?.id){
        setRecipeProduct({id:saved.id,name:saved.name??normalized.name,recipeKind:catalogRole==="preparation"?"preparation":"dish"});
      }else if(!normalized.id&&normalized.sellable&&canManageAssortments&&saved?.id){
        setCommercialReason(`Alta del ${catalogSingular} y definición de su comercialización`);
        setCommercialProduct({id:saved.id,name:saved.name??normalized.name});
      }
    }
    setSaving(false);
  }
  function clearFilters(){setSearch("");setDebouncedSearch("");setSaleFilter("all");setPage(1);}
  return <div className="content-frame product-catalog">
    <PageHeading eyebrow={experience === "restaurant" ? "Operación culinaria" : "Catálogo administrable"} title={catalogPluralTitle} description={experience==="restaurant"?(catalogRole === "ingredient"?"Registra los insumos que se reciben y se consumen en las recetas.":catalogRole === "preparation"?"Crea bases intermedias, como salsas o caldos, para reutilizarlas en varias recetas.":"Crea y mantiene sólo los platillos que se ofrecen en el punto de venta."):"Crea y mantiene productos canónicos de Satrapy. La importación acelera cargas grandes, pero no es necesaria para operar."} action={<div className="product-catalog__heading-actions"><Button variant="secondary" onClick={() => void refresh()}><RefreshCw size={16}/> Actualizar</Button>{canManage&&<Button variant="primary" onClick={() => void openNew()}><Plus size={16}/> {catalogRole === "preparation" ? "Nueva preparación" : `Nuevo ${catalogSingular}`}</Button>}</div>}/>
    {experience === "restaurant" && <nav className="restaurant-catalog-tabs" aria-label="Catálogo culinario"><button type="button" className={catalogRole === "dish" ? "is-active" : undefined} aria-current={catalogRole === "dish" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos"); setPage(1); }}>Platillos</button><button type="button" className={catalogRole === "ingredient" ? "is-active" : undefined} aria-current={catalogRole === "ingredient" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos?seccion=insumos"); setPage(1); }}>Insumos</button><button type="button" className={catalogRole === "preparation" ? "is-active" : undefined} aria-current={catalogRole === "preparation" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos?seccion=preparaciones"); setPage(1); }}>Preparaciones</button></nav>}
    {experience === "restaurant" ? <section className="product-catalog__guidance" aria-labelledby="restaurant-catalog-guidance"><div className="product-catalog__guidance-definition"><strong id="restaurant-catalog-guidance">{catalogGuidance.title}</strong><p>{catalogGuidance.description}</p></div><div className="product-catalog__guidance-capture"><strong>Cómo agregar</strong><p>Captura aquí {catalogSmallQuantity} o correcciones puntuales. Para catálogos extensos, usa la importación masiva.</p></div></section> : <p className="product-catalog__volume-note"><strong>Captura individual:</strong> úsala para {catalogSmallQuantity} o correcciones puntuales. Para catálogos extensos, conserva la importación masiva.</p>}
    <DataToolbar search={search} onSearchChange={setSearch} placeholder={experience === "restaurant" && catalogRole === "ingredient" ? "Buscar insumo por nombre o código" : experience === "restaurant" && catalogRole === "preparation" ? "Buscar preparación por nombre o código" : "Buscar código Satrapy, código de barras, alias o nombre"} filters={<Select value={saleFilter} onValueChange={value=>{setSaleFilter(value);setPage(1);}} ariaLabel="Filtrar por disponibilidad de venta" options={[{value:"all",label:catalogAllLabel},{value:"sellable",label:"Vendibles"},{value:"not_sellable",label:"No vendibles"}]}/>} activeFilters={(search.trim()?1:0)+(saleFilter!=="all"?1:0)} onClear={clearFilters} results={total}/>
    <DataRefreshStatus loading={loading} hasData={rows.length}/>{detailLoading&&<div className="inline-status" role="status">Abriendo {catalogSingular}…</div>}
    <DataState loading={loading&&rows.length===0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={() => void refresh()}>Reintentar</Button>} hasData={rows.length} emptyTitle={search||saleFilter!=="all"?"Sin coincidencias":catalogRole === "preparation"?"Aún no hay preparaciones":`Aún no hay ${catalogPlural}`} empty={search||saleFilter!=="all"?`No hay ${catalogPlural} que coincidan con estos criterios.`:canManage?(catalogRole === "preparation"?"Crea la primera preparación para comenzar a operar.":`Crea el primer ${catalogSingular} para comenzar a operar.`):`Tu perfil sólo permite consultar ${catalogPlural}.`} emptyAction={canManage&&!search&&saleFilter==="all"?<Button size="sm" variant="primary" onClick={() => void openNew()}><Plus size={15}/> {catalogRole === "preparation"?"Crear la primera preparación":`Crear primer ${catalogSingular}`}</Button>:undefined}>
      <div className="table-wrap surface-table"><table><thead><tr><th>Código Satrapy</th><th>{catalogSingularTitle}</th><th>Unidad</th><th>{catalogRole === "ingredient" ? "Uso en recetas" : "Grupo"}</th><th>Estado</th><th>Venta</th><th>Configuración</th><th>Diagnóstico</th><th className="number-cell">Precio</th></tr></thead><tbody>{rows.map(row=><InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar ${catalogSingular} ${row.name}`} onActivate={() => void openEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.attribute&&<small>{row.attribute}</small>}{row.is_preparation&&<small>Preparación</small>}</td><td>{row.unit??"—"}</td><td>{catalogRole === "ingredient" ? "Disponible para recetas" : row.product_group??"—"}</td><td><Badge tone={row.is_active?"success":"neutral"}>{row.is_active?"Activo":"Inactivo"}</Badge></td><td><Badge tone={row.is_sellable?"success":"neutral"}>{row.is_sellable?"Vendible":"No vendible"}</Badge></td><td><Badge tone={catalogRole === "preparation"||row.pos_ready?"success":"warning"}>{catalogRole === "preparation"?"Receta":row.pos_ready?"Completa":"Pendiente"}</Badge></td><td><small>{catalogRole === "preparation"?"Base culinaria reutilizable":row.pos_ready?"Configuración comercial completa":productReadinessSummary(row.blockers)==="Sin bloqueos"?"Requiere configuración comercial":productReadinessSummary(row.blockers)}</small></td><td className="number-cell">{row.price!=null?`${numberFormat(row.price)} ${row.currency_code??""}`:"—"}</td></InteractiveTableRow>)}</tbody></table></div>
    </DataState><DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} label={catalogPlural}/>
    <Drawer open={Boolean(draft)} onOpenChange={open=>{if(!open&&!saving){setDraft(null);setCostContext(null);}}} title={catalogFormTitle} className="product-catalog__drawer">
      {draft&&<form className={`product-catalog__form ${experience === "restaurant" ? "product-catalog__form--restaurant" : ""}`} onSubmit={saveProduct}>
        <div className="product-catalog__form-intro"><p>{experience === "restaurant" ? (catalogRole === "ingredient" ? (draft.id?"Actualiza el insumo y su forma de compra.":"Registra el insumo para recibirlo, costearlo y usarlo en recetas.") : catalogRole === "preparation" ? (draft.id?"Actualiza la preparación o abre su receta.":"Primero registra la preparación; después agrega sus insumos y activa su receta.") : (draft.id?"Actualiza el platillo o continúa con su receta y comercialización.":"Primero registra el platillo; después agrega su receta.")) : "Administra la identidad, inventario, impuestos y disponibilidad del producto canónico."}</p>{draft.sourceReference&&<small>Referencia importada: <strong>{draft.sourceReference}</strong></small>}{draft.id&&<small>Código Satrapy: <strong>{draft.internalSku}</strong></small>}</div>
        <div className="product-catalog__workspace">
          <section className="product-catalog__section product-catalog__identity"><header><h3>{catalogInformationTitle}</h3><p>Datos para identificarlo y encontrarlo rápidamente.</p></header><div className="product-catalog__form-grid"><Field label={catalogNameLabel}><Input required maxLength={240} autoFocus={!draft.id} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder={experience === "restaurant" ? (catalogRole === "ingredient" ? "Ej. Tomate saladet" : catalogRole === "preparation" ? "Ej. Salsa verde" : "Ej. Enchiladas verdes") : "Ej. Cable eléctrico"}/></Field><Field label="Unidad base" hint="Unidad usada en inventario y venta, por ejemplo KG o PZA."><Input maxLength={80} value={draft.unit} onChange={event=>setDraft({...draft,unit:event.target.value.toUpperCase()})} placeholder={experience === "restaurant" ? (catalogRole === "ingredient" ? "KG" : catalogRole === "preparation" ? "ML" : "PZA") : "PZA"}/></Field><Field label={experience === "restaurant" ? "Categoría" : "Grupo"} hint="Opcional."><Input maxLength={160} value={draft.productGroup} onChange={event=>setDraft({...draft,productGroup:event.target.value})} placeholder={experience === "restaurant" ? (catalogRole === "ingredient" ? "Ej. Proteínas" : catalogRole === "preparation" ? "Ej. Salsas" : "Ej. Desayunos") : "Ej. Material eléctrico"}/></Field><Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field></div></section>

          <section className="product-catalog__section product-catalog__inventory"><header><h3>{catalogRole === "preparation" ? "Uso culinario" : "Inventario y compra"}</h3><p>{catalogRole === "ingredient" ? "Define cómo se recibe y controla este insumo." : catalogRole === "preparation" ? "Una preparación se calcula desde sus insumos y puede reutilizarse en platillos." : "Actívalo sólo si este artículo mantiene existencia propia."}</p></header>{catalogRole === "preparation" ? <p className="product-catalog__readiness-note">No se vende ni se recibe por separado. Al vender un platillo, Satrapy expande la receta activa y descuenta sus insumos originales.</p> : <><Field label="Tipo operativo" hint="Mercancía exige existencias para vender; servicio no descuenta inventario."><Select value={draft.inventoryPolicy} onValueChange={value=>setDraft({...draft,inventoryPolicy:value as ProductDraft["inventoryPolicy"],lotControlled:value==="tracked"?draft.lotControlled:false})} ariaLabel="Tipo operativo" options={[{value:"unclassified",label:"Elige el tipo operativo"},{value:"tracked",label:"Mercancía con inventario"},{value:"not_required",label:"Servicio sin inventario"}]}/>{draft.inventoryPolicy==="unclassified"&&<span className="product-catalog__tax-selection" role="status">Indica cómo maneja inventario antes de venderlo.</span>}</Field><div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.lotControlled} disabled={draft.inventoryPolicy!=="tracked"} onChange={event=>setDraft({...draft,lotControlled:event.target.checked})}/> Solicitar lote y caducidad al recibir</label></div>{draft.inventoryPolicy==="tracked"&&<><div className="product-catalog__purchase-grid"><Field label="Unidad de compra"><Input maxLength={80} value={purchaseUnit.code} onChange={event=>setPurchaseUnit({...purchaseUnit,code:event.target.value.toUpperCase()})} placeholder={draft.unit||"CAJA"}/></Field><Field label="Unidades base por compra" hint={`${purchaseUnit.code.trim()||"Unidad de compra"} = ${purchaseUnit.factor||"1"} ${draft.unit||"unidad base"}`}><Input inputMode="decimal" value={purchaseUnit.factor} onChange={event=>setPurchaseUnit({...purchaseUnit,factor:event.target.value})} placeholder="1"/></Field></div><p className="product-catalog__readiness-note">El lote y la caducidad se pedirán en cada recepción nueva; el historial no cambia.</p></>}</>}</section>

          {catalogRole === "preparation" ? <section className="product-catalog__section product-catalog__commerce"><header><h3>Estado</h3><p>La preparación queda disponible para otras recetas al activar su versión.</p></header><div className="product-catalog__checks"><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> Preparación activa</label></div><p className="product-catalog__readiness-note">No requiere categoría fiscal, precio, surtido ni disponibilidad por sucursal.</p></section> : <section className="product-catalog__section product-catalog__commerce"><header><h3>Impuestos y venta</h3><p>Define el tratamiento fiscal y si puede ofrecerse comercialmente.</p></header><Field label="Categoría fiscal" hint="La tasa vigente queda auditada."><Select value={draft.taxCategoryId} onValueChange={value=>setDraft(current=>current?{...current,taxCategoryId:value}:current)} ariaLabel="Categoría fiscal" options={[{value:"",label:"Sin categoría fiscal"},...taxCategories.map(category=>({value:category.id,label:`${category.code} · ${category.name}${category.rate!=null?` (${numberFormat(category.rate*100)}%)`:""}`}))]}/>{draft.taxCategoryId&&<span className="product-catalog__tax-selection" role="status">Categoría seleccionada.</span>}</Field><Button type="button" size="sm" variant="ghost" onClick={()=>setTaxEditorOpen(open=>!open)} aria-expanded={taxEditorOpen}>{taxEditorOpen?"Ocultar creación fiscal":"Crear categoría fiscal"}</Button>{taxEditorOpen&&<div className="product-catalog__tax-editor"><Field label="Código fiscal"><Input maxLength={40} value={taxDraft.code} onChange={event=>setTaxDraft({...taxDraft,code:event.target.value.toUpperCase()})} placeholder="IVA16"/></Field><Field label="Nombre fiscal"><Input maxLength={120} value={taxDraft.name} onChange={event=>setTaxDraft({...taxDraft,name:event.target.value})} placeholder="IVA 16%"/></Field><Field label="Tasa porcentual"><Input inputMode="decimal" value={taxDraft.rate} onChange={event=>setTaxDraft({...taxDraft,rate:event.target.value})} placeholder="16"/></Field><Field label="Motivo de alta"><Input maxLength={240} value={taxDraft.reason} onChange={event=>setTaxDraft({...taxDraft,reason:event.target.value})} placeholder="Ej. Alta de tratamiento fiscal"/></Field><Button type="button" variant="secondary" loading={savingTax} disabled={!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()} onClick={()=>void saveTaxCategory()}>Crear y seleccionar</Button></div>}<div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.sellable} onChange={event=>setDraft({...draft,sellable:event.target.checked})}/> Disponible para venta</label><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> {catalogSingularTitle} activo</label></div><p className="product-catalog__readiness-note">{catalogRole === "ingredient" ? "El insumo sólo se venderá si lo habilitas aquí." : "La disponibilidad por sucursal se define por separado."}</p>{draft.id&&catalogRole === "dish"&&canManageAssortments&&<Button type="button" variant="secondary" onClick={()=>{setCommercialReason(`Actualización de la comercialización del ${catalogSingular}`);setCommercialProduct({id:draft.id!,name:draft.name});setDraft(null);}}>Definir disponibilidad por sucursal</Button>}</section>}

          {draft.id&&canManageCosts&&costContext&&<section className="product-catalog__cost-capture product-catalog__section--wide"><header><div><strong>Valuación de inventario</strong><p>Captura manual para altas o correcciones puntuales.</p></div><Badge tone={costContext.matrix_ready?"success":"warning"}>{costContext.matrix_ready?costMethodLabel(costContext.cost_method):"Matriz pendiente"}</Badge></header>{costContext.matrix_ready?<><div className="product-catalog__cost-summary"><span>Costo vigente<strong>{costContext.current_cost?`${numberFormat(costContext.current_cost.amount)} ${costContext.currency_code}`:"Sin costo"}</strong></span><span>Moneda contable<strong>{costContext.currency_code}</strong></span></div><div className="product-catalog__cost-fields"><Field label="Nuevo costo vigente"><Input inputMode="decimal" value={costDraft.amount} onChange={event=>setCostDraft({...costDraft,amount:event.target.value})} placeholder="0.00"/></Field><Field label="Motivo obligatorio"><Input maxLength={240} value={costDraft.reason} onChange={event=>setCostDraft({...costDraft,reason:event.target.value})} placeholder="Ej. Alta inicial para valuación"/></Field><Button type="button" variant="secondary" loading={savingCost} disabled={!costDraft.reason.trim()||!(Number(costDraft.amount.replace(",","."))>0)} onClick={()=>void saveCurrentCost()}>Guardar costo</Button></div></>:<p className="product-catalog__cost-warning">Primero configura y aprueba la matriz contable.</p>}</section>}
          {draft.id&&(catalogRole === "dish"||catalogRole === "preparation")&&canManageRecipes&&<section className="product-catalog__recipe-action product-catalog__section--wide"><div><strong>{catalogRole === "preparation" ? "Receta de la preparación" : "Receta y costeo"}</strong><p>{catalogRole === "preparation" ? "Define rendimiento, insumos y merma de esta base reutilizable." : "Define rendimiento, insumos, preparaciones y merma."}</p></div><Button type="button" variant="secondary" onClick={()=>{setRecipeProduct({id:draft.id!,name:draft.name,recipeKind:catalogRole==="preparation"?"preparation":"dish"});setDraft(null);}}><ChefHat size={16} aria-hidden="true"/> Abrir receta</Button></section>}
        </div>
        <label className="operation-reason product-catalog__reason">Motivo obligatorio<textarea required rows={2} value={draft.reason} onChange={event=>setDraft({...draft,reason:event.target.value})} placeholder={draft.id?"Ej. Actualización de información comercial":experience!=="restaurant"?"Ej. Alta inicial del producto":catalogRole === "ingredient"?"Ej. Alta inicial de insumo":catalogRole === "preparation"?"Ej. Alta inicial de preparación":"Ej. Alta inicial del platillo"}/></label><div className="product-catalog__form-actions"><Button type="button" variant="secondary" disabled={saving} onClick={()=>setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving} disabled={saving||draft.inventoryPolicy==="unclassified"}>{draft.id?"Guardar cambios":experience==="restaurant"?(catalogRole === "ingredient"?"Crear insumo":catalogRole === "preparation"?"Crear preparación y continuar":"Crear platillo y continuar"): `Crear ${words.singular}`}</Button></div>
      </form>}
    </Drawer>
    <ProductCommercializationModal companyId={companyId} product={commercialProduct} open={Boolean(commercialProduct)} initialReason={commercialReason} experience={experience} onOpenChange={(open)=>{if(!open)setCommercialProduct(null);}} onSaved={refresh}/>
    <RecipeEditorModal companyId={companyId} product={recipeProduct} recipeKind={recipeProduct?.recipeKind??"dish"} open={Boolean(recipeProduct)} onCreateIngredient={()=>{setRecipeProduct(null);router.replace("/satrapy/inventario/productos?seccion=insumos");void openNew("ingredient");}} onOpenChange={open=>{if(!open){setRecipeProduct(null);void refresh();}}}/>
  </div>;
}
