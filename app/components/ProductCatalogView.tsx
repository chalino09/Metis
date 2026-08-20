"use client";

import { Archive, ChefHat, Plus, RefreshCw } from "lucide-react";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ProductCommercializationModal } from "@/app/components/ProductCommercializationModal";
import { RecipeEditorModal } from "@/app/components/RecipeEditorModal";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Drawer, Field, Input, Modal, Select, useToast } from "@/app/components/ui/primitives";
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
type ProductPurchaseUnit = { base_unit:string|null; purchase_unit:string|null; base_units_per_purchase_unit:number; presentation_content_confirmed_at:string|null };
type RestaurantIntegrityIssue = ProductListRow & { issue_code:"missing_culinary_role"|"invalid_purchase_configuration"|"presentation_content_unconfirmed"; message:string; purchase_unit_code:string|null; base_unit_code:string|null; base_units_per_purchase_unit:number|null };
type ArchiveRecipeDependency = { product_id:string; product_name:string; recipe_kind:"dish"|"preparation"; version_number:number };
type ArchiveTarget = { id:string; name:string; active_recipes:ArchiveRecipeDependency[]; inventory_location_count:number; open_purchase_order_count:number };
type ProductDraft = { id:string|null; internalSku:string; name:string; barcode:string; unit:string; productGroup:string; taxCategoryId:string; inventoryPolicy:"tracked"|"not_required"|"unclassified"; lotControlled:boolean; sellable:boolean; active:boolean; reason:string; updatedAt:string|null; sourceReference:string|null };
const emptyDraft = (): ProductDraft => ({ id:null, internalSku:"", name:"", barcode:"", unit:"", productGroup:"", taxCategoryId:"", inventoryPolicy:"tracked", lotControlled:false, sellable:true, active:true, reason:"",updatedAt:null,sourceReference:null });
const restaurantUnitOptions = [
  { value:"mg", label:"Miligramo (mg)" },
  { value:"g", label:"Gramo (g)" },
  { value:"kg", label:"Kilogramo (kg)" },
  { value:"ml", label:"Mililitro (ml)" },
  { value:"l", label:"Litro (l)" },
  { value:"piece", label:"Pieza" },
];
const RESTAURANT_NO_CATEGORY = "__sin_categoria__";
const RESTAURANT_OTHER_CATEGORY = "__otra_categoria__";
const restaurantCategoryLabels:Record<RestaurantCatalogRole,string[]> = {
  ingredient:["Proteínas","Frutas y verduras","Lácteos y huevos","Granos, cereales y harinas","Abarrotes y secos","Condimentos y especias","Congelados","Bebidas e insumos líquidos","Pan y tortillas","Otros insumos"],
  dish:["Desayunos","Entradas","Sopas y ensaladas","Platos fuertes","Guarniciones","Postres","Bebidas","Otros platillos"],
  preparation:["Salsas","Aderezos","Caldos y fondos","Marinados","Masas","Cremas y bases","Guarniciones base","Otras preparaciones"],
};
const RESTAURANT_NO_PURCHASE_PRESENTATION = "__sin_presentacion__";
const RESTAURANT_OTHER_PURCHASE_PRESENTATION = "__otra_presentacion__";
const restaurantPurchasePresentationOptions = [
  { value:RESTAURANT_NO_PURCHASE_PRESENTATION, label:"Selecciona una presentación", disabled:true },
  { value:"CAJA", label:"Caja" },
  { value:"SACO", label:"Saco" },
  { value:"BOLSA", label:"Bolsa" },
  { value:"PAQUETE", label:"Paquete" },
  { value:"BOTELLA", label:"Botella" },
  { value:"PZA", label:"Pieza" },
  { value:"MG", label:"Miligramo (mg)" },
  { value:"G", label:"Gramo (g)" },
  { value:"KG", label:"Kilogramo (kg)" },
  { value:"ML", label:"Mililitro (ml)" },
  { value:"L", label:"Litro (l)" },
  { value:RESTAURANT_OTHER_PURCHASE_PRESENTATION, label:"Otra presentación" },
];
function restaurantCategorySelectValue(value:string, categories:string[]) {
  const normalized=value.trim().toLowerCase();
  if(!normalized)return RESTAURANT_NO_CATEGORY;
  return categories.find(category=>category.toLowerCase()===normalized)??RESTAURANT_OTHER_CATEGORY;
}
function restaurantCategoryDisplay(value:string|null|undefined, role:RestaurantCatalogRole) {
  const normalized=(value??"").trim().toLowerCase();
  if(!normalized)return "Sin categoría";
  const match=restaurantCategoryLabels[role].find(category=>category.toLowerCase()===normalized);
  return match??`Otra: ${(value??"").trim()}`;
}
function restaurantUnitDimension(value:string|null|undefined) {
  const normalized=restaurantUnitCode(value,"");
  if(normalized==="mg"||normalized==="g"||normalized==="kg")return "mass";
  if(normalized==="ml"||normalized==="l")return "volume";
  if(normalized==="piece")return "count";
  return null;
}
function restaurantPurchasePresentationOptionsFor(baseUnit:string|null|undefined) {
  const dimension=restaurantUnitDimension(baseUnit);
  return restaurantPurchasePresentationOptions.filter(option=>{
    if([RESTAURANT_NO_PURCHASE_PRESENTATION,"CAJA","PAQUETE",RESTAURANT_OTHER_PURCHASE_PRESENTATION].includes(option.value))return true;
    if(dimension==="mass")return ["SACO","BOLSA","MG","G","KG"].includes(option.value);
    if(dimension==="volume")return ["BOTELLA","ML","L"].includes(option.value);
    if(dimension==="count")return option.value==="PZA";
    return false;
  });
}
function restaurantPurchasePresentationSelectValueForUnit(value:string,baseUnit:string|null|undefined) {
  const normalized=value.trim().toUpperCase();
  const options=restaurantPurchasePresentationOptionsFor(baseUnit);
  return normalized&&options.some(option=>option.value===normalized)?normalized:normalized?RESTAURANT_OTHER_PURCHASE_PRESENTATION:RESTAURANT_NO_PURCHASE_PRESENTATION;
}
function restaurantPurchasePresentationName(value:string) {
  const label=restaurantPurchasePresentationOptions.find(option=>option.value===value.trim().toUpperCase())?.label;
  return label||value.trim().toLowerCase()||"presentación";
}
function restaurantUnitCode(value:string|null|undefined, fallback:string) {
  const normalized=(value??"").trim().toLowerCase();
  if(normalized==="pza"||normalized==="pieza"||normalized==="piezas"||normalized==="ea"||normalized==="unidad"||normalized==="unidades")return "piece";
  return restaurantUnitOptions.some(option=>option.value===normalized)?normalized:fallback;
}
function restaurantUnitLabel(value:string|null|undefined, singular=false) {
  const normalized=restaurantUnitCode(value,"");
  if(normalized==="mg")return singular?"miligramo (mg)":"miligramos (mg)";
  if(normalized==="g")return singular?"gramo (g)":"gramos (g)";
  if(normalized==="kg")return singular?"kilogramo (kg)":"kilogramos (kg)";
  if(normalized==="ml")return singular?"mililitro (ml)":"mililitros (ml)";
  if(normalized==="l")return singular?"litro (l)":"litros (l)";
  if(normalized==="piece")return singular?"pieza":"piezas";
  return "unidades base";
}
function restaurantUnitQuantityPrompt(value:string|null|undefined) {
  return restaurantUnitCode(value,"")==="piece"?"cuántas":"cuántos";
}
function restaurantUnitShortLabel(value:string|null|undefined) {
  const normalized=restaurantUnitCode(value,"");
  if(normalized==="piece")return "Pieza";
  return normalized||"—";
}
function restaurantAutomaticPurchaseFactor(purchaseCode:string, baseUnit:string) {
  const units:Record<string,{dimension:"mass"|"volume"|"count";scale:number}>={
    mg:{dimension:"mass",scale:.001},g:{dimension:"mass",scale:1},kg:{dimension:"mass",scale:1000},
    ml:{dimension:"volume",scale:1},l:{dimension:"volume",scale:1000},
    piece:{dimension:"count",scale:1},
  };
  const purchaseUnit=restaurantUnitCode(purchaseCode,purchaseCode.trim().toLowerCase());
  const normalizedBase=restaurantUnitCode(baseUnit,"");
  const purchase=units[purchaseUnit],base=units[normalizedBase];
  return purchase&&base&&purchase.dimension===base.dimension?purchase.scale/base.scale:null;
}
function restaurantRoleLabel(role:RestaurantCatalogRole) {
  return role==="ingredient"?"Insumo":role==="preparation"?"Preparación":"Platillo";
}
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
  const detailRequestId = useRef(0);
  const [rows,setRows] = useState<ProductListRow[]>([]); const [loading,setLoading] = useState(true); const [error,setError] = useState<string|null>(null);
  const [search,setSearch] = useState(""); const [debouncedSearch,setDebouncedSearch] = useState(""); const [saleFilter,setSaleFilter] = useState("all"); const [page,setPage] = useState(1); const [total,setTotal] = useState(0);
  const [draft,setDraft] = useState<ProductDraft|null>(null); const [detailLoading,setDetailLoading] = useState(false); const [saving,setSaving] = useState(false);
  const [commercialProduct,setCommercialProduct] = useState<{id:string;name:string}|null>(null);
  const [recipeProduct,setRecipeProduct] = useState<{id:string;name:string;recipeKind:"dish"|"preparation"}|null>(null);
  const [commercialReason,setCommercialReason] = useState("");
  const [costContext,setCostContext] = useState<ProductCostContext|null>(null);
  const [costDraft,setCostDraft] = useState({amount:"",reason:""});
  const [savingCost,setSavingCost] = useState(false);
  const [purchaseUnit,setRawPurchaseUnit] = useState({code:"",factor:""});
  const [purchasePresentationSelection,setPurchasePresentationSelection] = useState(RESTAURANT_NO_PURCHASE_PRESENTATION);
  const [purchasePresentationOther,setPurchasePresentationOther] = useState("");
  const [otherRestaurantCategory,setOtherRestaurantCategory] = useState("");
  const [taxCategories,setTaxCategories] = useState<TaxCategory[]>([]); const [taxDraft,setTaxDraft] = useState<{code:string;name:string;rate:string;reason:string}>({code:"",name:"",rate:"16",reason:""}); const [savingTax,setSavingTax] = useState(false);
  const [taxEditorOpen,setTaxEditorOpen] = useState(false);
  const [integrityIssues,setIntegrityIssues] = useState<RestaurantIntegrityIssue[]>([]);
  const [integrityTotal,setIntegrityTotal] = useState(0);
  const [integrityReviewOpen,setIntegrityReviewOpen] = useState(false);
  const [archiveTarget,setArchiveTarget] = useState<ArchiveTarget|null>(null);
  const [archiveReason,setArchiveReason] = useState("");
  const [archiveError,setArchiveError] = useState<string|null>(null);
  const [archiving,setArchiving] = useState(false);
  const archiveReasonInputRef = useRef<HTMLTextAreaElement|null>(null);
  const catalogFormTitle = draft?.id ? `Editar ${catalogSingular}` : catalogRole === "preparation" ? "Nueva preparación" : `Nuevo ${catalogSingular}`;
  const canArchiveIngredient = experience==="restaurant"&&catalogRole==="ingredient"&&canManage;
  function setPurchaseUnit(next:{code:string;factor:string}|((current:{code:string;factor:string})=>{code:string;factor:string})){
    setRawPurchaseUnit(current=>{
      const resolved=typeof next==="function"?next(current):next;
      const automaticFactor=restaurantAutomaticPurchaseFactor(resolved.code,draft?.unit??"");
      if(automaticFactor!=null)return {...resolved,factor:String(automaticFactor)};
      return resolved.code!==current.code?{...resolved,factor:""}:resolved;
    });
  }

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
  const loadIntegrityIssues = useCallback(async () => {
    if(experience!=="restaurant"||catalogRole!=="ingredient") { setIntegrityIssues([]); setIntegrityTotal(0); return; }
    const {data,error:integrityError}=await getSupabaseClient().rpc("list_restaurant_catalog_integrity_issues",{p_company_id:companyId,p_page:1,p_page_size:50});
    if(integrityError) return;
    const result=data as {items?:RestaurantIntegrityIssue[];total?:number}|null;
    setIntegrityIssues(result?.items??[]);setIntegrityTotal(result?.total??0);
  },[catalogRole,companyId,experience]);
  useEffect(() => { void Promise.resolve().then(loadIntegrityIssues); },[loadIntegrityIssues]);
  const loadTaxCategories = useCallback(async () => {
    const {data,error:taxError}=await getSupabaseClient().rpc("list_tax_categories_admin",{p_company_id:companyId});
    if(taxError){toast({title:"No se pudieron cargar las categorías fiscales",description:errorMessage(taxError,"Actualiza e intenta de nuevo."),tone:"error"});return;}
    setTaxCategories((data??[]) as TaxCategory[]);
  },[companyId,toast]);
  async function refresh(){queryCache.invalidate(`products:${companyId}:`);await Promise.all([load(true),loadIntegrityIssues()]);}
  async function openEdit(row:ProductListRow){
    if(!canManage)return;
    const detailRequest=++detailRequestId.current;
    const rowRole=experience==="restaurant"&&row.catalog_role?row.catalog_role:catalogRole;
    const fallbackUnit=rowRole==="ingredient"?"g":rowRole==="preparation"?"ml":"piece";
    setOtherRestaurantCategory(row.product_group??"");
    setDraft({id:row.id,internalSku:row.internal_sku,name:row.name,barcode:row.barcode??"",unit:experience==="restaurant"?restaurantUnitCode(row.unit,fallbackUnit):row.unit??"",productGroup:row.product_group??"",taxCategoryId:"",inventoryPolicy:row.inventory_policy==="tracked"||row.inventory_policy==="not_required"?row.inventory_policy:"unclassified",lotControlled:false,sellable:row.is_sellable,active:row.is_active,reason:"",updatedAt:null,sourceReference:row.alpha_sku});
    setDetailLoading(true);
    setTaxEditorOpen(false);
    if(experience === "restaurant" && row.catalog_role && row.catalog_role !== catalogRole) {
      const targetPath=row.catalog_role === "ingredient" ? "/satrapy/inventario/productos?seccion=insumos" : row.catalog_role === "preparation" ? "/satrapy/inventario/productos?seccion=preparaciones" : "/satrapy/inventario/productos";
      router.replace(targetPath,{scroll:false});
    }
    const client=getSupabaseClient();
    const [{data,error:detailError},costResult,purchaseResult]=await Promise.all([
      client.from("products").select("id, internal_sku, alpha_sku, name, barcode, unit, product_group, tax_category_id, inventory_policy, is_inventory_tracked, lot_controlled, is_sellable, is_active, updated_at").eq("company_id",companyId).eq("id",row.id).single(),
      canManageCosts?client.rpc("get_product_cost_admin_context",{p_company_id:companyId,p_product_id:row.id}):Promise.resolve({data:null,error:null}),
      client.rpc("get_product_purchase_unit",{p_company_id:companyId,p_product_id:row.id}),
    ]);
    if(detailRequestId.current!==detailRequest)return;
    if(detailError||!data){setDetailLoading(false);setDraft(null);toast({title:`No se pudo abrir el ${words.singular}`,description:errorMessage(detailError,"Actualiza la lista e intenta nuevamente."),tone:"error"});return;}
    if(costResult.error){toast({title:"No se pudo consultar el costo",description:errorMessage(costResult.error,`Puedes editar el ${words.singular}, pero no su valuación.`),tone:"error"});}
    const nextCost=(costResult.data??null) as ProductCostContext|null;
    setCostContext(nextCost);
    setCostDraft({amount:nextCost?.current_cost?.amount?.toString()??"",reason:""});
    const nextPurchase=(purchaseResult.data??null) as ProductPurchaseUnit|null;
    const purchaseCode=(nextPurchase?.purchase_unit??data.unit??"").trim().toUpperCase();
    const presentationSelection=experience==="restaurant"&&rowRole==="ingredient"?restaurantPurchasePresentationSelectValueForUnit(purchaseCode,data.unit):RESTAURANT_NO_PURCHASE_PRESENTATION;
    const automaticFactor=restaurantAutomaticPurchaseFactor(purchaseCode,data.unit??"");
    const contentNeedsConfirmation=experience==="restaurant"&&rowRole==="ingredient"&&automaticFactor==null&&!nextPurchase?.presentation_content_confirmed_at;
    setRawPurchaseUnit({code:purchaseCode,factor:contentNeedsConfirmation?"":String(nextPurchase?.base_units_per_purchase_unit??1)});
    setPurchasePresentationSelection(presentationSelection);
    setPurchasePresentationOther(experience==="restaurant"&&rowRole==="ingredient"&&restaurantPurchasePresentationSelectValueForUnit(purchaseCode,data.unit)===RESTAURANT_OTHER_PURCHASE_PRESENTATION?purchaseCode:"");
    await loadTaxCategories();
    if(detailRequestId.current!==detailRequest)return;
    setOtherRestaurantCategory(data.product_group??"");
    setDraft({id:data.id,internalSku:data.internal_sku,name:data.name,barcode:data.barcode??"",unit:experience==="restaurant"?restaurantUnitCode(data.unit,catalogRole==="ingredient"?"g":catalogRole==="preparation"?"ml":"piece"):data.unit??"",productGroup:data.product_group??"",taxCategoryId:data.tax_category_id??"",inventoryPolicy:data.inventory_policy==="tracked"||data.inventory_policy==="not_required"?data.inventory_policy:"unclassified",lotControlled:data.lot_controlled,sellable:data.is_sellable,active:data.is_active,reason:"",updatedAt:data.updated_at,sourceReference:data.alpha_sku});
    setDetailLoading(false);
  }
  async function openNew(role:RestaurantCatalogRole=catalogRole){await loadTaxCategories();setTaxEditorOpen(false);setCostContext(null);setCostDraft({amount:"",reason:""});setRawPurchaseUnit({code:"",factor:""});setPurchasePresentationSelection(RESTAURANT_NO_PURCHASE_PRESENTATION);setPurchasePresentationOther("");setOtherRestaurantCategory("");setDraft({...emptyDraft(),unit:experience==="restaurant"?restaurantUnitCode(null,role==="ingredient"?"g":role==="preparation"?"ml":"piece"):"",inventoryPolicy:experience==="restaurant"&&role!=="ingredient"?"not_required":"tracked",sellable:experience!=="restaurant"||role==="dish"});}
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
    const normalized={...draft,internalSku:draft.internalSku.trim().toUpperCase(),name:draft.name.trim(),unit:experience==="restaurant"?restaurantUnitCode(draft.unit,catalogRole==="ingredient"?"g":catalogRole==="preparation"?"ml":"piece"):draft.unit.trim(),productGroup:draft.productGroup.trim(),reason:draft.reason.trim()};
    if(!normalized.name||!normalized.reason)return;
    const selectedTaxCategoryId=normalized.taxCategoryId||null;
    const fingerprint=JSON.stringify(normalized);setSaving(true);
    const client=getSupabaseClient();
    const requestKey=idempotency.get("save-product",fingerprint);
    const purchaseCode=(purchaseUnit.code.trim()||normalized.unit.trim()).toUpperCase();
    const purchaseFactor=Number(purchaseUnit.factor.replace(",","."));
    const response=experience==="restaurant"
      ? await client.rpc("save_restaurant_catalog_item",{p_company_id:companyId,p_product_id:normalized.id,p_internal_sku:normalized.internalSku,p_name:normalized.name,p_barcode:normalized.barcode.trim()||null,p_unit:normalized.unit.trim()||null,p_product_group:normalized.productGroup.trim()||null,p_role:catalogRole,p_is_sellable:normalized.sellable,p_is_active:normalized.active,p_tax_category_id:selectedTaxCategoryId,p_purchase_unit_code:catalogRole==="ingredient"?purchaseCode:null,p_base_units_per_purchase_unit:catalogRole==="ingredient"?purchaseFactor:null,p_lot_controlled:catalogRole==="ingredient"&&normalized.lotControlled,p_reason:normalized.reason,p_expected_updated_at:normalized.updatedAt,p_client_request_id:requestKey})
      : await client.rpc("save_product",{p_company_id:companyId,p_product_id:normalized.id,p_internal_sku:normalized.internalSku,p_name:normalized.name,p_barcode:normalized.barcode.trim()||null,p_unit:normalized.unit.trim()||null,p_product_group:normalized.productGroup.trim()||null,p_inventory_policy:normalized.inventoryPolicy,p_is_sellable:normalized.sellable,p_is_active:normalized.active,p_tax_category_id:selectedTaxCategoryId,p_reason:normalized.reason,p_expected_updated_at:normalized.updatedAt,p_client_request_id:requestKey});
    const {data,error:saveError}=response;
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
      if(experience!=="restaurant"&&normalized.inventoryPolicy==="tracked"&&purchaseCode&&Number.isFinite(purchaseFactor)&&purchaseFactor>0&&saved?.id){
        const purchaseFingerprint=JSON.stringify({productId:saved.id,purchaseCode,purchaseFactor,reason:normalized.reason});
        const {error:purchaseError}=await getSupabaseClient().rpc("set_product_purchase_unit",{p_company_id:companyId,p_product_id:saved.id,p_purchase_unit_code:purchaseCode,p_base_units_per_purchase_unit:purchaseFactor,p_reason:normalized.reason,p_client_request_id:idempotency.get("save-product-purchase-unit",purchaseFingerprint)});
        if(purchaseError){setSaving(false);toast({title:`${catalogSingularTitle} guardado; falta la conversión`,description:errorMessage(purchaseError,"Corrige la unidad de compra e intenta nuevamente."),tone:"error"});return;}
        idempotency.clear("save-product-purchase-unit");
      }
      if(experience!=="restaurant"&&saved?.id&&(normalized.id!==null||normalized.lotControlled)){
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
  async function openArchive(){
    if(!draft?.id||!canArchiveIngredient)return;
    const {data,error:contextError}=await getSupabaseClient().rpc("get_restaurant_ingredient_archive_context",{p_company_id:companyId,p_product_id:draft.id});
    if(contextError){toast({title:"No se pudo revisar el archivo",description:errorMessage(contextError,"Actualiza e intenta nuevamente."),tone:"error"});return;}
    const context=data as Omit<ArchiveTarget,"id"|"name">;
    setArchiveTarget({id:draft.id,name:draft.name,active_recipes:context.active_recipes??[],inventory_location_count:context.inventory_location_count??0,open_purchase_order_count:context.open_purchase_order_count??0});
    setArchiveReason("");
    setArchiveError(null);
  }
  async function archiveIngredient(){
    if(!archiveTarget)return;
    if(!archiveReason.trim()){
      setArchiveError("Indica el motivo para archivar el insumo.");
      archiveReasonInputRef.current?.focus();
      return;
    }
    const reason=archiveReason.trim();
    const fingerprint=JSON.stringify({productId:archiveTarget.id,reason});
    setArchiving(true);
    setArchiveError(null);
    const {error:archiveRequestError}=await getSupabaseClient().rpc("archive_restaurant_ingredient",{
      p_company_id:companyId,
      p_product_id:archiveTarget.id,
      p_reason:reason,
      p_client_request_id:idempotency.get("archive-restaurant-ingredient",fingerprint),
    });
    if(archiveRequestError){
      setArchiveError(errorMessage(archiveRequestError,"No se pudo archivar el insumo. Intenta nuevamente."));
    }else{
      idempotency.clear("archive-restaurant-ingredient");
      const archivedName=archiveTarget.name;
      setArchiveTarget(null);
      setArchiveReason("");
      setDraft(null);
      setPage(1);
      await refresh();
      toast({title:"Insumo archivado",description:`${archivedName} ya no aparece en el catálogo ni en nuevas recetas.`,tone:"success"});
    }
    setArchiving(false);
  }
  function clearFilters(){setSearch("");setDebouncedSearch("");setSaleFilter("all");setPage(1);}
  function selectRestaurantUnit(value:string){
    setDraft(current=>current?{...current,unit:value}:current);
    if(catalogRole!=="ingredient")return;
    const compatible=restaurantPurchasePresentationOptionsFor(value).some(option=>option.value===purchasePresentationSelection);
    if(!compatible){setPurchasePresentationSelection(RESTAURANT_NO_PURCHASE_PRESENTATION);setPurchasePresentationOther("");setRawPurchaseUnit({code:"",factor:""});return;}
    setRawPurchaseUnit(current=>{const automaticFactor=restaurantAutomaticPurchaseFactor(current.code,value);return automaticFactor==null?current:{...current,factor:String(automaticFactor)};});
  }
  useEffect(()=>{
    if(experience!=="restaurant"||catalogRole!=="ingredient"||!draft)return;
    const automaticFactor=restaurantAutomaticPurchaseFactor(purchaseUnit.code,draft.unit);
    if(automaticFactor==null||purchaseUnit.factor===String(automaticFactor))return;
    const update=window.setTimeout(()=>setRawPurchaseUnit(current=>({...current,factor:String(automaticFactor)})),0);
    return ()=>window.clearTimeout(update);
  },[catalogRole,draft,experience,purchaseUnit.code,purchaseUnit.factor]);
  const restaurantCategoryOptions=[{value:RESTAURANT_NO_CATEGORY,label:"Sin categoría"},...restaurantCategoryLabels[catalogRole].map(category=>({value:category,label:category})),{value:RESTAURANT_OTHER_CATEGORY,label:"Otra categoría"}];
  const restaurantCategoryValue=restaurantCategorySelectValue(draft?.productGroup??"",restaurantCategoryLabels[catalogRole]);
  const purchasePresentationOptions=restaurantPurchasePresentationOptionsFor(draft?.unit);
  const automaticPurchaseFactor=draft&&catalogRole==="ingredient"?restaurantAutomaticPurchaseFactor(purchaseUnit.code,draft.unit):null;
  const purchaseContentLabel=automaticPurchaseFactor==null?"Contenido neto por presentación":"Equivalencia automática";
  const purchaseContentHint=automaticPurchaseFactor==null?`Escribe ${restaurantUnitQuantityPrompt(draft?.unit)} ${restaurantUnitLabel(draft?.unit)} contiene 1 ${restaurantPurchasePresentationName(purchaseUnit.code||purchasePresentationOther)}.`:`1 ${restaurantPurchasePresentationName(purchaseUnit.code)} = ${purchaseUnit.factor||"—"} ${restaurantUnitLabel(draft?.unit,Number(purchaseUnit.factor||0)===1)}`;
  const archiveBlocked=Boolean(archiveTarget&&(archiveTarget.active_recipes.length>0||archiveTarget.inventory_location_count>0||archiveTarget.open_purchase_order_count>0));
  return <div className="content-frame product-catalog">
    <PageHeading eyebrow={experience === "restaurant" ? "Operación culinaria" : "Catálogo administrable"} title={catalogPluralTitle} description={experience==="restaurant"?(catalogRole === "ingredient"?"Registra los insumos que se reciben y se consumen en las recetas.":catalogRole === "preparation"?"Crea bases intermedias, como salsas o caldos, para reutilizarlas en varias recetas.":"Crea y mantiene sólo los platillos que se ofrecen en el punto de venta."):"Crea y mantiene productos canónicos de Satrapy. La importación acelera cargas grandes, pero no es necesaria para operar."} action={<div className="product-catalog__heading-actions"><Button variant="secondary" onClick={() => void refresh()}><RefreshCw size={16}/> Actualizar</Button>{canManage&&<Button variant="primary" onClick={() => void openNew()}><Plus size={16}/> {catalogRole === "preparation" ? "Nueva preparación" : `Nuevo ${catalogSingular}`}</Button>}</div>}/>
    {experience === "restaurant" && <nav className="restaurant-catalog-tabs" aria-label="Funciones culinarias"><button type="button" className={catalogRole === "dish" ? "is-active" : undefined} aria-current={catalogRole === "dish" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos"); setPage(1); }}><strong>Platillos</strong><span>Lo que vendes al comensal</span></button><button type="button" className={catalogRole === "ingredient" ? "is-active" : undefined} aria-current={catalogRole === "ingredient" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos?seccion=insumos"); setPage(1); }}><strong>Insumos</strong><span>Lo que compras y consumes</span></button><button type="button" className={catalogRole === "preparation" ? "is-active" : undefined} aria-current={catalogRole === "preparation" ? "page" : undefined} onClick={() => { router.replace("/satrapy/inventario/productos?seccion=preparaciones"); setPage(1); }}><strong>Preparaciones</strong><span>Bases internas reutilizables</span></button></nav>}
    {experience === "restaurant" ? <section className="product-catalog__guidance" aria-labelledby="restaurant-catalog-guidance"><div className="product-catalog__guidance-definition"><strong id="restaurant-catalog-guidance">{catalogGuidance.title}</strong><p>{catalogGuidance.description}</p></div><div className="product-catalog__guidance-capture"><strong>Cómo agregar</strong><p>Captura aquí {catalogSmallQuantity} o correcciones puntuales. Para catálogos extensos, usa la importación masiva.</p></div></section> : <p className="product-catalog__volume-note"><strong>Captura individual:</strong> úsala para {catalogSmallQuantity} o correcciones puntuales. Para catálogos extensos, conserva la importación masiva.</p>}
    {experience === "restaurant" && catalogRole === "ingredient" && integrityTotal > 0 && <section className="product-catalog__integrity-notice" aria-labelledby="catalog-integrity-title"><div><strong id="catalog-integrity-title">{integrityTotal} {integrityTotal === 1 ? "insumo requiere" : "insumos requieren"} revisión</strong><p>Confirma la presentación y su contenido real antes de usar estos registros en operación. Para una carga amplia, usa una corrección por lote.</p></div><Button type="button" variant="secondary" onClick={()=>setIntegrityReviewOpen(true)}>Revisar configuraciones</Button></section>}
    <DataToolbar search={search} onSearchChange={setSearch} placeholder={experience === "restaurant" && catalogRole === "ingredient" ? "Buscar insumo por nombre o código" : experience === "restaurant" && catalogRole === "preparation" ? "Buscar preparación por nombre o código" : "Buscar código Satrapy, código de barras, alias o nombre"} filters={<Select value={saleFilter} onValueChange={value=>{setSaleFilter(value);setPage(1);}} ariaLabel="Filtrar por disponibilidad de venta" options={[{value:"all",label:catalogAllLabel},{value:"sellable",label:"Vendibles"},{value:"not_sellable",label:"No vendibles"}]}/>} activeFilters={(search.trim()?1:0)+(saleFilter!=="all"?1:0)} onClear={clearFilters} results={total}/>
    <DataRefreshStatus loading={loading} hasData={rows.length}/>
    <DataState loading={loading&&rows.length===0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={() => void refresh()}>Reintentar</Button>} hasData={rows.length} emptyTitle={search||saleFilter!=="all"?"Sin coincidencias":catalogRole === "preparation"?"Aún no hay preparaciones":`Aún no hay ${catalogPlural}`} empty={search||saleFilter!=="all"?`No hay ${catalogPlural} que coincidan con estos criterios.`:canManage?(catalogRole === "preparation"?"Crea la primera preparación para comenzar a operar.":`Crea el primer ${catalogSingular} para comenzar a operar.`):`Tu perfil sólo permite consultar ${catalogPlural}.`} emptyAction={canManage&&!search&&saleFilter==="all"?<Button size="sm" variant="primary" onClick={() => void openNew()}><Plus size={15}/> {catalogRole === "preparation"?"Crear la primera preparación":`Crear primer ${catalogSingular}`}</Button>:undefined}>
      <div className="table-wrap surface-table"><table><thead><tr><th>Código Satrapy</th><th>{catalogSingularTitle}</th>{experience === "restaurant"&&<th>Función culinaria</th>}<th>Unidad</th><th>{experience === "restaurant"?"Categoría":catalogRole === "ingredient"?"Uso en recetas":"Grupo"}</th><th>Estado</th><th>Venta</th><th>Configuración</th><th>Diagnóstico</th><th className="number-cell">Precio</th></tr></thead><tbody>{rows.map(row=><InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar ${catalogSingular} ${row.name}`} onActivate={() => void openEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.attribute&&<small>{row.attribute}</small>}{experience !== "restaurant"&&row.is_preparation&&<small>Preparación</small>}</td>{experience === "restaurant"&&<td><Badge tone="info">{catalogSingularTitle}</Badge></td>}<td>{experience === "restaurant"?restaurantUnitShortLabel(row.unit):row.unit??"—"}</td><td>{experience === "restaurant"?restaurantCategoryDisplay(row.product_group,catalogRole):catalogRole === "ingredient"?"Uso en recetas":row.product_group??"—"}</td><td><Badge tone={row.is_active?"success":"neutral"}>{row.is_active?"Activo":"Inactivo"}</Badge></td><td><Badge tone={row.is_sellable?"success":"neutral"}>{row.is_sellable?"Vendible":"No vendible"}</Badge></td><td><Badge tone={catalogRole === "preparation"||row.pos_ready?"success":"warning"}>{catalogRole === "preparation"?"Receta":row.pos_ready?"Completa":"Pendiente"}</Badge></td><td><small>{catalogRole === "preparation"?"Base culinaria reutilizable":row.pos_ready?"Configuración comercial completa":productReadinessSummary(row.blockers)==="Sin bloqueos"?"Requiere configuración comercial":productReadinessSummary(row.blockers)}</small></td><td className="number-cell">{row.price!=null?`${numberFormat(row.price)} ${row.currency_code??""}`:"—"}</td></InteractiveTableRow>)}</tbody></table></div>
    </DataState><DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} label={catalogPlural}/>
    <Drawer open={Boolean(draft)} onOpenChange={open=>{if(!open&&!saving){detailRequestId.current+=1;setDraft(null);setDetailLoading(false);setCostContext(null);}}} title={catalogFormTitle} className="product-catalog__drawer">
      {draft&&(detailLoading?<div className="product-catalog__loading" role="status" aria-live="polite" aria-busy="true"><span className="sr-only">Cargando datos del {catalogSingular}…</span><span className="product-catalog__loading-line product-catalog__loading-line--title"/><span className="product-catalog__loading-line"/><span className="product-catalog__loading-line product-catalog__loading-line--short"/><span className="product-catalog__loading-card"/><span className="product-catalog__loading-card"/></div>:<form className={`product-catalog__form ${experience === "restaurant" ? "product-catalog__form--restaurant" : ""}`} onSubmit={saveProduct}>
        <div className="product-catalog__form-intro">{experience === "restaurant" ? <div className="restaurant-form-intro"><div><span className="product-catalog__eyebrow">Función culinaria</span><h3>{restaurantRoleLabel(catalogRole)}</h3><p>{catalogRole === "ingredient" ? (draft.id ? "Actualiza cómo se compra y mide este insumo." : "Registra una materia prima con su unidad real de consumo.") : catalogRole === "preparation" ? (draft.id ? "Actualiza la base y su rendimiento." : "Registra la base; después define su rendimiento y receta.") : (draft.id ? "Actualiza el platillo y su receta." : "Registra lo que vendes al comensal y después agrega su receta.")}</p></div><div className="restaurant-form-steps" aria-label="Progreso del formulario"><span className="is-current">1 <small>Datos básicos</small></span>{catalogRole !== "ingredient" && <><span aria-hidden="true">→</span><span>2 <small>Receta</small></span></>}</div></div> : <p>Administra la identidad, inventario, impuestos y disponibilidad del producto canónico.</p>}{draft.sourceReference&&<small>Referencia importada: <strong>{draft.sourceReference}</strong></small>}{draft.id&&<small>Código Satrapy: <strong>{draft.internalSku}</strong></small>}</div>
        <div className="product-catalog__workspace">
          <section className="product-catalog__section product-catalog__identity"><header><h3>{experience === "restaurant" ? `Datos del ${catalogSingular}` : catalogInformationTitle}</h3><p>{experience === "restaurant" ? "La función culinaria ya está definida por este apartado." : "Datos para identificarlo y encontrarlo rápidamente."}</p></header><div className="product-catalog__form-grid">{experience === "restaurant" ? <><Field label={catalogNameLabel}><Input required maxLength={240} autoFocus={!draft.id} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder={catalogRole === "ingredient" ? "Ej. Tomate saladet" : catalogRole === "preparation" ? "Ej. Salsa verde" : "Ej. Enchiladas verdes"}/></Field><Field label="Categoría" hint="Elige una categoría existente o captura otra."><div className="product-catalog__field-control"><Select value={restaurantCategoryValue} onValueChange={value=>{if(value===RESTAURANT_OTHER_CATEGORY){setOtherRestaurantCategory(draft.productGroup);}else{setOtherRestaurantCategory("");setDraft({...draft,productGroup:value===RESTAURANT_NO_CATEGORY?"":value});}}} ariaLabel="Categoría culinaria" options={restaurantCategoryOptions}/>{restaurantCategoryValue===RESTAURANT_OTHER_CATEGORY&&<Input maxLength={160} value={otherRestaurantCategory} onChange={event=>{setOtherRestaurantCategory(event.target.value);setDraft({...draft,productGroup:event.target.value});}} placeholder="Ej. Proteínas"/>}</div></Field>{catalogRole !== "preparation" && <Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field>}<Field label={catalogRole === "dish" ? "Unidad de venta" : "Unidad de consumo"} hint={catalogRole === "dish" ? "Los platillos se venden por pieza." : "La unidad se usará para cantidades y costos de receta."}><Select value={draft.unit} onValueChange={selectRestaurantUnit} ariaLabel={catalogRole === "dish" ? "Unidad de venta" : "Unidad de consumo"} options={catalogRole === "dish" ? [{value:"piece",label:"Pieza"}] : restaurantUnitOptions}/></Field></> : <><Field label={catalogNameLabel}><Input required maxLength={240} autoFocus={!draft.id} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder="Ej. Cable eléctrico"/></Field><Field label="Unidad base" hint="Unidad usada en inventario y venta, por ejemplo KG o PZA."><Input maxLength={80} value={draft.unit} onChange={event=>setDraft({...draft,unit:event.target.value.toUpperCase()})} placeholder="PZA"/></Field><Field label="Grupo" hint="Opcional."><Input maxLength={160} value={draft.productGroup} onChange={event=>setDraft({...draft,productGroup:event.target.value})} placeholder="Ej. Material eléctrico"/></Field><Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field></>}</div></section>

          <section className="product-catalog__section product-catalog__inventory">
            <header>
              <h3>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Compra e inventario" : catalogRole === "preparation" ? "Uso de la preparación" : "Receta y operación") : catalogRole === "preparation" ? "Uso culinario" : "Inventario y compra"}</h3>
              <p>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Recibe el insumo en una presentación y consúmelo en la unidad base." : catalogRole === "preparation" ? "La cantidad producida se define al capturar la receta." : "El platillo no conserva inventario propio: su receta descuenta los componentes.") : catalogRole === "ingredient" ? "Define cómo se recibe y controla este insumo." : catalogRole === "preparation" ? "Una preparación se calcula desde sus insumos y puede reutilizarse en platillos." : "Actívalo sólo si este artículo mantiene existencia propia."}</p>
            </header>
            {experience === "restaurant" ? catalogRole === "ingredient" ? <>
              <div className="restaurant-fixed-role"><Badge tone="info">Insumo con inventario</Badge><p>Se compra, recibe y consume en recetas. Su venta es excepcional y se controla aparte.</p></div>
              <div className="product-catalog__purchase-grid">
                <Field label="Presentación de compra" hint="Elige cómo llega del proveedor.">
                  <Select value={purchasePresentationSelection} onValueChange={value=>{if(value===RESTAURANT_OTHER_PURCHASE_PRESENTATION){setPurchasePresentationSelection(value);setPurchasePresentationOther("");setPurchaseUnit({...purchaseUnit,code:""});}else if(value===RESTAURANT_NO_PURCHASE_PRESENTATION){setPurchasePresentationSelection(value);setPurchasePresentationOther("");setPurchaseUnit({...purchaseUnit,code:""});}else{setPurchasePresentationSelection(value);setPurchasePresentationOther("");setPurchaseUnit({...purchaseUnit,code:value});}}} ariaLabel="Presentación de compra" options={purchasePresentationOptions}/>
                </Field>
                <Field label={purchaseContentLabel} hint={purchaseContentHint}>
                  <Input required inputMode="decimal" readOnly={automaticPurchaseFactor!=null} value={purchaseUnit.factor} onChange={event=>setPurchaseUnit({...purchaseUnit,factor:event.target.value})} placeholder={automaticPurchaseFactor==null?"Ej. 750":"Se calcula automáticamente"}/>
                </Field>
              </div>
              {purchasePresentationSelection===RESTAURANT_OTHER_PURCHASE_PRESENTATION&&<Field label="Otra presentación" hint="Escribe el nombre que usa tu proveedor."><Input required maxLength={80} value={purchasePresentationOther} onChange={event=>{const value=event.target.value.toUpperCase();setPurchasePresentationOther(value);setPurchaseUnit({...purchaseUnit,code:value});}} placeholder="Ej. COSTAL"/></Field>}
              <div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.lotControlled} onChange={event=>setDraft({...draft,lotControlled:event.target.checked})}/> Solicitar lote y caducidad al recibir</label></div>
              <p className="product-catalog__readiness-note">Las presentaciones cambian según la unidad de consumo: peso, volumen o piezas. Para caja, saco, bolsa, paquete o botella, captura el contenido neto real.</p>
            </> : <div className="restaurant-fixed-role"><Badge tone="info">{catalogRole === "preparation" ? "Base interna reutilizable" : "Venta por receta"}</Badge><p>{catalogRole === "preparation" ? "No se recibe ni se vende directamente. Su rendimiento, merma e insumos se capturan en la receta." : "La disponibilidad operativa se evalúa con la receta activa; no convierte el platillo en un insumo."}</p></div> : catalogRole === "preparation" ? <p className="product-catalog__readiness-note">No se vende ni se recibe por separado. Al vender un platillo, Satrapy expande la receta activa y descuenta sus insumos originales.</p> : <><Field label="Tipo operativo" hint="Mercancía exige existencias para vender; servicio no descuenta inventario."><Select value={draft.inventoryPolicy} onValueChange={value=>setDraft({...draft,inventoryPolicy:value as ProductDraft["inventoryPolicy"],lotControlled:value==="tracked"?draft.lotControlled:false})} ariaLabel="Tipo operativo" options={[{value:"unclassified",label:"Elige el tipo operativo"},{value:"tracked",label:"Mercancía con inventario"},{value:"not_required",label:"Servicio sin inventario"}]}/>{draft.inventoryPolicy==="unclassified"&&<span className="product-catalog__tax-selection" role="status">Indica cómo maneja inventario antes de venderlo.</span>}</Field><div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.lotControlled} disabled={draft.inventoryPolicy!=="tracked"} onChange={event=>setDraft({...draft,lotControlled:event.target.checked})}/> Solicitar lote y caducidad al recibir</label></div>{draft.inventoryPolicy==="tracked"&&<><div className="product-catalog__purchase-grid"><Field label="Unidad de compra"><Input maxLength={80} value={purchaseUnit.code} onChange={event=>setPurchaseUnit({...purchaseUnit,code:event.target.value.toUpperCase()})} placeholder={draft.unit||"CAJA"}/></Field><Field label="Unidades base por compra" hint={`${purchaseUnit.code.trim()||"Unidad de compra"} = ${purchaseUnit.factor||"1"} ${draft.unit||"unidad base"}`}><Input inputMode="decimal" value={purchaseUnit.factor} onChange={event=>setPurchaseUnit({...purchaseUnit,factor:event.target.value})} placeholder="1"/></Field></div><p className="product-catalog__readiness-note">El lote y la caducidad se pedirán en cada recepción nueva; el historial no cambia.</p></>}</>}</section>

          {experience === "restaurant" && catalogRole === "preparation" ? <section className="product-catalog__section product-catalog__commerce"><header><h3>Estado de la base</h3><p>Activa la preparación cuando su receta esté completa.</p></header><div className="product-catalog__checks"><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> Preparación activa</label></div><p className="product-catalog__readiness-note">No se vende ni requiere categoría fiscal. La receta define su rendimiento y costo.</p></section> : <section className="product-catalog__section product-catalog__commerce"><header><h3>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Venta excepcional" : "Venta del platillo") : "Impuestos y venta"}</h3><p>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Un insumo sólo se vende cuando se habilita de forma explícita." : "Define el tratamiento fiscal del artículo que llega al comensal.") : "Define el tratamiento fiscal y si puede ofrecerse comercialmente."}</p></header><Field label="Categoría fiscal" hint="La tasa vigente queda auditada."><Select value={draft.taxCategoryId} onValueChange={value=>setDraft(current=>current?{...current,taxCategoryId:value}:current)} ariaLabel="Categoría fiscal" options={[{value:"",label:"Sin categoría fiscal"},...taxCategories.map(category=>({value:category.id,label:`${category.code} · ${category.name}${category.rate!=null?` (${numberFormat(category.rate*100)}%)`:""}`}))]}/>{draft.taxCategoryId&&<span className="product-catalog__tax-selection" role="status">Categoría seleccionada.</span>}</Field><Button type="button" size="sm" variant="ghost" onClick={()=>setTaxEditorOpen(open=>!open)} aria-expanded={taxEditorOpen}>{taxEditorOpen?"Ocultar creación fiscal":"Crear categoría fiscal"}</Button>{taxEditorOpen&&<div className="product-catalog__tax-editor"><Field label="Código fiscal"><Input maxLength={40} value={taxDraft.code} onChange={event=>setTaxDraft({...taxDraft,code:event.target.value.toUpperCase()})} placeholder="IVA16"/></Field><Field label="Nombre fiscal"><Input maxLength={120} value={taxDraft.name} onChange={event=>setTaxDraft({...taxDraft,name:event.target.value})} placeholder="IVA 16%"/></Field><Field label="Tasa porcentual"><Input inputMode="decimal" value={taxDraft.rate} onChange={event=>setTaxDraft({...taxDraft,rate:event.target.value})} placeholder="16"/></Field><Field label="Motivo de alta"><Input maxLength={240} value={taxDraft.reason} onChange={event=>setTaxDraft({...taxDraft,reason:event.target.value})} placeholder="Ej. Alta de tratamiento fiscal"/></Field><Button type="button" variant="secondary" loading={savingTax} disabled={!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()} onClick={()=>void saveTaxCategory()}>Crear y seleccionar</Button></div>}<div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.sellable} onChange={event=>setDraft({...draft,sellable:event.target.checked})}/> {experience === "restaurant" && catalogRole === "ingredient" ? "Habilitar venta excepcional" : "Disponible para venta"}</label><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> {catalogSingularTitle} activo</label></div><p className="product-catalog__readiness-note">{experience === "restaurant" && catalogRole === "ingredient" ? "Venderlo no cambia su función: sigue siendo un insumo para recetas." : experience === "restaurant" ? "La disponibilidad por sucursal se define por separado." : "La disponibilidad por sucursal se define por separado."}</p>{draft.id&&catalogRole === "dish"&&canManageAssortments&&<Button type="button" variant="secondary" onClick={()=>{setCommercialReason(`Actualización de la comercialización del ${catalogSingular}`);setCommercialProduct({id:draft.id!,name:draft.name});setDraft(null);}}>Definir disponibilidad por sucursal</Button>}</section>}

          {draft.id&&canManageCosts&&costContext&&<section className="product-catalog__cost-capture product-catalog__section--wide"><header><div><strong>Valuación de inventario</strong><p>Captura manual para altas o correcciones puntuales.</p></div><Badge tone={costContext.matrix_ready?"success":"warning"}>{costContext.matrix_ready?costMethodLabel(costContext.cost_method):"Matriz pendiente"}</Badge></header>{costContext.matrix_ready?<><div className="product-catalog__cost-summary"><span>Costo vigente<strong>{costContext.current_cost?`${numberFormat(costContext.current_cost.amount)} ${costContext.currency_code}`:"Sin costo"}</strong></span><span>Moneda contable<strong>{costContext.currency_code}</strong></span></div><div className="product-catalog__cost-fields"><Field label="Nuevo costo vigente"><Input inputMode="decimal" value={costDraft.amount} onChange={event=>setCostDraft({...costDraft,amount:event.target.value})} placeholder="0.00"/></Field><Field label="Motivo obligatorio"><Input maxLength={240} value={costDraft.reason} onChange={event=>setCostDraft({...costDraft,reason:event.target.value})} placeholder="Ej. Alta inicial para valuación"/></Field><Button type="button" variant="secondary" loading={savingCost} disabled={!costDraft.reason.trim()||!(Number(costDraft.amount.replace(",","."))>0)} onClick={()=>void saveCurrentCost()}>Guardar costo</Button></div></>:<p className="product-catalog__cost-warning">Primero configura y aprueba la matriz contable.</p>}</section>}
          {draft.id&&(catalogRole === "dish"||catalogRole === "preparation")&&canManageRecipes&&<section className="product-catalog__recipe-action product-catalog__section--wide"><div><strong>{catalogRole === "preparation" ? "Receta de la preparación" : "Receta y costeo"}</strong><p>{catalogRole === "preparation" ? "Define rendimiento, insumos y merma de esta base reutilizable." : "Define rendimiento, insumos, preparaciones y merma."}</p></div><Button type="button" variant="secondary" onClick={()=>{setRecipeProduct({id:draft.id!,name:draft.name,recipeKind:catalogRole==="preparation"?"preparation":"dish"});setDraft(null);}}><ChefHat size={16} aria-hidden="true"/> Abrir receta</Button></section>}
          {canArchiveIngredient&&draft.id&&<section className="product-catalog__archive-action product-catalog__section--wide"><div><strong>Archivar insumo</strong><p>Lo quita del catálogo y de nuevas recetas. Sus movimientos e historial se conservan.</p></div><Button type="button" variant="danger" onClick={()=>void openArchive()}><Archive size={16} aria-hidden="true"/> Archivar insumo</Button></section>}
        </div>
        <label className="operation-reason product-catalog__reason">Motivo obligatorio<textarea required rows={2} value={draft.reason} onChange={event=>setDraft({...draft,reason:event.target.value})} placeholder={draft.id?"Ej. Actualización de información culinaria":experience!=="restaurant"?"Ej. Alta inicial del producto":catalogRole === "ingredient"?"Ej. Alta inicial de insumo":catalogRole === "preparation"?"Ej. Alta inicial de preparación":"Ej. Alta inicial del platillo"}/></label><div className="product-catalog__form-actions"><Button type="button" variant="secondary" disabled={saving} onClick={()=>setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving} disabled={saving||draft.inventoryPolicy==="unclassified"}>{draft.id?"Guardar cambios":experience==="restaurant"?(catalogRole === "ingredient"?"Crear insumo":catalogRole === "preparation"?"Crear preparación y abrir receta":"Crear platillo y abrir receta"): `Crear ${words.singular}`}</Button></div>
      </form>)}
    </Drawer>
    <ProductCommercializationModal companyId={companyId} product={commercialProduct} open={Boolean(commercialProduct)} initialReason={commercialReason} experience={experience} onOpenChange={(open)=>{if(!open)setCommercialProduct(null);}} onSaved={refresh}/>
    <RecipeEditorModal companyId={companyId} product={recipeProduct} recipeKind={recipeProduct?.recipeKind??"dish"} open={Boolean(recipeProduct)} onCreateIngredient={()=>{setRecipeProduct(null);router.replace("/satrapy/inventario/productos?seccion=insumos");void openNew("ingredient");}} onOpenChange={open=>{if(!open){setRecipeProduct(null);void refresh();}}}/>
    <Modal open={integrityReviewOpen} onOpenChange={setIntegrityReviewOpen} eyebrow="Revisión de catálogo" title="Configuraciones por corregir" description="Corrige aquí pocas configuraciones puntuales. Para un catálogo amplio, usa una corrección por lote que conserve la auditoría." footer={<Button variant="secondary" onClick={()=>setIntegrityReviewOpen(false)}>Cerrar revisión</Button>}>
      {integrityIssues.length?<div className="product-catalog__integrity-list">{integrityIssues.map(issue=><article key={`${issue.issue_code}:${issue.id}`}><div><Badge tone="warning">{issue.issue_code==="missing_culinary_role"?"Función pendiente":"Conversión pendiente"}</Badge><strong>{issue.name}</strong><p>{issue.message}</p>{issue.purchase_unit_code&&<small>Presentación actual: {issue.purchase_unit_code}{issue.base_unit_code?` · Unidad de consumo: ${restaurantUnitLabel(issue.base_unit_code)}`:""}</small>}</div><Button type="button" size="sm" variant="secondary" onClick={()=>{setIntegrityReviewOpen(false);void openEdit(issue);}}>Corregir registro</Button></article>)}</div>:<p className="product-catalog__readiness-note">No hay configuraciones pendientes en esta página. Actualiza la lista para revisar de nuevo.</p>}
    </Modal>
    <Modal open={Boolean(archiveTarget)} onOpenChange={open=>{if(!open&&!archiving){setArchiveTarget(null);setArchiveReason("");setArchiveError(null);}}} eyebrow="Acción irreversible en operación" title={archiveTarget?`Archivar ${archiveTarget.name}`:"Archivar insumo"} description="Se conservarán movimientos, costos y auditoría. Primero resuelve las dependencias activas que se muestran aquí." closeDisabled={archiving} footer={<><Button variant="secondary" disabled={archiving} onClick={()=>{setArchiveTarget(null);setArchiveReason("");setArchiveError(null);}}>Cancelar</Button>{!archiveBlocked&&<Button variant="danger" loading={archiving} onClick={()=>void archiveIngredient()}>Archivar insumo</Button>}</>}>
      {archiveTarget?.active_recipes.length ? <section className="product-catalog__archive-dependencies" aria-labelledby="archive-recipes-title"><div><strong id="archive-recipes-title">Recetas activas que usan este insumo</strong><p>Crea una nueva versión de cada receta, quita o reemplaza el insumo y actívala. La versión histórica se conserva.</p></div><ul>{archiveTarget.active_recipes.map(recipe=><li key={`${recipe.product_id}:${recipe.version_number}`}><span><strong>{recipe.product_name}</strong><small>{recipe.recipe_kind==="preparation"?"Preparación":"Platillo"} · versión activa {recipe.version_number}</small></span>{canManageRecipes&&<Button type="button" size="sm" variant="secondary" onClick={()=>{setArchiveTarget(null);setArchiveReason("");setRecipeProduct({id:recipe.product_id,name:recipe.product_name,recipeKind:recipe.recipe_kind});}}>Abrir receta</Button>}</li>)}</ul></section> : null}
      {archiveTarget?.inventory_location_count ? <p className="product-catalog__archive-blocker" role="status">Hay existencias en {archiveTarget.inventory_location_count} {archiveTarget.inventory_location_count===1?"ubicación":"ubicaciones"}. Ajusta o agota el inventario antes de archivar.</p> : null}
      {archiveTarget?.open_purchase_order_count ? <p className="product-catalog__archive-blocker" role="status">Hay {archiveTarget.open_purchase_order_count} {archiveTarget.open_purchase_order_count===1?"orden de compra abierta":"órdenes de compra abiertas"}. Ciérralas o elimina el renglón antes de archivar.</p> : null}
      {!archiveBlocked&&<><label className="operation-reason">Motivo para archivar<textarea ref={archiveReasonInputRef} required rows={3} value={archiveReason} onChange={event=>{setArchiveReason(event.target.value);setArchiveError(null);}} placeholder="Ej. Insumo creado por error; no tiene movimientos" aria-invalid={archiveError?true:undefined} aria-describedby={archiveError?"archive-ingredient-error":undefined}/></label>{archiveError&&<p id="archive-ingredient-error" className="product-catalog__archive-error" role="alert">{archiveError}</p>}</>}
    </Modal>
  </div>;
}
