import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const ui=readFileSync("app/components/PurchaseReceiptsModule.tsx","utf8");
const migration=readFileSync("supabase/migrations/202608210001_procurement_receipt_location_inheritance.sql","utf8");

test("la recepción hereda y bloquea la ubicación de la solicitud",()=>{
  assert.match(migration,/join public\.procurement_requisitions requisition/);
  assert.match(migration,/requisition\.folio=v_order\.requisition_reference/);
  assert.match(migration,/'inherited_location_id',v_inherited_location_id/);
  assert.match(migration,/new\.location_id<>v_expected_location_id/);
  assert.match(ui,/locationId:nextCandidate\.inherited_location_id\?\?""/);
  assert.match(ui,/disabled=\{Boolean\(candidate\?\.inherited_location_id\)\}/);
  assert.match(ui,/Heredado de la solicitud de compra\./);
});
