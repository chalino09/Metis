import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const components = readFileSync("app/components/ui/bi.tsx", "utf8");
const summary = readFileSync("app/components/BiModule.tsx", "utf8");
const styles = readFileSync("app/globals.css", "utf8");
const pkg = JSON.parse(readFileSync("package.json", "utf8")) as { dependencies?: Record<string, string> };
const contract = readFileSync("docs/bi-phase-0-visual-contract-20260812.md", "utf8");

test("Fase 0 expone una sola familia de componentes BI sobre primitives existentes", () => {
  for (const name of ["MetricCard", "MetricDelta", "AttentionItem", "BiFilterBar", "AnalyticsTable", "BiDrawer", "ChartContainer", "BiState"]) {
    assert.match(components, new RegExp(`export function ${name}`));
  }
  assert.match(components, /import \{ Table \} from "\.\/data"/);
  assert.match(components, /import \{ Drawer \} from "\.\/primitives"/);
  assert.match(contract, /No crea un tema, una paleta ni una librería paralela/);
});

test("los aliases BI conservan los tokens y significados semánticos de Satrapy", () => {
  assert.match(styles, /--bi-surface: var\(--surface\)/);
  assert.match(styles, /--bi-accent: var\(--accent\)/);
  assert.match(styles, /--bi-positive: var\(--success\)/);
  assert.match(styles, /--bi-caution: var\(--warning\)/);
  assert.match(styles, /--bi-critical: var\(--danger\)/);
  assert.match(styles, /\.bi-metric-card[^}]*box-shadow:none/);
});

test("el resumen adopta la base sin cambiar consultas; Recharts se incorpora sólo en Fase 1", () => {
  for (const name of ["MetricCard", "MetricDelta", "BiFilterBar", "ChartContainer", "BiDrawer", "AnalyticsTable", "BiState"]) {
    assert.match(summary, new RegExp(`<${name}`));
  }
  assert.match(summary, /\.rpc\("bi_get_executive_summary"/);
  assert.ok(pkg.dependencies?.recharts);
});

test("estados y cifras conservan accesibilidad y estabilidad visual", () => {
  assert.match(components, /kind === "error" \? \{ role: "alert"/);
  assert.match(components, /"aria-live": "polite"/);
  assert.match(styles, /\.bi-metric-card__value[^}]*font-variant-numeric:tabular-nums/);
  assert.match(styles, /\.bi-analytics-table td[^}]*height:var\(--bi-row-compact\)/);
});
