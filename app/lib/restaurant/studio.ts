export type CulinaryRole = "dish" | "ingredient" | "preparation";
export type CatalogItem = {
  id: string;
  name: string;
  internal_sku: string;
  unit: string;
  product_group: string | null;
  is_active: boolean;
  is_sellable: boolean;
  price: number | null;
  currency_code: string | null;
  pos_ready: boolean;
  blockers: string[];
  recipe_status?: "active" | "draft" | "missing";
  purchase_unit_code?: string;
  base_units_per_purchase_unit?: number;
  usage_count?: number;
  recipe_yield_quantity?: number;
  recipe_yield_unit_code?: string;
  recipe_portion_count?: number;
  location_status?: LocationStatus[];
  ready_location_count?: number;
  offered_location_count?: number;
  image_data?: string | null;
};
export type ComponentOption = {
  id: string;
  name: string;
  internal_sku: string;
  unit: string;
  catalog_role: "ingredient" | "preparation";
  recipe_kind: "preparation" | null;
};
export type RecipeLine = ComponentOption & {
  quantity: string;
  unit_code: string;
  notes?: string | null;
};
export type CostPreview = {
  allowed: boolean;
  can_view: boolean;
  total_cost: number | null;
  cost_per_portion: number | null;
  currency_code: string;
  lines: { product_id: string; cost: number | null; message?: string }[];
};
export type RecipeVersion = {
  id: string;
  status: string;
  waste_percent: number;
  yield_quantity: number;
  yield_unit_code: string;
  portion_count: number;
  components: {
    product_id: string;
    product_name: string;
    product_code: string;
    entered_quantity: number;
    entered_unit_code: string;
    base_unit_code: string;
    catalog_role: CulinaryRole;
    notes?: string | null;
  }[];
};
export type LocationStatus = {
  id: string;
  name: string;
  available: boolean;
  message: string;
};
export type StudioContext = {
  location_status: LocationStatus[];
  currency_code: string;
  recipe_revision: string;
  product: {
    id: string;
    name: string;
    internal_sku: string;
    unit: string;
    barcode: string | null;
    product_group: string | null;
    tax_category_id: string | null;
    is_sellable: boolean;
    is_active: boolean;
    lot_controlled: boolean;
    updated_at: string;
  } | null;
  recipe: { active: RecipeVersion | null; draft: RecipeVersion | null } | null;
  presentation: {
    image_data: string | null;
    description: string;
    batch_portions: number;
    revision: number;
  } | null;
  tax_categories: {
    id: string;
    name: string;
    rate: number | null;
    is_active: boolean;
  }[];
  price_lists: {
    id: string;
    name: string;
    currency_code: string;
    is_default: boolean;
  }[];
  prices: { price_list_id: string; amount: number; final_price: number }[];
  assortments: {
    id: string;
    name: string;
    included: boolean;
    locations: { id: string; name: string }[];
  }[];
  locations: { id: string; name: string }[];
  purchase: {
    purchase_unit: string;
    base_units_per_purchase_unit: number;
  } | null;
  cost: {
    cost_method?: "average_cost" | "replacement_cost" | "standard_cost";
    matrix_ready: boolean;
    currency_code: string;
    current_cost: { id: string; amount: number } | null;
  } | null;
  bundle: BundleDraft | null;
};
export type BundleDraft = {
  is_active: boolean;
  combo_price_amount: string;
  groups: {
    name: string;
    minimum_selections: number;
    maximum_selections: number;
    options: { id: string; name: string }[];
  }[];
  extras: { id: string; name: string }[];
};

