import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

type TicketItem = { product_name?: string; product_code?: string; quantity?: number; total_amount?: number };
type CanonicalTicket = {
  folio?: string;
  issued_at?: string;
  sale?: { total_amount?: number; currency_code?: string; customer?: { display_name?: string } | null };
  payment?: { method_code?: string; received_amount?: number; change_amount?: number; reference?: string };
  items?: TicketItem[];
  identity?: {
    company?: { display_name?: string; legal_name?: string | null; tax_id?: string | null };
    location?: { code?: string; name?: string; address?: string | null; contact_phone?: string | null };
    register?: { code?: string; name?: string } | null;
    collaborator?: { display_name?: string } | null;
  };
};

export type TicketBranding = {
  display_name?: string;
  legal_name?: string | null;
  tax_id?: string | null;
  contact_line?: string | null;
  document_title?: string | null;
  header_message?: string | null;
  website?: string | null;
  return_policy?: string | null;
  footer_message?: string | null;
  paper_width?: "58mm" | "80mm" | null;
  show_customer?: boolean;
  show_product_code?: boolean;
  show_payment_details?: boolean;
  show_tax_id?: boolean;
  logo_url?: string | null;
};

type TicketLayout = { width: number; sideMargin: number; textWidth: number; bodySize: number; lineHeight: number };

function layoutFor(branding: TicketBranding): TicketLayout {
  const width = branding.paper_width === "58mm" ? 164.41 : 226.77;
  const sideMargin = branding.paper_width === "58mm" ? 10 : 15;
  return { width, sideMargin, textWidth: width - sideMargin * 2, bodySize: branding.paper_width === "58mm" ? 7.5 : 8.5, lineHeight: branding.paper_width === "58mm" ? 10 : 11 };
}

function money(value: number | undefined, currency?: string) {
  const currencyCode = /^[A-Z]{3}$/.test(currency ?? "") ? currency! : "MXN";
  return new Intl.NumberFormat("es-MX", { style: "currency", currency: currencyCode, minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function ticketDate(value?: string) {
  if (!value) return "";
  return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function safePdfText(value: unknown) {
  return String(value ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^\x20-\x7E]/g, "");
}

function wrapText(text: string, font: PDFFont, size: number, maxWidth: number) {
  const words = safePdfText(text).trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [""];
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, size) <= maxWidth) { current = candidate; continue; }
    if (current) lines.push(current);
    current = word;
  }
  if (current) lines.push(current);
  return lines;
}

function drawCentered(page: PDFPage, layout: TicketLayout, text: string, y: number, font: PDFFont, size: number) {
  const normalized = safePdfText(text);
  const width = font.widthOfTextAtSize(normalized, size);
  page.drawText(normalized, { x: Math.max(layout.sideMargin, (layout.width - width) / 2), y, font, size, color: rgb(0.08, 0.1, 0.09) });
}

function drawCenteredLines(page: PDFPage, layout: TicketLayout, text: string | null | undefined, y: number, font: PDFFont, size: number) {
  if (!text) return y;
  for (const line of wrapText(text, font, size, layout.textWidth)) { drawCentered(page, layout, line, y, font, size); y -= layout.lineHeight; }
  return y;
}

function drawRule(page: PDFPage, layout: TicketLayout, y: number) {
  page.drawLine({ start: { x: layout.sideMargin, y }, end: { x: layout.width - layout.sideMargin, y }, thickness: 0.5, color: rgb(0.72, 0.75, 0.73) });
}

async function embedTicketLogo(document: PDFDocument, logoUrl?: string | null) {
  if (!logoUrl) return null;
  try {
    const response = await fetch(logoUrl);
    if (!response.ok) return null;
    const bytes = await response.arrayBuffer();
    return (response.headers.get("content-type") ?? "").includes("png") ? document.embedPng(bytes) : document.embedJpg(bytes);
  } catch { return null; }
}

