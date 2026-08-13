import type {
  ImportIssue,
  ImportKind,
  InventoryRecord,
  LocationType,
  ParsedAlphaFile,
  ProductRecord,
  PriceRecord,
  CostRecord,
  SaleRecord,
} from "./types.ts";
import { classifyAlphaUpload } from "./alpha-upload-routing.ts";

type AlphaFileInput = Pick<File, "name" | "arrayBuffer">;

export function detectAlphaFileKind(fileName: string): ImportKind {
  const kind = classifyAlphaUpload(fileName);
  return kind === "products" || kind === "inventory" || kind === "prices" || kind === "costs" || kind === "sales" ? kind : "unsupported";
}

export async function parseAlphaFile(
  file: AlphaFileInput,
  source: ParsedAlphaFile["source"],
): Promise<ParsedAlphaFile> {
  const buffer = await file.arrayBuffer();
  return parseAlphaWorkbook(buffer, file.name, source);
}

export async function parseAlphaWorkbook(
  buffer: ArrayBuffer,
  fileName: string,
  source: ParsedAlphaFile["source"],
): Promise<ParsedAlphaFile> {
  const importKind = detectAlphaFileKind(fileName);
  const fileHash = await sha256(buffer);
  const emptyResult: ParsedAlphaFile = {
    fileName,
    fileHash,
    importKind,
    source,
    snapshotDate: null,
    products: [],
    inventory: [],
    prices: [],
    costs: [],
    sales: [],
    rejectedRows: [],
    locations: [],
    issues: [],
  };

  try {
    // SheetJS is loaded only when the operator chooses a file, keeping the
    // authenticated operational interface lean until an import is requested.
    const XLSX = await import("xlsx");
    const workbook = XLSX.read(new Uint8Array(buffer), { type: "array", raw: false });
    const effectiveKind = importKind === "unsupported" && isRecognizedProductWorkbook(workbook, XLSX)
      ? "products"
      : importKind;
    const parsedBase = { ...emptyResult, importKind: effectiveKind };
    if (effectiveKind === "unsupported") {
      return {
        ...parsedBase,
        issues: [{
          severity: "error",
          code: "ARCHIVO_NO_COMPATIBLE",
          message: "Archivo no reconocido. Usa una exportación cata_prd, reexic2, rprecprd, rcostprd, nvtadesg o un catálogo con encabezados fiscales de producto.",
        }],
      };
    }
    if (effectiveKind === "products") {
      return { ...parsedBase, ...parseProductWorkbook(workbook, XLSX) };
    }
    const firstSheet = workbook.Sheets[workbook.SheetNames[0]];
    if (!firstSheet) throw new Error("El libro no contiene una hoja legible.");
    const rows = readWorksheetRows(firstSheet, XLSX);
    if (effectiveKind === "inventory") return { ...parsedBase, ...parseInventoryRows(rows) };
    if (effectiveKind === "prices") return { ...parsedBase, ...parsePriceRows(rows) };
    if (effectiveKind === "sales") return { ...parsedBase, ...parseSalesRows(rows, fileName) };
    return { ...parsedBase, ...parseCostRows(rows) };
  } catch {
    return {
      ...emptyResult,
      issues: [
        {
          severity: "error",
          code: "FORMATO_NO_COMPATIBLE",
          message: "No se pudo leer el archivo. Verifica que sea una exportación XLS/XLSX compatible.",
        },
      ],
    };
  }
}

type ProductHeader = Record<string, number>;

function isRecognizedProductWorkbook(workbook: { SheetNames: string[]; Sheets: Record<string, unknown> }, XLSX: typeof import("xlsx")): boolean {
  return workbook.SheetNames.some((sheetName) => {
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) return false;
    const header = findProductHeader(readWorksheetRows(sheet, XLSX));
    return normalized(sheetName) === "cat prod" ? Boolean(header) : isMasterProductTemplate(header);
  });
}

