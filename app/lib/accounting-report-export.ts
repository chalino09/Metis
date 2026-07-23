import ExcelJS from "exceljs";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import { accountingReportColumnLabel, accountingReportKeys, accountingReportLabel, isAccountingAmountKey } from "./accounting-report.ts";

export type AccountingReportExport = {
  report_type: string; starts_on: string; ends_on: string; generated_at?: string;
  rows: Array<Record<string, unknown>>; total: number; totals?: Record<string, number>; balanced?: boolean | null;
};

const green = "1C6656", pale = "E9F4F0", ink = "17211E", muted = "64716C", line = "D9E2DE";

function rawValue(key: string, value: unknown) {
  if (value === null || value === undefined) return "";
  if (isAccountingAmountKey(key)) return Number(value);
  if (key.endsWith("_date") && typeof value === "string") return new Date(`${value.slice(0, 10)}T12:00:00Z`);
  if (key === "account_type") return value === "asset" ? "Activo" : value === "liability" ? "Pasivo" : value === "equity" ? "Capital" : value === "revenue" ? "Ingreso" : value === "expense" ? "Gasto" : String(value);
  if (key === "normal_balance") return value === "debit" ? "Deudora" : "Acreedora";
  return String(value);
}

function displayValue(key: string, value: unknown) {
  const raw = rawValue(key, value);
  if (raw === "") return "-";
  if (raw instanceof Date) return raw.toLocaleDateString("es-MX", { timeZone: "UTC" });
  if (typeof raw === "number" && isAccountingAmountKey(key)) return raw.toLocaleString("es-MX", { style: "currency", currency: "MXN", minimumFractionDigits: 2 });
  return String(raw);
}

export async function createAccountingExcel(report: AccountingReportExport, companyName: string, currency: string) {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = "Satrapy"; workbook.created = new Date(); workbook.modified = new Date();
  const sheet = workbook.addWorksheet("Reporte", { views: [{ state: "frozen", ySplit: 7, showGridLines: false }] });
  const keys = accountingReportKeys(report.rows); const width = Math.max(keys.length, 4); const end = columnName(width);
  sheet.mergeCells(`A1:${end}1`); sheet.getCell("A1").value = companyName; sheet.getCell("A1").font = { size: 11, bold: true, color: { argb: green } };
  sheet.mergeCells(`A2:${end}2`); sheet.getCell("A2").value = accountingReportLabel(report.report_type); sheet.getCell("A2").font = { size: 22, bold: true, color: { argb: ink } };
  sheet.mergeCells(`A3:${end}3`); sheet.getCell("A3").value = `Del ${dateLabel(report.starts_on)} al ${dateLabel(report.ends_on)}  ·  Moneda ${currency}`; sheet.getCell("A3").font = { size: 10, color: { argb: muted } };
  sheet.mergeCells(`A5:B5`); sheet.getCell("A5").value = "Renglones"; sheet.mergeCells(`C5:D5`); sheet.getCell("C5").value = report.total;
  for (let column = 1; column <= 4; column++) { const cell = sheet.getRow(5).getCell(column); cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: pale } }; cell.font = { bold: true, color: { argb: green } }; cell.alignment = { vertical: "middle" }; } sheet.getRow(5).height = 25;
  const headerRow = sheet.getRow(7); headerRow.values = keys.map(accountingReportColumnLabel); headerRow.height = 27;
  headerRow.eachCell((cell) => { cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: green } }; cell.font = { bold: true, color: { argb: "FFFFFF" }, size: 10 }; cell.alignment = { vertical: "middle", horizontal: "left" }; });
  for (const row of report.rows) sheet.addRow(keys.map((key) => rawValue(key, row[key])));
  for (let index = 0; index < keys.length; index++) {
    const key = keys[index]; const column = sheet.getColumn(index + 1); const label = accountingReportColumnLabel(key);
    column.width = Math.min(42, Math.max(label.length + 3, key.includes("description") || key === "name" ? 28 : isAccountingAmountKey(key) ? 16 : 13));
    if (isAccountingAmountKey(key)) column.numFmt = '$#,##0.00;[Red]($#,##0.00);-';
    if (key.endsWith("_date")) column.numFmt = "dd/mm/yyyy";
    column.alignment = { vertical: "top", horizontal: isAccountingAmountKey(key) ? "right" : "left", wrapText: key.includes("description") || key === "name" };
  }
  sheet.getCell("A1").alignment = { horizontal: "left", vertical: "middle" }; sheet.getRow(1).height = 20;
  sheet.getCell("A2").alignment = { horizontal: "left", vertical: "middle" }; sheet.getRow(2).height = 34;
  sheet.getCell("A3").alignment = { horizontal: "left", vertical: "middle" }; sheet.getRow(3).height = 20;
  for (let row = 8; row <= sheet.rowCount; row++) {
    sheet.getRow(row).height = 21; sheet.getRow(row).eachCell((cell) => { cell.font = { size: 9, color: { argb: ink } }; cell.border = { bottom: { style: "hair", color: { argb: line } } }; });
    if (row % 2 === 0) sheet.getRow(row).eachCell((cell) => { cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "F7FAF9" } }; });
  }
  if (report.rows.length && keys.some(isAccountingAmountKey)) {
    const totalRow = sheet.addRow(keys.map((key, index) => index === 0 ? "Totales del servidor" : isAccountingAmountKey(key) && report.totals?.[key] !== undefined ? Number(report.totals[key]) : ""));
    totalRow.height = 25; totalRow.eachCell((cell) => { cell.font = { bold: true, color: { argb: green } }; cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: pale } }; cell.border = { top: { style: "thin", color: { argb: green } } }; });
  }
  if (report.totals && Object.keys(report.totals).length) {
    const summary = workbook.addWorksheet("Totales", { views: [{ showGridLines: false }] });
    summary.columns = [{ header: "Concepto", key: "label", width: 34 }, { header: "Importe", key: "amount", width: 22 }];
    for (const [key, value] of Object.entries(report.totals)) summary.addRow({ label: accountingReportColumnLabel(key), amount: Number(value) });
    summary.getColumn(2).numFmt = '$#,##0.00;[Red]($#,##0.00);-';
    summary.getRow(1).eachCell((cell) => { cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: green } }; cell.font = { bold: true, color: { argb: "FFFFFF" } }; });
    if (report.balanced !== null && report.balanced !== undefined) summary.addRow({ label: "Comprobación Activo = Pasivo + Capital", amount: report.balanced ? "Correcta" : "Con diferencia" });
  }
  sheet.autoFilter = { from: { row: 7, column: 1 }, to: { row: Math.max(7, sheet.rowCount), column: Math.max(1, keys.length) } };
  sheet.headerFooter.oddFooter = "&LSatrapy&CInformación financiera&RPágina &P de &N";
  sheet.pageSetup = { orientation: keys.length > 6 ? "landscape" : "portrait", fitToPage: true, fitToWidth: 1, fitToHeight: 0, margins: { left: .3, right: .3, top: .5, bottom: .5, header: .2, footer: .2 } };
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}

