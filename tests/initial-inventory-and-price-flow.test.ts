import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const prices = readFileSync("app/components/PriceCatalogManagement.tsx", "utf8");
const primitives = readFileSync("app/components/ui/primitives.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608110002_manual_inventory_opening.sql", "utf8");

test("el inventario inicial se registra por lote, una vez y dentro del núcleo", () => {
  assert.match(app, /Registrar inventario inicial/);
  assert.match(app, /p_lines: lines/);
  assert.match(migration, /jsonb_array_length\(p_lines\)>500/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /inventory\.manual_opening_registered/);
  assert.match(migration, /movement_type='opening_manual'/);
  assert.match(migration, /Esta ubicación ya tiene movimientos/);
  assert.doesNotMatch(migration, /Restaurante Cuapancingo|SUC-001/);
});

test("precios explica la secuencia y mantiene el IVA canónico del producto", () => {
  assert.match(prices, /Crear la lista/);
  assert.match(prices, /Capturar precios e IVA/);
  assert.match(prices, /Asignar a sucursales/);
  assert.match(prices, /El IVA viene de cada producto/);
  assert.match(prices, /href="\/satrapy\/inventario\/productos"/);
  assert.doesNotMatch(prices, /save_tax_category|tax_category_id/);
});

test("datetime-local usa el calendario y la hora de Satrapy", () => {
  assert.match(primitives, /props\.type === "datetime-local"/);
  assert.match(primitives, /function DateTimeInput/);
  assert.match(primitives, /satrapy-datetime-time/);
  assert.match(primitives, /<DateInput/);
});
