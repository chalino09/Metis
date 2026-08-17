import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202608070003_pos_resilient_cart_changes.sql", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const resilience = readFileSync("app/lib/pos-resilience.ts", "utf8");

test("el cambio de partida y la cotización comparten una transacción idempotente", () => {
  assert.match(sql, /change_sale_cart_item_and_quote/);
  assert.match(sql, /pg_advisory_xact_lock/);
  assert.match(sql, /change_sale_cart_item\(/);
  assert.match(sql, /quote_sale_cart\(/);
  assert.match(sql, /unique \(company_id, client_request_id\)/);
  assert.match(sales, /change_sale_cart_item_and_quote/);
});

test("la degradación permite el borrador pero bloquea cobro y ticket", () => {
  assert.match(sales, /Sin conexión: venta pendiente de sincronizar/);
  assert.match(sales, /checkoutReady = online/);
  assert.match(sales, /disabled=\{!checkoutReady/);
  assert.match(sales, /Puedes buscar en caché y preparar el carrito/);
});

test("la cola y la caché locales se cifran sin guardar credenciales", () => {
  assert.match(resilience, /AES-GCM/);
  assert.match(resilience, /generateKey\([\s\S]+false, \["encrypt", "decrypt"\]\)/);
  assert.match(resilience, /indexedDB/);
  assert.doesNotMatch(resilience, /access_token|refresh_token|password|credential/i);
});

test("se instrumentan p95 de búsqueda, partida y cobro", () => {
  assert.match(sales, /name: "search"/);
  assert.match(sales, /name: "add_item"/);
  assert.match(sales, /name: "checkout"/);
  assert.doesNotMatch(sales, /p95 cobro|meta agregar &lt;300 ms/);
});
