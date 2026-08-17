import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration=readFileSync("supabase/migrations/202608170001_collection_assisted_agent.sql","utf8");
const agent=readFileSync("app/lib/collection-agent.ts","utf8");
const worker=readFileSync("scripts/collection-worker.ts","utf8");
const ui=readFileSync("app/components/CollectionAutomationModule.tsx","utf8");

test("el agente usa salida estructurada, herramienta cerrada y guardrail por caso",()=>{
  assert.match(agent,/@openai\/agents/);assert.match(agent,/outputType:collectionProposalSchema/);
  assert.match(agent,/consultar_contexto_cobranza/);assert.match(agent,/inputGuardrails/);assert.match(agent,/caseId/);
  assert.match(agent,/nunca ejecutas acciones/i);
});

test("el worker separa tareas asistidas y exige credenciales server-side",()=>{
  assert.match(worker,/task_type==="assisted_review"/);assert.match(worker,/OPENAI_API_KEY/);
  assert.match(worker,/collection_get_agent_context/);assert.match(worker,/collection_record_agent_proposal/);
  assert.match(worker,/collection_finish_assisted_task/);assert.match(worker,/forceFlush/);
  assert.doesNotMatch(worker,/NEXT_PUBLIC_OPENAI/);
});

test("la aprobación revalida saldo, vigencia y bloqueos sin tocar CxC",()=>{
  assert.match(migration,/v_balance<>v\.balance_snapshot/);assert.match(migration,/v\.expires_at<=clock_timestamp/);
  assert.match(migration,/collection_blocks.*status='active'/);assert.match(migration,/collection_decide_proposal/);
  assert.doesNotMatch(migration,/update public\.customer_receivables/);assert.doesNotMatch(migration,/insert into public\.receivable_payments/);
});

test("la generación y revisión son server-side, paginadas y explícitamente humanas",()=>{
  assert.match(migration,/collection_generate_assisted_reviews/);assert.match(migration,/p_batch_size not between 1 and 500/);
  assert.match(migration,/collection_list_proposals/);assert.match(ui,/Esperando aprobación/);
  assert.match(ui,/Aprobar no envía comunicaciones/);assert.match(ui,/Preparar lote de 100/);
  assert.doesNotMatch(ui,/\.from\(/);
});

test("la respuesta operativa no expone metadatos técnicos ni acceso directo",()=>{
  const listBody=migration.slice(migration.indexOf("create or replace function public.collection_list_proposals"),migration.indexOf("create or replace function public.collection_decide_proposal"));
  const publicSelect=listBody.match(/select p\.id,[^\n]+/)?.[0]??"";
  assert.doesNotMatch(publicSelect,/p\.model|p\.prompt_version|p\.evidence|p\.case_id/);
  assert.match(migration,/revoke select on public\.collection_proposals,public\.collection_executions,public\.collection_actions from authenticated/);
  assert.doesNotMatch(ui,/review\.model|review\.prompt_version|review\.evidence/);
  assert.match(ui,/Preparar contacto/);assert.match(ui,/Riesgo \{riskLabel/);
});

test("la fase cierra telemetría, aplicación única e historial contextual",()=>{
  assert.match(agent,/result\.state\.usage/);assert.match(agent,/traceIncludeSensitiveData:false/);assert.match(agent,/estimatedCostUsd/);
  assert.match(migration,/collection_finish_assisted_task/);assert.match(migration,/estimated_cost_usd/);assert.match(migration,/provider_trace_id/);
  assert.match(migration,/collection_apply_proposal/);assert.match(migration,/status='approved' for update/);assert.match(migration,/proposal_applied/);
  assert.match(migration,/assistant_history/);assert.match(ui,/Contexto asistido/);assert.match(ui,/Historial de propuestas/);assert.match(ui,/Aplicar aprobación/);
});
