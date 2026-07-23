import assert from "node:assert/strict";
import test from "node:test";
import {
  COMMERCIAL_ASSORTMENTS_PATH,
  LEGACY_POS_PREPARATION_PATH,
  MANAGE_ASSORTMENTS_REQUIREMENT,
  matchesNavigationRequirement,
  ROLE_PREVIEW_PERMISSIONS,
} from "../app/lib/navigation-access.ts";

test("surtidos comerciales pertenece a Configuración y conserva redirección desde la ruta anterior", () => {
  assert.equal(COMMERCIAL_ASSORTMENTS_PATH, "/satrapy/configuracion/surtidos");
  assert.equal(LEGACY_POS_PREPARATION_PATH, "/satrapy/ventas/preparacion-pos");
});

test("solo roles con manage_assortments pueden administrar surtidos", () => {
  assert.equal(matchesNavigationRequirement(ROLE_PREVIEW_PERMISSIONS.super_admin, MANAGE_ASSORTMENTS_REQUIREMENT), true);
  assert.equal(matchesNavigationRequirement(ROLE_PREVIEW_PERMISSIONS.direccion_admin, MANAGE_ASSORTMENTS_REQUIREMENT), true);
  assert.equal(matchesNavigationRequirement(ROLE_PREVIEW_PERMISSIONS.sucursal, MANAGE_ASSORTMENTS_REQUIREMENT), false);
  assert.equal(matchesNavigationRequirement(ROLE_PREVIEW_PERMISSIONS.almacen, MANAGE_ASSORTMENTS_REQUIREMENT), false);
  assert.equal(matchesNavigationRequirement(ROLE_PREVIEW_PERMISSIONS.punto_venta, MANAGE_ASSORTMENTS_REQUIREMENT), false);
});

test("view_pos_readiness por sí solo no autoriza cambios comerciales", () => {
  assert.equal(matchesNavigationRequirement(["view_pos_readiness"], MANAGE_ASSORTMENTS_REQUIREMENT), false);
  assert.equal(matchesNavigationRequirement(["manage_assortments"], MANAGE_ASSORTMENTS_REQUIREMENT), true);
});

test("los roles operativos conservan consulta explícita de inventario", () => {
  for (const role of ["direccion_admin", "sucursal", "ingeniero_campo", "almacen", "punto_venta"] as const) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS[role].includes("view_inventory"), true, role);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.supervisor_sucursal.includes("view_inventory"), true);
});

test("conteos separa captura y aprobación de diferencias", () => {
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("operate_inventory"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("approve_inventory_adjustments"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.supervisor_sucursal.includes("operate_inventory"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.supervisor_sucursal.includes("approve_inventory_adjustments"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("approve_inventory_adjustments"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("manage_company_users"), true);
});

test("transferencias requiere operación de inventario", () => {
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("operate_inventory"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("operate_inventory"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.supervisor_sucursal.includes("operate_inventory"), false);
});

test("proveedores separa consulta, mantenimiento y promoción", () => {
  for (const permission of ["view_suppliers", "manage_suppliers", "promote_suppliers"]) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission), true, permission);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("view_suppliers"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("promote_suppliers"), false);
});

test("órdenes de compra separa cada capacidad del workflow", () => {
  for (const permission of ["view_purchase_orders", "create_purchase_orders", "edit_purchase_orders", "submit_purchase_orders", "approve_purchase_orders", "reject_purchase_orders", "cancel_purchase_orders", "promote_purchase_orders"]) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission), true, permission);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("view_purchase_orders"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("approve_purchase_orders"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.punto_venta.includes("cancel_purchase_orders"), false);
});

test("recepciones separa captura, confirmación, reversa y consulta de costos", () => {
  for (const permission of ["view_purchase_receipts", "manage_purchase_receipt_drafts", "confirm_purchase_receipts", "reverse_purchase_receipts"]) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission), true, permission);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("view_purchase_receipts"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("confirm_purchase_receipts"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("reverse_purchase_receipts"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("view_costs"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.punto_venta.includes("view_purchase_receipts"), false);
});

test("facturas de proveedor separa borradores, confirmación, diferencias, reversa, crédito y CxP", () => {
  for (const permission of ["view_supplier_invoices", "manage_supplier_invoice_drafts", "confirm_supplier_invoices", "authorize_supplier_invoice_differences", "reverse_supplier_invoices", "manage_supplier_credit_notes", "view_accounts_payable"]) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission), true, permission);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("view_supplier_invoices"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("confirm_supplier_invoices"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.punto_venta.includes("view_accounts_payable"), false);
});

test("propuestas de pago separa preparación y aprobación", () => {
  assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("prepare_supplier_payment_proposals"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("approve_supplier_payment_proposals"), true);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("prepare_supplier_payment_proposals"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("approve_supplier_payment_proposals"), false);
});

test("pagos a proveedores separa cuentas, consulta, confirmación y reversa", () => {
  for (const permission of ["manage_supplier_paying_accounts", "view_supplier_payments", "confirm_supplier_payments", "reverse_supplier_payments", "manage_supplier_payment_documents", "verify_supplier_payment_rep_sat"]) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission), true, permission);
  }
  assert.equal(ROLE_PREVIEW_PERMISSIONS.almacen.includes("confirm_supplier_payments"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.sucursal.includes("reverse_supplier_payments"), false);
  assert.equal(ROLE_PREVIEW_PERMISSIONS.punto_venta.includes("manage_supplier_payment_documents"), false);
});

test("Bancos separa consulta, carga, conciliación y desconciliación", () => {
  for (const permission of ["view_banking", "import_bank_statements", "reconcile_banking", "unreconcile_banking"]) assert.ok(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes(permission));
});
