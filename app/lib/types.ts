export type AppRoleCode =
  | "super_admin"
  | "direccion_admin"
  | "supervisor_sucursal"
  | "sucursal"
  | "ingeniero_campo"
  | "almacen"
  | "punto_venta";

export type RoleOption = {
  code: AppRoleCode;
  display_name: string;
};

export type LocationType = "sucursal" | "almacen_central" | "almacen_operativo" | "campo";

export type LocationClassificationSource = "alpha_rule" | "manual_review";

export type ProductRecord = {
  rowNumber: number;
  rawData: Array<string | number>;
  alphaSku: string;
  alphaClass: string | null;
  name: string;
  attribute: string | null;
  unit: string | null;
  productGroup: string | null;
  subgroup: string | null;
  productType: string | null;
  staiva: string | null;
  porceniva: string | null;
  taxCategoryCode: "IVA16" | "IVA0" | null;
  taxRate: number | null;
};

export type InventoryRecord = {
  rowNumber: number;
  rawData: Array<string | number>;
  alphaSku: string;
  alphaClass: string | null;
  description: string;
  locationCode: string;
  locationName: string;
  quantity: number;
  unit: string | null;
  replacementCost: number | null;
  reportedValue: number | null;
};

export type PriceRecord = {
  rowNumber: number;
  sourceRowNumber: number;
  rawData: Array<string | number>;
  alphaSku: string;
  alphaClass: string | null;
  description: string;
  unit: string | null;
  listNumber: number;
  amount: number;
  currencyLabel: string;
};

export type CostRecord = {
  rowNumber: number;
  rawData: Array<string | number>;
  alphaSku: string;
  alphaClass: string | null;
  description: string;
  unit: string | null;
  replacementCost: number | null;
  currencyLabel: string;
  adValorem: number | null;
};

export type RejectedImportRow = {
  rowNumber: number;
  rawData: Array<string | number>;
  detectedType: "products" | "inventory" | "prices" | "costs";
  normalizedData: Record<string, unknown>;
};

export type ImportIssue = {
  severity: "error" | "warning";
  code:
    | "SKU_FALTANTE"
    | "SKU_DUPLICADO"
    | "PRODUCTO_INEXISTENTE"
    | "UBICACION_DESCONOCIDA"
    | "CANTIDAD_NO_VALIDA"
    | "COSTO_NO_VALIDO"
    | "TOTAL_NO_CUADRA"
    | "FECHA_SNAPSHOT_FALTANTE"
    | "FORMATO_NO_COMPATIBLE"
    | "ARCHIVO_NO_COMPATIBLE"
    | "PRECIO_NO_VALIDO"
    | "PRECIO_FALTANTE"
    | "COSTO_FALTANTE"
    | "MONEDA_SIN_MAPEAR"
    | "LISTA_PRECIO_SIN_MAPEAR"
    | "HOJA_PRODUCTOS_FALTANTE"
    | "HOJA_PRODUCTOS_CONFLICTIVA"
    | "IMPUESTO_FALTANTE"
    | "IMPUESTO_NO_COMPATIBLE";
  message: string;
  rowNumber?: number;
  alphaSku?: string;
  locationCode?: string;
  contextKey?: string;
};

export type ImportKind = "products" | "inventory" | "prices" | "costs" | "unsupported";

export type ParsedAlphaFile = {
  fileName: string;
  fileHash: string;
  importKind: ImportKind;
  source: "manual" | "local_development";
  snapshotDate: string | null;
  products: ProductRecord[];
  inventory: InventoryRecord[];
  prices: PriceRecord[];
  costs: CostRecord[];
  rejectedRows: RejectedImportRow[];
  locations: Array<{
    externalCode: string;
    name: string;
    locationType: LocationType | null;
    classificationSource: LocationClassificationSource | null;
  }>;
  issues: ImportIssue[];
};

export type CompanyMembership = {
  companyId: string;
  companyName: string;
  companyUpdatedAt: string;
  productExperience: import("@/app/lib/product-experience").ProductExperience;
  roles: RoleOption[];
  permissions: string[];
};

export type ProductRow = {
  id: string;
  internal_sku: string;
  alpha_sku: string | null;
  alpha_class: string | null;
  name: string;
  attribute: string | null;
  unit: string | null;
  product_group: string | null;
  subgroup: string | null;
  product_type: string | null;
  updated_at: string;
};

export type LocationRow = {
  id: string;
  external_code: string;
  name: string;
  location_type: string;
  is_active: boolean;
};

export type InventoryRow = {
  location_id: string;
  location_code: string;
  location_name: string;
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  quantity_on_hand: number;
  balance_updated_at: string;
  last_movement_type: string | null;
  last_movement_at: string | null;
  has_snapshot_reference?: boolean;
  snapshot_quantity: number | null;
  snapshot_date: string | null;
  snapshot_source_file: string | null;
  difference_from_snapshot: number | null;
};

export type InventoryProductRow = {
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  total_quantity_on_hand: number;
  location_count: number;
  positive_location_count: number;
  balance_updated_at: string | null;
  locations: InventoryRow[];
};

export type ImportBatchRow = {
  id: string;
  import_type: string;
  status: string;
  source: string;
  started_at: string;
  completed_at: string | null;
  records_received: number;
  records_imported: number;
  import_files: Array<{ original_name: string; file_type: string; row_count: number }>;
  import_errors: Array<{ severity: string; error_code: string; message: string; row_number: number | null }>;
};
