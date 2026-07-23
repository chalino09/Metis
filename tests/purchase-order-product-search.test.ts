import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607180011_fast_purchase_order_product_search.sql", "utf8");

test("la OC usa un selector ligero con protección contra respuestas atrasadas", () => {
  assert.match(ui, /search_purchase_order_products/);
  assert.match(ui, /productSearchRequest/);
  assert.match(ui, /},120\)/);
  assert.match(ui, /if\(error\).*search_products/);
});

test("el selector de OC no calcula información comercial innecesaria", () => {
  assert.match(migration, /product\.is_active/);
  assert.match(migration, /product\.is_inventory_tracked/);
  assert.match(migration, /limit v_limit/);
  assert.doesNotMatch(migration, /product_prices/);
  assert.doesNotMatch(migration, /tax_rates/);
  assert.doesNotMatch(migration, /count\(\*\)/);
  assert.doesNotMatch(migration, /blockers/);
});
