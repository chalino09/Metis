import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607240006_inventory_grouped_by_product.sql", "utf8");

test("inventario pagina y agrupa por producto desde el servidor", () => {
  assert.match(ui, /search_inventory_products_by_location/);
  assert.match(migration, /product_scope as materialized/);
  assert.match(migration, /paged_products as materialized/);
  assert.match(migration, /jsonb_agg\(jsonb_build_object\([\s\S]*'locations', item\.locations/);
});

test("el desglose incluye sucursales accesibles aunque su saldo sea cero", () => {
  assert.match(migration, /cross join accessible_locations/);
  assert.match(migration, /coalesce\(balance\.quantity_on_hand, 0\)/);
  assert.match(ui, /Ver sucursales/);
  assert.match(ui, /positive_location_count/);
});

test("la referencia histórica permanece bajo demanda por sucursal", () => {
  assert.match(ui, /openSnapshotReference\(location\)/);
  assert.match(ui, /get_inventory_snapshot_reference/);
});
