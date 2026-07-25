import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607180010_fast_inventory_location_search.sql", "utf8");
const groupedMigration = readFileSync(
  "supabase/migrations/202607240006_inventory_grouped_by_product.sql",
  "utf8",
);
const listFunction = migration.split("create or replace function public.get_inventory_snapshot_reference")[0];

test("inventario separa la lista operativa del detalle histórico", () => {
  assert.match(ui, /search_inventory_products_by_location/);
  assert.match(ui, /get_inventory_snapshot_reference/);
  assert.match(ui, /has_snapshot_reference/);
  assert.doesNotMatch(listFunction, /latest_snapshot_per_location/);
  assert.doesNotMatch(listFunction, /difference_from_snapshot', item/);
  assert.doesNotMatch(groupedMigration, /latest_snapshot_per_location/);
  assert.doesNotMatch(groupedMigration, /difference_from_snapshot', row_data/);
});

test("la referencia histórica se limita a una ubicación y un producto", () => {
  assert.match(migration, /snapshot_item\.location_id = p_location_id/);
  assert.match(migration, /snapshot_item\.product_id = p_product_id/);
  assert.match(migration, /limit 1/);
});
