"use client";

import {
  AlertCircle,
  ArrowRightLeft,
  ArrowRight,
  BarChart3,
  BookOpen,
  Building2,
  Boxes,
  Check,
  ClipboardCheck,
  FileSpreadsheet,
  History,
  Landmark,
  LayoutGrid,
  LoaderCircle,
  LogOut,
  MapPinned,
  PackageSearch,
  RefreshCw,
  ReceiptText,
  ShoppingCart,
  TrendingUp,
  Truck,
  Upload,
  UserRoundCheck,
  Users,
  WalletCards,
} from "lucide-react";
import { Fragment, useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { usePathname, useRouter } from "next/navigation";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Input, Modal, Select, ToastProvider, useToast } from "@/app/components/ui/primitives";
import { useDismissiblePopover } from "@/app/components/ui/use-dismissible-popover";
import { getSupabaseClient } from "@/app/lib/supabase";
import { classifyAlphaUpload, isPurchasingAlphaUpload } from "@/app/lib/alpha-upload-routing";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { presentImportedSourceText } from "@/app/lib/presentation-text";
import { purchasingUploadPackageState } from "@/app/lib/purchasing-upload-package";
import { COMMERCIAL_ASSORTMENTS_PATH, LEGACY_POS_PREPARATION_PATH, MANAGE_ASSORTMENTS_REQUIREMENT, matchesNavigationRequirement, ROLE_PREVIEW_PERMISSIONS, type NavigationRequirement } from "@/app/lib/navigation-access";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { CashDeskView, CustomerMasterView, CustomersView, NewCustomerMasterView, PosSalesView, ReceivablesView, SalesAuditView, SalesHistoryView, SalesSettingsView } from "@/app/components/SalesModule";
import { CommercialAssortmentsView } from "@/app/components/CommercialAssortmentsView";
import { SalesQuotesView } from "@/app/components/SalesQuotesModule";
import { SalesOrdersView } from "@/app/components/SalesOrdersModule";
import { SuppliersView } from "@/app/components/SuppliersModule";
import { PurchaseOrderPromotionAudit, PurchaseOrdersView } from "@/app/components/PurchaseOrdersModule";
import { ProcurementView } from "@/app/components/ProcurementModule";
import { PurchaseReceiptsView } from "@/app/components/PurchaseReceiptsModule";
import { SupplierInvoicesView, SupplierPayingAccountsView } from "@/app/components/SupplierInvoicesModule";
import { AccountingModule } from "@/app/components/AccountingModule";
import { BankingModule } from "@/app/components/BankingModule";
import { CompanyLocationsView } from "@/app/components/CompanyLocationsView";
import { CompanyUsersView } from "@/app/components/CompanyUsersView";
import { ConfigurationHome } from "@/app/components/ConfigurationHome";
import { InitialMigrationView } from "@/app/components/InitialMigrationView";
import { ProductCatalogView } from "@/app/components/ProductCatalogView";
import type {
  AppRoleCode,
  ImportBatchRow,
  InventoryProductRow,
  InventoryRow,
  LocationType,
  RoleOption,
} from "@/app/lib/types";

type ViewName = "settings_home" | "initial_migration" | "migration" | "users_access" | "suppliers" | "procurement" | "purchase_orders" | "purchase_receipts" | "supplier_invoices" | "supplier_paying_accounts" | "products" | "inventory" | "inventory_counts" | "inventory_transfers" | "inventory_replenishment" | "locations" | "audit" | "sales_audit" | "assortments" | "pos" | "sales_history" | "sales_quotes" | "sales_orders" | "customers" | "receivables" | "cash" | "sales_settings" | "accounting_summary" | "accounting_accounts" | "accounting_periods" | "accounting_reports" | "accounting_journals" | "accounting_events" | "accounting_banking" | "accounting_opening" | "accounting_settings";
type AreaName = "sales" | "purchasing" | "inventory" | "accounting" | "settings";

const ALL_ROLES: RoleOption[] = [
  { code: "super_admin", display_name: "Super Admin" },
  { code: "direccion_admin", display_name: "Dirección / Admin General" },
  { code: "sucursal", display_name: "Operador de Sucursal" },
  { code: "ingeniero_campo", display_name: "Ingeniero de Campo" },
  { code: "almacen", display_name: "Almacén" },
];

const VIEW_META: Record<ViewName, {
  label: string;
  icon: typeof Boxes;
  href: string;
  area: AreaName;
  requirement?: NavigationRequirement;
}> = {
  settings_home: {
    label: "Configuración general",
    icon: LayoutGrid,
    href: "/satrapy/configuracion",
    area: "settings",
    requirement: { any: ["manage_locations","manage_company_users","import_data","import_prices","import_costs","import_accounting_opening","view_import_audit","manage_assortments","manage_supplier_paying_accounts","manage_payment_methods","manage_discount_policies","manage_prices","manage_ticket_branding","view_sales_audit","view_accounting","configure_accounting","view_banking"] },
  },
  initial_migration: {
    label: "Migración inicial",
    icon: Building2,
    href: "/satrapy/configuracion/migracion-inicial",
    area: "settings",
    requirement: { any: ["import_data","import_prices","import_costs","import_accounting_opening"] },
  },
  users_access: {
    label: "Usuarios y accesos",
    icon: Users,
    href: "/satrapy/configuracion/usuarios",
    area: "settings",
    requirement: { all: ["manage_company_users"] },
  },
  migration: {
    label: "Centro de Migración",
    icon: FileSpreadsheet,
    href: "/satrapy/configuracion/importaciones",
    area: "settings",
    requirement: { any: ["import_data", "import_prices", "import_costs", "import_accounting_opening"] },
  },
  suppliers: {
    label: "Proveedores",
    icon: Truck,
    href: "/satrapy/compras/proveedores",
    area: "purchasing",
    requirement: { all: ["view_suppliers"] },
  },
  procurement: {
    label: "Abastecimiento",
    icon: ShoppingCart,
    href: "/satrapy/compras/abastecimiento",
    area: "purchasing",
    requirement: { all: ["view_procurement"] },
  },
  purchase_orders: {
    label: "Órdenes de compra",
    icon: ClipboardCheck,
    href: "/satrapy/compras/ordenes",
    area: "purchasing",
    requirement: { all: ["view_purchase_orders"] },
  },
  purchase_receipts: {
    label: "Recepciones",
    icon: Truck,
    href: "/satrapy/compras/recepciones",
    area: "purchasing",
    requirement: { all: ["view_purchase_receipts"] },
  },
  supplier_invoices: {
    label: "Facturas y CxP",
    icon: ReceiptText,
    href: "/satrapy/compras/facturas",
    area: "purchasing",
    requirement: { any: ["view_supplier_invoices", "view_accounts_payable"] },
  },
  supplier_paying_accounts: {
    label: "Cuentas bancarias",
    icon: WalletCards,
    href: "/satrapy/configuracion/cuentas-bancarias",
    area: "settings",
    requirement: { all: ["manage_supplier_paying_accounts"] },
  },
  products: {
    label: "Productos",
    icon: PackageSearch,
    href: "/satrapy/inventario/productos",
    area: "inventory",
    requirement: { all: ["view_products"] },
  },
  inventory: {
    label: "Inventario por ubicación",
    icon: Boxes,
    href: "/satrapy/inventario/existencias",
    area: "inventory",
    requirement: { all: ["view_inventory"] },
  },
  inventory_counts: {
    label: "Conteos físicos",
    icon: ClipboardCheck,
    href: "/satrapy/inventario/conteos",
    area: "inventory",
    requirement: { any: ["operate_inventory", "approve_inventory_adjustments"] },
  },
  inventory_transfers: {
    label: "Transferencias",
    icon: ArrowRightLeft,
    href: "/satrapy/inventario/transferencias",
    area: "inventory",
    requirement: { all: ["operate_inventory"] },
  },
  inventory_replenishment: {
    label: "Reabastecimiento",
    icon: TrendingUp,
    href: "/satrapy/inventario/reabastecimiento",
    area: "inventory",
    requirement: { any: ["view_inventory", "manage_inventory_replenishment"] },
  },
  locations: {
    label: "Sucursales",
    icon: MapPinned,
    href: "/satrapy/configuracion/empresa/sucursales",
    area: "settings",
    requirement: { all: ["manage_locations"] },
  },
  audit: {
    label: "Auditoría de importaciones",
    icon: History,
    href: "/satrapy/configuracion/auditoria-importaciones",
    area: "settings",
    requirement: { all: ["view_import_audit"] },
  },
  sales_audit: {
    label: "Auditoría comercial",
    icon: History,
    href: "/satrapy/configuracion/auditoria-comercial",
    area: "settings",
    requirement: { all: ["view_sales_audit"] },
  },
  assortments: {
    label: "Surtidos comerciales",
    icon: ClipboardCheck,
    href: COMMERCIAL_ASSORTMENTS_PATH,
    area: "settings",
    requirement: MANAGE_ASSORTMENTS_REQUIREMENT,
  },
  pos: {
    label: "Punto de venta",
    icon: ShoppingCart,
    href: "/satrapy/ventas/pos",
    area: "sales",
    requirement: { all: ["use_pos"] },
  },
  sales_history: {
    label: "Ventas",
    icon: ReceiptText,
    href: "/satrapy/ventas/historial",
    area: "sales",
    requirement: { all: ["view_sales"] },
  },
  sales_quotes: {
    label: "Cotizaciones",
    icon: ClipboardCheck,
    href: "/satrapy/ventas/cotizaciones",
    area: "sales",
    requirement: { all: ["view_sales_quotes"] },
  },
  sales_orders: {
    label: "Órdenes de venta",
    icon: PackageSearch,
    href: "/satrapy/ventas/pedidos",
    area: "sales",
    requirement: { all: ["view_sales_orders"] },
  },
  customers: {
    label: "Clientes",
    icon: Users,
    href: "/satrapy/ventas/clientes",
    area: "sales",
    requirement: { any: ["use_pos", "manage_customers"] },
  },
  receivables: {
    label: "Cuentas por cobrar",
    icon: ReceiptText,
    href: "/satrapy/ventas/cuentas-por-cobrar",
    area: "sales",
    requirement: { all: ["view_customer_credit", "record_receivable_payment"] },
  },
  cash: {
    label: "Caja",
    icon: WalletCards,
    href: "/satrapy/ventas/caja",
    area: "sales",
    requirement: { any: ["open_cash_session", "view_cash_reports"] },
  },
  sales_settings: {
    label: "Configuración comercial",
    icon: WalletCards,
    href: "/satrapy/configuracion/ventas",
    area: "settings",
    requirement: { any: ["manage_payment_methods", "manage_discount_policies", "manage_locations", "manage_prices"] },
  },
  accounting_summary: { label: "Resumen", icon: FileSpreadsheet, href: "/satrapy/contabilidad", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_accounts: { label: "Catálogo de cuentas", icon: BookOpen, href: "/satrapy/contabilidad/catalogo", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_periods: { label: "Periodos", icon: ClipboardCheck, href: "/satrapy/contabilidad/periodos", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_reports: { label: "Estados financieros", icon: BarChart3, href: "/satrapy/contabilidad/estados-financieros", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_journals: { label: "Pólizas", icon: ReceiptText, href: "/satrapy/contabilidad/polizas", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_events: { label: "Eventos", icon: ReceiptText, href: "/satrapy/contabilidad/eventos", area: "accounting", requirement: { all: ["view_accounting"] } },
  accounting_banking: { label: "Bancos", icon: Landmark, href: "/satrapy/contabilidad/bancos", area: "accounting", requirement: { all: ["view_banking"] } },
  accounting_opening: { label: "Apertura", icon: History, href: "/satrapy/contabilidad/apertura", area: "accounting", requirement: { any: ["view_accounting", "import_accounting_opening"] } },
  accounting_settings: { label: "Configuración contable", icon: WalletCards, href: "/satrapy/configuracion/contabilidad", area: "settings", requirement: { any: ["view_accounting", "configure_accounting"] } },
};

function customerMasterId(pathname: string) {
  const match = pathname.match(/^\/satrapy\/ventas\/clientes\/([0-9a-f-]+)$/i);
  return match?.[1] ?? null;
}

function isNewCustomerPath(pathname: string) {
  return pathname === "/satrapy/ventas/clientes/nuevo";
}

function viewForPath(pathname: string): ViewName | undefined {
  if (pathname === LEGACY_POS_PREPARATION_PATH) return "assortments";
  if (pathname === "/satrapy/inventario/ubicaciones") return "locations";
  if (pathname === "/satrapy/contabilidad/configuracion") return "accounting_settings";
  return (Object.keys(VIEW_META) as ViewName[]).find((name) => VIEW_META[name].href === pathname);
}

const NAVIGATION_SECTIONS: Array<{ id: AreaName; label: string; views: ViewName[] }> = [
  { id: "sales", label: "Ventas", views: ["pos", "sales_history", "sales_quotes", "sales_orders", "customers", "receivables", "cash"] },
  { id: "purchasing", label: "Compras", views: ["suppliers", "procurement", "purchase_orders", "purchase_receipts", "supplier_invoices"] },
  { id: "inventory", label: "Inventario", views: ["products", "inventory", "inventory_counts", "inventory_transfers", "inventory_replenishment"] },
  { id: "accounting", label: "Contabilidad", views: ["accounting_summary", "accounting_accounts", "accounting_reports", "accounting_periods", "accounting_journals", "accounting_events", "accounting_banking", "accounting_opening"] },
  { id: "settings", label: "Configuración", views: ["settings_home", "locations", "users_access", "initial_migration", "migration", "audit", "assortments", "supplier_paying_accounts", "sales_settings", "sales_audit", "accounting_settings"] },
];

const SETTINGS_PRIMARY_VIEWS: ViewName[] = ["settings_home", "locations", "users_access", "initial_migration"];

const DATA_PAGE_SIZE = 50;

function getAllowedNavigation(permissions: string[], previewRole: AppRoleCode | null) {
  const effectivePermissions = previewRole ? ROLE_PREVIEW_PERMISSIONS[previewRole] : permissions;
  const isAllowed = (name: ViewName) => matchesNavigationRequirement(effectivePermissions, VIEW_META[name].requirement);
  const navigation = NAVIGATION_SECTIONS.map((section) => ({ ...section, views: section.views.filter(isAllowed) }))
    .filter((section) => section.views.length > 0);
  return { navigation, views: navigation.flatMap((section) => section.views) };
}

export function SatrapyShell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const { appState, companies, configured, isSuperAdmin, loading, notice, previewRole, setPreviewRole, selectCompany, refreshAccess } = useSatrapy();

  if (loading) return <LoadingScreen />;
  if (!configured) return <AccessUnavailableScreen />;
  if (!appState) return <LoginScreen notice={notice} onRetry={() => void refreshAccess()} />;

  const { navigation: allowedNavigation, views: allowedViews } = getAllowedNavigation(appState.membership.permissions, previewRole);
  const requestedView = customerMasterId(pathname) ? "customers" : viewForPath(pathname);
  const activeView = requestedView && allowedViews.includes(requestedView) ? requestedView : allowedViews[0] ?? "inventory";
  const activeArea = VIEW_META[activeView].area;
  const activeRole = appState.membership.roles.find((role) => role.code !== "super_admin") ?? appState.membership.roles[0];
  const activeSection = allowedNavigation.find((section) => section.id === activeArea) ?? allowedNavigation[0];
  const contextViews = activeSection?.id === "settings"
    ? activeSection.views.filter((name) => SETTINGS_PRIMARY_VIEWS.includes(name) || name === activeView)
    : activeSection?.views;
  return (
    <ToastProvider>
    <main className={`app-shell ${pathname === "/satrapy/ventas/pos" ? "app-shell--pos" : ""}`}>
      <header className="global-header">
        <div className="brand-lockup">
          <span className="brand-mark">S</span>
          <div>
            <strong>Satrapy</strong>
            <span>Operación, en orden</span>
          </div>
        </div>

        <nav className="global-nav" aria-label="Áreas principales">
          {allowedNavigation.map((section) => (
            <button
              className={`global-nav__item ${activeArea === section.id ? "is-active" : ""}`}
              aria-current={activeArea === section.id ? "page" : undefined}
              onClick={() => router.push(VIEW_META[section.views[0]].href)}
              key={section.id}
            >{section.label}</button>
          ))}
        </nav>

        <div className="global-header__controls">
          {isSuperAdmin || companies.length > 1 ? <div className="global-session-switchers"><div className="global-company-selector"><Select ariaLabel="Cambiar empresa" value={appState.membership.companyId} onValueChange={(companyId) => void selectCompany(companyId)} options={companies.map((company) => ({ value: company.id, label: company.display_name }))} /></div>{isSuperAdmin && <RolePreview selectedRole={previewRole} onChange={(role) => setPreviewRole(role)} compact />}</div> : <div className="global-company-context" title={appState.membership.companyName}><Building2 size={14} /><span>{appState.membership.companyName}</span></div>}
          {activeRole && <Badge className="global-role-badge" tone={activeRole.code === "super_admin" ? "primary" : "neutral"}>{activeRole.display_name}</Badge>}
          <div className="user-avatar">{appState.email.slice(0, 1).toUpperCase()}</div>
          <button className="icon-button" aria-label="Cerrar sesión" onClick={() => void getSupabaseClient().auth.signOut()}><LogOut size={16} /></button>
        </div>
      </header>

      <section className="main-panel">
        <nav className={`context-nav ${activeSection?.id === "accounting" ? "context-nav--accounting" : ""}`} aria-label={`Secciones de ${activeSection?.label ?? "Satrapy"}`}>
          <div className="topbar__context">
            <strong>{appState.membership.companyName}</strong>
            <span>{activeSection?.label ?? "Operación"}</span>
          </div>
          <div className="context-nav__links">
            {contextViews?.map((name) => {
              const item = VIEW_META[name];
              const Icon = item.icon;
              return <button className={`context-nav__item ${activeView === name ? "is-active" : ""}`} aria-current={activeView === name ? "page" : undefined} onClick={() => router.push(item.href)} key={name}><Icon size={16} />{item.label}</button>;
            })}
          </div>
          <span className="topbar__status">Operación en orden</span>
        </nav>
        {previewRole && (
          <div className="role-preview-banner">
            <UserRoundCheck size={17} />
            <span>Vista de interfaz como <strong>{roleLabel(previewRole)}</strong>.</span>
            <button onClick={() => setPreviewRole(null)}>Salir de vista</button>
          </div>
        )}
        {children}
      </section>
    </main>
    </ToastProvider>
  );
}

export function SatrapyRouteContent() {
  const pathname = usePathname();
  const router = useRouter();
  const { appState, loading, previewRole } = useSatrapy();
  const selectedCustomerId = customerMasterId(pathname);
  const creatingCustomer = isNewCustomerPath(pathname);
  const requestedView = selectedCustomerId || creatingCustomer ? "customers" : viewForPath(pathname);
  const { views: allowedViews } = getAllowedNavigation(appState?.membership.permissions ?? [], previewRole);
  const activeView = requestedView && allowedViews.includes(requestedView) ? requestedView : allowedViews[0] ?? "inventory";
  const isForbidden = Boolean(requestedView && !allowedViews.includes(requestedView));

  useEffect(() => {
    if (!loading && appState && pathname === LEGACY_POS_PREPARATION_PATH) {
      router.replace(VIEW_META.assortments.href);
      return;
    }
    if (!loading && appState && pathname === "/satrapy/inventario/ubicaciones") {
      router.replace(VIEW_META.locations.href);
      return;
    }
    if (!loading && appState && pathname === "/satrapy/contabilidad/configuracion") {
      router.replace(VIEW_META.accounting_settings.href);
      return;
    }
    if (loading || !appState || requestedView || !allowedViews.length) return;
    router.replace(VIEW_META[allowedViews[0]].href);
  }, [allowedViews, appState, loading, pathname, requestedView, router]);

  if (loading || !appState) return null;
  if (isForbidden) return <AccessDeniedScreen onGoHome={() => router.replace(VIEW_META[allowedViews[0]].href)} />;
  if (!requestedView) return <div className="route-loading" aria-live="polite"><LoaderCircle className="spin" size={18} /> Abriendo tu espacio de trabajo…</div>;
  if (activeView === "migration") return <MigrationCenter companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "suppliers") return <SuppliersView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "procurement") return <ProcurementView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "purchase_orders") return <PurchaseOrdersView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "purchase_receipts") return <PurchaseReceiptsView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "supplier_invoices") return <SupplierInvoicesView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "supplier_paying_accounts") return <SupplierPayingAccountsView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "products") return <ProductCatalogView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "inventory") return <InventoryView companyId={appState.membership.companyId} />;
  if (activeView === "inventory_counts") return <InventoryCountsView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "inventory_transfers") return <InventoryTransfersView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "inventory_replenishment") return <InventoryReplenishmentView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "settings_home") return <ConfigurationHome permissions={appState.membership.permissions} />;
  if (activeView === "initial_migration") return <InitialMigrationView companyId={appState.membership.companyId} />;
  if (activeView === "locations") return <CompanyLocationsView companyId={appState.membership.companyId} />;
  if (activeView === "users_access") return <CompanyUsersView companyId={appState.membership.companyId} />;
  if (activeView === "audit") return <ImportAuditWorkspace companyId={appState.membership.companyId} canPromotePurchaseOrders={appState.membership.permissions.includes("promote_purchase_orders")} />;
  if (activeView === "sales_audit") return <SalesAuditView companyId={appState.membership.companyId} />;
  if (activeView === "pos") return <PosSalesView key={appState.membership.companyId} companyId={appState.membership.companyId} companyName={appState.membership.companyName} cashierName={appState.email} permissions={appState.membership.permissions} />;
  if (activeView === "sales_history") return <SalesHistoryView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "sales_quotes") return <SalesQuotesView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "sales_orders") return <SalesOrdersView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "customers" && creatingCustomer) return <NewCustomerMasterView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "customers" && selectedCustomerId) return <CustomerMasterView companyId={appState.membership.companyId} customerId={selectedCustomerId} permissions={appState.membership.permissions} />;
  if (activeView === "customers") return <CustomersView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "receivables") return <ReceivablesView companyId={appState.membership.companyId} />;
  if (activeView === "cash") return <CashDeskView companyId={appState.membership.companyId} />;
  if (activeView === "sales_settings") return <SalesSettingsView companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "accounting_summary") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="summary" />;
  if (activeView === "accounting_accounts") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="accounts" />;
  if (activeView === "accounting_periods") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="periods" />;
  if (activeView === "accounting_reports") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="reports" />;
  if (activeView === "accounting_journals") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="journals" />;
  if (activeView === "accounting_events") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="events" />;
  if (activeView === "accounting_banking") return <BankingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} />;
  if (activeView === "accounting_opening") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="opening" />;
  if (activeView === "accounting_settings") return <AccountingModule companyId={appState.membership.companyId} permissions={appState.membership.permissions} view="settings" />;
  return <CommercialAssortmentsView key={appState.membership.companyId} companyId={appState.membership.companyId} />;
}

