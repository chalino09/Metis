import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui = readFileSync("app/components/ProcurementModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608200001_procurement_manual_product_guard.sql", "utf8");
const singleCharacterSearch = readFileSync("supabase/migrations/202608200003_procurement_single_character_product_search.sql", "utf8");

test("la solicitud excepcional busca productos de forma server-side", () => {
  assert.match(ui, /manualProductQuery/);
  assert.match(ui, /query\.length < 1/);
  assert.match(ui, /p_query: query/);
  assert.match(ui, /role="combobox"/);
  assert.match(ui, /aria-activedescendant/);
  assert.match(ui, /ArrowDown/);
  assert.match(ui, /No hay coincidencias/);
});

test("la creación valida fecha y usa una clave idempotente", () => {
  assert.match(ui, /!manual\.targetDate/);
  assert.match(ui, /p_client_request_id: manualRequestId\.current/);
  assert.match(migration, /client_request_id uuid/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /procurement_requisitions_company_request_uidx/);
});

test("el servidor limita las partidas a productos inventariables activos", () => {
  assert.match(migration, /product\.is_active/);
  assert.match(migration, /product\.is_inventory_tracked/);
  assert.match(migration, /procurement_requisition_product_guard/);
});

test("una letra usa búsqueda por prefijo con límite server-side", () => {
  assert.match(singleCharacterSearch, /length\(v_query\) = 1/);
  assert.match(singleCharacterSearch, /like v_query \|\| '%'/);
  assert.match(singleCharacterSearch, /limit v_limit/);
  assert.match(singleCharacterSearch, /create_procurement_requisitions/);
});
