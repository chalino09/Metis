export type AlphaStandardImportKind = "products" | "inventory" | "prices" | "costs";
export type AlphaCustomerFileKind = "customers" | "credit_terms" | "ledger" | "collections";
export type AlphaPurchasingFileKind = "suppliers" | "purchase_orders" | "payable_documents" | "supplier_payments";
export type AlphaUploadKind = AlphaStandardImportKind | AlphaCustomerFileKind | AlphaPurchasingFileKind | "unrecognized";

const standardPatterns: Array<[AlphaStandardImportKind, RegExp]> = [
  ["products", /^cata_prd_.+\.xlsx?$/i],
  ["inventory", /^reexic2_.+\.xlsx?$/i],
  ["prices", /^rprecprd_.+\.xlsx?$/i],
  ["costs", /^rcostprd_.+\.xlsx?$/i],
];

const customerPatterns: Array<[AlphaCustomerFileKind, RegExp]> = [
  ["customers", /^cata_cte_.+\.xlsx?$/i],
  ["credit_terms", /^cat_ctee_.+\.xlsx?$/i],
  ["ledger", /^lis_sal_.+\.xlsx?$/i],
  ["collections", /^cob_cte_.+\.xlsx?$/i],
];

const purchasingPatterns: Array<[AlphaPurchasingFileKind, RegExp]> = [
  ["suppliers", /^cata_prv_.+\.xlsx?$/i],
  ["purchase_orders", /^rpcon2_.+\.xlsx?$/i],
  ["payable_documents", /^lfchvenc_.+\.xlsx?$/i],
  ["supplier_payments", /^pag_det_.+\.xlsx?$/i],
];

export function classifyAlphaUpload(fileName: string): AlphaUploadKind {
  return standardPatterns.find(([, pattern]) => pattern.test(fileName))?.[0]
    ?? customerPatterns.find(([, pattern]) => pattern.test(fileName))?.[0]
    ?? purchasingPatterns.find(([, pattern]) => pattern.test(fileName))?.[0]
    ?? "unrecognized";
}

export function isStandardAlphaUpload(kind: AlphaUploadKind): kind is AlphaStandardImportKind {
  return ["products", "inventory", "prices", "costs"].includes(kind);
}

export function isCustomerAlphaUpload(kind: AlphaUploadKind): kind is AlphaCustomerFileKind {
  return ["customers", "credit_terms", "ledger", "collections"].includes(kind);
}

export function isPurchasingAlphaUpload(kind: AlphaUploadKind): kind is AlphaPurchasingFileKind {
  return ["suppliers", "purchase_orders", "payable_documents", "supplier_payments"].includes(kind);
}

export function alphaUploadLabel(kind: AlphaUploadKind): string {
  if (kind === "products") return "Catálogo de productos";
  if (kind === "inventory") return "Inventario";
  if (kind === "prices") return "Precios";
  if (kind === "costs") return "Costos";
  if (kind === "customers") return "Catálogo de clientes";
  if (kind === "credit_terms") return "Condiciones comerciales";
  if (kind === "ledger") return "Documentos y saldos CxC";
  if (kind === "collections") return "Evidencia de cobranza";
  if (kind === "suppliers") return "Catálogo de proveedores";
  if (kind === "purchase_orders") return "Órdenes de compra";
  if (kind === "payable_documents") return "Documentos y saldos CxP";
  if (kind === "supplier_payments") return "Evidencia de pagos a proveedores";
  return "Archivo no reconocido";
}
