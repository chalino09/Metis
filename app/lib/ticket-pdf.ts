import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";

type TicketItem = {
  product_name?: string;
  quantity?: number;
  total_amount?: number;
};

type CanonicalTicket = {
  folio?: string;
  issued_at?: string;
  sale?: {
    total_amount?: number;
    currency_code?: string;
    customer?: { display_name?: string } | null;
  };
  payment?: {
    method_code?: string;
    received_amount?: number;
    change_amount?: number;
  };
  items?: TicketItem[];
};

const TICKET_WIDTH = 226.77;
const SIDE_MARGIN = 15;
const TEXT_WIDTH = TICKET_WIDTH - SIDE_MARGIN * 2;
const BODY_SIZE = 8.5;
const LINE_HEIGHT = 11;

function money(value: number | undefined, currency?: string) {
  const currencyCode = /^[A-Z]{3}$/.test(currency ?? "") ? currency! : "MXN";
  return new Intl.NumberFormat("es-MX", {
    style: "currency",
    currency: currencyCode,
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function ticketDate(value?: string) {
  if (!value) return "";
  return new Intl.DateTimeFormat("es-MX", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function safePdfText(value: unknown) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^\x20-\x7E]/g, "");
}

function wrapText(text: string, font: PDFFont, size: number, maxWidth: number) {
  const words = safePdfText(text).trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [""];
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    const candidate = current ? `${current} ${word}` : word;
    if (font.widthOfTextAtSize(candidate, size) <= maxWidth) {
      current = candidate;
      continue;
    }
    if (current) lines.push(current);
    current = word;
  }
  if (current) lines.push(current);
  return lines;
}

function drawCentered(page: PDFPage, text: string, y: number, font: PDFFont, size: number) {
  const normalized = safePdfText(text);
  const width = font.widthOfTextAtSize(normalized, size);
  page.drawText(normalized, { x: Math.max(SIDE_MARGIN, (TICKET_WIDTH - width) / 2), y, font, size, color: rgb(0.08, 0.1, 0.09) });
}

function drawRule(page: PDFPage, y: number) {
  page.drawLine({
    start: { x: SIDE_MARGIN, y },
    end: { x: TICKET_WIDTH - SIDE_MARGIN, y },
    thickness: 0.5,
    color: rgb(0.72, 0.75, 0.73),
  });
}

export async function createTicketPdf(ticketInput: Record<string, unknown>) {
  const ticket = ticketInput as CanonicalTicket;
  const document = await PDFDocument.create();
  const regular = await document.embedFont(StandardFonts.Helvetica);
  const bold = await document.embedFont(StandardFonts.HelveticaBold);
  const items = ticket.items ?? [];
  const itemLines = items.map((item) => ({
    item,
    lines: wrapText(`${Number(item.quantity ?? 0)} x ${item.product_name ?? "Producto"}`, regular, BODY_SIZE, TEXT_WIDTH - 58),
  }));
  const contentHeight = itemLines.reduce((sum, entry) => sum + Math.max(1, entry.lines.length) * LINE_HEIGHT + 5, 0);
  const paymentRows = ticket.payment?.method_code ? 1 : 0;
  const receivedRows = ticket.payment?.received_amount != null ? 1 : 0;
  const changeRows = Number(ticket.payment?.change_amount ?? 0) > 0 ? 1 : 0;
  const height = Math.max(340, 235 + contentHeight + (paymentRows + receivedRows + changeRows) * 14);
  const page = document.addPage([TICKET_WIDTH, height]);
  let y = height - 25;

  drawCentered(page, "SATRAPY", y, bold, 13);
  y -= 16;
  drawCentered(page, "TICKET DE VENTA", y, bold, 9);
  y -= 18;
  drawCentered(page, ticket.folio ?? "Sin folio", y, bold, 10);
  y -= 15;
  drawCentered(page, ticket.sale?.customer?.display_name ?? "Venta de mostrador", y, regular, BODY_SIZE);
  y -= 13;
  drawCentered(page, ticketDate(ticket.issued_at), y, regular, 7.5);
  y -= 14;
  drawRule(page, y);
  y -= 15;

  for (const { item, lines } of itemLines) {
    lines.forEach((line, index) => {
      page.drawText(line, { x: SIDE_MARGIN, y, font: regular, size: BODY_SIZE, color: rgb(0.08, 0.1, 0.09) });
      if (index === 0) {
        const amount = safePdfText(money(item.total_amount, ticket.sale?.currency_code));
        page.drawText(amount, {
          x: TICKET_WIDTH - SIDE_MARGIN - bold.widthOfTextAtSize(amount, BODY_SIZE),
          y,
          font: bold,
          size: BODY_SIZE,
          color: rgb(0.08, 0.1, 0.09),
        });
      }
      y -= LINE_HEIGHT;
    });
    y -= 5;
  }

  drawRule(page, y);
  y -= 19;
  page.drawText("TOTAL", { x: SIDE_MARGIN, y, font: bold, size: 11, color: rgb(0.04, 0.06, 0.05) });
  const total = safePdfText(money(ticket.sale?.total_amount, ticket.sale?.currency_code));
  page.drawText(total, { x: TICKET_WIDTH - SIDE_MARGIN - bold.widthOfTextAtSize(total, 11), y, font: bold, size: 11, color: rgb(0.04, 0.06, 0.05) });
  y -= 18;

  const drawPaymentRow = (label: string, value: string) => {
    page.drawText(safePdfText(label), { x: SIDE_MARGIN, y, font: regular, size: BODY_SIZE, color: rgb(0.2, 0.23, 0.21) });
    const normalized = safePdfText(value);
    page.drawText(normalized, { x: TICKET_WIDTH - SIDE_MARGIN - bold.widthOfTextAtSize(normalized, BODY_SIZE), y, font: bold, size: BODY_SIZE, color: rgb(0.08, 0.1, 0.09) });
    y -= 14;
  };
  if (ticket.payment?.method_code) drawPaymentRow("Pago", ticket.payment.method_code);
  if (ticket.payment?.received_amount != null) drawPaymentRow("Recibido", money(ticket.payment.received_amount, ticket.sale?.currency_code));
  if (Number(ticket.payment?.change_amount ?? 0) > 0) drawPaymentRow("Cambio", money(ticket.payment?.change_amount, ticket.sale?.currency_code));

  y -= 4;
  drawRule(page, y);
  y -= 18;
  drawCentered(page, "Gracias por su compra", y, regular, BODY_SIZE);

  document.setTitle(`Ticket ${safePdfText(ticket.folio ?? "")}`);
  document.setSubject("Comprobante de venta");
  document.setCreator("Satrapy");
  document.setProducer("Satrapy");
  return document.save();
}

export async function downloadTicketPdf(ticket: Record<string, unknown>) {
  const bytes = await createTicketPdf(ticket);
  const blob = new Blob([new Uint8Array(bytes)], { type: "application/pdf" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  const folio = safePdfText(ticket.folio ?? "venta").replace(/[^a-zA-Z0-9_-]+/g, "-");
  link.href = url;
  link.download = `ticket-${folio || "venta"}.pdf`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
