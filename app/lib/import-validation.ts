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
      : parsed.importKind === "costs" ? parsed.costs : [];
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

function chunk<T>(items: T[], size: number) {
  const groups: T[][] = [];
  for (let index = 0; index < items.length; index += size) groups.push(items.slice(index, index + size));
  return groups;
}
