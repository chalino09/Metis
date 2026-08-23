import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
const sql=readFileSync("supabase/migrations/202608170004_restaurant_phase1_recipe_authoring.sql","utf8");
const ui=readFileSync("app/components/RecipeEditorModal.tsx","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");
const css=readFileSync("app/globals.css","utf8");
test("la receta completa se guarda en una RPC transaccional e idempotente",()=>{assert.match(sql,/save_culinary_recipe_draft/);assert.match(sql,/jsonb_to_recordset\(p_components\)/);assert.match(sql,/culinary_recipe_requests/);});
test("la búsqueda de ingredientes es server-side y paginada",()=>{assert.match(sql,/search_culinary_components/);assert.match(sql,/limit v_size offset/);});
test("el catálogo separa platillos, insumos y preparaciones sin duplicar products",()=>{const catalogSql=readFileSync("supabase/migrations/202608170007_restaurant_phase1_preparations_catalog.sql","utf8");assert.match(catalogSql,/p_role not in \('dish','ingredient','preparation'\)/);assert.match(catalogSql,/p_role='dish' and \(is_dish/);assert.match(catalogSql,/p_role='ingredient' and is_inventory_tracked/);assert.match(catalogSql,/p_role='preparation' and is_preparation/);assert.match(catalog,/search_restaurant_catalog/);assert.match(catalog,/seccion=insumos/);assert.match(catalog,/seccion=preparaciones/);});
test("la carga inicial procesa un lote transaccional en servidor",()=>{assert.match(sql,/import_culinary_recipe_batch/);assert.match(sql,/jsonb_array_length\(p_rows\)>500/);assert.match(sql,/culinary_recipe\.batch_imported/);});
test("la interfaz conserva versiones mediante borrador, activación, costo y margen",()=>{for(const text of ["Guardar borrador","Activar receta","Costo por porción","Margen estimado","La receta activa no cambia"])assert.match(ui,new RegExp(text));assert.match(ui,/p_recipe_kind:recipeKind/);assert.match(ui,/p_duplicate_from_version_id:context\?\.active\?\.id\?\?null/);});
test("los controles principales tienen etiquetas y errores anunciables",()=>{assert.match(ui,/htmlFor={searchId}/);assert.match(ui,/aria-invalid={Boolean\(currentError\)\|\|undefined}/);assert.match(ui,/aria-describedby={currentError\?errorId:undefined}/);assert.match(ui,/aria-label={`Quitar \${line\.productName}`}/);});
test("el platillo usa una receta directa por porción y la base separa su rendimiento",()=>{for(const text of ["Receta por porción","Buscar insumo o base","¿Qué lleva una tanda?","Continuar al rendimiento","Ajuste opcional de merma","Volver a componentes"])assert.match(ui,new RegExp(text));assert.match(ui,/type EditorStep = "components"\|"yield"/);assert.match(ui,/recipeKind==="dish"\?\{yield:1,yieldUnit:"piece",portions:1\}/);});

test("el selector de insumos se superpone sin desplazar el contenido de la receta",()=>{
  assert.match(css,/\.recipe-editor__component-search \{ position:relative;/);
  assert.match(css,/\.recipe-editor__results \{ position:absolute;[^}]*top:calc\(100% \+ 6px\)/);
});
test("la navegación prioriza menú e insumos y presenta las bases como opcionales",()=>{for(const text of ["Menú","Platillos y receta por porción","Insumos","Bases reutilizables","Opcional"])assert.match(catalog,new RegExp(text));assert.match(catalog,/restaurant-catalog-tabs__primary/);assert.match(catalog,/restaurant-catalog-tabs__secondary/);});
test("los platillos nuevos no duplican inventario del núcleo",()=>{assert.match(catalog,/inventoryPolicy:experience==="restaurant"&&role!=="ingredient"\?"not_required":"tracked"/);});
