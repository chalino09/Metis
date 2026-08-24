"use client";

import { Archive, ChefHat, CookingPot, PackageSearch, Plus, RefreshCw, UploadCloud, UtensilsCrossed } from "lucide-react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ProductCommercializationModal } from "@/app/components/ProductCommercializationModal";
import { ProductCreationWizard } from "@/app/components/ProductCreationWizard";
import { RestaurantCatalogImportModal } from "@/app/components/RestaurantCatalogImportModal";
import { RecipeEditorModal } from "@/app/components/RecipeEditorModal";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Drawer, Field, Input, Modal, Select, useToast } from "@/app/components/ui/primitives";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { productReadinessLabel, productReadinessSummary } from "@/app/lib/product-readiness";
import { productVocabulary, type ProductExperience } from "@/app/lib/product-experience";
import { getSupabaseClient } from "@/app/lib/supabase";

const PAGE_SIZE = 50;
type RestaurantCatalogRole = "dish" | "ingredient" | "preparation";
type ProductListRow = { id:string; internal_sku:string; alpha_sku:string|null; name:string; attribute:string|null; barcode:string|null; unit:string|null; product_group:string|null; inventory_policy:"tracked"|"not_required"|"unclassified"; is_active:boolean; is_sellable:boolean; is_inventory_tracked:boolean; base_price?:number|null; price:number|null; currency_code:string|null; assortment_count?:number; offered_location_count?:number; quantity_on_hand?:number|null; pos_ready:boolean; blockers?:string[]; catalog_role?:RestaurantCatalogRole; is_preparation?:boolean; purchase_unit_code?:string|null; base_units_per_purchase_unit?:number|null; recipe_status?:"active"|"draft"|"missing"; recipe_version_number?:number|null; recipe_yield_quantity?:number|null; recipe_yield_unit_code?:string|null; recipe_portion_count?:number|null; usage_count?:number; invalid_component_count?:number };
type TaxCategory = { id:string; code:string; name:string; rate:number|null; is_active:boolean };
type ProductCostContext = { product:{id:string;name:string}; cost_method:"replacement_cost"|"standard_cost"|"average_cost"|null; currency_code:string|null; matrix_ready:boolean; current_cost:{id:string;amount:number;valid_from:string}|null };
type DishPriceList = { id:string;name:string;currency_code:string;is_active:boolean;is_default:boolean };
type DishPriceProduct = { product_id:string;amount:number|null;tax_rate:number|null;tax_amount:number|null;total_amount:number|null };
type DishRecipeContext = { active:{status:string;cost?:{allowed:boolean;cost_per_portion:number|null;currency_code:string;blockers:Array<{message:string}>}}|null;draft:{status:string;cost?:{allowed:boolean;cost_per_portion:number|null;currency_code:string;blockers:Array<{message:string}>}}|null;sale_price:number|null;currency_code:string };
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
  dish:["Desayunos","Entradas","Sopas y ensaladas","Platos fuertes","Guarniciones","Postres","Bebidas","Extras","Otros platillos"],
  preparation:["Salsas","Aderezos","Caldos y fondos","Marinados","Masas","Cremas y bases","Guarniciones base","Otras bases"],
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
  return role==="ingredient"?"Insumo":role==="preparation"?"Base reutilizable":"Platillo";
}
function errorMessage(error:{message?:string}|null, fallback:string) { return error?.message?.replace(/^.*?error:\s*/i, "").trim() || fallback; }
function catalogLoadError(error:{message?:string}|null, label:string) {
  const raw=error?.message?.toLowerCase()??"";
  return raw.includes("schema cache")||raw.includes("does not exist")||raw.includes("could not find the function")
    ? `Falta instalar la migración de catálogo culinario (202608230001) para cargar ${label}.`
    : `No se pudieron cargar los ${label}.`;
}
function numberFormat(value:number) { return new Intl.NumberFormat("es-MX", { maximumFractionDigits:3 }).format(value); }
function moneyFormat(value:number|null|undefined,currency="MXN") { return value==null?"Pendiente":new Intl.NumberFormat("es-MX",{style:"currency",currency,maximumFractionDigits:2}).format(value); }
function costMethodLabel(value:ProductCostContext["cost_method"]) { return value==="replacement_cost"?"Costo de reposición":value==="standard_cost"?"Costo estándar":value==="average_cost"?"Costo promedio":"Sin método activo"; }

function recipeState(row:ProductListRow) {
  if((row.invalid_component_count??0)>0)return {label:"Revisar receta",tone:"danger" as const,detail:"Contiene componentes no permitidos"};
  if(row.recipe_status==="active")return {label:"Receta activa",tone:"success" as const,detail:row.recipe_version_number?`Versión ${row.recipe_version_number}`:"Lista para usar"};
  if(row.recipe_status==="draft")return {label:"Borrador",tone:"warning" as const,detail:"Falta activar"};
  return {label:"Sin receta",tone:"neutral" as const,detail:"Falta capturar"};
}

