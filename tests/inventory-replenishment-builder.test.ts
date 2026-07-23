import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607200001_inventory_replenishment_canonical_builder.sql", "utf8");

test("reabastecimiento reutiliza el constructor visual con selección múltiple", () => {
  assert.match(ui, /Configurar mínimos y máximos/);
  assert.match(ui, /search_inventory_replenishment_products/);
  assert.match(ui, /selectedProductIds/);
  assert.match(ui, /Agregar seleccionados/);
  assert.match(ui, />Cerrar<\/Button>/);
  assert.match(ui, /useDismissiblePopover\(productPickerRef, productPickerOpen/);
  assert.match(ui, /Aplicar a todas/);
  assert.match(ui, /Importar políticas/);
  assert.match(ui, /Guardar políticas/);
});

test("el constructor guarda identidades canónicas en un lote server-side", () => {
  assert.match(ui, /configure_inventory_replenishment_policy_items/);
  assert.match(ui, /product_id: line\.product_id/);
  assert.match(migration, /jsonb_to_recordset\(p_lines\) input\([\s\S]*product_id uuid/);
  assert.match(migration, /v_received > 500/);
  assert.match(migration, /on conflict \(location_id, product_id\) do update/);
  assert.doesNotMatch(migration, /for\s+\w+\s+in/i);
});

test("la mejora permanece aislada de inventario, compras y costos", () => {
  assert.doesNotMatch(migration, /insert into public\.inventory_ledger/i);
  assert.doesNotMatch(migration, /update public\.inventory_balances/i);
  assert.doesNotMatch(migration, /insert into public\.inventory_transfers/i);
  assert.doesNotMatch(migration, /purchase_orders|purchase_receipts|product_costs/i);
});
