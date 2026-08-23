import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202608130009_ticket_location_collaborator_snapshot.sql", "utf8");
const settings = readFileSync("app/components/TicketBrandingSettings.tsx", "utf8");
const ticket = readFileSync("app/lib/ticket-pdf.ts", "utf8");

test("los tickets nuevos congelan sucursal, caja y colaborador en servidor", () => {
  assert.match(sql, /before insert on public\.canonical_tickets/);
  assert.match(sql, /ticket_operational_snapshot/);
  assert.match(sql, /collaborator_user_links/);
  assert.match(sql, /'schema_version',2/);
  assert.match(sql, /content_sha256/);
});

test("el teléfono pertenece al maestro de sucursal y no al perfil empresarial", () => {
  assert.match(sql, /location_operating_profiles[\s\S]*contact_phone/);
  assert.match(settings, /get_ticket_location_preview/);
  assert.match(settings, /Sucursal para vista previa/);
});

test("el PDF usa la fotografía operativa del ticket", () => {
  assert.match(ticket, /ticket\.identity\?\.location/);
  assert.match(ticket, /ticket\.identity\?\.collaborator/);
  assert.match(ticket, /ticket\.identity\?\.register/);
});
