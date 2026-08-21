import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sales = readFileSync("app/components/SalesModule.tsx", "utf8");

test("la política explica su alcance y deja visible la prioridad comercial", () => {
  assert.match(sales, /todas las sucursales/);
  assert.match(sales, /precios escalonados y los descuentos especiales sustituyen esta política/);
  assert.match(sales, /Revisar precios de productos/);
});

test("la configuración exige tres rangos consecutivos antes de guardar", () => {
  assert.match(sales, /Configura los tres niveles de la política/);
  assert.match(sales, /Los rangos deben ser consecutivos, sin huecos ni traslapes/);
  assert.match(sales, /Cada nivel debe ofrecer un descuento mayor al anterior/);
  assert.match(sales, /disabled=\{loading \|\| Boolean\(validationError\)\}/);
  assert.match(sales, /Cambios sin aplicar/);
});

test("el estado vacío explica la política antes de iniciar la captura", () => {
  assert.match(sales, /Configura tres rangos consecutivos\. El último puede quedar sin límite/);
  assert.match(sales, /Configurar 3 niveles/);
});
