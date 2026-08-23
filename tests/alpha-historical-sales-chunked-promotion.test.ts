import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const route = readFileSync("app/api/imports/stage/[batchId]/actions/route.ts", "utf8");
const ui = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608120017_chunked_alpha_historical_sales_promotion.sql", "utf8");
const taxFix = readFileSync("supabase/migrations/202608120018_fix_alpha_historical_sales_tax_fallback.sql", "utf8");

test("el historial de ventas usa bloques server-side acotados", () => {
  assert.match(route, /promote_alpha_historical_sales_chunk/);
  assert.match(route, /p_chunk_size:[\s\S]*750/);
  assert.match(migration, /least\(greatest\(coalesce\(p_chunk_size,750\),100\),1000\)/);
  assert.match(migration, /for update/);
  assert.match(migration, /on conflict \(company_id,source_import_batch_id,source_document_key\)/);
  assert.match(migration, /status='completed'/);
  assert.match(migration, /cash_movements_created',0/);
});

test("el fallback fiscal no confunde descuento con impuesto y respeta documentos inmutables", () => {
  const helper = taxFix.match(/create or replace function public\.alpha_historical_sales_lines[\s\S]*?\n\$\$;/)?.[0] ?? "";
  assert.ok(helper);
  assert.doesNotMatch(helper, /normalized_data->>'discountAmount'/);
  assert.match(helper, /normalized_data->>'lineTotal'[\s\S]*normalized_data->>'unitPrice'[\s\S]*normalized_data->>'quantity'/);
  assert.match(taxFix, /where progress\.status='processing'/);
  assert.match(taxFix, /sales_history\.tax_interpretation_boundary/);
  assert.match(taxFix, /canonical_documents_mutated',false/);
  assert.match(taxFix, /immutable\.taxable_amount\+pending\.taxable_amount/);
  assert.doesNotMatch(taxFix, /delete\s+from\s+public\.(?:canonical_tickets|sale_item_taxes|sale_items|sales)/i);
  assert.doesNotMatch(taxFix, /update\s+public\.(?:canonical_tickets|sale_item_taxes|sale_items|sales)/i);
});

test("el modal muestra avance, evita doble envío y permite reanudar", () => {
  assert.match(ui, /actionRequestInFlight\.current/);
  assert.match(ui, /while \(result\.status !== "completed"\)/);
  assert.match(ui, /setPromotionProgress\(result\)/);
  assert.match(ui, /Reanudar importación/);
  assert.match(ui, /role="status"/);
  assert.match(ui, /aria-live="polite"/);
  assert.match(ui, /closeDisabled=\{busy\}/);
});
