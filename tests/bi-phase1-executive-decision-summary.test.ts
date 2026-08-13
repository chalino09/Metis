import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/BiModule.tsx", "utf8");
const styles = readFileSync("app/globals.css", "utf8");
const migration = readFileSync("supabase/migrations/202608120002_bi_executive_decision_summary.sql", "utf8");
const pkg = JSON.parse(readFileSync("package.json", "utf8")) as { dependencies?: Record<string, string> };

test("Fase 1 prioriza señales, un KPI protagonista y máximo tres secundarios", () => {
  assert.match(ui, /buildExecutiveAttention/);
  assert.match(ui, /Reglas deterministas; no son alertas persistidas/);
  assert.match(ui, /const heroMetric=metrics\.find/);
  assert.match(ui, /\.slice\(0,3\)/);
  assert.match(ui, /Métricas secundarias/);
  assert.match(ui, /periodo equivalente anterior/);
});

test("la visualización principal usa Recharts y conserva una ruta de investigación accesible", () => {
  assert.ok(pkg.dependencies?.recharts);
  assert.match(ui, /from "recharts"/);
  assert.match(ui, /<LineChart/);
  assert.match(ui, /<BarChart/);
  assert.match(ui, /bi-trend-points/);
  assert.match(ui, /locationId:row\.location_id/);
});

test("el resumen operativo se deriva y limita server-side", () => {
  assert.match(migration, /bi_get_executive_charts_before_decision_summary/);
  assert.match(migration, /public\.can_access_location\(l\.id\)/);
  assert.match(migration, /limit 12/);
  assert.match(migration, /bi\.executive_operational_summary_queried/);
  assert.match(migration, /previous_value/);
  assert.match(migration, /share_percent/);
});

test("la nueva jerarquía reutiliza los tokens y mantiene superficies planas", () => {
  for (const selector of [".bi-executive-attention", ".bi-executive-kpis", ".bi-operational-summary", ".bi-recharts-tooltip"]) assert.match(styles, new RegExp(selector.replaceAll(".", "\\.")));
  assert.match(styles, /var\(--bi-border\)/);
  assert.match(styles, /font-variant-numeric:tabular-nums/);
});
