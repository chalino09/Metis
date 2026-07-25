import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/202607240007_procurement_sourcing.sql", "utf8");
const replenishment = readFileSync("supabase/migrations/202607240008_procurement_replenishment_generation.sql", "utf8");
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
  assert.match(app, /<ProcurementView/);
  assert.match(app, /Preparar requisición/);
  assert.match(app, /generate_procurement_requisition_from_replenishment/);
  assert.match(ui, /Registrar cotización/);
  assert.match(ui, /Preparar recomendación/);
  assert.match(ui, /Aprobar y crear OC/);
});

test("reabastecimiento genera necesidades sin duplicar partidas activas", () => {
  assert.match(replenishment, /generate_procurement_requisition_from_replenishment/);
  assert.match(replenishment, /not exists\(\s*select 1 from public\.procurement_requisition_lines/);
  assert.match(replenishment, /procurement\.replenishment_generated/);
});
