import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const quotes = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const receipts = readFileSync("app/components/PurchaseReceiptsModule.tsx", "utf8");
const requisitions = readFileSync("app/components/ProcurementModule.tsx", "utf8");
const migration = readFileSync("supabase/migrations/202608200005_procurement_requisition_destination_for_receipts.sql", "utf8");
const destinationChangeMigration = readFileSync("supabase/migrations/202608200006_procurement_requisition_destination_change.sql", "utf8");

test("el destino sólo se puede cambiar desde la solicitud antes de cotizar", () => {
  assert.match(requisitions, /change_procurement_requisition_destination/);
  assert.match(requisitions, /Cambiar destino/);
  assert.match(requisitions, /detail\.quotes\.length === 0/);
  assert.match(destinationChangeMigration, /status in \('draft','quoting'\)/);
  assert.match(destinationChangeMigration, /La solicitud ya tiene cotizaciones; no puede cambiar destino\./);
  assert.match(destinationChangeMigration, /available_quantity_snapshot=coalesce/);
  assert.match(destinationChangeMigration, /procurement\.requisition_destination_changed/);
});

test("la cotización muestra el destino heredado y no permite editarlo", () => {
  assert.match(quotes, /destination_location_name:selected\.location_name/);
  assert.match(quotes, /Destino de entrega/);
  assert.match(quotes, /Heredado de la solicitud; no se modifica desde la cotización\./);
  assert.match(quotes, /readOnly value=\{draft\.destination_location_name\}/);
});

test("la recepción toma y bloquea el destino de la solicitud vinculada", () => {
  assert.match(migration, /destination_location_id/);
  assert.match(migration, /procurement_purchase_orders/);
  assert.match(migration, /procurement_requisitions/);
  assert.match(receipts, /locationId:nextCandidate\.inherited_location_id\?\?""/);
  assert.match(receipts, /Almacén de recepción/);
  assert.match(receipts, /Heredado de la solicitud de compra\./);
});
