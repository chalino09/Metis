import assert from"node:assert/strict";
import{readFileSync}from"node:fs";
import test from"node:test";

const sql=readFileSync("supabase/migrations/202607260004_bi_phase5_budgets.sql","utf8");
const allocationsSql=readFileSync("supabase/migrations/202607260005_bi_budget_period_allocations.sql","utf8");
const repairSql=readFileSync("supabase/migrations/202607270001_fix_bi_budget_period_end.sql","utf8");
const saveRpcSql=readFileSync("supabase/migrations/202607270002_bi_budget_save_single_rpc.sql","utf8");
const periodTriggerSql=readFileSync("supabase/migrations/202607270003_fix_bi_budget_period_trigger.sql","utf8");
const executiveSql=readFileSync("supabase/migrations/202607270005_bi_executive_budget_summary.sql","utf8");
const ui=readFileSync("app/components/BiBudgetsModule.tsx","utf8");
const shell=readFileSync("app/components/SatrapyApp.tsx","utf8");
const route=readFileSync("app/api/bi/budgets/import/route.ts","utf8");
const stageAll=readFileSync("app/api/imports/stage-all/route.ts","utf8");
const budgetImport=readFileSync("app/lib/bi-budget-import.ts","utf8");
const explorer=readFileSync("app/components/BiModule.tsx","utf8");

test("versiones, aprobación y sustitución son inmutables y auditadas",()=>{
  assert.match(sql,/create table public\.bi_budget_versions/);
  assert.match(sql,/status text not null default'draft'.*'approved','superseded'/s);
  assert.match(sql,/Una versión aprobada no puede modificarse destructivamente/);
  assert.match(sql,/replaces_version_id/);assert.match(sql,/bi\.budget_approved/);
  assert.match(sql,/El motivo de aprobación es obligatorio/);
  assert.match(ui,/Sustituir/);assert.match(ui,/Motivo obligatorio/);
});

