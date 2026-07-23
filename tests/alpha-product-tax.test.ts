import assert from "node:assert/strict";
import test from "node:test";
import * as XLSX from "xlsx";
import { classifyAlphaLocation, parseAlphaWorkbook } from "../app/lib/alpha.ts";

type ProductTax = { sku: string; staiva: string | number; porceniva: string | number };

function productRows(products: ProductTax[]) {
  const rows: Array<Array<string | number>> = [[], [], [], [], [], []];
  const header = Array<string>(28).fill("");
  header[0] = "Clase";
  header[4] = "Clave";
  header[7] = "Nombre";
  header[9] = "Atributo";
  header[12] = "Unidad";
  header[13] = "Grupo";
  header[16] = "Subgrupo";
  header[25] = "Tipo";
  header[26] = "staiva";
  header[27] = "porceniva";
  rows[5] = header;
  for (const [index, product] of products.entries()) {
    const row = Array<string | number>(28).fill("");
    row[0] = "01";
    row[4] = product.sku;
    row[7] = `Producto ${index + 1}`;
    row[12] = "PZA";
    row[26] = product.staiva;
    row[27] = product.porceniva;
    rows.push(row);
  }
  return rows;
}

function workbookBuffer(sheets: Array<{ name: string; rows: Array<Array<string | number>> }>, bookType: "xlsx" | "biff8" = "xlsx") {
  const workbook = XLSX.utils.book_new();
  for (const sheet of sheets) XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet(sheet.rows), sheet.name);
  return XLSX.write(workbook, { type: "array", bookType }) as ArrayBuffer;
}

function masterProductRows() {
  const header = ["cse_prod", "cve_prod", "desc_prod", "uni_med", "staiva", "porceniva", "cve_tial", "staclas1"];
  return [
    header,
    ["Instrucción", "Instrucción", "Instrucción", "Instrucción", "Instrucción", "Instrucción"],
    ["Necesario", "Necesario", "Necesario", "Necesario", "Opcional", "Necesario"],
    ["", "Ejemplo"],
    [],
    ["CLASE", "MASTER-IVA16", "Producto maestro IVA 16", "PZA", 2, 16, "TIPO", 0],
    ["CLASE", "MASTER-IVA0", "Producto maestro IVA 0", "PZA", 2, 0, "TIPO", 0],
    ["CLASE", "MASTER-FALTA", "Producto maestro incompleto", "PZA", "", "", "TIPO", 0],
    ["", "", "Etiqueta de gasto sin SKU", "", "", "", "", 1],
  ];
}

function catalogRowsWithoutTaxes() {
  const rows: Array<Array<string | number>> = [[], [], [], [], [], []];
  rows[5] = ["Clase", "", "", "", "Clave", "", "", "Nombre", "", "Atributo", "", "", "Unidad", "Grupo", "", "", "Subgrupo", "", "", "Ma. Lo.", "", "D. Vi.", "", "", "", "Tipo de Producto"];
  rows.push(["ACEROS", "", "", "", "AC10171", "", "", "PIJA HEXAGONAL", "", "", "", "", "PZA", "PIJAS", "", "", "ACEROS", "", "", "", "", "", "", "", "", "P. TERMINADO"]);
  return rows;
}

test("cata_prd importa el producto sin inventar impuestos y lo deja pendiente de fiscal", async () => {
  const parsed = await parseAlphaWorkbook(
    workbookBuffer([{ name: "sheet1", rows: catalogRowsWithoutTaxes() }], "biff8"),
    "cata_prd_20260708.xls",
    "local_development",
  );

  assert.equal(parsed.issues.length, 0);
  assert.equal(parsed.products.length, 1);
  assert.equal(parsed.products[0]?.alphaSku, "AC10171");
  assert.equal(parsed.products[0]?.taxCategoryCode, null);
  assert.equal(parsed.products[0]?.taxRate, null);
});

test("clasifica los productos de CAT PROD con IVA 16% y tasa 0%", async () => {
  const taxes = [
    ...Array.from({ length: 482 }, (_, index) => ({ sku: `IVA16-${index}`, staiva: 2, porceniva: 16 })),
    ...Array.from({ length: 1020 }, (_, index) => ({ sku: `IVA0-${index}`, staiva: 2, porceniva: 0 })),
  ];
  const parsed = await parseAlphaWorkbook(
    workbookBuffer([{ name: "CAT PROD", rows: productRows(taxes) }]),
    "cata_prd_20260715.xlsx",
    "local_development",
  );

  assert.equal(parsed.issues.length, 0);
  assert.equal(parsed.products.filter((product) => product.taxCategoryCode === "IVA16").length, 482);
  assert.equal(parsed.products.filter((product) => product.taxCategoryCode === "IVA0").length, 1020);
});

test("ignora una copia idéntica de CAT PROD y bloquea una copia parcial", async () => {
  const rows = productRows([{ sku: "SKU-1", staiva: 2, porceniva: 16 }]);
  const identical = await parseAlphaWorkbook(
    workbookBuffer([{ name: "CAT PROD", rows }, { name: "CAT PROD copia", rows }]),
    "cata_prd_20260715.xlsx",
    "local_development",
  );
  assert.equal(identical.issues.length, 0);
  assert.equal(identical.products.length, 1);

  const partial = await parseAlphaWorkbook(
    workbookBuffer([{ name: "CAT PROD", rows }, { name: "CAT PROD parcial", rows: productRows([]) }]),
    "cata_prd_20260715.xlsx",
    "local_development",
  );
  assert.equal(partial.issues.some((issue) => issue.code === "HOJA_PRODUCTOS_CONFLICTIVA"), true);
});

test("reconoce el formato maestro de Alpha por encabezados fiscales, no por el nombre de hoja", async () => {
  const parsed = await parseAlphaWorkbook(
    workbookBuffer([{ name: "Cualquier nombre", rows: masterProductRows() }], "biff8"),
    "3.1 PRODUCTOS.xls",
    "local_development",
  );

  assert.equal(parsed.importKind, "products");
  assert.equal(parsed.products.length, 2);
  assert.equal(parsed.products[0]?.alphaSku, "MASTER-IVA16");
  assert.equal(parsed.products[0]?.taxCategoryCode, "IVA16");
  assert.equal(parsed.products[1]?.taxCategoryCode, "IVA0");
  assert.equal(parsed.issues.filter((issue) => issue.code === "IMPUESTO_FALTANTE").length, 1);
  assert.equal(parsed.issues.filter((issue) => issue.code === "SKU_FALTANTE").length, 0);
});

test("bloquea combinaciones fiscales incompletas, desconocidas y exentas sin evidencia", async () => {
  const parsed = await parseAlphaWorkbook(
    workbookBuffer([{
      name: "CAT PROD",
      rows: productRows([
        { sku: "FALTA", staiva: 2, porceniva: "" },
        { sku: "DESCONOCIDO", staiva: 1, porceniva: 16 },
        { sku: "EXENTO", staiva: 3, porceniva: 0 },
      ]),
    }]),
    "cata_prd_20260715.xlsx",
    "local_development",
  );

  assert.equal(parsed.products.length, 0);
  assert.equal(parsed.rejectedRows.length, 3);
  assert.equal(parsed.issues.filter((issue) => issue.code === "IMPUESTO_FALTANTE").length, 1);
  assert.equal(parsed.issues.filter((issue) => issue.code === "IMPUESTO_NO_COMPATIBLE").length, 2);
});

test("reconoce la abreviatura SUC como sucursal", () => {
  assert.equal(classifyAlphaLocation("CUAPA", "SUC CUAPANCINGO"), "sucursal");
});
