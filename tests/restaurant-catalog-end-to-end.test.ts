import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {parseRestaurantCatalogFile} from "../app/lib/restaurant-catalog-import.ts";

const sql=readFileSync("supabase/migrations/202608220001_restaurant_catalog_end_to_end.sql","utf8");
const roleRepair=readFileSync("supabase/migrations/202608220002_restaurant_standard_category_role_repair.sql","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");
const editor=readFileSync("app/components/RecipeEditorModal.tsx","utf8");
const importer=readFileSync("app/components/RestaurantCatalogImportModal.tsx","utf8");
const parser=readFileSync("app/lib/restaurant-catalog-import.ts","utf8");

test("menú, insumos y bases usan listados específicos sin columnas comerciales heredadas",()=>{
  assert.match(catalog,/function RestaurantCatalogTable/);
  assert.match(catalog,/Unidad de consumo/);
  assert.match(catalog,/Presentación de compra/);
  assert.match(catalog,/Rendimiento por tanda/);
  assert.match(catalog,/Receta por porción/);
  assert.match(catalog,/catalogRole !== "dish"/);
  assert.match(catalog,/catalogRole !== "preparation" && <Field label=/);
  assert.match(parser,/role === "preparation" \? ""/);
  assert.doesNotMatch(catalog,/Habilitar venta excepcional/);
});

test("el servidor impide vender insumos y bases sin modificar surtidos",()=>{
  assert.match(sql,/role_data\.role in \('ingredient','preparation'\)/);
  assert.match(sql,/restaurant\.non_dish_commercial_fields_cleared/);
  assert.match(sql,/set is_sellable=false,tax_category_id=null/);
  assert.match(sql,/Sólo los platillos pueden habilitarse para venta en Restaurante/);
  assert.doesNotMatch(sql,/delete from public\.assortment/);
});

test("las recetas sólo aceptan insumos o bases activas y bloquean platillos",()=>{
  assert.match(sql,/role_data\.role in \('ingredient','preparation'\)/);
  assert.match(sql,/Una receta sólo puede contener insumos o bases reutilizables/);
  assert.match(sql,/Activa la receta de cada base antes de reutilizarla/);
  assert.match(editor,/Un platillo no puede formar parte de otra receta/);
  assert.match(editor,/Las bases aparecen cuando su receta está activa/);
  assert.match(roleRepair,/catalog_role',component_role\.role/);
  assert.match(roleRepair,/restaurant\.culinary_role_repaired_from_standard_category/);
});

test("el editor carga los insumos existentes antes de escribir",()=>{
  assert.match(editor,/p_query:trimmed\|\|null/);
  assert.doesNotMatch(editor,/if\(!open\|\|!trimmed\)return/);
  assert.match(editor,/Los insumos aparecen automáticamente/);
});

test("la carga masiva comparte el catálogo canónico y una transacción auditada",()=>{
  assert.match(sql,/import_restaurant_catalog_batch/);
  assert.match(sql,/jsonb_array_length\(p_rows\)>500/);
  assert.match(sql,/perform public\.save_restaurant_catalog_item/);
  assert.match(sql,/restaurant\.catalog_batch_imported/);
  assert.match(importer,/Se guardarán todos los registros o ninguno/);
  assert.match(parser,/plantilla_/);
  assert.match(parser,/csv\|xlsx/);
});

test("el alta manual y la importación explican qué falta después",()=>{
  assert.match(catalog,/Crear platillo y armar receta/);
  assert.match(catalog,/Crear base y armar receta/);
  assert.match(importer,/Las recetas se completan después, platillo por platillo/);
  assert.match(importer,/Completa las recetas pendientes desde el listado/);
});

test("el archivo aplica sólo los campos que corresponden a cada módulo",async()=>{
  const bases=await parseRestaurantCatalogFile(new File(["nombre,categoria\nSalsa roja,Salsas"],"bases.csv"),"preparation");
  assert.deepEqual(bases.errors,[]);
  assert.equal(bases.rows[0]?.unit,"");
  assert.equal(bases.rows[0]?.is_sellable,false);

  const ingredients=await parseRestaurantCatalogFile(new File(["nombre,unidad,presentacion_compra,contenido_por_presentacion\nJitomate,g,KG,1000"],"insumos.csv"),"ingredient");
  assert.deepEqual(ingredients.errors,[]);
  assert.equal(ingredients.rows[0]?.purchase_unit_code,"KG");
  assert.equal(ingredients.rows[0]?.base_units_per_purchase_unit,1000);

  const invalid=await parseRestaurantCatalogFile(new File(["nombre,unidad\nJitomate,g"],"insumos.csv"),"ingredient");
  assert.match(invalid.errors.join(" "),/presentación de compra/);
});
