import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608110003_pos_cart_reset_controls.sql", "utf8");

test("el cajero puede retirar su propio descuento sin aprobarlo", () => {
  assert.match(migration, /cancel_own_cart_discount/);
  assert.match(migration, /requester_id = auth\.uid\(\)/);
  assert.match(migration, /status = 'cancelled'/);
  assert.match(migration, /sale_discount_percent = 0/);
  assert.match(migration, /discount\.cancelled/);
  assert.match(sales, /Quitar descuento/);
  assert.match(sales, /cancel_own_cart_discount/);
});

test("vaciar una venta conserva el carrito descartado y abre uno limpio", () => {
  assert.match(migration, /discard_own_sale_cart/);
  assert.match(migration, /status = 'discarded'/);
  assert.match(migration, /insert into public\.sale_carts/);
  assert.match(migration, /sale_cart\.discarded/);
  assert.doesNotMatch(migration, /delete from public\.sale_cart_items/);
  assert.match(sales, /Vaciar venta/);
  assert.match(sales, /Conservar venta/);
  assert.match(sales, /discard_own_sale_cart/);
});

test("los controles destructivos esperan la sincronización del POS", () => {
  assert.match(sales, /pendingChanges > 0/);
  assert.match(sales, /disabled=\{!checkoutReady \|\| busy\}/);
  assert.match(sales, /cualquier descuento pendiente\. La acción quedará auditada/);
});