test("jerarquía limita combinaciones y evita doble conteo",()=>{
  assert.match(sql,/scope_type in\(\s*'company','location','responsible','category','location_category','responsible_category'/);
  assert.match(sql,/p\.scope_type='company'and p_scope_type='location'/);
  assert.match(sql,/p\.scope_type='location'and p_scope_type in\('location_category','responsible'\)/);
  assert.match(sql,/budget_kind='independent'/);assert.match(sql,/pending_distribution/);assert.match(sql,/distribution_excess/);
  assert.match(sql,/No suma porcentajes ni mezcla presupuestos superiores con sus distribuciones/);
  assert.match(ui,/Asignado/);assert.match(ui,/Excedente/);assert.match(ui,/Pendiente/);
});

test("metas anuales y trimestrales se distribuyen por mes sin duplicar el presupuesto",()=>{
  assert.match(allocationsSql,/create table public\.bi_budget_monthly_allocations/);
  assert.match(allocationsSql,/unique\(version_id,month_start\)/);
  assert.match(allocationsSql,/abs\(allocation_total-p_value\)>0\.005/);
  assert.match(allocationsSql,/La distribución mensual debe cubrir cada mes y sumar exactamente la meta total/);
  assert.match(allocationsSql,/delete from public\.bi_budget_monthly_allocations/);
  assert.match(ui,/Distribución por mes/);assert.match(ui,/Distribuir por igual/);assert.match(ui,/Copiar anterior/);
  assert.match(ui,/Faltan \$\{amount\(difference/);
});

test("los cierres mensual, trimestral y anual usan aritmética de intervalos válida",()=>{
  for(const source of[sql,allocationsSql,repairSql,saveRpcSql,periodTriggerSql])assert.doesNotMatch(source,/interval'[0-9]+ (?:month|months|year)-1 day'/);
  assert.match(repairSql,/interval'1 year'-interval'1 day'/);
  assert.match(repairSql,/interval'3 months'-interval'1 day'/);
  assert.match(saveRpcSql,/create or replace function public\.bi_save_budget_draft/);
  assert.doesNotMatch(saveRpcSql,/bi_save_budget_draft_phase5/);
  assert.match(saveRpcSql,/notify pgrst,'reload schema'/);
  assert.match(periodTriggerSql,/create or replace function public\.bi_validate_budget_version/);
  assert.match(periodTriggerSql,/v_start\+interval'1 year'-interval'1 day'/);
  assert.match(periodTriggerSql,/create or replace function public\.bi_promote_budget_import/);
  assert.match(periodTriggerSql,/pg_get_functiondef\('public\.bi_validate_budget_version\(\)'::regprocedure\)/);
  assert.match(periodTriggerSql,/bi_budget_versions_validate/);
  assert.match(periodTriggerSql,/date'2026-12-31'/);
});

test("atribución comercial es explícita, canónica y sin backfill Alpha",()=>{
  assert.match(sql,/create table public\.collaborator_user_links/);
  assert.match(sql,/create table public\.sale_responsibilities/);
  assert.match(sql,/assign_sale_responsible/);assert.match(sql,/link_collaborator_user/);
  assert.match(sql,/bi\.sale_responsible_assigned/);
  assert.doesNotMatch(sql,/alpha_external_id.*sale_responsibilities|display_name.*insert into public\.sale_responsibilities/is);
});

test("resultado real reutiliza ventas canónicas y respeta cancelaciones",()=>{
  assert.match(sql,/create or replace function public\.bi_budget_actual/);
  assert.match(sql,/public\.sales s join public\.sale_items si/);
  assert.match(sql,/not exists\(select 1 from public\.sale_cancellations/);
  assert.match(sql,/sr\.collaborator_id=v\.collaborator_id/);
  assert.match(sql,/p\.category_id=v\.category_id/);
  assert.match(sql,/El catálogo BI no dispone aún de costo reconocido por partida vendida y fecha/);
  assert.match(sql,/bi_budget_drilldown/);assert.match(ui,/Ver operaciones que explican el resultado/);
});

test("el Resumen ejecutivo muestra una sola meta aplicable sin sumar porcentajes",()=>{
  assert.match(executiveSql,/create or replace function public\.bi_get_executive_budget_summary/);
  assert.match(executiveSql,/public\.bi_budget_actual/);
  assert.match(executiveSql,/public\.bi_can_view_budget_version/);
  assert.match(executiveSql,/public\.can_access_location/);
  assert.match(executiveSql,/budget_kind='independent'/);
  assert.match(executiveSql,/no se agregan para evitar doble conteo/i);
  assert.doesNotMatch(executiveSql,/sum\s*\([^)]*attainment|avg\s*\([^)]*attainment/i);
  assert.match(executiveSql,/bi\.executive_budget_summary_queried/);
  assert.match(explorer,/\.rpc\("bi_get_executive_budget_summary"/);
  for(const label of["Presupuesto contra resultado","Resultado acumulado","Cumplimiento","Pendiente","Proyección al cierre"])assert.match(explorer,new RegExp(label));
});

test("importación masiva usa staging paginado, promoción idempotente y códigos canónicos",()=>{
  assert.match(sql,/create table public\.bi_budget_import_batches/);assert.match(sql,/create table public\.bi_budget_import_rows/);
  assert.match(sql,/between 1 y 50,000|entre 1 y 50,000/);assert.match(sql,/status='promoted'.*idempotent.*true/s);
  assert.match(sql,/external_code=trim\(r->>'location_code'\)/);assert.match(sql,/code=trim\(r->>'responsible_code'\)/);assert.match(sql,/external_code=trim\(r->>'category_code'\)/);
  assert.match(budgetImport,/XLSX\.utils\.sheet_to_json/);assert.match(budgetImport,/createHash\("sha256"\)/);assert.match(budgetImport,/15\s*\*\s*1024\s*\*\s*1024/);
  assert.match(route,/plantilla_presupuestos_satrapy\.xlsx/);assert.match(route,/plantilla_presupuestos_satrapy\.csv/);
  assert.doesNotMatch(route,/from\("(?:locations|collaborators|product_categories)"\)/);
});

test("presupuestos reutiliza el único cargador del Centro de Migración",()=>{
  assert.doesNotMatch(ui,/Importar presupuestos|Importación masiva|BudgetImportWorkspace/);
  assert.doesNotMatch(shell,/BudgetImportWorkspace|id="metas-presupuestos"|Importar metas y presupuestos/);
  assert.equal((shell.match(/Subir archivos de origen/g)??[]).length,1);
  assert.equal((shell.match(/type="file"/g)??[]).length,1);
  assert.match(shell,/bi_budget_import_preview/);
  assert.match(shell,/bi_promote_budget_import/);
  assert.match(stageAll,/detectAndStageBudgetImport/);
  assert.match(stageAll,/kind:\s*"bi_budgets"/);
  assert.doesNotMatch(route,/export async function POST/);
  assert.match(shell,/import_bi_budgets/);
});

test("RLS separa empresa, ubicación, usuario y exportación heredada",()=>{
  for(const permission of["view_bi_budgets","create_bi_budget_drafts","import_bi_budgets","approve_bi_budgets","manage_bi_budget_distributions","view_team_bi_budgets"])assert.match(sql,new RegExp(`'${permission}'`));
  assert.match(sql,/public\.can_access_location\(v_effective_location\)/);
  assert.match(sql,/public\.bi_user_is_field_engineer/);assert.match(sql,/v\.collaborator_id=v_own/);
  assert.match(sql,/alter table public\.bi_budget_versions enable row level security/);
  assert.match(sql,/create policy bi_budget_versions_read/);
  assert.match(shell,/bi_budgets/);assert.match(shell,/\/satrapy\/bi\/metas-presupuestos/);
});

test("catálogo, Explorador, vistas, tableros y exportaciones conservan un solo motor",()=>{
  assert.match(sql,/rename to bi_get_metric_catalog_phase4/);
  assert.match(sql,/rename to bi_explorer_query_phase4/);
  assert.match(sql,/return public\.bi_explorer_query_phase4/);
  for(const suffix of["budget","actual","variance","projection","attainment"])assert.match(sql,new RegExp(`target\\|\\|'_'\\|\\|suffix|${suffix}`));
  assert.match(explorer,/BiBudgetsModule/);
  assert.doesNotMatch(sql,/create table public\.(?:bi_sales|bi_margin|bi_actual_results)/);
  assert.match(sql,/bi_budget_explorer_query/);
});

test("consultas operativas están paginadas y acotadas",()=>{
  assert.match(sql,/least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
  assert.match(sql,/limit v_size offset\(v_page-1\)\*v_size/);
  assert.match(sql,/jsonb_array_length\(p_rows\)>50000/);
  assert.match(budgetImport,/rows\.length\s*>\s*50_000/);
  assert.doesNotMatch(ui,/\.from\("(?:sales|sale_items|bi_budget_versions)"\)/);
});
