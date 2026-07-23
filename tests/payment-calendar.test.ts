import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const component = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607180004_operational_payment_calendar.sql", "utf8");

test("Agenda vive dentro de Pagos con vistas semanal, mensual y tabla", () => {
  assert.match(component, /value: "agenda", label: "Agenda"/);
  assert.match(component, /label: "Pagos realizados"/);
  assert.match(component, /onView\("week"\)/);
  assert.match(component, /onView\("month"\)/);
  assert.match(component, /onView\("table"\)/);
});

test("seleccionar reutiliza constructor, propuesta y detalle de pago", () => {
  assert.match(component, /setProposalBuilderOpen\(true\)/);
  assert.match(component, /setTab\("payments"\); setPaymentsSection\("proposals"\)/);
  assert.match(component, /openProposalDetail\(item\.proposal_id\)/);
  assert.match(component, /setCalendarPaymentId\(item\.payment_id\)/);
  assert.match(component, /get_supplier_payment_detail/);
});

test("RPC de agenda es paginado, separa totales por fecha y moneda y no muta saldos", () => {
  assert.match(migration, /has_company_permission\(p_company_id,'view_accounts_payable'\)/);
  assert.match(migration, /limit v_size offset \(v_page-1\)\*v_size/);
  assert.match(migration, /group by due_date,currency_code/);
  assert.match(migration, /'overdue'.*'due_today'.*'upcoming'.*'future'/s);
  assert.match(migration, /'scheduled'/);
  assert.doesNotMatch(migration, /\b(update|insert into|delete from)\s+public\.accounts_payable\b/i);
});
