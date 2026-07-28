import assert from"node:assert/strict";
import{readFileSync}from"node:fs";
import test from"node:test";

const sql=readFileSync("supabase/migrations/202607270006_bi_phase6_dependency_network.sql","utf8");
const ui=readFileSync("app/components/BiDependencyNetwork.tsx","utf8");
const route=readFileSync("app/api/bi/network/export/route.ts","utf8");
const audit=readFileSync("docs/bi-phase-6-dependency-network-audit-20260727.md","utf8");
const volatilityFix=readFileSync("supabase/migrations/202607270007_fix_bi_network_query_volatility.sql","utf8");
const overview=readFileSync("supabase/migrations/202607270008_bi_supplier_dependency_overview.sql","utf8");

test("construye sólo las cuatro relaciones canónicas y conserva evidencia explicable",()=>{
  for(const relation of["supplier_product","product_category","product_location_assortment","product_location_availability"])assert.match(sql,new RegExp(relation));
  for(const source of["procurement_quotes","procurement_awards","purchase_orders","purchase_receipts","sales_assortments","inventory_balances","product_pos_readiness_detail"])assert.match(sql,new RegExp(source));
  assert.match(sql,/when r\.supplier_id is not null then r\.amount when o\.supplier_id is not null/);
  assert.match(sql,/products\.category_id/);
  assert.doesNotMatch(sql,/alpha_class\s*=/);
  assert.match(audit,/Ventas sólo alimentan tamaño de nodos/);
});

test("no duplica etapas ni confunde surtido con readiness",()=>{
  assert.match(sql,/confirmed_receipt[\s\S]*approved_order[\s\S]*approved_award[\s\S]*received_quote/);
  assert.match(sql,/product_location_assortment/);
  assert.match(sql,/product_location_availability/);
  assert.match(sql,/blocked_readiness/);
  assert.match(audit,/Readiness nunca elimina la pertenencia/);
});

test("la vista ejecutiva agrega y pagina proveedores completos en servidor",()=>{
  assert.match(sql,/least\(greatest\(coalesce\(p_node_limit,120\),1\),200\)/);
  assert.match(sql,/least\(greatest\(coalesce\(p_edge_limit,240\),1\),400\)/);
  assert.match(sql,/least\(greatest\(coalesce\(p_expansion_levels,0\),0\),2\)/);
  assert.match(ui,/requestRef\.current\?\.abort/);
  assert.match(ui,/bi_supplier_dependency_overview/);
  assert.match(ui,/DataPagination/);
  assert.match(overview,/least\(greatest\(coalesce\(p_page_size,24\),1\),50\)/);
  assert.match(overview,/limit v_size offset\(v_page-1\)\*v_size/);
  assert.match(overview,/Agrega en servidor; nunca construye un resumen a partir de una subred truncada/);
});

test("la UI conserva una sola lectura ejecutiva, filtros y detalle por proveedor",()=>{
  for(const text of["Dependencia por proveedor","Proveedor único","Productos de mayor exposición","Abrir en Explorador"])assert.match(ui,new RegExp(text));
  for(const filter of["dateFrom","locationId","categoryId","supplierId","productId","concentration"])assert.match(ui,new RegExp(filter));
  assert.match(ui,/SupplierDetail/);
  assert.doesNotMatch(ui,/bi_dependency_network_drilldown/);
  assert.doesNotMatch(ui,/Pantalla completa/);
});

test("empresa, ubicación, permisos y auditoría se aplican en servidor",()=>{
  assert.match(sql,/has_company_permission\(p_company_id,'view_bi_dependency_network'\)/);
  assert.match(sql,/public\.can_access_location/);
  assert.match(sql,/expand_bi_dependency_network/);
  assert.match(sql,/bi\.network_queried/);
  assert.match(sql,/bi\.network_drilldown/);
  assert.match(sql,/bi\.network_export_started/);
  assert.doesNotMatch(ui,/\.from\("(?:purchase_receipts|purchase_orders|inventory_balances|sales_assortments)"\)/);
  assert.match(sql,/bi_dependency_network_query\([\s\S]*?returns jsonb language plpgsql volatile security definer/);
  assert.match(volatilityFix,/alter function public\.bi_dependency_network_query[\s\S]*volatile/);
  assert.match(overview,/public\.bi_assert_network_scope/);
  assert.match(overview,/public\.can_access_location/);
  assert.match(overview,/bi\.supplier_dependency_overview_queried/);
  assert.match(overview,/grant execute on function public\.bi_supplier_dependency_overview/);
});

test("vistas, widgets seguros y exportaciones guardan configuración, no resultados",()=>{
  assert.match(sql,/coalesce\(p_definition->>'kind','explorer'\)='network'/);
  assert.match(sql,/La red es demasiado grande para un tablero/);
  assert.match(ui,/bi_save_view/);
  assert.match(route,/bi_start_network_export/);
  assert.match(route,/p_node_limit:200,p_edge_limit:400/);
  assert.match(route,/sharp/);
  assert.match(route,/bi_finish_export/);
});
