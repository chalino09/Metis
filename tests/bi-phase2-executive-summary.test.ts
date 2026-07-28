import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607260001_bi_phase2_executive_summary.sql", "utf8");
const ui = readFileSync("app/components/BiModule.tsx", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");

test("Fase 2 agrega series y comparaciones únicamente server-side", () => {
  assert.match(migration, /create or replace function public\.bi_get_executive_charts/);
  assert.match(migration, /v_days>366/);
  assert.match(migration, /generate_series\(0,v_days-1\)/);
  assert.match(migration, /public\.canonical_accounting_auxiliaries\(p_company_id,p_date_to\)/);
  assert.match(migration, /public\.canonical_accounting_auxiliaries\(p_company_id,v_previous_to\)/);
  assert.match(ui, /\.rpc\("bi_get_executive_charts"/);
  assert.doesNotMatch(ui, /\.from\("(?:sales|bank_transactions|customer_receivables|accounts_payable|inventory_ledger)"\)/);
});

test("empresa, ubicación, permiso y auditoría se validan dentro de las RPC", () => {
  assert.match(migration, /public\.has_company_permission\(p_company_id,'view_bi'\)/);
  assert.match(migration, /l\.company_id=p_company_id and public\.can_access_location\(l\.id\)/);
  assert.match(migration, /public\.can_access_location\(s\.location_id\)/);
  assert.match(migration, /public\.can_access_location\(il\.location_id\)/);
  assert.match(migration, /'bi\.executive_charts_queried'/);
  assert.match(migration, /'bi\.drilldown_v2_queried'/);
  assert.match(migration, /revoke all on function public\.bi_get_executive_charts/);
});

test("las seis visualizaciones conservan contrato y la UI admite el margen reconocido", () => {
  for (const code of ["sales", "gross_margin", "cash_flow", "receivables", "payables", "inventory"]) {
    assert.match(migration, new RegExp(`'code','${code}'`));
  }
  assert.match(migration, /No existe costo reconocido por partida vendida y fecha/);
  assert.match(ui, /costo reconocido congelado por partida/);
  assert.match(ui, /metric\("gross_margin"\)\?\.available/);
  assert.match(ui, /Datos parciales/);
  assert.match(ui, /No hay datos para los filtros seleccionados/);
});

test("cada punto conserva filtros y abre detalle paginado server-side", () => {
  assert.match(migration, /create or replace function public\.bi_get_drilldown_v2/);
  assert.match(migration, /least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
  assert.match(migration, /limit v_size offset\(v_page-1\)\*v_size/);
  assert.match(ui, /\.rpc\("bi_get_drilldown_v2"/);
  assert.match(ui, /p_as_of_date:request\.asOf/);
  assert.match(ui, /dateFrom:date,dateTo:date/);
});

test("periodo y ubicación se conservan al navegar dentro de BI", () => {
  assert.match(ui, /query\.set\("from",next\.dateFrom\)/);
  assert.match(ui, /query\.set\("to",next\.dateTo\)/);
  assert.match(ui, /query\.set\("location",next\.locationId\)/);
  assert.match(app, /activeSection\?\.id === "bi" \? `\$\{item\.href\}\$\{window\.location\.search\}`/);
});
