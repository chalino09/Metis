import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const prices = readFileSync("app/components/PriceCatalogManagement.tsx", "utf8");
const css = readFileSync("app/globals.css", "utf8");
const migration = readFileSync("supabase/migrations/202607230006_pos_phase1_experience.sql", "utf8");
const otherLocationStockMigration = readFileSync("supabase/migrations/202607230008_pos_other_location_stock.sql", "utf8");

test("el POS muestra precios totales y permite cantidades directas", () => {
  assert.match(sales, /Precio total/);
  assert.match(sales, /aria-label=\{`Cantidad de \$\{item\.name\}`\}/);
  assert.match(sales, /setItemQuantity/);
  assert.match(sales, /max=\{item\.inventory_tracked \? item\.quantity_on_hand/);
});

test("el cobro evita faltantes, muestra cambio y distingue tarjeta", () => {
  assert.match(sales, /Falta por recibir/);
  assert.match(sales, /pos-change-summary/);
  assert.match(sales, /CreditCard/);
  assert.match(sales, /isCashPayment && !validReceivedAmount/);
});

test("el ticket se envía al diálogo de impresión sin descargarlo", () => {
  assert.match(sales, /Imprimir ticket/);
  assert.match(sales, /printTicketPdf/);
  assert.match(sales, /window\.open/);
  assert.match(readFileSync("app/lib/ticket-pdf.ts", "utf8"), /target\.print\(\)/);
  assert.doesNotMatch(css, /body\.is-printing-ticket/);
  const ticketPreview = sales.slice(sales.indexOf("function TicketPreview"), sales.indexOf("function PosEmpty"));
  assert.doesNotMatch(ticketPreview, /tax_amount|Impuestos|IVA/);
});

test("la búsqueda separa términos y el catálogo interno desglosa IVA", () => {
  assert.match(migration, /regexp_split_to_table\(v_query,'\\s\+'\)/);
  assert.match(migration, /'base_price_amount'/);
  assert.match(migration, /'tax_amount'/);
  assert.match(migration, /'total_amount'/);
  assert.match(prices, /Precio sin IVA/);
  assert.match(prices, /Precio total/);
});

test("el POS consulta existencias de otras sucursales sin alterar la venta local", () => {
  assert.match(sales, /Otras sucursales/);
  assert.match(sales, /list_pos_product_other_location_stock/);
  assert.match(sales, /Solo lectura\. La venta sigue usando la existencia/);
  assert.match(otherLocationStockMigration, /public\.can_access_location\(location_data\.id\)/);
  assert.match(otherLocationStockMigration, /location_data\.id <> p_current_location_id/);
  assert.match(otherLocationStockMigration, /limit v_size offset/);
});
