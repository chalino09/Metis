import { mkdir, writeFile } from "node:fs/promises";
import { createTicketPdf } from "../app/lib/ticket-pdf.ts";

const outputDirectory = "output/pdf";
await mkdir(outputDirectory, { recursive: true });
const bytes = await createTicketPdf({
  folio: "VTA-000123",
  issued_at: "2026-07-23T18:30:00.000Z",
  sale: {
    total_amount: 1275.5,
    currency_code: "MXN",
    customer: { display_name: "Cliente de mostrador" },
  },
  payment: {
    method_code: "EFECTIVO",
    received_amount: 1300,
    change_amount: 24.5,
  },
  items: [
    { product_name: "Supra engorde alimento balanceado", quantity: 2, total_amount: 975.5 },
    { product_name: "Producto adicional", quantity: 1, total_amount: 300 },
  ],
});
await writeFile(`${outputDirectory}/ticket-pos-sample.pdf`, bytes);
