import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql=readFileSync("supabase/migrations/202608180002_restaurant_phase2_invoice_requests.sql","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");
const requests=readFileSync("app/components/InvoiceRequestsModule.tsx","utf8");
const navigation=readFileSync("app/components/SatrapyApp.tsx","utf8");

test("las funciones culinarias son explícitas, canónicas y auditadas",()=>{
 assert.match(sql,/create table if not exists public\.product_culinary_roles/);
 assert.match(sql,/set_product_culinary_role/);
 assert.match(sql,/product\.culinary_role_changed/);
 assert.match(sql,/from public\.product_culinary_roles role_data join public\.products/);
 assert.doesNotMatch(sql,/create table[^;]+(?:dishes|ingredients|preparations)\s*\(/i);
 assert.match(catalog,/function restaurantRoleLabel/);
 assert.match(catalog,/product_culinary_roles|catalogRole/);
 assert.doesNotMatch(catalog,/Disponible para recetas/);
});

test("la solicitud conserva fotografía fiscal y una sola identidad por ticket",()=>{
 assert.match(sql,/create table if not exists public\.sale_invoice_requests/);
 assert.match(sql,/unique\(company_id,sale_id\)/);
 assert.match(sql,/tax_regime_code text not null/);
 assert.match(sql,/fiscal_postal_code text not null/);
 assert.match(sql,/cfdi_use_code text not null/);
 assert.match(sql,/client_request_id uuid not null/);
 assert.match(sql,/Una venta cancelada no puede solicitar factura/);
});

test("los estados no confunden solicitud con CFDI emitido",()=>{
 for(const status of ["pending_review","ready_to_issue","issued","rejected","cancelled"])assert.match(sql,new RegExp(status));
 assert.match(sql,/No se puede marcar como emitida sin UUID fiscal/);
 assert.match(sql,/sale_invoice_request_history/);
 assert.match(requests,/Una solicitud no es un CFDI timbrado/);
});

test("la bandeja es server-side, paginada y sólo aparece en Restaurante",()=>{
 assert.match(sql,/list_sale_invoice_requests/);
 assert.match(sql,/limit v_size offset/);
 assert.match(requests,/DataPagination/);
 assert.match(navigation,/invoice_requests/);
 assert.match(readFileSync("app/lib/product-experience.ts","utf8"),/"invoice_requests"/);
});
