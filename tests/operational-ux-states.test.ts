import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const dataState = readFileSync("app/components/ui/data.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const inventory = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const orders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const receipts = readFileSync("app/components/PurchaseReceiptsModule.tsx", "utf8");
const supplierInvoices = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");

test("carga, vacío y error exponen estados semánticos consistentes", () => {
  assert.match(dataState, /data-state--loading" role="status" aria-live="polite"/);
  assert.match(dataState, /data-state--error" role="alert"/);
  assert.match(dataState, /data-state--empty" role="status"/);
  assert.match(dataState, /emptyTitle = "No hay información para mostrar\."/);
});

test("Ventas, Inventario y Compras conservan resultados durante una actualización", () => {
  for (const source of [sales, inventory, orders, receipts, supplierInvoices]) {
    assert.match(source, /DataRefreshStatus/, "falta el estado de actualización no bloqueante");
  }
  assert.match(sales, /loading=\{loading&&rows\.length===0\}/);
  assert.match(inventory, /loading=\{loading && rows\.length === 0\}/);
  assert.match(orders, /loading=\{loading&&rows\.length===0\}/);
  assert.match(receipts, /loading=\{loading&&rows\.length===0\}/);
});

test("los listados principales ofrecen recuperación y mensajes entendibles", () => {
  for (const source of [sales, inventory, orders, receipts]) assert.match(source, />Reintentar<\/Button>/);
  assert.match(supplierInvoices, /> Actualizar<\/Button>/);
  assert.match(orders, /No se pudieron cargar las cotizaciones y órdenes\./);
  assert.match(receipts, /No se pudieron cargar las recepciones\./);
  assert.match(sales, /No se pudieron consultar las ventas\./);
  assert.match(inventory, /No se pudieron cargar las sugerencias de reabastecimiento\./);
  assert.match(supplierInvoices, /No se pudieron cargar las cuentas por pagar\./);
});

test("la navegación, paginación y estados pendientes explican su situación", () => {
  assert.match(inventory, /aria-current=\{activeArea === section\.id \? "page" : undefined\}/);
  assert.match(inventory, /aria-current=\{activeView === name \? "page" : undefined\}/);
  assert.match(orders, /const PAGE_SIZE=25;/);
  assert.match(supplierInvoices, /emptyTitle="No hay facturas\."/);
  assert.match(inventory, /replenishment-policy-requirement/);
  assert.match(inventory, /Selecciona una ubicación para habilitar el guardado\./);
});
