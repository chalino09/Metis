import { mkdir, writeFile } from "node:fs/promises";
import { createQuotePdfBlob, type QuotePdfDocument } from "../app/lib/quote-pdf";

const sample: QuotePdfDocument = {
  branding: {
    display_name: "Satrapy Demo Comercial",
    legal_name: "Satrapy Demo Comercial, S.A. de C.V.",
    tax_id: "XAXX010101000",
    fiscal_address: "Av. Comercial 125, Centro, Puebla, Pue. C.P. 72000",
    document_title: "COTIZACIÓN",
    contact_line: "Sucursal QA Central · ventas@satrapy.mx · 222 000 0000",
    header_message: "Ponemos a su consideración la siguiente propuesta, preparada con los precios vigentes al momento de su emisión.",
    footer_message: "Estamos a sus órdenes para resolver dudas o confirmar el pedido.",
    terms_and_conditions: "Vigencia: hasta la fecha indicada en este documento. Pago: conforme a las condiciones comerciales del cliente. Entrega y existencia: se confirman al convertir la cotización en pedido; esta propuesta no reserva mercancía.",
    website: "satrapy.mx",
    accent_color: "#245A8D",
  },
  quote: {
    folio: "COT-260822-0592D5",
    status: "approved",
    currency_code: "MXN",
    valid_until: "2026-09-06",
    subtotal_amount: 210,
    tax_amount: 33.6,
    total_amount: 243.6,
    approved_at: "2026-08-22T18:20:00.000Z",
    approved_by: { id: "qa", name: "Dirección comercial" },
    customer: { display_name: "Cliente QA Cobranza Fase 2", code: "CLI-E5767437" },
    location: { name: "Sucursal QA Central", code: "QA-CENTRAL" },
    lines: [
      { product_name: "Cable acero QA conversión 1000 M", product_code: "QA-28-M-001", quantity: 5, unit_name: "Metro", unit_total_amount: 2.32, line_total_amount: 11.6 },
      { product_name: "Producto QA R-OP", product_code: "QA-PROD-001", quantity: 2, unit_name: "Pieza", unit_total_amount: 116, line_total_amount: 232 },
    ],
  },
};

const outputDirectory = new URL("../output/pdf/", import.meta.url);
const output = new URL("satrapy-cotizacion-fase-3a.pdf", outputDirectory);
await mkdir(outputDirectory, { recursive: true });
const blob = await createQuotePdfBlob(sample);
await writeFile(output, new Uint8Array(await blob.arrayBuffer()));
console.log(output.pathname);