function parseProductWorkbook(workbook: { SheetNames: string[]; Sheets: Record<string, unknown> }, XLSX: typeof import("xlsx")) {
  let primarySheetName = workbook.SheetNames.find((sheetName) => {
    const sheet = workbook.Sheets[sheetName];
    return normalized(sheetName) === "cat prod" && Boolean(sheet && findProductHeader(readWorksheetRows(sheet, XLSX)));
  });
  if (!primarySheetName) {
    primarySheetName = workbook.SheetNames.find((sheetName) => {
      const sheet = workbook.Sheets[sheetName];
      return Boolean(sheet && isMasterProductTemplate(findProductHeader(readWorksheetRows(sheet, XLSX))));
    });
  }
  if (!primarySheetName) {
    primarySheetName = workbook.SheetNames.find((sheetName) => {
      const sheet = workbook.Sheets[sheetName];
      return Boolean(sheet && findProductHeader(readWorksheetRows(sheet, XLSX)));
    });
  }
  if (!primarySheetName) {
    return {
      products: [], inventory: [], prices: [], costs: [], sales: [], rejectedRows: [], locations: [],
      issues: [{
        severity: "error" as const,
        code: "HOJA_PRODUCTOS_FALTANTE" as const,
        message: "El catálogo debe incluir Clave y Nombre; la configuración fiscal puede llegar después desde el maestro con staiva y porceniva.",
      }],
    };
  }
  const primarySheet = workbook.Sheets[primarySheetName];
  if (!primarySheet) throw new Error("La hoja CAT PROD no es legible.");
  const primaryRows = readWorksheetRows(primarySheet, XLSX);
  const parsed = parseProductRows(primaryRows);
  const primaryFingerprint = productSheetFingerprint(primaryRows);

  for (const sheetName of workbook.SheetNames) {
    if (sheetName === primarySheetName || !productSheetKey(sheetName).startsWith("catprod")) continue;
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) continue;
    const candidateRows = readWorksheetRows(sheet, XLSX);
    if (productSheetFingerprint(candidateRows) === primaryFingerprint) continue;
    parsed.issues.push({
      severity: "error",
      code: "HOJA_PRODUCTOS_CONFLICTIVA",
      message: `La hoja ${sheetName} parece una copia parcial o distinta de CAT PROD. Retírala o corrige su contenido antes de importar.`,
    });
  }
  return parsed;
}

function readWorksheetRows(sheet: unknown, XLSX: typeof import("xlsx")): Array<Array<string | number>> {
  return XLSX.utils.sheet_to_json<Array<string | number>>(sheet as import("xlsx").WorkSheet, {
    header: 1,
    defval: "",
    raw: false,
  });
}

