import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  "supabase/migrations/202608120018_optimize_bi_sale_margin_coverage.sql",
  "utf8",
);

test("la cobertura de margen resuelve acceso una vez y usa fechas indexables", () => {
  assert.match(migration, /accessible_locations as materialized/);
  assert.match(migration, /selected_sales as materialized/);
  assert.match(migration, /join accessible_locations location_access/);
  assert.match(migration, /completed_at>=p_date_from::timestamptz/);
  assert.match(migration, /completed_at<\(p_date_to\+1\)::timestamptz/);
  assert.doesNotMatch(migration, /completed_at::date/);
  assert.doesNotMatch(migration, /can_access_location\(sale_data\.location_id\)/);
});

test("la optimización de margen no escribe documentos POS", () => {
  assert.doesNotMatch(migration, /delete\s+from\s+public\.(?:sales|sale_items|canonical_tickets)/i);
  assert.doesNotMatch(migration, /update\s+public\.(?:sales|sale_items|canonical_tickets)/i);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.(?:sales|sale_items|canonical_tickets)/i);
});
