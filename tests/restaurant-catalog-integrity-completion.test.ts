import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202608200002_restaurant_catalog_integrity_completion.sql", "utf8");
const catalog = readFileSync("app/components/ProductCatalogView.tsx", "utf8");
const recipeEditor = readFileSync("app/components/RecipeEditorModal.tsx", "utf8");

test("las presentaciones variables requieren contenido confirmado y las métricas usan su equivalencia exacta", () => {
  assert.match(sql, /presentation_content_confirmed_at/);
  assert.match(sql, /v_purchase='kg' and v_base='g' then return 1000/);
  assert.match(sql, /v_purchase='l' and v_base='ml' then return 1000/);
  assert.match(sql, /restaurant_purchase_configuration_error/);
  assert.match(catalog, /Contenido neto por presentación/);
  assert.match(catalog, /Las presentaciones cambian según la unidad de consumo/);
});

test("la revisión encuentra configuraciones heredadas sin modificar su contenido automáticamente", () => {
  assert.match(sql, /list_restaurant_catalog_integrity_issues/);
  assert.match(sql, /presentation_content_unconfirmed/);
  assert.match(catalog, /Revisar configuraciones/);
  assert.match(catalog, /Para un catálogo amplio, usa una corrección por lote/);
});

test("el archivo expone la receta activa y permite corregir una nueva versión", () => {
  assert.match(sql, /get_restaurant_ingredient_archive_context/);
  assert.match(sql, /'active_recipes',v_active_recipes/);
  assert.match(sql, /'components'.*v_active/);
  assert.match(catalog, /Recetas activas que usan este insumo/);
  assert.match(catalog, /Abrir receta/);
  assert.match(recipeEditor, /next\.draft\?\?next\.active/);
  assert.match(recipeEditor, /Duplicar versión activa/);
});
