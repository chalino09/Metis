import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync("supabase/migrations/202608220003_sales_quote_document_approval.sql", "utf8");
const availabilitySql = readFileSync("supabase/migrations/202608220009_sales_quote_availability_notice.sql", "utf8");
const quotes = readFileSync("app/components/SalesQuotesModule.tsx", "utf8");
const pdf = readFileSync("app/lib/quote-pdf.tsx", "utf8");

test("la aprobacion formaliza el documento antes del envio", () => {
  assert.match(sql, /status in \('draft', 'approved', 'sent', 'accepted', 'not_converted'\)/);
  assert.match(sql, /create or replace function public\.approve_sales_quote/);
  assert.match(sql, /v_event = 'sent' and v_quote\.status <> 'approved'/);
  assert.match(sql, /sales_quote\.approved/);
  assert.match(sql, /document_format', 'react_pdf_a4'/);
});

test("la interfaz permite revisar, aprobar y descargar el mismo PDF", () => {
  assert.match(quotes, /approve_sales_quote/);
  assert.match(quotes, /Aprobar cotizacion|Aprobar cotización/);
  assert.match(quotes, /quote-document-pages/);
  assert.match(pdf, /@react-pdf\/renderer/);
  assert.match(pdf, /createQuotePdfUrl/);
});

test("la cotizacion advierte faltantes sin reservar ni descontar inventario", () => {
  assert.match(availabilitySql, /quantity_reserved/);
  assert.match(availabilitySql, /availability_status/);
  assert.match(availabilitySql, /supply_status/);
  assert.doesNotMatch(availabilitySql, /update public\.inventory_balances/i);
  assert.doesNotMatch(availabilitySql, /insert into public\.inventory_balances/i);
  assert.match(quotes, /Surtido pendiente/);
  assert.match(quotes, /Puedes aprobar y enviar la cotización/);
  assert.match(pdf, /Surtido pendiente/);
});
