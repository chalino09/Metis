import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createBiCsv,createBiXlsx,type BiExportReport } from "../app/lib/bi-report-export.ts";

const root=new URL("..",import.meta.url);
const read=(path:string)=>readFile(new URL(path,root),"utf8");

test("Fase 3 consulta agregados operativos con búsqueda, allowlist, orden y paginación server-side",async()=>{
  const sql=await read("supabase/migrations/202608120019_bi_operational_analytics_tables.sql");
  assert.match(sql,/create or replace function public\.bi_get_operational_table/i);
  assert.match(sql,/public\.bi_explorer_query/);
  assert.match(sql,/v_sort not in\('negative_impact','positive_contribution'/);
  assert.match(sql,/lower\(group_label\) like '%'\|\|lower\(v_search\)\|\|'%'/);
  assert.match(sql,/limit v_size offset \(v_page-1\)\*v_size/);
  assert.match(sql,/bi\.operational_table_queried/);
  assert.match(sql,/least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
});

test("la UI conserva el drawer de Fase 2 y no consulta hechos desde el navegador",async()=>{
  const source=await read("app/components/BiModule.tsx");
  assert.match(source,/OperationalAnalyticsSection/);
  assert.match(source,/\.rpc\("bi_get_operational_table"/);
  assert.match(source,/createOperationalInvestigationContext/);
  assert.match(source,/onInspect\(createOperationalInvestigationContext/);
  assert.match(source,/AnalyticsSortHeader/);
  assert.match(source,/setTimeout[\s\S]*320/);
  assert.doesNotMatch(source,/\.from\("(?:sales|sale_items|products|locations)"\)/);
});

test("vendedor permanece fuera hasta tener una atribución canónica única",async()=>{
  const source=await read("app/components/BiModule.tsx");
  const contract=await read("docs/bi-phase-2-contextual-investigation-contract-20260812.md");
  assert.doesNotMatch(source,/OperationalDimension\s*=\s*[\s\S]*seller/);
  assert.match(contract,/Vendedor no se presenta porque no hay una relación canónica y única/);
});

test("exportación operativa reproduce columnas, búsqueda, orden y contexto",async()=>{
  const report:BiExportReport={companyName:"Empresa QA",targetLabel:"Productos · Ventas netas",generatedAt:"2026-08-12T22:00:00Z",sections:[{
    title:"Productos · Ventas netas",widgetType:"table",definition:{kind:"operational_table",metric_code:"net_sales",dimension:"product",date_from:"2026-08-01",date_to:"2026-08-12",search:"café",sort_by:"negative_impact",sort_direction:"desc"},currencyCode:"MXN",total:1,chart:[],
    rows:[{group_label:"Café molido",current_value:900,previous_value:1200,change_value:-300,change_percent:-25,share_percent:12.5,contribution_percent:30,ranking:1,status:"deteriorated",available:true}],
    metrics:[{code:"net_sales",name:"Ventas netas",formula:"Σ partidas",unit:"currency",source:"sales + sale_items",grain:"flow_day",kind:"accrual",limitations:"Sin impuestos"}],
  }]};
  const csv=new TextDecoder().decode(createBiCsv(report));
  for(const value of ["Café molido","Variación absoluta","Participación en el total","negative_impact","café"])assert.match(csv,new RegExp(value));
  const xlsx=await createBiXlsx(report);assert.ok(xlsx.byteLength>3000);
});
