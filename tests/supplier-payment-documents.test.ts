import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607180001_supplier_payment_documents_rep.sql", "utf8");
const component = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");

test("comprobantes y REP usan bucket privado, signed URLs y RLS sin mutación de objetos", () => {
  assert.match(migration, /values\('supplier-payment-documents','supplier-payment-documents',false,/);
  assert.match(migration, /supplier_payment_documents_storage_read/);
  assert.match(migration, /supplier_payment_documents_storage_insert/);
  assert.doesNotMatch(migration, /supplier_payment_documents_storage_(update|delete)/);
  assert.match(component, /from\("supplier-payment-documents"\)\.createSignedUrl/);
  assert.doesNotMatch(component, /from\("supplier-payment-documents"\)\.getPublicUrl/);
});

test("el REP se rehasea y analiza server-side antes de registrar evidencia", () => {
  assert.match(migration, /digest\(v_bytes,'sha256'\)/);
  assert.match(migration, /xmlparse\(document v_text\)/);
  assert.match(migration, /El SHA-256 del REP no coincide con su contenido/);
  assert.match(component, /register_supplier_payment_rep_xml/);
});
