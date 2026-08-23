export type ProductExperience = "core" | "restaurant";

const RESTAURANT_VIEWS = new Set([
  "bi_summary",
  "restaurant_costs",
  "pos",
  "sales_history",
  "invoice_requests",
  "suppliers",
  "purchase_receipts",
  "cash",
  "products",
  "inventory",
  "inventory_counts",
  "inventory_replenishment",
  "collaborators_directory",
  "payroll",
  "settings_home",
  "migration",
  "locations",
  "users_access",
  "assortments",
  "sales_settings",
  "sales_audit",
]);

export function normalizeProductExperience(value: unknown): ProductExperience {
  return value === "restaurant" ? "restaurant" : "core";
}

export function isViewAvailableForExperience(view: string, experience: ProductExperience) {
  return experience === "core" || RESTAURANT_VIEWS.has(view);
}

export function productVocabulary(experience: ProductExperience) {
  return experience === "restaurant"
    ? { singular: "platillo", singularTitle: "Platillo", plural: "platillos", pluralTitle: "Platillos" }
    : { singular: "producto", singularTitle: "Producto", plural: "productos", pluralTitle: "Productos" };
}

export function experienceViewLabel(view: string, defaultLabel: string, experience: ProductExperience) {
  if (experience !== "restaurant") return defaultLabel;
  const labels: Record<string, string> = {
    bi_summary: "Indicadores",
    restaurant_costs: "Costos y márgenes",
    purchase_receipts: "Entradas de insumos",
    sales_history: "Tickets y ventas",
    products: "Platillos",
    inventory: "Existencias",
    inventory_counts: "Conteos y ajustes",
    inventory_replenishment: "Mínimos de inventario",
    collaborators_directory: "Directorio",
    payroll: "Nómina y recibos",
    users_access: "Roles y accesos",
    assortments: "Disponibilidad de platillos",
    sales_settings: "Caja, pagos y ticket",
    sales_audit: "Cancelaciones y descuentos",
  };
  return labels[view] ?? defaultLabel;
}

export function experienceSectionLabel(section: string, defaultLabel: string, experience: ProductExperience) {
  if (experience !== "restaurant") return defaultLabel;
  if (section === "bi") return "Indicadores";
  if (section === "collaborators") return "Colaboradores";
  return defaultLabel;
}

export function experienceRoleLabel(code: string, defaultLabel: string, experience: ProductExperience) {
  if (experience !== "restaurant") return defaultLabel;
  if (code === "punto_venta") return "Cajero";
  if (code === "sucursal") return "Encargado";
  if (code === "direccion_admin") return "Administrador";
  return defaultLabel;
}
