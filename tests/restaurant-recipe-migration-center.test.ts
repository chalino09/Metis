import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {reconcileRestaurantRecipeImport,type RestaurantRecipeImportSource} from "../app/lib/restaurant-recipe-import.ts";

const panel=readFileSync("app/components/RestaurantRecipeMigrationPanel.tsx","utf8");
const parser=readFileSync("app/lib/restaurant-recipe-import.ts","utf8");
const shell=readFileSync("app/components/SatrapyApp.tsx","utf8");
const sql=readFileSync("supabase/migrations/202608290001_restaurant_recipe_package_import.sql","utf8");

test("el Centro único muestra el importador de recetas solo en Restaurante",()=>{
  assert.match(shell,/prepareRestaurantRecipeImport\(companyId,file\)/);
  assert.doesNotMatch(panel,/type="file"/);
  assert.match(panel,/cargador único/);
});

test("el parser reconoce el formato por bloques y limita el volumen",()=>{
  assert.match(parser,/DETALLE RECETAS/);
  assert.match(parser,/rows\.length > 1000/);
  assert.match(parser,/recipes\.length !== 10/);
  assert.match(panel,/Se normalizan a la unidad base/);
});

test("Aceite 123 se fusiona con Aceite y no crea un duplicado",()=>{
  assert.match(parser,/"ACEITE 123": \{ name: "Aceite"/);
  const source:RestaurantRecipeImportSource={file_name:"recetas.xlsx",sheet_name:"DETALLE_RECETAS",blockers:[],warnings:[],recipes:[{
    source_name:"RECETA",name:"Receta",recipe_kind:"dish",yield_quantity:1,yield_unit_code:"piece",portion_count:1,source_total:42,calculated_total:42,source_row:4,blockers:[],warnings:[],components:[
      {source_name:"ACEITE 123",canonical_name:"Aceite",alias_reason:"marca",quantity:1,unit_code:"l",unit_cost:42,line_cost:42,source_row:4,warnings:[]},
    ],
  }]};
  const preview=reconcileRestaurantRecipeImport(source,[{id:"aceite",internal_sku:"ING-005",name:"Aceite",unit:"ml"}]);
  assert.equal(preview.counts.existing,1);
  assert.equal(preview.counts.create,0);
  assert.equal(preview.ingredients[0]?.existing_product?.id,"aceite");
});

test("la conciliación separa existentes, altas y decisiones bloqueantes",()=>{
  for(const text of ["Usar existente","Crear insumo","Revisar","Decisiones necesarias antes de importar"])assert.match(panel,new RegExp(text));
  assert.match(parser,/mezcla piezas con peso o volumen/);
});

test("las decisiones provisionales documentan chiles, pollo y lentejas",()=>{
  assert.match(parser,/1500 \/ 16/);
  assert.match(parser,/20 \/ 4/);
  assert.match(parser,/insumo independiente por kg/);
  assert.match(parser,/yield_quantity = 8/);
  assert.match(parser,/Lentejas guisadas/);
});

test("la confirmación usa una sola RPC transaccional e idempotente",()=>{
  assert.match(shell,/import_restaurant_recipe_package/);
  assert.match(sql,/restaurant_recipe_import_requests/);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/save_restaurant_catalog_item/);
  assert.match(sql,/save_culinary_recipe_draft/);
  assert.match(sql,/restaurant\.recipe_package_imported/);
});

test("los platillos se normalizan a una porción antes de importar",()=>{
  assert.match(parser,/componentInBaseUnits\(component,base\)\/divisor/);
  assert.match(parser,/recipe_kind==="dish"\?1:recipe\.yield_quantity/);
});
