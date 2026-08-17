import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const migration=fs.readFileSync("supabase/migrations/202608140001_bi_metric_contract.sql","utf8");
const catalogRoute=fs.readFileSync("app/api/bi/metrics/catalog/route.ts","utf8");
const queryRoute=fs.readFileSync("app/api/bi/metrics/query/route.ts","utf8");
const exportsCode=fs.readFileSync("app/lib/bi-report-export.ts","utf8");

test("el catálogo publica un contrato versionado y explicable",()=>{
  for(const field of["metric_id","contract_version","responsible_rpc","favorable_direction","compatible_filters","time_granularities","supported_comparisons","availability","value_behavior","trace","examples"])
    assert.match(migration,new RegExp(`'${field}'`));
  assert.match(migration,/'arbitrary_sql',false/);
});

test("la consulta agent es allowlisted, paginada, acotada y usa el motor humano",()=>{
  assert.match(migration,/key not in\('metric_id','period','comparison','granularity','dimensions','filters','order','page','limit'\)/);
  assert.match(migration,/date_to-date_from>365/);
  assert.match(migration,/least\(greatest\(coalesce\(\(p_request->>'limit'\)::integer,25\),1\),100\)/);
  assert.match(migration,/result:=public\.bi_explorer_query/);
  assert.doesNotMatch(migration,/execute\s+format|p_request->>'sql'/i);
});

test("la observabilidad evita prompts y payloads sensibles",()=>{
  for(const field of["metric_id","contract_version","actor_type","query_type","duration_ms","rows_returned","status","cache"])
    assert.match(migration,new RegExp(`'${field}'`));
  assert.doesNotMatch(migration,/'prompt'/);
});

test("los endpoints exigen sesión y no cachean entre empresas",()=>{
  for(const route of[catalogRoute,queryRoute]){
    assert.match(route,/auth\.getUser\(\)/);assert.match(route,/private, no-store/);assert.match(route,/vary":"authorization/);
  }
  assert.match(queryRoute,/MAX_BYTES=16_384/);assert.match(queryRoute,/Consulta no disponible para este acceso/);
});

test("alertas y exportaciones conservan metric_id y versión",()=>{
  assert.match(migration,/bi_alerts add column if not exists metric_contract_version/);
  assert.match(migration,/bi_alert_rules add column if not exists metric_contract_version/);
  assert.match(exportsCode,/metric_id/);assert.match(exportsCode,/contract_version/);assert.match(exportsCode,/responsible_rpc/);
});
