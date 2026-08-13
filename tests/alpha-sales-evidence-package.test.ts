import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/202608120005_alpha_sales_evidence_package.sql", import.meta.url), "utf8");
const stageAll = readFileSync(new URL("../app/api/imports/stage-all/route.ts", import.meta.url), "utf8");
const upload = readFileSync(new URL("../app/lib/import-upload-staging.ts", import.meta.url), "utf8");
const interfaceSource = readFileSync(new URL("../app/components/SatrapyApp.tsx", import.meta.url), "utf8");
const stagedBatchesRoute = readFileSync(new URL("../app/api/imports/staged-batches/route.ts", import.meta.url), "utf8");

test("ventas y cobranza comparten un paquete persistente por empresa y corte", () => {
  assert.match(migration, /begin_alpha_sales_evidence_file/);
  assert.match(migration, /b\.snapshot_date=p_cutoff_date/);
  assert.match(migration, /p_source_kind not in \('sales','collections'\)/);
  assert.match(migration, /has_sales/);
  assert.match(migration, /has_collections/);
  assert.match(migration, /Paquete 2\/2 conciliado como evidencia/);
});

test("la conciliación se mantiene en staging y no promueve operaciones", () => {
  assert.match(migration, /evidenceKind'='sale_line'/);
  assert.match(migration, /evidenceKind'='collection'/);
  assert.match(migration, /promotion_enabled',false/);
  assert.doesNotMatch(migration, /insert\s+into\s+public\.(sales|sale_payments|cash_movements|inventory_movements)/i);
});

test("cob_cte puede cargarse solo o junto con el paquete de clientes", () => {
  assert.match(stageAll, /salesCollectionFiles\.push\(file\)/);
  assert.match(stageAll, /stageAlphaSalesCollectionUpload/);
  assert.match(upload, /p_source_kind:\s*"collections"/);
  assert.match(upload, /evidenceKind:\s*"collection"/);
});

test("la interfaz informa claramente 1 de 2 y 2 de 2", () => {
  assert.match(interfaceSource, /1\/2 archivos detectado/);
  assert.match(interfaceSource, /2\/2 archivos conciliados/);
  assert.match(interfaceSource, /Falta cob_cte/);
  assert.match(interfaceSource, /Falta nvtadesg/);
  assert.match(interfaceSource, /if \(batchId\) await loadPreview\(batchId, batchId === activeBatchId \? page : 1\)/);
  assert.match(stagedBatchesRoute, /filesByBatch\.get\(batch\.id\)/);
  assert.match(stagedBatchesRoute, /\.from\("import_files"\)/);
  assert.match(interfaceSource, /batch\.import_files\.map\(\(file\) => file\.original_name\)\.join\(" \+ "\)/);
  assert.match(interfaceSource, /className="inline-status upload-processing" role="status"/);
  assert.match(interfaceSource, /loadingPreview && !busy/);
});
