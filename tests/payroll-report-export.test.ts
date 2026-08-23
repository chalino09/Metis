import assert from "node:assert/strict";
import test from "node:test";
import ExcelJS from "exceljs";
import { createPayrollPeriodExcel, createPayrollReceiptExcel } from "../app/lib/payroll-report-export.ts";

test("el reporte de nómina conserva pagos e incidencias retroactivas", async () => {
  const bytes = await createPayrollPeriodExcel(
    { starts_on: "2026-08-03", ends_on: "2026-08-09", payment_state: "paid", has_adjustments: true },
    [{
      collaborator_name_snapshot: "Ana Pérez", base_pay_snapshot: 5000, additions_total: 500,
      reductions_total: 100, total_pay: 5400, payment_method: "transfer",
      concepts: [
        { label: "Sueldo base", concept_code: "base_pay", direction: "addition", amount: 5000, source_date: "2026-08-03" },
        { label: "Bono", concept_code: "bonus", direction: "addition", amount: 500, source_date: "2026-08-03", calculation_metadata: { occurred_on: "2026-07-31", retroactive: true } },
      ],
    }],
    [{ payment_method: "transfer", payment_date: "2026-08-10", payment_reference: "SPEI-123", total_amount: 5400 }],
  );

  assert.equal(Buffer.from(bytes).subarray(0, 2).toString(), "PK");
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(bytes as unknown as Parameters<typeof workbook.xlsx.load>[0]);
  const summary = workbook.getWorksheet("Nómina");
  const incidents = workbook.getWorksheet("Incidencias");
  const daily = workbook.getWorksheet("Detalle por fecha");
  const receipts = workbook.getWorksheet("Recibos");
  assert.ok(summary);
  assert.ok(incidents);
  assert.ok(daily);
  assert.ok(receipts);
  assert.match(String(summary.getCell("A2").value), /Nómina pagada · Con ajustes/);
  assert.equal(summary.getCell("G5").value, "2026-08-10");
  assert.equal(summary.getCell("I5").value, "SPEI-123");
  assert.equal(incidents.getCell("F2").value, "2026-07-31");
  assert.equal(incidents.getCell("G2").value, "Sí");
  assert.equal(daily.getCell("A5").value, "Ana Pérez");
  assert.equal(daily.getCell("C5").value, 5000);
  assert.match(String(daily.getCell("I5").value), /Bono/);
  assert.equal(receipts.getCell("A3").value, "Colaborador");
  assert.equal(receipts.getCell("B3").value, "Ana Pérez");
  assert.equal(receipts.getCell("A10").value, "Pago neto");
  assert.equal(receipts.getCell("C10").value, 5400);
});

test("el recibo individual sólo incluye al colaborador seleccionado", async () => {
  const bytes = await createPayrollReceiptExcel(
    { starts_on: "2026-08-03", ends_on: "2026-08-09", payment_state: "paid" },
    { collaborator_name_snapshot: "Ana Pérez", base_pay_snapshot: 5000, additions_total: 500, reductions_total: 100, total_pay: 5400, payment_method: "transfer", concepts: [{ label: "Sueldo base", concept_code: "base_pay", direction: "addition", amount: 5000, source_date: "2026-08-03" }] },
    [{ payment_method: "transfer", payment_date: "2026-08-10", payment_reference: "SPEI-123", total_amount: 5400 }],
  );
  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.load(bytes as unknown as Parameters<typeof workbook.xlsx.load>[0]);
  assert.deepEqual(workbook.worksheets.map(sheet => sheet.name), ["Recibo"]);
  assert.equal(workbook.getWorksheet("Recibo")?.getCell("B3").value, "Ana Pérez");
  assert.equal(workbook.getWorksheet("Recibo")?.getCell("C9").value, 5400);
});
