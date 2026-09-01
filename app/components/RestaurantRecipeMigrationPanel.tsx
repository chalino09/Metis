"use client";

import {AlertTriangle} from "lucide-react";
import {Badge,Button} from "@/app/components/ui/primitives";
import {buildRestaurantRecipeImportPackage,parseRestaurantRecipeWorkbook,reconcileRestaurantRecipeImport,type RestaurantRecipeCatalogItem,type RestaurantRecipeImportPreview} from "@/app/lib/restaurant-recipe-import";
import {getSupabaseClient} from "@/app/lib/supabase";

type CatalogResponse={items?:RestaurantRecipeCatalogItem[];total?:number};

async function loadRestaurantIngredients(companyId:string){
  const items:RestaurantRecipeCatalogItem[]=[];let page=1;let total=0;
  do{
    const {data,error}=await getSupabaseClient().rpc("search_restaurant_catalog",{p_company_id:companyId,p_role:"ingredient",p_query:null,p_page:page,p_page_size:50,p_is_sellable:null});
    if(error)throw error;
    const result=(data??{}) as CatalogResponse;items.push(...(result.items??[]));total=Number(result.total??items.length);page+=1;
  }while(items.length<total&&page<=20);
  return items;
}

export async function prepareRestaurantRecipeImport(companyId:string,file:File){
  const source=await parseRestaurantRecipeWorkbook(await file.arrayBuffer(),file.name);
  if(!source.sheet_name)return null;
  return reconcileRestaurantRecipeImport(source,await loadRestaurantIngredients(companyId));
}

export function RestaurantRecipeMigrationPanel({preview,busy,error,canImport,onClear,onConfirm}:{preview:RestaurantRecipeImportPreview|null;busy:boolean;error:string|null;canImport:boolean;onClear:()=>void;onConfirm:()=>void}){
  return <section className="restaurant-recipe-migration" aria-labelledby="restaurant-recipe-migration-title">
    <header className="restaurant-recipe-migration__header"><div><span className="eyebrow">Restaurante</span><h2 id="restaurant-recipe-migration-title">Recetas e insumos necesarios</h2><p>El archivo se detectó desde el cargador único. Aquí sólo se revisa y confirma el resultado.</p></div>{preview&&<Button variant="secondary" size="sm" disabled={busy} onClick={onClear}>Quitar vista previa</Button>}</header>
    {error&&<p className="restaurant-recipe-migration__error" role="alert">{error}</p>}
    {preview&&<div className="restaurant-recipe-migration__preview">
      <div className="restaurant-recipe-migration__summary" aria-label="Resumen de la vista previa"><span><small>Recetas</small><strong>{preview.counts.recipes}</strong></span><span><small>Componentes</small><strong>{preview.counts.components}</strong></span><span className="is-existing"><small>Ya existen</small><strong>{preview.counts.existing}</strong></span><span className="is-new"><small>Por crear</small><strong>{preview.counts.create}</strong></span><span className={preview.counts.blocked?"is-blocked":"is-existing"}><small>Bloqueos</small><strong>{preview.counts.blocked}</strong></span></div>
      {(preview.blockers.length>0||preview.ingredients.some(item=>item.blockers.length>0))&&<section className="restaurant-recipe-migration__blockers" aria-labelledby="restaurant-recipe-blockers-title"><header><AlertTriangle size={18} aria-hidden="true"/><div><strong id="restaurant-recipe-blockers-title">Decisiones necesarias antes de importar</strong><p>Estos casos impiden confirmar el lote; no bloquean la revisión.</p></div></header><ul>{preview.blockers.map(blocker=><li key={blocker}>{blocker}</li>)}{preview.ingredients.flatMap(item=>item.blockers.map(blocker=><li key={`${item.canonical_name}:${blocker}`}><strong>{item.canonical_name}:</strong> {blocker}</li>))}</ul></section>}
      <section className="restaurant-recipe-migration__ingredients" aria-labelledby="restaurant-recipe-ingredients-title"><header><div><h3 id="restaurant-recipe-ingredients-title">Conciliación de insumos</h3><p>Las coincidencias reutilizan el registro canónico; nunca crean un duplicado por nombre o alias.</p></div><Badge tone={preview.counts.blocked?"warning":"success"}>{preview.ingredients.length} insumos canónicos</Badge></header><div className="table-wrap"><table><thead><tr><th>Insumo canónico</th><th>Nombres del Excel</th><th>Uso</th><th>Unidad propuesta</th><th>Decisión</th></tr></thead><tbody>{preview.ingredients.map(item=><tr key={item.canonical_name}><td><strong>{item.canonical_name}</strong>{item.existing_product&&<small>{item.existing_product.internal_sku}</small>}</td><td>{item.source_names.join(" · ")}{item.warnings[0]&&<small>{item.warnings[0]}</small>}</td><td>{item.usage_count} {item.usage_count===1?"línea":"líneas"}</td><td>{item.base_unit_code??"—"}{item.purchase_unit_code&&<small>Compra: {item.purchase_unit_code} · {item.base_units_per_purchase_unit} {item.base_unit_code}</small>}</td><td><Badge tone={item.status==="existing"?"success":item.status==="create"?"info":"warning"}>{item.status==="existing"?"Usar existente":item.status==="create"?"Crear insumo":"Revisar"}</Badge></td></tr>)}</tbody></table></div></section>
      <section className="restaurant-recipe-migration__recipes" aria-labelledby="restaurant-recipe-list-title"><header><div><h3 id="restaurant-recipe-list-title">{preview.counts.recipes} recetas detectadas</h3><p>Se normalizan a la unidad base y los platillos se guardan por porción. Los costos escritos sólo sirven como referencia.</p></div></header><div>{preview.recipes.map(recipe=><details key={`${recipe.source_row}:${recipe.name}`}><summary><span><strong>{recipe.name}</strong><small>{recipe.recipe_kind==="preparation"?`${recipe.yield_quantity?.toLocaleString("es-MX")} ml por tanda`:`${recipe.portion_count??"Sin"} porciones`} · {recipe.components.length} componentes</small></span><Badge tone={recipe.blockers.length?"warning":"neutral"}>{recipe.blockers.length?"Revisar":"Detectada"}</Badge></summary><ul>{recipe.components.map(component=><li key={`${component.source_row}:${component.source_name}`}><span>{component.canonical_name}</span><strong>{component.quantity.toLocaleString("es-MX")} {component.unit_code??"sin unidad"}</strong></li>)}</ul>{recipe.warnings.map(warning=><p key={warning} className="restaurant-recipe-migration__warning">{warning}</p>)}</details>)}</div></section>
      <footer className="restaurant-recipe-migration__footer"><div><strong>{preview.counts.blocked?"La vista previa sigue bloqueada.":"Lote listo para confirmar."}</strong><span>{preview.counts.blocked?"Resuelve las decisiones señaladas.":"La confirmación creará todo o no creará nada."}</span></div><Button variant="primary" loading={busy} disabled={!canImport||busy||Boolean(preview.counts.blocked)} onClick={onConfirm}>Confirmar {preview.counts.recipes} recetas</Button></footer>
    </div>}
  </section>;
}

export {buildRestaurantRecipeImportPackage};