function parseProductRows(rows: Array<Array<string | number>>) {
  const products: ProductRecord[] = [];
  const rejectedRows: ParsedAlphaFile["rejectedRows"] = [];
  const issues: ImportIssue[] = [];
  const seenSkus = new Set<string>();
  const header = findProductHeader(rows);

  if (!header) {
    const headerIssues: ImportIssue[] = [{
      severity: "error",
      code: "FORMATO_NO_COMPATIBLE",
      message: "CAT PROD debe incluir encabezados Clave, Nombre, staiva y porceniva.",
    }];
    return {
      products, inventory: [], prices: [], costs: [], rejectedRows, locations: [],
      issues: headerIssues,
    };
  }

  const hasTaxColumns = header.columns.staiva !== undefined && header.columns.porceniva !== undefined;
  const dataStartIndex = isMasterProductTemplate(header) ? findMasterProductDataStart(rows, header) : header.rowIndex + 1;
  for (let index = dataStartIndex; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const alphaSku = productValue(row, header.columns, ["clave", "claveproducto", "codigo", "sku", "cveprod"], 4);
    const name = productValue(row, header.columns, ["nombre", "descripcion", "descprod"], 7);
    const sourceKind = productValue(row, header.columns, ["staclas1"], -1);

    // Detail/attribute continuation rows in Alpha have no value in the Nombre column.
    if (!alphaSku && !name) continue;
    // Master exports can include unlabeled service/expense labels after the
    // product catalog. They have no canonical product key and do not belong in
    // the product promotion flow.
    if (!alphaSku && name && sourceKind === "1") continue;
    if (!alphaSku && name) {
      issues.push({
        severity: "error",
        code: "SKU_FALTANTE",
        rowNumber: index + 1,
        message: "Producto sin Clave (SKU) en el catálogo de origen.",
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "products", normalizedData: { alphaSku: null, name } });
      continue;
    }
    if (!name) {
      issues.push({
        severity: "error",
        code: "FORMATO_NO_COMPATIBLE",
        rowNumber: index + 1,
        alphaSku,
        message: "Producto sin Nombre; no se puede importar una ficha incompleta.",
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "products", normalizedData: { alphaSku, name: null } });
      continue;
    }
    if (seenSkus.has(alphaSku)) {
      issues.push({
        severity: "error",
        code: "SKU_DUPLICADO",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} aparece más de una vez en el archivo.`,
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "products", normalizedData: { alphaSku, name } });
      continue;
    }
    seenSkus.add(alphaSku);
    const staiva = productValue(row, header.columns, ["staiva"], -1);
    const porceniva = productValue(row, header.columns, ["porceniva"], -1);
    const tax = hasTaxColumns ? parseProductTax(staiva, porceniva) : null;
    if (hasTaxColumns && !tax) {
      const incomplete = !staiva || !porceniva;
      issues.push({
        severity: "error",
        code: incomplete ? "IMPUESTO_FALTANTE" : "IMPUESTO_NO_COMPATIBLE",
        rowNumber: index + 1,
        alphaSku,
        message: incomplete
          ? `El SKU ${alphaSku} no tiene staiva y porceniva completos.`
          : staiva === "3"
            ? `El SKU ${alphaSku} usa staiva = 3. La categoría exenta no está habilitada hasta contar con una exportación real que la respalde.`
            : `El SKU ${alphaSku} tiene una combinación fiscal no reconocida: staiva ${staiva}, porceniva ${porceniva}.`,
      });
      rejectedRows.push({
        rowNumber: index + 1,
        rawData: row,
        detectedType: "products",
        normalizedData: { alphaSku, name, staiva: staiva || null, porceniva: porceniva || null },
      });
      continue;
    }
    products.push({
      rowNumber: index + 1,
      rawData: row,
      alphaSku,
      alphaClass: nullIfEmpty(productValue(row, header.columns, ["clase", "cseprod"], 0)),
      name,
      attribute: nullIfEmpty(productValue(row, header.columns, ["atributo"], 9)),
      unit: nullIfEmpty(productValue(row, header.columns, ["unidad", "unimed"], 12)),
      productGroup: nullIfEmpty(productValue(row, header.columns, ["grupo", "grupoproducto"], 13)),
      subgroup: nullIfEmpty(productValue(row, header.columns, ["subgrupo"], 16)),
      productType: nullIfEmpty(productValue(row, header.columns, ["tipo", "tipoproducto", "cvetial"], 25)),
      staiva: hasTaxColumns ? staiva || null : null,
      porceniva: hasTaxColumns ? porceniva || null : null,
      taxCategoryCode: tax?.categoryCode ?? null,
      taxRate: tax?.rate ?? null,
    });
  }

  if (!products.length && !issues.length) {
    issues.push({
      severity: "error",
      code: "FORMATO_NO_COMPATIBLE",
      message: "No se encontraron productos válidos en el formato cata_prd de origen.",
    });
  }
  return { products, inventory: [], prices: [], costs: [], sales: [], rejectedRows, locations: [], issues };
}

function findProductHeader(rows: Array<Array<string | number>>): { rowIndex: number; columns: ProductHeader } | null {
  for (let rowIndex = 0; rowIndex < Math.min(rows.length, 20); rowIndex += 1) {
    const columns: ProductHeader = {};
    (rows[rowIndex] ?? []).forEach((value, columnIndex) => {
      const key = productHeaderKey(value);
      if (key && columns[key] === undefined) columns[key] = columnIndex;
    });
    const hasSku = ["clave", "claveproducto", "codigo", "sku", "cveprod"].some((key) => columns[key] !== undefined);
    const hasName = ["nombre", "descripcion", "descprod"].some((key) => columns[key] !== undefined);
    if (hasSku && hasName) return { rowIndex, columns };
  }
  return null;
}

function isMasterProductTemplate(header: { rowIndex: number; columns: ProductHeader } | null): boolean {
  return Boolean(header && header.columns.cveprod !== undefined && header.columns.descprod !== undefined);
}

function findMasterProductDataStart(rows: Array<Array<string | number>>, header: { rowIndex: number; columns: ProductHeader }): number {
  for (let index = header.rowIndex + 1; index < Math.min(rows.length, header.rowIndex + 21); index += 1) {
    const row = rows[index] ?? [];
    const sku = productValue(row, header.columns, ["cveprod"], -1);
    const name = productValue(row, header.columns, ["descprod"], -1);
    if (sku && name && parseNumeric(productValue(row, header.columns, ["staiva"], -1)) !== null) return index;
  }
  // The Alpha master template reserves four instruction rows below its headers.
  return Math.min(header.rowIndex + 5, rows.length);
}

function productHeaderKey(value: unknown): string {
  return normalized(value).replace(/[^a-z0-9]/g, "");
}

function productValue(row: Array<string | number>, columns: ProductHeader, aliases: string[], fallback: number): string {
  const column = aliases.map((alias) => columns[alias]).find((candidate) => candidate !== undefined);
  return clean(row[column ?? fallback]);
}

function parseProductTax(staiva: string, porceniva: string): { categoryCode: "IVA16" | "IVA0"; rate: number } | null {
  const status = parseNumeric(staiva);
  const percentage = parseNumeric(porceniva);
  if (status !== 2 || percentage === null) return null;
  if (percentage === 16 || percentage === 0.16) return { categoryCode: "IVA16", rate: 0.16 };
  if (percentage === 0) return { categoryCode: "IVA0", rate: 0 };
  return null;
}

function productSheetKey(value: string): string {
  return productHeaderKey(value);
}

function productSheetFingerprint(rows: Array<Array<string | number>>): string {
  return JSON.stringify(rows.map((row) => row.map(clean)).filter((row) => row.some(Boolean)));
}

function parseInventoryRows(rows: Array<Array<string | number>>) {
  const inventory: InventoryRecord[] = [];
  const rejectedRows: ParsedAlphaFile["rejectedRows"] = [];
  const issues: ImportIssue[] = [];
  const locationByCode = new Map<string, ParsedAlphaFile["locations"][number]>();
  let currentLocation: { code: string; name: string } | null = null;
  let currentAlphaClass: string | null = null;
  const snapshotDate = extractReportDate(rows);

  if (!snapshotDate) {
    issues.push({
      severity: "error",
      code: "FECHA_SNAPSHOT_FALTANTE",
      message: "No se encontró una fecha válida en el encabezado del reporte de existencias de origen.",
    });
  }

  // Alpha's reexic2 has visual headings around row 8. A location starts at Almacén.
  for (let index = 8; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const firstCell = normalized(row[0]);
    if (firstCell === "almacen") {
      const code = clean(row[4]);
      const name = clean(row[9]) || code;
      if (!code) {
        issues.push({
          severity: "error",
          code: "UBICACION_DESCONOCIDA",
          rowNumber: index + 1,
          message: "Se encontró un bloque de Almacén sin clave de ubicación.",
        });
        currentLocation = null;
      } else {
        currentLocation = { code, name };
        currentAlphaClass = null;
        const locationType = classifyAlphaLocation(code, name);
        locationByCode.set(code, {
          externalCode: code,
          name,
          locationType,
          classificationSource: locationType ? "alpha_rule" : null,
        });
        if (!locationType) {
          issues.push({
            severity: "error",
            code: "UBICACION_DESCONOCIDA",
            rowNumber: index + 1,
            locationCode: code,
            message: `La ubicación ${code} (${name}) requiere clasificación manual antes de importarse.`,
          });
        }
      }
      continue;
    }

    if (normalized(row[1]) === "clase") {
      currentAlphaClass = nullIfEmpty(row[4]);
      continue;
    }

    const alphaSku = clean(row[0]);
    const description = clean(row[5]);
    // "Clase" separators and report headings are not inventory rows.
    if (normalized(alphaSku) === "clave" || (!alphaSku && !description)) continue;
    if (!alphaSku && description) {
      issues.push({
        severity: "error",
        code: "SKU_FALTANTE",
        rowNumber: index + 1,
        message: "Existencia sin Clave (SKU) en el reporte de origen.",
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "inventory", normalizedData: { alphaSku: null, description, locationCode: currentLocation?.code ?? null, locationName: currentLocation?.name ?? null } });
      continue;
    }
    if (alphaSku && !description) {
      issues.push({
        severity: "error",
        code: "FORMATO_NO_COMPATIBLE",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} no tiene descripción en el reporte de origen.`,
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "inventory", normalizedData: { alphaSku, description: null, locationCode: currentLocation?.code ?? null, locationName: currentLocation?.name ?? null } });
      continue;
    }

    if (!currentLocation) {
      issues.push({
        severity: "error",
        code: "UBICACION_DESCONOCIDA",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} no pertenece a ningún Almacén detectado.`,
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "inventory", normalizedData: { alphaSku, description, locationCode: null, locationName: null } });
      continue;
    }

    const quantity = numberAt(row, 16, 17);
    const replacementCost = numberAt(row, 25, 26);
    const reportedValue = numberAt(row, 27, 28);
    if (replacementCost !== null && replacementCost < 0) {
      issues.push({
        severity: "error",
        code: "COSTO_NO_VALIDO",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} tiene un costo de reposición negativo.`,
      });
    }
    if (replacementCost === 0) {
      issues.push({
        severity: "warning",
        code: "COSTO_NO_VALIDO",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} tiene un costo de reposición en cero.`,
      });
    }
    if (reportedValue !== null && reportedValue < 0) {
      issues.push({
        severity: "error",
        code: "COSTO_NO_VALIDO",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} tiene un costo total reportado negativo.`,
      });
    }
    if (
      quantity !== null &&
      replacementCost !== null &&
      reportedValue !== null &&
      Math.abs(quantity * replacementCost - reportedValue) > 0.05
    ) {
      issues.push({
        severity: "warning",
        code: "TOTAL_NO_CUADRA",
        rowNumber: index + 1,
        alphaSku,
        message: `El total reportado de ${alphaSku} no coincide con existencia × costo de reposición.`,
      });
    }
    if (quantity === null) {
      issues.push({
        severity: "error",
        code: "FORMATO_NO_COMPATIBLE",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} no tiene una existencia numérica válida.`,
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "inventory", normalizedData: { alphaSku, alphaClass: currentAlphaClass, description, locationCode: currentLocation.code, locationName: currentLocation.name, quantity: null, unit: nullIfEmpty(row[20]), replacementCost, reportedValue, snapshotDate } });
      continue;
    }
    if (quantity < 0) {
      issues.push({
        severity: "error",
        code: "CANTIDAD_NO_VALIDA",
        rowNumber: index + 1,
        alphaSku,
        message: `El SKU ${alphaSku} tiene una existencia negativa.`,
      });
      rejectedRows.push({ rowNumber: index + 1, rawData: row, detectedType: "inventory", normalizedData: { alphaSku, alphaClass: currentAlphaClass, description, locationCode: currentLocation.code, locationName: currentLocation.name, quantity, unit: nullIfEmpty(row[20]), replacementCost, reportedValue, snapshotDate } });
      continue;
    }

    inventory.push({
      rowNumber: index + 1,
      rawData: row,
      alphaSku,
      alphaClass: currentAlphaClass,
      description,
      locationCode: currentLocation.code,
      locationName: currentLocation.name,
      quantity,
      unit: nullIfEmpty(row[20]),
      replacementCost,
      reportedValue,
    });
  }

  if (!inventory.length && !issues.length) {
    issues.push({
      severity: "error",
      code: "FORMATO_NO_COMPATIBLE",
      message: "No se encontraron existencias válidas en el formato reexic2 de origen.",
    });
  }
  return {
    products: [],
    inventory,
    prices: [],
    costs: [],
    sales: [],
    rejectedRows,
    locations: [...locationByCode.values()],
    snapshotDate,
    issues,
  };
}

function parsePriceRows(rows: Array<Array<string | number>>) {
  const prices: PriceRecord[] = [];
  const rejectedRows: ParsedAlphaFile["rejectedRows"] = [];
  const issues: ImportIssue[] = [];
  const seenSkus = new Set<string>();
  const populatedLists = new Set<number>();
  const currencies = new Set<string>();
  const listColumns = [10, 11, 13, 14, 15, 16];
  const snapshotDate = extractReportDate(rows);

  for (let index = 6; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const sourceRowNumber = index + 1;
    const alphaSku = clean(row[3]);
    const description = clean(row[6]);
    if (!alphaSku && !description) continue;
    if (!alphaSku) {
      issues.push({ severity: "error", code: "SKU_FALTANTE", rowNumber: sourceRowNumber * 10, message: "Precio sin Clave (SKU) en los datos de origen." });
      rejectedRows.push({ rowNumber: sourceRowNumber * 10, rawData: row, detectedType: "prices", normalizedData: { sourceRowNumber, alphaSku: null, description } });
      continue;
    }
    if (seenSkus.has(alphaSku)) {
      issues.push({ severity: "error", code: "SKU_DUPLICADO", rowNumber: sourceRowNumber * 10, alphaSku, message: `El SKU ${alphaSku} aparece más de una vez en el reporte de precios.` });
      rejectedRows.push({ rowNumber: sourceRowNumber * 10, rawData: row, detectedType: "prices", normalizedData: { sourceRowNumber, alphaSku, description } });
      continue;
    }
    seenSkus.add(alphaSku);
    const currencyLabel = clean(row[19]);
    if (currencyLabel) currencies.add(currencyLabel);
    let foundPrice = false;
    listColumns.forEach((column, listIndex) => {
      const rawAmount = clean(row[column]);
      if (!rawAmount) return;
      foundPrice = true;
      const listNumber = listIndex + 1;
      populatedLists.add(listNumber);
      const rowNumber = sourceRowNumber * 10 + listNumber;
      const amount = parseNumeric(rawAmount);
      if (amount === null || amount < 0) {
        issues.push({ severity: "error", code: "PRECIO_NO_VALIDO", rowNumber, alphaSku, contextKey: `ALPHA_LIST_${listNumber}`, message: `El SKU ${alphaSku} tiene un precio inválido en Lista ${listNumber}.` });
      } else if (amount === 0) {
        issues.push({ severity: "warning", code: "PRECIO_NO_VALIDO", rowNumber, alphaSku, contextKey: `ALPHA_LIST_${listNumber}`, message: `El SKU ${alphaSku} tiene precio cero en Lista ${listNumber}.` });
      }
      if (amount !== null) prices.push({ rowNumber, sourceRowNumber, rawData: row, alphaSku, alphaClass: nullIfEmpty(row[0]), description, unit: nullIfEmpty(row[8]), listNumber, amount, currencyLabel });
    });
    if (!foundPrice) {
      const rowNumber = sourceRowNumber * 10;
      issues.push({ severity: "warning", code: "PRECIO_FALTANTE", rowNumber, alphaSku, message: `El SKU ${alphaSku} no tiene precio en ninguna lista de origen.` });
      rejectedRows.push({ rowNumber, rawData: row, detectedType: "prices", normalizedData: { sourceRowNumber, alphaSku, description, rejected: true } });
    }
  }
  for (const listNumber of populatedLists) issues.push({ severity: "error", code: "LISTA_PRECIO_SIN_MAPEAR", contextKey: `ALPHA_LIST_${listNumber}`, message: `La lista de origen ${listNumber} requiere asignación comercial antes de importar.` });
  for (const currency of currencies) issues.push({ severity: "error", code: "MONEDA_SIN_MAPEAR", contextKey: currency, message: `La moneda ${currency} requiere confirmación de código ISO.` });
  return { products: [], inventory: [], prices, costs: [], sales: [], rejectedRows, locations: [], snapshotDate, issues };
}

function parseCostRows(rows: Array<Array<string | number>>) {
  const costs: CostRecord[] = [];
  const rejectedRows: ParsedAlphaFile["rejectedRows"] = [];
  const issues: ImportIssue[] = [];
  const seenSkus = new Set<string>();
  const currencies = new Set<string>();
  const snapshotDate = extractReportDate(rows);
  for (let index = 6; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const rowNumber = index + 1;
    const alphaSku = clean(row[3]);
    const description = clean(row[5]);
    if (!alphaSku && !description) continue;
    if (!alphaSku) {
      issues.push({ severity: "error", code: "SKU_FALTANTE", rowNumber, message: "Costo sin Clave (SKU) en los datos de origen." });
      rejectedRows.push({ rowNumber, rawData: row, detectedType: "costs", normalizedData: { alphaSku: null, description } });
      continue;
    }
    if (seenSkus.has(alphaSku)) {
      issues.push({ severity: "error", code: "SKU_DUPLICADO", rowNumber, alphaSku, message: `El SKU ${alphaSku} aparece más de una vez en el reporte de costos.` });
      rejectedRows.push({ rowNumber, rawData: row, detectedType: "costs", normalizedData: { alphaSku, description } });
      continue;
    }
    seenSkus.add(alphaSku);
    const currencyLabel = clean(row[14]);
    if (currencyLabel) currencies.add(currencyLabel);
    const replacementCost = parseNumeric(clean(row[12]));
    const adValorem = parseNumeric(clean(row[17]));
    if (replacementCost === null) issues.push({ severity: "warning", code: "COSTO_FALTANTE", rowNumber, alphaSku, message: `El SKU ${alphaSku} no tiene costo de reposición informado.` });
    else if (replacementCost < 0) issues.push({ severity: "error", code: "COSTO_NO_VALIDO", rowNumber, alphaSku, message: `El SKU ${alphaSku} tiene costo negativo.` });
    else if (replacementCost === 0) issues.push({ severity: "warning", code: "COSTO_NO_VALIDO", rowNumber, alphaSku, message: `El SKU ${alphaSku} tiene costo cero.` });
    costs.push({ rowNumber, rawData: row, alphaSku, alphaClass: nullIfEmpty(row[0]), description, unit: nullIfEmpty(row[8]), replacementCost, currencyLabel, adValorem });
  }
  for (const currency of currencies) issues.push({ severity: "error", code: "MONEDA_SIN_MAPEAR", contextKey: currency, message: `La moneda ${currency} requiere confirmación de código ISO.` });
  return { products: [], inventory: [], prices: [], costs, sales: [], rejectedRows, locations: [], snapshotDate, issues };
}

type SalesColumns = { headerRow: number; detailRow: number; header: Record<string, number>; detail: Record<string, number> };

function parseSalesRows(rows: Array<Array<string | number>>, fileName: string) {
  const sales: SaleRecord[] = [];
  const rejectedRows: ParsedAlphaFile["rejectedRows"] = [];
  const issues: ImportIssue[] = [];
  const columns = findSalesColumns(rows);
  const snapshotDate = extractReportDate(rows) ?? extractDateFromFileName(fileName);
  if (!columns) {
    return {
      products: [], inventory: [], prices: [], costs: [], sales, rejectedRows, locations: [], snapshotDate,
      issues: [{ severity: "error" as const, code: "VENTA_ESTRUCTURA_NO_COMPATIBLE" as const, message: "nvtadesg debe incluir Fecha Alta, Folio, Sucursal y una segunda fila con Clave Prod., Cantidad y Total." }],
    };
  }

  let currentHeader: { saleDate: string; sourceFolio: string; locationCode: string; customerExternalCode: string | null; customerName: string | null; warehouseName: string | null; sourceStatus: string | null; sourceInvoice: string | null } | null = null;
  for (let index = columns.detailRow + 1; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const saleDate = parseAlphaDate(valueAt(row, columns.header, "fecha alta"));
    const sourceFolio = valueAt(row, columns.header, "folio", columns.header.folio - 1);
    const locationCode = valueAt(row, columns.header, "sucursal");
    // The two visual header rows reuse several columns (for example column 5
    // is Sucursal in the header and Descripción in the detail). Date or folio,
    // not any shared column, identifies a new sale header.
    if (saleDate || sourceFolio) {
      if (!saleDate || !sourceFolio || !locationCode) {
        const code = !saleDate ? "VENTA_FECHA_NO_VALIDA" : !sourceFolio ? "VENTA_FOLIO_FALTANTE" : "VENTA_SUCURSAL_FALTANTE";
        issues.push({ severity: "error", code, rowNumber: index + 1, message: `Encabezado de venta incompleto: ${!saleDate ? "Fecha Alta" : !sourceFolio ? "Folio" : "Sucursal"} es obligatorio.` });
        currentHeader = null;
      } else {
        currentHeader = {
          saleDate, sourceFolio, locationCode,
          customerExternalCode: nullIfEmpty(valueAt(row, columns.header, "cliente")),
          customerName: nullIfEmpty(valueAt(row, columns.header, "nombre")),
          warehouseName: nullIfEmpty(valueAt(row, columns.header, "almacen")),
          sourceStatus: nullIfEmpty(valueAt(row, columns.header, "status")),
          sourceInvoice: nullIfEmpty(valueAt(row, columns.header, "factura", columns.header.factura - 3)),
        };
      }
      continue;
    }
    const alphaSku = valueAt(row, columns.detail, "clave prod.");
    const description = nullIfEmpty(valueAt(row, columns.detail, "descripcion"));
    if (!alphaSku && !description) continue;
    if (!currentHeader) {
      issues.push({ severity: "error", code: "VENTA_ESTRUCTURA_NO_COMPATIBLE", rowNumber: index + 1, alphaSku: alphaSku || undefined, message: "La partida de venta no tiene un encabezado válido de Fecha Alta, Folio y Sucursal." });
      rejectedRows.push({ rowNumber: index + 1, rawData: compactSalesRaw(row, columns), detectedType: "sales", normalizedData: { alphaSku: alphaSku || null, description } });
      continue;
    }
    if (!alphaSku) {
      issues.push({ severity: "error", code: "SKU_FALTANTE", rowNumber: index + 1, message: "Partida de venta sin Clave Prod." });
      rejectedRows.push({ rowNumber: index + 1, rawData: compactSalesRaw(row, columns), detectedType: "sales", normalizedData: { ...currentHeader, alphaSku: null, description } });
      continue;
    }
    const quantity = parseNumeric(valueAt(row, columns.detail, "cantidad", 20));
    const lineTotal = parseNumeric(valueAt(row, columns.detail, "total", 37));
    if (quantity === null || quantity <= 0) {
      issues.push({ severity: "error", code: "CANTIDAD_NO_VALIDA", rowNumber: index + 1, alphaSku, locationCode: currentHeader.locationCode, message: `La partida ${alphaSku} tiene una cantidad no válida.` });
    }
    if (lineTotal !== null && lineTotal < 0) {
      issues.push({ severity: "error", code: "VENTA_TOTAL_NO_VALIDO", rowNumber: index + 1, alphaSku, locationCode: currentHeader.locationCode, message: `La partida ${alphaSku} tiene un total negativo.` });
    }
    if (quantity === null || quantity <= 0 || (lineTotal !== null && lineTotal < 0)) {
      rejectedRows.push({ rowNumber: index + 1, rawData: compactSalesRaw(row, columns), detectedType: "sales", normalizedData: { ...currentHeader, alphaSku, description, quantity, lineTotal } });
      continue;
    }
    const unitPrice = parseNumeric(valueAt(row, columns.detail, "pr. unitario"));
    const sourceTax = parseNumeric(valueAt(row, columns.detail, "dcto", 27));
    sales.push({
      rowNumber: index + 1, rawData: compactSalesRaw(row, columns), ...currentHeader, alphaSku, description,
      unit: nullIfEmpty(valueAt(row, columns.detail, "unidad", 17)), quantity,
      unitPrice,
      taxAmount: lineTotal !== null && unitPrice !== null ? Math.max(0, lineTotal - (unitPrice * quantity)) : sourceTax,
      discountAmount: 0,
      lineAmount: parseNumeric(valueAt(row, columns.detail, "importe")), lineTotal,
      discountPercent: parseNumeric(valueAt(row, columns.detail, "descuentos %", 42)),
      lot: nullIfEmpty(valueAt(row, columns.detail, "lote")),
    });
  }
  if (!sales.length && !issues.length) issues.push({ severity: "error", code: "VENTA_ESTRUCTURA_NO_COMPATIBLE", message: "No se encontraron partidas válidas en nvtadesg." });
  return { products: [], inventory: [], prices: [], costs: [], sales, rejectedRows, locations: [], snapshotDate, issues };
}

function findSalesColumns(rows: Array<Array<string | number>>): SalesColumns | null {
  for (let index = 0; index < Math.min(rows.length - 1, 20); index += 1) {
    const header = headerMap(rows[index] ?? []);
    const detail = headerMap(rows[index + 1] ?? []);
    if (header["fecha alta"] !== undefined && header.folio !== undefined && header.sucursal !== undefined
      && detail["clave prod."] !== undefined && detail.cantidad !== undefined && detail.total !== undefined) {
      return { headerRow: index, detailRow: index + 1, header, detail };
    }
  }
  return null;
}

function headerMap(row: Array<string | number>) {
  const map: Record<string, number> = {};
  row.forEach((cell, index) => { const key = normalized(cell); if (key && map[key] === undefined) map[key] = index; });
  return map;
}

function valueAt(row: Array<string | number>, columns: Record<string, number>, key: string, ...fallbacks: number[]) {
  for (const index of [columns[key], ...fallbacks]) {
    if (!Number.isInteger(index)) continue;
    const value = clean(row[index]);
    if (value) return value;
  }
  return "";
}

function compactSalesRaw(row: Array<string | number>, columns: SalesColumns): Array<string | number> {
  return [
    valueAt(row, columns.header, "fecha alta"), valueAt(row, columns.header, "folio"), valueAt(row, columns.header, "sucursal"),
    valueAt(row, columns.header, "cliente"), valueAt(row, columns.header, "nombre"), valueAt(row, columns.header, "status"),
    valueAt(row, columns.detail, "clave prod."), valueAt(row, columns.detail, "descripcion"), valueAt(row, columns.detail, "cantidad", 20), valueAt(row, columns.detail, "total", 37),
  ];
}

export function classifyAlphaLocation(code: string, name: string): LocationType | null {
  const source = `${normalized(code)} ${normalized(name)}`;
  if (/\bsuc(?:ursal)?\b/.test(source)) return "sucursal";
  if (normalized(code) === "general" || /almacen\s+(general|central)|central/.test(source)) {
    return "almacen_central";
  }
  if (/asesor|ingenier[oa]|campo/.test(source)) return "campo";
  if (/almacen|bodega/.test(source)) return "almacen_operativo";
  return null;
}

function extractReportDate(rows: Array<Array<string | number>>): string | null {
  for (const row of rows.slice(0, 12)) {
    const values = row.map(clean);
    for (let index = 0; index < values.length; index += 1) {
      if (normalized(values[index]) !== "fecha:") continue;
      for (const candidate of values.slice(index + 1)) {
        const parsed = parseAlphaDate(candidate);
        if (parsed) return parsed;
      }
    }
    for (const value of values) {
      const match = value.match(/fecha\s*:\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})/i);
      if (match) return parseAlphaDate(match[1]);
    }
  }
  return null;
}

function extractDateFromFileName(fileName: string): string | null {
  const match = fileName.match(/(?:^|_)(20\d{2})(\d{2})(\d{2})(?:_|\.)/);
  if (!match) return null;
  const [, year, month, day] = match;
  const candidate = `${year}-${month}-${day}`;
  const date = new Date(`${candidate}T00:00:00Z`);
  return Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== candidate ? null : candidate;
}

function parseAlphaDate(value: string): string | null {
  const match = clean(value).match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$/);
  if (!match) return null;
  const [, dayRaw, monthRaw, yearRaw] = match;
  const day = Number(dayRaw);
  const month = Number(monthRaw);
  const year = Number(yearRaw.length === 2 ? `20${yearRaw}` : yearRaw);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return `${year.toString().padStart(4, "0")}-${month.toString().padStart(2, "0")}-${day.toString().padStart(2, "0")}`;
}

function clean(value: unknown): string {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function nullIfEmpty(value: unknown): string | null {
  return clean(value) || null;
}

function normalized(value: unknown): string {
  return clean(value)
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function numberAt(row: Array<string | number>, ...positions: number[]): number | null {
  for (const position of positions) {
    const raw = clean(row[position]);
    if (!raw) continue;
    const value = Number(raw.replace(/[$,\s]/g, ""));
    if (Number.isFinite(value)) return value;
  }
  return null;
}

function parseNumeric(raw: string): number | null {
  if (!raw) return null;
  const value = Number(raw.replace(/[$,\s]/g, ""));
  return Number.isFinite(value) ? value : null;
}

async function sha256(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join("");
}
