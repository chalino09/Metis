import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607240006_inventory_grouped_by_product.sql", "utf8");
const movementMigration = readFileSync("supabase/migrations/202608040001_inventory_location_movement_history.sql", "utf8");

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

test("una sucursal seleccionada muestra su existencia y movimientos sin expansión redundante", () => {
  assert.match(ui, /const directLocationView = selectedLocation !== "all" \|\| accessibleLocations\.length === 1/);
  assert.match(ui, /directLocationView \? "Existencia" : "Existencia total"/);
  assert.match(ui, /directLocationView \? "Movimiento reciente" : "Sucursales"/);
  assert.match(ui, /directLocation \? <Button variant="secondary" size="sm" aria-label=\{`Ver movimientos de/);
  assert.match(ui, /!directLocation && expanded/);
});

test("la referencia histórica permanece bajo demanda por sucursal", () => {
  assert.match(ui, /openSnapshotReference\(location\)/);
  assert.match(ui, /get_inventory_snapshot_reference/);
});

test("el historial queda dentro de existencias y consulta el ledger por producto y ubicación", () => {
  assert.match(ui, /Ver movimientos/);
  assert.match(ui, /list_inventory_location_movements/);
  assert.match(ui, /<Drawer open=\{Boolean\(movementRow\)\}/);
  assert.match(movementMigration, /has_company_permission\(p_company_id, 'view_inventory'\)/);
  assert.match(movementMigration, /public\.can_access_location\(location_data\.id\)/);
  assert.match(movementMigration, /ledger\.location_id = p_location_id/);
  assert.match(movementMigration, /ledger\.product_id = p_product_id/);
  assert.match(movementMigration, /limit v_size offset/);
});
