import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607280003_sales_returns.sql", "utf8");
const ui = readFileSync("app/components/SalesModule.tsx", "utf8");

test("la devolución permanece ligada al ticket y a cada partida original", () => {
  assert.match(migration, /sale_id uuid not null references public\.sales/);
  assert.match(migration, /sale_item_id uuid not null references public\.sale_items/);
  assert.match(migration, /v_prior_quantity\+v_input\.quantity>v_item\.quantity/);
  assert.match(migration, /Cada partida vendida debe aparecer una sola vez/);
  assert.match(migration, /client_request_id uuid not null/);
});

test("inventario sólo se reintegra cuando la mercancía es recibible", () => {
  assert.match(migration, /restocked boolean not null/);
  assert.match(migration, /if v_input\.restock then[\s\S]*movement_type,sale_return_item_id/);
  assert.match(migration, /'sale_return'/);
  assert.match(ui, /Mercancía recibible/);
  assert.match(ui, /Sólo las partidas marcadas como recibibles regresarán a existencia/);
});

test("el ajuste financiero y contable no muta la venta", () => {
  assert.doesNotMatch(migration, /update public\.sales set/);
  assert.match(migration, /financial_adjustment_kind in \('cash_refund','external_refund','receivable_reduction'\)/);
  assert.match(migration, /sale_return_confirmed/);
  assert.match(migration, /recognized_unit_cost/);
  assert.match(migration, /'inventory','debit',v_restock_cost/);
  assert.match(migration, /'cost_of_goods_sold','debit',0,'credit',v_restock_cost/);
});

test("postventa es server-side, transaccional, auditada y sin captura registro por registro", () => {
  assert.match(migration, /create or replace function public\.process_sale_return/);
  assert.match(migration, /jsonb_to_recordset\(p_items\)/);
  assert.match(migration, /'sale\.returned'/);
  assert.match(migration, /'reason',trim\(p_reason\)/);
  assert.match(ui, /Captura en conjunto las partidas recibidas/);
  assert.match(ui, /get_sale_return_context/);
});
