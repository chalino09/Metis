import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608090001_automatic_internal_codes.sql", "utf8");
const products = readFileSync("app/components/ProductCatalogView.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");

test("los identificadores internos se asignan en servidor y preservan códigos existentes", () => {
  assert.match(migration, /next_company_internal_code/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /'PROD'/);
  assert.match(migration, /'PAGO'/);
  assert.match(migration, /'CAJA'/);
  assert.match(migration, /update public\.products set name=/);
  assert.match(migration, /update public\.payment_methods set display_name=/);
  assert.match(migration, /update public\.cash_registers set location_id=/);
});

test("las altas no solicitan códigos internos", () => {
  assert.doesNotMatch(products, /<Field label="Código Satrapy"/);
  assert.match(products, /if\(!normalized\.name\|\|!normalized\.reason\)return/);
  assert.doesNotMatch(sales, /<label>Código<Input required value=\{paymentCode\}/);
  assert.doesNotMatch(sales, /<label>Código<Input required value=\{registerCode\}/);
});
