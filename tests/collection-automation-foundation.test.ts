import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { ROLE_PREVIEW_PERMISSIONS } from "../app/lib/navigation-access.ts";

const migration=readFileSync("supabase/migrations/202608120003_collection_automation_foundation.sql","utf8");
const worker=readFileSync("scripts/collection-worker.ts","utf8");
const ui=readFileSync("app/components/CollectionAutomationModule.tsx","utf8");
const sales=readFileSync("app/components/SalesModule.tsx","utf8");
const app=readFileSync("app/components/SatrapyApp.tsx","utf8");
const plan=readFileSync("docs/planes/automatizacion-cobranza.md","utf8");

test("la automatización está restringida a roles autorizados",()=>{
  assert.ok(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("view_collection_automation"));
  for(const role of ["sucursal","ingeniero_campo","almacen","punto_venta"] as const) assert.equal(ROLE_PREVIEW_PERMISSIONS[role].includes("view_collection_automation"),false);
  assert.match(migration,/public\.has_company_permission\(p_company_id,'view_collection_automation'\)/);
});

test("la cola usa lease, SKIP LOCKED, backoff e idempotencia",()=>{
  assert.match(migration,/for update of t skip locked/);
  assert.match(migration,/lease_expires_at<=clock_timestamp\(\)/);
  assert.match(migration,/30\*power\(2,v_task\.attempt_count-1\)/);
  assert.match(migration,/unique\(company_id,idempotency_key\)/);
  assert.match(migration,/unique\(task_id,attempt\)/);
  assert.match(migration,/on conflict\(company_id,idempotency_key\) do nothing/);
});

test("una política incompleta bloquea generación y reclamación",()=>{
  assert.match(migration,/Automatización de cobranza no configurada/);
  assert.match(migration,/public\.collection_policy_is_complete\(p\)/);
  assert.match(migration,/p\.status='approved'/);
  assert.match(ui,/No configurada/);
  assert.match(migration,/collection_save_policy_draft/);assert.match(migration,/collection_approve_policy/);assert.match(migration,/collection\.policy_approved/);
});

test("el worker conserva tareas deterministas sin depender de proveedores",()=>{
  assert.match(worker,/collection_claim_tasks/);assert.match(worker,/internal_healthcheck/);assert.match(worker,/provider: null/);
  assert.doesNotMatch(worker,/twilio/i);assert.match(plan,/El flujo funciona sin OpenAI ni Twilio/);
});

test("la bandeja es paginada, semántica y no consulta tablas directamente",()=>{
  assert.match(ui,/collection_list_cases/);assert.match(ui,/DataPagination/);assert.match(ui,/<main/);assert.match(ui,/aria-labelledby/);
  assert.doesNotMatch(ui,/\.from\(/);
  assert.match(sales,/Vistas de cuentas por cobrar/);assert.match(ui,/Vistas de cuentas por cobrar/);
  assert.doesNotMatch(app,/views: \["pos", "sales_history", "sales_quotes", "sales_orders", "customers", "receivables", "collection_automation"/);
  assert.match(app,/const INTERNAL_VIEWS: ViewName\[\] = \["collection_automation"\]/);
  assert.match(app,/INTERNAL_VIEWS\.filter\(isAllowed\)/);
});
