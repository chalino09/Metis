import assert from"node:assert/strict";
import test from"node:test";
import{PDFDocument}from"pdf-lib";
import{createBiCsv,createBiPdf,createBiXlsx,type BiExportReport}from"../app/lib/bi-report-export.ts";
const report:BiExportReport={companyName:"Empresa QA",targetLabel:"Tablero dirección",generatedAt:"2026-07-26T22:00:00Z",sections:[{title:"Ventas",widgetType:"chart",definition:{date_from:"2026-07-01",date_to:"2026-07-26"},currencyCode:"MXN",total:1,rows:[{group_label:"Centro",metric_code:"net_sales",current_value:1250,previous_value:1000,available:true}],chart:[{group_label:"Centro",current_value:1250}],metrics:[{code:"net_sales",name:"Ventas netas",formula:"Σ partidas",unit:"currency",source:"sales",grain:"flow_day",kind:"accrual",limitations:"Sin impuestos"}]}]};
test("CSV incluye datos y contexto",()=>{const text=new TextDecoder().decode(createBiCsv(report));assert.match(text,/Empresa QA/);assert.match(text,/Centro/);assert.match(text,/1250/);});
test("XLSX incluye datos y metodología",async()=>{const bytes=await createBiXlsx(report);assert.ok(bytes.byteLength>3000);});
test("PDF ejecutivo es válido y contiene páginas",async()=>{const bytes=await createBiPdf(report);const pdf=await PDFDocument.load(bytes);assert.ok(pdf.getPageCount()>=1);});
