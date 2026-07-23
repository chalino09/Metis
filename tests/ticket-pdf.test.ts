import assert from "node:assert/strict";
import test from "node:test";
import { PDFDocument } from "pdf-lib";
import { createTicketPdf } from "../app/lib/ticket-pdf.ts";

test("genera un PDF térmico de una sola página con metadatos del folio", async () => {
  const bytes = await createTicketPdf({
    folio: "VTA-000123",
    issued_at: "2026-07-23T18:30:00.000Z",
    sale: {
      total_amount: 1275.5,
      currency_code: "MXN",
      customer: { display_name: "Cliente de prueba" },
    },
    payment: {
      method_code: "EFECTIVO",
      received_amount: 1300,
      change_amount: 24.5,
    },
    items: [
      { product_name: "Supra engorde alimento de prueba con nombre largo", quantity: 2, total_amount: 975.5 },
      { product_name: "Producto adicional", quantity: 1, total_amount: 300 },
    ],
  });

  assert.equal(Buffer.from(bytes).subarray(0, 4).toString(), "%PDF");
  const document = await PDFDocument.load(bytes);
  assert.equal(document.getPageCount(), 1);
  assert.equal(document.getTitle(), "Ticket VTA-000123");
  const { width, height } = document.getPage(0).getSize();
  assert.ok(Math.abs(width - 226.77) < 0.01);
  assert.ok(height >= 340);
});

test("el PDF no incorpora campos fiscales del documento canónico", async () => {
  const bytes = await createTicketPdf({
    folio: "VTA-FISCAL",
    sale: { total_amount: 116, currency_code: "MXN", tax_amount: 16 },
    items: [{ product_name: "Producto", quantity: 1, total_amount: 116, tax_amount: 16 }],
  });
  const raw = Buffer.from(bytes).toString("latin1");
  assert.doesNotMatch(raw, /tax_amount|IVA|Impuestos/);
});