function RestaurantCatalogTable({role,rows,canManage,onEdit}:{role:RestaurantCatalogRole;rows:ProductListRow[];canManage:boolean;onEdit:(row:ProductListRow)=>void}) {
  if(role==="ingredient")return <div className="table-wrap surface-table"><table className="restaurant-catalog-table"><thead><tr><th>Código</th><th>Insumo</th><th>Categoría</th><th>Unidad de consumo</th><th>Presentación de compra</th><th>Uso en recetas</th><th>Estado</th></tr></thead><tbody>{rows.map(row=><InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar insumo ${row.name}`} onActivate={()=>onEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.barcode&&<small>{row.barcode}</small>}</td><td>{restaurantCategoryDisplay(row.product_group,role)}</td><td><strong>{restaurantUnitShortLabel(row.unit)}</strong><small>Se descuenta en recetas</small></td><td><strong>{row.purchase_unit_code??"Pendiente"}</strong><small>{row.base_units_per_purchase_unit?`${numberFormat(row.base_units_per_purchase_unit)} ${restaurantUnitShortLabel(row.unit)}`:"Completa la equivalencia"}</small></td><td><strong>{row.usage_count??0}</strong><small>{(row.usage_count??0)===1?"receta activa":"recetas activas"}</small></td><td><Badge tone={row.is_active?"success":"neutral"}>{row.is_active?"Activo":"Inactivo"}</Badge></td></InteractiveTableRow>)}</tbody></table></div>;
  if(role==="preparation")return <div className="table-wrap surface-table"><table className="restaurant-catalog-table"><thead><tr><th>Código</th><th>Base reutilizable</th><th>Categoría</th><th>Rendimiento por tanda</th><th>Receta</th><th>Uso en recetas</th><th>Estado</th></tr></thead><tbody>{rows.map(row=>{const state=recipeState(row);return <InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar base ${row.name}`} onActivate={()=>onEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong></td><td><strong>{row.name}</strong><small>Base interna</small></td><td>{restaurantCategoryDisplay(row.product_group,role)}</td><td><strong>{row.recipe_yield_quantity?numberFormat(row.recipe_yield_quantity):"—"} {row.recipe_yield_unit_code?restaurantUnitShortLabel(row.recipe_yield_unit_code):""}</strong><small>{row.recipe_status==="active"?`Rinde para ${numberFormat(row.recipe_portion_count??1)} ${(row.recipe_portion_count??1)===1?"platillo":"platillos"}`:"Se define en la receta"}</small></td><td><Badge tone={state.tone}>{state.label}</Badge><small>{state.detail}</small></td><td><strong>{row.usage_count??0}</strong><small>{(row.usage_count??0)===1?"receta activa":"recetas activas"}</small></td><td><Badge tone={row.is_active?"success":"neutral"}>{row.is_active?"Activa":"Inactiva"}</Badge></td></InteractiveTableRow>;})}</tbody></table></div>;
  return <div className="table-wrap surface-table"><table className="restaurant-catalog-table"><thead><tr><th>Código</th><th>Platillo</th><th>Categoría</th><th>Receta por porción</th><th>Venta</th><th className="number-cell">Precio</th></tr></thead><tbody>{rows.map(row=>{const state=recipeState(row);return <InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar platillo ${row.name}`} onActivate={()=>onEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.barcode&&<small>{row.barcode}</small>}</td><td>{restaurantCategoryDisplay(row.product_group,role)}</td><td><Badge tone={state.tone}>{state.label}</Badge><small>{state.detail}</small></td><td><Badge tone={row.pos_ready?"success":row.is_sellable?"warning":"neutral"}>{row.pos_ready?"Listo para operar":row.is_sellable?"Configuración pendiente":"No disponible"}</Badge></td><td className="number-cell"><strong>{row.price!=null?`${numberFormat(row.price)} ${row.currency_code??""}`:"—"}</strong></td></InteractiveTableRow>;})}</tbody></table></div>;
}

export function ProductCatalogView({ companyId, permissions, experience="core" }: { companyId:string; permissions:string[]; experience?:ProductExperience }) {
  const words = productVocabulary(experience);
  const router = useRouter();
  const searchParams = useSearchParams();
  const catalogRole: RestaurantCatalogRole = experience === "restaurant" && searchParams.get("seccion") === "preparaciones" ? "preparation" : experience === "restaurant" && searchParams.get("seccion") === "insumos" ? "ingredient" : "dish";
  const catalogPlural = experience === "restaurant" ? (catalogRole === "ingredient" ? "insumos" : catalogRole === "preparation" ? "bases" : "platillos") : words.plural;
  const catalogSingular = experience === "restaurant" ? (catalogRole === "ingredient" ? "insumo" : catalogRole === "preparation" ? "base" : "platillo") : words.singular;
  const catalogPluralTitle = experience === "restaurant" ? (catalogRole === "ingredient" ? "Insumos" : catalogRole === "preparation" ? "Bases reutilizables" : "Menú") : words.pluralTitle;
  const catalogSingularTitle = experience === "restaurant" ? (catalogRole === "ingredient" ? "Insumo" : catalogRole === "preparation" ? "Base reutilizable" : "Platillo") : words.singularTitle;
  const catalogAllLabel = catalogRole === "preparation" ? "Todas las bases" : `Todos los ${catalogPlural}`;
  const catalogInformationTitle = catalogRole === "preparation" ? "Información de la base" : experience === "restaurant" ? `Información del ${catalogSingular}` : "Información básica";
  const catalogNameLabel = catalogRole === "preparation" ? "Nombre de la base" : experience === "restaurant" ? `Nombre del ${catalogSingular}` : "Nombre del producto";
  const canManage = permissions.includes("manage_products");
  const canManageAssortments = permissions.includes("manage_assortments");
  const canUseGuidedCreate = experience==="core"&&canManage&&permissions.includes("manage_prices")&&canManageAssortments;
  const canManageCosts = permissions.includes("import_costs");
  const canManagePrices = permissions.includes("manage_prices");
  const canConfigureCostPolicy = permissions.includes("view_accounting") && permissions.includes("configure_accounting_events");
  const canManageRecipes = experience==="restaurant"&&permissions.includes("manage_recipes");
  const { queryCache } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const requestId = useRef(0);
  const detailRequestId = useRef(0);
  const [rows,setRows] = useState<ProductListRow[]>([]); const [loading,setLoading] = useState(true); const [error,setError] = useState<string|null>(null);
  const [search,setSearch] = useState(""); const [debouncedSearch,setDebouncedSearch] = useState(""); const [saleFilter,setSaleFilter] = useState("all"); const [page,setPage] = useState(1); const [total,setTotal] = useState(0);
  const [draft,setDraft] = useState<ProductDraft|null>(null); const [detailLoading,setDetailLoading] = useState(false); const [saving,setSaving] = useState(false);
  const [editingReadiness,setEditingReadiness] = useState<{posReady:boolean;blockers:string[];price:number|null;currencyCode:string|null;quantityOnHand:number|null}|null>(null);
  const [creationOpen,setCreationOpen] = useState(false);
  const [importOpen,setImportOpen] = useState(false);
  const [commercialProduct,setCommercialProduct] = useState<{id:string;name:string}|null>(null);
  const [recipeProduct,setRecipeProduct] = useState<{id:string;name:string;recipeKind:"dish"|"preparation"}|null>(null);
  const [commercialReason,setCommercialReason] = useState("");
  const [costContext,setCostContext] = useState<ProductCostContext|null>(null);
  const [costDraft,setCostDraft] = useState({amount:"",reason:""});
  const [savingCost,setSavingCost] = useState(false);
  const [dishPriceLists,setDishPriceLists] = useState<DishPriceList[]>([]);
  const [dishPriceListId,setDishPriceListId] = useState("");
  const [dishFinalPrice,setDishFinalPrice] = useState("");
  const [dishPriceLoading,setDishPriceLoading] = useState(false);
  const [savingDishPrice,setSavingDishPrice] = useState(false);
  const [dishRecipeContext,setDishRecipeContext] = useState<DishRecipeContext|null>(null);
  const [purchaseUnit,setRawPurchaseUnit] = useState({code:"",factor:""});
  const [purchasePresentationSelection,setPurchasePresentationSelection] = useState(RESTAURANT_NO_PURCHASE_PRESENTATION);
  const [purchasePresentationOther,setPurchasePresentationOther] = useState("");
  const [otherRestaurantCategory,setOtherRestaurantCategory] = useState("");
  const [restaurantCategoryIsOther,setRestaurantCategoryIsOther] = useState(false);
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
  const catalogFormTitle = draft?.id ? `Editar ${catalogSingular}` : catalogRole === "preparation" ? "Nueva base reutilizable" : `Nuevo ${catalogSingular}`;
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
    const client=getSupabaseClient();
    const response=experience === "restaurant"
      ? await client.rpc("search_restaurant_catalog",{p_company_id:companyId,p_role:catalogRole,p_query:debouncedSearch||null,p_page:page,p_page_size:PAGE_SIZE,p_is_sellable:isSellable})
      : await client.rpc("search_products",{p_company_id:companyId,p_query:debouncedSearch||null,p_page:page,p_page_size:PAGE_SIZE,p_is_sellable:isSellable});
    const {data,error:queryError}=response;
    if(current!==requestId.current)return;
    const result=data as {items?:ProductListRow[];total?:number}|null;
    let nextRows=result?.items??[];
    if(experience==="core"&&!queryError){
      const trackedIds=nextRows.filter(item=>item.inventory_policy==="tracked").map(item=>item.id);
      if(trackedIds.length){
        const {data:balances,error:balanceError}=await client.from("inventory_balances").select("product_id, quantity_on_hand").eq("company_id",companyId).in("product_id",trackedIds);
        if(current!==requestId.current)return;
        if(!balanceError){
          const totals=new Map<string,number>();
          for(const balance of balances??[])totals.set(balance.product_id,(totals.get(balance.product_id)??0)+Number(balance.quantity_on_hand??0));
          nextRows=nextRows.map(item=>item.inventory_policy==="tracked"?{...item,quantity_on_hand:totals.get(item.id)??0}:item);
        }
      }
    }
    const next={rows:nextRows,total:result?.total??0};
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
  const loadDishPriceForList = useCallback(async (productId:string,internalSku:string,priceListId:string) => {
    if(!priceListId){setDishFinalPrice("");return;}
    setDishPriceLoading(true);
    const {data,error:priceError}=await getSupabaseClient().rpc("search_price_list_products",{p_company_id:companyId,p_price_list_id:priceListId,p_query:internalSku,p_page:1,p_page_size:20});
    const item=((data as {items?:DishPriceProduct[]}|null)?.items??[]).find(candidate=>candidate.product_id===productId);
    setDishFinalPrice(item?.total_amount==null?"":String(item.total_amount));
    setDishPriceLoading(false);
    if(priceError)toast({title:"No se pudo consultar el precio",description:errorMessage(priceError,"Puedes editar el platillo, pero el precio no se cargó."),tone:"error"});
  },[companyId,toast]);
  const loadDishCommercialContext = useCallback(async (productId:string,internalSku:string) => {
    setDishPriceLoading(true);
    const client=getSupabaseClient();
    const [listsResult,recipeResult]=await Promise.all([
      canManagePrices?client.rpc("list_price_lists_admin",{p_company_id:companyId}):Promise.resolve({data:[],error:null}),
      client.rpc("get_culinary_recipe_context",{p_company_id:companyId,p_product_id:productId}),
    ]);
    const lists=((listsResult.data??[]) as DishPriceList[]).filter(list=>list.is_active);
    const selected=(lists.find(list=>list.is_default)??lists[0])?.id??"";
    setDishPriceLists(lists);setDishPriceListId(selected);
    setDishRecipeContext(recipeResult.error?null:recipeResult.data as DishRecipeContext);
    if(listsResult.error)toast({title:"No se pudieron cargar las listas de precios",description:errorMessage(listsResult.error,"Actualiza e intenta nuevamente."),tone:"error"});
    if(selected)await loadDishPriceForList(productId,internalSku,selected);else{setDishFinalPrice("");setDishPriceLoading(false);}
  },[canManagePrices,companyId,loadDishPriceForList,toast]);
  async function createDefaultDishPriceList(){
    if(!canManagePrices)return;
    setSavingDishPrice(true);
    const fingerprint=JSON.stringify({companyId,name:"Precio general",currency:"MXN"});
    const {data,error}=await getSupabaseClient().rpc("save_price_list",{p_company_id:companyId,p_price_list_id:null,p_internal_code:"GENERAL",p_name:"Precio general",p_currency_code:"MXN",p_is_active:true,p_is_default:true,p_reason:"Alta de lista predeterminada desde el platillo",p_expected_updated_at:null,p_client_request_id:idempotency.get("create-default-dish-price-list",fingerprint)});
    setSavingDishPrice(false);
    if(error){toast({title:"No se pudo crear la lista",description:errorMessage(error,"Verifica si ya existe una lista con el código GENERAL."),tone:"error"});return;}
    idempotency.clear("create-default-dish-price-list");
    const created=data as DishPriceList;
    setDishPriceLists([created]);setDishPriceListId(created.id);setDishFinalPrice("");
    toast({title:"Lista creada",description:"Precio general quedó como lista predeterminada.",tone:"success"});
  }
  async function saveDishPrice(productId:string,taxRate:number,reason:string){
    if(!canManagePrices||!dishPriceListId||!dishFinalPrice.trim())return true;
    const finalPrice=Number(dishFinalPrice.replace(",","."));
    if(!(finalPrice>0))return false;
    setSavingDishPrice(true);
    const baseAmount=finalPrice/(1+taxRate);
    const fingerprint=JSON.stringify({productId,priceListId:dishPriceListId,baseAmount});
    const {error}=await getSupabaseClient().rpc("save_product_price",{p_company_id:companyId,p_price_list_id:dishPriceListId,p_product_id:productId,p_amount:baseAmount,p_effective_from:null,p_reason:reason,p_client_request_id:idempotency.get("save-dish-price",fingerprint)});
    setSavingDishPrice(false);
    if(error){toast({title:"El platillo se guardó, pero falta el precio",description:errorMessage(error,"Vuelve a guardar el precio."),tone:"error"});return false;}
    idempotency.clear("save-dish-price");return true;
  }
  async function refresh(){queryCache.invalidate(`products:${companyId}:`);await Promise.all([load(true),loadIntegrityIssues()]);}
  async function openEdit(row:ProductListRow){
    if(!canManage)return;
    setEditingReadiness({posReady:row.pos_ready,blockers:row.blockers??[],price:row.price,currencyCode:row.currency_code,quantityOnHand:row.quantity_on_hand??null});
    const detailRequest=++detailRequestId.current;
    const rowRole=experience==="restaurant"&&row.catalog_role?row.catalog_role:catalogRole;
    const fallbackUnit=rowRole==="ingredient"?"g":rowRole==="preparation"?"ml":"piece";
    setOtherRestaurantCategory(row.product_group??"");
    setRestaurantCategoryIsOther(Boolean(row.product_group && restaurantCategorySelectValue(row.product_group,restaurantCategoryLabels[rowRole])===RESTAURANT_OTHER_CATEGORY));
    setDraft({id:row.id,internalSku:row.internal_sku,name:row.name,barcode:row.barcode??"",unit:experience==="restaurant"?catalogRole==="dish"?"piece":restaurantUnitCode(row.unit,catalogRole==="preparation"?"":fallbackUnit):row.unit??"",productGroup:row.product_group??"",taxCategoryId:"",inventoryPolicy:row.inventory_policy==="tracked"||row.inventory_policy==="not_required"?row.inventory_policy:"unclassified",lotControlled:false,sellable:row.is_sellable,active:row.is_active,reason:"",updatedAt:null,sourceReference:row.alpha_sku});
    setDetailLoading(true);
    setTaxEditorOpen(false);
    setDishPriceLists([]);setDishPriceListId("");setDishFinalPrice("");setDishRecipeContext(null);
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
    setRestaurantCategoryIsOther(Boolean(data.product_group && restaurantCategorySelectValue(data.product_group,restaurantCategoryLabels[rowRole])===RESTAURANT_OTHER_CATEGORY));
    setDraft({id:data.id,internalSku:data.internal_sku,name:data.name,barcode:data.barcode??"",unit:experience==="restaurant"?catalogRole==="dish"?"piece":restaurantUnitCode(data.unit,catalogRole==="ingredient"?"g":""):data.unit??"",productGroup:data.product_group??"",taxCategoryId:data.tax_category_id??"",inventoryPolicy:data.inventory_policy==="tracked"||data.inventory_policy==="not_required"?data.inventory_policy:"unclassified",lotControlled:data.lot_controlled,sellable:data.is_sellable,active:data.is_active,reason:"",updatedAt:data.updated_at,sourceReference:data.alpha_sku});
    if(experience==="restaurant"&&rowRole==="dish")await loadDishCommercialContext(data.id,data.internal_sku);
    setDetailLoading(false);
  }
  async function openNew(role:RestaurantCatalogRole=catalogRole){await loadTaxCategories();if(canUseGuidedCreate){setCreationOpen(true);return;}setTaxEditorOpen(false);setCostContext(null);setCostDraft({amount:"",reason:""});setRawPurchaseUnit({code:"",factor:""});setPurchasePresentationSelection(RESTAURANT_NO_PURCHASE_PRESENTATION);setPurchasePresentationOther("");setOtherRestaurantCategory("");setRestaurantCategoryIsOther(false);setDishPriceLists([]);setDishPriceListId("");setDishFinalPrice("");setDishRecipeContext(null);if(experience==="restaurant"&&role==="dish"&&canManagePrices){const {data}=await getSupabaseClient().rpc("list_price_lists_admin",{p_company_id:companyId});const lists=((data??[]) as DishPriceList[]).filter(list=>list.is_active);setDishPriceLists(lists);setDishPriceListId((lists.find(list=>list.is_default)??lists[0])?.id??"");}setDraft({...emptyDraft(),unit:experience==="restaurant"?restaurantUnitCode(null,role==="ingredient"?"g":role==="preparation"?"":"piece"):"",inventoryPolicy:experience==="restaurant"&&role!=="ingredient"?"not_required":"tracked",sellable:experience!=="restaurant"||role==="dish"});}
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
    const normalized={...draft,internalSku:draft.internalSku.trim().toUpperCase(),name:draft.name.trim(),unit:experience==="restaurant"?catalogRole==="dish"?"piece":restaurantUnitCode(draft.unit,catalogRole==="ingredient"?"g":""):draft.unit.trim(),productGroup:draft.productGroup.trim(),reason:draft.reason.trim()};
    if(!normalized.name||!normalized.reason)return;
    const selectedTaxCategoryId=experience==="restaurant"&&catalogRole!=="dish"?null:normalized.taxCategoryId||null;
    const fingerprint=JSON.stringify(normalized);setSaving(true);
    const client=getSupabaseClient();
    const requestKey=idempotency.get("save-product",fingerprint);
    const purchaseCode=(purchaseUnit.code.trim()||normalized.unit.trim()).toUpperCase();
    const purchaseFactor=Number(purchaseUnit.factor.replace(",","."));
    const response=experience==="restaurant"
      ? await client.rpc("save_restaurant_catalog_item",{p_company_id:companyId,p_product_id:normalized.id,p_internal_sku:normalized.internalSku,p_name:normalized.name,p_barcode:normalized.barcode.trim()||null,p_unit:normalized.unit.trim()||null,p_product_group:normalized.productGroup.trim()||null,p_role:catalogRole,p_is_sellable:catalogRole==="dish"&&normalized.sellable,p_is_active:normalized.active,p_tax_category_id:catalogRole==="dish"?selectedTaxCategoryId:null,p_purchase_unit_code:catalogRole==="ingredient"?purchaseCode:null,p_base_units_per_purchase_unit:catalogRole==="ingredient"?purchaseFactor:null,p_lot_controlled:catalogRole==="ingredient"&&normalized.lotControlled,p_reason:normalized.reason,p_expected_updated_at:normalized.updatedAt,p_client_request_id:requestKey})
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
      if(experience==="restaurant"&&catalogRole==="dish"&&saved?.id&&dishFinalPrice.trim()){
        const selectedTax=taxCategories.find(category=>category.id===selectedTaxCategoryId);
        if(selectedTax?.rate==null){
          idempotency.clear("save-product");
          setDraft(current=>current?{...current,updatedAt:saved.updated_at??current.updatedAt}:current);
          setSaving(false);
          toast({title:"El platillo se guardó, pero falta el impuesto",description:"Selecciona una categoría fiscal con tasa vigente para calcular y guardar el precio final.",tone:"error"});
          return;
        }
        const priceSaved=await saveDishPrice(saved.id,selectedTax.rate,normalized.reason);
        if(!priceSaved){
          idempotency.clear("save-product");
          setDraft(current=>current?{...current,updatedAt:saved.updated_at??current.updatedAt}:current);
          setSaving(false);
          return;
        }
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
  const restaurantCategoryValue=restaurantCategoryIsOther?RESTAURANT_OTHER_CATEGORY:restaurantCategorySelectValue(draft?.productGroup??"",restaurantCategoryLabels[catalogRole]);
  const purchasePresentationOptions=restaurantPurchasePresentationOptionsFor(draft?.unit);
  const automaticPurchaseFactor=draft&&catalogRole==="ingredient"?restaurantAutomaticPurchaseFactor(purchaseUnit.code,draft.unit):null;
  const purchaseContentLabel=automaticPurchaseFactor==null?"Contenido neto por presentación":"Equivalencia automática";
  const purchaseContentHint=automaticPurchaseFactor==null?`Escribe ${restaurantUnitQuantityPrompt(draft?.unit)} ${restaurantUnitLabel(draft?.unit)} contiene 1 ${restaurantPurchasePresentationName(purchaseUnit.code||purchasePresentationOther)}.`:`1 ${restaurantPurchasePresentationName(purchaseUnit.code)} = ${purchaseUnit.factor||"—"} ${restaurantUnitLabel(draft?.unit,Number(purchaseUnit.factor||0)===1)}`;
  const archiveBlocked=Boolean(archiveTarget&&(archiveTarget.active_recipes.length>0||archiveTarget.inventory_location_count>0||archiveTarget.open_purchase_order_count>0));
  const selectedDishPriceList=dishPriceLists.find(list=>list.id===dishPriceListId)??null;
  const selectedDishTax=taxCategories.find(category=>category.id===draft?.taxCategoryId)??null;
  const parsedDishFinalPrice=Number(dishFinalPrice.replace(",","."))||0;
  const dishBasePrice=selectedDishTax?.rate==null?null:parsedDishFinalPrice/(1+selectedDishTax.rate);
  const dishTaxAmount=dishBasePrice==null?null:parsedDishFinalPrice-dishBasePrice;
  const dishRecipeVersion=dishRecipeContext?.draft??dishRecipeContext?.active;
  const dishCost=dishRecipeVersion?.cost?.cost_per_portion??null;
  const dishMargin=parsedDishFinalPrice>0&&dishCost!=null?parsedDishFinalPrice-dishCost:null;
  return <div className="content-frame product-catalog">
    <PageHeading eyebrow={experience === "restaurant" ? "Operación culinaria" : "Catálogo administrable"} title={catalogPluralTitle} description={experience==="restaurant"?(catalogRole === "ingredient"?"Administra lo que compras, recibes y utilizas en las recetas.":catalogRole === "preparation"?"Administra salsas, caldos y mezclas que preparas por tanda y reutilizas.":"Administra los platillos del punto de venta y su receta por porción."):"Crea y mantiene productos canónicos de Satrapy. La importación acelera cargas grandes, pero no es necesaria para operar."} action={<div className="product-catalog__heading-actions"><Button variant="secondary" onClick={() => void refresh()}><RefreshCw size={16} aria-hidden="true"/> Actualizar</Button>{canManage&&experience==="restaurant"&&catalogRole==="ingredient"&&<Button variant="secondary" onClick={() => setImportOpen(true)}><UploadCloud size={16} aria-hidden="true"/> Importar insumos</Button>}{canManage&&<Button variant="primary" onClick={() => void openNew()}><Plus size={16} aria-hidden="true"/> {catalogRole === "preparation" ? "Nueva base" : `Nuevo ${catalogSingular}`}</Button>}</div>}/>
    {experience === "restaurant" && <nav className="restaurant-catalog-tabs" aria-label="Catálogo del restaurante"><div className="restaurant-catalog-tabs__primary"><Link href="/satrapy/inventario/productos" className={catalogRole === "dish" ? "is-active" : undefined} aria-current={catalogRole === "dish" ? "page" : undefined} onClick={() => {setPage(1);setSaleFilter("all");}}><span className="restaurant-catalog-tabs__icon"><UtensilsCrossed size={19} aria-hidden="true"/></span><span><strong>Menú</strong><small>Platillos y receta por porción</small></span></Link><Link href="/satrapy/inventario/productos?seccion=insumos" className={catalogRole === "ingredient" ? "is-active" : undefined} aria-current={catalogRole === "ingredient" ? "page" : undefined} onClick={() => {setPage(1);setSaleFilter("all");}}><span className="restaurant-catalog-tabs__icon"><PackageSearch size={19} aria-hidden="true"/></span><span><strong>Insumos</strong><small>Lo que compras y consumes</small></span></Link></div><Link href="/satrapy/inventario/productos?seccion=preparaciones" className={`restaurant-catalog-tabs__secondary${catalogRole === "preparation" ? " is-active" : ""}`} aria-current={catalogRole === "preparation" ? "page" : undefined} onClick={() => {setPage(1);setSaleFilter("all");}}><span className="restaurant-catalog-tabs__icon"><CookingPot size={18} aria-hidden="true"/></span><span><span className="restaurant-catalog-tabs__secondary-title"><strong>Bases reutilizables</strong><Badge tone="neutral">Opcional</Badge></span><small>Salsas, caldos y mezclas preparadas por tanda</small></span></Link></nav>}
    {experience === "restaurant" && catalogRole === "ingredient" && integrityTotal > 0 && <section className="product-catalog__integrity-notice" aria-labelledby="catalog-integrity-title"><div><strong id="catalog-integrity-title">{integrityTotal} {integrityTotal === 1 ? "insumo requiere" : "insumos requieren"} revisión</strong><p>Confirma la presentación y su contenido real antes de usar estos registros en operación. Para una carga amplia, usa una corrección por lote.</p></div><Button type="button" variant="secondary" onClick={()=>setIntegrityReviewOpen(true)}>Revisar configuraciones</Button></section>}
    <DataToolbar search={search} onSearchChange={setSearch} placeholder={experience === "restaurant" && catalogRole === "ingredient" ? "Buscar insumo por nombre o código" : experience === "restaurant" && catalogRole === "preparation" ? "Buscar base por nombre o código" : "Buscar platillo por nombre o código"} filters={<Select value={saleFilter} onValueChange={value=>{setSaleFilter(value);setPage(1);}} ariaLabel={experience==="restaurant"&&catalogRole!=="dish"?"Filtrar por estado":"Filtrar por disponibilidad de venta"} options={experience==="restaurant"&&catalogRole!=="dish"?[{value:"all",label:catalogAllLabel},{value:"sellable",label:"Activos"},{value:"not_sellable",label:"Inactivos"}]:[{value:"all",label:catalogAllLabel},{value:"sellable",label:"Disponibles para venta"},{value:"not_sellable",label:"No disponibles"}]}/>} activeFilters={(search.trim()?1:0)+(saleFilter!=="all"?1:0)} onClear={clearFilters} results={total}/>
    <DataRefreshStatus loading={loading} hasData={rows.length}/>
    <DataState loading={loading&&rows.length===0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={() => void refresh()}>Reintentar</Button>} hasData={rows.length} emptyTitle={search||saleFilter!=="all"?"Sin coincidencias":`Aún no hay ${catalogPlural}`} empty={search||saleFilter!=="all"?`No hay ${catalogPlural} que coincidan con estos criterios.`:canManage?`Crea ${catalogRole === "preparation" ? "la primera" : "el primer"} ${catalogSingular} para comenzar a operar.`:`Tu perfil sólo permite consultar ${catalogPlural}.`} emptyAction={canManage&&!search&&saleFilter==="all"?<Button size="sm" variant="primary" onClick={() => void openNew()}><Plus size={15} aria-hidden="true"/> {catalogRole === "preparation"?"Crear la primera base":`Crear primer ${catalogSingular}`}</Button>:undefined}>
      {experience==="restaurant"?<RestaurantCatalogTable role={catalogRole} rows={rows} canManage={canManage} onEdit={row=>void openEdit(row)}/>:<div className="table-wrap surface-table"><table><thead><tr><th>Código</th><th>Producto</th><th>Tipo y unidad</th><th className="number-cell">Precio final</th><th>Sucursales</th><th>Estado de venta</th></tr></thead><tbody>{rows.map(row=>{const blockers=row.blockers??[];const withoutStock=row.inventory_policy==="tracked"&&row.quantity_on_hand!=null&&row.quantity_on_hand<=0;return <InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar producto ${row.name}`} onActivate={()=>void openEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.product_group&&<small>{row.product_group}</small>}</td><td><strong>{row.inventory_policy==="tracked"?"Mercancía":row.inventory_policy==="not_required"?"Servicio":"Por definir"}</strong><small>{row.unit??"Sin unidad"}</small></td><td className="number-cell"><strong>{row.price!=null?`${numberFormat(row.price)} ${row.currency_code??""}`:"—"}</strong>{row.price!=null&&<small>Impuesto incluido</small>}</td><td><strong>{row.offered_location_count??0}</strong><small>{(row.offered_location_count??0)===1?"sucursal":"sucursales"}</small></td><td><Badge tone={row.pos_ready?"success":"warning"}>{row.pos_ready?"Configurado":`Faltan ${blockers.length} ${blockers.length===1?"paso":"pasos"}`}</Badge>{row.pos_ready&&withoutStock?<small>Sin existencia</small>:!row.pos_ready&&<small>{productReadinessSummary(blockers)}</small>}</td></InteractiveTableRow>;})}</tbody></table></div>}
    </DataState><DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} label={catalogPlural}/>
    <Drawer open={Boolean(draft)} onOpenChange={open=>{if(!open&&!saving&&!savingDishPrice){detailRequestId.current+=1;setDraft(null);setEditingReadiness(null);setDetailLoading(false);setCostContext(null);setDishPriceLists([]);setDishPriceListId("");setDishFinalPrice("");setDishRecipeContext(null);}}} title={catalogFormTitle} className="product-catalog__drawer">
      {draft&&(detailLoading?<div className="product-catalog__loading" role="status" aria-live="polite" aria-busy="true"><span className="sr-only">Cargando datos del {catalogSingular}…</span><span className="product-catalog__loading-line product-catalog__loading-line--title"/><span className="product-catalog__loading-line"/><span className="product-catalog__loading-line product-catalog__loading-line--short"/><span className="product-catalog__loading-card"/><span className="product-catalog__loading-card"/></div>:<form className={`product-catalog__form ${experience === "restaurant" ? "product-catalog__form--restaurant" : ""} ${experience === "restaurant"&&catalogRole === "dish" ? "product-catalog__form--dish" : ""} ${draft.id ? "product-catalog__form--editing" : ""}`} onSubmit={saveProduct}>
        <div className="product-catalog__form-intro">{experience === "restaurant" ? <div className="restaurant-form-intro"><div><span className="product-catalog__eyebrow">{draft.id?"Editar datos":"Nuevo registro"}</span><h3>{restaurantRoleLabel(catalogRole)}</h3><p>{catalogRole === "ingredient" ? (draft.id ? "Actualiza cómo compras y mides este insumo." : "Registra una materia prima con su unidad real de consumo.") : catalogRole === "preparation" ? (draft.id ? "Actualiza únicamente los datos generales de esta base." : "Primero registra la base; enseguida agregarás sus insumos y rendimiento.") : (draft.id ? "Actualiza únicamente los datos comerciales del platillo." : "Primero registra el platillo; enseguida agregarás lo que lleva una porción.")}</p></div>{!draft.id&&catalogRole!=="ingredient"&&<div className="restaurant-form-steps" aria-label="Progreso del alta"><span className="is-current">1 <small>Datos</small></span><span aria-hidden="true">→</span><span>2 <small>Receta</small></span></div>}</div> : draft.id?<div className="product-catalog__edit-summary"><div><span className="product-catalog__eyebrow">Edición puntual</span><strong>{draft.name}</strong><small>{draft.internalSku} · {draft.inventoryPolicy==="tracked"?"Mercancía con inventario":draft.inventoryPolicy==="not_required"?"Servicio sin inventario":"Tipo operativo pendiente"}</small></div><div className="product-catalog__edit-state"><Badge tone={editingReadiness?.posReady?"success":"warning"}>{editingReadiness?.posReady?"Configurado":`${editingReadiness?.blockers.length??0} pendientes`}</Badge>{draft.inventoryPolicy==="tracked"&&editingReadiness?.quantityOnHand!=null&&editingReadiness.quantityOnHand<=0&&<small>Sin existencia</small>}{editingReadiness?.price!=null&&<small>Precio final: {numberFormat(editingReadiness.price)} {editingReadiness.currencyCode??""}</small>}</div></div>:<p>Administra la identidad, inventario, impuestos y disponibilidad del producto canónico.</p>}{draft.sourceReference&&<small>Referencia importada: <strong>{draft.sourceReference}</strong></small>}</div>
        {draft.id&&catalogRole==="dish"&&editingReadiness&&!editingReadiness.posReady&&<section className="product-catalog__pending" aria-labelledby="product-edit-pending-title"><div><strong id="product-edit-pending-title">Completa lo necesario para vender</strong><p>{productReadinessSummary(editingReadiness.blockers)}</p></div><ul>{editingReadiness.blockers.map(blocker=><li key={blocker}><span aria-hidden="true">•</span>{productReadinessLabel(blocker)}</li>)}</ul>{editingReadiness.blockers.some(blocker=>["missing_tax_category","missing_current_tax_rate","not_sellable","inactive"].includes(blocker))&&<Button type="button" size="sm" variant="secondary" onClick={()=>document.querySelector<HTMLElement>(".product-catalog__commerce")?.scrollIntoView({behavior:"smooth",block:"start"})}>Revisar venta e impuestos</Button>}{editingReadiness.blockers.includes("missing_or_zero_price")&&<Button type="button" size="sm" variant="secondary" onClick={()=>document.querySelector<HTMLElement>(".product-catalog__dish-price")?.scrollIntoView({behavior:"smooth",block:"start"})}>Capturar precio</Button>}</section>}
        <div className="product-catalog__workspace">
          <section className="product-catalog__section product-catalog__identity"><header><h3>{experience === "restaurant" ? catalogRole === "preparation" ? "Datos de la base" : `Datos del ${catalogSingular}` : catalogInformationTitle}</h3><p>{experience === "restaurant" ? "La función culinaria ya está definida por este apartado." : "Datos para identificarlo y encontrarlo rápidamente."}</p></header><div className="product-catalog__form-grid">{experience === "restaurant" ? <><Field label={catalogNameLabel}><Input required maxLength={240} autoFocus={!draft.id} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder={catalogRole === "ingredient" ? "Ej. Tomate saladet" : catalogRole === "preparation" ? "Ej. Salsa verde" : "Ej. Enchiladas verdes"}/></Field><Field label="Categoría" hint="Elige una categoría existente o captura otra."><div className="product-catalog__field-control"><Select value={restaurantCategoryValue} onValueChange={value=>{if(value===RESTAURANT_OTHER_CATEGORY){setRestaurantCategoryIsOther(true);setOtherRestaurantCategory(draft.productGroup);}else{setRestaurantCategoryIsOther(false);setOtherRestaurantCategory("");setDraft({...draft,productGroup:value===RESTAURANT_NO_CATEGORY?"":value});}}} ariaLabel="Categoría culinaria" options={restaurantCategoryOptions}/>{restaurantCategoryValue===RESTAURANT_OTHER_CATEGORY&&<Input maxLength={160} value={otherRestaurantCategory} onChange={event=>{setOtherRestaurantCategory(event.target.value);setDraft({...draft,productGroup:event.target.value});}} placeholder="Ej. Extras"/>}</div></Field>{catalogRole !== "preparation" && <Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field>}{catalogRole !== "preparation" && <Field label={catalogRole === "dish" ? "Unidad de venta" : "Unidad de consumo"} hint={catalogRole === "dish" ? "Los platillos se venden por pieza." : "La unidad se usará para cantidades y costos de receta."}><Select value={draft.unit} onValueChange={selectRestaurantUnit} ariaLabel={catalogRole === "dish" ? "Unidad de venta" : "Unidad de consumo"} options={catalogRole === "dish" ? [{value:"piece",label:"Pieza"}] : restaurantUnitOptions}/></Field>}</> : <><Field label={catalogNameLabel}><Input required maxLength={240} autoFocus={!draft.id} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder="Ej. Cable eléctrico"/></Field><Field label="Unidad de inventario y venta" hint="Unidad usada para existencias y ventas, por ejemplo KG o PZA."><Input maxLength={80} value={draft.unit} onChange={event=>setDraft({...draft,unit:event.target.value.toUpperCase()})} placeholder="PZA"/></Field><Field label="Grupo" hint="Opcional."><Input maxLength={160} value={draft.productGroup} onChange={event=>setDraft({...draft,productGroup:event.target.value})} placeholder="Ej. Material eléctrico"/></Field><Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field></>}</div></section>

          <section className="product-catalog__section product-catalog__inventory">
            <header>
              <h3>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Compra e inventario" : catalogRole === "preparation" ? "Uso de la base" : "Receta y operación") : catalogRole === "preparation" ? "Uso culinario" : "Inventario y compra"}</h3>
              <p>{experience === "restaurant" ? (catalogRole === "ingredient" ? "Recibe el insumo en una presentación y consúmelo en la unidad base." : catalogRole === "preparation" ? "La cantidad producida se define al capturar la receta." : "El platillo no conserva inventario propio: su receta descuenta los componentes.") : catalogRole === "ingredient" ? "Define cómo se recibe y controla este insumo." : catalogRole === "preparation" ? "Una preparación se calcula desde sus insumos y puede reutilizarse en platillos." : "Actívalo sólo si este artículo mantiene existencia propia."}</p>
            </header>
            {experience === "restaurant" ? catalogRole === "ingredient" ? <>
              <div className="restaurant-fixed-role"><Badge tone="info">Insumo con inventario</Badge><p>Se compra, recibe y consume en recetas. No forma parte del menú ni se vende.</p></div>
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
            </> : <div className="restaurant-fixed-role"><Badge tone="info">{catalogRole === "preparation" ? "Base interna reutilizable" : "Venta por receta"}</Badge><p>{catalogRole === "preparation" ? "No se recibe ni se vende directamente. Su rendimiento, merma e insumos se capturan en la receta." : "La disponibilidad operativa se evalúa con la receta activa; no convierte el platillo en un insumo."}</p></div> : catalogRole === "preparation" ? <p className="product-catalog__readiness-note">No se vende ni se recibe por separado. Al vender un platillo, Satrapy expande la receta activa y descuenta sus insumos originales.</p> : <><Field label="Tipo operativo" hint="Mercancía exige existencias para vender; servicio no descuenta inventario."><Select value={draft.inventoryPolicy} onValueChange={value=>setDraft({...draft,inventoryPolicy:value as ProductDraft["inventoryPolicy"],lotControlled:value==="tracked"?draft.lotControlled:false})} ariaLabel="Tipo operativo" options={[{value:"unclassified",label:"Elige el tipo operativo"},{value:"tracked",label:"Mercancía con inventario"},{value:"not_required",label:"Servicio sin inventario"}]}/>{draft.inventoryPolicy==="unclassified"&&<span className="product-catalog__tax-selection" role="status">Indica cómo maneja inventario antes de venderlo.</span>}</Field><div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.lotControlled} disabled={draft.inventoryPolicy!=="tracked"} onChange={event=>setDraft({...draft,lotControlled:event.target.checked})}/> Solicitar lote y caducidad al recibir</label></div>{draft.inventoryPolicy==="tracked"&&<><strong>Compra y recepción</strong><div className="product-catalog__purchase-grid"><Field label="Unidad de compra"><Input maxLength={80} value={purchaseUnit.code} onChange={event=>setPurchaseUnit({...purchaseUnit,code:event.target.value.toUpperCase()})} placeholder={draft.unit||"CAJA"}/></Field><Field label="Unidades base por compra" hint={`${purchaseUnit.code.trim()||"Unidad de compra"} = ${purchaseUnit.factor||"1"} ${draft.unit||"unidad base"}. Ejemplo: 1 ROLLO = 1,000 M`}><Input inputMode="decimal" value={purchaseUnit.factor} onChange={event=>setPurchaseUnit({...purchaseUnit,factor:event.target.value})} placeholder="1"/></Field></div><p className="product-catalog__readiness-note">El lote y la caducidad se pedirán en cada recepción nueva; el historial no cambia.</p></>}</>}</section>

          {experience === "restaurant" && catalogRole !== "dish" ? <section className="product-catalog__section product-catalog__commerce"><header><h3>{catalogRole==="ingredient"?"Estado del insumo":"Estado de la base"}</h3><p>{catalogRole==="ingredient"?"Desactívalo cuando ya no deba comprarse ni agregarse a nuevas recetas.":"Actívala mientras forme parte de la operación culinaria."}</p></header><div className="product-catalog__checks"><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> {catalogRole==="ingredient"?"Insumo activo":"Base activa"}</label></div><p className="product-catalog__readiness-note">{catalogRole==="ingredient"?"Los insumos no se venden ni requieren configuración fiscal.":"Las bases no se venden; su rendimiento y costo provienen de la receta."}</p></section> : <section className="product-catalog__section product-catalog__commerce"><header><h3>{experience === "restaurant" ? "Venta del platillo" : "Impuestos y venta"}</h3><p>{experience === "restaurant" ? "Define el tratamiento fiscal del platillo que llega al comensal." : "Define el tratamiento fiscal y si puede ofrecerse comercialmente."}</p></header><Field label="Categoría fiscal" hint="La tasa vigente queda auditada."><Select value={draft.taxCategoryId} onValueChange={value=>setDraft(current=>current?{...current,taxCategoryId:value}:current)} ariaLabel="Categoría fiscal" options={[{value:"",label:"Sin categoría fiscal"},...taxCategories.map(category=>({value:category.id,label:`${category.code} · ${category.name}${category.rate!=null?` (${numberFormat(category.rate*100)}%)`:""}`}))]}/>{draft.taxCategoryId&&<span className="product-catalog__tax-selection" role="status">Categoría seleccionada.</span>}</Field><Button type="button" size="sm" variant="ghost" onClick={()=>setTaxEditorOpen(open=>!open)} aria-expanded={taxEditorOpen}>{taxEditorOpen?"Ocultar creación fiscal":"Crear categoría fiscal"}</Button>{taxEditorOpen&&<div className="product-catalog__tax-editor"><Field label="Código fiscal"><Input maxLength={40} value={taxDraft.code} onChange={event=>setTaxDraft({...taxDraft,code:event.target.value.toUpperCase()})} placeholder="IVA16"/></Field><Field label="Nombre fiscal"><Input maxLength={120} value={taxDraft.name} onChange={event=>setTaxDraft({...taxDraft,name:event.target.value})} placeholder="IVA 16%"/></Field><Field label="Tasa porcentual"><Input inputMode="decimal" value={taxDraft.rate} onChange={event=>setTaxDraft({...taxDraft,rate:event.target.value})} placeholder="16"/></Field><Field label="Motivo de alta"><Input maxLength={240} value={taxDraft.reason} onChange={event=>setTaxDraft({...taxDraft,reason:event.target.value})} placeholder="Ej. Alta de tratamiento fiscal"/></Field><Button type="button" variant="secondary" loading={savingTax} disabled={!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()} onClick={()=>void saveTaxCategory()}>Crear y seleccionar</Button></div>}<div className="product-catalog__checks product-catalog__checks--compact"><label><input type="checkbox" checked={draft.sellable} onChange={event=>setDraft({...draft,sellable:event.target.checked})}/> Disponible para venta</label><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> {catalogSingularTitle} activo</label></div><p className="product-catalog__readiness-note">La disponibilidad por sucursal se define por separado.</p>{draft.id&&catalogRole === "dish"&&canManageAssortments&&<Button type="button" variant="secondary" onClick={()=>{setCommercialReason(`Actualización de la comercialización del ${catalogSingular}`);setCommercialProduct({id:draft.id!,name:draft.name});setDraft(null);}}>Definir disponibilidad por sucursal</Button>}</section>}

          {draft.id&&canManageCosts&&costContext&&(experience!=="restaurant"||catalogRole==="ingredient")&&<section className="product-catalog__cost-capture product-catalog__section--wide"><header><div><strong>Valuación de inventario</strong><p>Captura manual para altas o correcciones puntuales. Para muchos insumos, usa la importación masiva de costos.</p></div><Badge tone={costContext.matrix_ready?"success":"warning"}>{costContext.matrix_ready?costMethodLabel(costContext.cost_method):"Costo por configurar"}</Badge></header>{costContext.matrix_ready?<><div className="product-catalog__cost-summary"><span>Costo vigente<strong>{costContext.current_cost?`${numberFormat(costContext.current_cost.amount)} ${costContext.currency_code}`:"Sin costo"}</strong></span><span>Moneda contable<strong>{costContext.currency_code}</strong></span></div><div className="product-catalog__cost-fields"><Field label="Nuevo costo vigente"><Input inputMode="decimal" value={costDraft.amount} onChange={event=>setCostDraft({...costDraft,amount:event.target.value})} placeholder="0.00"/></Field><Field label="Motivo obligatorio"><Input maxLength={240} value={costDraft.reason} onChange={event=>setCostDraft({...costDraft,reason:event.target.value})} placeholder="Ej. Alta inicial para valuación"/></Field><Button type="button" variant="secondary" loading={savingCost} disabled={!costDraft.reason.trim()||!(Number(costDraft.amount.replace(",","."))>0)} onClick={()=>void saveCurrentCost()}>Guardar costo</Button></div></>:<section className="product-catalog__cost-warning" aria-labelledby="cost-setup-title"><strong id="cost-setup-title">Antes de registrar costos, configura la política de costos.</strong><p>Satrapy necesita saber qué método usará y qué cuentas contables afectará cada operación nueva.</p><ol><li>Elige el método de costo.</li><li>Vincula las cuentas de compras, inventario y costo de ventas.</li><li>Activa la política para esta empresa.</li></ol>{canConfigureCostPolicy?<Link className="ui-button ui-button--secondary ui-button--sm" href="/satrapy/contabilidad/eventos">Configurar política de costos</Link>:<p className="product-catalog__cost-access">Pide a la persona que administra Contabilidad que active la política de costos. Cuando quede lista, podrás capturar el costo aquí.</p>}</section>}</section>}
          {experience==="restaurant"&&catalogRole==="dish"&&<section className="product-catalog__dish-price product-catalog__section--wide" aria-labelledby="dish-price-title"><header><div><h3 id="dish-price-title">Precio de venta</h3><p>Captura el precio final que pagará el comensal y elige la lista donde se aplicará.</p></div>{dishPriceLoading&&<span role="status">Cargando precio…</span>}</header>{canManagePrices?dishPriceLists.length?<><div className="product-catalog__dish-price-fields"><Field label="Lista de precios"><Select ariaLabel="Lista de precios del platillo" value={dishPriceListId} onValueChange={value=>{setDishPriceListId(value);if(draft.id)void loadDishPriceForList(draft.id,draft.internalSku,value);else setDishFinalPrice("");}} options={dishPriceLists.map(list=>({value:list.id,label:`${list.name} · ${list.currency_code}${list.is_default?" · Predeterminada":""}`}))}/></Field><Field label={`Precio final (${selectedDishPriceList?.currency_code??"MXN"})`} hint="Incluye el impuesto seleccionado."><Input type="number" min="0.01" step="0.01" inputMode="decimal" value={dishFinalPrice} onChange={event=>setDishFinalPrice(event.target.value)} disabled={selectedDishTax?.rate==null} aria-describedby={selectedDishTax?.rate==null?"dish-price-tax-help":undefined}/></Field></div>{selectedDishTax?.rate==null?<p id="dish-price-tax-help" className="product-catalog__inline-help" role="status">Selecciona primero una categoría fiscal con tasa vigente.</p>:parsedDishFinalPrice>0&&<div className="product-catalog__price-breakdown" aria-label="Desglose del precio"><span>Sin IVA<strong>{moneyFormat(dishBasePrice,selectedDishPriceList?.currency_code)}</strong></span><span>IVA {numberFormat(selectedDishTax.rate*100)}%<strong>{moneyFormat(dishTaxAmount,selectedDishPriceList?.currency_code)}</strong></span><span>Precio final<strong>{moneyFormat(parsedDishFinalPrice,selectedDishPriceList?.currency_code)}</strong></span></div>}</>:<div className="product-catalog__inline-empty"><div><strong>Aún no hay una lista de precios</strong><p>Crea una lista predeterminada para guardar este platillo sin salir del editor.</p></div><Button type="button" size="sm" variant="secondary" loading={savingDishPrice} onClick={()=>void createDefaultDishPriceList()}>Crear precio general</Button></div>:<p className="product-catalog__inline-help">Puedes consultar el platillo, pero tu perfil no permite cambiar precios.</p>}</section>}
          {experience==="restaurant"&&catalogRole==="dish"&&draft.id&&<section className="product-catalog__dish-completion product-catalog__section--wide" aria-labelledby="dish-completion-title"><header><div><h3 id="dish-completion-title">Receta, rentabilidad y disponibilidad</h3><p>Completa el platillo desde aquí. Cada editor regresa a este mismo formulario.</p></div><Badge tone={editingReadiness?.posReady?"success":"warning"}>{editingReadiness?.posReady?"Listo para vender":"Configuración pendiente"}</Badge></header><div className="product-catalog__dish-summary" aria-live="polite"><span>Receta<strong>{dishRecipeContext?.active?"Activa":dishRecipeContext?.draft?"Borrador":"Sin receta"}</strong></span><span>Costo por porción<strong>{moneyFormat(dishCost,dishRecipeContext?.currency_code??selectedDishPriceList?.currency_code)}</strong></span><span>Margen estimado<strong>{moneyFormat(dishMargin,selectedDishPriceList?.currency_code)}</strong></span><span>Disponibilidad<strong>{editingReadiness?.blockers.includes("outside_assortment")?"Sin sucursales":"Configurada"}</strong></span></div><div className="product-catalog__dish-actions">{canManageRecipes&&<Button type="button" variant="secondary" onClick={()=>setRecipeProduct({id:draft.id!,name:draft.name,recipeKind:"dish"})}><ChefHat size={16} aria-hidden="true"/> Editar receta</Button>}{canManageAssortments&&<Button type="button" variant="secondary" onClick={()=>{setCommercialReason(`Actualización de la disponibilidad de ${draft.name}`);setCommercialProduct({id:draft.id!,name:draft.name});}}>Definir sucursales</Button>}</div>{dishRecipeVersion?.cost&&!dishRecipeVersion.cost.allowed&&<p className="product-catalog__inline-help">{dishRecipeVersion.cost.blockers?.[0]?.message??"Completa el costo de los insumos para calcular la rentabilidad."}</p>}</section>}
          {draft.id&&catalogRole === "preparation"&&canManageRecipes&&<section className="product-catalog__recipe-action product-catalog__section--wide"><div><strong>Receta por tanda</strong><p>Administra los insumos y el rendimiento desde un solo editor.</p></div><Button type="button" variant="secondary" onClick={()=>setRecipeProduct({id:draft.id!,name:draft.name,recipeKind:"preparation"})}><ChefHat size={16} aria-hidden="true"/> Editar receta</Button></section>}
          {canArchiveIngredient&&draft.id&&<section className="product-catalog__archive-action product-catalog__section--wide"><div><strong>Archivar insumo</strong><p>Lo quita del catálogo y de nuevas recetas. Sus movimientos e historial se conservan.</p></div><Button type="button" variant="danger" onClick={()=>void openArchive()}><Archive size={16} aria-hidden="true"/> Archivar insumo</Button></section>}
        </div>
        <label className="operation-reason product-catalog__reason">Motivo obligatorio<textarea required rows={2} value={draft.reason} onChange={event=>setDraft({...draft,reason:event.target.value})} placeholder={draft.id?"Ej. Actualización de información culinaria":experience!=="restaurant"?"Ej. Alta inicial del producto":catalogRole === "ingredient"?"Ej. Alta inicial de insumo":catalogRole === "preparation"?"Ej. Alta de salsa de la casa":"Ej. Alta inicial del platillo"}/></label><div className="product-catalog__form-actions"><Button type="button" variant="secondary" disabled={saving} onClick={()=>setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving} disabled={saving||draft.inventoryPolicy==="unclassified"}>{draft.id?"Guardar cambios":experience==="restaurant"?(catalogRole === "ingredient"?"Crear insumo":catalogRole === "preparation"?"Crear base y armar receta":"Crear platillo y armar receta"): `Crear ${words.singular}`}</Button></div>
      </form>)}
    </Drawer>
    <RestaurantCatalogImportModal companyId={companyId} role="ingredient" open={importOpen} onOpenChange={setImportOpen} onImported={refresh}/>
    <ProductCreationWizard companyId={companyId} open={creationOpen} taxCategories={taxCategories} onOpenChange={setCreationOpen} onCreated={refresh}/>
    <ProductCommercializationModal companyId={companyId} product={commercialProduct} open={Boolean(commercialProduct)} initialReason={commercialReason} experience={experience} onOpenChange={(open)=>{if(!open){setCommercialProduct(null);void refresh();}}} onSaved={refresh}/>
    <RecipeEditorModal companyId={companyId} product={recipeProduct} recipeKind={recipeProduct?.recipeKind??"dish"} open={Boolean(recipeProduct)} onCreateIngredient={()=>{setRecipeProduct(null);router.replace("/satrapy/inventario/productos?seccion=insumos");void openNew("ingredient");}} onOpenChange={open=>{if(!open){const closed=recipeProduct;setRecipeProduct(null);void refresh();if(closed&&draft?.id===closed.id)void loadDishCommercialContext(closed.id,draft.internalSku);}}}/>
    <Modal open={integrityReviewOpen} onOpenChange={setIntegrityReviewOpen} eyebrow="Revisión de catálogo" title="Configuraciones por corregir" description="Corrige aquí pocas configuraciones puntuales. Para un catálogo amplio, usa una corrección por lote que conserve la auditoría." footer={<Button variant="secondary" onClick={()=>setIntegrityReviewOpen(false)}>Cerrar revisión</Button>}>
      {integrityIssues.length?<div className="product-catalog__integrity-list">{integrityIssues.map(issue=><article key={`${issue.issue_code}:${issue.id}`}><div><Badge tone="warning">{issue.issue_code==="missing_culinary_role"?"Función pendiente":"Conversión pendiente"}</Badge><strong>{issue.name}</strong><p>{issue.message}</p>{issue.purchase_unit_code&&<small>Presentación actual: {issue.purchase_unit_code}{issue.base_unit_code?` · Unidad de consumo: ${restaurantUnitLabel(issue.base_unit_code)}`:""}</small>}</div><Button type="button" size="sm" variant="secondary" onClick={()=>{setIntegrityReviewOpen(false);void openEdit(issue);}}>Corregir registro</Button></article>)}</div>:<p className="product-catalog__readiness-note">No hay configuraciones pendientes en esta página. Actualiza la lista para revisar de nuevo.</p>}
    </Modal>
    <Modal open={Boolean(archiveTarget)} onOpenChange={open=>{if(!open&&!archiving){setArchiveTarget(null);setArchiveReason("");setArchiveError(null);}}} eyebrow="Acción irreversible en operación" title={archiveTarget?`Archivar ${archiveTarget.name}`:"Archivar insumo"} description="Se conservarán movimientos, costos y auditoría. Primero resuelve las dependencias activas que se muestran aquí." closeDisabled={archiving} footer={<><Button variant="secondary" disabled={archiving} onClick={()=>{setArchiveTarget(null);setArchiveReason("");setArchiveError(null);}}>Cancelar</Button>{!archiveBlocked&&<Button variant="danger" loading={archiving} onClick={()=>void archiveIngredient()}>Archivar insumo</Button>}</>}>
      {archiveTarget?.active_recipes.length ? <section className="product-catalog__archive-dependencies" aria-labelledby="archive-recipes-title"><div><strong id="archive-recipes-title">Recetas activas que usan este insumo</strong><p>Crea una nueva versión de cada receta, quita o reemplaza el insumo y actívala. La versión histórica se conserva.</p></div><ul>{archiveTarget.active_recipes.map(recipe=><li key={`${recipe.product_id}:${recipe.version_number}`}><span><strong>{recipe.product_name}</strong><small>{recipe.recipe_kind==="preparation"?"Base reutilizable":"Platillo"} · versión activa {recipe.version_number}</small></span>{canManageRecipes&&<Button type="button" size="sm" variant="secondary" onClick={()=>{setArchiveTarget(null);setArchiveReason("");setRecipeProduct({id:recipe.product_id,name:recipe.product_name,recipeKind:recipe.recipe_kind});}}>Abrir receta</Button>}</li>)}</ul></section> : null}
      {archiveTarget?.inventory_location_count ? <p className="product-catalog__archive-blocker" role="status">Hay existencias en {archiveTarget.inventory_location_count} {archiveTarget.inventory_location_count===1?"ubicación":"ubicaciones"}. Ajusta o agota el inventario antes de archivar.</p> : null}
      {archiveTarget?.open_purchase_order_count ? <p className="product-catalog__archive-blocker" role="status">Hay {archiveTarget.open_purchase_order_count} {archiveTarget.open_purchase_order_count===1?"orden de compra abierta":"órdenes de compra abiertas"}. Ciérralas o elimina el renglón antes de archivar.</p> : null}
      {!archiveBlocked&&<><label className="operation-reason">Motivo para archivar<textarea ref={archiveReasonInputRef} required rows={3} value={archiveReason} onChange={event=>{setArchiveReason(event.target.value);setArchiveError(null);}} placeholder="Ej. Insumo creado por error; no tiene movimientos" aria-invalid={archiveError?true:undefined} aria-describedby={archiveError?"archive-ingredient-error":undefined}/></label>{archiveError&&<p id="archive-ingredient-error" className="product-catalog__archive-error" role="alert">{archiveError}</p>}</>}
    </Modal>
  </div>;
}
