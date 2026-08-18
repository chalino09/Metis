import type { ImportIssue, ParsedAlphaFile } from "@/app/lib/types";

export type StagingRowPayload = {
  row_number: number;
  source_file: string;
  detected_type: "products" | "inventory" | "prices" | "costs" | "sales";
  raw_data: { cells: Array<string | number> };
  normalized_data: Record<string, unknown>;
  validation_status: "valid" | "warning" | "error";
};

export type StagingErrorPayload = {
  severity: "error" | "warning";
  error_code: string;
  message: string;
  row_number: number | null;
  alpha_sku: string | null;
  location_code: string | null;
  context_key: string | null;
};

export function buildStagingPayload(
  parsed: ParsedAlphaFile,
  additionalIssues: ImportIssue[] = [],
): { rows: StagingRowPayload[]; errors: StagingErrorPayload[] } {
  const locationByCode = new Map(parsed.locations.map((location) => [location.externalCode, location]));
  const locationErrors = parsed.inventory
    .filter((row) => !locationByCode.get(row.locationCode)?.locationType)
    .map<ImportIssue>((row) => ({
      severity: "error",
      code: "UBICACION_DESCONOCIDA",
      rowNumber: row.rowNumber,
      alphaSku: row.alphaSku,
      locationCode: row.locationCode,
      message: `La ubicación ${row.locationCode} (${row.locationName}) requiere clasificación manual antes de importarse.`,
    }));
  const issues = [
    ...parsed.issues.filter((issue) => !(issue.code === "UBICACION_DESCONOCIDA" && issue.locationCode)),
    ...locationErrors,
    ...additionalIssues,
  ];
  const issueByRow = new Map<number, ImportIssue[]>();
  for (const issue of issues) {
    if (!issue.rowNumber) continue;
    issueByRow.set(issue.rowNumber, [...(issueByRow.get(issue.rowNumber) ?? []), issue]);
  }
  const statusFor = (rowNumber: number): StagingRowPayload["validation_status"] => {
    const rowIssues = issueByRow.get(rowNumber) ?? [];
    if (rowIssues.some((issue) => issue.severity === "error")) return "error";
    if (rowIssues.some((issue) => issue.severity === "warning")) return "warning";
    return "valid";
  };

  let acceptedRows: StagingRowPayload[] = [];
  if (parsed.importKind === "products") acceptedRows = parsed.products.map((row) => ({
      row_number: row.rowNumber,
      source_file: parsed.fileName,
      detected_type: "products",
      raw_data: { cells: row.rawData },
      normalized_data: {
        alphaSku: row.alphaSku,
        alphaClass: row.alphaClass,
        name: row.name,
        attribute: row.attribute,
        unit: row.unit,
        productGroup: row.productGroup,
        subgroup: row.subgroup,
        productType: row.productType,
        staiva: row.staiva,
        porceniva: row.porceniva,
        taxCategoryCode: row.taxCategoryCode,
        taxRate: row.taxRate,
        priceTiers: row.priceTiers,
      },
      validation_status: statusFor(row.rowNumber),
    }));
  if (parsed.importKind === "inventory") acceptedRows = parsed.inventory.map((row) => {
      const location = locationByCode.get(row.locationCode);
      return {
        row_number: row.rowNumber,
        source_file: parsed.fileName,
        detected_type: "inventory" as const,
        raw_data: { cells: row.rawData },
        normalized_data: {
          alphaSku: row.alphaSku,
          alphaClass: row.alphaClass,
          description: row.description,
          locationCode: row.locationCode,
          locationName: row.locationName,
          locationType: location?.locationType ?? null,
          classificationSource: location?.classificationSource ?? null,
          quantity: row.quantity,
          unit: row.unit,
          replacementCost: row.replacementCost,
          reportedValue: row.reportedValue,
          snapshotDate: parsed.snapshotDate,
        },
        validation_status: statusFor(row.rowNumber),
      };
    });
  if (parsed.importKind === "prices") acceptedRows = parsed.prices.map((row) => ({
    row_number: row.rowNumber,
    source_file: parsed.fileName,
    detected_type: "prices",
    raw_data: { cells: row.rawData },
    normalized_data: {
      sourceRowNumber: row.sourceRowNumber,
      alphaSku: row.alphaSku,
      alphaClass: row.alphaClass,
      description: row.description,
      unit: row.unit,
      listNumber: row.listNumber,
      listExternalCode: `ALPHA_LIST_${row.listNumber}`,
      semanticCode: null,
      amount: row.amount,
      currencyLabel: row.currencyLabel,
      currencyCode: null,
      effectiveDate: parsed.snapshotDate,
    },
    validation_status: statusFor(row.rowNumber),
  }));
  if (parsed.importKind === "costs") acceptedRows = parsed.costs.map((row) => ({
    row_number: row.rowNumber,
    source_file: parsed.fileName,
    detected_type: "costs",
    raw_data: { cells: row.rawData },
    normalized_data: {
      alphaSku: row.alphaSku,
      alphaClass: row.alphaClass,
      description: row.description,
      unit: row.unit,
      replacementCost: row.replacementCost,
      currencyLabel: row.currencyLabel,
      currencyCode: null,
      adValorem: row.adValorem,
      effectiveDate: parsed.snapshotDate,
    },
    validation_status: statusFor(row.rowNumber),
  }));
  if (parsed.importKind === "sales") acceptedRows = parsed.sales.map((row) => ({
    row_number: row.rowNumber,
    source_file: parsed.fileName,
    detected_type: "sales",
    raw_data: { cells: row.rawData },
    normalized_data: {
      evidenceKind: "sale_line",
      saleDate: row.saleDate,
      sourceFolio: row.sourceFolio,
      locationCode: row.locationCode,
      canonicalLocationId: row.canonicalLocationId ?? null,
      canonicalLocationCode: row.canonicalLocationCode ?? null,
      customerExternalCode: row.customerExternalCode,
      customerName: row.customerName,
      warehouseName: row.warehouseName,
      sourceStatus: row.sourceStatus,
      sourceInvoice: row.sourceInvoice,
      alphaSku: row.alphaSku,
      description: row.description,
      unit: row.unit,
      quantity: row.quantity,
      unitPrice: row.unitPrice,
      taxAmount: row.taxAmount,
      discountAmount: row.discountAmount,
      lineAmount: row.lineAmount,
      lineTotal: row.lineTotal,
      discountPercent: row.discountPercent,
      lot: row.lot,
      evidenceOnly: true,
    },
    validation_status: statusFor(row.rowNumber),
  }));

  const rejectedRows: StagingRowPayload[] = parsed.rejectedRows.map((row) => {
    const locationCode = typeof row.normalizedData.locationCode === "string" ? row.normalizedData.locationCode : null;
    const location = locationCode ? locationByCode.get(locationCode) : null;
    return {
      row_number: row.rowNumber,
      source_file: parsed.fileName,
      detected_type: row.detectedType,
      raw_data: { cells: row.rawData },
      normalized_data: {
        ...row.normalizedData,
        rejected: true,
        ...(row.detectedType === "inventory" && location ? {
          locationType: location.locationType,
          classificationSource: location.classificationSource,
          snapshotDate: parsed.snapshotDate,
        } : {}),
      },
      validation_status: statusFor(row.rowNumber),
    };
  });
  const rows = [...acceptedRows, ...rejectedRows].sort((first, second) => first.row_number - second.row_number);

  return {
    rows,
    errors: issues.map((issue) => ({
      severity: issue.severity,
      error_code: issue.code,
      message: issue.message,
      row_number: issue.rowNumber ?? null,
      alpha_sku: issue.alphaSku ?? null,
      location_code: issue.locationCode ?? null,
      context_key: issue.contextKey ?? null,
    })),
  };
}