function LoginScreen({ notice, onRetry }: { notice: string | null; onRetry: () => void }) {
  const [mode, setMode] = useState<"login" | "register">("login");
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [passwordConfirmation, setPasswordConfirmation] = useState("");
  const [error, setError] = useState<string | null>(notice);
  const [sending, setSending] = useState(false);

  function changeMode(nextMode: "login" | "register") {
    setMode(nextMode);
    setPassword("");
    setPasswordConfirmation("");
    setError(null);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setSending(true);
    setError(null);
    if (mode === "register") {
      if (password !== passwordConfirmation) {
        setError("Las contraseñas no coinciden.");
        setSending(false);
        return;
      }
      const response = await fetch("/api/auth/register", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ fullName, email, password }) });
      const result = await response.json();
      if (!response.ok) {
        setError(result.message ?? "No pudimos crear la cuenta.");
        setSending(false);
        return;
      }
    }
    const { error: signInError } = await getSupabaseClient().auth.signInWithPassword({ email, password });
    if (signInError) {
      const needsEmailConfirmation = signInError.code === "email_not_confirmed" || signInError.message.toLowerCase().includes("email not confirmed");
      setError(needsEmailConfirmation
        ? "Confirma tu correo electrónico antes de iniciar sesión."
        : "No pudimos iniciar sesión. Verifica tus credenciales o contacta a tu administrador.");
    }
    setSending(false);
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <div className="brand-lockup"><span className="brand-mark">S</span><strong>Satrapy</strong></div>
        <div className="auth-heading">
          <h1>{mode === "login" ? "Iniciar sesión" : "Crear cuenta"}</h1>
          <p>{mode === "login" ? "Entra con tus credenciales de Satrapy." : "Completa tus datos para comenzar."}</p>
        </div>
        <div className="auth-mode-switch" aria-label="Acceso a Satrapy">
          <button type="button" className={mode === "login" ? "is-active" : ""} onClick={() => changeMode("login")}>Iniciar sesión</button>
          <button type="button" className={mode === "register" ? "is-active" : ""} onClick={() => changeMode("register")}>Crear cuenta</button>
        </div>
        <form onSubmit={submit} className="auth-form">
          {mode === "register" && <label>Nombre completo<input required value={fullName} onChange={(event) => setFullName(event.target.value)} autoComplete="name" /></label>}
          <label>Correo<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" /></label>
          <label>Contraseña<input type="password" required minLength={mode === "register" ? 8 : undefined} value={password} onChange={(event) => setPassword(event.target.value)} autoComplete={mode === "login" ? "current-password" : "new-password"} /></label>
          {mode === "register" && <label>Confirmar contraseña<input type="password" required minLength={8} value={passwordConfirmation} onChange={(event) => setPasswordConfirmation(event.target.value)} autoComplete="new-password" /></label>}
          {error && <p className="form-error"><AlertCircle size={16} />{error}</p>}
          {notice && mode === "login" && <Button className="auth-retry" type="button" variant="ghost" size="sm" onClick={onRetry}><RefreshCw size={14} /> Reintentar acceso</Button>}
          <button className="primary-button" disabled={sending}>{sending ? <LoaderCircle className="spin" size={17} /> : null} {mode === "login" ? "Entrar" : "Crear mi cuenta"} <ArrowRight size={17} /></button>
        </form>
      </section>
    </main>
  );
}

function AccessUnavailableScreen() {
  return (
    <main className="auth-page">
      <section className="auth-card config-card">
        <div className="brand-lockup"><span className="brand-mark">S</span><strong>Satrapy</strong></div>
        <div className="auth-heading">
          <span className="eyebrow">Acceso</span>
          <h1>Acceso no disponible.</h1>
        </div>
      </section>
    </main>
  );
}

function LoadingScreen() {
  return <main className="auth-page"><div className="loading-copy" role="status" aria-live="polite"><LoaderCircle className="spin" size={22} aria-hidden="true" /><span>Validando acceso…</span></div></main>;
}

function RolePreview({ selectedRole, onChange, compact = false }: { selectedRole: AppRoleCode | null; onChange: (role: AppRoleCode | null) => void; compact?: boolean }) {
  return (
    <div className={compact ? "role-preview role-preview--compact" : "role-preview"}>
      {!compact && <span className="eyebrow">Super Admin</span>}
      <label>{compact ? "Vista de rol" : "Ver como rol"}
        <Select
          ariaLabel="Ver como rol"
          value={selectedRole ?? "default"}
          onValueChange={(value) => onChange(value === "default" ? null : value as AppRoleCode)}
          options={[{ value: "default", label: compact ? "Vista" : "Vista predeterminada" }, ...ALL_ROLES.filter((role) => role.code !== "super_admin").map((role) => ({ value: role.code, label: role.display_name }))]}
          style={compact ? { width: 62, minWidth: 62, minHeight: 30, border: 0, borderRadius: 7, background: "transparent", boxShadow: "none", padding: "5px 7px", color: "#68756f", fontSize: 10, fontWeight: 650 } : undefined}
        />
      </label>
    </div>
  );
}

function AccessDeniedScreen({ onGoHome }: { onGoHome: () => void }) {
  return <div className="content-frame"><section className="access-denied"><span className="eyebrow">Acceso</span><h1>No tienes acceso a esta sección.</h1><p>Tu empresa y permisos siguen protegidos en el servidor. Elige una sección disponible para continuar.</p><Button variant="secondary" onClick={onGoHome}>Ir a mi inicio</Button></section></div>;
}

type StagedBatch = {
  id: string;
  import_type: "products" | "inventory" | "prices" | "costs" | "unsupported";
  status: "staged" | "validation_failed" | "failed" | "completed" | "processing" | "discarded" | "expired";
  source: string;
  file_sha256: string;
  snapshot_date: string | null;
  records_received: number;
  valid_rows: number;
  warning_rows: number;
  error_rows: number;
  blocking_error_count: number;
  pending_warning_count: number;
  staging_purged_at: string | null;
  import_files: Array<{ original_name: string; file_type: string }>;
};

type StagedRow = {
  id: string;
  row_number: number;
  source_file: string;
  detected_type: "products" | "inventory" | "prices" | "costs";
  raw_data: { cells?: unknown[] };
  normalized_data: Record<string, unknown>;
  validation_status: "valid" | "warning" | "error";
  resolved_product_id: string | null;
  resolved_at: string | null;
  resolution_reason: string | null;
  issues: StagedIssue[];
};

type StagedIssue = {
  id: string;
  severity: "error" | "warning";
  error_code: string;
  message: string;
  resolved_at: string | null;
  acknowledged_at: string | null;
};

type StagingErrorGroup = { error_code: string; severity: "error" | "warning"; total: number; pending: number };
type PendingLocation = { external_code: string; name: string; row_count: number };
type StagingPreviewData = {
  batch: StagedBatch;
  file: { original_name: string; file_type: string; file_sha256: string; row_count: number } | null;
  rows: StagedRow[];
  error_groups: StagingErrorGroup[];
  pending_locations: PendingLocation[];
  pagination: { page: number; page_size: number; total: number };
  commercial_requirements?: {
    currencies: Array<{ source_label: string; currency_code: string | null; rows: number }>;
    price_lists: Array<{ external_code: string; semantic_code: string | null; is_default: boolean; rows: number }>;
  };
  tax_summary?: Array<{ tax_category_code: string; total: number }>;
};
type OperationDialog =
  | { kind: "product"; row: StagedRow }
  | { kind: "warning"; code: string }
  | { kind: "discard" }
  | { kind: "retry" };
type CustomerMigrationBatch = { id: string; cutoff_date: string; status: string; records_received: number; records_promoted: number; differences: number; summary: { reconciled_customers?: number; customers_with_differences?: number; failure_reason?: string; remaining_customers?: number; receivable_repair?: { status?: string; corrected_total?: number }; receivable_backfill?: { status?: string; total_after?: number }; customer_identity_repair?: { status?: string; ambiguous_customers?: number }; customer_conflict_review?: { status?: string } } };
type PurchasingMigrationBatch = { id: string; cutoff_date: string; status: "loading" | "staged" | "validation_failed" | "failed"; records_received: number; differences: number; summary: { suppliers?: number; purchase_orders?: number; purchase_order_lines?: number; payable_documents?: number; payable_outstanding_total?: number; supplier_payments?: number; supplier_payment_total?: number; receipt_source_available?: boolean; error_count?: number; warning_count?: number; operational_import_ready?: boolean; failure_reason?: string }; files: Array<{ report_type: string; original_name: string; row_count: number }> };
type ReceivableBackfillPreview = { batch_id: string; can_apply: boolean; eligible_documents: number; eligible_total: number; documents_to_insert: number; amount_to_insert: number; already_recorded_documents: number; excluded_unresolved_customer_documents: number; excluded_unresolved_customer_amount: number; duplicate_payload_hashes: number; staged_documents_missing_from_source: number; source_documents_not_in_staging: number; existing_document_conflicts: number };
type MigrationUploadResult = { files: string[]; kind: string; label: string; status: "staged" | "awaiting_configuration" | "validation_failed" | "duplicate" | "failed" | "unrecognized"; batch_id?: string; message?: string };
type CustomerIdentityConflict = {
  batch_id: string; cutoff_date: string; external_code: string; display_name: string; tax_id: string | null;
  commercial_type: string | null; credit_limit: number | null; credit_term_days: number | null;
  document_count: number; document_total: number; status: "discrepancy" | "promoted";
  differences: Array<{ code: string; message: string; severity: "error" | "warning"; evidence?: Record<string, unknown> }>;
  candidates: Array<{ id: string; code: string; display_name: string; tax_id: string | null; credit_enabled: boolean; match_reasons: string[] }>;
  latest_decision: { decision: string; reason: string; decided_at: string; decided_by: string; target_customer_id: string | null } | null;
  decision_history: Array<{ decision: string; reason: string; decided_at: string; decided_by: string; target_customer_id: string | null }>;
};

const alphaCustomerMigrationFile = /^(?:cata_cte|cat_ctee|lis_sal|cob_cte)_.+\.xlsx?$/i;

function customerMigrationStatusLabel(status: string) {
  return status === "ready_to_promote" ? "Listo para importar"
    : status === "promoting" ? "Importación en curso"
    : status === "staged" ? "Archivo preparado"
      : status === "completed" ? "Importación completada"
        : status === "completed_with_discrepancies" ? "Completada con diferencias"
          : status === "failed" ? "Fallida"
            : "Procesando";
}

function customerMigrationSummary(batch: CustomerMigrationBatch) {
  if (batch.summary.receivable_backfill?.status === "completed") return `${batch.records_promoted} clientes importados · CxC total: ${numberFormat(Number(batch.summary.receivable_backfill.total_after ?? 0))} MXN`;
  if (batch.summary.receivable_repair?.status === "completed") return `${batch.records_promoted} clientes importados · CxC corregida: ${numberFormat(Number(batch.summary.receivable_repair.corrected_total ?? 0))} MXN`;
  if (batch.status === "ready_to_promote") return `${batch.summary.reconciled_customers ?? 0} clientes listos · ${batch.differences} bloqueados`;
  if (batch.status === "promoting") return `${batch.records_promoted} clientes importados · ${batch.summary.remaining_customers ?? 0} pendientes`;
  if (batch.status === "staged") return `${batch.records_received} registros preparados para revisión`;
  return `${batch.records_promoted} clientes importados · ${batch.differences} diferencias`;
}

function uploadResultStatusLabel(status: MigrationUploadResult["status"]) {
  return status === "staged" ? "Preparado" : status === "awaiting_configuration" ? "Guardado · requiere revisión" : status === "validation_failed" ? "Estructura o datos por revisar" : status === "duplicate" ? "Ya importado" : status === "unrecognized" ? "Archivo no reconocido" : "No se pudo preparar";
}

function isMisroutedCustomerMigrationBatch(batch: StagedBatch) {
  return batch.import_type === "unsupported" && batch.import_files.some((file) => alphaCustomerMigrationFile.test(file.original_name));
}

function isCompletePurchasingMigrationBatch(batch: PurchasingMigrationBatch) {
  return purchasingUploadPackageState(batch.files.map((file) => file.original_name)).complete;
}

