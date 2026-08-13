import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(new URL("supabase/migrations/202608130004_bi_cost_correction_ledger.sql", root), "utf8");
const moduleSource = await readFile(new URL("app/components/BiModule.tsx", root), "utf8");

test("la corrección histórica es autorizada, set-based y auditable", () => {
  assert.match(migration, /has_company_permission\(p_company_id,'import_costs'\)/);
  assert.match(migration, /has_company_permission\(p_company_id,'manage_bi_alerts'\)/);
  assert.match(migration, /insert into public\.sale_item_cost_correction_lines/);
  assert.match(migration, /item\.recognized_cost_amount is null/);
  assert.match(migration, /sale_item_cost_corrections/);
  assert.match(migration, /bi\.missing_sale_cost_corrected/);
  assert.match(migration, /bi_evaluate_company_alerts/);
});

test("la corrección no altera el costo vigente y contempla ambos periodos", () => {
  assert.doesNotMatch(migration, /update public\.sale_items/);
  assert.doesNotMatch(migration, /insert into public\.product_costs/);
  assert.match(moduleSource, /period_scope:"current"\|"comparison"/);
  assert.match(moduleSource, /alert\.comparison_from&&alert\.comparison_to/);
  assert.match(moduleSource, /No modifica ventas, cantidades, costos vigentes ni partidas ya valorizadas/);
  assert.match(moduleSource, /Aplicar y reevaluar/);
});
