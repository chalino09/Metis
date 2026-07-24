import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

export type QuotePdfBranding = {
  display_name: string; legal_name?: string | null; tax_id?: string | null; document_title: string;
  contact_line?: string | null; header_message?: string | null; footer_message: string;
  terms_and_conditions?: string | null; website?: string | null; logo_url?: string | null;
};

export type QuotePdfDocument = {
  quote: {
    folio: string; currency_code: string; valid_until?: string | null; subtotal_amount: number; tax_amount: number; total_amount: number;
    customer: { display_name: string; code?: string | null }; location: { name: string; code?: string | null };
    lines: Array<{ product_name: string; product_code?: string | null; quantity: number; unit_name?: string | null; unit_total_amount: number; line_total_amount: number }>;
  };
  branding: QuotePdfBranding;
};

const pageSize: [number, number] = [595.28, 841.89];
const margin = 48;
const ink = rgb(0.09, 0.14, 0.12);
const muted = rgb(0.34, 0.40, 0.37);
const accent = rgb(0.08, 0.38, 0.32);
const paper = rgb(0.96, 0.98, 0.97);

function money(value: number, currency = "MXN") {
  return new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(value ?? 0));
}

function date(value: string | null | undefined) {
  return value ? new Date(value + "T12:00:00").toLocaleDateString("es-MX", { dateStyle: "long" }) : "Sin vigencia";
}

function wrap(text: string, font: PDFFont, size: number, width: number) {
  const lines: string[] = []; let current = "";
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const next = current ? current + " " + word : word;
    if (font.widthOfTextAtSize(next, size) <= width || !current) current = next;
    else { lines.push(current); current = word; }
  }
  if (current) lines.push(current);
  return lines;
}

async function embedLogo(document: PDFDocument, url: string | null | undefined) {
  if (!url) return null;
  try {
    const response = await fetch(url); if (!response.ok) return null;
    const bytes = await response.arrayBuffer();
    return (response.headers.get("content-type") ?? "").includes("png") ? await document.embedPng(bytes) : await document.embedJpg(bytes);
  } catch { return null; }
}

function text(page: PDFPage, value: string, x: number, y: number, font: PDFFont, size: number, color = ink) {
  page.drawText(value, { x, y, font, size, color });
}

function rule(page: PDFPage, y: number) {
  page.drawLine({ start: { x: margin, y }, end: { x: pageSize[0] - margin, y }, thickness: 0.8, color: rgb(0.80, 0.84, 0.82) });
}

