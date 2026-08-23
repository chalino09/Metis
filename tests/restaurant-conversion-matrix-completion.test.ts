import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202608200004_restaurant_conversion_matrix_completion.sql", "utf8");
const catalog = readFileSync("app/components/ProductCatalogView.tsx", "utf8");

test("la matriz cubre peso, volumen y piezas sin mezclar dimensiones", () => {
  assert.match(sql, /\('mg','g','kg'\)/);
  assert.match(sql, /\('ml','l'\)/);
  assert.match(sql, /v_purchase_dimension is distinct from v_base_dimension/);
  assert.match(sql, /v_code='BOTELLA' and v_base_dimension<>'volume'/);
  assert.match(sql, /v_code in \('SACO','BOLSA'\) and v_base_dimension<>'mass'/);
});

test("la interfaz ofrece únicamente presentaciones compatibles", () => {
  assert.match(catalog, /restaurantPurchasePresentationOptionsFor/);
  assert.match(catalog, /dimension==="mass"/);
  assert.match(catalog, /dimension==="volume"/);
  assert.match(catalog, /Contenido neto por presentación/);
  assert.match(catalog, /Escribe \$\{restaurantUnitQuantityPrompt/);
});

test("el saneamiento automático sólo toca conversiones demostrables", () => {
  assert.match(sql, /has_no_operational_history/);
  assert.match(sql, /purchase_order_lines/);
  assert.match(sql, /purchase_receipt_lines/);
  assert.match(sql, /inventory_ledger/);
  assert.match(sql, /inventory_balances/);
  assert.match(sql, /product\.purchase_unit_conversion_completed/);
});
