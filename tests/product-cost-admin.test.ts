import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607230018_product_cost_admin.sql", "utf8");
const products = readFileSync("app/components/ProductCatalogView.tsx", "utf8");

test("la corrección puntual reutiliza costos y la matriz contable vigentes", () => {
  assert.doesNotMatch(migration, /create table/i);
  assert.match(migration, /accounting_event_rule_sets/);
  assert.match(migration, /accounting_config_versions/);
  assert.match(migration, /v_rule_set\.cost_method/);
  assert.match(migration, /base_currency/);
  assert.match(migration, /product_costs/);
});

test("la captura server-side valida permiso, concurrencia y motivo", () => {
  assert.match(migration, /has_company_permission\(p_company_id, 'import_costs'\)/);
  assert.match(migration, /p_amount <= 0/);
  assert.match(migration, /p_expected_cost_id/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /product\.cost_set/);
  assert.match(migration, /'reason', trim\(p_reason\)/);
});

test("el editor separa la corrección individual de la carga masiva", () => {
  assert.match(products, /Valuación de inventario/);
  assert.match(products, /correcciones puntuales/);
  assert.match(products, /importación masiva de costos/);
  assert.match(products, /get_product_cost_admin_context/);
  assert.match(products, /set_product_current_cost/);
});
