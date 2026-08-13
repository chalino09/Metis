import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { parseAlphaWorkbook } from "../app/lib/alpha.ts";
import { buildStagingPayload } from "../app/lib/import-staging.ts";
import { deriveDominantWarehouseByCode } from "../app/lib/import-validation.ts";
import type { SaleRecord } from "../app/lib/types.ts";

function salesWorkbook() {
  const rows: Array<Array<string | number>> = [[], [], [], []];
  const header = Array<string>(47).fill("");
  header[0] = "Fecha Alta"; header[3] = "Folio"; header[5] = "Sucursal"; header[9] = "Cliente"; header[11] = "Nombre";
  header[23] = "Almacén"; header[41] = "Status"; header[46] = "Factura";
  const detail = Array<string>(47).fill("");
  detail[0] = "Clave Prod."; detail[5] = "Descripción"; detail[16] = "Unidad"; detail[19] = "Cantidad";
  detail[22] = "Pr. Unitario"; detail[28] = "Dcto"; detail[32] = "Importe"; detail[37] = "Total"; detail[39] = "Descuentos %"; detail[46] = "Lote";
  rows.push(header, detail);
  const sale = Array<string | number>(47).fill("");
  sale[0] = "01/07/2026"; sale[3] = "2934"; sale[5] = "AQX"; sale[9] = "3285"; sale[11] = "PUBLICO EN GENERAL"; sale[23] = "AQUIXTLA"; sale[41] = "Pagada"; sale[46] = "2756";
  const line = Array<string | number>(47).fill("");
  line[0] = "AC10171"; line[5] = "PIJA HEXAGONAL"; line[16] = "PZA"; line[19] = 2; line[22] = 17.4; line[32] = 34.8; line[37] = 34.8; line[46] = "LOTE-1";
  rows.push(sale, line);
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet(rows), "Notas de venta");
  return XLSX.write(workbook, { type: "array", bookType: "biff8" }) as ArrayBuffer;
}

test("nvtadesg se detecta y conserva una partida como evidencia, sin inferir cobro", async () => {
  const parsed = await parseAlphaWorkbook(salesWorkbook(), "nvtadesg_20260708_0016RD.XLS", "local_development");
  assert.equal(parsed.importKind, "sales");
  assert.equal(parsed.snapshotDate, "2026-07-08");
  assert.equal(parsed.sales.length, 1);
  assert.deepEqual(parsed.sales[0] && {
    saleDate: parsed.sales[0].saleDate, sourceFolio: parsed.sales[0].sourceFolio,
    locationCode: parsed.sales[0].locationCode, alphaSku: parsed.sales[0].alphaSku, lineTotal: parsed.sales[0].lineTotal,
  }, { saleDate: "2026-07-01", sourceFolio: "2934", locationCode: "AQX", alphaSku: "AC10171", lineTotal: 34.8 });
  const payload = buildStagingPayload(parsed);
  assert.equal(payload.rows[0]?.detected_type, "sales");
  assert.equal(payload.rows[0]?.normalized_data.evidenceKind, "sale_line");
  assert.equal(payload.rows[0]?.normalized_data.evidenceOnly, true);
  assert.equal("paymentMethod" in (payload.rows[0]?.normalized_data ?? {}), false);
});

test("deriva el almacén dominante de una abreviatura sin codificar aliases de empresa", () => {
  const rows = [
    { locationCode: "AQX", warehouseName: "AQUIXTLA" },
    { locationCode: "AQX", warehouseName: "AQUIXTLA" },
    { locationCode: "AQX", warehouseName: "CHIGNA" },
    { locationCode: "CUA", warehouseName: "CUAPA" },
  ] as SaleRecord[];
  const dominant = deriveDominantWarehouseByCode(rows);
  assert.equal(dominant.get("AQX"), "AQUIXTLA");
  assert.equal(dominant.get("CUA"), "CUAPA");
});
