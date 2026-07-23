import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const suppliers = readFileSync("app/components/SuppliersModule.tsx", "utf8");
const orders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const parser = readFileSync("app/lib/alpha.ts", "utf8");
const customerParser = readFileSync("app/lib/alpha-customer-migration.ts", "utf8");
const presentationText = readFileSync("app/lib/presentation-text.ts", "utf8");

test("la interfaz usa lenguaje neutral para el origen de los datos", () => {
  assert.doesNotMatch(app, /Excel de Alpha|archivos de Alpha|CxC Alpha|CxP Alpha|RFC Alpha|SKU Alpha|interpretación de Alpha|importado de Alpha|Proveedores Alpha|compra Alpha|paquetes Alpha/i);
  assert.doesNotMatch(suppliers, /Alpha se conserva|<small>Alpha /i);
  assert.doesNotMatch(orders, /Alpha reporta/i);
  assert.match(app, /SKU de origen/);
  assert.match(app, /Proveedores importados/);
});

test("los mensajes nuevos de importación tampoco exponen la marca", () => {
  assert.doesNotMatch(parser, /message: [^\n]*\bAlpha\b/);
  assert.match(customerParser, /Cliente importado \$\{code\}/);
  assert.match(presentationText, /presentImportedSourceText/);
  assert.match(app, /presentImportedSourceText\(result\.message\)/);
});