export async function createQuotePdf(data: QuotePdfDocument) {
  const document = await PDFDocument.create();
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const logo = await embedLogo(document, data.branding.logo_url);
  let page = document.addPage(pageSize); let y = pageSize[1] - margin;
  const width = pageSize[0] - margin * 2; const quote = data.quote; const branding = data.branding;
  const addPage = () => { page = document.addPage(pageSize); y = pageSize[1] - margin; };
  const ensure = (height: number) => { if (y - height < margin + 38) addPage(); };
  const line = (value: string, x: number, size = 10, font = regular, color = ink, gap = 14) => { ensure(gap); text(page, value, x, y, font, size, color); y -= gap; };
  const wrapped = (value: string, x: number, maxWidth: number, size = 9, font = regular, color = muted, gap = 12) => { for (const part of wrap(value, font, size, maxWidth)) line(part, x, size, font, color, gap); };

  page.drawRectangle({ x: 0, y: pageSize[1] - 8, width: pageSize[0], height: 8, color: accent });
  if (logo) { const ratio = Math.min(84 / logo.width, 45 / logo.height); page.drawImage(logo, { x: margin, y: y - 44, width: logo.width * ratio, height: logo.height * ratio }); }
  const brandX = logo ? margin + 98 : margin;
  line(branding.display_name, brandX, 17, bold, ink, 22);
  if (branding.legal_name && branding.legal_name !== branding.display_name) line(branding.legal_name, brandX, 8, regular, muted, 11);
  if (branding.contact_line) line(branding.contact_line, brandX, 8, regular, muted, 11);
  if (branding.tax_id) line("RFC " + branding.tax_id, brandX, 8, regular, muted, 11);
  y -= 18;
  page.drawRectangle({ x: margin, y: y - 59, width, height: 59, color: paper });
  text(page, branding.document_title, margin + 14, y - 22, bold, 16, accent);
  text(page, quote.folio, margin + 14, y - 40, bold, 10, ink);
  text(page, "Emitida " + new Date().toLocaleDateString("es-MX"), pageSize[0] - margin - 130, y - 22, regular, 8, muted);
  text(page, "Vigencia: " + date(quote.valid_until), pageSize[0] - margin - 130, y - 40, regular, 8, muted);
  y -= 80;
  if (branding.header_message) { wrapped(branding.header_message, margin, width, 10, regular, muted, 14); y -= 6; }
  line("CLIENTE", margin, 8, bold, accent, 13);
  line(quote.customer.display_name, margin, 11, bold, ink, 15);
  line((quote.customer.code ?? "Sin clave") + " · " + quote.location.name, margin, 9, regular, muted, 21);
  rule(page, y); y -= 18;
  const columns = { product: margin, qty: 348, unit: 414, total: 494 };
  text(page, "PRODUCTO", columns.product, y, bold, 8, muted); text(page, "CANT.", columns.qty, y, bold, 8, muted); text(page, "P. UNIT.", columns.unit, y, bold, 8, muted); text(page, "IMPORTE", columns.total, y, bold, 8, muted);
  y -= 15; rule(page, y); y -= 14;
  for (const item of quote.lines) {
    const description = item.product_code ? item.product_name + " · " + item.product_code : item.product_name;
    const rows = wrap(description, regular, 9, 290); ensure(Math.max(24, rows.length * 12 + 12));
    rows.forEach((row, index) => text(page, row, columns.product, y - index * 12, regular, 9, ink));
    text(page, Number(item.quantity).toLocaleString("es-MX"), columns.qty, y, regular, 9, ink);
    text(page, money(item.unit_total_amount, quote.currency_code), columns.unit, y, regular, 9, ink);
    text(page, money(item.line_total_amount, quote.currency_code), columns.total, y, bold, 9, ink);
    y -= Math.max(24, rows.length * 12 + 12); rule(page, y); y -= 11;
  }
  ensure(100);
  const totalsX = 380;
  line("Subtotal  " + money(quote.subtotal_amount, quote.currency_code), totalsX, 9, regular, muted, 15);
  line("IVA  " + money(quote.tax_amount, quote.currency_code), totalsX, 9, regular, muted, 15);
  page.drawRectangle({ x: totalsX - 10, y: y - 30, width: 177, height: 32, color: accent });
  text(page, "TOTAL", totalsX, y - 11, bold, 10, rgb(1, 1, 1)); text(page, money(quote.total_amount, quote.currency_code), totalsX + 77, y - 11, bold, 10, rgb(1, 1, 1));
  y -= 55;
  if (branding.terms_and_conditions) { line("CONDICIONES", margin, 8, bold, accent, 13); wrapped(branding.terms_and_conditions, margin, width, 8, regular, muted, 11); y -= 5; }
  rule(page, y); y -= 14; wrapped(branding.footer_message, margin, width, 8, regular, muted, 11);
  if (branding.website) line(branding.website, margin, 8, regular, accent, 11);
  return document.save();
}

export async function downloadQuotePdf(data: QuotePdfDocument) {
  const bytes = await createQuotePdf(data);
  const url = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: "application/pdf" }));
  const anchor = document.createElement("a"); anchor.href = url; anchor.download = data.quote.folio + ".pdf";
  document.body.appendChild(anchor); anchor.click(); anchor.remove(); window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export async function printQuotePdf(data: QuotePdfDocument) {
  const target = window.open("", "satrapy-quote-print", "popup,width=900,height=720");
  if (!target) throw new Error("El navegador bloqueó la ventana de impresión.");
  target.document.write("<title>Preparando cotización…</title><p style=\"font-family:system-ui;padding:24px\">Preparando cotización…</p>");
  const bytes = await createQuotePdf(data);
  const url = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: "application/pdf" }));
  target.addEventListener("load", () => { target.focus(); target.print(); }, { once: true });
  target.location.href = url; window.setTimeout(() => URL.revokeObjectURL(url), 60000);
}