function MigrationCenter({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const [batches, setBatches] = useState<StagedBatch[]>([]);
  const [batchPage, setBatchPage] = useState(1);
  const [batchTotal, setBatchTotal] = useState(0);
  const [activeBatchId, setActiveBatchId] = useState<string | null>(null);
  const [preview, setPreview] = useState<StagingPreviewData | null>(null);
  const [page, setPage] = useState(1);
  const [statusFilter, setStatusFilter] = useState("");
  const [errorCodeFilter, setErrorCodeFilter] = useState("");
  const [busy, setBusy] = useState(false);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [operationDialog, setOperationDialog] = useState<OperationDialog | null>(null);
  const [customerMigrationBatches, setCustomerMigrationBatches] = useState<CustomerMigrationBatch[]>([]);
  const [purchasingMigrationBatches, setPurchasingMigrationBatches] = useState<PurchasingMigrationBatch[]>([]);
  const [customerConflicts, setCustomerConflicts] = useState<CustomerIdentityConflict[]>([]);
  const [receivableBackfill, setReceivableBackfill] = useState<ReceivableBackfillPreview | null>(null);
  const [receivableBackfillAcknowledged, setReceivableBackfillAcknowledged] = useState(false);
  const [uploadResults, setUploadResults] = useState<MigrationUploadResult[]>([]);
  const [pendingPurchasingFileCount, setPendingPurchasingFileCount] = useState(0);
  const [linkedAlphaFolderAvailable, setLinkedAlphaFolderAvailable] = useState(false);
  const pendingPurchasingFiles = useRef(new Map<string, File>());
  const canImport = permissions.some((permission) => ["import_data", "import_prices", "import_costs", "import_accounting_opening", "import_bank_statements"].includes(permission));
  const canImportCustomers = permissions.includes("import_data");
  const visibleBatches = batches.filter((batch) => !isMisroutedCustomerMigrationBatch(batch));
  const visibleCustomerMigrationBatches = customerMigrationBatches.filter((batch) => !(batch.status === "failed"
    && customerMigrationBatches.some((candidate) => candidate.id !== batch.id && candidate.cutoff_date === batch.cutoff_date && candidate.status !== "failed")));
  const visiblePurchasingMigrationBatches = purchasingMigrationBatches.filter((batch) => isCompletePurchasingMigrationBatch(batch)
    || !purchasingMigrationBatches.some((candidate) => candidate.cutoff_date === batch.cutoff_date && isCompletePurchasingMigrationBatch(candidate)));
  const active = visibleBatches.find((batch) => batch.id === activeBatchId) ?? visibleBatches[0] ?? null;

  const loadPreview = useCallback(async (batchId: string, requestedPage = page) => {
    setLoadingPreview(true);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const params = new URLSearchParams({ page: String(requestedPage), pageSize: "50" });
      if (statusFilter) params.set("status", statusFilter);
      if (errorCodeFilter) params.set("errorCode", errorCodeFilter);
      const response = await fetch(`/api/imports/stage/${batchId}?${params}`, {
        headers: { Authorization: `Bearer ${session.access_token}` },
        cache: "no-store",
      });
      const result = await response.json() as StagingPreviewData & { message?: string };
      if (!response.ok) throw new Error(result.message ?? "PREVIEW_FAILED");
      setPreview(result);
      setPage(result.pagination.page);
    } catch (error) {
      setPreview(null);
      setMessage(error instanceof Error && error.message !== "PREVIEW_FAILED" ? error.message : "No se pudo recuperar el preview persistente.");
    } finally {
      setLoadingPreview(false);
    }
  }, [errorCodeFilter, page, statusFilter]);

  const loadBatches = useCallback(async (preferredBatchId?: string, requestedBatchPage = batchPage) => {
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const params = new URLSearchParams({ companyId, page: String(requestedBatchPage), pageSize: "20" });
      const response = await fetch(`/api/imports/staged-batches?${params}`, {
        headers: { Authorization: `Bearer ${session.access_token}` },
        cache: "no-store",
      });
      const result = await response.json() as { batches?: StagedBatch[]; pagination?: { page: number; page_size: number; total: number }; message?: string };
      if (!response.ok) throw new Error(result.message ?? "BATCHES_FAILED");
      const nextBatches = result.batches ?? [];
      const returnedPage = result.pagination?.page ?? requestedBatchPage;
      const nextTotal = result.pagination?.total ?? 0;
      setBatchTotal(nextTotal);
      if (nextBatches.length === 0 && nextTotal > 0 && returnedPage > 1) {
        setBatchPage(returnedPage - 1);
        return;
      }
      setBatchPage(returnedPage);
      const nextVisibleBatches = nextBatches.filter((batch) => !isMisroutedCustomerMigrationBatch(batch));
      setBatches(nextBatches);
      setActiveBatchId((current) => preferredBatchId && nextVisibleBatches.some((batch) => batch.id === preferredBatchId)
        ? preferredBatchId
        : nextVisibleBatches.find((batch) => batch.id === current)?.id ?? nextVisibleBatches[0]?.id ?? null);
    } catch {
      setMessage("No se pudieron recuperar las importaciones en staging.");
    }
  }, [batchPage, companyId]);

  useEffect(() => { void Promise.resolve().then(() => loadBatches()); }, [loadBatches]);
  const loadCustomerMigrationBatches = useCallback(async () => {
    const session = (await getSupabaseClient().auth.getSession()).data.session;
    if (!session) return;
    const response = await fetch(`/api/imports/customer-migration?companyId=${encodeURIComponent(companyId)}`, { headers: { Authorization: `Bearer ${session.access_token}` }, cache: "no-store" });
    if (!response.ok) return;
    const result = await response.json() as { batches?: CustomerMigrationBatch[] };
    setCustomerMigrationBatches(result.batches ?? []);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(loadCustomerMigrationBatches); }, [loadCustomerMigrationBatches]);
  const loadPurchasingMigrationBatches = useCallback(async () => {
    const session = (await getSupabaseClient().auth.getSession()).data.session;
    if (!session) return;
    const response = await fetch(`/api/imports/purchasing-migration?companyId=${encodeURIComponent(companyId)}&page=1&pageSize=20`, { headers: { Authorization: `Bearer ${session.access_token}` }, cache: "no-store" });
    if (!response.ok) return;
    const result = await response.json() as { items?: PurchasingMigrationBatch[] };
    setPurchasingMigrationBatches(result.items ?? []);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(loadPurchasingMigrationBatches); }, [loadPurchasingMigrationBatches]);
  useEffect(() => {
    void fetch("/api/imports/stage-folder", { cache: "no-store" })
      .then((response) => response.ok ? response.json() as Promise<{ available?: boolean }> : null)
      .then((result) => setLinkedAlphaFolderAvailable(Boolean(result?.available)))
      .catch(() => setLinkedAlphaFolderAvailable(false));
  }, []);
  const loadCustomerConflicts = useCallback(async () => {
    const session = (await getSupabaseClient().auth.getSession()).data.session;
    if (!session) return;
    const response = await fetch(`/api/imports/customer-migration/conflicts?companyId=${encodeURIComponent(companyId)}`, { headers: { Authorization: `Bearer ${session.access_token}` }, cache: "no-store" });
    if (!response.ok) return;
    const result = await response.json() as { conflicts?: CustomerIdentityConflict[] };
    setCustomerConflicts(result.conflicts ?? []);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(loadCustomerConflicts); }, [loadCustomerConflicts]);
  useEffect(() => {
    void Promise.resolve().then(() => {
      if (!activeBatchId) { setPreview(null); return; }
      const saved = window.sessionStorage.getItem(`satrapy-staging-view:${activeBatchId}`);
      if (saved) {
        try {
          const state = JSON.parse(saved) as { page?: number; status?: string; errorCode?: string };
          setPage(state.page && state.page > 0 ? state.page : 1);
          setStatusFilter(state.status ?? "");
          setErrorCodeFilter(state.errorCode ?? "");
          return;
        } catch { /* Se recupera con valores seguros. */ }
      }
      setPage(1); setStatusFilter(""); setErrorCodeFilter("");
    });
  }, [activeBatchId]);
  useEffect(() => {
    if (!activeBatchId) return;
    window.sessionStorage.setItem(`satrapy-staging-view:${activeBatchId}`, JSON.stringify({ page, status: statusFilter, errorCode: errorCodeFilter }));
    void Promise.resolve().then(() => loadPreview(activeBatchId, page));
  }, [activeBatchId, errorCodeFilter, loadPreview, page, statusFilter]);

  async function addFiles(files: FileList | File[]) {
    const readyFiles: File[] = [];
    for (const file of Array.from(files)) {
      const kind = classifyAlphaUpload(file.name);
      if (isPurchasingAlphaUpload(kind)) pendingPurchasingFiles.current.set(kind, file);
      else readyFiles.push(file);
    }
    const purchasingState = purchasingUploadPackageState([...pendingPurchasingFiles.current.values()].map((file) => file.name));
    setPendingPurchasingFileCount(purchasingState.detected);
    if (purchasingState.complete) readyFiles.push(...pendingPurchasingFiles.current.values());
    if (!readyFiles.length) {
      setUploadResults([]);
      setMessage(`Compras/CxP: ${purchasingState.detected}/4 archivos detectados. Satrapy esperará el paquete completo antes de crear staging.`);
      return;
    }
    setBusy(true);
    setMessage(null);
    setUploadResults([]);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const form = new FormData();
      form.set("companyId", companyId);
      readyFiles.forEach((file) => form.append("files", file));
      const response = await fetch("/api/imports/stage-all", { method: "POST", headers: { Authorization: `Bearer ${session.access_token}` }, body: form });
      const result = await response.json() as { results?: MigrationUploadResult[]; message?: string };
      if (!response.ok) throw new Error(result.message ?? "No se pudo preparar la carga.");
      const results = result.results ?? [];
      setUploadResults(results);
      if (purchasingState.complete) {
        pendingPurchasingFiles.current.clear();
        setPendingPurchasingFileCount(0);
      }
      const batchId = results.find((item) => item.batch_id)?.batch_id;
      await Promise.all([loadBatches(batchId, 1), loadCustomerMigrationBatches(), loadPurchasingMigrationBatches(), loadCustomerConflicts()]);
      const prepared = results.filter((item) => item.status === "staged").length;
      const rejected = results.filter((item) => item.status === "unrecognized" || item.status === "failed").length;
      const pendingSuffix = purchasingState.detected && !purchasingState.complete ? ` Compras/CxP conserva ${purchasingState.detected}/4 archivos en espera.` : "";
      setMessage((rejected ? `${prepared} carga${prepared === 1 ? "" : "s"} preparada${prepared === 1 ? "" : "s"}; ${rejected} requiere${rejected === 1 ? "" : "n"} revisión.` : "La carga quedó preparada en staging. Puedes revisar cada resultado antes de confirmar.") + pendingSuffix);
      toast({ title: rejected ? "Carga preparada con incidencias" : "Carga preparada", description: "Cada resultado conserva su staging y auditoría.", tone: rejected ? "info" : "success" });
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo generar el staging del archivo.");
    } finally {
      setBusy(false);
    }
  }

  async function consolidatePurchasingFromLinkedFolder() {
    setBusy(true);
    setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch("/api/imports/stage-folder", {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ companyId, mode: "purchasing" }),
      });
      const result = await response.json() as { status?: string; batch_id?: string; message?: string };
      if (!response.ok) throw new Error(result.message ?? "No se pudo consolidar Compras/CxP.");
      await loadPurchasingMigrationBatches();
      setMessage(result.status === "duplicate" ? "El paquete consolidado de Compras/CxP ya estaba preparado." : "Los cuatro archivos quedaron consolidados en un solo paquete de staging.");
      toast({ title: "Compras y CxP consolidadas", description: "La evidencia permanece en staging; todavía no crea operaciones ni saldos.", tone: "success" });
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo consolidar Compras/CxP.");
    } finally {
      setBusy(false);
    }
  }

  async function promoteCustomerMigration(batchId: string) {
    setBusy(true); setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch(`/api/imports/customer-migration/${batchId}/promote`, { method: "POST", headers: { Authorization: `Bearer ${session.access_token}` } });
      const result = await response.json() as { message?: string; status?: string; chunk_promoted?: number; promoted_customers?: number; blocked_customers?: number; remaining_customers?: number };
      if (!response.ok) throw new Error(result.message ?? "No se pudo promover Clientes/CxC.");
      const remaining = result.remaining_customers ?? 0;
      setMessage(remaining > 0
        ? `Bloque procesado: ${result.chunk_promoted ?? 0} clientes. Quedan ${remaining}; usa “Continuar importación” para el siguiente bloque.`
        : `Migración ${result.status}: ${result.promoted_customers ?? 0} clientes promovidos y ${result.blocked_customers ?? 0} bloqueados.`);
      toast({
        title: remaining > 0 ? "Bloque importado" : "Promoción terminada",
        description: remaining > 0 ? `Quedan ${remaining} clientes por procesar.` : "Los clientes con diferencias permanecen bloqueados.",
        tone: "success",
      });
      await Promise.all([loadCustomerMigrationBatches(), loadCustomerConflicts()]);
    } catch (error) { setMessage(error instanceof Error ? error.message : "No se pudo promover Clientes/CxC."); }
    finally { setBusy(false); }
  }

  async function repairCustomerMigration(batchId: string) {
    setBusy(true); setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const request = async (mode: "preview" | "apply") => {
        const response = await fetch(`/api/imports/customer-migration/${batchId}/repair`, { method: "POST", headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" }, body: JSON.stringify({ mode }) });
        const result = await response.json() as { message?: string; can_apply?: boolean; current_total?: number; source_total?: number; payments_at_risk?: number; unmatched_source_documents?: number; corrected_total?: number; documents_closed?: number; documents_updated?: number; documents_inserted?: number };
        if (!response.ok) throw new Error(result.message ?? "No se pudo corregir CxC.");
        return result;
      };
      const preview = await request("preview");
      if (!preview.can_apply) throw new Error(`La corrección se bloqueó sin cambiar datos: ${preview.payments_at_risk ?? 0} pagos requieren revisión y ${preview.unmatched_source_documents ?? 0} documentos no coincidieron con staging.`);
      const result = await request("apply");
      setMessage(`Saldos de CxC validados desde lis_sal: ${numberFormat(Number(preview.current_total ?? 0))} MXN → ${numberFormat(Number(result.corrected_total ?? 0))} MXN. ${result.documents_closed ?? 0} documentos cerrados, ${result.documents_updated ?? 0} actualizados y ${result.documents_inserted ?? 0} incorporados.`);
      toast({ title: "Saldos de CxC validados", description: "La conciliación quedó registrada en auditoría.", tone: "success" });
      await loadCustomerMigrationBatches();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo corregir CxC.");
      toast({ title: "No se modificaron los saldos", description: error instanceof Error ? error.message : "La validación preventiva bloqueó la corrección.", tone: "error" });
    } finally { setBusy(false); }
  }

  async function decideCustomerConflict(conflict: CustomerIdentityConflict, decision: "link_existing" | "create_cash_without_rfc" | "leave_pending", reason: string, targetCustomerId?: string): Promise<boolean> {
    setBusy(true); setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch(`/api/imports/customer-migration/conflicts/${conflict.batch_id}/${encodeURIComponent(conflict.external_code)}`, {
        method: "POST", headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ decision, reason, targetCustomerId: targetCustomerId ?? null }),
      });
      const result = await response.json() as { message?: string; status?: string; remaining_conflicts?: number };
      if (!response.ok) throw new Error(result.message ?? "No se pudo registrar la decisión.");
      const label = decision === "link_existing" ? "Cliente vinculado" : decision === "create_cash_without_rfc" ? "Cliente de contado creado" : "Caso dejado pendiente";
      setMessage(`${label}. Quedan ${result.remaining_conflicts ?? 0} conflictos críticos en el lote.`);
      toast({ title: label, description: "La decisión, el motivo y la evidencia quedaron auditados.", tone: "success" });
      await Promise.all([loadCustomerMigrationBatches(), loadCustomerConflicts()]);
      return true;
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo registrar la decisión.");
      return false;
    } finally { setBusy(false); }
  }

  async function previewReceivableBackfill(batchId: string) {
    setBusy(true); setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch(`/api/imports/customer-migration/${batchId}/receivable-backfill`, { method: "POST", headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" }, body: JSON.stringify({ mode: "preview" }) });
      const result = await response.json() as ReceivableBackfillPreview & { message?: string };
      if (!response.ok) throw new Error(result.message ?? "No se pudo preparar la incorporación de CxC.");
      setReceivableBackfill(result);
      setReceivableBackfillAcknowledged(false);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo preparar la incorporación de CxC.");
    } finally { setBusy(false); }
  }

  async function applyReceivableBackfill() {
    if (!receivableBackfill) return;
    setBusy(true); setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch(`/api/imports/customer-migration/${receivableBackfill.batch_id}/receivable-backfill`, { method: "POST", headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" }, body: JSON.stringify({ mode: "apply" }) });
      const result = await response.json() as { message?: string; documents_inserted?: number; amount_inserted?: number; total_after?: number };
      if (!response.ok) throw new Error(result.message ?? "No se pudo incorporar la CxC pendiente.");
      setMessage(`CxC incorporada: ${result.documents_inserted ?? 0} documentos por ${numberFormat(Number(result.amount_inserted ?? 0))} MXN. Total vigente: ${numberFormat(Number(result.total_after ?? 0))} MXN.`);
      toast({ title: "CxC pendiente incorporada", description: "Solo se agregaron documentos verificados de clientes promovidos; la operación quedó auditada.", tone: "success" });
      setReceivableBackfill(null);
      await loadCustomerMigrationBatches();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo incorporar la CxC pendiente.");
      toast({ title: "No se modificó CxC", description: error instanceof Error ? error.message : "La validación preventiva bloqueó la incorporación.", tone: "error" });
    } finally { setBusy(false); }
  }

  async function reviewLocation(externalCode: string, locationType: LocationType) {
    if (!active) return;
    setBusy(true);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("SESSION");
      const response = await fetch(`/api/imports/stage/${active.id}/location`, {
        method: "PATCH",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ externalCode, locationType }),
      });
      if (!response.ok) throw new Error("REVIEW_FAILED");
      await loadBatches(active.id);
      await loadPreview(active.id, page);
      setMessage("Clasificación guardada en staging.");
      toast({ title: "Ubicación clasificada", description: "La revisión quedó guardada en staging.", tone: "success" });
    } catch {
      setMessage("No se pudo guardar la clasificación de ubicación.");
    } finally {
      setBusy(false);
    }
  }

  async function runAction(body: Record<string, unknown>) {
    if (!active || busy) return null;
    setBusy(true);
    setMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("Sesión no válida.");
      const response = await fetch(`/api/imports/stage/${active.id}/actions`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      const result = await response.json() as { status?: string; batch_id?: string; records_imported?: number; count?: number; message?: string };
      if (!response.ok) throw new Error(result.message ?? "No se pudo completar la operación.");
      return result;
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "No se pudo completar la operación.");
      return null;
    } finally {
      setBusy(false);
    }
  }

  async function confirmImport(assortmentIds: string[] = []) {
    const result = await runAction({ action: "confirm", assortmentIds });
    setConfirming(false);
    if (!result) return;
    if (result.status === "completed") {
      await loadBatches();
      setMessage(`Importación finalizada: ${result.records_imported ?? 0} registros aplicados de forma atómica.`);
      toast({ title: "Importación finalizada", description: `${result.records_imported ?? 0} registros fueron aplicados de forma atómica.`, tone: "success" });
    } else {
      if (active) { await loadBatches(active.id); await loadPreview(active.id, page); }
      setMessage(result.message ?? "La importación no se completó y no dejó datos parciales.");
    }
  }

  async function completeOperation(payload: { productId?: string; reason: string }) {
    if (!operationDialog || !active) return;
    const body = operationDialog.kind === "product"
      ? { action: "resolve_product", stagingRowId: operationDialog.row.id, productId: payload.productId, reason: payload.reason }
      : operationDialog.kind === "warning"
        ? { action: "acknowledge_warnings", errorCode: operationDialog.code, reason: payload.reason }
        : { action: operationDialog.kind, reason: payload.reason };
    const result = await runAction(body);
    if (!result) return;
    setOperationDialog(null);
    if (operationDialog.kind === "retry" && result.batch_id) {
      await loadBatches(result.batch_id);
      setMessage("Se creó un nuevo lote de reintento con el staging conservado.");
      return;
    }
    await loadBatches(active.id);
    if (operationDialog.kind !== "discard") await loadPreview(active.id, page);
    setMessage(operationDialog.kind === "product" ? "Mapeo de producto registrado." : operationDialog.kind === "warning" ? "Alertas reconocidas y auditadas." : "Lote descartado y conservado en auditoría.");
    toast({ title: "Operación registrada", description: "El cambio quedó trazable en la auditoría.", tone: "success" });
  }

  const summaryBatch = preview?.batch ?? active;
  const locationsPendingReview = preview?.pending_locations ?? [];
  const readyForImport = Boolean(summaryBatch && summaryBatch.status === "staged" && summaryBatch.blocking_error_count === 0
    && summaryBatch.pending_warning_count === 0 && locationsPendingReview.length === 0 && canImport);

  return (
    <div className="content-frame migration-view">
      <PageHeading eyebrow="Importación" title="Centro de Migración" description="Carga juntos los archivos de origen; Satrapy los reconoce, valida y conserva en staging antes de confirmar." />
      <section className="migration-grid">
        <div className="upload-stack">
          <label className="upload-zone">
            <Upload size={22} />
            <strong>Subir archivos de origen</strong>
            <span>Selecciona todos los CSV o Excel disponibles. Satrapy detecta cada archivo automáticamente y conserva un resultado por archivo o paquete.</span>
            <input type="file" accept=".csv,.xls,.xlsx" multiple disabled={!canImport || busy} onChange={(event) => { const selected = Array.from(event.target.files ?? []); event.target.value = ""; if (selected.length) void addFiles(selected); }} />
          </label>
          {pendingPurchasingFileCount > 0 && <p className="permission-note">Compras/CxP: {pendingPurchasingFileCount}/4 archivos detectados. No se creará staging hasta completar el paquete.</p>}
          {uploadResults.length > 0 && <section className="upload-results" aria-label="Resultado de la carga">{uploadResults.map((result) => <article key={`${result.kind}:${result.files.join("|")}`}><div><strong>{result.label}</strong><small>{result.files.join(", ")}{result.message ? ` · ${presentImportedSourceText(result.message)}` : ""}</small></div><Badge tone={result.status === "staged" ? "success" : result.status === "duplicate" ? "neutral" : result.status === "awaiting_configuration" || result.status === "validation_failed" ? "warning" : "danger"}>{uploadResultStatusLabel(result.status)}</Badge></article>)}</section>}
        </div>
        <div className="import-rules">
          <span className="eyebrow">Antes de confirmar</span>
          <ul>
            <li><Check size={15} /> El preview queda guardado aunque recargues la página.</li>
            <li><Check size={15} /> SKU, producto, ubicación y cantidades se validan antes de confirmar.</li>
            <li><Check size={15} /> La confirmación final es una sola transacción auditable.</li>
            <li><Check size={15} /> Un archivo ya completado no se vuelve a importar.</li>
          </ul>
          <div className="folder-import-actions"><span>Para estados bancarios sin formato propio:</span><div><a className="secondary-button" href="/templates/plantilla_estado_bancario_neutral.xlsx" download>Plantilla XLSX</a><a className="secondary-button" href="/templates/plantilla_estado_bancario_neutral.csv" download>Plantilla CSV</a></div></div>
        </div>
      </section>

      <section className="location-review">
        <div><span className="eyebrow">Clientes y CxC importados</span><h2>Paquetes detectados</h2><p>Los archivos cata_cte, cat_ctee, lis_sal y cob_cte se agrupan automáticamente. Satrapy compara las fuentes y valida qué datos están listos para importar. Cobranza es evidencia: nunca genera abonos.</p></div>
        <div className="location-review-list">
          <div className="location-review-note"><FileSpreadsheet size={22} /><span>Satrapy detecta los archivos, compara sus datos y bloquea cualquier diferencia antes de la importación final.</span></div>
          {visibleCustomerMigrationBatches.map((batch) => <div className="location-review-row" key={batch.id}><span><strong>Corte {dateOnlyFormat(batch.cutoff_date)} · {customerMigrationStatusLabel(batch.status)}</strong><small>{customerMigrationSummary(batch)}</small></span>{["ready_to_promote", "promoting"].includes(batch.status) && <button className="primary-button" disabled={busy || !canImportCustomers} onClick={() => void promoteCustomerMigration(batch.id)}>{batch.status === "promoting" ? "Continuar importación" : "Importar clientes y CxC"}</button>}{["completed", "completed_with_discrepancies"].includes(batch.status) && batch.summary.receivable_repair?.status !== "completed" && customerConflicts.every((conflict) => conflict.batch_id !== batch.id) && <button className="secondary-button" disabled={busy || !canImportCustomers} onClick={() => void repairCustomerMigration(batch.id)}>Validar saldos CxC</button>}{(batch.summary.customer_identity_repair?.status === "completed" || batch.summary.customer_conflict_review?.status === "completed") && batch.summary.receivable_repair?.status === "completed" && batch.summary.receivable_backfill?.status !== "completed" && <button className="secondary-button" disabled={busy || !canImportCustomers} onClick={() => void previewReceivableBackfill(batch.id)}>Revisar CxC de clientes resueltos</button>}</div>)}
        </div>
      </section>

      <section className="location-review">
        <div><span className="eyebrow">Compras y CxP importados</span><h2>Paquetes de evidencia</h2><p>Satrapy agrupa cata_prv, rpcon2, lfchvenc y pag_det. Los datos quedan en staging y auditoría; no crean recepciones, saldos ni pagos operativos hasta que el flujo correspondiente esté habilitado.</p>{linkedAlphaFolderAvailable && <button className="secondary-button" disabled={busy || !canImportCustomers} onClick={() => void consolidatePurchasingFromLinkedFolder()}>Consolidar archivos detectados</button>}</div>
        <div className="location-review-list">
          <div className="location-review-note"><FileSpreadsheet size={22} /><span>Flujo confirmado: Proveedor → OC → Aprobación. La recepción vinculada no está en los archivos entregados y permanece como brecha explícita.</span></div>
          {visiblePurchasingMigrationBatches.map((batch) => <div className="location-review-row" key={batch.id}><span><strong>Corte {dateOnlyFormat(batch.cutoff_date)} · {batch.status === "staged" ? "Evidencia preparada" : batch.status === "validation_failed" ? "Datos por revisar" : batch.status === "failed" ? "Fallida" : "Procesando"}</strong><small>{batch.summary.suppliers ?? 0} proveedores · {batch.summary.purchase_orders ?? 0} OC / {batch.summary.purchase_order_lines ?? 0} partidas · {batch.summary.payable_documents ?? 0} documentos CxP por {numberFormat(Number(batch.summary.payable_outstanding_total ?? 0))} MXN · {batch.summary.supplier_payments ?? 0} aplicaciones de pago como evidencia</small><small>{batch.summary.error_count ?? 0} errores · {batch.summary.warning_count ?? 0} alertas · recepción histórica no disponible</small></span><Badge tone={batch.status === "staged" ? "warning" : batch.status === "validation_failed" || batch.status === "failed" ? "danger" : "neutral"}>{batch.status === "staged" ? "Solo staging" : batch.status === "validation_failed" ? "Revisión requerida" : batch.status === "failed" ? "Fallida" : "Procesando"}</Badge></div>)}
        </div>
      </section>

      {customerConflicts.length > 0 && <CustomerConflictInbox conflicts={customerConflicts} busy={busy || !canImportCustomers} onDecide={decideCustomerConflict} />}

      {(busy || loadingPreview) && <div className="inline-status"><LoaderCircle className="spin" size={17} /> {busy ? "Procesando…" : "Cargando staging…"}</div>}
      {message && <div className={`inline-status ${message.includes("falló") || message.includes("bloqueó") || message.includes("pudo") ? "is-error" : "is-success"}`}>{message.includes("finalizada") || message.includes("generado") || message.includes("guardada") ? <Check size={17} /> : <AlertCircle size={17} />}{presentImportedSourceText(message)}</div>}

      {visibleBatches.length > 0 && (
        <section className="import-preview-shell">
          <div className="preview-file-tabs" role="tablist" aria-label="Importaciones en staging">
            {visibleBatches.map((batch) => <button role="tab" aria-selected={active?.id === batch.id} className={active?.id === batch.id ? "is-active" : ""} onClick={() => setActiveBatchId(batch.id)} key={batch.id}>{fileNameForBatch(batch)}{batch.status === "failed" ? " · fallido" : ""}</button>)}
          </div>
          {batchTotal > 20 && <div className="staging-pagination"><span>Lotes {((batchPage - 1) * 20) + 1}–{Math.min(batchPage * 20, batchTotal)} de {batchTotal}</span><div><button className="secondary-button" disabled={batchPage <= 1 || busy} onClick={() => setBatchPage(value => Math.max(1, value - 1))}>Lotes recientes</button><button className="secondary-button" disabled={batchPage * 20 >= batchTotal || busy} onClick={() => setBatchPage(value => value + 1)}>Lotes anteriores</button></div></div>}
          {active?.status === "failed" && <div className="staging-lifecycle"><div><strong>Este lote falló sin aplicar datos parciales.</strong><span>El staging sigue disponible para un reintento controlado.</span></div><button className="secondary-button" disabled={busy || Boolean(active.staging_purged_at)} onClick={() => setOperationDialog({ kind: "retry" })}>Reintentar</button></div>}
          {preview && <StagingPreview preview={preview} statusFilter={statusFilter} errorCodeFilter={errorCodeFilter}
            onStatusChange={(value) => { setPage(1); setStatusFilter(value); }} onErrorCodeChange={(value) => { setPage(1); setErrorCodeFilter(value); }}
            onResolve={(row) => setOperationDialog({ kind: "product", row })} onAcknowledge={(code) => setOperationDialog({ kind: "warning", code })} />}
          {preview?.commercial_requirements && <CommercialReview requirements={preview.commercial_requirements} busy={busy} onAction={async (body) => { const result = await runAction(body); if (result && active) { await loadBatches(active.id); await loadPreview(active.id, page); } }} />}
          {active && active.import_type === "inventory" && locationsPendingReview.length > 0 && <LocationReview locations={locationsPendingReview.map((location) => ({ externalCode: location.external_code, name: location.name }))} onReview={reviewLocation} />}
          {preview && preview.pagination.total > preview.pagination.page_size && <div className="staging-pagination"><span>Página {preview.pagination.page} de {Math.max(1, Math.ceil(preview.pagination.total / preview.pagination.page_size))} · {preview.pagination.total} filas</span><div><button className="secondary-button" disabled={page <= 1 || busy} onClick={() => setPage((value) => Math.max(1, value - 1))}>Anterior</button><button className="secondary-button" disabled={page * preview.pagination.page_size >= preview.pagination.total || busy} onClick={() => setPage((value) => value + 1)}>Siguiente</button></div></div>}
          {active && (
            <div className="confirm-bar">
              <div><strong>{summaryBatch?.blocking_error_count ? `${summaryBatch.blocking_error_count} errores pendientes` : summaryBatch?.pending_warning_count ? `${summaryBatch.pending_warning_count} alertas por reconocer` : readyForImport ? "Listo para confirmar" : active.status === "failed" ? "Lote fallido" : "Staging con incidencias"}</strong><span>{summaryBatch?.valid_rows ?? 0} válidas · {summaryBatch?.warning_rows ?? 0} con alerta · {summaryBatch?.error_rows ?? 0} con error</span></div>
              <div className="confirm-actions">{["staged", "validation_failed"].includes(active.status) && <button className="secondary-button danger-button" disabled={busy} onClick={() => setOperationDialog({ kind: "discard" })}>Descartar</button>}<button className="primary-button" disabled={!readyForImport || busy} onClick={() => setConfirming(true)}><ClipboardCheck size={17} /> Confirmar importación</button></div>
            </div>
          )}
          {!canImport && <p className="permission-note">Tu rol no tiene permiso para preparar ni confirmar importaciones.</p>}
        </section>
      )}
      {confirming && active && <ConfirmDialog companyId={companyId} batch={active} busy={busy} onCancel={() => !busy && setConfirming(false)} onConfirm={(assortmentIds) => void confirmImport(assortmentIds)} />}
      {operationDialog && <StagingOperationDialog operation={operationDialog} companyId={companyId} busy={busy} onCancel={() => !busy && setOperationDialog(null)} onConfirm={(payload) => void completeOperation(payload)} />}
      {receivableBackfill && <Modal open onOpenChange={(open) => { if (!open && !busy) setReceivableBackfill(null); }} eyebrow="CxC pendiente" title="Revisar incorporación de documentos" description="Solo se agregarán documentos cuya clave y hash coincidan con lis_sal y cuyo cliente de staging ya tenga un cliente canónico promovido." footer={<><Button variant="secondary" disabled={busy} onClick={() => setReceivableBackfill(null)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!receivableBackfill.can_apply || !receivableBackfillAcknowledged} onClick={() => void applyReceivableBackfill()}>Incorporar documentos auditados</Button></>}><div className="pos-prep-confirm-summary"><span><strong>{receivableBackfill.documents_to_insert}</strong> documentos por <strong>{numberFormat(Number(receivableBackfill.amount_to_insert))} MXN</strong> se agregarán</span><span><strong>{receivableBackfill.already_recorded_documents}</strong> documentos ya existen y no se duplicarán</span><span><strong>{receivableBackfill.excluded_unresolved_customer_documents}</strong> documentos por <strong>{numberFormat(Number(receivableBackfill.excluded_unresolved_customer_amount))} MXN</strong> quedan fuera por clientes sin resolver</span><span><strong>{receivableBackfill.existing_document_conflicts + receivableBackfill.duplicate_payload_hashes + receivableBackfill.staged_documents_missing_from_source + receivableBackfill.source_documents_not_in_staging}</strong> inconsistencias bloqueantes</span></div>{!receivableBackfill.can_apply && <p className="permission-note">No se puede aplicar: el preview detectó una incompatibilidad de hash, staging o documento existente.</p>}<label className="checkbox-label"><input type="checkbox" checked={receivableBackfillAcknowledged} disabled={busy || !receivableBackfill.can_apply} onChange={(event) => setReceivableBackfillAcknowledged(event.target.checked)} /> Confirmo el preview; esta operación no modifica clientes, pagos ni documentos existentes.</label></Modal>}
    </div>
  );
}

