import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202607230020_pos_external_payment_reference.sql", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const ticketPdf = readFileSync("app/lib/ticket-pdf.ts", "utf8");

test("el cobro externo conserva una referencia sin mezclarla con caja", () => {
  assert.match(sql, /add column if not exists payment_reference text/);
  assert.match(sql, /settlement_kind = 'external' and v_reference is null/);
  assert.match(sql, /set_config\('satrapy\.pos_payment_reference'/);
  assert.match(sql, /complete_sale\(/);
  assert.match(sql, /revoke execute on function public\.complete_sale/);
});

test("la referencia forma parte del ticket canónico y de su hash", () => {
  assert.match(sql, /jsonb_set\(new\.payload, '\{payment,reference\}'/);
  assert.match(sql, /extensions\.digest\(new\.payload::text, 'sha256'\)/);
  assert.match(ticketPdf, /drawPaymentRow\("Autorización", ticket\.payment\.reference\)/);
});

test("el POS exige evidencia antes de confirmar tarjeta", () => {
  assert.match(sales, /complete_pos_sale/);
  assert.match(sales, /Folio emitido por la terminal/);
  assert.match(sales, /la terminal procesa el cobro/);
  assert.match(sales, /selectedPayment\?\.settlement_kind === "external" && !paymentReference\.trim\(\)/);
});
