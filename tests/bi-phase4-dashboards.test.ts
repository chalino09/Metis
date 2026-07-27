import assert from"node:assert/strict";
import{readFileSync}from"node:fs";
import test from"node:test";
const sql=readFileSync("supabase/migrations/202607260003_bi_phase4_dashboards_exports.sql","utf8");
const ui=readFileSync("app/components/BiModule.tsx","utf8");
const route=readFileSync("app/api/bi/export/route.ts","utf8");
test("vistas versionadas guardan configuración y revalidan con el Explorador",()=>{
  assert.match(sql,/create table public\.bi_saved_views/);assert.match(sql,/create table public\.bi_saved_view_versions/);
  assert.match(sql,/public\.bi_explorer_query\(/);assert.match(sql,/bi_view_availability/);
  assert.match(sql,/owner_id=auth\.uid\(\)or\(visibility='company'/);assert.match(sql,/bi\.view_shared/);
});
test("tableros guardan layout transaccional y coordinan widgets",()=>{
  assert.match(sql,/create table public\.bi_dashboards/);assert.match(sql,/create table public\.bi_dashboard_widgets/);
  assert.match(sql,/jsonb_array_length\(p_widgets\)/);assert.match(sql,/revision<>p_expected_revision/);
  assert.match(sql,/Un tablero admite hasta 12 widgets/);assert.match(sql,/exception when others/);
  assert.match(ui,/bi_get_dashboard_snapshot/);assert.match(ui,/bi_save_dashboard_layout/);
});
test("permisos, RLS y auditoría están separados",()=>{
  for(const code of["view_bi_dashboards","manage_own_bi_views","share_bi_views","manage_bi_dashboards","export_bi_reports"])assert.match(sql,new RegExp(`'${code}'`));
  assert.match(sql,/enable row level security/);assert.match(sql,/bi\.view_created/);assert.match(sql,/bi\.view_duplicated/);assert.match(sql,/bi\.dashboard_layout_saved/);assert.match(sql,/bi\.export_completed/);
});
test("exportación reconstruye páginas desde servidor y limita volumen",()=>{
  assert.match(route,/bi_prepare_export/);assert.match(route,/bi_explorer_query/);assert.match(route,/PAGE_SIZE=100,MAX_ROWS=50_000/);
  assert.match(route,/for\(let page=2/);assert.match(route,/bi_finish_export/);
  assert.doesNotMatch(route,/body\.(?:rows|chart|items)/);
});