function CustomerConflictInbox({ conflicts, busy, onDecide }: {
  conflicts: CustomerIdentityConflict[];
  busy: boolean;
  onDecide: (conflict: CustomerIdentityConflict, decision: "link_existing" | "create_cash_without_rfc" | "leave_pending", reason: string, targetCustomerId?: string) => Promise<boolean>;
}) {
  const [selection, setSelection] = useState<{ conflict: CustomerIdentityConflict; decision: "link_existing" | "create_cash_without_rfc" | "leave_pending" } | null>(null);
  const [reason, setReason] = useState("");
  const [targetCustomerId, setTargetCustomerId] = useState("");
  const open = (conflict: CustomerIdentityConflict, decision: "link_existing" | "create_cash_without_rfc" | "leave_pending") => {
    setSelection({ conflict, decision });
    setReason("");
    setTargetCustomerId(conflict.candidates[0]?.id ?? "");
  };
  const decisionLabel = selection?.decision === "link_existing" ? "Vincular cliente existente" : selection?.decision === "create_cash_without_rfc" ? "Crear de contado sin RFC" : "Dejar pendiente";
  return <section className="customer-conflict-inbox" aria-labelledby="customer-conflicts-title">
    <div className="customer-conflict-inbox__heading"><div><span className="eyebrow">Revisión requerida</span><h2 id="customer-conflicts-title">Conflictos de identidad de clientes</h2><p>{conflicts.length} caso{conflicts.length === 1 ? "" : "s"} crítico{conflicts.length === 1 ? "" : "s"}. La CxC de cada caso queda bloqueada hasta que el cliente tenga una decisión auditada.</p></div><Badge tone="danger">{conflicts.length} pendientes</Badge></div>
    <div className="customer-conflict-list">{conflicts.map((conflict) => <article key={`${conflict.batch_id}:${conflict.external_code}`}>
      <div className="customer-conflict-source"><span className="customer-conflict-code">{conflict.external_code}</span><strong>{presentImportedSourceText(conflict.display_name)}</strong><small>RFC de origen: {conflict.tax_id || "sin RFC"} · Corte {dateOnlyFormat(conflict.cutoff_date)}</small><small>{conflict.document_count} documento{conflict.document_count === 1 ? "" : "s"} CxC por {numberFormat(Number(conflict.document_total))} MXN — no se incorporarán aún.</small></div>
      <div className="customer-conflict-details"><div><b>Diferencias</b>{conflict.differences.map((difference) => <p key={`${difference.code}:${difference.message}`}>{presentImportedSourceText(difference.message)}</p>)}</div><div><b>Candidatos canónicos</b>{conflict.candidates.length ? conflict.candidates.map((candidate) => <p key={candidate.id}><strong>{presentImportedSourceText(candidate.display_name)}</strong> · {candidate.code} · RFC {candidate.tax_id || "—"}<small>{candidate.match_reasons.join(" · ")}{candidate.credit_enabled ? " · tiene crédito" : " · sin crédito"}</small></p>) : <p>No se encontró coincidencia automática; puedes crear el cliente de contado sin RFC o dejar el caso pendiente.</p>}</div></div>
      <div className="customer-conflict-actions"><button className="secondary-button" disabled={busy || conflict.candidates.length === 0} onClick={() => open(conflict, "link_existing")}>Vincular existente</button><button className="secondary-button" disabled={busy} onClick={() => open(conflict, "create_cash_without_rfc")}>Crear de contado sin RFC</button><button className="text-button" disabled={busy} onClick={() => open(conflict, "leave_pending")}>Dejar pendiente</button></div>
    </article>)}</div>
    {selection && <Modal open onOpenChange={(isOpen) => { if (!isOpen && !busy) setSelection(null); }} eyebrow="Decisión de identidad" title={decisionLabel} description={selection.decision === "link_existing" ? "Elige el cliente canónico que coincide con la evidencia. No se creará otro cliente." : selection.decision === "create_cash_without_rfc" ? "Se creará un cliente de contado, sin RFC y sin crédito. El RFC de origen se conserva solo en la evidencia de importación." : "El cliente y sus documentos CxC seguirán bloqueados. Puedes retomarlo después desde esta bandeja."} footer={<><Button variant="secondary" disabled={busy} onClick={() => setSelection(null)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!reason.trim() || (selection.decision === "link_existing" && !targetCustomerId)} onClick={() => void onDecide(selection.conflict, selection.decision, reason, targetCustomerId || undefined).then((saved) => { if (saved) setSelection(null); })}>Registrar decisión</Button></>}><div className="customer-conflict-decision">{selection.decision === "link_existing" && <label>Cliente existente<Select ariaLabel="Cliente canónico a vincular" value={targetCustomerId || "unselected"} onValueChange={(value) => setTargetCustomerId(value === "unselected" ? "" : value)} options={[{ value: "unselected", label: "Seleccionar cliente", disabled: true }, ...selection.conflict.candidates.map((candidate) => ({ value: candidate.id, label: `${candidate.display_name} · ${candidate.code} · ${candidate.match_reasons.join(", ")}` }))]} /></label>}<label className="operation-reason">Motivo<textarea value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Explica la evidencia de esta decisión para la auditoría" rows={3} /></label></div></Modal>}
  </section>;
}

function StagingPreview({ preview, statusFilter, errorCodeFilter, onStatusChange, onErrorCodeChange, onResolve, onAcknowledge }: { preview: StagingPreviewData; statusFilter: string; errorCodeFilter: string; onStatusChange: (value: string) => void; onErrorCodeChange: (value: string) => void; onResolve: (row: StagedRow) => void; onAcknowledge: (code: string) => void }) {
  const { batch, rows, error_groups: groups } = preview;
  const label = batch.import_type === "products" ? "Catálogo de productos" : batch.import_type === "inventory" ? "Inventario por ubicación" : batch.import_type === "prices" ? "Listas de precios" : batch.import_type === "costs" ? "Costos de reposición" : "Archivo no compatible";
  const taxSummaryLabel = (preview.tax_summary ?? []).map(({ tax_category_code: code, total }) => `${code === "IVA16" ? "IVA 16%" : code === "IVA0" ? "IVA tasa 0%" : code}: ${total}`).join(" · ");
  return <div className="import-preview"><div className="preview-summary"><span className="file-kind">{label}</span><span>{batch.records_received} filas leídas</span>{["inventory", "prices", "costs"].includes(batch.import_type) && <span>Fecha efectiva: {batch.snapshot_date ? dateOnlyFormat(batch.snapshot_date) : "pendiente de validación"}</span>}{taxSummaryLabel && <span>Fiscal: {taxSummaryLabel}</span>}<span>{batch.valid_rows} válidas · {batch.warning_rows} alertas · {batch.error_rows} errores</span></div>
    <div className="staging-filters"><label>Estado<Select ariaLabel="Filtrar filas por estado" value={statusFilter || "all"} onValueChange={(value) => onStatusChange(value === "all" ? "" : value)} options={[{ value: "all", label: "Todos" }, { value: "valid", label: "Válidas" }, { value: "warning", label: "Alertas" }, { value: "error", label: "Errores" }]} /></label><label>Incidencia<Select ariaLabel="Filtrar filas por incidencia" value={errorCodeFilter || "all"} onValueChange={(value) => onErrorCodeChange(value === "all" ? "" : value)} options={[{ value: "all", label: "Todas" }, ...groups.map((group) => ({ value: group.error_code, label: `${group.error_code} (${group.total})` }))]} /></label></div>
    {groups.length > 0 && <div className="staging-groups">{groups.map((group) => <div key={`${group.error_code}:${group.severity}`}><span className={`status-pill ${group.severity === "error" ? "failed" : "validation_failed"}`}>{group.error_code}</span><span>{group.total} fila{group.total === 1 ? "" : "s"} · {group.pending} pendiente{group.pending === 1 ? "" : "s"}</span>{group.severity === "warning" && group.pending > 0 && <button className="text-button" onClick={() => onAcknowledge(group.error_code)}>Reconocer</button>}</div>)}</div>}
    <div className="table-wrap">{batch.import_type === "products" ? <table><thead><tr><th>Fila</th><th>SKU de origen</th><th>Nombre</th><th>Unidad</th><th>Clase</th><th>Fiscal</th><th>Estado</th></tr></thead><tbody>{rows.map((row) => <StagingProductRow row={row} key={row.id} />)}</tbody></table> : batch.import_type === "inventory" ? <table><thead><tr><th>Fila</th><th>SKU de origen</th><th>Producto</th><th>Ubicación</th><th>Existencia</th><th>Unidad</th><th>Estado</th><th></th></tr></thead><tbody>{rows.map((row) => <StagingInventoryRow row={row} onResolve={onResolve} key={row.id} />)}</tbody></table> : <table><thead><tr><th>Fila</th><th>SKU de origen</th><th>Producto</th><th>{batch.import_type === "prices" ? "Lista" : "Tipo"}</th><th>{batch.import_type === "prices" ? "Precio" : "Costo"}</th><th>Moneda</th><th>Estado</th></tr></thead><tbody>{rows.map((row) => <StagingCommercialRow row={row} kind={batch.import_type as "prices" | "costs"} key={row.id} />)}</tbody></table>}</div>
    {rows.length === 0 && <div className="empty-state"><PackageSearch size={18} /> No hay filas para los filtros seleccionados.</div>}</div>;
}

function StagingCommercialRow({ row, kind }: { row: StagedRow; kind: "prices" | "costs" }) {
  const amount = Number(row.normalized_data[kind === "prices" ? "amount" : "replacementCost"] ?? 0);
  return <tr className={row.validation_status === "error" ? "staging-rejected-row" : ""}><td>{row.normalized_data.sourceRowNumber ? Number(row.normalized_data.sourceRowNumber) : row.row_number}</td><td className="mono">{textValue(row.normalized_data, "alphaSku") || "—"}</td><td>{textValue(row.normalized_data, "description") || "—"}{row.validation_status === "error" && <RawRowDetails row={row} />}</td><td>{kind === "prices" ? textValue(row.normalized_data, "listExternalCode") : "Reposición"}</td><td>{Number.isFinite(amount) ? numberFormat(amount) : "—"}</td><td>{textValue(row.normalized_data, "currencyCode") || textValue(row.normalized_data, "currencyLabel") || "—"}</td><td>{validationLabel(row.validation_status)}</td></tr>;
}

function CommercialReview({ requirements, busy, onAction }: { requirements: NonNullable<StagingPreviewData["commercial_requirements"]>; busy: boolean; onAction: (body: Record<string, unknown>) => Promise<void> }) {
  return <section className="location-review"><div><span className="eyebrow">Configuración comercial</span><h2>Confirma la interpretación de los datos importados</h2><p>Sin segmento de cliente, la empresa usará el mayor precio vigente por producto. La lista predeterminada solo mantiene una referencia administrativa; esta regla se puede cambiar después.</p></div><div className="location-review-list">{requirements.currencies.map((currency) => <div className="location-review-row" key={currency.source_label}><span><strong>{currency.source_label}</strong><small>{currency.rows} filas · {currency.currency_code ?? "sin mapear"}</small></span>{!currency.currency_code && <button className="secondary-button" disabled={busy} onClick={() => void onAction({ action: "map_currency", sourceLabel: currency.source_label, currencyCode: "MXN" })}>Confirmar como MXN</button>}</div>)}{requirements.price_lists.map((list) => <PriceListReview key={list.external_code} list={list} busy={busy} onAction={onAction} />)}</div></section>;
}

function PriceListReview({ list, busy, onAction }: { list: NonNullable<StagingPreviewData["commercial_requirements"]>["price_lists"][number]; busy: boolean; onAction: (body: Record<string, unknown>) => Promise<void> }) {
  const [semanticCode, setSemanticCode] = useState(list.semantic_code ?? ""); const [isDefault, setIsDefault] = useState(list.is_default);
  return <div className="location-review-row"><span><strong>{list.external_code}</strong><small>{list.rows} precios</small></span><Select ariaLabel={`Segmento para ${list.external_code}`} value={semanticCode || "unselected"} onValueChange={(value) => setSemanticCode(value === "unselected" ? "" : value)} options={[{ value: "unselected", label: "Seleccionar segmento", disabled: true }, { value: "primera", label: "Primera" }, { value: "segunda", label: "Segunda" }, { value: "tercera", label: "Tercera" }, { value: "top", label: "Top" }]} /><label className="checkbox-label"><input type="checkbox" checked={isDefault} onChange={(event) => setIsDefault(event.target.checked)} /> Predeterminada</label><button className="secondary-button" disabled={busy || !semanticCode} onClick={() => void onAction({ action: "map_price_list", externalCode: list.external_code, semanticCode, isDefault })}>Guardar</button></div>;
}

function StagingProductRow({ row }: { row: StagedRow }) {
  const taxCategory = textValue(row.normalized_data, "taxCategoryCode");
  return <tr className={row.validation_status === "error" ? "staging-rejected-row" : ""}><td>{row.row_number}</td><td className="mono">{textValue(row.normalized_data, "alphaSku") || "—"}</td><td>{textValue(row.normalized_data, "name") || "—"}{row.validation_status === "error" && <RawRowDetails row={row} />}</td><td>{textValue(row.normalized_data, "unit") || "—"}</td><td>{textValue(row.normalized_data, "alphaClass") || "—"}</td><td>{taxCategory === "IVA16" ? "IVA 16%" : taxCategory === "IVA0" ? "IVA tasa 0%" : "—"}</td><td>{validationLabel(row.validation_status)}</td></tr>;
}

function StagingInventoryRow({ row, onResolve }: { row: StagedRow; onResolve: (row: StagedRow) => void }) {
  const missingProduct = row.issues.some((issue) => issue.error_code === "PRODUCTO_INEXISTENTE" && !issue.resolved_at);
  return <tr className={row.validation_status === "error" ? "staging-rejected-row" : ""}><td>{row.row_number}</td><td className="mono">{textValue(row.normalized_data, "alphaSku") || "—"}</td><td>{textValue(row.normalized_data, "description") || "—"}{row.resolved_product_id && <small>Mapeo controlado registrado</small>}{row.validation_status === "error" && <RawRowDetails row={row} />}</td><td><span className="location-chip">{textValue(row.normalized_data, "locationCode") || "—"}</span> {textValue(row.normalized_data, "locationName")}</td><td>{numberFormat(Number(row.normalized_data.quantity ?? 0))}</td><td>{textValue(row.normalized_data, "unit") || "—"}</td><td>{validationLabel(row.validation_status)}</td><td>{missingProduct && <button className="text-button" onClick={() => onResolve(row)}>Resolver</button>}</td></tr>;
}

function RawRowDetails({ row }: { row: StagedRow }) {
  return <details className="raw-row-details"><summary>Datos originales</summary><p>{row.issues.map((issue) => presentImportedSourceText(issue.message)).join(" · ")}</p><code>{JSON.stringify(row.raw_data.cells ?? [])}</code></details>;
}

function LocationReview({ locations, onReview }: { locations: Array<{ externalCode: string; name: string }>; onReview: (externalCode: string, locationType: LocationType) => void }) {
  return <section className="location-review" aria-labelledby="location-review-title"><div><span className="eyebrow">Revisión requerida</span><h2 id="location-review-title">Clasifica las ubicaciones nuevas</h2><p>La selección se guarda en staging antes de permitir la importación.</p></div><div className="location-review-list">{locations.map((location) => <LocationTypeSelect location={location} onReview={onReview} key={location.externalCode} />)}</div></section>;
}

function LocationTypeSelect({ location, onReview }: { location: { externalCode: string; name: string }; onReview: (externalCode: string, locationType: LocationType) => void }) {
  const [value, setValue] = useState("unselected");
  return <div className="location-review-row"><span><strong>{location.externalCode}</strong><small>{location.name}</small></span><Select ariaLabel={`Clasificar ${location.externalCode}`} value={value} onValueChange={(next) => { setValue(next); if (next !== "unselected") void onReview(location.externalCode, next as LocationType); }} options={[{ value: "unselected", label: "Seleccionar tipo", disabled: true }, { value: "sucursal", label: "Sucursal" }, { value: "almacen_central", label: "Almacén central" }, { value: "almacen_operativo", label: "Almacén operativo" }, { value: "campo", label: "Campo / asignado a ingeniero" }]} /></div>;
}

function ConfirmDialog({ companyId, batch, busy, onCancel, onConfirm }: { companyId: string; batch: StagedBatch; busy: boolean; onCancel: () => void; onConfirm: (assortmentIds: string[]) => void }) {
  const [acknowledged, setAcknowledged] = useState(false);
  const [assortments, setAssortments] = useState<Array<{id:string;code:string;name:string;status:string;location_ids:string[]}>>([]);
  const [selectedAssortmentIds, setSelectedAssortmentIds] = useState<string[]>([]);
  const [assortmentsLoading, setAssortmentsLoading] = useState(batch.import_type === "products");
  useEffect(() => {
    if (batch.import_type !== "products") return;
    let active = true;
    void getSupabaseClient().rpc("get_sales_assortment_admin_context", { p_company_id: companyId }).then(({ data, error }) => {
      if (!active) return;
      const context = data as {assortments?:Array<{id:string;code:string;name:string;status:string;location_ids:string[]}>}|null;
      setAssortments(error ? [] : (context?.assortments ?? []).filter((assortment) => assortment.status !== "inactive"));
      setAssortmentsLoading(false);
    });
    return () => { active = false; };
  }, [batch.import_type, companyId]);
  const label = batch.import_type === "products" ? "catálogo de productos" : batch.import_type === "inventory" ? "inventario por ubicación" : batch.import_type === "prices" ? "listas de precios" : "costos de reposición";
  const toggleAssortment = (id:string) => setSelectedAssortmentIds((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current,id]);
  return <Modal open onOpenChange={(open) => { if (!open && !busy) onCancel(); }} eyebrow="Confirmación requerida" title={`Aplicar ${label}`} description="La base de datos aplicará este staging en una única transacción. Si algo falla, no quedarán datos parciales." footer={<><Button variant="secondary" disabled={busy} onClick={onCancel}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!acknowledged||assortmentsLoading} onClick={()=>onConfirm(selectedAssortmentIds)}>Confirmar y registrar</Button></>}>
    {batch.import_type==="products"&&<section className="import-assortment-selector"><div><strong>Surtido de destino</strong><p>Selecciona uno o varios destinos para todo el lote. Sin selección, los productos se importarán fuera de surtido para revisión.</p></div>{assortmentsLoading?<small>Cargando surtidos…</small>:assortments.length?<div>{assortments.map((assortment)=><label key={assortment.id}><input type="checkbox" checked={selectedAssortmentIds.includes(assortment.id)} onChange={()=>toggleAssortment(assortment.id)}/><span><strong>{assortment.name}</strong><small>{assortment.code} · {assortment.location_ids.length} sucursal{assortment.location_ids.length===1?"":"es"}</small></span></label>)}</div>:<small>No hay surtidos disponibles; el catálogo quedará fuera de surtido.</small>}</section>}
    <label className="checkbox-label"><input type="checkbox" checked={acknowledged} disabled={busy} onChange={(event) => setAcknowledged(event.target.checked)} /> Confirmo que revisé el preview persistente y deseo continuar.</label>
  </Modal>;
}

