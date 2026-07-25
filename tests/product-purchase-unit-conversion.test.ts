import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607240005_purchase_units_and_base_inventory.sql", "utf8");
const products = readFileSync("app/components/ProductCatalogView.tsx", "utf8");
const receipts = readFileSync("app/components/PurchaseReceiptsModule.tsx", "utf8");

test("la conversión de compra conserva la unidad base como inventario canónico", () => {
  assert.match(migration, /create table if not exists public\.product_purchase_units/);
  assert.match(migration, /base_units_per_purchase_unit numeric\(18,6\) not null check \(base_units_per_purchase_unit > 0\)/);
  assert.match(migration, /generated always as \(round\(quantity\*base_units_per_purchase_unit,6\)\) stored/);
  assert.match(migration, /v_qty,v_po_line\.base_units_per_purchase_unit/);
  assert.match(migration, /v_line\.inventory_quantity/);
});

test("la OC congela la equivalencia y la recepción sigue operando en unidad de compra", () => {
  assert.match(migration, /purchase_unit_id uuid references public\.units_of_measure/);
  assert.match(migration, /base_units_per_purchase_unit numeric\(18,6\) not null default 1/);
  assert.match(migration, /select \* into v_purchase from public\.product_purchase_units/);
  assert.match(migration, /v_po_line\.quantity-v_previous/);
  assert.match(receipts, /Cantidad actual/);
});

test("el catálogo explica y configura la compra por unidad sin alterar POS", () => {
  assert.match(products, /Unidad de inventario y venta/);
  assert.match(products, /Compra y recepción/);
  assert.match(products, /1 ROLLO = 1,000 M/);
  assert.match(products, /set_product_purchase_unit/);
});
