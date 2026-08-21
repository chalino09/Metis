import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const moduleSource = readFileSync("app/components/SupplierInvoicesModule.tsx", "utf8");
const primitives = readFileSync("app/components/ui/primitives.tsx", "utf8");
const styles = readFileSync("app/globals.css", "utf8");

test("Facturas y CxP diferencia navegación principal y secundaria", () => {
  assert.match(moduleSource, /data-active-tab=\{tab\}/);
  assert.match(moduleSource, /className="supplier-invoice-primary-tabs" ariaLabel="Secciones de Facturas y CxP"/);
  assert.match(moduleSource, /className="supplier-invoice-secondary-tabs" ariaLabel="Secciones de pagos"/);
  assert.match(primitives, /ariaLabel = "Secciones"/);
  assert.match(primitives, /aria-label=\{ariaLabel\}/);
});

test("los filtros quedan separados de la selección activa", () => {
  assert.match(styles, /\.supplier-invoice-module > \* \{ order:7; \}/);
  assert.match(styles, /\.supplier-invoice-module > \.data-toolbar \{ order:5; margin:0 0 24px;/);
  assert.match(styles, /data-active-tab="payments"\] > \.supplier-payments-list-heading \{ order:4;/);
  assert.match(styles, /\.payment-proposal-filters\.compact \{ grid-template-columns:repeat\(3,minmax\(150px,1fr\)\); \}/);
  assert.match(styles, /\.supplier-invoice-primary-tabs \.ui-tabs \{/);
  assert.match(styles, /\.supplier-invoice-secondary-tabs \.ui-tabs \{/);
  assert.match(styles, /content:"Buscar facturas"/);
  assert.match(styles, /content:"Estado"/);
  assert.match(styles, /padding:8px 12px 7px;/);
  assert.match(styles, /grid-column:1 \/ -1;\n  content:"Filtros"/);
  assert.match(styles, /\.supplier-invoice-module \.ui-tabs__trigger:focus-visible/);
});

test("CxP agrupa cada título con su contenido", () => {
  assert.match(moduleSource, /className="supplier-payables-section"/);
  assert.match(moduleSource, /<h2>Resumen de antigüedad<\/h2>/);
  assert.match(moduleSource, /aria-label="Resumen de antigüedad"/);
  assert.match(moduleSource, /<h2>Vencimientos y saldos<\/h2>/);
});
