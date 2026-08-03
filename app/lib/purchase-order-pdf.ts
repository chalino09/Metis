import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

export type PurchaseOrderPdfDocument = {
  folio: string;
  status: "draft" | "pending_approval" | "approved" | "rejected" | "cancelled";
  currency_code: string;
  ordered_date: string;
  expected_date?: string | null;
  supplier_reference?: string | null;
  supplier: { display_name: string; code: string; tax_id?: string | null };
  lines: Array<{ description: string; unit?: string | null; quantity: number; unit_cost: number; line_total?: number | null }>;
  subtotal: number;
  discounts: number;
  total: number;
  notes?: string | null;
};

const pageSize: [number, number] = [595.28, 841.89];
const margin = 48;
const ink = rgb(0.09, 0.14, 0.12);
const muted = rgb(0.34, 0.40, 0.37);
const accent = rgb(0.08, 0.38, 0.32);
const paper = rgb(0.96, 0.98, 0.97);

function money(value: number, currency: string) {
  return new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(value ?? 0));
}

function date(value: string | null | undefined) {
  return value ? new Date(`${value}T12:00:00`).toLocaleDateString("es-MX", { dateStyle: "long" }) : "Sin fecha";
}

function wrap(value: string, font: PDFFont, size: number, width: number) {
  const lines: string[] = []; let current = "";
  for (const word of value.split(/\s+/).filter(Boolean)) {
    const next = current ? `${current} ${word}` : word;
    if (!current || font.widthOfTextAtSize(next, size) <= width) current = next;
    else { lines.push(current); current = word; }
  }
  if (current) lines.push(current);
  return lines;
}

function text(page: PDFPage, value: string, x: number, y: number, font: PDFFont, size: number, color = ink) {
  page.drawText(value, { x, y, font, size, color });
}

function rule(page: PDFPage, y: number) {
  page.drawLine({ start: { x: margin, y }, end: { x: pageSize[0] - margin, y }, thickness: 0.8, color: rgb(0.80, 0.84, 0.82) });
}

function titleFor(status: PurchaseOrderPdfDocument["status"]) {
  return status === "draft" || status === "rejected" ? "COTIZACIÓN DE COMPRA" : "ORDEN DE COMPRA";
}

export async function createPurchaseOrderPdf(data: PurchaseOrderPdfDocument) {
  const document = await PDFDocument.create();
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  let page = document.addPage(pageSize); let y = pageSize[1] - margin;
  const width = pageSize[0] - margin * 2;
  const addPage = () => { page = document.addPage(pageSize); y = pageSize[1] - margin; };
  const ensure = (height: number) => { if (y - height < margin + 36) addPage(); };
  const line = (value: string, x: number, size = 10, font = regular, color = ink, gap = 14) => { ensure(gap); text(page, value, x, y, font, size, color); y -= gap; };
  const wrapped = (value: string, x: number, maxWidth: number, size = 9, font = regular, color = muted, gap = 12) => { for (const part of wrap(value, font, size, maxWidth)) line(part, x, size, font, color, gap); };

  page.drawRectangle({ x: 0, y: pageSize[1] - 8, width: pageSize[0], height: 8, color: accent });
  line("Satrapy", margin, 18, bold, ink, 22);
  line("Compras", margin, 9, regular, muted, 28);
  page.drawRectangle({ x: margin, y: y - 62, width, height: 62, color: paper });
  text(page, titleFor(data.status), margin + 14, y - 23, bold, 15, accent);
  text(page, data.folio, margin + 14, y - 42, bold, 10, ink);
  text(page, `Fecha: ${date(data.ordered_date)}`, pageSize[0] - margin - 155, y - 23, regular, 8, muted);
  text(page, `Entrega: ${date(data.expected_date)}`, pageSize[0] - margin - 155, y - 42, regular, 8, muted);
  y -= 82;
  line("PROVEEDOR", margin, 8, bold, accent, 13);
  line(data.supplier.display_name, margin, 11, bold, ink, 15);
  line(`${data.supplier.code}${data.supplier.tax_id ? ` · RFC ${data.supplier.tax_id}` : ""}`, margin, 9, regular, muted, 18);
  if (data.supplier_reference) line(`Referencia: ${data.supplier_reference}`, margin, 9, regular, muted, 18);
  rule(page, y); y -= 18;
  const columns = { item: margin, qty: 340, unit: 398, cost: 446, total: 507 };
  text(page, "PARTIDA", columns.item, y, bold, 8, muted); text(page, "CANT.", columns.qty, y, bold, 8, muted); text(page, "UNIDAD", columns.unit, y, bold, 8, muted); text(page, "COSTO", columns.cost, y, bold, 8, muted); text(page, "IMPORTE", columns.total, y, bold, 8, muted);
  y -= 15; rule(page, y); y -= 14;
  for (const item of data.lines) {
    const rows = wrap(item.description, regular, 9, 275); ensure(Math.max(24, rows.length * 12 + 12));
    rows.forEach((row, index) => text(page, row, columns.item, y - index * 12, regular, 9, ink));
    text(page, Number(item.quantity).toLocaleString("es-MX"), columns.qty, y, regular, 9, ink);
    text(page, item.unit ?? "—", columns.unit, y, regular, 8, ink);
    text(page, money(item.unit_cost, data.currency_code), columns.cost, y, regular, 8, ink);
    text(page, money(item.line_total ?? item.quantity * item.unit_cost, data.currency_code), columns.total, y, bold, 8, ink);
    y -= Math.max(24, rows.length * 12 + 12); rule(page, y); y -= 11;
  }
  ensure(95);
  const totalsX = 374;
  line(`Subtotal  ${money(data.subtotal, data.currency_code)}`, totalsX, 9, regular, muted, 15);
  line(`Descuentos  ${money(data.discounts, data.currency_code)}`, totalsX, 9, regular, muted, 15);
  page.drawRectangle({ x: totalsX - 10, y: y - 30, width: 181, height: 32, color: accent });
  text(page, "TOTAL", totalsX, y - 11, bold, 10, rgb(1, 1, 1)); text(page, money(data.total, data.currency_code), totalsX + 68, y - 11, bold, 10, rgb(1, 1, 1));
  y -= 55;
  if (data.notes) { line("NOTAS", margin, 8, bold, accent, 13); wrapped(data.notes, margin, width, 8, regular, muted, 11); y -= 4; }
  rule(page, y); y -= 14; wrapped("Documento generado desde Satrapy. La recepción, inventario y cuentas por pagar se registran en sus pasos operativos correspondientes.", margin, width, 8, regular, muted, 11);
  return document.save();
}

export async function downloadPurchaseOrderPdf(data: PurchaseOrderPdfDocument) {
  const bytes = await createPurchaseOrderPdf(data);
  const url = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: "application/pdf" }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = `${data.folio}.pdf`;
  document.body.appendChild(anchor); anchor.click(); anchor.remove(); window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export async function printPurchaseOrderPdf(data: PurchaseOrderPdfDocument) {
  const target = window.open("", "satrapy-purchase-order-print", "popup,width=900,height=720");
  if (!target) throw new Error("El navegador bloqueó la ventana de impresión.");
  target.document.write("<title>Preparando documento…</title><p style=\"font-family:system-ui;padding:24px\">Preparando documento…</p>");
  const bytes = await createPurchaseOrderPdf(data);
  const url = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: "application/pdf" }));
  target.addEventListener("load", () => { target.focus(); target.print(); }, { once: true });
  target.location.href = url; window.setTimeout(() => URL.revokeObjectURL(url), 60000);
}
