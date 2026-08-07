import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const route = readFileSync(new URL("../app/api/imports/accounting/route.ts", import.meta.url), "utf8");
const accountingModule = readFileSync(new URL("../app/components/AccountingModule.tsx", import.meta.url), "utf8");

test("cada vista contable pide únicamente su alcance", () => {
  assert.match(route, /const view=request\.nextUrl\.searchParams\.get\("view"\)\?\?"summary"/);
  for (const view of ["summary", "accounts", "periods", "reports", "journals", "events", "opening", "settings"]) {
    assert.match(route, new RegExp(`if\\(view==="${view}"\\)`));
  }
  assert.match(accountingModule, /new URLSearchParams\(\{companyId,view\}\)/);
});

test("pólizas, ajustes y eventos usan paginación del servidor", () => {
  assert.match(route, /journalsPage=pageFor\("journalsPage"\)/);
  assert.match(route, /adjustmentsPage=pageFor\("adjustmentsPage"\)/);
  assert.match(route, /eventsPage=pageFor\("eventsPage"\)/);
  assert.match(route, /\.range\(journalsRange\.from,journalsRange\.to\)/);
  assert.match(route, /\.range\(adjustmentsRange\.from,adjustmentsRange\.to\)/);
  assert.match(route, /\.range\(eventsRange\.from,eventsRange\.to\)/);
  assert.match(accountingModule, /label="pólizas"/);
  assert.match(accountingModule, /label="ajustes"/);
  assert.match(accountingModule, /label="eventos"/);
});

test("el resumen usa totales ligeros, no las colecciones completas", () => {
  assert.match(accountingModule, /const open = data\.stats\.openPeriodCount/);
  assert.match(accountingModule, /const posted = data\.stats\.postedJournalCount/);
  assert.match(route, /postedJournalCount/);
});

test("el centro de pendientes deriva trabajo de estados contables existentes", () => {
  for (const source of ["accounting_events", "accounting_manual_adjustments", "accounting_close_runs", "bank_reconciliation_exceptions"]) {
    assert.match(route, new RegExp(`from\\(\"${source}\"\\)`));
  }
  assert.match(route, /pendingWork/);
  assert.match(accountingModule, /Pendientes contables/);
  assert.match(accountingModule, /pendingWork\.length > 0/);
  assert.doesNotMatch(accountingModule, /V\$\{approved\.version\}/);
  assert.match(route, /\/satrapy\/contabilidad\/bancos/);
});