export const categories: Record<CulinaryRole, string[]> = {
  dish: [
    "Desayunos",
    "Entradas",
    "Sopas y ensaladas",
    "Platos fuertes",
    "Guarniciones",
    "Postres",
    "Bebidas",
    "Extras",
  ],
  ingredient: [
    "Proteínas",
    "Frutas y verduras",
    "Lácteos y huevos",
    "Granos, cereales y harinas",
    "Abarrotes y secos",
    "Condimentos y especias",
    "Pan y tortillas",
    "Bebidas e insumos líquidos",
  ],
  preparation: [
    "Salsas",
    "Aderezos",
    "Caldos y fondos",
    "Marinados",
    "Masas",
    "Cremas y bases",
    "Guarniciones base",
  ],
};
const units: Record<
  string,
  { dimension: string; scale: number; label: string }
> = {
  mg: { dimension: "mass", scale: 0.001, label: "mg" },
  g: { dimension: "mass", scale: 1, label: "g" },
  kg: { dimension: "mass", scale: 1000, label: "kg" },
  ml: { dimension: "volume", scale: 1, label: "ml" },
  l: { dimension: "volume", scale: 1000, label: "l" },
  piece: { dimension: "count", scale: 1, label: "piezas" },
};
export function canonicalUnit(value: string) {
  const key = value.trim().toLowerCase();
  return ["pza", "pieza", "piezas", "ea"].includes(key) ? "piece" : key;
}
export function compatibleUnits(base: string) {
  const dimension = units[canonicalUnit(base)]?.dimension;
  return Object.entries(units)
    .filter(([, unit]) => unit.dimension === dimension)
    .map(([value, unit]) => ({ value, label: unit.label }));
}
export function unitLabel(value: string) {
  return units[canonicalUnit(value)]?.label ?? value;
}
export function purchaseFactor(purchase: string, base: string) {
  const from = units[canonicalUnit(purchase)],
    to = units[canonicalUnit(base)];
  return from && to && from.dimension === to.dimension
    ? from.scale / to.scale
    : null;
}
export function numberValue(value: string) {
  return value.trim() ? Number(value.replace(",", ".")) : NaN;
}
export function recipeComponents(lines: RecipeLine[]) {
  return lines.map((line, index) => ({
    product_id: line.id,
    quantity: numberValue(line.quantity),
    unit_code: line.unit_code,
    base_unit_code: canonicalUnit(line.unit),
    sort_order: index,
    ...(line.notes != null ? { notes: line.notes } : {}),
  }));
}
export function netMargin(
  finalPrice: number,
  taxRate: number | null,
  cost: number | null,
) {
  if (
    !Number.isFinite(finalPrice) ||
    finalPrice <= 0 ||
    taxRate == null ||
    !Number.isFinite(taxRate) ||
    cost == null ||
    !Number.isFinite(cost)
  )
    return null;
  const net = finalPrice / (1 + taxRate),
    amount = net - cost;
  return { net, amount, percent: (amount / net) * 100 };
}
export function money(value: number | null | undefined, currency = "MXN") {
  return value == null || !Number.isFinite(value)
    ? "Por calcular"
    : new Intl.NumberFormat("es-MX", {
        style: "currency",
        currency,
        maximumFractionDigits: 2,
      }).format(value);
}
export function restaurantError(error: unknown) {
  const message =
    error && typeof error === "object" && "message" in error
      ? String(error.message)
      : "No se pudo completar la operación. Intenta nuevamente.";
  if (/schema cache|does not exist|could not find the function/i.test(message))
    return "La actualización de Restaurante todavía no está instalada en esta base de datos. Tus datos se conservan; solicita aplicar la actualización y vuelve a intentar.";
  if (/matriz contable|configuración contable aprobada/i.test(message))
    return "La política de costos todavía no está configurada. Puedes guardar el insumo sin costo y pedir al administrador que complete la configuración de costos.";
  if (
    /sale_cart_bundle_selections.*foreign key|foreign key.*sale_cart_bundle_selections/i.test(
      message,
    )
  )
    return "Hay una venta en curso usando estas opciones. Termina o cancela esa venta antes de quitar el grupo.";
  return message.replace(/^.*?error:\s*/i, "");
}
