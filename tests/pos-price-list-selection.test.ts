import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608160001_pos_cart_price_list_selection.sql", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const css = readFileSync("app/globals.css", "utf8");

test("la lista se elige por venta y nunca como precio libre", () => {
  assert.match(migration, /add column if not exists price_list_id/);
  assert.match(migration, /set_sale_cart_price_list/);
  assert.match(migration, /p_expected_revision/);
  assert.match(migration, /sale_cart\.price_list_changed/);
  assert.match(migration, /La lista seleccionada no tiene precio vigente/);
  assert.doesNotMatch(sales, /Editar precio|Precio manual/);
});

test("el catálogo, carrito y cobro usan la misma lista efectiva", () => {
  assert.match(migration, /search_pos_cart_products/);
  assert.match(migration, /search_pos_cart_blocked_products/);
  assert.match(migration, /quote_sale_cart/);
  assert.match(migration, /satrapy\.pos_price_list_id/);
  assert.match(sales, /search_pos_cart_products/);
  assert.match(sales, /search_pos_cart_blocked_products/);
});

test("cada partida selecciona su nivel y no existe un selector global de lista", () => {
  assert.doesNotMatch(sales, /className="pos-price-list-select"/);
  assert.match(sales, /className="pos-price-tier-select"/);
  assert.match(sales, /set_sale_cart_item_price_tier/);
  assert.match(sales, /value: "automatic"/);
  assert.match(css, /\.pos-price-tier-select/);
});
