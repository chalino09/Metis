import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202607230009_ticket_branding_profiles.sql", "utf8");
const ticketOptionsSql = readFileSync("supabase/migrations/202607230010_ticket_preview_and_print_options.sql", "utf8");
const settings = readFileSync("app/components/TicketBrandingSettings.tsx", "utf8");
const ticket = readFileSync("app/lib/ticket-pdf.ts", "utf8");

test("el perfil de ticket se administra por empresa y queda auditado", () => {
  assert.match(sql, /create table if not exists public\.ticket_branding_profiles/);
  assert.match(sql, /manage_ticket_branding/);
  assert.match(sql, /ticket_branding\.updated/);
  assert.match(sql, /get_ticket_branding/);
});

test("la pantalla limita el logotipo a formatos imprimibles", () => {
  assert.match(settings, /image\/png/,);
  assert.match(settings, /image\/jpeg/,);
  assert.match(settings, /2 \* 1024 \* 1024/);
  assert.match(settings, /Guardar configuración/);
  assert.match(settings, /Vista previa/);
});

test("la presentación del ticket permite opciones térmicas auditadas", () => {
  assert.match(ticketOptionsSql, /paper_width/);
  assert.match(ticketOptionsSql, /show_product_code/);
  assert.match(ticketOptionsSql, /show_payment_details/);
  assert.match(ticketOptionsSql, /ticket_branding\.updated/);
});

test("el PDF toma la identidad comercial sin incluir el desglose fiscal", () => {
  assert.match(ticket, /branding\.display_name/);
  assert.match(ticket, /branding\.footer_message/);
  assert.match(ticket, /branding\.paper_width/);
  assert.match(ticket, /branding\.show_product_code/);
  assert.doesNotMatch(ticket, /tax_amount/);
});
