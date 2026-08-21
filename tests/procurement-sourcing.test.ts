import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202607240007_procurement_sourcing.sql", "utf8");
const replenishment = readFileSync("supabase/migrations/202607240008_procurement_replenishment_generation.sql", "utf8");
const replenishmentWorkQueue = readFileSync("supabase/migrations/202608050001_inventory_replenishment_work_queue.sql", "utf8");
const nextActionFlow = readFileSync("supabase/migrations/202608050002_procurement_next_action_flow.sql", "utf8");
const supplierLevelPromptPayment = readFileSync("supabase/migrations/202608050003_procurement_quote_prompt_payment_at_supplier_level.sql", "utf8");
const requiredQuoteData = readFileSync("supabase/migrations/202608050004_procurement_quote_required_commercial_data.sql", "utf8");
const ui = readFileSync("app/components/ProcurementModule.tsx", "utf8");

test("abastecimiento adjudica por partida y genera una OC por proveedor", () => {
  assert.match(migration, /create table public\.procurement_requisitions/);
  assert.match(migration, /create table public\.procurement_quotes/);
  assert.match(migration, /create table public\.procurement_award_lines/);
  assert.match(migration, /for v_supplier in select distinct q\.supplier_id/);
  assert.match(migration, /insert into public\.purchase_orders/);
  assert.match(migration, /'draft'/);
  assert.match(migration, /update public\.purchase_orders set status='approved'/);
  assert.match(migration, /'approved'/);
});

test("cotizaciones preservan condiciones y separan descuentos", () => {
  assert.match(migration, /credit_days_snapshot/);
  assert.match(migration, /prompt_payment_terms_snapshot/);
  assert.match(migration, /commercial_discount_percent/);
  assert.match(migration, /prompt_payment_discount_percent/);
  assert.match(migration, /to_regclass\('public\.supplier_prompt_payment_terms'\)/);
  assert.match(ui, /Descuento comercial/);
  assert.match(ui, /Pronto pago/);
});

test("la interfaz presenta el módulo antes de las órdenes de compra", () => {
  const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
  assert.match(app, /href: "\/satrapy\/compras\/abastecimiento"/);
  assert.match(app, /id: "purchasing", label: "Compras", views: \["suppliers", "procurement", "purchase_orders"/);
  assert.match(app, /<ProcurementView/);
  assert.match(app, /Crear solicitud/);
  assert.match(app, /generate_procurement_requisition_from_replenishment/);
  assert.match(ui, /Registrar cotización/);
  assert.match(ui, /Siguiente paso/);
  assert.match(ui, /Aprobar compra y crear orden/);
  assert.match(ui, /Enviar selección a aprobación/);
  assert.match(ui, /Resumen de autorización/);
  assert.match(ui, /Almacén destino/);
  assert.match(ui, /Ajustar cantidades/);
  assert.match(ui, /Editar cotización/);
  assert.doesNotMatch(ui, /Preparar selección/);
});

test("compras guía la acción siguiente y sólo permite editar la necesidad antes de cotizar", () => {
  assert.match(nextActionFlow, /adjust_procurement_requisition_quantities/);
  assert.match(nextActionFlow, /ya tiene cotizaciones/);
  assert.match(nextActionFlow, /create_procurement_order_from_selection/);
  assert.match(nextActionFlow, /recommend_procurement_award/);
  assert.match(nextActionFlow, /approve_procurement_award/);
});

test("el pronto pago es una condición única de proveedor para cada cotización", () => {
  assert.match(supplierLevelPromptPayment, /prompt_payment_discount_percent/);
  assert.match(supplierLevelPromptPayment, /prompt_payment_term_days/);
  assert.match(ui, /Se precarga desde el proveedor/);
  assert.match(ui, /promptPaymentDiscount/);
  assert.doesNotMatch(ui, /<Field label="Pronto pago %">/);
});

test("una cotización operativa exige precio, disponibilidad, vigencia y fecha de entrega", () => {
  assert.match(requiredQuoteData, /Indica la vigencia de la cotización/);
  assert.match(requiredQuoteData, /line\.available_quantity<=0/);
  assert.match(requiredQuoteData, /line\.unit_price<=0/);
  assert.match(requiredQuoteData, /line\.expected_date is null/);
  assert.match(ui, /Captura vigencia, fecha estimada, disponibilidad y precio mayor a cero/);
});

test("reabastecimiento genera necesidades sin duplicar partidas activas", () => {
  assert.match(replenishment, /generate_procurement_requisition_from_replenishment/);
  assert.match(replenishment, /not exists\(\s*select 1 from public\.procurement_requisition_lines/);
  assert.match(replenishment, /procurement\.replenishment_generated/);
  assert.match(replenishmentWorkQueue, /r\.status in \('draft','quoting','recommended'\)/);
  assert.match(replenishmentWorkQueue, /pg_advisory_xact_lock/);
});
