import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const baseMigration = readFileSync("supabase/migrations/202607240001_supplier_payment_terms.sql", "utf8");
const correction = readFileSync("supabase/migrations/202607240002_supplier_prompt_payment_terms.sql", "utf8");
const settlement = readFileSync("supabase/migrations/202607240003_supplier_prompt_payment_settlement.sql", "utf8");
const suppliers = readFileSync("app/components/SuppliersModule.tsx", "utf8");
const invoices = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");

test("conserva días de crédito y modela hasta tres descuentos por proveedor", () => {
  assert.match(baseMigration, /payable_term_days/);
  assert.match(correction, /create table if not exists public\.supplier_prompt_payment_terms/);
  assert.match(correction, /tier_number between 1 and 3/);
  assert.match(correction, /discount_components jsonb/);
  assert.match(correction, /save_supplier_prompt_payment_terms/);
  assert.match(suppliers, /Días de crédito/);
  assert.match(suppliers, /Plazo \$\{index\+1\} \(días\)/);
  assert.match(suppliers, /Acepta valores como 10 o 10\+5/);
});

test("las facturas congelan las condiciones y agenda proyecta el beneficio sin cambiar saldos", () => {
  assert.match(correction, /supplier_invoice_prompt_payment_terms/);
  assert.match(correction, /snapshot_supplier_prompt_payment_terms/);
  assert.match(correction, /estimated_savings/);
  assert.match(correction, /estimated_total/);
  assert.match(invoices, /Pagos → Agenda/);
  assert.match(invoices, /Sin descuento vigente/);
  assert.match(invoices, /Total estimado/);
  assert.match(invoices, /suggestedProposalAmount/);
  assert.match(invoices, /Pronto pago \{promptPayment\.discount_expression\}/);
  assert.doesNotMatch(invoices, /Reconocer total posterior/);
  assert.doesNotMatch(invoices, /Total después del plazo/);
});

test("la operación incorrecta de aumento queda deshabilitada de forma compatible", () => {
  assert.match(correction, /Esta operación fue retirada/);
  assert.match(correction, /revoke all on function public\.recognize_supplier_late_payment_charge[\s\S]*from authenticated/);
  assert.match(correction, /LEGACY: retirado/);
  assert.match(correction, /p_late_payment_total is not null[\s\S]*El total posterior fue retirado/);
});

test("el pago oportuno extingue la CxP y conserva el descuento separado", () => {
  assert.match(settlement, /prompt_payment_discount_amount/);
  assert.match(settlement, /p_effective_date<=v_line\.issued_date\+t\.term_days/);
  assert.match(settlement, /v_settlement:=round\(v_line\.proposed_amount\+v_discount,6\)/);
  assert.match(settlement, /outstanding_amount=round\(outstanding_amount-v_settlement,6\)/);
  assert.match(settlement, /Descuento obtenido por pronto pago/);
  assert.match(invoices, /<th className="number-cell">Descuento<\/th>/);
});
