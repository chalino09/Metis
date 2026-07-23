import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseBankStatement } from "../app/lib/bank-statement-import.ts";

const migration=readFileSync("supabase/migrations/202607210001_m4c_banking_reconciliation.sql","utf8");
const route=readFileSync("app/api/imports/stage-all/route.ts","utf8");
const shell=readFileSync("app/components/SatrapyApp.tsx","utf8");

test("la plantilla neutral XLSX se detecta sin selector",()=>{
  const parsed=parseBankStatement(readFileSync("public/templates/plantilla_estado_bancario_neutral.xlsx"));
  assert.ok(parsed);assert.equal(parsed.rows.length,2);assert.equal(parsed.metadata.currency.value,"MXN");assert.equal(parsed.metadata.accountLast4.value,"ABCD");assert.equal(parsed.metadata.openingBalance.value,1000);assert.equal(parsed.metadata.closingBalance.value,1150);
});

test("la plantilla neutral CSV conserva el mismo contrato",()=>{
  const parsed=parseBankStatement(readFileSync("public/templates/plantilla_estado_bancario_neutral.csv"));
  assert.ok(parsed);assert.equal(parsed.rows.length,2);assert.equal(parsed.metadata.accountLast4.value,"ABCD");assert.deepEqual(parsed.rows.map(row=>[row.reference,row.credit,row.debit]),[["COBRO-001",500,0],["PAGO-001",0,350]]);
});

test("el Centro principal detecta CSV/XLSX bancario antes del detector contable",()=>{
  assert.match(route,/detectAndStageBankStatement/);assert.match(route,/xlsx\?\|csv/);assert.match(shell,/Centro de Migración/);assert.match(shell,/plantilla_estado_bancario_neutral\.xlsx/);assert.doesNotMatch(shell,/Selecciona el tipo de estado bancario/);
});

test("el dominio bancario es neutral, masivo, paginado e inmutable",()=>{
  assert.match(migration,/create table public\.financial_accounts/);assert.match(migration,/legacy_paying_account_id/);assert.match(migration,/jsonb_to_recordset/);assert.match(migration,/limit v_size offset\(v_page-1\)\*v_size/);assert.match(migration,/bank_transactions_immutable/);assert.match(migration,/saldo inicial \+ abonos - cargos = saldo final/i);assert.doesNotMatch(migration,/BBVA|Santander|Banorte|HSBC|Citibanamex/i);
});