function StagingOperationDialog({ operation, companyId, busy, onCancel, onConfirm }: { operation: OperationDialog; companyId: string; busy: boolean; onCancel: () => void; onConfirm: (payload: { productId?: string; reason: string }) => void }) {
  const [reason, setReason] = useState("");
  const [search, setSearch] = useState("");
  const [products, setProducts] = useState<Array<{ id: string; alpha_sku: string; name: string }>>([]);
  const [productId, setProductId] = useState("");
  const [searching, setSearching] = useState(false);
  async function searchProducts() {
    const safe = search.trim().replace(/[,().%_*]/g, " ");
    if (safe.length < 2) return;
    setSearching(true);
    const { data } = await getSupabaseClient().from("products").select("id, alpha_sku, name")
      .eq("company_id", companyId).eq("is_active", true)
      .or(`alpha_sku.ilike.%${safe}%,name.ilike.%${safe}%`).order("name").limit(30);
    setProducts((data ?? []) as Array<{ id: string; alpha_sku: string; name: string }>); setSearching(false);
  }
  const title = operation.kind === "product" ? "Mapear a un producto existente" : operation.kind === "warning" ? `Reconocer ${operation.code}` : operation.kind === "discard" ? "Descartar lote" : "Reintentar lote fallido";
  const description = operation.kind === "product" ? `El SKU de origen ${textValue(operation.row.normalized_data, "alphaSku") || "sin clave"} quedará conservado permanentemente.` : operation.kind === "warning" ? "Este reconocimiento se aplicará a todas las filas pendientes de este tipo y quedará auditado." : operation.kind === "discard" ? "El lote se cerrará sin importar datos. Su resumen, hash y auditoría se conservarán." : "Se creará un lote nuevo usando el staging conservado. El lote fallido seguirá en auditoría.";
  const canSubmit = reason.trim().length > 0 && (operation.kind !== "product" || Boolean(productId));
  return <Modal open onOpenChange={(open) => { if (!open && !busy) onCancel(); }} eyebrow="Operación controlada" title={title} description={description} footer={<><Button variant="secondary" disabled={busy} onClick={onCancel}>Cancelar</Button><Button variant={operation.kind === "discard" ? "danger" : "primary"} loading={busy} disabled={!canSubmit} onClick={() => onConfirm({ productId: productId || undefined, reason: reason.trim() })}>{operation.kind === "discard" ? "Descartar lote" : "Guardar y auditar"}</Button></>}>
    {operation.kind === "product" && <div className="product-resolution-search"><label>Buscar producto activo<input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="SKU o nombre" /></label><Button variant="secondary" size="sm" disabled={searching || search.trim().length < 2} loading={searching} onClick={() => void searchProducts()}>Buscar</Button><label>Producto seleccionado<Select ariaLabel="Producto seleccionado" value={productId || "unselected"} onValueChange={(value) => setProductId(value === "unselected" ? "" : value)} options={[{ value: "unselected", label: "Seleccionar producto", disabled: true }, ...products.map((product) => ({ value: product.id, label: `${product.alpha_sku} · ${product.name}` }))]} /></label></div>}
    <label className="operation-reason">Motivo<textarea value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Escribe el motivo para la auditoría" rows={3} /></label>
  </Modal>;
}

function InventoryView({ companyId }: { companyId: string }) {
  const { accessibleLocations, queryCache } = useSatrapy();
  const [rows, setRows] = useState<InventoryProductRow[]>([]);
  const [expandedProducts, setExpandedProducts] = useState<Set<string>>(() => new Set());
  const [referenceRow, setReferenceRow] = useState<InventoryRow | null>(null);
  const [referenceLoading, setReferenceLoading] = useState(false);
  const [referenceError, setReferenceError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [debouncedSearch, setDebouncedSearch] = useState("");
  const [selectedLocation, setSelectedLocation] = useState("all");
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const requestId = useRef(0);
  useEffect(() => { const timer = window.setTimeout(() => { setDebouncedSearch(search.trim()); setPage(1); }, 280); return () => window.clearTimeout(timer); }, [search]);
  const load = useCallback(async () => {
    const cacheKey = `inventory:${companyId}:${debouncedSearch}:${selectedLocation}:${page}`;
    const cached = queryCache.get<{ rows: InventoryProductRow[]; total: number }>(cacheKey);
    if (cached) {
      setRows(cached.rows); setTotal(cached.total); setLoading(false); setError(null);
      return;
    }
    const current = ++requestId.current;
    setLoading(true); setError(null);
    const { data, error: queryError } = await getSupabaseClient().rpc("search_inventory_products_by_location", {
      p_company_id: companyId,
      p_location_id: selectedLocation === "all" ? null : selectedLocation,
      p_query: debouncedSearch || null,
      p_page: page,
      p_page_size: DATA_PAGE_SIZE,
    });
    if (current !== requestId.current) return;
    const result = data as { items?: InventoryProductRow[]; total?: number } | null;
    const next = { rows: result?.items ?? [], total: result?.total ?? 0 };
    setRows(next.rows); setTotal(next.total); setError(queryError ? "No se pudo cargar el inventario." : null); setLoading(false);
    if (!queryError) queryCache.set(cacheKey, next);
  }, [companyId, debouncedSearch, page, queryCache, selectedLocation]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  function changeSearch(value: string) { setSearch(value); }
  function changeLocation(value: string) { setPage(1); setExpandedProducts(new Set()); setSelectedLocation(value); }
  function clearFilters() { setSearch(""); setDebouncedSearch(""); setSelectedLocation("all"); setExpandedProducts(new Set()); setPage(1); }
  const empty = search ? "No hay existencias para esa búsqueda." : selectedLocation !== "all" ? "No hay existencias operativas para la ubicación seleccionada." : "Aún no hay existencias operativas inicializadas.";
  const locationOptions = [{ value: "all", label: "Todas las ubicaciones" }, ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))];
  function refresh() { queryCache.invalidate(`inventory:${companyId}:`); void load(); }
  function toggleProduct(productId: string) {
    setExpandedProducts((current) => {
      const next = new Set(current);
      if (next.has(productId)) next.delete(productId); else next.add(productId);
      return next;
    });
  }
  async function openSnapshotReference(row: InventoryRow) {
    setReferenceRow(row); setReferenceError(null);
    if (row.snapshot_quantity != null) return;
    setReferenceLoading(true);
    const { data, error: queryError } = await getSupabaseClient().rpc("get_inventory_snapshot_reference", {
      p_company_id: companyId,
      p_location_id: row.location_id,
      p_product_id: row.product_id,
    });
    const reference = data as { available?: boolean; snapshot_quantity?: number; snapshot_date?: string | null; snapshot_source_file?: string | null; difference_from_snapshot?: number | null } | null;
    if (queryError || !reference?.available) setReferenceError(queryError ? "No se pudo consultar el corte importado." : "Ya no existe una referencia importada para este producto.");
    else setReferenceRow((current) => current ? { ...current, snapshot_quantity: Number(reference.snapshot_quantity), snapshot_date: reference.snapshot_date ?? null, snapshot_source_file: reference.snapshot_source_file ?? null, difference_from_snapshot: reference.difference_from_snapshot ?? null } : current);
    setReferenceLoading(false);
  }
  return <div className="content-frame inventory-product-inquiry"><PageHeading eyebrow="Existencia operativa" title="Inventario por ubicación" description="Consulta cada producto con su existencia total y despliega el saldo de cada sucursal." action={<Button variant="secondary" onClick={refresh}><RefreshCw size={16} /> Actualizar</Button>} /><DataToolbar search={search} onSearchChange={changeSearch} placeholder="Buscar producto o SKU" filters={<Select value={selectedLocation} onValueChange={changeLocation} ariaLabel="Filtrar por ubicación" options={locationOptions} />} activeFilters={(search.trim() ? 1 : 0) + (selectedLocation !== "all" ? 1 : 0)} onClear={clearFilters} results={total} /><DataState loading={loading && rows.length === 0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={refresh}>Reintentar</Button>} hasData={rows.length} empty={empty}><div className="table-wrap surface-table inventory-product-table"><table><thead><tr><th>SKU</th><th>Producto</th><th className="number-cell">Existencia total</th><th>Sucursales</th><th>Actualización</th><th aria-label="Acciones" /></tr></thead><tbody>{rows.map((product) => {
    const expanded = expandedProducts.has(product.product_id);
    return <Fragment key={product.product_id}><tr className="inventory-product-row"><td className="mono">{product.product_code}</td><td><strong>{product.product_name}</strong><small>{product.unit ?? "Sin unidad"}</small></td><td className="number-cell"><strong>{numberFormat(Number(product.total_quantity_on_hand))} {product.unit ?? ""}</strong></td><td><strong>{product.location_count} {product.location_count === 1 ? "sucursal" : "sucursales"}</strong><small>{product.positive_location_count} con existencia</small></td><td>{product.balance_updated_at ? dateTimeFormat(product.balance_updated_at) : "Sin movimientos"}</td><td><Button variant="secondary" size="sm" aria-expanded={expanded} onClick={() => toggleProduct(product.product_id)}>{expanded ? "Ocultar" : "Ver sucursales"}</Button></td></tr>{expanded && <tr className="inventory-location-detail-row"><td colSpan={6}><div className="inventory-location-breakdown" aria-label={`Existencias por sucursal de ${product.product_name}`}>{product.locations.map((location) => <article key={location.location_id}><div><span className="location-chip">{location.location_code}</span><strong>{location.location_name}</strong></div><div className="inventory-location-balance"><strong>{numberFormat(Number(location.quantity_on_hand))} {product.unit ?? ""}</strong><small>{location.balance_updated_at ? `Actualizado ${dateTimeFormat(location.balance_updated_at)}` : "Sin saldo inicializado"}</small></div><div><strong>{location.last_movement_type ? inventoryMovementLabel(location.last_movement_type) : "Sin movimientos"}</strong><small>{location.last_movement_at ? dateTimeFormat(location.last_movement_at) : "—"}</small></div><div>{location.has_snapshot_reference ? <Button variant="secondary" size="sm" onClick={() => void openSnapshotReference(location)}>Ver corte importado</Button> : <span className="inventory-no-reference">Sin referencia</span>}</div></article>)}</div></td></tr>}</Fragment>;
  })}</tbody></table></div></DataState><DataPagination page={page} total={total} pageSize={DATA_PAGE_SIZE} onChange={setPage} />
    <Modal open={Boolean(referenceRow)} onOpenChange={(open) => { if (!open) { setReferenceRow(null); setReferenceLoading(false); setReferenceError(null); } }} eyebrow="Referencia histórica" title={referenceRow ? referenceRow.product_name : "Corte importado"} description="Este corte fue el punto de referencia importado. No reemplaza la existencia actual ni registra un conteo físico.">{referenceLoading ? <div className="loading-copy" role="status"><LoaderCircle className="spin" size={18} /> Consultando corte importado…</div> : referenceError ? <p className="form-error">{referenceError}</p> : referenceRow && <dl className="inventory-reference-summary"><div><dt>Ubicación</dt><dd>{referenceRow.location_code} · {referenceRow.location_name}</dd></div><div><dt>Cantidad importada</dt><dd>{numberFormat(Number(referenceRow.snapshot_quantity ?? 0))} {referenceRow.unit ?? ""}</dd></div><div><dt>Fecha del corte</dt><dd>{referenceRow.snapshot_date ? dateOnlyFormat(referenceRow.snapshot_date) : "Sin fecha"}</dd></div><div><dt>Archivo de origen</dt><dd>{referenceRow.snapshot_source_file ?? "No disponible"}</dd></div><div><dt>Cambio desde ese corte</dt><dd>{referenceRow.difference_from_snapshot == null ? "No calculable" : `${Number(referenceRow.difference_from_snapshot) > 0 ? "+" : ""}${numberFormat(Number(referenceRow.difference_from_snapshot))} ${referenceRow.unit ?? ""}`}</dd></div><div><dt>Existencia actual</dt><dd>{numberFormat(Number(referenceRow.quantity_on_hand))} {referenceRow.unit ?? ""}</dd></div></dl>}</Modal>
  </div>;
}

type InventoryReplenishmentRow = {
  policy_id: string;
  location_id: string;
  location_code: string;
  location_name: string;
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  quantity_on_hand: number;
  minimum_quantity: number;
  maximum_quantity: number;
  is_below_minimum: boolean;
  shortage_quantity: number;
  suggested_quantity: number;
  updated_at: string;
};
type InventoryReplenishmentProduct = {
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  product_group: string | null;
  quantity_on_hand: number;
  minimum_quantity: number | null;
  maximum_quantity: number | null;
  has_policy: boolean;
};
type InventoryReplenishmentDraftLine = InventoryReplenishmentProduct & {
  minimum: string;
  maximum: string;
};

function parseReplenishmentBatch(value: string): { lines?: Array<{ product_code: string; minimum_quantity: number; maximum_quantity: number }>; error?: string } {
  const rows = value.split(/\r?\n/).map((row) => row.trim()).filter(Boolean);
  if (!rows.length) return { error: "Pega al menos un SKU con mínimo y máximo." };
  if (rows.length > 500) return { error: "El lote no puede exceder 500 partidas." };
  const codes = new Set<string>();
  const lines: Array<{ product_code: string; minimum_quantity: number; maximum_quantity: number }> = [];
  for (const row of rows) {
    const fields = row.split(/[;,\t]/).map((field) => field.trim());
    if (fields.length !== 3 || !fields[0]) return { error: "Usa una línea por política: SKU,mínimo,máximo." };
    const minimumQuantity = Number(fields[1]);
    const maximumQuantity = Number(fields[2]);
    const key = fields[0].toLocaleLowerCase("es-MX");
    if (!Number.isFinite(minimumQuantity) || minimumQuantity <= 0 || !Number.isFinite(maximumQuantity) || maximumQuantity < minimumQuantity) {
      return { error: `Los límites de ${fields[0]} deben ser válidos: mínimo mayor a cero y máximo mayor o igual.` };
    }
    if (codes.has(key)) return { error: `El SKU ${fields[0]} está repetido.` };
    codes.add(key); lines.push({ product_code: fields[0], minimum_quantity: minimumQuantity, maximum_quantity: maximumQuantity });
  }
  return { lines };
}

function InventoryReplenishmentView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { accessibleLocations } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const [rows, setRows] = useState<InventoryReplenishmentRow[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [debouncedSearch, setDebouncedSearch] = useState("");
  const [locationFilter, setLocationFilter] = useState("all");
  const [belowMinimumOnly, setBelowMinimumOnly] = useState(true);
  const [policyLocationId, setPolicyLocationId] = useState("");
  const [draftLines, setDraftLines] = useState<InventoryReplenishmentDraftLine[]>([]);
  const [productQuery, setProductQuery] = useState("");
  const [productResults, setProductResults] = useState<InventoryReplenishmentProduct[]>([]);
  const [selectedProductIds, setSelectedProductIds] = useState<Set<string>>(new Set());
  const [productSearching, setProductSearching] = useState(false);
  const [productPickerOpen, setProductPickerOpen] = useState(false);
  const [bulkMinimum, setBulkMinimum] = useState("");
  const [bulkMaximum, setBulkMaximum] = useState("");
  const [bulkImportOpen, setBulkImportOpen] = useState(false);
  const [batch, setBatch] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const productRequestId = useRef(0);
  const productPickerRef = useRef<HTMLLabelElement>(null);
  const canManage = permissions.includes("manage_inventory_replenishment");
  const locationOptions = [{ value: "all", label: "Todas las ubicaciones" }, ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))];

  useEffect(() => { const timer = window.setTimeout(() => { setDebouncedSearch(search.trim()); setPage(1); }, 280); return () => window.clearTimeout(timer); }, [search]);
  const load = useCallback(async () => {
    setLoading(true); setError(null);
    const { data, error: queryError } = await getSupabaseClient().rpc("list_inventory_replenishment_suggestions", {
      p_company_id: companyId,
      p_location_id: locationFilter === "all" ? null : locationFilter,
      p_query: debouncedSearch || null,
      p_below_minimum_only: belowMinimumOnly,
      p_page: page,
      p_page_size: DATA_PAGE_SIZE,
    });
    const result = data as { items?: InventoryReplenishmentRow[]; total?: number } | null;
    if (!queryError) { setRows(result?.items ?? []); setTotal(result?.total ?? 0); }
    if (queryError) setError("No se pudieron cargar las sugerencias de reabastecimiento.");
    setLoading(false);
  }, [belowMinimumOnly, companyId, debouncedSearch, locationFilter, page]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  useDismissiblePopover(productPickerRef, productPickerOpen, () => setProductPickerOpen(false));

  useEffect(() => {
    if (!policyLocationId) return;
    const timer = window.setTimeout(async () => {
      const current = ++productRequestId.current;
      setProductSearching(true);
      const { data, error: queryError } = await getSupabaseClient().rpc("search_inventory_replenishment_products", {
        p_company_id: companyId,
        p_location_id: policyLocationId,
        p_query: productQuery.trim() || null,
        p_page: 1,
        p_page_size: 50,
      });
      if (current !== productRequestId.current) return;
      const result = data as { items?: InventoryReplenishmentProduct[] } | null;
      setProductResults(queryError ? [] : (result?.items ?? []));
      setProductSearching(false);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [companyId, policyLocationId, productQuery]);

  function selectPolicyLocation(value: string) {
    productRequestId.current += 1;
    setPolicyLocationId(value === "unselected" ? "" : value);
    setProductQuery(""); setProductResults([]); setSelectedProductIds(new Set()); setProductPickerOpen(false);
  }

  function toggleProduct(productId: string) {
    setSelectedProductIds((current) => {
      const next = new Set(current);
      if (next.has(productId)) next.delete(productId); else next.add(productId);
      return next;
    });
  }

  function selectVisibleProducts() {
    const available = productResults.filter((product) => !draftLines.some((line) => line.product_id === product.product_id));
    const remaining = Math.max(500 - draftLines.length, 0);
    setSelectedProductIds(new Set(available.slice(0, remaining).map((product) => product.product_id)));
  }

  function addSelectedProducts() {
    const selected = productResults.filter((product) => selectedProductIds.has(product.product_id));
    const additions = selected.filter((product) => !draftLines.some((line) => line.product_id === product.product_id));
    setDraftLines((current) => [...current, ...additions.slice(0, Math.max(500 - current.length, 0)).map((product) => ({
      ...product,
      minimum: product.minimum_quantity == null ? "" : String(product.minimum_quantity),
      maximum: product.maximum_quantity == null ? "" : String(product.maximum_quantity),
    }))]);
    setSelectedProductIds(new Set()); setProductQuery(""); setProductPickerOpen(false);
  }

  function updateDraftPolicy(productId: string, field: "minimum" | "maximum", value: string) {
    setDraftLines((current) => current.map((line) => line.product_id === productId ? { ...line, [field]: value } : line));
  }

  function applyBulkLimits() {
    const minimum = Number(bulkMinimum);
    const maximum = Number(bulkMaximum);
    if (!Number.isFinite(minimum) || minimum <= 0 || !Number.isFinite(maximum) || maximum < minimum) {
      toast({ title: "Límites no válidos", description: "El mínimo debe ser mayor que cero y el máximo debe ser igual o mayor.", tone: "error" }); return;
    }
    setDraftLines((current) => current.map((line) => ({ ...line, minimum: bulkMinimum, maximum: bulkMaximum })));
  }

  const invalidDraftLines = draftLines.filter((line) => {
    const minimum = Number(line.minimum);
    const maximum = Number(line.maximum);
    return !Number.isFinite(minimum) || minimum <= 0 || !Number.isFinite(maximum) || maximum < minimum;
  });

  async function savePolicyItems() {
    if (!policyLocationId || !draftLines.length || invalidDraftLines.length) {
      toast({ title: "Revisa las políticas", description: "Selecciona una ubicación y captura mínimos y máximos válidos.", tone: "error" }); return;
    }
    const items = draftLines.map((line) => ({ product_id: line.product_id, minimum_quantity: Number(line.minimum), maximum_quantity: Number(line.maximum) }));
    setBusy(true);
    const fingerprint = JSON.stringify({ companyId, locationId: policyLocationId, items });
    const { data, error: rpcError } = await getSupabaseClient().rpc("configure_inventory_replenishment_policy_items", {
      p_company_id: companyId,
      p_location_id: policyLocationId,
      p_lines: items,
      p_client_request_id: idempotency.get("inventory-replenishment-configure-items", fingerprint),
    });
    if (rpcError) toast({ title: "No se guardaron las políticas", description: inventoryRpcMessage(rpcError, "Revisa productos y límites."), tone: "error" });
    else {
      const result = data as { line_count: number };
      idempotency.clear("inventory-replenishment-configure-items");
      setDraftLines([]); setProductQuery(""); setProductResults([]); setBulkMinimum(""); setBulkMaximum("");
      setLocationFilter(policyLocationId); setBelowMinimumOnly(false); setPage(1);
      await load();
      toast({ title: "Políticas configuradas", description: `${result.line_count} políticas actualizadas. No se movió inventario ni se crearon órdenes.`, tone: "success" });
    }
    setBusy(false);
  }

  async function importPolicies() {
    const parsed = parseReplenishmentBatch(batch);
    if (parsed.error || !parsed.lines) { toast({ title: "Lote no válido", description: parsed.error ?? "Revisa las políticas.", tone: "error" }); return; }
    if (!policyLocationId) { toast({ title: "Selecciona una ubicación", description: "Los mínimos y máximos se configuran por ubicación.", tone: "info" }); return; }
    setBusy(true);
    const fingerprint = JSON.stringify({ companyId, locationId: policyLocationId, lines: parsed.lines });
    const { data, error: rpcError } = await getSupabaseClient().rpc("configure_inventory_replenishment_policies", {
      p_company_id: companyId,
      p_location_id: policyLocationId,
      p_lines: parsed.lines,
      p_client_request_id: idempotency.get("inventory-replenishment-configure", fingerprint),
    });
    if (rpcError) toast({ title: "No se configuraron las políticas", description: inventoryRpcMessage(rpcError, "Revisa SKU y límites."), tone: "error" });
    else {
      const result = data as { line_count: number };
      idempotency.clear("inventory-replenishment-configure");
      setBatch(""); setBulkImportOpen(false); setLocationFilter(policyLocationId); setBelowMinimumOnly(false); setPage(1);
      await load();
      toast({ title: "Políticas configuradas", description: `${result.line_count} políticas actualizadas. No se crearon órdenes ni se movió inventario.`, tone: "success" });
    }
    setBusy(false);
  }

  async function prepareRequisition() {
    if (locationFilter === "all") { toast({ title: "Selecciona una ubicación", description: "Las requisiciones se preparan para una ubicación destino.", tone: "info" }); return; }
    setBusy(true);
    const { data, error: rpcError } = await getSupabaseClient().rpc("generate_procurement_requisition_from_replenishment", { p_company_id: companyId, p_location_id: locationFilter, p_target_date: null, p_product_ids: null });
    setBusy(false);
    if (rpcError) { toast({ title: "No se preparó la requisición", description: inventoryRpcMessage(rpcError, "Revisa los faltantes disponibles."), tone: "error" }); return; }
    const result = data as { folio?: string; lines?: unknown[] };
    toast({ title: "Requisición preparada", description: `${result.folio ?? "La requisición"} reúne ${result.lines?.length ?? 0} faltantes y está lista para cotizar.`, tone: "success" });
    await load();
  }

  function clearFilters() { setSearch(""); setDebouncedSearch(""); setLocationFilter("all"); setBelowMinimumOnly(true); setPage(1); }
  const empty = belowMinimumOnly ? "No hay productos bajo su mínimo con los filtros actuales." : "No hay políticas de mínimos y máximos configuradas con los filtros actuales.";
  return <div className="content-frame inventory-replenishment"><PageHeading eyebrow="Planeación de inventario" title="Reabastecimiento" description="Las sugerencias se calculan sobre la existencia vigente y solo indican cuánto recuperar hasta el máximo. No crean órdenes de compra." action={<><Button variant="secondary" disabled={locationFilter === "all" || !rows.some((row) => row.is_below_minimum)} loading={busy} onClick={() => void prepareRequisition()}>Preparar requisición</Button><Button variant="secondary" loading={loading} onClick={() => void load()}><RefreshCw size={16} /> Actualizar</Button></>} />
    {canManage && <section className="inventory-transfer-builder inventory-replenishment-builder"><header><div><span className="eyebrow">Políticas de inventario</span><h2>Configurar mínimos y máximos</h2></div><Button variant="secondary" size="sm" disabled={!policyLocationId} onClick={() => setBulkImportOpen(true)}>Importar políticas</Button></header>
      <div className="inventory-transfer-route"><label>Ubicación<Select ariaLabel="Ubicación para configurar políticas" value={policyLocationId || "unselected"} onValueChange={selectPolicyLocation} options={[{ value: "unselected", label: "Selecciona ubicación", disabled: true }, ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))]} disabled={draftLines.length > 0} /></label></div>
      <label ref={productPickerRef} className="inventory-transfer-product-search">Agregar productos<Input role="combobox" aria-expanded={productPickerOpen} aria-controls="inventory-replenishment-product-options" aria-label="Buscar productos para reabastecimiento" value={productQuery} disabled={!policyLocationId || draftLines.length >= 500} onFocus={() => setProductPickerOpen(true)} onClick={() => setProductPickerOpen(true)} onChange={(event) => { setProductQuery(event.target.value); setProductPickerOpen(true); }} placeholder={policyLocationId ? "Buscar por producto, SKU, código o grupo" : "Selecciona primero la ubicación"} />{policyLocationId && productPickerOpen && <div id="inventory-replenishment-product-options" className="inventory-transfer-product-results inventory-replenishment-product-results" role="listbox">{productSearching ? <p>Buscando productos…</p> : productResults.length ? <><div className="inventory-replenishment-result-actions"><Button variant="ghost" size="sm" onClick={() => setProductPickerOpen(false)}>Cerrar</Button><Button variant="ghost" size="sm" onClick={selectVisibleProducts}>Seleccionar resultados</Button><Button variant="primary" size="sm" disabled={!selectedProductIds.size} onClick={addSelectedProducts}>Agregar seleccionados ({selectedProductIds.size})</Button></div>{productResults.map((product) => { const alreadyAdded = draftLines.some((line) => line.product_id === product.product_id); const selected = selectedProductIds.has(product.product_id); return <label className={alreadyAdded ? "is-disabled" : ""} key={product.product_id}><input type="checkbox" checked={selected || alreadyAdded} disabled={alreadyAdded} onChange={() => toggleProduct(product.product_id)} /><span><strong>{product.product_name}</strong><small>{product.product_code} · {product.unit ?? "Sin unidad"}{product.product_group ? ` · ${product.product_group}` : ""}</small></span><span><b>{numberFormat(Number(product.quantity_on_hand))}</b><small>{product.has_policy ? `Min ${numberFormat(Number(product.minimum_quantity))} · Max ${numberFormat(Number(product.maximum_quantity))}` : "Sin política"}</small></span></label>; })}</> : <p>No hay productos para esta búsqueda.</p>}</div>}</label>
      {draftLines.length ? <><div className="inventory-replenishment-bulk-limits"><label>Mínimo para todas<Input type="number" min="0.000001" step="0.000001" value={bulkMinimum} onChange={(event) => setBulkMinimum(event.target.value)} /></label><label>Máximo para todas<Input type="number" min="0.000001" step="0.000001" value={bulkMaximum} onChange={(event) => setBulkMaximum(event.target.value)} /></label><Button variant="secondary" disabled={!bulkMinimum || !bulkMaximum} onClick={applyBulkLimits}>Aplicar a todas</Button></div><div className="table-wrap inventory-transfer-draft-lines inventory-replenishment-draft-lines"><table><thead><tr><th>Producto</th><th className="number-cell">Existencia</th><th className="number-cell">Mínimo</th><th className="number-cell">Máximo</th><th aria-label="Acciones" /></tr></thead><tbody>{draftLines.map((line) => { const minimum = Number(line.minimum); const maximum = Number(line.maximum); const invalid = !Number.isFinite(minimum) || minimum <= 0 || !Number.isFinite(maximum) || maximum < minimum; return <tr key={line.product_id}><td><strong>{line.product_name}</strong><small>{line.product_code} · {line.unit ?? "Sin unidad"}</small></td><td className="number-cell">{numberFormat(Number(line.quantity_on_hand))}</td><td className="number-cell"><Input aria-label={`Mínimo de ${line.product_name}`} aria-invalid={invalid} type="number" min="0.000001" step="0.000001" value={line.minimum} onChange={(event) => updateDraftPolicy(line.product_id, "minimum", event.target.value)} /></td><td className="number-cell"><Input aria-label={`Máximo de ${line.product_name}`} aria-invalid={invalid} type="number" min="0.000001" step="0.000001" value={line.maximum} onChange={(event) => updateDraftPolicy(line.product_id, "maximum", event.target.value)} />{invalid && <small className="inventory-transfer-line-error">Revisa mínimo y máximo</small>}</td><td><Button variant="ghost" size="sm" onClick={() => setDraftLines((current) => current.filter((item) => item.product_id !== line.product_id))}>Quitar</Button></td></tr>; })}</tbody></table></div></> : <div className="inventory-transfer-builder-empty"><strong>Aún no hay productos</strong><span>Busca y selecciona varios productos para configurar sus políticas.</span></div>}
      <footer><span><strong>{draftLines.length}</strong> de 500 políticas{(!policyLocationId || !draftLines.length || invalidDraftLines.length > 0) && <small id="replenishment-policy-requirement" className="inventory-replenishment-requirement">{!policyLocationId ? "Selecciona una ubicación para habilitar el guardado." : !draftLines.length ? "Agrega al menos un producto para habilitar el guardado." : "Corrige los mínimos y máximos marcados antes de guardar."}</small>}</span><div>{draftLines.length > 0 && <Button variant="secondary" disabled={busy} onClick={() => { setDraftLines([]); setProductQuery(""); setSelectedProductIds(new Set()); }}>Limpiar</Button>}<Button variant="primary" loading={busy} aria-describedby={!policyLocationId || !draftLines.length || invalidDraftLines.length > 0 ? "replenishment-policy-requirement" : undefined} disabled={!policyLocationId || !draftLines.length || invalidDraftLines.length > 0} onClick={() => void savePolicyItems()}>Guardar políticas</Button></div></footer>
    </section>}
    <DataToolbar search={search} onSearchChange={setSearch} placeholder="Buscar producto o SKU" filters={<><Select value={locationFilter} onValueChange={(value) => { setLocationFilter(value); setPage(1); }} ariaLabel="Filtrar reabastecimiento por ubicación" options={locationOptions} /><Select value={belowMinimumOnly ? "below" : "all"} onValueChange={(value) => { setBelowMinimumOnly(value === "below"); setPage(1); }} ariaLabel="Mostrar políticas" options={[{ value: "below", label: "Solo bajo mínimo" }, { value: "all", label: "Todas las políticas" }]} /></>} activeFilters={(search.trim() ? 1 : 0) + (locationFilter !== "all" ? 1 : 0) + (belowMinimumOnly ? 0 : 1)} onClear={clearFilters} results={total} />
    <DataRefreshStatus loading={loading} hasData={rows.length} /><DataState loading={loading && rows.length === 0} error={error} errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>} hasData={rows.length} emptyTitle="No hay sugerencias de reabastecimiento." empty={empty}><div className="table-wrap surface-table"><table><thead><tr><th>Producto</th><th>Ubicación</th><th className="number-cell">Existencia</th><th className="number-cell">Mínimo</th><th className="number-cell">Máximo</th><th className="number-cell">Sugerido</th><th>Estado</th></tr></thead><tbody>{rows.map((row) => <tr key={row.policy_id}><td><strong>{row.product_name}</strong><small>{row.product_code} · {row.unit ?? "Sin unidad"}</small></td><td><span className="location-chip">{row.location_code}</span> {row.location_name}</td><td className="number-cell">{numberFormat(Number(row.quantity_on_hand))}</td><td className="number-cell">{numberFormat(Number(row.minimum_quantity))}</td><td className="number-cell">{numberFormat(Number(row.maximum_quantity))}</td><td className="number-cell"><strong>{row.is_below_minimum ? numberFormat(Number(row.suggested_quantity)) : "—"}</strong>{row.is_below_minimum && <small>Faltan {numberFormat(Number(row.shortage_quantity))} al mínimo</small>}</td><td><Badge tone={row.is_below_minimum ? "warning" : "success"}>{row.is_below_minimum ? "Reabastecer" : "En rango"}</Badge></td></tr>)}</tbody></table></div></DataState><DataPagination page={page} total={total} pageSize={DATA_PAGE_SIZE} onChange={setPage} />
    <Modal open={bulkImportOpen} onOpenChange={(open) => !busy && setBulkImportOpen(open)} eyebrow="Carga secundaria" title="Importar políticas por SKU" description="Úsalo para pegar datos preparados en Excel. Para operación diaria utiliza la selección visual." footer={<><Button variant="secondary" disabled={busy} onClick={() => setBulkImportOpen(false)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!policyLocationId || !batch.trim()} onClick={() => void importPolicies()}>Importar y guardar</Button></>}><label className="operation-reason">Una política por renglón: SKU,mínimo,máximo<textarea value={batch} onChange={(event) => setBatch(event.target.value)} rows={7} placeholder={"FERT-001,10,30\nRIEGO-020,5,15"} /></label><small>Se validarán entre 1 y 500 SKU distintos antes de guardar.</small></Modal>
  </div>;
}