export async function createTicketPdf(ticketInput: Record<string, unknown>, branding: TicketBranding = {}) {
  const ticket = ticketInput as CanonicalTicket;
  branding = { ...branding, display_name: ticket.identity?.company?.display_name ?? branding.display_name, legal_name: ticket.identity?.company?.legal_name ?? branding.legal_name, tax_id: ticket.identity?.company?.tax_id ?? branding.tax_id };
  const layout = layoutFor(branding);
  const document = await PDFDocument.create();
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const itemLines = (ticket.items ?? []).map((item) => ({
    item,
    lines: wrapText(`${Number(item.quantity ?? 0)} x ${branding.show_product_code && item.product_code ? `${item.product_code} · ` : ""}${item.product_name ?? "Producto"}`, regular, layout.bodySize, layout.textWidth - 54),
  }));
  const contentHeight = itemLines.reduce((sum, entry) => sum + Math.max(1, entry.lines.length) * layout.lineHeight + 5, 0);
  const headerExtra = (branding.logo_url ? 46 : 0) + (branding.legal_name ? 12 : 0) + (branding.contact_line ? 12 : 0) + (branding.header_message ? 16 : 0) + (branding.show_tax_id && branding.tax_id ? 12 : 0) + (branding.show_customer !== false ? 15 : 0) + (ticket.identity?.location?.name ? 12 : 0) + (ticket.identity?.location?.address ? 22 : 0) + (ticket.identity?.location?.contact_phone ? 12 : 0) + (ticket.identity?.collaborator?.display_name || ticket.identity?.register?.name ? 13 : 0);
  const footerExtra = (branding.website ? 12 : 0) + (branding.return_policy ? 24 : 0);
  const paymentRows = branding.show_payment_details === false ? 0 : (ticket.payment?.method_code ? 1 : 0) + (ticket.payment?.received_amount != null ? 1 : 0) + (ticket.payment?.reference ? 1 : 0) + (Number(ticket.payment?.change_amount ?? 0) > 0 ? 1 : 0);
  const height = Math.max(layout.width === 164.41 ? 330 : 360, 235 + headerExtra + footerExtra + contentHeight + paymentRows * 14);
  const page = document.addPage([layout.width, height]);
  let y = height - 23;

  const logo = await embedTicketLogo(document, branding.logo_url);
  if (logo) {
    const scale = Math.min((layout.width - layout.sideMargin * 2) * .48 / logo.width, 34 / logo.height, 1);
    const width = logo.width * scale; const logoHeight = logo.height * scale;
    page.drawImage(logo, { x: (layout.width - width) / 2, y: y - logoHeight + 5, width, height: logoHeight }); y -= logoHeight + 7;
  }
  drawCentered(page, layout, branding.display_name || "SATRAPY", y, bold, layout.width === 164.41 ? 11 : 13); y -= 15;
  if (branding.legal_name && branding.legal_name !== branding.display_name) y = drawCenteredLines(page, layout, branding.legal_name, y, regular, 7);
  if (branding.show_tax_id && branding.tax_id) { drawCentered(page, layout, `RFC ${branding.tax_id}`, y, regular, 7); y -= 11; }
  y = drawCenteredLines(page, layout, branding.contact_line, y, regular, 7.3);
  if (ticket.identity?.location?.name) { drawCentered(page, layout, `${ticket.identity.location.name}${ticket.identity.location.code ? ` · ${ticket.identity.location.code}` : ""}`, y, bold, 7.5); y -= 11; }
  y = drawCenteredLines(page, layout, ticket.identity?.location?.address, y, regular, 7);
  if (ticket.identity?.location?.contact_phone) { drawCentered(page, layout, `Tel. ${ticket.identity.location.contact_phone}`, y, regular, 7); y -= 11; }
  y = drawCenteredLines(page, layout, branding.header_message, y, regular, 7.3);
  drawCentered(page, layout, branding.document_title || "TICKET DE VENTA", y, bold, 8.5); y -= 17;
  drawCentered(page, layout, ticket.folio ?? "Sin folio", y, bold, 9.5); y -= 14;
  if (branding.show_customer !== false) { drawCentered(page, layout, ticket.sale?.customer?.display_name ?? "Venta de mostrador", y, regular, layout.bodySize); y -= 13; }
  drawCentered(page, layout, ticketDate(ticket.issued_at), y, regular, 7.2); y -= 13;
  if (ticket.identity?.collaborator?.display_name || ticket.identity?.register?.name) { drawCentered(page, layout, `${ticket.identity.collaborator?.display_name ? `Atendio: ${ticket.identity.collaborator.display_name}` : ""}${ticket.identity?.register?.name ? ` · ${ticket.identity.register.name}` : ""}`, y, regular, 7); y -= 12; }
  drawRule(page, layout, y); y -= 14;

  for (const { item, lines } of itemLines) {
    lines.forEach((line, index) => {
      page.drawText(line, { x: layout.sideMargin, y, font: regular, size: layout.bodySize, color: rgb(0.08, 0.1, 0.09) });
      if (index === 0) { const amount = safePdfText(money(item.total_amount, ticket.sale?.currency_code)); page.drawText(amount, { x: layout.width - layout.sideMargin - bold.widthOfTextAtSize(amount, layout.bodySize), y, font: bold, size: layout.bodySize, color: rgb(0.08, 0.1, 0.09) }); }
      y -= layout.lineHeight;
    }); y -= 5;
  }

  drawRule(page, layout, y); y -= 18;
  page.drawText("TOTAL", { x: layout.sideMargin, y, font: bold, size: 10.5, color: rgb(0.04, 0.06, 0.05) });
  const total = safePdfText(money(ticket.sale?.total_amount, ticket.sale?.currency_code));
  page.drawText(total, { x: layout.width - layout.sideMargin - bold.widthOfTextAtSize(total, 10.5), y, font: bold, size: 10.5, color: rgb(0.04, 0.06, 0.05) }); y -= 18;
  if (branding.show_payment_details !== false) {
    const drawPaymentRow = (label: string, value: string) => { page.drawText(safePdfText(label), { x: layout.sideMargin, y, font: regular, size: layout.bodySize, color: rgb(.2, .23, .21) }); const normalized = safePdfText(value); page.drawText(normalized, { x: layout.width - layout.sideMargin - bold.widthOfTextAtSize(normalized, layout.bodySize), y, font: bold, size: layout.bodySize, color: rgb(.08, .1, .09) }); y -= 14; };
    if (ticket.payment?.method_code) drawPaymentRow("Pago", ticket.payment.method_code);
    if (ticket.payment?.received_amount != null) drawPaymentRow("Recibido", money(ticket.payment.received_amount, ticket.sale?.currency_code));
    if (ticket.payment?.reference) drawPaymentRow("Autorización", ticket.payment.reference);
    if (Number(ticket.payment?.change_amount ?? 0) > 0) drawPaymentRow("Cambio", money(ticket.payment?.change_amount, ticket.sale?.currency_code));
  }
  y -= 4; drawRule(page, layout, y); y -= 16;
  y = drawCenteredLines(page, layout, branding.footer_message || "Gracias por su compra", y, regular, layout.bodySize);
  y = drawCenteredLines(page, layout, branding.return_policy, y - 2, regular, 7);
  drawCenteredLines(page, layout, branding.website, y - 2, regular, 7);
  document.setTitle(`Ticket ${safePdfText(ticket.folio ?? "")}`); document.setSubject("Comprobante de venta"); document.setCreator("Satrapy"); document.setProducer("Satrapy");
  return document.save();
}

export async function printTicketPdf(ticket: Record<string, unknown>, branding?: TicketBranding, printWindow?: Window | null) {
  const target = printWindow ?? window.open("", "satrapy-ticket-print", "popup,width=480,height=720");
  if (!target) throw new Error("El navegador bloqueó la ventana de impresión.");
  const bytes = await createTicketPdf(ticket, branding); const blob = new Blob([new Uint8Array(bytes)], { type: "application/pdf" }); const url = URL.createObjectURL(blob);
  target.addEventListener("load", () => { target.focus(); target.print(); }, { once: true });
  target.location.replace(url);
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
