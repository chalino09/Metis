export type RestaurantImportRole = "dish" | "ingredient" | "preparation";

export type RestaurantCatalogImportRow = {
  internal_sku: string;
  name: string;
  barcode: string;
  unit: string;
  product_group: string;
  is_active: boolean;
  is_sellable: boolean;
  tax_category_code: string;
  purchase_unit_code: string;
  base_units_per_purchase_unit: number | null;
  lot_controlled: boolean;
};

export type RestaurantCatalogImportPreview = {
  rows: RestaurantCatalogImportRow[];
  errors: string[];
  fileName: string;
};

const headerAliases: Record<string, keyof RestaurantCatalogImportRow> = {
  codigo: "internal_sku",
  codigo_satrapy: "internal_sku",
  sku: "internal_sku",
  nombre: "name",
  nombre_del_producto: "name",
  codigo_de_barras: "barcode",
  codigo_barras: "barcode",
  unidad: "unit",
  unidad_de_consumo: "unit",
  categoria: "product_group",
  categoria_culinaria: "product_group",
  activo: "is_active",
  vendible: "is_sellable",
  categoria_fiscal: "tax_category_code",
  categoria_fiscal_codigo: "tax_category_code",
  presentacion_de_compra: "purchase_unit_code",
  presentacion_compra: "purchase_unit_code",
  contenido_por_presentacion: "base_units_per_purchase_unit",
  contenido_neto: "base_units_per_purchase_unit",
  lote_y_caducidad: "lot_controlled",
  controlar_lote: "lot_controlled",
};

function normalizedHeader(value: unknown) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

function text(value: unknown) {
  return String(value ?? "").trim();
}

function booleanValue(value: unknown, fallback: boolean) {
  if (value === undefined || value === null || text(value) === "") return fallback;
  const normalized = text(value).toLowerCase();
  if (["si", "sí", "s", "true", "1", "activo", "activa"].includes(normalized)) return true;
  if (["no", "n", "false", "0", "inactivo", "inactiva"].includes(normalized)) return false;
  return fallback;
}

function unitCode(value: unknown) {
  const normalized = text(value).toLowerCase();
  if (["pieza", "piezas", "pza", "unidad", "unidades", "ea"].includes(normalized)) return "piece";
  return normalized;
}

export async function parseRestaurantCatalogFile(file: File, role: RestaurantImportRole): Promise<RestaurantCatalogImportPreview> {
  if (!/\.(csv|xlsx?)$/i.test(file.name)) return { rows: [], errors: ["Selecciona un archivo CSV o Excel."], fileName: file.name };
  const XLSX = await import("xlsx");
  const workbook = XLSX.read(await file.arrayBuffer(), { type: "array", cellDates: false });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  if (!sheet) return { rows: [], errors: ["El archivo no contiene una hoja para importar."], fileName: file.name };
  const raw = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: "", raw: false });
  if (raw.length > 500) return { rows: [], errors: ["El archivo supera el máximo de 500 registros por lote."], fileName: file.name };

  const rows: RestaurantCatalogImportRow[] = [];
  const errors: string[] = [];
  raw.forEach((source, index) => {
    const mapped: Partial<Record<keyof RestaurantCatalogImportRow, unknown>> = {};
    for (const [header, value] of Object.entries(source)) {
      const key = headerAliases[normalizedHeader(header)];
      if (key) mapped[key] = value;
    }
    const rowNumber = index + 2;
    const name = text(mapped.name);
    const unit = role === "dish" ? "piece" : role === "preparation" ? "" : unitCode(mapped.unit);
    const purchaseUnit = text(mapped.purchase_unit_code).toUpperCase();
    const factorText = text(mapped.base_units_per_purchase_unit).replace(",", ".");
    const factor = factorText ? Number(factorText) : null;
    if (!name) errors.push(`Fila ${rowNumber}: escribe el nombre.`);
    if (role === "ingredient" && !["mg", "g", "kg", "ml", "l", "piece"].includes(unit)) errors.push(`Fila ${rowNumber}: usa una unidad válida (g, kg, ml, l o pieza).`);
    if (role === "ingredient" && !purchaseUnit) errors.push(`Fila ${rowNumber}: indica la presentación de compra.`);
    if (role === "ingredient" && (!(factor && Number.isFinite(factor)) || factor <= 0)) errors.push(`Fila ${rowNumber}: el contenido por presentación debe ser mayor que cero.`);
    rows.push({
      internal_sku: text(mapped.internal_sku).toUpperCase(),
      name,
      barcode: text(mapped.barcode),
      unit,
      product_group: text(mapped.product_group),
      is_active: booleanValue(mapped.is_active, true),
      is_sellable: role === "dish" && booleanValue(mapped.is_sellable, false),
      tax_category_code: role === "dish" ? text(mapped.tax_category_code).toUpperCase() : "",
      purchase_unit_code: role === "ingredient" ? purchaseUnit : "",
      base_units_per_purchase_unit: role === "ingredient" ? factor : null,
      lot_controlled: role === "ingredient" && booleanValue(mapped.lot_controlled, false),
    });
  });
  if (!raw.length) errors.push("El archivo no contiene registros.");
  return { rows, errors, fileName: file.name };
}

export async function downloadRestaurantCatalogTemplate(role: RestaurantImportRole) {
  const XLSX = await import("xlsx");
  const sample = role === "ingredient"
    ? [{ codigo: "", nombre: "Tomate saladet", categoria: "Frutas y verduras", unidad: "g", codigo_barras: "", presentacion_compra: "CAJA", contenido_por_presentacion: 10000, lote_y_caducidad: "No", activo: "Sí" }]
    : role === "preparation"
      ? [{ codigo: "", nombre: "Salsa roja", categoria: "Salsas", activo: "Sí" }]
      : [{ codigo: "", nombre: "Enchiladas rojas", categoria: "Platos fuertes", categoria_fiscal_codigo: "IVA16", vendible: "Sí", activo: "Sí" }];
  const sheet = XLSX.utils.json_to_sheet(sample);
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, sheet, role === "ingredient" ? "Insumos" : role === "preparation" ? "Bases" : "Menu");
  XLSX.writeFile(workbook, `plantilla_${role === "ingredient" ? "insumos" : role === "preparation" ? "bases" : "menu"}_restaurant.xlsx`);
}
