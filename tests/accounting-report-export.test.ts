import assert from "node:assert/strict";
import test from "node:test";
import ExcelJS from "exceljs";
import { PDFDocument } from "pdf-lib";
import { createAccountingExcel, createAccountingPdf, type AccountingReportExport } from "../app/lib/accounting-report-export.ts";

const report: AccountingReportExport = {
  report_type: "trial_balance", starts_on: "2026-07-01", ends_on: "2026-07-31", total: 2,
  rows: [
    { account_id: "a", code: "1000", name: "Caja", account_type: "asset", normal_balance: "debit", opening: 1000, debit: 500, credit: 350, ending_balance: 1150 },
    { account_id: "b", code: "4000", name: "Ventas", account_type: "revenue", normal_balance: "credit", opening: 0, debit: 0, credit: 500, ending_balance: -500 },
  ],
};

test("el Excel financiero conserva metadatos, valores numéricos y formato contable", async () => {
  const bytes = await createAccountingExcel(report, "Empresa de prueba", "MXN");
  assert.equal(Buffer.from(bytes).subarray(0, 2).toString(), "PK");
  const workbook = new ExcelJS.Workbook(); await workbook.xlsx.load(bytes as unknown as Parameters<typeof workbook.xlsx.load>[0]);
  const sheet = workbook.getWorksheet("Reporte"); assert.ok(sheet);
  assert.equal(sheet.getCell("A1").value, "Empresa de prueba");
  assert.equal(sheet.getCell("A2").value, "Balanza de comprobación");
  assert.equal(sheet.getCell("A8").value, "1000");
  assert.equal(sheet.getCell("E8").value, 1000);
  assert.match(String(sheet.getColumn(5).numFmt), /\$#/);
  assert.equal(sheet.views[0]?.state, "frozen");
});

test("el PDF financiero es multipágina, identificable y contiene el reporte", async () => {
  const manyRows = Array.from({ length: 80 }, (_, index) => ({ ...report.rows[index % 2], code: String(1000 + index) }));
  const bytes = await createAccountingPdf({ ...report, rows: manyRows, total: manyRows.length }, "Empresa de prueba", "MXN");
  assert.equal(Buffer.from(bytes).subarray(0, 4).toString(), "%PDF");
  const document = await PDFDocument.load(bytes);
  assert.ok(document.getPageCount() > 1);
  assert.match(document.getTitle() ?? "", /Balanza de comprobación/);
  assert.equal(document.getAuthor(), "Satrapy");
});
