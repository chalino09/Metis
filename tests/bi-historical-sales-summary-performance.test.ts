import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(
  "supabase/migrations/202608120017_optimize_bi_historical_sales_summary.sql",
  "utf8",
);

test("el resumen histórico agrega cada fuente una vez y usa rangos indexables", () => {
  assert.match(migration, /sales_company_currency_completed_idx/);
  assert.match(migration, /sales_daily as materialized/);
  assert.match(migration, /collections_daily as materialized/);
  assert.match(migration, /supplier_payments_daily as materialized/);
  assert.match(migration, /completed_at>=v_previous_from::timestamptz/);
  assert.match(migration, /completed_at<\(p_date_to\+1\)::timestamptz/);
  assert.doesNotMatch(migration, /completed_at::date=d\.series_date/);
});

test("las gráficas resuelven acceso por ubicación antes de leer ventas", () => {
  const charts = migration.match(
    /create or replace function public\.bi_get_executive_charts_before_recognized_cost[\s\S]*?\nend \$\$;/,
  )?.[0] ?? "";
  const salesBlock = charts.match(
    /if v_sales_available and v_currency is not null then[\s\S]*?\n  end if;/,
  )?.[0] ?? "";
  assert.ok(charts);
  assert.ok(salesBlock);
  assert.match(salesBlock, /accessible_locations as materialized/);
  assert.match(salesBlock, /join accessible_locations location_access/);
  assert.doesNotMatch(salesBlock, /can_access_location\(sale_data\.location_id\)/);
});

test("la optimización BI es de solo lectura sobre documentos POS", () => {
  assert.doesNotMatch(migration, /delete\s+from\s+public\.(?:sales|sale_items|canonical_tickets)/i);
  assert.doesNotMatch(migration, /update\s+public\.(?:sales|sale_items|canonical_tickets)/i);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.(?:sales|sale_items|canonical_tickets)/i);
});
