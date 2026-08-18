import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608180001_pos_product_price_tiers.sql", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const alpha = readFileSync("app/lib/alpha.ts", "utf8");

test("los precios escalonados se resuelven por cantidad en servidor", () => {
  assert.match(migration, /create table if not exists public\.product_price_quantity_tiers/);
  assert.match(migration, /product_price_quantity_tiers_no_overlap/);
  assert.match(migration, /v_quantity >= tier\.min_quantity/);
  assert.match(migration, /v_quantity <= tier\.max_quantity/);
  assert.match(migration, /set_sale_cart_item_price_tier/);
  assert.match(migration, /satrapy\.pos_cart_id/);
  assert.match(migration, /complete_pos_sale/);
});

test("un precio escalonado no acumula el descuento porcentual de empresa", () => {
  assert.match(migration, /doble descuento no autorizado/);
  assert.match(migration, /new\.discount_percent := 0/);
});

test("el POS informa el nivel automático o manual por partida", () => {
  assert.match(sales, /price_tier_mode/);
  assert.match(sales, /"Automático"/);
  assert.match(sales, /"Manual"/);
  assert.match(sales, /priceTierRange/);
});

test("la importación Alpha conserva rangos precN, desdN y hastN", () => {
  assert.match(alpha, /parseProductPriceTiers/);
  assert.match(alpha, /`prec\$\{listNumber\}`/);
  assert.match(alpha, /`desd\$\{listNumber\}`/);
  assert.match(alpha, /`hast\$\{listNumber\}`/);
  assert.match(migration, /sync_alpha_product_price_tiers_from_batch/);
});
