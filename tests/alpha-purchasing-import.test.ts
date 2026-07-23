import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { parseAlphaPurchasingMigration } from "../app/lib/alpha-purchasing-migration.ts";

type Cell = string | number | Date;

function workbook(name: string, rows: Cell[][]) {
  const book = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(book, XLSX.utils.aoa_to_sheet(rows), "sheet1");
  return new File([XLSX.write(book, { type: "array", bookType: "biff8" }) as ArrayBuffer], name);
}

function baseRows(length: number) {
  const rows = Array.from({ length }, () => [] as Cell[]);
  rows[1] = ["Fecha:", "", "", new Date("2026-07-08T12:00:00Z")];
  return rows;
}

test("agrupa proveedores, órdenes, CxP y pagos sin inventar recepciones", async () => {
  const supplierRows = baseRows(7);
  supplierRows[4] = [1, "", "", "", "PROVEEDOR UNO", "", "", "", "", "", "", "CALLE 1", "", "", "", "", "", "", "CENTRO", "", "", "", "PUEBLA", "", "PUEBLA"];
  supplierRows[5] = ["Proveedor", "", "", "", "", "Tipo de Proveedor", "", "", "NAL", "R.F.C.", "", "AAA010101AAA", "", "", "Lada", "", "Telefonos", "2220000000"];

  const orderRows = baseRows(9);
  orderRows[6] = [new Date("2026-07-01T12:00:00Z"), "", "", "", 10, "CUA", "", 1, "", "", "PROVEEDOR UNO", "", "", "", "", "", "", "", "", "GENERAL", "", "", "", "", "", "", "PESOS", "", "", "", "", 0, "", 1, "", "", "", "", "Por Surtir", "", "", "", "Aceptada"];
  orderRows[7] = ["CLASE", "", "", "", "SKU-1", "", "", "PRODUCTO UNO", "", "", "", "", "", "", "", "", "", "PZA", "", "", "", "", "", "", "", 2, "", "", "", 50, "", "", "", "", 0, "", "", 0, "", "", new Date("2026-07-10T12:00:00Z")];

  const payableRows = baseRows(8);
  payableRows[6] = ["FAC-1", "", "", "", "", "", "", "", "", 1, "PROVEEDOR UNO", "", "", "", "", new Date("2026-07-01T12:00:00Z"), "", new Date("2026-07-31T12:00:00Z"), "", "", "", "Factura", "", "", "", 100, "", "", "", "", "PESOS"];
  payableRows[7] = ["NC-1", "", "", "", "", "", "", "", "", 1, "PROVEEDOR UNO", "", "", "", "", new Date("2026-07-02T12:00:00Z"), "", new Date("2026-07-31T12:00:00Z"), "", "", "", "Nota", "", "", "", -10, "", "", "", "", "PESOS"];

  const paymentRows = baseRows(9);
  paymentRows[6] = [5, "", "", "", "CUA", "", new Date("2026-07-03T12:00:00Z"), "", "", "F", "FAC-1", "", "", "", "", "PROVEEDOR UNO", "", "", "", "", "", 40, "Efectivo", "", "", "", "", "", "", "", "P"];
  paymentRows[7] = ["", "", "", "", "CUA", "", "", "", "", "F", "FAC-X", "", "", "", "", "NOMBRE SIN CATALOGO", "", "", "", "", "", 15, "Transferencia", "", "", "", "", "", "", "", "P"];

  const payload = await parseAlphaPurchasingMigration([
    workbook("cata_prv_20260708.xls", supplierRows),
    workbook("rpcon2_20260708.xls", orderRows),
    workbook("lfchvenc_20260708.xls", payableRows),
    workbook("pag_det_20260708.xls", paymentRows),
  ]);

  assert.equal(payload.suppliers.length, 1);
  assert.equal(payload.suppliers[0]?.tax_id, "AAA010101AAA");
  assert.equal(payload.suppliers[0]?.supplier_type, "NAL");
  assert.equal(payload.suppliers[0]?.phone, "2220000000");
  assert.equal(payload.purchaseOrders.length, 1);
  assert.equal(payload.purchaseOrderLines.length, 1);
  assert.equal(payload.payableDocuments.length, 2);
  assert.equal(payload.supplierPayments.length, 2);
  assert.equal(payload.supplierPayments[0]?.matched_supplier_external_code, "1");
  assert.equal(payload.supplierPayments[1]?.matched_supplier_external_code, null);
  assert.equal(payload.summary.payable_outstanding_total, 90);
  assert.equal(payload.summary.receipt_source_available, false);
  assert.equal(payload.differences.some((item) => item.difference_code === "RECEIPT_SOURCE_NOT_AVAILABLE"), true);
  assert.equal(payload.differences.some((item) => item.difference_code === "SUPPLIER_CREDIT_BALANCE_REQUIRES_CLASSIFICATION"), true);
  assert.equal(payload.differences.some((item) => item.difference_code === "PAYMENT_SUPPLIER_UNRESOLVED"), true);
  assert.equal(payload.differences.some((item) => item.severity === "error"), false);
});

test("lee RFC y teléfono cuando cata_prv deja una fila en blanco antes del detalle", async () => {
  const supplierRows = baseRows(9);
  supplierRows[4] = [1, "", "", "", "PROVEEDOR DOS", "", "", "", "", "", "", "CALLE 2"];
  supplierRows[5] = [];
  supplierRows[6] = ["Proveedor", "", "", "", "", "Tipo de Proveedor", "", "", "NAL", "R.F.C.", "", "BBB010101BBB", "", "", "Lada", "", "Telefonos", "5550000000"];
  const payload = await parseAlphaPurchasingMigration([workbook("cata_prv_20260708.xls", supplierRows)]);
  assert.equal(payload.suppliers[0]?.tax_id, "BBB010101BBB");
  assert.equal(payload.suppliers[0]?.phone, "5550000000");
});

test("rechaza archivos de cortes distintos", async () => {
  const first = baseRows(7);
  first[4] = [1, "", "", "", "PROVEEDOR"];
  first[5] = ["Proveedor"];
  const second = baseRows(8);
  second[1] = ["Fecha:", "", "", new Date("2026-07-09T12:00:00Z")];
  second[6] = ["FAC", "", "", "", "", "", "", "", "", 1, "PROVEEDOR", "", "", "", "", new Date("2026-07-01T12:00:00Z"), "", new Date("2026-07-31T12:00:00Z"), "", "", "", "Factura", "", "", "", 10, "", "", "", "", "PESOS"];
  await assert.rejects(() => parseAlphaPurchasingMigration([workbook("cata_prv_a.xls", first), workbook("lfchvenc_b.xls", second)]), /misma fecha de corte/);
});
