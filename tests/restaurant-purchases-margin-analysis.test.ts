import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration=readFileSync(new URL("../supabase/migrations/202608230004_restaurant_purchases_margin_analysis.sql",import.meta.url),"utf8");
const runtimeRepair=readFileSync(new URL("../supabase/migrations/202608230005_restaurant_margin_runtime_repairs.sql",import.meta.url),"utf8");
const receipts=readFileSync(new URL("../app/components/RestaurantPurchaseReceiptsView.tsx",import.meta.url),"utf8");
const analysis=readFileSync(new URL("../app/components/RestaurantCostAnalysis.tsx",import.meta.url),"utf8");
const experience=readFileSync(new URL("../app/lib/product-experience.ts",import.meta.url),"utf8");

test("restaurant purchase confirmation is transactional, bounded and idempotent",()=>{
  assert.match(migration,/jsonb_array_length\(p_lines\) not between 1 and 100/);
  assert.match(migration,/client_request_id=p_client_request_id/);
  assert.match(migration,/confirm_purchase_receipt\(p_company_id,v_receipt_id,gen_random_uuid\(\)\)/);
  assert.match(migration,/restaurant\.purchase_received/);
  assert.match(receipts,/confirm_restaurant_purchase_receipt/);
  assert.match(receipts,/inventario y costo actualizados/);
});

test("restaurant weekly analysis includes cost changes and projected and realized margin",()=>{
  assert.match(migration,/purchase_receipt_cost_changes/);
  assert.match(migration,/projected_margin_percent/);
  assert.match(migration,/realized_margin_percent/);
  assert.match(analysis,/Variación de precios de insumos/);
  assert.match(analysis,/Rentabilidad por platillo/);
});

test("margin policies create persistent BI alerts and restaurant navigation exposes both flows",()=>{
  assert.match(migration,/restaurant_dish_margin_below_threshold/);
  assert.match(migration,/bi_store_detected_alert/);
  assert.match(migration,/set_restaurant_margin_threshold/);
  assert.match(experience,/"purchase_receipts"/);
  assert.match(experience,/"restaurant_costs"/);
});

test("runtime repair tolerates dishes without recipes and evaluates fresh costs immediately",()=>{
  assert.match(runtimeRepair,/case when active_version\.id is null then null else public\.culinary_version_cost/);
  assert.match(runtimeRepair,/culinary_version_cost\(active_version\.id,active_version\.portion_count,clock_timestamp\(\)/);
  assert.match(runtimeRepair,/notify pgrst,'reload schema'/);
});
