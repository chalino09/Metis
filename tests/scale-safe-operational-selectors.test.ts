import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607180005_scale_safe_operational_selectors.sql", "utf8");
const stagedRoute = readFileSync("app/api/imports/staged-batches/route.ts", "utf8");
const shell = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const suppliers = readFileSync("app/components/SuppliersModule.tsx", "utf8");
const purchaseOrders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const receipts = readFileSync("app/components/PurchaseReceiptsModule.tsx", "utf8");
const invoices = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");
const invoiceableReceipts = readFileSync("supabase/migrations/202607180012_fast_invoiceable_receipt_search.sql", "utf8");
const operationalOptions = readFileSync("supabase/migrations/202607180013_fast_supplier_and_receivable_order_options.sql", "utf8");
const receivableOrderContext = readFileSync("supabase/migrations/202608050005_receivable_order_picker_context.sql", "utf8");

test("staging expone total y páginas sin perder los lotes posteriores al top 20", () => {
  assert.match(migration, /list_import_staging_batches_page/);
  assert.match(migration, /limit v_size offset \(v_page - 1\) \* v_size/);
  assert.match(migration, /'pagination'.*'total'/s);
  assert.match(stagedRoute, /searchParams\.get\("page"\)/);
  assert.match(stagedRoute, /list_import_staging_batches_page/);
  assert.match(shell, /batchTotal > 20/);
  assert.match(shell, /Lotes anteriores/);
});

test("las bandejas de excepciones recorren todas sus páginas y muestran el total real", () => {
  assert.match(suppliers, /p_page:exceptionPage,p_page_size:50/);
  assert.match(suppliers, /exceptionTotal/);
  assert.match(purchaseOrders, /p_page:exceptionPage,p_page_size:50/);
  assert.match(purchaseOrders, /Bandeja de excepciones \(\{exceptionTotal\}\)/);
});

test("recepciones y facturas buscan entidades operativas en servidor", () => {
  assert.match(receipts, /search_receivable_purchase_order_options/);
  assert.match(receipts, /p_query:orderQuery\.trim\(\)\|\|null/);
  assert.match(invoices, /p_query: receiptQuery\.trim\(\) \|\| null/);
  assert.match(invoices, /p_query: draftSupplierQuery\.trim\(\) \|\| null/);
  assert.match(invoices, /p_query: filterSupplierQuery\.trim\(\) \|\| null/);
  assert.match(invoices, /p_query: extracted\.issuer_rfc/);
  assert.doesNotMatch(invoices, /p_page_size:\s*100,\s*p_is_active:\s*true/);
  assert.doesNotMatch(invoices, /search_invoiceable_receipts[^\n]+p_page_size:\s*100/);
});

test("proveedores y OC recibibles usan opciones ligeras sin perfiles ni conteos", () => {
  assert.match(purchaseOrders, /search_supplier_options/);
  assert.match(invoices, /search_supplier_options/);
  assert.match(operationalOptions, /create or replace function public\.search_supplier_options/);
  assert.match(operationalOptions, /create or replace function public\.search_receivable_purchase_order_options/);
  assert.doesNotMatch(operationalOptions, /count\(\*\)/);
  assert.doesNotMatch(operationalOptions, /legal_name|address_line|phone_e164/);
});

test("el selector de recepción distingue órdenes por entrega y total sin ampliar la consulta", () => {
  assert.match(receivableOrderContext, /po\.expected_date/);
  assert.match(receivableOrderContext, /po\.total/);
  assert.match(receivableOrderContext, /po\.currency_code/);
  assert.doesNotMatch(receivableOrderContext, /count\(\*\)/);
  assert.match(receipts, /Entrega esperada:/);
  assert.match(receipts, /Total:/);
});

test("recepciones facturables calculan saldos una vez y reutilizan la página", () => {
  assert.match(invoiceableReceipts, /with line_balances as materialized/);
  assert.match(invoiceableReceipts, /sum\(sil\.quantity\) filter \(where si\.id is not null\)/);
  assert.match(invoiceableReceipts, /candidates as materialized/);
  assert.match(invoiceableReceipts, /counted as/);
  assert.match(invoiceableReceipts, /paged as materialized/);
  assert.doesNotMatch(invoiceableReceipts, /select sum\(sil\.quantity\).*purchase_receipt_line_id=prl\.id/s);
});
