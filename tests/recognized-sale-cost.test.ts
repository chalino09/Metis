import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607280001_sale_item_recognized_cost.sql", "utf8");
const ui = readFileSync("app/components/BiModule.tsx", "utf8");

test("cada partida congela el costo reconocido en servidor", () => {
  for (const field of ["recognized_unit_cost", "recognized_cost_method", "recognized_cost_currency_code", "recognized_product_cost_id", "recognized_cost_amount"]) {
    assert.match(migration, new RegExp(field));
  }
  assert.match(migration, /create trigger sale_items_capture_recognized_cost/);
  assert.match(migration, /before insert on public\.sale_items/);
  assert.match(migration, /valid_from <= v_sale\.completed_at/);
  assert.match(migration, /valid_to is null or valid_to > v_sale\.completed_at/);
  assert.match(migration, /coalesce\(v_method, 'replacement_cost'\)/);
  assert.match(migration, /no se suplanta con costo actual ni cero/);
});

test("contabilidad y margen consumen el snapshot, no el costo vigente", () => {
  assert.match(migration, /sum\(si\.recognized_cost_amount\)/);
  assert.doesNotMatch(migration, /sum\(si\.quantity\*pc\.amount\)/);
  assert.match(migration, /sale_margin_coverage/);
  assert.match(migration, /missing_cost_item_count/);
  assert.match(migration, /El periodo actual o comparable contiene partidas sin costo reconocido/);
  assert.match(migration, /El resultado exige cobertura completa de costo reconocido/);
});

test("la interfaz muestra margen y explica la cobertura sin exponer costo unitario", () => {
  assert.match(ui, /gross_margin: "gross_margin"/);
  assert.match(ui, /costo reconocido congelado por partida/);
  assert.match(ui, /metric\.code === "inventory_value" \|\| metric\.code === "gross_margin"/);
  assert.doesNotMatch(ui, /recognized_unit_cost/);
});

test("el snapshot no queda expuesto en lecturas directas de ventas", () => {
  assert.match(migration, /revoke select on public\.sale_items from public,anon,authenticated/);
  const directReadGrant = migration.match(/grant select \(([\s\S]*?)\) on public\.sale_items to authenticated/);
  assert.ok(directReadGrant);
  assert.match(directReadGrant[1] ?? "", /total_amount,created_at/);
  assert.doesNotMatch(directReadGrant[1] ?? "", /recognized_/);
});
