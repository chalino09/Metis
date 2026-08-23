export const PRODUCT_READINESS_LABELS: Record<string, string> = {
  inactive: "Producto inactivo",
  not_sellable: "No marcado como vendible",
  commercial_review_required: "Clasificación comercial pendiente",
  inventory_setup_required: "Inventario pendiente de preparar",
  missing_sales_unit: "Sin unidad de venta",
  missing_tax_category: "Sin categoría fiscal",
  missing_current_tax_rate: "Sin tasa fiscal vigente",
  missing_or_zero_price: "Sin precio vigente",
  missing_active_recipe: "Sin receta activa",
  invalid_recipe_components: "Receta con componentes no permitidos",
  outside_assortment: "Sin sucursales de venta",
  out_of_stock: "Sin existencia",
};

export function productReadinessLabel(code: string) {
  return PRODUCT_READINESS_LABELS[code] ?? code.replaceAll("_", " ");
}

export function productReadinessSummary(blockers: string[] | null | undefined) {
  if (!blockers?.length) return "Sin bloqueos";
  return blockers.map(productReadinessLabel).join(" · ");
}
