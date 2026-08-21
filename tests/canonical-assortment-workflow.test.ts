import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607230016_canonical_assortment_workflow.sql", "utf8");
const products = readFileSync("app/components/ProductCatalogView.tsx", "utf8");
const commercialization = readFileSync("app/components/ProductCommercializationModal.tsx", "utf8");
const assortments = readFileSync("app/components/CommercialAssortmentsView.tsx", "utf8");
const pos = readFileSync("app/components/SalesModule.tsx", "utf8");
const imports = readFileSync("app/api/imports/stage/[batchId]/actions/route.ts", "utf8");

test("el surtido usa productos, sucursales y UUID canónicos sin crear otra entidad", () => {
  assert.match(migration, /get_sales_assortment_admin_context/);
  assert.match(migration, /get_product_sales_assortment_context/);
  assert.match(migration, /set_product_sales_assortments/);
  assert.doesNotMatch(migration, /create table/);
});

test("la pertenencia comercial no modifica existencias", () => {
  const assignment = migration.slice(
    migration.indexOf("create or replace function public.set_product_sales_assortments"),
    migration.indexOf("create or replace function public.set_sales_assortment_locations"),
  );
  assert.match(assignment, /sales_assortment_items/);
  assert.doesNotMatch(assignment, /inventory_balances|inventory_movements/);
});

test("el alta manual abre una etapa explícita de comercialización", () => {
  assert.match(products, /Ahora define en qué surtidos se ofrecerá/);
  assert.match(products, /ProductCommercializationModal/);
  assert.match(products, /Definir disponibilidad por sucursal/);
  assert.match(products, /Configuración comercial completa/);
  assert.match(commercialization, /Esta decisión no modifica precios ni existencias/);
  assert.match(commercialization, /Sucursales activas/);
});

test("la administración reutiliza un contexto server-side y conserva operaciones masivas", () => {
  assert.match(assortments, /get_sales_assortment_admin_context/);
  assert.match(assortments, /set_sales_assortment_locations/);
  assert.match(assortments, /set_sales_assortment_membership/);
  assert.doesNotMatch(assortments, /\.from\("sales_assortments"\)/);
  assert.doesNotMatch(assortments, /\.from\("locations"\)/);
});

test("POS explica la exclusión del surtido sin convertirla en venta", () => {
  assert.match(migration, /outside_assortment/);
  assert.match(pos, /Fuera del surtido de esta sucursal/);
  assert.match(pos, /Productos no disponibles/);
});

test("la importación de productos aplica un destino masivo en la misma transacción", () => {
  assert.match(imports, /confirm_product_import_with_assortments/);
  assert.match(imports, /p_assortment_ids/);
  assert.match(migration, /v_result := public\.confirm_staged_import/);
  assert.match(migration, /cross join imported_products/);
});