export async function createAccountingPdf(report: AccountingReportExport, companyName: string, currency: string) {
  const document = await PDFDocument.create(); const regular = await document.embedFont(StandardFonts.Helvetica); const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const keys = accountingReportKeys(report.rows); const landscape = keys.length > 5; const size: [number, number] = landscape ? [841.89, 595.28] : [595.28, 841.89];
  const margin = 34, rowHeight = 20, headerHeight = 24; const usable = size[0] - margin * 2; const weights = keys.map((key) => isAccountingAmountKey(key) ? 1.05 : key.includes("description") || key === "name" ? 1.8 : 1.1); const weightSum = weights.reduce((a, b) => a + b, 0); const widths = weights.map((weight) => usable * weight / weightSum);
  let page = document.addPage(size), y = size[1] - margin;
  const addHeader = () => {
    page.drawText(companyName, { x: margin, y, size: 9, font: bold, color: rgb(.11,.40,.34) }); y -= 22;
    page.drawText(accountingReportLabel(report.report_type), { x: margin, y, size: 19, font: bold, color: rgb(.09,.13,.12) }); y -= 18;
    page.drawText(`Del ${dateLabel(report.starts_on)} al ${dateLabel(report.ends_on)}  |  ${currency}  |  ${report.total.toLocaleString("es-MX")} renglones`, { x: margin, y, size: 8.5, font: regular, color: rgb(.39,.44,.42) }); y -= 20;
    page.drawRectangle({ x: margin, y: y - 4, width: usable, height: headerHeight, color: rgb(.11,.40,.34) }); let x = margin;
    keys.forEach((key, index) => { page.drawText(fitText(accountingReportColumnLabel(key), widths[index] - 8, 7.3, bold), { x: x + 4, y: y + 5, size: 7.3, font: bold, color: rgb(1,1,1) }); x += widths[index]; }); y -= rowHeight;
  };
  const addPage = () => { page = document.addPage(size); y = size[1] - margin; addHeader(); };
  addHeader();
  report.rows.forEach((row, rowIndex) => {
    if (y < margin + 28) addPage(); if (rowIndex % 2 === 1) page.drawRectangle({ x: margin, y: y - 4, width: usable, height: rowHeight, color: rgb(.97,.98,.98) });
    let x = margin; keys.forEach((key, index) => { const text = fitText(displayValue(key, row[key]), widths[index] - 8, 7, regular); const textWidth = regular.widthOfTextAtSize(text, 7); page.drawText(text, { x: isAccountingAmountKey(key) ? x + widths[index] - textWidth - 4 : x + 4, y: y + 3, size: 7, font: regular, color: rgb(.09,.13,.12) }); x += widths[index]; }); y -= rowHeight;
  });
  const pages = document.getPages(); pages.forEach((item, index) => { const footer = `Generado por Satrapy  |  ${new Date().toLocaleString("es-MX")}  |  Página ${index + 1} de ${pages.length}`; item.drawText(footer, { x: margin, y: 17, size: 7, font: regular, color: rgb(.39,.44,.42) }); });
  document.setTitle(`${accountingReportLabel(report.report_type)} - ${companyName}`); document.setAuthor("Satrapy"); document.setSubject(`Información financiera ${report.starts_on} a ${report.ends_on}`);
  return document.save();
}

function dateLabel(value: string) { const [year, month, day] = value.slice(0, 10).split("-"); return `${day}/${month}/${year}`; }
function columnName(value: number) { let result = ""; while (value > 0) { value--; result = String.fromCharCode(65 + value % 26) + result; value = Math.floor(value / 26); } return result; }
function fitText(value: string, maxWidth: number, fontSize: number, font: { widthOfTextAtSize(value: string, size: number): number }) { if (font.widthOfTextAtSize(value, fontSize) <= maxWidth) return value; let text = value; while (text.length > 1 && font.widthOfTextAtSize(`${text}...`, fontSize) > maxWidth) text = text.slice(0, -1); return `${text}...`; }
