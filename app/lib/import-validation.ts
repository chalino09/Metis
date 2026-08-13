import type { SupabaseClient } from "@supabase/supabase-js";
import type { ImportIssue, ParsedAlphaFile } from "@/app/lib/types";

/**
 * Commercial and inventory reports may only reference Alpha SKUs that already
 * exist in the company's product master. This check intentionally runs with
 * the caller's JWT; it never bypasses RLS with an administrative key.
 */
export async function validateReferencedProducts(
  parsed: ParsedAlphaFile,
  companyId: string,
  supabase: SupabaseClient,
): Promise<ImportIssue[]> {
  const referencedRows = parsed.importKind === "inventory" ? parsed.inventory
    : parsed.importKind === "prices" ? parsed.prices
      : parsed.importKind === "costs" ? parsed.costs
        : parsed.importKind === "sales" ? parsed.sales : [];
  if (!referencedRows.length) return [];

  const skus = [...new Set(referencedRows.map((row) => row.alphaSku))];
  const found = new Set<string>();
  for (const group of chunk(skus, 200)) {
    const { data, error } = await supabase
      .from("products")
      .select("alpha_sku")
      .eq("company_id", companyId)
      .in("alpha_sku", group);
    if (error) throw error;
    (data ?? []).forEach((product) => found.add(product.alpha_sku));
  }

  return referencedRows
    .filter((row) => !found.has(row.alphaSku))
    .map((row) => ({
      severity: "error" as const,
      code: "PRODUCTO_INEXISTENTE" as const,
      rowNumber: row.rowNumber,
      alphaSku: row.alphaSku,
      message: `El SKU ${row.alphaSku} no existe en Productos. Importa primero cata_prd.`,
    }));
}

/** Sales staging is evidence-only, but its branch and product references must
 * still be visible before a future, separately-approved historical promotion. */
export async function validateReferencedSales(
  parsed: ParsedAlphaFile,
  companyId: string,
  supabase: SupabaseClient,
): Promise<ImportIssue[]> {
  if (parsed.importKind !== "sales" || !parsed.sales.length) return [];
  const issues: ImportIssue[] = [];
  const { data, error } = await supabase.from("locations").select("id,external_code,name").eq("company_id", companyId).eq("is_active", true);
  if (error) throw error;
  const canonicalByLabel = new Map<string, { id: string; external_code: string }>();
  for (const location of data ?? []) {
    canonicalByLabel.set(normalizedLocationLabel(location.external_code), location);
    canonicalByLabel.set(normalizedLocationLabel(location.name), location);
  }
  const dominantWarehouseByCode = deriveDominantWarehouseByCode(parsed.sales);
  for (const row of parsed.sales) {
    const direct = canonicalByLabel.get(normalizedLocationLabel(row.locationCode));
    const dominantWarehouse = dominantWarehouseByCode.get(normalizedLocationLabel(row.locationCode));
    const inferred = dominantWarehouse ? canonicalByLabel.get(dominantWarehouse) : undefined;
    const rowWarehouse = row.warehouseName ? normalizedLocationLabel(row.warehouseName) : null;
    const conflict = Boolean(rowWarehouse && dominantWarehouse && rowWarehouse !== dominantWarehouse);
    const resolved = conflict ? undefined : direct ?? inferred;
    row.canonicalLocationId = resolved?.id ?? null;
    row.canonicalLocationCode = resolved?.external_code ?? null;
    if (conflict) {
      issues.push({ severity: "warning", code: "UBICACION_CONFLICTO", rowNumber: row.rowNumber, alphaSku: row.alphaSku, locationCode: row.locationCode, message: `La abreviatura ${row.locationCode} normalmente corresponde a ${dominantWarehouse}; esta fila declara ${row.warehouseName}. Requiere revisión.` });
    } else if (!resolved) {
      issues.push({ severity: "warning", code: "UBICACION_DESCONOCIDA", rowNumber: row.rowNumber, alphaSku: row.alphaSku, locationCode: row.locationCode, message: `La sucursal ${row.locationCode} no coincide con una ubicación canónica; la venta queda como evidencia en staging.` });
    }
  }
  return issues;
}

export function deriveDominantWarehouseByCode(rows: ParsedAlphaFile["sales"]) {
  const counts = new Map<string, Map<string, number>>();
  for (const row of rows) {
    if (!row.locationCode || !row.warehouseName) continue;
    const code = normalizedLocationLabel(row.locationCode);
    const warehouse = normalizedLocationLabel(row.warehouseName);
    const warehouses = counts.get(code) ?? new Map<string, number>();
    warehouses.set(warehouse, (warehouses.get(warehouse) ?? 0) + 1);
    counts.set(code, warehouses);
  }
  return new Map([...counts].map(([code, warehouses]) => [code, [...warehouses].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))[0]![0]]));
}

function normalizedLocationLabel(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").trim().toUpperCase();
}

function chunk<T>(items: T[], size: number) {
  const groups: T[][] = [];
  for (let index = 0; index < items.length; index += size) groups.push(items.slice(index, index + size));
  return groups;
}