type InventoryTransferStatus = "sent" | "in_transit" | "received";
type InventoryTransferSummary = {
  id: string;
  source_location_id: string;
  source_location_code: string;
  source_location_name: string;
  destination_location_id: string;
  destination_location_code: string;
  destination_location_name: string;
  status: InventoryTransferStatus;
  line_count: number;
  sent_at: string;
  in_transit_at: string | null;
  received_at: string | null;
  sent_by_name: string | null;
  transited_by_name: string | null;
  received_by_name: string | null;
};
type InventoryTransferLine = {
  id: string;
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  quantity: number;
  dispatched: boolean;
  received: boolean;
};
type InventoryTransferDraftLine = {
  product_id: string;
  product_code: string;
  product_name: string;
  unit: string | null;
  available_quantity: number;
  quantity: string;
};

function parseTransferBatch(value: string): { lines?: Array<{ product_code: string; quantity: number }>; error?: string } {
  const rows = value.split(/\r?\n/).map((row) => row.trim()).filter(Boolean);
  if (!rows.length) return { error: "Pega al menos un SKU y una cantidad." };
  if (rows.length > 500) return { error: "El lote no puede exceder 500 partidas." };
  const codes = new Set<string>();
  const lines: Array<{ product_code: string; quantity: number }> = [];
  for (const row of rows) {
    const fields = row.split(/[;,\t]/).map((field) => field.trim());
    if (fields.length !== 2 || !fields[0]) return { error: "Usa una línea por partida: SKU,cantidad." };
    const quantity = Number(fields[1]);
    const key = fields[0].toLocaleLowerCase("es-MX");
    if (!Number.isFinite(quantity) || quantity <= 0) return { error: `La cantidad de ${fields[0]} debe ser mayor que cero.` };
    if (codes.has(key)) return { error: `El SKU ${fields[0]} está repetido.` };
    codes.add(key); lines.push({ product_code: fields[0], quantity });
  }
  return { lines };
}

function InventoryTransfersView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { accessibleLocations } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const [transfers, setTransfers] = useState<InventoryTransferSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [statusFilter, setStatusFilter] = useState("all");
  const [sourceLocationId, setSourceLocationId] = useState("");
  const [destinationLocationId, setDestinationLocationId] = useState("");
  const [draftLines, setDraftLines] = useState<InventoryTransferDraftLine[]>([]);
  const [productQuery, setProductQuery] = useState("");
  const [productResults, setProductResults] = useState<InventoryRow[]>([]);
  const [productSearching, setProductSearching] = useState(false);
  const [productPickerOpen, setProductPickerOpen] = useState(false);
  const [bulkImportOpen, setBulkImportOpen] = useState(false);
  const [batch, setBatch] = useState("");
  const [selectedTransferId, setSelectedTransferId] = useState<string | null>(null);
  const [lines, setLines] = useState<InventoryTransferLine[]>([]);
  const [lineTotal, setLineTotal] = useState(0);
  const [linePage, setLinePage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [lineLoading, setLineLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const productRequestId = useRef(0);
  const productPickerRef = useRef<HTMLLabelElement>(null);
  const canOperate = permissions.includes("operate_inventory");
  const selectedTransfer = transfers.find((transfer) => transfer.id === selectedTransferId) ?? null;
  const locationOptions = accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }));
  const sourceAccessible = selectedTransfer ? accessibleLocations.some((location) => location.id === selectedTransfer.source_location_id) : false;
  const destinationAccessible = selectedTransfer ? accessibleLocations.some((location) => location.id === selectedTransfer.destination_location_id) : false;

  const loadTransfers = useCallback(async () => {
    setLoading(true); setError(null);
    const { data, error: queryError } = await getSupabaseClient().rpc("list_inventory_transfers", {
      p_company_id: companyId,
      p_status: statusFilter === "all" ? null : statusFilter,
      p_page: page,
      p_page_size: 25,
    });
    const result = data as { items?: InventoryTransferSummary[]; total?: number } | null;
    setTransfers(result?.items ?? []); setTotal(result?.total ?? 0);
    if (queryError) setError(inventoryRpcMessage(queryError, "No se pudieron cargar las transferencias."));
    setLoading(false);
  }, [companyId, page, statusFilter]);

  const loadLines = useCallback(async () => {
    if (!selectedTransferId) { setLines([]); setLineTotal(0); return; }
    setLineLoading(true);
    const { data, error: queryError } = await getSupabaseClient().rpc("list_inventory_transfer_lines", {
      p_inventory_transfer_id: selectedTransferId,
      p_page: linePage,
      p_page_size: DATA_PAGE_SIZE,
    });
    const result = data as { items?: InventoryTransferLine[]; total?: number } | null;
    setLines(result?.items ?? []); setLineTotal(result?.total ?? 0);
    if (queryError) toast({ title: "No se cargaron las partidas", description: inventoryRpcMessage(queryError, "Intenta nuevamente."), tone: "error" });
    setLineLoading(false);
  }, [linePage, selectedTransferId, toast]);

  useEffect(() => { void Promise.resolve().then(loadTransfers); }, [loadTransfers]);
  useEffect(() => { void Promise.resolve().then(loadLines); }, [loadLines]);
  useDismissiblePopover(productPickerRef, productPickerOpen, () => setProductPickerOpen(false));

  useEffect(() => {
    const query = productQuery.trim();
    if (!sourceLocationId || query.length < 2) return;
    const timer = window.setTimeout(async () => {
      const current = ++productRequestId.current;
      setProductSearching(true);
      let { data, error: queryError } = await getSupabaseClient().rpc("search_inventory_transfer_products", {
        p_company_id: companyId,
        p_source_location_id: sourceLocationId,
        p_query: query,
        p_limit: 25,
      });
      if (queryError) {
        const fallback = await getSupabaseClient().rpc("search_inventory_balances", {
          p_company_id: companyId,
          p_location_id: sourceLocationId,
          p_query: query,
          p_page: 1,
          p_page_size: 25,
        });
        data = fallback.data;
        queryError = fallback.error;
      }
      if (current !== productRequestId.current) return;
      const result = data as { items?: InventoryRow[] } | null;
      setProductResults(queryError ? [] : (result?.items ?? []).filter((item) => Number(item.quantity_on_hand) > 0));
      setProductSearching(false);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [companyId, productQuery, sourceLocationId]);

  function selectSource(value: string) {
    productRequestId.current += 1;
    setSourceLocationId(value === "unselected-source" ? "" : value);
    setProductQuery(""); setProductResults([]); setProductSearching(false); setProductPickerOpen(false);
  }

  function changeProductQuery(value: string) {
    productRequestId.current += 1;
    setProductQuery(value);
    setProductPickerOpen(value.trim().length >= 2);
    if (value.trim().length < 2) {
      setProductResults([]); setProductSearching(false);
    }
  }

  function addDraftLine(product: InventoryRow) {
    if (draftLines.some((line) => line.product_id === product.product_id)) return;
    setDraftLines((current) => [...current, {
      product_id: product.product_id,
      product_code: product.product_code,
      product_name: product.product_name,
      unit: product.unit,
      available_quantity: Number(product.quantity_on_hand),
      quantity: "1",
    }]);
    setProductQuery(""); setProductResults([]); setProductPickerOpen(false);
  }

  function updateDraftQuantity(productId: string, quantity: string) {
    setDraftLines((current) => current.map((line) => line.product_id === productId ? { ...line, quantity } : line));
  }

  const invalidDraftLines = draftLines.filter((line) => {
    const quantity = Number(line.quantity);
    return !Number.isFinite(quantity) || quantity <= 0 || quantity > line.available_quantity;
  });

  async function submitTransferItems(items: Array<{ product_id: string; quantity: number }>) {
    if (!sourceLocationId || !destinationLocationId || sourceLocationId === destinationLocationId) {
      toast({ title: "Selecciona origen y destino distintos", description: "La transferencia necesita dos ubicaciones autorizadas.", tone: "info" }); return;
    }
    if (!items.length || items.length > 500) {
      toast({ title: "Agrega productos", description: "La transferencia debe contener entre 1 y 500 partidas.", tone: "info" }); return;
    }
    setBusy(true);
    const fingerprint = JSON.stringify({ companyId, sourceLocationId, destinationLocationId, items });
    const { data, error: rpcError } = await getSupabaseClient().rpc("create_inventory_transfer_items", {
      p_company_id: companyId,
      p_source_location_id: sourceLocationId,
      p_destination_location_id: destinationLocationId,
      p_lines: items,
      p_client_request_id: idempotency.get("inventory-transfer-create-items", fingerprint),
    });
    if (rpcError) toast({ title: "No se preparó la transferencia", description: inventoryRpcMessage(rpcError, "Revisa existencias y cantidades."), tone: "error" });
    else {
      const result = data as { inventory_transfer_id: string; line_count: number };
      idempotency.clear("inventory-transfer-create-items");
      setSelectedTransferId(result.inventory_transfer_id); setLinePage(1); setDraftLines([]); setProductQuery(""); setStatusFilter("all");
      await loadTransfers();
      toast({ title: "Transferencia preparada", description: `${result.line_count} partidas validadas. El inventario se descontará al despachar.`, tone: "success" });
    }
    setBusy(false);
  }

  async function prepareTransfer() {
    if (invalidDraftLines.length) {
      toast({ title: "Revisa las cantidades", description: "Cada cantidad debe ser mayor que cero y no superar la existencia del origen.", tone: "error" }); return;
    }
    await submitTransferItems(draftLines.map((line) => ({ product_id: line.product_id, quantity: Number(line.quantity) })));
  }

  async function createTransferFromBatch() {
    const parsed = parseTransferBatch(batch);
    if (parsed.error || !parsed.lines) { toast({ title: "Lote no válido", description: parsed.error ?? "Revisa las partidas.", tone: "error" }); return; }
    setBusy(true);
    const fingerprint = JSON.stringify({ companyId, sourceLocationId, destinationLocationId, lines: parsed.lines });
    const { data, error: rpcError } = await getSupabaseClient().rpc("create_inventory_transfer", {
      p_company_id: companyId,
      p_source_location_id: sourceLocationId,
      p_destination_location_id: destinationLocationId,
      p_lines: parsed.lines,
      p_client_request_id: idempotency.get("inventory-transfer-create", fingerprint),
    });
    if (rpcError) toast({ title: "No se importaron las partidas", description: inventoryRpcMessage(rpcError, "Revisa existencias y SKU."), tone: "error" });
    else {
      const result = data as { inventory_transfer_id: string; line_count: number };
      idempotency.clear("inventory-transfer-create");
      setSelectedTransferId(result.inventory_transfer_id); setLinePage(1); setBatch(""); setBulkImportOpen(false); setStatusFilter("all");
      await loadTransfers();
      toast({ title: "Transferencia preparada", description: `${result.line_count} partidas importadas y validadas. El inventario se descontará al despachar.`, tone: "success" });
    }
    setBusy(false);
  }

  async function markInTransit() {
    if (!selectedTransfer) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ transferId: selectedTransfer.id, status: "in_transit" });
    const { error: rpcError } = await getSupabaseClient().rpc("mark_inventory_transfer_in_transit", {
      p_inventory_transfer_id: selectedTransfer.id,
      p_client_request_id: idempotency.get("inventory-transfer-transit", fingerprint),
    });
    if (rpcError) toast({ title: "No pasó a tránsito", description: inventoryRpcMessage(rpcError, "Verifica la existencia vigente del origen."), tone: "error" });
    else { idempotency.clear("inventory-transfer-transit"); await Promise.all([loadTransfers(), loadLines()]); toast({ title: "Transferencia en tránsito", description: "El origen fue descontado y el movimiento quedó en el ledger.", tone: "success" }); }
    setBusy(false);
  }

  async function receiveTransfer() {
    if (!selectedTransfer) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ transferId: selectedTransfer.id, status: "received" });
    const { error: rpcError } = await getSupabaseClient().rpc("receive_inventory_transfer", {
      p_inventory_transfer_id: selectedTransfer.id,
      p_client_request_id: idempotency.get("inventory-transfer-receive", fingerprint),
    });
    if (rpcError) toast({ title: "No se recibió la transferencia", description: inventoryRpcMessage(rpcError, "Intenta nuevamente."), tone: "error" });
    else { idempotency.clear("inventory-transfer-receive"); await Promise.all([loadTransfers(), loadLines()]); toast({ title: "Transferencia recibida", description: "El destino fue abonado y el movimiento quedó en el ledger.", tone: "success" }); }
    setBusy(false);
  }

  return <div className="content-frame inventory-transfers"><PageHeading eyebrow="Movimiento entre ubicaciones" title="Transferencias" description="Prepara las partidas, despacha desde el origen y confirma la recepción completa en el destino." />
    {canOperate && <section className="inventory-transfer-builder"><header><div><span className="eyebrow">Nueva transferencia</span><h2>Preparar movimiento</h2></div><Button variant="secondary" size="sm" onClick={() => setBulkImportOpen(true)}>Importar partidas</Button></header>
      <div className="inventory-transfer-route"><label>Origen<Select ariaLabel="Ubicación origen" value={sourceLocationId || "unselected-source"} onValueChange={selectSource} options={[{ value: "unselected-source", label: "Selecciona origen", disabled: true }, ...locationOptions]} disabled={draftLines.length > 0} /></label><label>Destino<Select ariaLabel="Ubicación destino" value={destinationLocationId || "unselected-destination"} onValueChange={(value) => setDestinationLocationId(value === "unselected-destination" ? "" : value)} options={[{ value: "unselected-destination", label: "Selecciona destino", disabled: true }, ...locationOptions.map((option) => ({ ...option, disabled: option.value === sourceLocationId }))]} /></label></div>
      <label ref={productPickerRef} className="inventory-transfer-product-search">Agregar producto<Input role="combobox" aria-expanded={productPickerOpen} aria-controls="inventory-transfer-product-options" aria-label="Buscar producto del origen" value={productQuery} disabled={!sourceLocationId || draftLines.length >= 500} onFocus={() => setProductPickerOpen(productQuery.trim().length >= 2)} onClick={() => setProductPickerOpen(productQuery.trim().length >= 2)} onChange={(event) => changeProductQuery(event.target.value)} placeholder={sourceLocationId ? "Buscar por producto o SKU" : "Selecciona primero el origen"} />{sourceLocationId && productPickerOpen && productQuery.trim().length >= 2 && <div id="inventory-transfer-product-options" className="inventory-transfer-product-results" role="listbox">{productSearching ? <p>Buscando existencias…</p> : productResults.length ? productResults.map((product) => { const alreadyAdded = draftLines.some((line) => line.product_id === product.product_id); return <button type="button" role="option" aria-selected={alreadyAdded} disabled={alreadyAdded} key={product.product_id} onClick={() => addDraftLine(product)}><span><strong>{product.product_name}</strong><small>{product.product_code} · {product.unit ?? "Sin unidad"}</small></span><span><b>{numberFormat(Number(product.quantity_on_hand))}</b><small>disponibles</small></span></button>; }) : <p>No hay productos con existencia para esta búsqueda.</p>}</div>}</label>
      {draftLines.length ? <div className="table-wrap inventory-transfer-draft-lines"><table><thead><tr><th>Producto</th><th className="number-cell">Disponible</th><th className="number-cell">Cantidad</th><th aria-label="Acciones" /></tr></thead><tbody>{draftLines.map((line) => { const quantity = Number(line.quantity); const invalid = !Number.isFinite(quantity) || quantity <= 0 || quantity > line.available_quantity; return <tr key={line.product_id}><td><strong>{line.product_name}</strong><small>{line.product_code} · {line.unit ?? "Sin unidad"}</small></td><td className="number-cell">{numberFormat(line.available_quantity)}</td><td className="number-cell"><Input aria-label={`Cantidad a transferir de ${line.product_name}`} aria-invalid={invalid} type="number" min="0.000001" max={line.available_quantity} step="0.000001" value={line.quantity} onChange={(event) => updateDraftQuantity(line.product_id, event.target.value)} />{invalid && <small className="inventory-transfer-line-error">Máximo {numberFormat(line.available_quantity)}</small>}</td><td><Button variant="ghost" size="sm" onClick={() => setDraftLines((current) => current.filter((item) => item.product_id !== line.product_id))}>Quitar</Button></td></tr>; })}</tbody></table></div> : <div className="inventory-transfer-builder-empty"><strong>Aún no hay partidas</strong><span>Busca productos del inventario del origen para agregarlos a la transferencia.</span></div>}
      <footer><span><strong>{draftLines.length}</strong> de 500 partidas</span><div>{draftLines.length > 0 && <Button variant="secondary" disabled={busy} onClick={() => { setDraftLines([]); setProductQuery(""); }}>Limpiar</Button>}<Button variant="primary" loading={busy} disabled={!sourceLocationId || !destinationLocationId || !draftLines.length || invalidDraftLines.length > 0} onClick={() => void prepareTransfer()}>Preparar transferencia</Button></div></footer>
    </section>}
    <DataToolbar filters={<Select value={statusFilter} onValueChange={(value) => { setStatusFilter(value); setPage(1); setSelectedTransferId(null); }} ariaLabel="Filtrar transferencias por estado" options={[{ value: "all", label: "Todos los estados" }, { value: "sent", label: "Preparadas" }, { value: "in_transit", label: "En tránsito" }, { value: "received", label: "Recibidas" }]} />} activeFilters={statusFilter !== "all" ? 1 : 0} onClear={() => { setStatusFilter("all"); setPage(1); }} results={total} />
    <div className="inventory-transfer-layout"><section><DataState loading={loading} error={error} errorAction={<Button size="sm" onClick={() => void loadTransfers()}>Reintentar</Button>} hasData={transfers.length} empty="Aún no hay transferencias entre ubicaciones."><div className="table-wrap surface-table"><table><thead><tr><th>Origen</th><th>Destino</th><th>Estado</th><th>Partidas</th><th>Envío</th></tr></thead><tbody>{transfers.map((transfer) => <InteractiveTableRow className={selectedTransferId === transfer.id ? "is-selected" : ""} selected={selectedTransferId === transfer.id} label={`Abrir transferencia de ${transfer.source_location_name} a ${transfer.destination_location_name}`} key={transfer.id} onActivate={() => { setSelectedTransferId(transfer.id); setLinePage(1); }}><td><strong>{transfer.source_location_name}</strong><small>{transfer.source_location_code}</small></td><td><strong>{transfer.destination_location_name}</strong><small>{transfer.destination_location_code}</small></td><td><Badge tone={inventoryTransferTone(transfer.status)}>{inventoryTransferStatusLabel(transfer.status)}</Badge></td><td>{transfer.line_count}</td><td>{dateTimeFormat(transfer.sent_at)}</td></InteractiveTableRow>)}</tbody></table></div></DataState><DataPagination page={page} total={total} pageSize={25} onChange={setPage} /></section>
      <section className="inventory-transfer-detail">{!selectedTransfer ? <div className="customer-master-empty">Selecciona una transferencia para consultar sus partidas o avanzar su estado.</div> : <><header><div><span className="eyebrow">{selectedTransfer.source_location_code} → {selectedTransfer.destination_location_code}</span><h2>{selectedTransfer.source_location_name} a {selectedTransfer.destination_location_name}</h2></div><Badge tone={inventoryTransferTone(selectedTransfer.status)}>{inventoryTransferStatusLabel(selectedTransfer.status)}</Badge></header><p className="settings-note">{selectedTransfer.line_count} partidas · Preparada por {selectedTransfer.sent_by_name ?? "Usuario"} el {dateTimeFormat(selectedTransfer.sent_at)}.</p><DataState loading={lineLoading} error={null} hasData={lines.length} empty="La transferencia no contiene partidas."><div className="table-wrap"><table><thead><tr><th>Producto</th><th className="number-cell">Cantidad</th><th>Salida</th><th>Recepción</th></tr></thead><tbody>{lines.map((line) => <tr key={line.id}><td><strong>{line.product_name}</strong><small>{line.product_code} · {line.unit ?? "Sin unidad"}</small></td><td className="number-cell">{numberFormat(Number(line.quantity))}</td><td>{line.dispatched ? "Registrada" : "Pendiente"}</td><td>{line.received ? "Registrada" : "Pendiente"}</td></tr>)}</tbody></table></div></DataState><DataPagination page={linePage} total={lineTotal} pageSize={DATA_PAGE_SIZE} onChange={setLinePage} /><div className="inventory-transfer-actions">{selectedTransfer.status === "sent" && sourceAccessible && <Button variant="primary" loading={busy} onClick={() => void markInTransit()}>Despachar transferencia</Button>}{selectedTransfer.status === "in_transit" && destinationAccessible && <Button variant="primary" loading={busy} onClick={() => void receiveTransfer()}>Confirmar recepción completa</Button>}{selectedTransfer.status === "sent" && <small>Al despachar se descuenta el inventario del origen.</small>}{selectedTransfer.status === "in_transit" && <small>Confirma únicamente después de verificar todas las partidas en el destino.</small>}{selectedTransfer.status === "received" && <small>Transferencia terminada y conciliada en el ledger.</small>}</div></>}</section></div>
    <Modal open={bulkImportOpen} onOpenChange={(open) => !busy && setBulkImportOpen(open)} eyebrow="Carga secundaria" title="Importar partidas por SKU" description="Úsalo para datos preparados por otro sistema. Para operación diaria utiliza el buscador visual." footer={<><Button variant="secondary" disabled={busy} onClick={() => setBulkImportOpen(false)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!sourceLocationId || !destinationLocationId || !batch.trim()} onClick={() => void createTransferFromBatch()}>Importar y preparar</Button></>}><label className="operation-reason">Una partida por renglón: SKU,cantidad<textarea value={batch} onChange={(event) => setBatch(event.target.value)} rows={7} placeholder={"FERT-001,12\nRIEGO-020,4"} /></label><small>Se validarán entre 1 y 500 SKU distintos antes de crear la transferencia.</small></Modal>
  </div>;
}

