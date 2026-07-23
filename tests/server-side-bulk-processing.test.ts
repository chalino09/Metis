import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202607180007_server_side_bulk_processing.sql", "utf8");
const customerRoute = readFileSync("app/api/imports/customer-migration/[batchId]/promote/route.ts", "utf8");
const customerUi = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const purchaseOrders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");

function functionBody(name: string) {
  const match = migration.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\n\\$\\$;`, "i"));
  assert.ok(match, `No se encontró ${name}`);
  return match[0];
}

test("cada solicitud de importación procesa un solo bloque reanudable", () => {
  assert.doesNotMatch(customerRoute, /for\s*\(let chunk/);
  assert.match(customerRoute, /p_limit: 200/);
  assert.match(customerRoute, /status: \(result\.remaining_customers \?\? 0\) > 0 \? 202 : 200/);
  assert.match(customerUi, /Continuar importación/);
  assert.match(customerUi, /Quedan \$\{remaining\}/);

  assert.doesNotMatch(purchaseOrders, /while\s*\(status\s*===\s*"in_progress"\)/);
  assert.match(purchaseOrders, /p_page_size:25/);
  assert.match(purchaseOrders, /Continuar promoción/);
});

test("el posteo del conteo físico escribe saldos y ledger por conjuntos", () => {
  const body = functionBody("decide_inventory_count");
  assert.doesNotMatch(body, /for\s+v_line\s+in/i);
  assert.match(body, /insert into public\.inventory_balances[\s\S]*select v_count\.company_id/);
  assert.match(body, /on conflict\(location_id, product_id\) do update/);
  assert.match(body, /insert into public\.inventory_ledger[\s\S]*from public\.inventory_count_lines/);
  assert.match(body, /for update of balance/);
});

test("FIFO aplica cientos de documentos con una asignación de ventana", () => {
  const helper = functionBody("apply_receivable_payment_fifo_set");
  const payment = functionBody("record_receivable_payment");
  assert.match(helper, /sum\(item\.outstanding_amount\) over/);
  assert.match(helper, /for update of receivable/);
  assert.match(helper, /insert into public\.receivable_payment_applications[\s\S]*select p_payment_id/);
  assert.match(helper, /if round\(v_applied, 2\) <> v_amount/);
  assert.doesNotMatch(payment, /for\s+v_receivable\s+in/i);
  assert.match(payment, /apply_receivable_payment_fifo_set/);
  assert.match(payment, /client_request_id = v_request_id/);
});

test("las propuestas CxP validan, bloquean e insertan muchas líneas server-side", () => {
  const body = functionBody("save_supplier_payment_proposal");
  assert.doesNotMatch(body, /for\s+v_line\s+in/i);
  assert.match(body, /jsonb_to_recordset\(p_lines\)/);
  assert.match(body, /order by payable\.id[\s\S]*for update of payable/);
  assert.match(body, /insert into public\.supplier_payment_proposal_lines[\s\S]*select p_company_id/);
  assert.match(body, /pg_advisory_xact_lock/);
  assert.match(body, /line_count', v_line_count/);
});

