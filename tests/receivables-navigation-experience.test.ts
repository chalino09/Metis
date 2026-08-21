import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const collection = readFileSync("app/components/CollectionAutomationModule.tsx", "utf8");
const navigation = readFileSync("app/components/ReceivablesNavigation.tsx", "utf8");

test("CxC mantiene activo el módulo padre al entrar a Gestiones", () => {
  assert.match(app, /function navigationViewIsActive\(name: ViewName, activeView: ViewName\)/);
  assert.match(app, /activeView === "receivables" \|\| activeView === "collection_automation"/);
  assert.match(app, /const active = navigationViewIsActive\(name, activeView\)/);
});

test("Cartera y Gestiones comparten encabezado y pestañas", () => {
  assert.match(navigation, /export function ReceivablesModuleHeader/);
  assert.match(sales, /<ReceivablesModuleHeader active="cartera"/);
  assert.match(collection, /<ReceivablesModuleHeader active="gestiones"/);
  assert.match(navigation, /aria-current=\{active === "cartera" \? "page" : undefined\}/);
  assert.match(navigation, /aria-current=\{active === "gestiones" \? "page" : undefined\}/);
});

test("Cartera conserva el shell durante la carga del contexto", () => {
  assert.match(sales, /receivables-loading-grid/);
  assert.match(sales, /<ReceivablesModuleHeader active="cartera"/);
  assert.match(sales, /aria-busy="true" aria-live="polite"/);
});
