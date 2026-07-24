import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const salesModule = readFileSync("app/components/SalesModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607230013_receivable_debtor_context.sql", "utf8");
const leastOverdueMigration = readFileSync("supabase/migrations/202607230014_receivable_least_overdue_sort.sql", "utf8");

test("CxC muestra una ficha de deudor resuelta por servidor", () => {
  assert.match(salesModule, /get_receivable_customer_context/);
  assert.match(salesModule, /Expediente de cobranza/);
  assert.match(salesModule, /Contacto principal/);
  assert.match(salesModule, /Dirección/);
  assert.match(salesModule, /Registrar abono/);
});

test("la ficha de deudor conserva límites de acceso y datos canónicos", () => {
  assert.match(migration, /has_company_permission\(p_company_id,'view_customer_credit'\)/);
  assert.match(migration, /public\.customer_contacts/);
  assert.match(migration, /public\.customer_addresses/);
  assert.match(migration, /grant execute on function public\.get_receivable_customer_context/);
});

test("CxC permite priorizar server-side el menor saldo vencido positivo", () => {
  assert.match(salesModule, /Menor saldo vencido/);
  assert.match(salesModule, /least_overdue/);
  assert.match(salesModule, /Mayor saldo pendiente/);
  assert.match(salesModule, /Menor saldo pendiente/);
  assert.match(salesModule, /Mayor saldo vencido/);
  assert.match(salesModule, /Vencimiento más próximo/);
  assert.match(leastOverdueMigration, /smallest_balance/);
  assert.match(leastOverdueMigration, /nullif\(coalesce\(b\.overdue,0\),0\).*asc nulls last/);
  assert.match(leastOverdueMigration, /has_company_permission\(p_company_id,'view_customer_credit'\)/);
});
