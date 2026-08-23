import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608200011_assortment_filtered_membership.sql", "utf8");
const view = readFileSync("app/components/CommercialAssortmentsView.tsx", "utf8");

test("la operación masiva se resuelve en servidor y queda auditada", () => {
  assert.match(migration, /set_sales_assortment_membership_by_filter/);
  assert.match(migration, /create temporary table if not exists assortment_filtered_products/);
  assert.match(migration, /audit_log/);
  assert.match(migration, /'reason', v_reason/);
  assert.doesNotMatch(migration, /inventory_balances|inventory_movements|product_prices/);
});

test("la interfaz distingue selección manual de todos los resultados", () => {
  assert.match(view, /set_sales_assortment_membership_by_filter/);
  assert.match(view, /Selección manual/);
  assert.match(view, /Todos los resultados del filtro/);
  assert.match(view, /Motivo obligatorio/);
});
