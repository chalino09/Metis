import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607260002_bi_phase3_explorer.sql", "utf8");
const ui = readFileSync("app/components/BiModule.tsx", "utf8");
const audit = readFileSync("docs/bi-phase-3-domain-audit-20260726.md", "utf8");

test("el catálogo explícito conserva fórmula, unidad, fuente, granularidad y limitaciones", () => {
  assert.match(migration, /create or replace function public\.bi_get_metric_catalog/);
  for (const field of ["formula", "unit", "source", "grain", "dimensions", "kind", "visualizations", "drilldown", "limitations"]) {
    assert.match(migration, new RegExp(`'${field}'`));
  }
  for (const moduleName of ["Ventas", "Margen", "Caja", "CxC", "CxP", "Compras", "Inventario", "Bancos", "Contabilidad", "Nómina"]) {
    assert.match(migration, new RegExp(`'module','${moduleName}'`));
  }
});

test("margen y nómina monetaria aparecen bloqueados con evidencia, no con adaptadores", () => {
  assert.match(migration, /'code','gross_margin'[\s\S]*?'available',false/);
  assert.match(migration, /No existe costo reconocido por partida vendida y fecha/);
  assert.match(migration, /'code','payroll_accrued'[\s\S]*?'available',false/);
  assert.match(migration, /corridas no conservan moneda canónica/);
  assert.match(audit, /Tickets no se agrupan por producto/);
  assert.match(audit, /Bancos sólo se agrupa por cuenta financiera/);
});

test("compatibilidad, fórmulas y visualizaciones se validan server-side", () => {
  assert.match(migration, /Las métricas no comparten granularidad comprobada/);
  assert.match(migration, /Las métricas no comparten unidad/);
  assert.match(migration, /Línea y área requieren la dimensión periodo/);
  assert.match(migration, /Dispersión requiere exactamente dos métricas/);
  assert.match(migration, /sum\(si\.taxable_amount\)/);
  assert.match(migration, /count\(distinct s\.id\)/);
  assert.match(migration, /il\.line_subtotal-il\.invoice_discount_amount/);
  assert.match(migration, /bt\.direction='credit'then bt\.amount else -bt\.amount/);
});

test("empresa, ubicación, RLS lógico, auditoría y volumen permanecen server-side", () => {
  assert.match(migration, /public\.has_company_permission\(p_company_id,'view_bi'\)/);
  assert.match(migration, /l\.company_id=p_company_id and public\.can_access_location\(l\.id\)/);
  assert.match(migration, /public\.can_access_location\(s\.location_id\)/);
  assert.match(migration, /public\.can_access_location\(pr\.location_id\)/);
  assert.match(migration, /public\.can_access_location\(il\.location_id\)/);
  assert.match(migration, /least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
  assert.match(migration, /limit 120/);
  assert.match(migration, /'bi\.explorer_queried'/);
  assert.match(migration, /revoke all on function public\.bi_explorer_query/);
});

test("la UI usa el catálogo y RPC existentes sin descargar tablas operativas", () => {
  assert.match(ui, /\.rpc\("bi_get_metric_catalog"/);
  assert.match(ui, /\.rpc\("bi_explorer_query"/);
  assert.match(ui, /\.rpc\("bi_get_explorer_drilldown"/);
  assert.doesNotMatch(ui, /\.from\("(?:sales|sale_items|cash_movements|bank_transactions|inventory_ledger|payroll_periods)"\)/);
  assert.match(ui, /router\.replace\(`\/satrapy\/bi\/explorador\?\$\{query\.toString\(\)\}`\)/);
  for (const visualization of ["line", "bar", "area", "scatter"]) assert.match(ui, new RegExp(`${visualization}:`));
});