type InventoryCountStatus = "open" | "review" | "pending_approval" | "posted" | "rejected" | "cancelled";
type InventoryCountSummary = {
  id: string;
  location_id: string;
  location_code: string;
  location_name: string;
  status: InventoryCountStatus;
  line_count: number;
  counted_line_count: number;
  variance_line_count: number;
  variance_reason: string | null;
  cancellation_reason: string | null;
  opened_by_name: string | null;
  submitted_by_name: string | null;
  decided_by_name: string | null;
  cancelled_by_name: string | null;
  opened_at: string;
  reviewed_at: string | null;
  submitted_at: string | null;
  decided_at: string | null;
  posted_at: string | null;
  cancelled_at: string | null;
};
type InventoryCountLine = {
  id: string;
  product_id: string;
  product_code: string;
  product_barcode: string | null;
  product_name: string;
  unit: string | null;
  expected_quantity: number | null;
  counted_quantity: number | null;
  variance_quantity: number | null;
  counted_at: string | null;
};

function InventoryCountsView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { accessibleLocations } = useSatrapy();
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const [counts, setCounts] = useState<InventoryCountSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [statusFilter, setStatusFilter] = useState("all");
  const [locationFilter, setLocationFilter] = useState("all");
  const [newLocationId, setNewLocationId] = useState("");
  const [selectedCountId, setSelectedCountId] = useState<string | null>(null);
  const [lines, setLines] = useState<InventoryCountLine[]>([]);
  const [linePage, setLinePage] = useState(1);
  const [lineTotal, setLineTotal] = useState(0);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const dirtyLineIds = useRef(new Set<string>());
  const [reason, setReason] = useState("");
  const [lineSearch, setLineSearch] = useState("");
  const [debouncedLineSearch, setDebouncedLineSearch] = useState("");
  const [lineFilter, setLineFilter] = useState("all");
  const [scanCode, setScanCode] = useState("");
  const scanTarget = useRef("");
  const countWorkspaceRef = useRef<HTMLElement | null>(null);
  const [cancelReason, setCancelReason] = useState<string | null>(null);
  const [confirmVisibleZero, setConfirmVisibleZero] = useState(false);
  const [loading, setLoading] = useState(true);
  const [lineLoading, setLineLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const canOperate = permissions.includes("operate_inventory");
  const canApprove = permissions.includes("approve_inventory_adjustments");
  const selectedCount = counts.find((count) => count.id === selectedCountId) ?? null;

  const loadCounts = useCallback(async () => {
    setLoading(true); setError(null);
    const { data, error: queryError } = await getSupabaseClient().rpc("list_inventory_counts", {
      p_company_id: companyId,
      p_location_id: locationFilter === "all" ? null : locationFilter,
      p_status: statusFilter === "all" ? null : statusFilter,
      p_page: page,
      p_page_size: 25,
    });
    const result = data as { items?: InventoryCountSummary[]; total?: number } | null;
    setCounts(result?.items ?? []); setTotal(result?.total ?? 0);
    if (queryError) setError(inventoryRpcMessage(queryError, "No se pudieron cargar los conteos."));
    setLoading(false);
  }, [companyId, locationFilter, page, statusFilter]);

  const loadLines = useCallback(async () => {
    if (!selectedCountId) { setLines([]); setLineTotal(0); return; }
    setLineLoading(true);
    const { data, error: queryError } = await getSupabaseClient().rpc("search_inventory_count_lines", {
      p_inventory_count_id: selectedCountId,
      p_query: debouncedLineSearch || null,
      p_capture_status: lineFilter,
      p_page: linePage,
      p_page_size: DATA_PAGE_SIZE,
    });
    const result = data as { items?: InventoryCountLine[]; total?: number } | null;
    const nextLines = result?.items ?? [];
    setLines(nextLines); setLineTotal(result?.total ?? 0);
    setDraft((current) => ({ ...current, ...Object.fromEntries(nextLines.map((line) => [line.id, line.counted_quantity == null ? "" : String(line.counted_quantity)])) }));
    if (queryError) toast({ title: "No se cargaron las partidas", description: inventoryRpcMessage(queryError, "Intenta nuevamente."), tone: "error" });
    setLineLoading(false);
    if (!queryError && scanTarget.current && debouncedLineSearch === scanTarget.current) {
      scanTarget.current = "";
      window.setTimeout(() => {
        if (nextLines.length === 1) { const input = countWorkspaceRef.current?.querySelector<HTMLInputElement>("[data-count-input]"); input?.focus(); input?.select(); }
        else if (!nextLines.length) toast({ title: "Código no encontrado", description: "Verifica el código de barras, SKU o alias escaneado.", tone: "info" });
      }, 0);
    }
  }, [debouncedLineSearch, lineFilter, linePage, selectedCountId, toast]);

  useEffect(() => { void Promise.resolve().then(loadCounts); }, [loadCounts]);
  useEffect(() => { void Promise.resolve().then(loadLines); }, [loadLines]);

  const pendingPayload = useCallback(() => lines
    .filter((line) => dirtyLineIds.current.has(line.id) && draft[line.id] !== undefined && draft[line.id] !== "")
    .map((line) => ({ product_id: line.product_id, counted_quantity: Number(draft[line.id]), line_id: line.id })), [draft, lines]);

  const savePendingLines = useCallback(async ({ silent = false }: { silent?: boolean } = {}) => {
    if (!selectedCount || selectedCount.status !== "open") return true;
    const payload = pendingPayload();
    if (!payload.length) return true;
    if (payload.some((line) => !Number.isFinite(line.counted_quantity) || line.counted_quantity < 0)) {
      toast({ title: "Captura cantidades válidas", description: "Las cantidades deben ser números iguales o mayores que cero.", tone: "info" });
      return false;
    }
    setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("save_inventory_count_batch", {
      p_inventory_count_id: selectedCount.id,
      p_lines: payload.map(({ product_id, counted_quantity }) => ({ product_id, counted_quantity })),
    });
    if (rpcError) {
      toast({ title: "No se guardó el avance", description: inventoryRpcMessage(rpcError, "Revisa las cantidades."), tone: "error" });
      setBusy(false);
      return false;
    }
    payload.forEach((line) => dirtyLineIds.current.delete(line.line_id));
    await loadCounts();
    if (!silent) toast({ title: "Avance guardado", description: `${payload.length} cantidades registradas en un solo lote.`, tone: "success" });
    setBusy(false);
    return true;
  }, [loadCounts, pendingPayload, selectedCount, toast]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void savePendingLines({ silent: true }).then((saved) => {
        if (saved) { setDebouncedLineSearch(lineSearch.trim()); setLinePage(1); }
      });
    }, 280);
    return () => window.clearTimeout(timer);
  }, [lineSearch, savePendingLines]);

  async function openCount() {
    if (!newLocationId) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ companyId, locationId: newLocationId });
    const { data, error: rpcError } = await getSupabaseClient().rpc("open_inventory_count", {
      p_company_id: companyId,
      p_location_id: newLocationId,
      p_client_request_id: idempotency.get("inventory-count-open", fingerprint),
    });
    if (rpcError) toast({ title: "No se pudo abrir el conteo", description: inventoryRpcMessage(rpcError, "Verifica que no exista otro conteo activo."), tone: "error" });
    else {
      idempotency.clear("inventory-count-open");
      const result = data as { inventory_count_id: string };
      setSelectedCountId(result.inventory_count_id); setLinePage(1); setReason(""); setLineSearch(""); setDebouncedLineSearch(""); setLineFilter("all");
      await loadCounts();
      toast({ title: "Conteo abierto", description: "Las partidas incluyen la existencia operativa y los productos del surtido activo de la sucursal.", tone: "success" });
    }
    setBusy(false);
  }

  async function savePage() {
    if (!dirtyLineIds.current.size) {
      toast({ title: "Avance al día", description: "No hay cantidades nuevas por guardar.", tone: "info" });
      return;
    }
    if (await savePendingLines()) await loadLines();
  }

  async function reviewCount() {
    if (!selectedCount) return;
    const payload = pendingPayload();
    if (payload.some((line) => !Number.isFinite(line.counted_quantity) || line.counted_quantity < 0)) {
      toast({ title: "Captura cantidades válidas", description: "Corrige las cantidades antes de finalizar.", tone: "info" }); return;
    }
    setBusy(true);
    const fingerprint = JSON.stringify({ countId: selectedCount.id, payload: payload.map(({ product_id, counted_quantity }) => ({ product_id, counted_quantity })) });
    const { data, error: rpcError } = await getSupabaseClient().rpc("review_inventory_count", {
      p_inventory_count_id: selectedCount.id,
      p_lines: payload.map(({ product_id, counted_quantity }) => ({ product_id, counted_quantity })),
      p_client_request_id: idempotency.get("inventory-count-review", fingerprint),
    });
    if (rpcError) toast({ title: "No se pudo finalizar la captura", description: inventoryRpcMessage(rpcError, "Confirma que todas las partidas estén contadas."), tone: "error" });
    else {
      idempotency.clear("inventory-count-review");
      payload.forEach((line) => dirtyLineIds.current.delete(line.line_id));
      const result = data as { status: InventoryCountStatus; variance_line_count: number };
      if (result.status === "review") { setLineSearch(""); setDebouncedLineSearch(""); setLineFilter("differences"); setLinePage(1); }
      await loadCounts();
      if (result.status !== "review") await loadLines();
      toast({ title: result.status === "posted" ? "Conteo cerrado" : "Revisa las diferencias", description: result.status === "posted" ? "No se detectaron diferencias y el inventario no cambió." : `${result.variance_line_count} diferencias están listas para explicar y enviar a aprobación.`, tone: result.status === "posted" ? "success" : "info" });
    }
    setBusy(false);
  }

  async function submitCount() {
    if (!selectedCount || !reason.trim()) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ countId: selectedCount.id, reason: reason.trim() });
    const { error: rpcError } = await getSupabaseClient().rpc("submit_inventory_count", {
      p_inventory_count_id: selectedCount.id,
      p_variance_reason: reason.trim(),
      p_client_request_id: idempotency.get("inventory-count-submit", fingerprint),
    });
    if (rpcError) toast({ title: "No se enviaron las diferencias", description: inventoryRpcMessage(rpcError, "El servidor bloqueó el envío."), tone: "error" });
    else {
      idempotency.clear("inventory-count-submit");
      await Promise.all([loadCounts(), loadLines()]);
      toast({ title: "Diferencias enviadas", description: "El conteo quedó pendiente de aprobación independiente.", tone: "success" });
    }
    setBusy(false);
  }

  async function cancelCount() {
    if (!selectedCount || !cancelReason?.trim()) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ countId: selectedCount.id, reason: cancelReason.trim() });
    const { error: rpcError } = await getSupabaseClient().rpc("cancel_inventory_count", {
      p_inventory_count_id: selectedCount.id,
      p_reason: cancelReason.trim(),
      p_client_request_id: idempotency.get("inventory-count-cancel", fingerprint),
    });
    if (rpcError) toast({ title: "No se canceló el conteo", description: inventoryRpcMessage(rpcError, "El servidor bloqueó la cancelación."), tone: "error" });
    else {
      idempotency.clear("inventory-count-cancel"); setCancelReason(null); dirtyLineIds.current.clear();
      await loadCounts();
      toast({ title: "Conteo cancelado", description: "La ubicación quedó disponible y el inventario no fue modificado.", tone: "success" });
    }
    setBusy(false);
  }

  async function markVisiblePendingAsZero() {
    if (!selectedCount) return;
    const pending = lines.filter((line) => line.counted_quantity == null && (draft[line.id] ?? "") === "");
    if (!pending.length) { setConfirmVisibleZero(false); return; }
    setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("save_inventory_count_batch", {
      p_inventory_count_id: selectedCount.id,
      p_lines: pending.map((line) => ({ product_id: line.product_id, counted_quantity: 0 })),
    });
    if (rpcError) toast({ title: "No se confirmaron los ceros", description: inventoryRpcMessage(rpcError, "Intenta nuevamente."), tone: "error" });
    else {
      pending.forEach((line) => dirtyLineIds.current.delete(line.id));
      setConfirmVisibleZero(false);
      await Promise.all([loadCounts(), loadLines()]);
      toast({ title: "Partidas confirmadas en cero", description: `${pending.length} partidas visibles se guardaron en un solo lote.`, tone: "success" });
    }
    setBusy(false);
  }

  async function changeLinePage(nextPage: number) {
    if (await savePendingLines({ silent: true })) setLinePage(nextPage);
  }

  async function changeLineFilter(value: string) {
    if (await savePendingLines({ silent: true })) { setLineFilter(value); setLinePage(1); }
  }

  async function scanCountLine() {
    const code = scanCode.trim();
    if (!code || !(await savePendingLines({ silent: true }))) return;
    scanTarget.current = code;
    setLineFilter("all"); setLinePage(1); setLineSearch(code); setDebouncedLineSearch(code); setScanCode("");
  }

  async function closeWorkspace() {
    if (await savePendingLines({ silent: true })) { setSelectedCountId(null); setLineSearch(""); setDebouncedLineSearch(""); setLineFilter("all"); }
  }

  function changeDraft(lineId: string, value: string) {
    dirtyLineIds.current.add(lineId);
    setDraft((current) => ({ ...current, [lineId]: value.replace(/[^0-9.]/g, "") }));
  }

  async function decideCount(approve: boolean) {
    if (!selectedCount) return;
    setBusy(true);
    const fingerprint = JSON.stringify({ countId: selectedCount.id, approve, reason: reason.trim() });
    const { error: rpcError } = await getSupabaseClient().rpc("decide_inventory_count", {
      p_inventory_count_id: selectedCount.id,
      p_approve: approve,
      p_decision_reason: reason.trim() || null,
      p_client_request_id: idempotency.get("inventory-count-decision", fingerprint),
    });
    if (rpcError) toast({ title: approve ? "No se aplicaron los ajustes" : "No se rechazó el conteo", description: inventoryRpcMessage(rpcError, "El servidor bloqueó la decisión."), tone: "error" });
    else {
      idempotency.clear("inventory-count-decision"); setReason("");
      await Promise.all([loadCounts(), loadLines()]);
      toast({ title: approve ? "Diferencias aprobadas" : "Conteo rechazado", description: approve ? "El saldo y el ledger quedaron actualizados en una sola transacción." : "El documento quedó cerrado sin modificar inventario.", tone: approve ? "success" : "info" });
    }
    setBusy(false);
  }

  const locationOptions = [{ value: "all", label: "Todas las ubicaciones" }, ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))];
  const countAction = selectedCount
    ? <Button variant="secondary" disabled={busy} onClick={() => void closeWorkspace()}>Volver a conteos</Button>
    : canOperate ? <div className="inventory-count-open"><Select ariaLabel="Ubicación para nuevo conteo" value={newLocationId || "unselected"} onValueChange={(value) => setNewLocationId(value === "unselected" ? "" : value)} options={[{ value: "unselected", label: "Selecciona ubicación", disabled: true }, ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` }))]} /><Button variant="primary" loading={busy} disabled={!newLocationId} onClick={() => void openCount()}>Abrir conteo</Button></div> : undefined;
  const pendingVisible = lines.filter((line) => line.counted_quantity == null && (draft[line.id] ?? "") === "").length;
  return <div className="content-frame inventory-counts"><PageHeading eyebrow="Control físico" title={selectedCount ? selectedCount.location_name : "Conteos físicos"} description={selectedCount ? `Conteo ${selectedCount.location_code} · captura ciega, guardada por lotes y auditable.` : "Captura un conteo completo por ubicación. Las diferencias solo afectan inventario después de una aprobación independiente."} action={countAction} />
    {!selectedCount ? <>
      <DataToolbar filters={<><Select value={locationFilter} onValueChange={(value) => { setLocationFilter(value); setPage(1); }} ariaLabel="Filtrar conteos por ubicación" options={locationOptions} /><Select value={statusFilter} onValueChange={(value) => { setStatusFilter(value); setPage(1); }} ariaLabel="Filtrar conteos por estado" options={[{ value: "all", label: "Todos los estados" }, { value: "open", label: "Abiertos" }, { value: "review", label: "En revisión" }, { value: "pending_approval", label: "Pendientes de aprobación" }, { value: "posted", label: "Aplicados" }, { value: "rejected", label: "Rechazados" }, { value: "cancelled", label: "Cancelados" }]} /></>} activeFilters={(locationFilter !== "all" ? 1 : 0) + (statusFilter !== "all" ? 1 : 0)} onClear={() => { setLocationFilter("all"); setStatusFilter("all"); setPage(1); }} results={total} />
      <DataState loading={loading} error={error} errorAction={<Button size="sm" onClick={() => void loadCounts()}>Reintentar</Button>} hasData={counts.length} empty="Aún no hay conteos físicos."><div className="table-wrap surface-table"><table><thead><tr><th>Ubicación</th><th>Estado</th><th>Avance</th><th>Diferencias</th><th>Apertura</th></tr></thead><tbody>{counts.map((count) => <InteractiveTableRow key={count.id} selected={selectedCountId === count.id} label={`Abrir conteo de ${count.location_name}`} onActivate={() => { dirtyLineIds.current.clear(); setSelectedCountId(count.id); setLinePage(1); setLineSearch(""); setDebouncedLineSearch(""); setLineFilter(count.status === "review" ? "differences" : "all"); setReason(count.variance_reason ?? ""); }}><td><strong>{count.location_name}</strong><small>{count.location_code}</small></td><td><Badge tone={inventoryCountTone(count.status)}>{inventoryCountStatusLabel(count.status)}</Badge></td><td>{count.counted_line_count}/{count.line_count}</td><td>{count.variance_line_count || "—"}</td><td>{dateTimeFormat(count.opened_at)}</td></InteractiveTableRow>)}</tbody></table></div></DataState><DataPagination page={page} total={total} pageSize={25} onChange={setPage} />
    </> : <section ref={countWorkspaceRef} className="inventory-count-detail inventory-count-detail--workspace">
      <header><div><span className="eyebrow">{selectedCount.location_code}</span><h2>{selectedCount.location_name}</h2></div><Badge tone={inventoryCountTone(selectedCount.status)}>{inventoryCountStatusLabel(selectedCount.status)}</Badge></header>
      <div className="inventory-count-progress"><strong>{selectedCount.counted_line_count} de {selectedCount.line_count}</strong><span>partidas capturadas{selectedCount.variance_line_count ? ` · ${selectedCount.variance_line_count} diferencias` : ""}</span><progress max={Math.max(selectedCount.line_count, 1)} value={selectedCount.counted_line_count} /></div>
      {selectedCount.status === "open" && canOperate && <div className="inventory-count-open"><Input aria-label="Escanear código de barras o SKU" value={scanCode} onChange={(event) => setScanCode(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void scanCountLine(); } }} placeholder="Escanea código de barras o SKU" /><Button variant="secondary" size="sm" disabled={!scanCode.trim() || busy} onClick={() => void scanCountLine()}>Localizar</Button></div>}
      <DataToolbar search={lineSearch} onSearchChange={setLineSearch} placeholder="Buscar producto, SKU, alias o código de barras" filters={<Select value={lineFilter} onValueChange={(value) => void changeLineFilter(value)} ariaLabel="Filtrar partidas del conteo" options={[{ value: "all", label: "Todas las partidas" }, { value: "pending", label: "Pendientes de contar" }, { value: "counted", label: "Capturadas" }, ...(selectedCount.status !== "open" ? [{ value: "differences", label: "Con diferencia" }] : [])]} />} activeFilters={(lineSearch.trim() ? 1 : 0) + (lineFilter !== "all" ? 1 : 0)} onClear={() => { setLineSearch(""); void changeLineFilter("all"); }} results={lineTotal} />
      {selectedCount.status === "open" && <div className="inventory-count-capture-note"><span>La existencia esperada permanece oculta durante la captura.</span>{pendingVisible > 0 && canOperate && <Button variant="secondary" size="sm" onClick={() => setConfirmVisibleZero(true)}>Confirmar visibles en cero</Button>}</div>}
      <DataState loading={lineLoading} error={null} hasData={lines.length} empty={lineSearch || lineFilter !== "all" ? "No hay partidas que coincidan con estos filtros." : "Este conteo no contiene partidas. Puedes finalizarlo para confirmar la ubicación vacía."}><div className="table-wrap inventory-count-lines"><table><thead><tr><th>Producto</th>{selectedCount.status !== "open" && <th className="number-cell">Esperado</th>}<th className="number-cell">Contado</th>{selectedCount.status !== "open" && <th className="number-cell">Diferencia</th>}</tr></thead><tbody>{lines.map((line) => <tr key={line.id}><td><strong>{line.product_name}</strong><small>{[line.product_code, line.product_barcode, line.unit ?? "Sin unidad"].filter(Boolean).join(" · ")}</small></td>{selectedCount.status !== "open" && <td className="number-cell">{numberFormat(Number(line.expected_quantity ?? 0))}</td>}<td className="number-cell">{selectedCount.status === "open" && canOperate ? <Input data-count-input aria-label={`Cantidad contada de ${line.product_name}`} inputMode="decimal" min="0" value={draft[line.id] ?? ""} onChange={(event) => changeDraft(line.id, event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); const next = event.currentTarget.closest("tr")?.nextElementSibling?.querySelector<HTMLInputElement>("[data-count-input]"); next?.focus(); next?.select(); } }} /> : line.counted_quantity == null ? "—" : numberFormat(Number(line.counted_quantity))}</td>{selectedCount.status !== "open" && <td className={`number-cell ${Number(line.variance_quantity ?? 0) !== 0 ? "is-variance" : ""}`}>{numberFormat(Number(line.variance_quantity ?? 0))}</td>}</tr>)}</tbody></table></div></DataState>
      <DataPagination page={linePage} total={lineTotal} pageSize={DATA_PAGE_SIZE} onChange={(value) => void changeLinePage(value)} />
      {(selectedCount.status === "open" || selectedCount.status === "review" || selectedCount.status === "pending_approval") && <div className="inventory-count-actions">
        {selectedCount.status === "review" && <label>Explicación de las diferencias<Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Describe la causa o el resultado de la verificación" /></label>}
        {selectedCount.status === "pending_approval" && <label>Motivo de la decisión<Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Obligatorio para rechazar" /></label>}
        <div>{selectedCount.status === "open" && canOperate && <><Button variant="danger" disabled={busy} onClick={() => setCancelReason("")}>Cancelar conteo</Button><Button loading={busy} onClick={() => void savePage()}>Guardar avance</Button><Button variant="primary" loading={busy} onClick={() => void reviewCount()}>Finalizar captura</Button></>}{selectedCount.status === "review" && canOperate && <><Button variant="danger" disabled={busy} onClick={() => setCancelReason("")}>Cancelar conteo</Button><Button variant="primary" loading={busy} disabled={!reason.trim()} onClick={() => void submitCount()}>Enviar diferencias a aprobación</Button></>}{selectedCount.status === "pending_approval" && canApprove && <><Button variant="danger" loading={busy} onClick={() => void decideCount(false)}>Rechazar</Button><Button variant="primary" loading={busy} onClick={() => void decideCount(true)}>Aprobar y ajustar</Button></>}</div>
      </div>}
      {selectedCount.status === "cancelled" && <p className="inventory-count-terminal-note"><strong>Conteo cancelado.</strong> {selectedCount.cancellation_reason}</p>}
    </section>}
    <Modal open={cancelReason !== null} onOpenChange={(open) => { if (!open && !busy) setCancelReason(null); }} eyebrow="Sin afectar inventario" title="Cancelar conteo" description="La captura quedará auditada, la ubicación volverá a estar disponible y no se generará ningún movimiento." footer={<><Button variant="secondary" disabled={busy} onClick={() => setCancelReason(null)}>Volver</Button><Button variant="danger" loading={busy} disabled={!cancelReason?.trim()} onClick={() => void cancelCount()}>Confirmar cancelación</Button></>}><label className="operation-reason">Motivo obligatorio<textarea rows={4} value={cancelReason ?? ""} onChange={(event) => setCancelReason(event.target.value)} placeholder="Ej. Conteo abierto para una prueba" /></label></Modal>
    <Modal open={confirmVisibleZero} onOpenChange={(open) => !busy && setConfirmVisibleZero(open)} eyebrow="Confirmación física" title="Confirmar partidas visibles en cero" description={`Se guardarán ${pendingVisible} partidas pendientes de esta página en un solo lote. Úsalo únicamente después de comprobar físicamente que no existe producto.`} footer={<><Button variant="secondary" disabled={busy} onClick={() => setConfirmVisibleZero(false)}>Volver</Button><Button variant="primary" loading={busy} onClick={() => void markVisiblePendingAsZero()}>Confirmar en cero</Button></>} />
  </div>;
}

function ImportAuditWorkspace({ companyId, canPromotePurchaseOrders }: { companyId: string; canPromotePurchaseOrders: boolean }) {
  const [scope, setScope] = useState("imports");
  return <div className="content-frame import-audit-workspace">
    <PageHeading eyebrow="Trazabilidad" title="Auditoría de importaciones" description="Consulta lotes y promociones desde una sola bandeja." />
    <DataToolbar filters={<Select value={scope} onValueChange={setScope} ariaLabel="Filtrar auditoría por alcance" options={[{ value: "imports", label: "Archivos y lotes" }, { value: "suppliers", label: "Proveedores importados" }, { value: "purchase_orders", label: "Órdenes de compra importadas" }]} />} activeFilters={scope === "imports" ? 0 : 1} onClear={() => setScope("imports")} />
    {scope === "imports" && <AuditView companyId={companyId} />}
    {scope === "suppliers" && <SupplierPromotionAudit companyId={companyId} />}
    {scope === "purchase_orders" && <PurchaseOrderPromotionAudit companyId={companyId} canPromote={canPromotePurchaseOrders} />}
  </div>;
}

function AuditView({ companyId }: { companyId: string }) {
  const { queryCache } = useSatrapy();
  type ImportAuditRow = Omit<ImportBatchRow, "import_files" | "import_errors"> & {
    actor_name: string;
    files: Array<{ original_name: string; file_type: string; row_count: number }>;
    issue_count: number;
  };
  const [rows, setRows] = useState<ImportAuditRow[]>([]); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null); const [statusFilter, setStatusFilter] = useState("all"); const [typeFilter, setTypeFilter] = useState("all"); const [page, setPage] = useState(1); const [total, setTotal] = useState(0); const requestId = useRef(0);
  const load = useCallback(async () => { const cacheKey = `audit:${companyId}:${typeFilter}:${statusFilter}:${page}`; const cached = queryCache.get<{ rows: ImportAuditRow[]; total: number }>(cacheKey); if (cached) { setRows(cached.rows); setTotal(cached.total); setError(null); setLoading(false); return; } const current = ++requestId.current; setLoading(true); setError(null); const { data, error: queryError } = await getSupabaseClient().rpc("list_import_audit", { p_company_id: companyId, p_page: page, p_page_size: DATA_PAGE_SIZE, p_import_type: typeFilter === "all" ? null : typeFilter, p_status: statusFilter === "all" ? null : statusFilter }); if (current !== requestId.current) return; const result = data as { items?: ImportAuditRow[]; total?: number } | null; const nextRows = result?.items ?? []; const nextTotal = result?.total ?? 0; setRows(nextRows); setTotal(nextTotal); setError(queryError ? "No se pudo cargar la auditoría." : null); setLoading(false); if (!queryError) queryCache.set(cacheKey, { rows: nextRows, total: nextTotal }); }, [companyId, page, queryCache, statusFilter, typeFilter]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  function clearFilters() { setStatusFilter("all"); setTypeFilter("all"); setPage(1); }
  function refresh() { queryCache.invalidate(`audit:${companyId}:`); void load(); }
  return <section className="import-audit-panel"><div className="import-audit-panel-heading"><div><h2>Archivos y lotes</h2><p>Cada lote conserva actor, archivo, resultado e incidencias.</p></div><Button variant="secondary" onClick={refresh}><RefreshCw size={16} /> Actualizar</Button></div><DataToolbar filters={<><Select value={typeFilter} onValueChange={(value) => { setTypeFilter(value); setPage(1); }} ariaLabel="Filtrar por tipo de importación" options={[{ value: "all", label: "Todos los tipos" }, { value: "products", label: "Productos" }, { value: "inventory", label: "Inventario" }, { value: "prices", label: "Precios" }, { value: "costs", label: "Costos" }]} /><Select value={statusFilter} onValueChange={(value) => { setStatusFilter(value); setPage(1); }} ariaLabel="Filtrar por estado de importación" options={[{ value: "all", label: "Todos los estados" }, { value: "completed", label: "Completado" }, { value: "staged", label: "En staging" }, { value: "validation_failed", label: "Validación fallida" }, { value: "failed", label: "Fallido" }, { value: "discarded", label: "Descartado" }, { value: "expired", label: "Vencido" }]} /></>} activeFilters={(typeFilter !== "all" ? 1 : 0) + (statusFilter !== "all" ? 1 : 0)} onClear={clearFilters} results={total} /><DataState loading={loading && rows.length === 0} error={error} errorAction={<Button variant="secondary" size="sm" onClick={refresh}>Reintentar</Button>} hasData={rows.length} empty="Aún no hay lotes de importación para auditar."><div className="table-wrap surface-table"><table><thead><tr><th>Tipo</th><th>Archivo</th><th>Estado</th><th>Actor</th><th className="number-cell">Registros</th><th>Fecha</th><th>Incidencias</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}><td><strong>{importTypeLabel(row.import_type)}</strong></td><td>{row.files.map((file) => file.original_name).join(", ") || "Archivo no disponible"}</td><td><Badge tone={auditStatusTone(row.status)}>{statusLabel(row.status)}</Badge></td><td>{row.actor_name}</td><td className="number-cell">{row.records_imported}/{row.records_received}</td><td>{dateTimeFormat(row.started_at)}</td><td>{row.issue_count > 0 ? <Badge tone="warning">{row.issue_count} incidencia{row.issue_count === 1 ? "" : "s"}</Badge> : <span>—</span>}</td></tr>)}</tbody></table></div></DataState><DataPagination page={page} total={total} pageSize={DATA_PAGE_SIZE} onChange={setPage} /></section>;
}

function SupplierPromotionAudit({ companyId }: { companyId: string }) {
  type Row = { id:string;cutoff_date:string;status:string;summary:{suppliers?:number;purchase_orders?:number;purchase_order_lines?:number;payable_documents?:number;supplier_payments?:number;error_count?:number;warning_count?:number};supplier_promotion_completed_at:string|null;supplier_promotion_summary:{source_suppliers?:number;promoted?:number;pending_exceptions?:number;purchase_orders_created?:number;payables_created?:number;payments_created?:number} };
  const [rows,setRows]=useState<Row[]>([]); const [loading,setLoading]=useState(true); const [error,setError]=useState<string|null>(null);
  const load=useCallback(async()=>{setLoading(true);const {data,error:rpcError}=await getSupabaseClient().rpc("list_alpha_purchasing_import_batches",{p_company_id:companyId,p_page:1,p_page_size:20});setRows(((data as {items?:Row[]}|null)?.items??[]));setError(rpcError?.message?presentImportedSourceText(rpcError.message):null);setLoading(false);},[companyId]);
  useEffect(()=>{void Promise.resolve().then(load);},[load]);
  return <section className="import-audit-panel supplier-audit-frame"><div className="import-audit-panel-heading"><div><h2>Promoción de proveedores</h2><p>Resultado auditable del maestro de proveedores; las demás etapas permanecen como evidencia.</p></div><Button variant="secondary" onClick={()=>void load()}><RefreshCw size={16}/> Actualizar</Button></div><DataState loading={loading} error={error} hasData={rows.length} empty="Aún no hay paquetes de importación de compras."><div className="table-wrap surface-table"><table><thead><tr><th>Corte</th><th>Staging</th><th>Promoción</th><th>Excepciones</th><th>Etapas no creadas</th></tr></thead><tbody>{rows.map(row=><tr key={row.id}><td><strong>{dateOnlyFormat(row.cutoff_date)}</strong><small>{row.summary.suppliers??0} proveedores · {row.summary.error_count??0} errores · {row.summary.warning_count??0} alertas</small></td><td><Badge tone={row.status==="staged"?"info":row.status==="validation_failed"?"danger":"neutral"}>{statusLabel(row.status)}</Badge></td><td>{row.supplier_promotion_completed_at?<><Badge tone={(row.supplier_promotion_summary.pending_exceptions??0)>0?"warning":"success"}>{row.supplier_promotion_summary.promoted??0}/{row.supplier_promotion_summary.source_suppliers??row.summary.suppliers??0}</Badge><small>{dateTimeFormat(row.supplier_promotion_completed_at)}</small></>:<span>Sin promover</span>}</td><td>{row.supplier_promotion_summary.pending_exceptions??0}</td><td><small>{row.supplier_promotion_summary.purchase_orders_created??0} OC · {row.supplier_promotion_summary.payables_created??0} CxP · {row.supplier_promotion_summary.payments_created??0} pagos</small></td></tr>)}</tbody></table></div></DataState></section>;
}



function textValue(data: Record<string, unknown>, key: string) {
  const value = data[key];
  return typeof value === "string" || typeof value === "number" ? String(value) : "";
}

function validationLabel(status: StagedRow["validation_status"]) {
  return status === "valid" ? "Válida" : status === "warning" ? "Alerta" : "Error";
}

function fileNameForBatch(batch: StagedBatch) {
  return batch.import_files[0]?.original_name ?? "Archivo en staging";
}
function roleLabel(code: AppRoleCode) { return ALL_ROLES.find((role) => role.code === code)?.display_name ?? code; }
function numberFormat(value: number) { return new Intl.NumberFormat("es-MX", { maximumFractionDigits: 3 }).format(value); }
function dateOnlyFormat(value: string) { return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeZone: "UTC" }).format(new Date(`${value}T00:00:00Z`)); }
function dateTimeFormat(value: string) { return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)); }
function statusLabel(status: string) { return status === "completed" ? "Completado" : status === "failed" ? "Fallido" : status === "discarded" ? "Descartado" : status === "expired" ? "Vencido" : status === "validation_failed" ? "Validación fallida" : status === "staged" ? "En staging" : "Procesando"; }
function importTypeLabel(type: string) { return type === "products" ? "Productos" : type === "inventory" ? "Inventario" : type === "prices" ? "Precios" : type === "costs" ? "Costos" : type; }
function inventoryMovementLabel(type: string) { return type === "opening_snapshot" ? "Saldo inicial" : type === "sale" ? "Venta" : type === "controlled_adjustment" ? "Ajuste controlado" : type === "physical_count_adjustment" ? "Conteo físico" : type === "transfer_out" ? "Salida por transferencia" : type === "transfer_in" ? "Entrada por transferencia" : type; }
function inventoryTransferStatusLabel(status: InventoryTransferStatus) { return status === "sent" ? "Preparada" : status === "in_transit" ? "En tránsito" : "Recibida"; }
function inventoryTransferTone(status: InventoryTransferStatus): "primary" | "warning" | "success" { return status === "sent" ? "primary" : status === "in_transit" ? "warning" : "success"; }
function inventoryCountStatusLabel(status: InventoryCountStatus) { return status === "open" ? "En captura" : status === "review" ? "En revisión" : status === "pending_approval" ? "Por aprobar" : status === "posted" ? "Aplicado" : status === "cancelled" ? "Cancelado" : "Rechazado"; }
function inventoryCountTone(status: InventoryCountStatus): "neutral" | "primary" | "warning" | "success" | "danger" | "info" { return status === "open" ? "primary" : status === "review" ? "info" : status === "pending_approval" ? "warning" : status === "posted" ? "success" : status === "cancelled" ? "neutral" : "danger"; }
function inventoryRpcMessage(error: { message?: string } | null, fallback: string) { return presentImportedSourceText(error?.message?.trim() || fallback); }
function auditStatusTone(status: string): "neutral" | "primary" | "success" | "warning" | "danger" | "info" { return status === "completed" ? "success" : status === "failed" || status === "validation_failed" ? "danger" : status === "processing" ? "warning" : status === "staged" ? "info" : "neutral"; }
