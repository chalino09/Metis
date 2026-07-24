import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  new URL("../supabase/migrations/202607230017_inventory_counts_include_assortment_products.sql", import.meta.url),
  "utf8",
);

test("inventory counts preserve existing balances and include active assortment products", () => {
  assert.match(migration, /from public\.inventory_balances balance/);
  assert.match(migration, /from public\.location_sales_assortments assignment/);
  assert.match(migration, /assortment\.status = 'active'/);
  assert.match(migration, /product\.is_active/);
  assert.match(migration, /product\.is_inventory_tracked/);
});

test("zero-stock assortment products remain non-mutating until count approval", () => {
  assert.match(migration, /coalesce\(balance\.quantity_on_hand, 0\)/);
  assert.doesNotMatch(migration, /insert into public\.inventory_balances/i);
  assert.doesNotMatch(migration, /insert into public\.inventory_ledger/i);
});

test("location assignment validity is respected", () => {
  assert.match(migration, /assignment\.location_id = p_location_id/);
  assert.match(migration, /assignment\.valid_from <= now\(\)/);
  assert.match(migration, /assignment\.valid_to is null or assignment\.valid_to > now\(\)/);
});
