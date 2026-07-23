"use client";

import { Plus, RefreshCw } from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Drawer, Field, Input, Select, useToast } from "@/app/components/ui/primitives";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { productReadinessSummary } from "@/app/lib/product-readiness";
import { getSupabaseClient } from "@/app/lib/supabase";

const PAGE_SIZE = 50;
type ProductListRow = { id:string; internal_sku:string; alpha_sku:string|null; name:string; attribute:string|null; barcode:string|null; unit:string|null; product_group:string|null; is_active:boolean; is_sellable:boolean; is_inventory_tracked:boolean; price:number|null; currency_code:string|null; pos_ready:boolean; blockers?:string[] };
type TaxCategory = { id:string; code:string; name:string; rate:number|null; is_active:boolean };
type ProductDraft = { id:string|null; internalSku:string; name:string; barcode:string; unit:string; productGroup:string; taxCategoryId:string; inventoryTracked:boolean; sellable:boolean; active:boolean; reason:string; updatedAt:string|null; sourceReference:string|null };
const emptyDraft = (): ProductDraft => ({ id:null, internalSku:"", name:"", barcode:"", unit:"", productGroup:"", taxCategoryId:"", inventoryTracked:true, sellable:true, active:true, reason:"", updatedAt:null, sourceReference:null });
function errorMessage(error:{message?:string}|null, fallback:string) { return error?.message?.replace(/^.*?error:\s*/i, "").trim() || fallback; }
function numberFormat(value:number) { return new Intl.NumberFormat("es-MX", { maximumFractionDigits:3 }).format(value); }

