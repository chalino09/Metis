import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const orders = readFileSync("app/components/PurchaseOrdersModule.tsx", "utf8");
const procurement = readFileSync("app/components/ProcurementModule.tsx", "utf8");
const documentSearch = readFileSync("supabase/migrations/202608200005_procurement_document_search.sql", "utf8");
const documentDateOrder = readFileSync("supabase/migrations/202608200006_procurement_document_date_order.sql", "utf8");

test("nueva cotización selecciona una solicitud pendiente con búsqueda paginada", () => {
  assert.match(orders, /search_procurement_requisitions/);
  assert.match(orders, /p_status:"quoting"/);
  assert.match(orders, /p_page:requisitionPage/);
  assert.match(orders, /Los productos y cantidades se heredan de la solicitud seleccionada/);
  assert.match(orders, /Busca por folio o ubicación/);
});

test("la selección abre el formulario canónico de cotización de la solicitud", () => {
  assert.match(orders, /Solicitud de compra/);
  assert.match(orders, /selectRequisition/);
  assert.match(orders, /get_procurement_requisition/);
  assert.match(orders, /save_procurement_quote/);
  assert.match(orders, /selected\.lines\.map/);
  assert.doesNotMatch(orders, /cotizar=1/);
  assert.doesNotMatch(procurement, /searchParams\.get\("cotizar"\)/);
});

test("los campos numéricos de la cotización permiten borrar el valor y validan al guardar", () => {
  assert.match(orders, /quantity:event\.target\.value/);
  assert.match(orders, /unit_cost:event\.target\.value/);
  assert.match(orders, /discount_percent_1:event\.target\.value/);
  assert.match(orders, /numericLineError/);
  assert.match(orders, /aria-invalid=\{lineErrors\[/);
  assert.match(orders, /available_quantity:Number\(line\.quantity\)/);
  assert.match(orders, /unit_price:Number\(line\.unit_cost\)/);
  assert.doesNotMatch(orders, /quantity:Number\(event\.target\.value\)/);
  assert.doesNotMatch(orders, /unit_cost:Number\(event\.target\.value\)/);
  assert.doesNotMatch(orders, /discount_percent_1:Number\(event\.target\.value\)/);
});

test("cotizaciones y órdenes se consultan como documentos distintos en una sola vista", () => {
  assert.match(orders, /search_procurement_documents/);
  assert.match(orders, /Tipo de documento/);
  assert.match(orders, /Todos los documentos/);
  assert.match(orders, /document\.document_type==="quote"/);
  assert.match(orders, /abastecimiento\?solicitud=/);
  assert.match(documentSearch, /from public\.procurement_quotes quote/);
  assert.match(documentSearch, /from public\.purchase_orders purchase_order/);
  assert.match(documentSearch, /limit v_size offset/);
  assert.match(documentSearch, /requisition_line\.required_quantity/);
});

test("guardar una cotización recarga el listado filtrado a cotizaciones", () => {
  assert.match(orders, /setDocumentType\("quote"\)/);
  assert.match(orders, /load\(\{documentType:"quote",status:"all",page:1,query:""\}\)/);
  assert.match(orders, /Ya aparece en Cotizaciones y órdenes/);
});

test("la vista de documentos ordena por fecha visible y desempata por creación", () => {
  assert.match(documentDateOrder, /order by document_date desc nulls last,created_at desc,id desc/);
  assert.match(documentDateOrder, /quote\.created_at::date document_date/);
  assert.match(documentDateOrder, /purchase_order\.ordered_date document_date/);
  assert.match(documentDateOrder, /to_jsonb\(paged\)-'created_at'/);
});
