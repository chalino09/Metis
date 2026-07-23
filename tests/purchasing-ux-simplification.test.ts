import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const purchasing = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");
const shell = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const historyMigration = readFileSync("supabase/migrations/202607180002_historical_accounts_payable_read.sql", "utf8");

test("Compras expone tres vistas principales y conserva los flujos dentro de ellas", () => {
  assert.match(purchasing, /label: "Facturas"/);
  assert.match(purchasing, /label: "Cuentas por pagar"/);
  assert.match(purchasing, /value: "payments", label: "Pagos"/);
  assert.doesNotMatch(purchasing, /value: "aging", label: "Antigüedad"/);
  assert.doesNotMatch(purchasing, /value: "due_inbox", label: "Vencimientos"/);
  assert.doesNotMatch(purchasing, /value: "paying_accounts", label: "Cuentas bancarias"/);
  assert.match(purchasing, /Resumen de antigüedad/);
  assert.match(purchasing, /Vencimientos y saldos/);
  assert.match(purchasing, /paymentsSection === "proposals"/);
  assert.match(purchasing, /paymentsSection === "confirmed"/);
});

test("excepciones, comprobantes y REP permanecen en el detalle de su origen", () => {
  assert.match(purchasing, /Excepciones \(\{exceptionTotal\}\)/);
  assert.match(purchasing, /Comprobantes y REP/);
  assert.match(purchasing, /paymentDetail\.documents/);
});

test("cuentas bancarias se mueve a Configuración con el permiso existente", () => {
  assert.match(shell, /href: "\/satrapy\/configuracion\/cuentas-bancarias"/);
  assert.match(shell, /requirement: \{ all: \["manage_supplier_paying_accounts"\] \}/);
  assert.match(shell, /<SupplierPayingAccountsView/);
});

test("Historial muestra el último corte en solo lectura sin mezclarlo con Por pagar", () => {
  assert.match(purchasing, /value: "current", label: "Por pagar"/);
  assert.match(purchasing, /value: "history", label: "Historial"/);
  assert.match(purchasing, /Historial de cuentas por pagar/);
  assert.match(purchasing, /No modifica saldos ni permite preparar pagos/);
  assert.match(purchasing, /Saldo al corte/);
  assert.match(purchasing, /Vencida al corte/);
  assert.match(purchasing, /En plazo al corte/);
  assert.doesNotMatch(purchasing, /Historial Alpha|Alpha histórico|históricas de Alpha/);
  assert.match(historyMigration, /has_company_permission\(p_company_id,'view_accounts_payable'\)/);
  assert.doesNotMatch(historyMigration, /\binsert into public\.accounts_payable\b|\bupdate public\.accounts_payable\b|\bdelete from public\.accounts_payable\b/i);
});