export function ProductCatalogView({ companyId, permissions }: { companyId:string; permissions:string[] }) {
  const canManage = permissions.includes("manage_products");
  const { queryCache } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const requestId = useRef(0);
  const [rows,setRows] = useState<ProductListRow[]>([]); const [loading,setLoading] = useState(true); const [error,setError] = useState<string|null>(null);
  const [search,setSearch] = useState(""); const [debouncedSearch,setDebouncedSearch] = useState(""); const [saleFilter,setSaleFilter] = useState("all"); const [page,setPage] = useState(1); const [total,setTotal] = useState(0);
  const [draft,setDraft] = useState<ProductDraft|null>(null); const [detailLoading,setDetailLoading] = useState(false); const [saving,setSaving] = useState(false);
  const [taxCategories,setTaxCategories] = useState<TaxCategory[]>([]); const [taxDraft,setTaxDraft] = useState<{code:string;name:string;rate:string;reason:string}>({code:"",name:"",rate:"16",reason:""}); const [savingTax,setSavingTax] = useState(false);

  useEffect(() => { const timer=window.setTimeout(() => { setDebouncedSearch(search.trim()); setPage(1); },280); return () => window.clearTimeout(timer); },[search]);
  const load = useCallback(async (force=false) => {
    const isSellable=saleFilter==="sellable"?true:saleFilter==="not_sellable"?false:null;
    const key=`products:${companyId}:${debouncedSearch}:${saleFilter}:${page}`;
    const cached=!force?queryCache.get<{rows:ProductListRow[];total:number}>(key):null;
    if(cached){setRows(cached.rows);setTotal(cached.total);setLoading(false);setError(null);return;}
    const current=++requestId.current; setLoading(true);setError(null);
    const {data,error:queryError}=await getSupabaseClient().rpc("search_products",{p_company_id:companyId,p_query:debouncedSearch||null,p_page:page,p_page_size:PAGE_SIZE,p_is_sellable:isSellable});
    if(current!==requestId.current)return;
    const result=data as {items?:ProductListRow[];total?:number}|null; const next={rows:result?.items??[],total:result?.total??0};
    queryCache.set(key,next);setRows(next.rows);setTotal(next.total);setError(queryError?"No se pudieron cargar los productos.":null);setLoading(false);
  },[companyId,debouncedSearch,page,queryCache,saleFilter]);
  useEffect(() => { void Promise.resolve().then(() => load()); },[load]);
  const loadTaxCategories = useCallback(async () => {
    const {data,error:taxError}=await getSupabaseClient().rpc("list_tax_categories_admin",{p_company_id:companyId});
    if(taxError){toast({title:"No se pudieron cargar las categorías fiscales",description:errorMessage(taxError,"Actualiza e intenta de nuevo."),tone:"error"});return;}
    setTaxCategories((data??[]) as TaxCategory[]);
  },[companyId,toast]);
  async function refresh(){queryCache.invalidate(`products:${companyId}:`);await load(true);}
  async function openEdit(row:ProductListRow){
    if(!canManage)return; setDetailLoading(true);
    const {data,error:detailError}=await getSupabaseClient().from("products").select("id, internal_sku, alpha_sku, name, barcode, unit, product_group, tax_category_id, is_inventory_tracked, is_sellable, is_active, updated_at").eq("company_id",companyId).eq("id",row.id).single();
    setDetailLoading(false);
    if(detailError||!data){toast({title:"No se pudo abrir el producto",description:errorMessage(detailError,"Actualiza la lista e intenta nuevamente."),tone:"error"});return;}
    await loadTaxCategories();
    setDraft({id:data.id,internalSku:data.internal_sku,name:data.name,barcode:data.barcode??"",unit:data.unit??"",productGroup:data.product_group??"",taxCategoryId:data.tax_category_id??"",inventoryTracked:data.is_inventory_tracked,sellable:data.is_sellable,active:data.is_active,reason:"",updatedAt:data.updated_at,sourceReference:data.alpha_sku});
  }
  async function openNew(){await loadTaxCategories();setDraft(emptyDraft());}
  async function saveTaxCategory(){
    if(!draft)return; const rate=Number(taxDraft.rate.replace(",","."));
    if(!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()||!Number.isFinite(rate)||rate<0||rate>100)return;
    const fingerprint=JSON.stringify(taxDraft);setSavingTax(true);
    const {data,error:taxError}=await getSupabaseClient().rpc("save_tax_category",{p_company_id:companyId,p_code:taxDraft.code.trim().toUpperCase(),p_name:taxDraft.name.trim(),p_rate:rate/100,p_reason:taxDraft.reason.trim(),p_client_request_id:idempotency.get("save-tax-category",fingerprint)});
    if(taxError)toast({title:"No se pudo guardar la categoría fiscal",description:errorMessage(taxError,"Verifica los datos e intenta nuevamente."),tone:"error"});
    else { const category=data as TaxCategory; idempotency.clear("save-tax-category"); await loadTaxCategories(); setDraft({...draft,taxCategoryId:category.id}); setTaxDraft({code:"",name:"",rate:"16",reason:""}); toast({title:"Categoría fiscal guardada",description:"Ya quedó seleccionada para este producto.",tone:"success"}); }
    setSavingTax(false);
  }
  async function saveProduct(event:FormEvent){
    event.preventDefault();if(!draft)return;
    const normalized={...draft,internalSku:draft.internalSku.trim().toUpperCase(),name:draft.name.trim(),reason:draft.reason.trim()};
    if(!normalized.internalSku||!normalized.name||!normalized.reason)return;
    const fingerprint=JSON.stringify(normalized);setSaving(true);
    const {error:saveError}=await getSupabaseClient().rpc("save_product",{p_company_id:companyId,p_product_id:normalized.id,p_internal_sku:normalized.internalSku,p_name:normalized.name,p_barcode:normalized.barcode.trim()||null,p_unit:normalized.unit.trim()||null,p_product_group:normalized.productGroup.trim()||null,p_is_inventory_tracked:normalized.inventoryTracked,p_is_sellable:normalized.sellable,p_is_active:normalized.active,p_tax_category_id:normalized.taxCategoryId||null,p_reason:normalized.reason,p_expected_updated_at:normalized.updatedAt,p_client_request_id:idempotency.get("save-product",fingerprint)});
    if(saveError)toast({title:"No se pudo guardar el producto",description:errorMessage(saveError,"Verifica los datos e intenta nuevamente."),tone:"error"});
    else{idempotency.clear("save-product");setDraft(null);setPage(1);await refresh();toast({title:normalized.id?"Producto actualizado":"Producto creado",description:"El cambio quedó registrado en auditoría.",tone:"success"});}
    setSaving(false);
  }
  function clearFilters(){setSearch("");setDebouncedSearch("");setSaleFilter("all");setPage(1);}
  const canSave=Boolean(draft?.internalSku.trim()&&draft.name.trim()&&draft.reason.trim());
  return <div className="content-frame product-catalog">
    <PageHeading eyebrow="Catálogo administrable" title="Productos" description="Crea y mantiene productos canónicos de Satrapy. La importación acelera cargas grandes, pero no es necesaria para operar." action={<div className="product-catalog__heading-actions"><Button variant="secondary" onClick={() => void refresh()}><RefreshCw size={16}/> Actualizar</Button>{canManage&&<Button variant="primary" onClick={() => void openNew()}><Plus size={16}/> Nuevo producto</Button>}</div>}/>
    <p className="product-catalog__volume-note"><strong>Captura individual:</strong> úsala para pocos productos o correcciones puntuales. Para catálogos extensos, conserva la importación masiva.</p>
    <DataToolbar search={search} onSearchChange={setSearch} placeholder="Buscar código Satrapy, código de barras, alias o nombre" filters={<Select value={saleFilter} onValueChange={value=>{setSaleFilter(value);setPage(1);}} ariaLabel="Filtrar por disponibilidad de venta" options={[{value:"all",label:"Todos los productos"},{value:"sellable",label:"Vendibles"},{value:"not_sellable",label:"No vendibles"}]}/>} activeFilters={(search.trim()?1:0)+(saleFilter!=="all"?1:0)} onClear={clearFilters} results={total}/>
    <DataRefreshStatus loading={loading} hasData={rows.length}/>{detailLoading&&<div className="inline-status" role="status">Abriendo producto…</div>}
    <DataState loading={loading&&rows.length===0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={() => void refresh()}>Reintentar</Button>} hasData={rows.length} emptyTitle={search||saleFilter!=="all"?"Sin coincidencias":"Tu catálogo está listo para comenzar"} empty={search||saleFilter!=="all"?"No hay productos que coincidan con estos criterios.":"Crea el primer producto desde cero o importa un catálogo para acelerar la carga."} emptyAction={canManage&&!search&&saleFilter==="all"?<Button size="sm" variant="primary" onClick={openNew}><Plus size={15}/> Crear primer producto</Button>:undefined}>
      <div className="table-wrap surface-table"><table><thead><tr><th>Código Satrapy</th><th>Producto</th><th>Unidad</th><th>Grupo</th><th>Estado</th><th>Venta</th><th>POS</th><th>Diagnóstico</th><th className="number-cell">Precio</th></tr></thead><tbody>{rows.map(row=><InteractiveTableRow key={row.id} disabled={!canManage} className={canManage?"product-catalog__row":undefined} label={`Editar producto ${row.name}`} onActivate={() => void openEdit(row)}><td className="mono"><strong>{row.internal_sku}</strong>{row.alpha_sku&&<small>Origen: {row.alpha_sku}</small>}</td><td><strong>{row.name}</strong>{row.attribute&&<small>{row.attribute}</small>}</td><td>{row.unit??"—"}</td><td>{row.product_group??"—"}</td><td><Badge tone={row.is_active?"success":"neutral"}>{row.is_active?"Activo":"Inactivo"}</Badge></td><td><Badge tone={row.is_sellable?"success":"neutral"}>{row.is_sellable?"Vendible":"No vendible"}</Badge></td><td><Badge tone={row.pos_ready?"success":"warning"}>{row.pos_ready?"Listo":"Pendiente"}</Badge></td><td><small>{row.pos_ready?"Sin bloqueos":productReadinessSummary(row.blockers)==="Sin bloqueos"?"Requiere configuración comercial":productReadinessSummary(row.blockers)}</small></td><td className="number-cell">{row.price!=null?`${numberFormat(row.price)} ${row.currency_code??""}`:"—"}</td></InteractiveTableRow>)}</tbody></table></div>
    </DataState><DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} label="productos"/>
    <Drawer open={Boolean(draft)} onOpenChange={open=>{if(!open&&!saving)setDraft(null);}} title={draft?.id?"Editar producto":"Nuevo producto"} className="product-catalog__drawer">
      {draft&&<form className="product-catalog__form" onSubmit={saveProduct}><p className="settings-drawer-intro">Este formulario crea o actualiza la misma entidad canónica que alimentan las importaciones. No altera precios ni existencias.</p>{draft.sourceReference&&<p className="product-catalog__source">Referencia importada conservada: <strong>{draft.sourceReference}</strong></p>}
      <div className="product-catalog__form-grid"><Field label="Código Satrapy" hint="Identidad canónica; se guarda en mayúsculas."><Input required maxLength={80} autoFocus={!draft.id} value={draft.internalSku} onChange={event=>setDraft({...draft,internalSku:event.target.value.toUpperCase()})} placeholder="PROD-001"/></Field><Field label="Código de barras" hint="Opcional y único dentro de la empresa."><Input maxLength={80} value={draft.barcode} onChange={event=>setDraft({...draft,barcode:event.target.value})}/></Field><Field label="Nombre"><Input required maxLength={240} value={draft.name} onChange={event=>setDraft({...draft,name:event.target.value})} placeholder="Nombre comercial"/></Field><Field label="Unidad" hint="Ej. PZA, KG o SERVICIO."><Input maxLength={80} value={draft.unit} onChange={event=>setDraft({...draft,unit:event.target.value.toUpperCase()})}/></Field><Field label="Grupo" hint="Clasificación operativa opcional."><Input maxLength={160} value={draft.productGroup} onChange={event=>setDraft({...draft,productGroup:event.target.value})}/></Field><Field label="Categoría fiscal" hint="Se reutiliza entre productos; la tasa vigente queda auditada."><Select value={draft.taxCategoryId} onValueChange={value=>setDraft({...draft,taxCategoryId:value})} ariaLabel="Categoría fiscal" options={[{value:"",label:"Sin categoría fiscal"},...taxCategories.map(category=>({value:category.id,label:`${category.code} · ${category.name}${category.rate!=null?` (${numberFormat(category.rate*100)}%)`:""}`}))]}/></Field></div>
        <section className="product-catalog__tax-capture"><div><strong>Nueva categoría fiscal</strong><p>Para pocos tratamientos reutilizables. Para asignar una categoría ya existente a muchos productos, usa la operación masiva.</p></div><div className="product-catalog__tax-fields"><Input maxLength={40} value={taxDraft.code} onChange={event=>setTaxDraft({...taxDraft,code:event.target.value.toUpperCase()})} placeholder="IVA16" aria-label="Código fiscal"/><Input maxLength={120} value={taxDraft.name} onChange={event=>setTaxDraft({...taxDraft,name:event.target.value})} placeholder="IVA 16%" aria-label="Nombre fiscal"/><Input inputMode="decimal" value={taxDraft.rate} onChange={event=>setTaxDraft({...taxDraft,rate:event.target.value})} placeholder="16" aria-label="Tasa porcentual"/><Input maxLength={240} value={taxDraft.reason} onChange={event=>setTaxDraft({...taxDraft,reason:event.target.value})} placeholder="Motivo de alta" aria-label="Motivo de categoría fiscal"/><Button type="button" variant="secondary" loading={savingTax} disabled={!taxDraft.code.trim()||!taxDraft.name.trim()||!taxDraft.reason.trim()} onClick={()=>void saveTaxCategory()}>Guardar categoría</Button></div></section>
        <div className="product-catalog__checks"><label><input type="checkbox" checked={draft.inventoryTracked} onChange={event=>setDraft({...draft,inventoryTracked:event.target.checked})}/> Controla existencias</label><label><input type="checkbox" checked={draft.sellable} onChange={event=>setDraft({...draft,sellable:event.target.checked})}/> Pertenece al catálogo vendible</label><label><input type="checkbox" checked={draft.active} onChange={event=>setDraft({...draft,active:event.target.checked})}/> Producto activo</label></div>
        <p className="product-catalog__readiness-note">Marcarlo como vendible no garantiza que esté listo para POS: unidad, impuestos, precio y existencias se validan por separado.</p><label className="operation-reason">Motivo obligatorio<textarea required rows={3} value={draft.reason} onChange={event=>setDraft({...draft,reason:event.target.value})} placeholder={draft.id?"Ej. Actualización de información comercial":"Ej. Alta inicial del catálogo"}/></label><div className="product-catalog__form-actions"><Button variant="secondary" disabled={saving} onClick={()=>setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving} disabled={!canSave}>{draft.id?"Guardar cambios":"Crear producto"}</Button></div>
      </form>}
    </Drawer>
  </div>;
}
