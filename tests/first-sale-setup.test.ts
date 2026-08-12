import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const configuration = readFileSync("app/components/ConfigurationHome.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const assortments = readFileSync("app/components/CommercialAssortmentsView.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608110001_first_sale_setup.sql", "utf8");

test("el inicio de primera venta pertenece al núcleo compartido", () => {
  assert.match(configuration, /label: "Preparar primera venta"/);
  assert.match(configuration, /label: "Productos por sucursal"/);
  assert.doesNotMatch(configuration, /Superficie del producto/);
  assert.doesNotMatch(configuration, /Experiencia por empresa/);
  assert.match(sales, /Inicio compartido/);
  assert.match(sales, /Lista de precios<\/strong> responde cuánto cuesta/);
  assert.match(sales, /Productos por sucursal<\/strong> responde qué se vende y dónde/);
});

test("las denominaciones MXN faltantes se completan en una sola operación auditada", () => {
  for (const value of ["0.50", "1.00", "2.00", "5.00", "10.00", "20.00", "50.00", "100.00", "200.00", "500.00", "1000.00"]) {
    assert.match(migration, new RegExp(`${value.replace(".", "\\.")}::numeric`));
  }
  assert.match(migration, /configure_standard_cash_denominations/);
  assert.match(migration, /on conflict \(company_id, currency_code, value\) do update/);
  assert.match(migration, /cash_denominations\.standard_configured/);
  assert.match(sales, /Completar MXN/);
});

test("crear productos por sucursal no pide código y activa el catálogo", () => {
  assert.doesNotMatch(assortments, /setNewCode|value=\{newCode\}|>Código<input/);
  assert.match(assortments, /p_code: ""/);
  assert.match(assortments, /Crear y activar/);
  assert.match(migration, /next_company_internal_code\(p_company_id, 'SURTIDO'/);
  assert.match(migration, /set status = 'active'/);
});
