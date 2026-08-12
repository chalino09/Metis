import type { AppRoleCode } from "@/app/lib/types";

export type NavigationRequirement = {
  all?: string[];
  any?: string[];
};

export const COMMERCIAL_ASSORTMENTS_PATH = "/satrapy/configuracion/surtidos";
export const LEGACY_POS_PREPARATION_PATH = "/satrapy/ventas/preparacion-pos";
export const MANAGE_ASSORTMENTS_REQUIREMENT: NavigationRequirement = { all: ["manage_assortments"] };

export const ROLE_PREVIEW_PERMISSIONS: Record<AppRoleCode, string[]> = {
  super_admin: ["*"],
  direccion_admin: ["view_bi", "view_bi_budgets", "create_bi_budget_drafts", "import_bi_budgets", "approve_bi_budgets", "manage_bi_budget_distributions", "view_team_bi_budgets", "view_products", "view_inventory", "operate_inventory", "approve_inventory_adjustments", "manage_inventory_replenishment", "manage_products", "manage_locations", "manage_company_users", "import_data", "import_prices", "import_costs", "view_import_audit", "view_pos_readiness", "manage_assortments", "view_prices", "manage_prices", "view_costs", "view_accounting", "configure_accounting", "import_accounting_opening", "post_accounting_adjustments", "approve_accounting_adjustments", "reverse_accounting_adjustments", "configure_accounting_events", "approve_accounting_events", "reprocess_accounting_events", "close_accounting_periods", "reopen_accounting_periods", "view_suppliers", "manage_suppliers", "promote_suppliers", "view_procurement", "create_procurement_requisitions", "manage_procurement_quotes", "recommend_procurement_awards", "approve_procurement_awards", "view_purchase_orders", "create_purchase_orders", "edit_purchase_orders", "submit_purchase_orders", "approve_purchase_orders", "reject_purchase_orders", "cancel_purchase_orders", "promote_purchase_orders", "view_purchase_receipts", "manage_purchase_receipt_drafts", "confirm_purchase_receipts", "reverse_purchase_receipts", "view_supplier_invoices", "manage_supplier_invoice_drafts", "confirm_supplier_invoices", "authorize_supplier_invoice_differences", "reverse_supplier_invoices", "manage_supplier_credit_notes", "reverse_supplier_credit_notes", "view_accounts_payable", "prepare_supplier_payment_proposals", "approve_supplier_payment_proposals", "manage_supplier_paying_accounts", "view_supplier_payments", "confirm_supplier_payments", "reverse_supplier_payments", "manage_supplier_payment_documents", "verify_supplier_payment_rep_sat", "use_pos", "view_sales", "view_sales_quotes", "manage_sales_quotes", "view_sales_orders", "manage_sales_orders", "sell_cash", "sell_credit", "cancel_sales", "manage_customers", "view_customer_credit", "reverse_receivable_payments", "apply_discount", "approve_discount", "open_cash_session", "close_own_cash_session", "approve_cash_variance", "record_cash_movement", "reverse_cash_movements", "view_cash_reports", "record_receivable_payment", "manage_payment_methods", "manage_discount_policies", "view_sales_audit", "view_collaborators", "manage_collaborators", "manage_payroll_movements", "manage_payroll_runs", "approve_payroll_runs", "mark_payroll_paid"],
  supervisor_sucursal: ["view_bi_budgets", "view_inventory", "view_cash_reports"],
  sucursal: ["view_products", "view_inventory", "operate_inventory", "view_prices", "use_pos", "view_sales", "view_sales_quotes", "manage_sales_quotes", "view_sales_orders", "manage_sales_orders", "sell_cash", "manage_customers", "view_customer_credit", "apply_discount", "open_cash_session", "close_own_cash_session", "record_cash_movement", "view_cash_reports", "record_receivable_payment"],
  ingeniero_campo: ["view_bi_budgets", "view_products", "view_inventory", "operate_inventory", "view_prices"],
  almacen: ["view_products", "view_inventory", "operate_inventory", "manage_inventory_replenishment", "view_prices", "manage_locations", "view_purchase_receipts", "manage_purchase_receipt_drafts", "confirm_purchase_receipts"],
  punto_venta: ["view_products", "view_inventory", "view_prices", "use_pos", "view_sales", "view_sales_quotes", "manage_sales_quotes", "view_sales_orders", "manage_sales_orders", "sell_cash", "manage_customers", "view_customer_credit", "apply_discount", "open_cash_session", "close_own_cash_session", "record_cash_movement", "view_cash_reports", "record_receivable_payment"],
};

ROLE_PREVIEW_PERMISSIONS.direccion_admin.push(
  "view_banking",
  "import_bank_statements",
  "reconcile_banking",
  "unreconcile_banking",
  "manage_location_operating_profiles",
  "manage_location_responsibilities",
  "view_location_profitability",
  "view_collection_automation",
  "manage_collection_automation",
);

export function matchesNavigationRequirement(permissions: string[], requirement?: NavigationRequirement) {
  const hasPermission = (permission: string) => permissions.includes("*") || permissions.includes(permission);
  return (!requirement?.all || requirement.all.every(hasPermission))
    && (!requirement?.any || requirement.any.some(hasPermission));
}
