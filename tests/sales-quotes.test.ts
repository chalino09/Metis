import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql = readFileSync("supabase/migrations/202607230011_sales_quotes_follow_up.sql", "utf8");
const composerSql = readFileSync("supabase/migrations/202607230012_quote_composer_and_pdf.sql", "utf8");
const quotes = readFileSync("app/components/SalesQuotesModule.tsx", "utf8");
const quotePdf = readFileSync("app/lib/quote-pdf.tsx", "utf8");
const quoteSettings = readFileSync("app/components/QuoteBrandingSettings.tsx", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");

test("las cotizaciones son documentos comerciales auditados y sin impacto operativo", () => {
  assert.match(sql, /create table if not exists public\.sales_quotes/);
  assert.match(sql, /create table if not exists public\.sales_quote_follow_ups/);
  assert.match(sql, /sales_quote\.follow_up_recorded/);
  assert.match(sql, /No autorizado para guardar esta cotización/);
  assert.doesNotMatch(sql, /insert into public\.sales\s/);
  assert.doesNotMatch(sql, /insert into public\.inventory_/);
});

test("el seguimiento exige un motivo cuando una cotización no se concreta", () => {
  assert.match(sql, /rejected_by_customer/);
  assert.match(sql, /cancelled_by_customer/);
  assert.match(sql, /lost_to_competition/);
  assert.match(sql, /no_follow_up_response/);
  assert.match(sql, /Selecciona el motivo por el que no se concretó/);
  assert.match(quotes, /¿Por qué no se concretó\?/);
});

test("Ventas expone cotizaciones con búsqueda server-side y datos canónicos", () => {
  assert.match(app, /sales_quotes/);
  assert.match(app, /\/satrapy\/ventas\/cotizaciones/);
  assert.match(quotes, /list_sales_quotes/);
  assert.match(quotes, /search_sales_quote_products/);
  assert.match(quotes, /save_sales_quote/);
});

test("el cotizador permite alta rápida auditada y conserva el formato del documento", () => {
  assert.match(composerSql, /create_sales_quote_customer/);
  assert.match(composerSql, /customer\.quote_quick_created/);
  assert.match(composerSql, /create table if not exists public\.sales_quote_document_snapshots/);
  assert.match(composerSql, /get_sales_quote_document/);
  assert.doesNotMatch(composerSql, /insert into public\.sales\s/);
  assert.doesNotMatch(composerSql, /insert into public\.inventory_/);
  assert.match(quotes, /Alta rápida/);
  assert.match(quotes, /Vista previa/);
  assert.match(quotePdf, /createQuotePdf/);
  assert.match(quotePdf, /printQuotePdf/);
  assert.match(quoteSettings, /Formato de cotización/);
});
