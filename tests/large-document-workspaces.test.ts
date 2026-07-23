import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607180006_large_document_workspaces.sql", "utf8");
const inventory = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const invoices = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");

test("el conteo localiza códigos y aliases sin cargar el catálogo completo", () => {
  assert.match(migration, /product\.barcode product_barcode/);
  assert.match(migration, /from public\.product_aliases alias_data/);
  assert.match(migration, /limit v_size offset \(v_page - 1\) \* v_size/);
  assert.match(inventory, /Escanear código de barras o SKU/);
  assert.match(inventory, /scanCountLine/);
  assert.match(inventory, /savePendingLines\(\{ silent: true \}\)/);
});

test("CxC devuelve resumen separado y documentos filtrados por página", () => {
  assert.match(migration, /list_customer_open_receivables_page/);
  assert.match(migration, /'summary', v_summary/);
  assert.match(migration, /'pagination'.*'total'/s);
  assert.match(migration, /'open_receivables', '\[\]'::jsonb/);
  assert.match(sales, /list_customer_open_receivables_page/);
  assert.match(sales, /p_due_status: documentDue/);
  assert.match(sales, /page=\{documentPage\} total=\{documentTotal\}/);
  assert.doesNotMatch(sales, /rpc\("list_customer_open_receivables"/);
});

test("la conciliación usa la recepción como base y renderiza solo una página", () => {
  assert.match(invoices, /Usar recepción como base/);
  assert.match(invoices, /candidate\.lines\.map\(line => \[line\.purchase_receipt_line_id, String\(line\.available_quantity\)\]\)/);
  assert.match(invoices, /const visible = filtered\.slice\(\(page - 1\) \* PAGE_SIZE, page \* PAGE_SIZE\)/);
  assert.match(invoices, /Mostrar solo por revisar/);
  assert.match(invoices, /Los totales y límites se validan nuevamente en servidor/);
});
