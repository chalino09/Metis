import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root=new URL("..",import.meta.url);
const read=(path:string)=>readFile(new URL(path,root),"utf8");

test("Fase 4 persiste condiciones idempotentes, auditables y programadas",async()=>{
  const sql=await read("supabase/migrations/202608130002_bi_persistent_operational_alerts.sql");
  assert.match(sql,/create table public\.bi_alerts/);
  assert.match(sql,/create unique index[\s\S]*condition_key[\s\S]*where status in\('active','reviewed'\)/i);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/create or replace function public\.bi_evaluate_company_alerts/);
  assert.match(sql,/create or replace function public\.bi_transition_alert/);
  assert.match(sql,/insert into public\.bi_alert_events/);
  assert.match(sql,/bi\.alert_reviewed/);
  assert.match(sql,/bi\.alert_resolved/);
  assert.match(sql,/cron\.schedule\('satrapy-bi-operational-alerts','\*\/30 \* \* \* \*'/);
});

test("consultas de alertas validan alcance, límites y paginan en servidor",async()=>{
  const sql=await read("supabase/migrations/202608130002_bi_persistent_operational_alerts.sql");
  assert.match(sql,/has_company_permission\(p_company_id,'view_bi_alerts'\)/);
  assert.match(sql,/has_company_permission\(p_company_id,'manage_bi_alerts'\)/);
  assert.match(sql,/least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
  assert.match(sql,/limit v_size offset\(v_page-1\)\*v_size/);
  assert.match(sql,/revoke all on function public\.bi_list_alerts[\s\S]*from public,anon/);
});

test("la UI administra alertas y reutiliza la investigación de Fase 2",async()=>{
  const source=await read("app/components/BiModule.tsx");
  const navigation=await read("app/components/SatrapyApp.tsx");
  assert.match(source,/\.rpc\("bi_list_alerts"/);
  assert.match(source,/\.rpc\("bi_get_attention_alerts"/);
  assert.match(source,/\.rpc\("bi_transition_alert"/);
  assert.match(source,/\.rpc\("bi_get_alert_history"/);
  assert.match(source,/alertInvestigationContext/);
  assert.match(source,/showEvidence&&<BiDrilldown/);
  assert.doesNotMatch(source,/no son alertas persistidas/i);
  assert.match(navigation,/\/satrapy\/bi\/alertas/);
  assert.match(navigation,/view_bi_alerts/);
});
