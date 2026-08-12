import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { neutralMetricValue } from "../app/lib/neutral-start.ts";

const migration = readFileSync("supabase/migrations/202607280004_company_neutral_start.sql", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const bi = readFileSync("app/components/BiModule.tsx", "utf8");
const accounting = readFileSync("app/components/AccountingModule.tsx", "utf8");

test("el arranque neutral se deriva sin flags ni saldos automáticos", () => {
  assert.match(migration, /company_neutral_start_snapshot/);
  assert.match(migration, /'creates_opening_balances',false/);
  assert.match(migration, /'manual_row_capture_supported',false/);
  assert.doesNotMatch(migration, /alter table public\.companies add column/i);
  assert.doesNotMatch(migration, /insert into public\.(inventory_balances|customer_receivables|accounts_payable|bank_transactions|accounting_journal_entries)/i);
  assert.doesNotMatch(migration, /alpha_/i);
});

test("el RPC aplica acceso por empresa, auditoría y permisos cerrados", () => {
  assert.match(migration, /public\.has_company_access\(p_company_id\)/);
  assert.match(migration, /'company\.neutral_start_inspected'/);
  assert.match(migration, /revoke all on function public\.company_neutral_start_snapshot/);
  assert.match(migration, /grant execute on function public\.get_company_neutral_start\(uuid\) to authenticated/);
});

test("BI diferencia cero operativo de indisponibilidad histórica", () => {
  assert.equal(neutralMetricValue("zero_no_operations", "currency"), "$0");
  assert.equal(neutralMetricValue("zero_no_operations", "integer"), "0");
  assert.equal(neutralMetricValue("unavailable", "currency"), "No disponible");
  assert.match(migration, /'value_state','zero_no_operations'/);
  assert.match(migration, /'value_state','unavailable'/);
  assert.match(migration, /No disponible: aún no existe base histórica/);
  assert.match(bi, /neutralMetricValue/);
});

test("la UI no muestra avisos de arranque neutral", () => {
  assert.doesNotMatch(app, /NeutralStartNotice/);
  assert.doesNotMatch(app, /module="(?:inventory|cash_banks|payables|accounting|bi)"/);
  assert.match(accounting, /importa archivos por conjunto/);
  assert.match(accounting, /Estado neutral, sin póliza de apertura/);
  assert.doesNotMatch(accounting, /Elige captura manual o importación/);
});

test("el margen conserva el cálculo previo por costo reconocido", () => {
  assert.match(migration, /bi_get_executive_summary_before_neutral_start/);
  assert.match(migration, /bi_get_executive_charts_before_neutral_start/);
  assert.doesNotMatch(migration, /product_costs|recognized_unit_cost|recognized_cost_amount/);
});
