import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/202608120010_alpha_sales_missing_sku_review.sql", import.meta.url), "utf8");
const actions = readFileSync(new URL("../app/api/imports/stage/[batchId]/actions/route.ts", import.meta.url), "utf8");
const preview = readFileSync(new URL("../app/api/imports/stage/[batchId]/route.ts", import.meta.url), "utf8");
const interfaceSource = readFileSync(new URL("../app/components/SatrapyApp.tsx", import.meta.url), "utf8");

test("las partidas de ventas sin Clave Prod. se revisan por descripción y unidad dentro de staging", () => {
  assert.match(migration, /get_alpha_sales_missing_sku_review/);
  assert.match(migration, /group by source_description, source_unit/);
  assert.match(migration, /resolve_alpha_sales_missing_sku/);
  assert.match(migration, /source_sku_preserved_as_missing', true/);
  assert.match(migration, /can_import_commercial\(v_batch\.company_id, 'sales'\)/);
});

test("el vínculo masivo actualiza solo el grupo seleccionado y queda auditado", () => {
  assert.match(migration, /and staging_row_id = any\(v_row_ids\)/);
  assert.match(migration, /sales_evidence\.missing_sku_mapped/);
  assert.match(migration, /refresh_import_staging_issue_summary/);
  assert.match(migration, /p_source_unit text default null/);
});

test("el Centro de Migración expone la revisión y no pide una herramienta externa", () => {
  assert.match(actions, /resolve_sales_missing_sku/);
  assert.match(actions, /resolve_alpha_sales_missing_sku/);
  assert.match(preview, /get_alpha_sales_missing_sku_review/);
  assert.match(interfaceSource, /Partidas sin SKU de origen/);
  assert.match(interfaceSource, /Vincular producto/);
  assert.match(interfaceSource, /el dato de origen seguirá vacío y trazable/);
});
