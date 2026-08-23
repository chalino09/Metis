import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("..", import.meta.url);
const read = (path: string) => readFile(new URL(path, root), "utf8");

test("Fase 2 define un contexto compartido y un recorrido semántico hasta evidencia", async () => {
  const source = await read("app/components/BiModule.tsx");
  assert.match(source, /export type BiInvestigationContext/);
  assert.match(source, /nextInvestigationDimension/);
  assert.match(source, /if\(metricCode===\"net_sales\"&&dimension===\"location\"\)return \"category\"/);
  assert.match(source, /if\(metricCode===\"net_sales\"&&dimension===\"category\"\)return \"product\"/);
  assert.match(source, /if\(metricCode===\"net_sales\"&&dimension===\"product\"\)return null/);
});

test("Fase 2 calcula contribuciones y reconciliación del lado servidor", async () => {
  const sql = await read("supabase/migrations/202608120004_bi_contextual_investigation.sql");
  assert.match(sql, /create or replace function public\.bi_get_metric_investigation/i);
  assert.match(sql, /public\.bi_explorer_query/);
  assert.match(sql, /100\.0\*\(coalesce\(current_value,0\)-coalesce\(previous_value,0\)\)\/v_change/);
  assert.match(sql, /'all_factors_change',v_change,'total_change',v_change/);
  assert.match(sql, /limit v_size offset \(v_page-1\)\*v_size/);
  assert.match(sql, /bi\.metric_investigation_queried/);
  assert.match(sql, /p_category_id uuid default null/);
});

test("el drawer presenta evidencia descriptiva, tabla y registros paginados", async () => {
  const source = await read("app/components/BiModule.tsx");
  assert.match(source, /Evidencia descriptiva: los factores muestran cómo se distribuye el cambio; no prueban causalidad/);
  assert.match(source, /ContributionChart/);
  assert.match(source, /Contribuciones al cambio de la métrica/);
  assert.match(source, /Registros que respaldan la métrica/);
  assert.match(source, /bi_get_drilldown_v2/);
  assert.match(source, /DataPagination page=\{investigation\.pagination\.page\}/);
});
