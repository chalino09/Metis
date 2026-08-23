import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202608220002_sales_quote_intake_review.sql", "utf8");
const component = readFileSync("app/components/QuotePreparationInbox.tsx", "utf8");

test("quote intake review recalculates canonical commercial data server-side", () => {
  assert.match(sql, /create or replace function public\.review_sales_quote_intake/);
  assert.match(sql, /join public\.product_prices/);
  assert.match(sql, /join lateral\([\s\S]*public\.tax_rates/);
  assert.match(sql, /left join public\.inventory_balances/);
  assert.match(sql, /jsonb_array_length\(p_lines\)>100/);
});

test("quote intake conversion reuses the canonical quote transaction", () => {
  assert.match(sql, /public\.save_sales_quote\(/);
  assert.match(sql, /status='converted',quote_id=v_quote_id/);
  assert.match(sql, /sales_quote_intake\.converted/);
});

test("review UI exposes product, customer and quantity adjustments", () => {
  assert.match(component, /Revisar y ajustar/);
  assert.match(component, /Buscar producto/);
  assert.match(component, /Guardar ajustes/);
  assert.match(component, /convert_sales_quote_intake/);
});

test("preparation warns about shortages without disabling quote creation", () => {
  assert.match(component, /Number\(line\.quantity\) > Number\(line\.quantity_on_hand/);
  assert.match(component, /Existencia insuficiente para surtir ahora/);
  assert.match(component, /Puedes crear la cotización/);
  assert.doesNotMatch(component, /disabled=\{shortageLines\.length/);
});
