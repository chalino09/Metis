import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql=readFileSync("supabase/migrations/202608180002_restaurant_archive_ingredients.sql","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");

test("el archivo de insumos conserva el producto canónico y valida dependencias",()=>{
  assert.match(sql,/archive_restaurant_ingredient/);
  assert.match(sql,/product_experience_code='restaurant'/);
  assert.match(sql,/role='ingredient'/);
  assert.match(sql,/inventory_balances/);
  assert.match(sql,/culinary_recipe_versions/);
  assert.match(sql,/purchase_order_lines/);
  assert.match(sql,/set is_active=false/);
  assert.match(sql,/restaurant\.ingredient_archived/);
  assert.doesNotMatch(sql,/delete from public\.products/i);
});

test("la acción sólo se muestra para Insumos de Restaurante y requiere motivo",()=>{
  assert.match(catalog,/canArchiveIngredient/);
  assert.match(catalog,/Archivar insumo/);
  assert.match(catalog,/Motivo para archivar/);
  assert.match(catalog,/archive_restaurant_ingredient/);
  assert.match(catalog,/aria-invalid/);
});
