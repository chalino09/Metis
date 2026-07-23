import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202607180008_inventory_transfer_canonical_builder.sql", "utf8");
const productSearchMigration = readFileSync("supabase/migrations/202607180009_fast_inventory_transfer_product_search.sql", "utf8");

test("la operación diaria usa un constructor visual con existencia del origen", () => {
  assert.match(ui, /Nueva transferencia/);
  assert.match(ui, /search_inventory_transfer_products/);
  assert.match(ui, /if \(queryError\) \{[\s\S]*search_inventory_balances/);
  assert.match(ui, /available_quantity/);
  assert.match(ui, /Preparar transferencia/);
  assert.match(ui, /Confirmar recepción completa/);
  assert.match(ui, /Importar partidas/);
});

test("el selector consulta solo la existencia necesaria para transferir", () => {
  assert.match(productSearchMigration, /balance\.quantity_on_hand > 0/);
  assert.match(productSearchMigration, /limit v_limit/);
  assert.doesNotMatch(productSearchMigration, /inventory_snapshot_items/);
  assert.doesNotMatch(productSearchMigration, /inventory_ledger/);
  assert.doesNotMatch(productSearchMigration, /count\(\*\)/);
});

test("el constructor envía identidades canónicas en un solo lote server-side", () => {
  assert.match(ui, /create_inventory_transfer_items/);
  assert.match(ui, /product_id: line\.product_id/);
  assert.match(migration, /jsonb_to_recordset\(p_lines\) input\(product_id uuid, quantity numeric\)/);
  assert.match(migration, /v_received > 500/);
  assert.match(migration, /insert into public\.inventory_transfer_lines[\s\S]*select v_transfer_id, input\.product_id/);
  assert.doesNotMatch(migration, /for\s+v_line\s+in/i);
});
