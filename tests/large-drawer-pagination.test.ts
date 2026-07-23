import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const dataUi = readFileSync("app/components/ui/data.tsx", "utf8");
const orders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const receipts = readFileSync("app/components/PurchaseReceiptsModule.tsx", "utf8");
const invoices = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");

test("el paginador de colecciones monta como máximo una ventana de 25 registros", () => {
  assert.match(dataUi, /export function PagedCollection<T>/);
  assert.match(dataUi, /pageSize = 25/);
  assert.match(dataUi, /items\.slice\(start, start \+ pageSize\)/);
  assert.match(dataUi, /DataPagination page=\{page\} total=\{items\.length\}/);
  assert.doesNotMatch(dataUi, /useEffect/);
});

test("los detalles de compras no renderizan todas las partidas y movimientos", () => {
  assert.match(orders, /PagedCollection items=\{detail\.lines\}/);
  assert.match(orders, /PagedCollection items=\{receiptRelation\.receipts\}/);
  assert.match(orders, /PagedCollection items=\{detail\.history\}/);
  assert.match(receipts, /PagedCollection items=\{detail\.lines\}/);
  assert.match(receipts, /PagedCollection items=\{detail\.movements\}/);
});

test("propuestas, facturas y pagos conservan totales pero acotan filas visibles", () => {
  assert.match(invoices, /PagedCollection items=\{Object\.values\(selectedPayables\)/);
  assert.match(invoices, /La selección completa se conserva entre páginas/);
  assert.match(invoices, /PagedCollection items=\{proposalDetail\.lines\}/);
  assert.match(invoices, /PagedCollection items=\{detail\.expense_lines\}/);
  assert.match(invoices, /PagedCollection items=\{paymentDetail\.applications\}/);
});

test("tickets grandes también limitan las partidas visibles", () => {
  assert.match(sales, /PagedCollection items=\{items\}/);
  assert.match(sales, /label="partidas"/);
});
