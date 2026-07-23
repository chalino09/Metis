import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { parseAccountingWorkbook } from "../app/lib/accounting-import.ts";

function workbook(rows:Record<string,unknown>[]){const book=XLSX.utils.book_new();XLSX.utils.book_append_sheet(book,XLSX.utils.json_to_sheet(rows),"Datos");return Buffer.from(XLSX.write(book,{type:"buffer",bookType:"xlsx"}));}
function accountingWorkbook(rows:Record<string,unknown>[],metadata:unknown[][]){const book=XLSX.utils.book_new();XLSX.utils.book_append_sheet(book,XLSX.utils.json_to_sheet(rows),"Datos");XLSX.utils.book_append_sheet(book,XLSX.utils.aoa_to_sheet(metadata),"Metadatos");return Buffer.from(XLSX.write(book,{type:"buffer",bookType:"xlsx"}));}

test("el cargador principal detecta catálogo contable por estructura",()=>{
  const parsed=parseAccountingWorkbook(workbook([{Código:"1000",Nombre:"Activo",Tipo:"Activo",Naturaleza:"Deudora"}]));
  assert.equal(parsed?.importType,"chart_of_accounts");assert.equal(parsed?.rows[0].account_type,"asset");assert.equal(parsed?.rows[0].normal_balance,"debit");
});

test("el cargador principal detecta balanza sin depender del nombre del archivo",()=>{
  const parsed=parseAccountingWorkbook(workbook([{Cuenta:"1000",Descripción:"Caja",Debe:100,Haber:0},{Cuenta:"3000",Descripción:"Capital",Debe:0,Haber:100}]));
  assert.equal(parsed?.importType,"trial_balance");assert.equal(parsed?.rows.length,2);assert.equal(parsed?.rows[1].credit,100);
});

test("una hoja ajena no se fuerza como archivo contable",()=>{
  assert.equal(parseAccountingWorkbook(workbook([{SKU:"P-1",Producto:"Equipo",Cantidad:2}])),null);
});

test("detecta fecha, moneda y estructura con evidencia del libro",()=>{
  const parsed=parseAccountingWorkbook(accountingWorkbook([{Código:"1000",Nombre:"Activo",Tipo:"Activo",Naturaleza:"Deudora"}],[["Dato","Valor"],["Fecha de corte","2026-07-08"],["Moneda","MXN"]]));
  assert.equal(parsed?.metadata.cutoffDate.value,"2026-07-08");assert.equal(parsed?.metadata.currency.value,"MXN");assert.equal(parsed?.metadata.catalogStructure.value?.format,"4");assert.equal(parsed?.metadata.cutoffDate.evidence[0].sheet,"Metadatos");
});

test("marca conflicto cuando el libro declara dos fechas de corte",()=>{
  const parsed=parseAccountingWorkbook(accountingWorkbook([{Cuenta:"1000",Debe:10,Haber:0},{Cuenta:"3000",Debe:0,Haber:10}],[["Fecha de corte","2026-07-08"],["Fecha de corte","2026-07-09"],["Moneda","MXN"]]));
  assert.equal(parsed?.metadata.cutoffDate.status,"conflict");assert.equal(parsed?.metadata.cutoffDate.value,null);
});

test("encuentra encabezados contables aunque no estén en la primera fila",()=>{
  const book=XLSX.utils.book_new();XLSX.utils.book_append_sheet(book,XLSX.utils.aoa_to_sheet([["Balanza al 08/07/2026"],[],["Cuenta","Debe","Haber"],["1000",25,0],["3000",0,25]]),"Reporte");XLSX.utils.book_append_sheet(book,XLSX.utils.aoa_to_sheet([["Moneda","MXN"]]),"Metadatos");
  const parsed=parseAccountingWorkbook(Buffer.from(XLSX.write(book,{type:"buffer",bookType:"xlsx"})));assert.equal(parsed?.rows.length,2);assert.equal(parsed?.metadata.cutoffDate.value,"2026-07-08");
});
