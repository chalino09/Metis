"use client";

import {
  AlertCircle,
  ArrowLeft,
  Banknote,
  CheckCircle2,
  CircleDollarSign,
  ClipboardList,
  CircleHelp,
  CreditCard,
  CloudOff,
  Clock3,
  Printer,
  ExternalLink,
  Minus,
  Pencil,
  Plus,
  Power,
  Search,
  ShoppingCart,
  Trash2,
  UserPlus,
  X,
} from "lucide-react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Badge, Button, CurrencyInput, Drawer, Input, Modal, Select, useToast } from "@/app/components/ui/primitives";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PageHeading as PageTitle, PagedCollection, Table } from "@/app/components/ui/data";
import { useDismissiblePopover } from "@/app/components/ui/use-dismissible-popover";
import { getSupabaseClient } from "@/app/lib/supabase";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { productVocabulary, type ProductExperience } from "@/app/lib/product-experience";
import { presentImportedSourceText } from "@/app/lib/presentation-text";
import { PriceCatalogManagement } from "@/app/components/PriceCatalogManagement";
import { printTicketPdf, type TicketBranding } from "@/app/lib/ticket-pdf";
import { TicketBrandingSettings } from "@/app/components/TicketBrandingSettings";
import { QuoteBrandingSettings } from "@/app/components/QuoteBrandingSettings";
 import { CommercialAssortmentsView } from "@/app/components/CommercialAssortmentsView";
 import { ReceivablesModuleHeader } from "@/app/components/ReceivablesNavigation";
import {
  appendPosQueue,
  getPosMetricP95,
  groupConsecutiveCartChanges,
  readPosCachedValue,
  readPosQueue,
  recordPosMetric,
  removePosQueueItems,
  writePosCache,
  type PosMetricName,
  type PosQueuedCartChange,
} from "@/app/lib/pos-resilience";

type PosLocation = { id: string; name: string; code: string };
type PosRegister = { id: string; location_id: string; name: string; code: string; currency_code: string };
type PaymentMethod = { id: string; code: string; name: string; settlement_kind: "cash_drawer" | "external" };
type ReceivableFinancialAccount = { id: string; alias: string; institution_name: string; currency_code: string; masked_ending: string };
type CashSession = { id: string; cash_register_id: string; location_id: string; status: string; opening_amount: number; opened_at?: string };
type PosContext = { locations: PosLocation[]; registers: PosRegister[]; payment_methods: PaymentMethod[]; own_open_session: CashSession | null };
type ProductSearchItem = { product_id: string; code: string | null; name: string; unit: string | null; inventory_tracked: boolean; quantity_on_hand: number; base_price_amount?: number; tax_amount?: number; price_amount: number; currency_code: string };
type PosLocationStockItem = { location_id: string; location_code: string; location_name: string; quantity_on_hand: number; updated_at: string | null };
type PosLocationStock = { product_name: string; unit: string | null; items: PosLocationStockItem[]; total: number; page: number; page_size: number };
type BlockedProductSearchItem = ProductSearchItem & { blockers: string[]; other_location_stock_count?: number; other_location_stock_quantity?: number };
type Customer = { id: string; code: string; display_name: string; credit_enabled: boolean; price_list_id?: string | null; credit_limit?: number; credit_term_days?: number; outstanding_amount?: number; overdue_amount?: number; next_due_date?: string | null; available_credit?: number; migration_status?: "manual" | "promoted" | "adjustment_pending"; alpha_external_code?: string | null };
type CustomerAddress = { id: string; label: string; address_line: string; neighborhood: string | null; municipality: string | null; state_name: string | null; postal_code: string | null; is_primary: boolean };
type CustomerContact = { id: string; display_name: string; role_name: string | null; phone: string | null; email: string | null; is_primary: boolean };
type CustomerReceivable = { id: string; reference: string | null; issued_at: string; due_date: string; original_amount: number; outstanding_amount: number };
type ReceivableDocument = CustomerReceivable & { currency_code: string | null };
type FifoPreview = { receivable_id: string; reference: string | null; due_date: string; amount_applied: number; remaining_after: number };
type ReceivableReceipt = { folio: string; issued_at: string; customer_name: string; payment_method: string; payment_reference: string | null; amount: number; currency_code: string; applications: Array<{ reference: string | null; amount_applied: number }> };
type CustomerMigrationAdjustment = { id: string; field_name: string; previous_value: unknown; proposed_value: unknown; reason: string; evidence: string; status: string; created_at: string; decision_reason: string | null };
type CashDashboard = { cash_session_id: string; status: string; opened_at: string; register_name: string; register_code: string; location_name: string; location_code: string; cashier_name: string; currency_code: string; opening_amount: number; expected_cash: number; cash_sales: number; receivable_payments: number; paid_in: number; paid_out: number };

const cashMovementLabels: Record<string, string> = {
  cash_sale: "Venta en efectivo",
  paid_in: "Ingreso de efectivo",
  paid_out: "Salida de efectivo",
  receivable_payment: "Cobro de cuenta pendiente",
  opening: "Apertura de caja",
  closing: "Cierre de caja",
};

function cashMovementLabel(type: string) {
  return cashMovementLabels[type] ?? "Movimiento de caja";
}
type ReceivablesSummary = { document_count: number; outstanding_amount: number; overdue_count: number; overdue_amount: number; next_due_date?: string | null };
type ReceivablesPage = { items?: ReceivableDocument[]; summary?: ReceivablesSummary; pagination?: { page: number; page_size: number; total: number } };
type ReceivableCustomerContext = { customer: { id: string; code: string; display_name: string; tax_id: string | null; payment_manager: string | null; credit_term_days: number | null }; contact: CustomerContact | null; address: CustomerAddress | null; summary: ReceivablesSummary };
type CustomerMaster = { id: string; code: string; display_name: string; tax_id: string | null; customer_type: "persona_fisica" | "persona_moral" | null; notes: string | null; is_active: boolean; is_imported: boolean; source_reference: string | null; migration_status: string; addresses: CustomerAddress[]; contacts: CustomerContact[]; commercial: { price_list_id: string | null; price_list_name: string | null; payment_manager: string | null; sales_agent: string | null; credit_enabled: boolean | null; credit_limit: number | null; credit_term_days: number | null; outstanding_amount: number | null; available_credit: number | null }; receivables_summary: ReceivablesSummary | null; open_receivables: CustomerReceivable[] };
type PriceTier = { id: string; name: string; min_quantity: number; max_quantity: number | null; amount: number; price_list_id: string };
type CartItem = { cart_item_id: string; product_id: string; code: string | null; name: string; unit: string | null; quantity: number; quantity_on_hand: number; inventory_tracked: boolean; unit_price_amount: number; price_tier_id?: string | null; price_tier_name?: string | null; price_tier_min_quantity?: number | null; price_tier_max_quantity?: number | null; price_tier_mode?: "automatic" | "manual"; available_price_tiers?: PriceTier[]; discount_percent: number; gross_amount: number; discount_amount: number; tax_amount: number; total_amount: number };
type VolumeDiscountTier = { tier_number: number; min_quantity: number; max_quantity: number | null; discount_percent: number; is_active: boolean };
type CartQuote = { cart_id: string; revision: number; customer_id: string | null; currency_code: string | null; price_list_id: string | null; price_list_name: string | null; price_list_override_id: string | null; price_list_overridden: boolean; items: CartItem[]; subtotal_amount: number; discount_amount: number; tax_amount: number; total_amount: number; can_checkout: boolean; pending_discount_approval: boolean };
type HeldSaleCart = { cart_id: string; revision: number; customer_id: string | null; customer_name: string | null; held_at: string; item_count: number; unit_count: number; preview_items: string[]; pending_discount_approval: boolean };
type HeldSaleCartPage = { items: HeldSaleCart[]; total: number; page: number; page_size: number };
type SaleRow = { sale_id: string; folio: string; location_id: string; sale_type: "cash" | "credit"; source_kind: "operational" | "alpha_historical"; customer_name: string | null; currency_code: string; total_amount: number; returned_amount: number; cancelled: boolean; completed_at: string };
type SaleTicketState = { saleId: string; sourceKind: SaleRow["source_kind"]; payload: Record<string, unknown>; cancellation: { id: string; reason: string; cancelled_at: string } | null };
type SaleReturnContext = {
  sale: { id: string; folio: string; sale_type: "cash" | "credit"; currency_code: string; total_amount: number; completed_at: string; location_id: string };
  items: Array<{ sale_item_id: string; product_id: string; product_code: string; product_name: string; unit_name: string | null; sold_quantity: number; returned_quantity: number; available_quantity: number; unit_price_amount: number; total_amount: number; inventory_tracked: boolean }>;
  returns: Array<{ id: string; reason: string; total_amount: number; financial_adjustment_kind: "cash_refund" | "external_refund" | "receivable_reduction"; external_reference: string | null; returned_by: string | null; returned_at: string; items: Array<{ sale_item_id: string; product_name: string; quantity: number; restocked: boolean }> }>;
  cancelled: boolean;
  can_process: boolean;
  settlement_kind: "cash_drawer" | "external" | "receivable";
  own_open_cash_session_id: string | null;
};

function money(value: number | string | null | undefined, currency?: string | null) {
  const currencyCode = /^[A-Z]{3}$/.test(currency ?? "") ? currency! : "MXN";
  return new Intl.NumberFormat("es-MX", { style: "currency", currency: currencyCode, minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function volumeDiscountLabel(items: CartItem[]) {
  const discounts = [...new Set(items.map((item) => Number(item.discount_percent ?? 0)).filter((percent) => percent > 0))].sort((a, b) => a - b);
  if (!discounts.length) return null;
  const formatPercent = (percent: number) => new Intl.NumberFormat("es-MX", { maximumFractionDigits: 2 }).format(percent);
  return discounts.length === 1
    ? `−${formatPercent(discounts[0])}% por volumen`
    : `−${formatPercent(discounts[0])}–${formatPercent(discounts[discounts.length - 1])}% por volumen`;
}

function priceTierRange(tier: PriceTier) {
  return tier.max_quantity === null ? `${tier.min_quantity}+ piezas` : `${tier.min_quantity}–${tier.max_quantity} piezas`;
}

function automaticPriceTier(item: CartItem) {
  return (item.available_price_tiers ?? []).find((tier) => item.quantity >= tier.min_quantity && (tier.max_quantity === null || item.quantity <= tier.max_quantity)) ?? null;
}

function dateTime(value: string) {
  return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}

function heldFor(value: string) {
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 60000));
  if (minutes < 1) return "Hace menos de un minuto";
  if (minutes < 60) return `Hace ${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return `Hace ${hours} h ${minutes % 60} min`;
}

function Pagination({ page, total, pageSize, onChange }: { page: number; total: number; pageSize: number; onChange: (page: number) => void }) {
  return <DataPagination page={page} total={total} pageSize={pageSize} onChange={onChange} label="movimientos" />;
}

function rpcError(error: { message?: string } | null, fallback: string) {
  return presentImportedSourceText(error?.message || fallback);
}

async function printCompanyTicket(companyId: string, ticket: Record<string, unknown>) {
  const printWindow = window.open("", "satrapy-ticket-print", "popup,width=480,height=720");
  if (!printWindow) throw new Error("El navegador bloqueó la ventana de impresión.");
  printWindow.document.write("<title>Preparando ticket…</title><p style=\"font-family:system-ui;padding:24px\">Preparando ticket…</p>");
  const { data } = await getSupabaseClient().rpc("get_ticket_branding", { p_company_id: companyId });
  const branding = data as (TicketBranding & { logo_path?: string | null }) | null;
  const identity = ticket.identity as { company?: { logo_path?: string | null } } | undefined;
  const logoPath = identity?.company?.logo_path ?? branding?.logo_path;
  const logoUrl = logoPath ? getSupabaseClient().storage.from("ticket-branding-assets").getPublicUrl(logoPath).data.publicUrl : null;
  await printTicketPdf(ticket, { ...branding, logo_url: logoUrl }, printWindow);
}

function posBlockerLabel(code: string) {
  const labels: Record<string, string> = { outside_assortment: "Fuera del surtido de esta sucursal", inactive: "Producto inactivo", not_sellable: "No habilitado para venta", commercial_review_required: "Revisión comercial pendiente", inventory_setup_required: "Inventario pendiente de preparar", missing_sales_unit: "Falta unidad de venta", missing_tax_category: "Falta categoría fiscal", missing_current_tax_rate: "Falta impuesto vigente", missing_or_zero_price: "Falta precio vigente", out_of_stock: "Sin existencia en esta sucursal" };
  return labels[code] ?? code.replaceAll("_", " ");
}

function otherLocationStockStatus(quantity: number) {
  if (quantity <= 0) return { label: "Sin existencia", tone: "empty" };
  if (quantity <= 3) return { label: "Bajo", tone: "low" };
  return { label: "Disponible", tone: "available" };
}

function highlightSearchMatch(value: string, query: string): ReactNode {
  const term = query.trim();
  if (!term) return value;
  const start = value.toLocaleLowerCase("es-MX").indexOf(term.toLocaleLowerCase("es-MX"));
  if (start < 0) return value;
  const end = start + term.length;
  return <>{value.slice(0, start)}<mark>{value.slice(start, end)}</mark>{value.slice(end)}</>;
}

function nextRoundCashAmount(total: number) {
  const denominations = [100, 200, 500, 1000, 2000, 5000, 10000];
  return denominations.find((amount) => amount >= total) ?? Math.ceil(total / 1000) * 1000;
}

function adjustmentFieldLabel(field: string) {
  return ({ display_name: "Nombre", tax_id: "RFC", phone: "Teléfono principal", address_line: "Dirección principal", contact_name: "Contacto principal", credit_limit: "Límite de crédito", credit_term_days: "Días de crédito", outstanding_amount: "Saldo" } as Record<string, string>)[field] ?? field;
}

async function getPosStorageScope(companyId: string) {
  const { data } = await getSupabaseClient().auth.getSession();
  const userId = data.session?.user.id;
  return userId ? `pos:${companyId}:${userId}` : null;
}

function mergeCachedProducts(current: ProductSearchItem[], incoming: ProductSearchItem[]) {
  const merged = new Map(current.map((product) => [product.product_id, product]));
  for (const product of incoming) merged.set(product.product_id, product);
  return [...merged.values()].slice(-2000);
}

function searchCachedProducts(products: ProductSearchItem[], query: string) {
  const normalized = query.trim().toLocaleLowerCase("es-MX");
  if (!normalized) return products.slice(0, 30);
  return products.filter((product) => [product.code, product.name, product.unit].some((value) => value?.toLocaleLowerCase("es-MX").includes(normalized))).slice(0, 30);
}

function optimisticCartChange(current: CartQuote, product: ProductSearchItem, delta: number): CartQuote {
  const existing = current.items.find((item) => item.product_id === product.product_id);
  const nextQuantity = Math.max(0, Number(existing?.quantity ?? 0) + delta);
  let items = current.items;
  if (nextQuantity > 0) {
    const originalQuantity = Number(existing?.quantity ?? 0);
    const grossUnit = existing && originalQuantity > 0 ? existing.gross_amount / originalQuantity : Number(product.base_price_amount ?? Math.max(0, product.price_amount - Number(product.tax_amount ?? 0)));
    const discountUnit = existing && originalQuantity > 0 ? existing.discount_amount / originalQuantity : 0;
    const taxUnit = existing && originalQuantity > 0 ? existing.tax_amount / originalQuantity : Number(product.tax_amount ?? Math.max(0, product.price_amount - grossUnit));
    const totalUnit = existing && originalQuantity > 0 ? existing.total_amount / originalQuantity : Number(product.price_amount);
    const updatedItem = {
      cart_item_id: existing?.cart_item_id ?? `pending:${product.product_id}`,
      product_id: product.product_id,
      code: existing?.code ?? product.code,
      name: existing?.name ?? product.name,
      unit: existing?.unit ?? product.unit,
      quantity: nextQuantity,
      quantity_on_hand: product.quantity_on_hand,
      inventory_tracked: product.inventory_tracked,
      unit_price_amount: existing?.unit_price_amount ?? Number(product.base_price_amount ?? product.price_amount),
      discount_percent: existing?.discount_percent ?? 0,
      gross_amount: grossUnit * nextQuantity,
      discount_amount: discountUnit * nextQuantity,
      tax_amount: taxUnit * nextQuantity,
      total_amount: totalUnit * nextQuantity,
    };
    items = existing ? current.items.map((item) => item.product_id === product.product_id ? updatedItem : item) : [...current.items, updatedItem];
  } else if (existing) {
    items = current.items.filter((item) => item.product_id !== product.product_id);
  }
  const subtotal = items.reduce((total, item) => total + Number(item.gross_amount ?? 0), 0);
  const discount = items.reduce((total, item) => total + Number(item.discount_amount ?? 0), 0);
  const tax = items.reduce((total, item) => total + Number(item.tax_amount ?? 0), 0);
  const total = items.reduce((sum, item) => sum + Number(item.total_amount ?? 0), 0);
  return { ...current, items, subtotal_amount: subtotal, discount_amount: discount, tax_amount: tax, total_amount: total };
}

function usePosContext(companyId: string) {
  const [context, setContext] = useState<PosContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const load = useCallback(async () => {
    setLoading(true);
    const scope = await getPosStorageScope(companyId);
    if (typeof navigator !== "undefined" && !navigator.onLine && scope) {
      const cached = await readPosCachedValue<PosContext>(scope, "context");
      if (cached) {
        setContext(cached); setError(null); setStale(true); setLoading(false); return;
      }
    }
    const { data, error: loadError } = await getSupabaseClient().rpc("get_pos_context", { p_company_id: companyId });
    if (loadError) {
      const cached = scope ? await readPosCachedValue<PosContext>(scope, "context") : null;
      if (cached) { setContext(cached); setError(null); setStale(true); }
      else { setError(rpcError(loadError, "No se pudo cargar el contexto POS.")); setContext(null); setStale(false); }
    } else {
      setContext(data as PosContext);
      setError(null);
      setStale(false);
      if (scope) await writePosCache(scope, "context", data as PosContext);
    }
    setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  return { context, loading, error, stale, reload: load };
}

export function PosSalesView({ companyId, companyName, cashierName, permissions, experience="core" }: { companyId: string; companyName: string; cashierName: string; permissions: string[]; experience?: ProductExperience }) {
  const productWords = productVocabulary(experience);
  const unavailableProductsLabel = experience === "restaurant" ? "Platillos no disponibles" : "Productos no disponibles";
  const { toast } = useToast();
  const { context, loading: contextLoading, error: contextError, stale: contextStale, reload: reloadContext } = usePosContext(companyId);
  const [cartId, setCartId] = useState<string | null>(null);
  const [quote, setQuote] = useState<CartQuote | null>(null);
  const [posTab, setPosTab] = useState<"current" | "held">("current");
  const [heldSales, setHeldSales] = useState<HeldSaleCartPage>({ items: [], total: 0, page: 1, page_size: 20 });
  const [heldLoading, setHeldLoading] = useState(false);
  const [heldError, setHeldError] = useState<string | null>(null);
  const [selectedHeldId, setSelectedHeldId] = useState<string | null>(null);
  const [heldPreview, setHeldPreview] = useState<CartQuote | null>(null);
  const [heldPreviewLoading, setHeldPreviewLoading] = useState(false);
  const [resumeCart, setResumeCart] = useState<HeldSaleCart | null>(null);
  const [discardHeldCart, setDiscardHeldCart] = useState<HeldSaleCart | null>(null);
  const [search, setSearch] = useState("");
  const [products, setProducts] = useState<ProductSearchItem[]>([]);
  const [productTotal, setProductTotal] = useState(0);
  const [productPage, setProductPage] = useState(1);
  const [productLoading, setProductLoading] = useState(false);
  const [productLoadingMore, setProductLoadingMore] = useState(false);
  const [blockedProducts, setBlockedProducts] = useState<BlockedProductSearchItem[]>([]);
  const [blockedTotal, setBlockedTotal] = useState(0);
  const [blockedOpen, setBlockedOpen] = useState(false);
  const [blockedLoading, setBlockedLoading] = useState(false);
  const [customerQuery, setCustomerQuery] = useState("");
  const [customerResults, setCustomerResults] = useState<Customer[]>([]);
  const [customerPickerOpen, setCustomerPickerOpen] = useState(false);
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [saleType, setSaleType] = useState<"cash" | "credit" | "deferred">("cash");
  const [paymentMethodId, setPaymentMethodId] = useState("");
  const [received, setReceived] = useState("");
  const [paymentReference, setPaymentReference] = useState("");
  const [expectedDeliveryDate, setExpectedDeliveryDate] = useState("");
  const [busy, setBusy] = useState(false);
  const [quickCustomerOpen, setQuickCustomerOpen] = useState(false);
  const [quickCustomerName, setQuickCustomerName] = useState("");
  const [quickCustomerPhone, setQuickCustomerPhone] = useState("");
  const [quickCustomerTaxId, setQuickCustomerTaxId] = useState("");
  const [ticket, setTicket] = useState<{ folio: string; ticket: Record<string, unknown> } | null>(null);
  const [ticketDownloading, setTicketDownloading] = useState(false);
  const [stockProduct, setStockProduct] = useState<ProductSearchItem | null>(null);
  const [locationStock, setLocationStock] = useState<PosLocationStock | null>(null);
  const [locationStockLoading, setLocationStockLoading] = useState(false);
  const [discountOpen, setDiscountOpen] = useState(false);
  const [discountPercent, setDiscountPercent] = useState("");
  const [discountReason, setDiscountReason] = useState("");
  const [discardCartOpen, setDiscardCartOpen] = useState(false);
  const [online, setOnline] = useState(() => typeof navigator === "undefined" || navigator.onLine);
  const [storageScope, setStorageScope] = useState<string | null>(null);
  const [pendingChanges, setPendingChanges] = useState(0);
  const [queueVersion, setQueueVersion] = useState(0);
  const [syncing, setSyncing] = useState(false);
  const [showSlowSyncStatus, setShowSlowSyncStatus] = useState(false);
  const [syncConflict, setSyncConflict] = useState<{ message: string; discardIds?: string[] } | null>(null);
  const [metricP95, setMetricP95] = useState<Record<PosMetricName, number | null>>({ search: null, add_item: null, checkout: null });
  const searchRef = useRef<HTMLInputElement>(null);
  const customerRef = useRef<HTMLInputElement>(null);
  const customerPickerRef = useRef<HTMLDivElement>(null);
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const cartRecoveryInFlight = useRef(false);
  const completeRef = useRef<() => void>(() => undefined);
  const productRequestRef = useRef(0);
  const blockedRequestRef = useRef(0);
  const quoteRef = useRef<CartQuote | null>(null);
  const authoritativeQuoteRef = useRef<CartQuote | null>(null);
  const syncInFlightRef = useRef(false);
  const restoredQueueCartRef = useRef<string | null>(null);
  const scannerBatchRef = useRef<{ cartId: string; productId: string; requestId: string; lastAt: number } | null>(null);

  const ownSession = context?.own_open_session?.status === "open" ? context.own_open_session : null;
  const selectedRegister = context?.registers.find((item) => item.id === ownSession?.cash_register_id) ?? null;
  const selectedLocation = context?.locations.find((item) => item.id === ownSession?.location_id) ?? null;
  const paymentMethods = context?.payment_methods ?? [];
  const selectedPayment = paymentMethods.find((method) => method.id === paymentMethodId) ?? null;
  const receivedAmount = Number(received.replace(",", "."));
  const saleTotal = Number(quote?.total_amount ?? 0);
  const discountLabel = useMemo(() => volumeDiscountLabel(quote?.items ?? []), [quote?.items]);
  const isCashPayment = saleType === "cash" && selectedPayment?.settlement_kind === "cash_drawer";
  const validReceivedAmount = Number.isFinite(receivedAmount) && receivedAmount >= saleTotal;
  const changeAmount = isCashPayment && validReceivedAmount ? receivedAmount - saleTotal : 0;
  const validOrderPayment = received === "" || (Number.isFinite(receivedAmount) && receivedAmount >= 0 && receivedAmount <= saleTotal);
  const quickCashAmounts = useMemo(() => {
    if (saleTotal <= 0) return { fixedAmounts: [], roundedAmount: null };
    const fixedAmounts = [100, 200, 500].filter((amount) => amount >= saleTotal);
    const roundedAmount = nextRoundCashAmount(saleTotal);
    return { fixedAmounts, roundedAmount: fixedAmounts.includes(roundedAmount) ? null : roundedAmount };
  }, [saleTotal]);
  const otherLocationStockItems = useMemo(() => (locationStock?.items ?? []).slice().sort((a, b) => {
    const aQuantity = Number(a.quantity_on_hand);
    const bQuantity = Number(b.quantity_on_hand);
    const aHasStock = aQuantity > 0;
    const bHasStock = bQuantity > 0;
    if (aHasStock !== bHasStock) return aHasStock ? -1 : 1;
    if (aHasStock && bHasStock && aQuantity !== bQuantity) return bQuantity - aQuantity;
    return a.location_name.localeCompare(b.location_name, "es-MX");
  }), [locationStock]);
  const connectionDegraded = !online || contextStale;
  const checkoutReady = online && !contextStale && pendingChanges === 0 && !syncing && !syncConflict;

  useEffect(() => {
    if (connectionDegraded || (!pendingChanges && !syncing)) {
      const timer = window.setTimeout(() => setShowSlowSyncStatus(false), 0);
      return () => window.clearTimeout(timer);
    }
    const timer = window.setTimeout(() => setShowSlowSyncStatus(true), 1500);
    return () => window.clearTimeout(timer);
  }, [connectionDegraded, pendingChanges, syncing]);

  useEffect(() => { quoteRef.current = quote; }, [quote]);

  useEffect(() => {
    const onOnline = () => setOnline(true);
    const onOffline = () => setOnline(false);
    window.addEventListener("online", onOnline);
    window.addEventListener("offline", onOffline);
    return () => { window.removeEventListener("online", onOnline); window.removeEventListener("offline", onOffline); };
  }, []);

  useEffect(() => {
    let active = true;
    void getPosStorageScope(companyId).then(async (scope) => {
      if (!active || !scope) return;
      setStorageScope(scope);
      const [queue, metrics] = await Promise.all([readPosQueue<ProductSearchItem>(scope), getPosMetricP95(scope)]);
      if (!active) return;
      setPendingChanges(queue.length);
      setMetricP95(metrics);
    });
    return () => { active = false; };
  }, [companyId]);

  useEffect(() => {
    if (!context) return;
    void Promise.resolve().then(() => {
      setPaymentMethodId((current) => context.payment_methods.some((method) => method.id === current) ? current : context.payment_methods[0]?.id ?? "");
    });
  }, [context]);

  const loadQuote = useCallback(async (id: string) => {
    if (!online && storageScope) {
      const cached = await readPosCachedValue<CartQuote>(storageScope, `cart:${id}`);
      if (cached) { setQuote(cached); quoteRef.current = cached; authoritativeQuoteRef.current = cached; return; }
    }
    const { data, error } = await getSupabaseClient().rpc("quote_sale_cart", { p_cart_id: id });
    if (error) {
      const cached = storageScope ? await readPosCachedValue<CartQuote>(storageScope, `cart:${id}`) : null;
      if (cached) { setQuote(cached); quoteRef.current = cached; authoritativeQuoteRef.current = cached; return; }
      toast({ title: "No pudimos cotizar el carrito", description: rpcError(error, "Intenta nuevamente."), tone: "error" });
      return;
    }
    setQuote(data as CartQuote);
    quoteRef.current = data as CartQuote;
    authoritativeQuoteRef.current = data as CartQuote;
    if (storageScope) await writePosCache(storageScope, `cart:${id}`, data as CartQuote);
  }, [online, storageScope, toast]);

  const loadHeldSales = useCallback(async (page = 1) => {
    if (!ownSession || !online) {
      setHeldSales({ items: [], total: 0, page: 1, page_size: 20 });
      setSelectedHeldId(null);
      setHeldPreview(null);
      return;
    }
    setHeldLoading(true);
    const { data, error } = await getSupabaseClient().rpc("list_own_held_sale_carts", {
      p_cash_session_id: ownSession.id,
      p_page: page,
      p_page_size: 20,
    });
    if (error) {
      setHeldError(rpcError(error, "No se pudieron cargar las ventas en espera."));
    } else {
      const next = data as HeldSaleCartPage;
      setHeldSales(next);
      setHeldError(null);
      setSelectedHeldId((current) => next.items.some((item) => item.cart_id === current) ? current : next.items[0]?.cart_id ?? null);
    }
    setHeldLoading(false);
  }, [online, ownSession]);

  useEffect(() => { void Promise.resolve().then(() => loadHeldSales()); }, [loadHeldSales]);

  useEffect(() => {
    if (!selectedHeldId || !online) { void Promise.resolve().then(() => setHeldPreview(null)); return; }
    let active = true;
    void Promise.resolve().then(async () => {
      setHeldPreviewLoading(true);
      const { data, error } = await getSupabaseClient().rpc("quote_sale_cart", { p_cart_id: selectedHeldId });
      if (!active) return;
      setHeldPreview(error ? null : data as CartQuote);
      if (error) setHeldError(rpcError(error, "La venta necesita revisión antes de retomarla."));
      setHeldPreviewLoading(false);
    });
    return () => { active = false; };
  }, [online, selectedHeldId]);

  const ensureCart = useCallback(async () => {
    if (cartRecoveryInFlight.current) return;
    cartRecoveryInFlight.current = true;
    try {
      if (!ownSession) { setCartId(null); setQuote(null); return; }
      if (!online && storageScope) {
        const cached = await readPosCachedValue<{ cartId: string; quote: CartQuote }>(storageScope, "active-cart");
        if (cached) { setCartId(cached.cartId); setQuote(cached.quote); quoteRef.current = cached.quote; authoritativeQuoteRef.current = cached.quote; }
        return;
      }
      const { data, error } = await getSupabaseClient().rpc("get_or_create_sale_cart", { p_company_id: companyId, p_cash_session_id: ownSession.id });
      if (error) {
        const cached = storageScope ? await readPosCachedValue<{ cartId: string; quote: CartQuote }>(storageScope, "active-cart") : null;
        if (cached) { setCartId(cached.cartId); setQuote(cached.quote); quoteRef.current = cached.quote; authoritativeQuoteRef.current = cached.quote; return; }
        setCartId(null); setQuote(null); toast({ title: "No se pudo recuperar tu sesión", description: rpcError(error, "Abre una caja propia antes de vender."), tone: "error" }); return;
      }
      const nextCartId = (data as { cart_id: string }).cart_id;
      setCartId(nextCartId);
      await loadQuote(nextCartId);
      if (storageScope && quoteRef.current) await writePosCache(storageScope, "active-cart", { cartId: nextCartId, quote: quoteRef.current });
    } finally {
      cartRecoveryInFlight.current = false;
    }
  }, [companyId, loadQuote, online, ownSession, storageScope, toast]);

  useEffect(() => { void Promise.resolve().then(ensureCart); }, [ensureCart]);

  useEffect(() => {
    if (!cartId || !selectedRegister) {
      productRequestRef.current += 1;
      void Promise.resolve().then(() => { setProducts([]); setProductTotal(0); setProductPage(1); setProductLoading(false); setProductLoadingMore(false); });
      return;
    }
    const request = ++productRequestRef.current;
    const timer = window.setTimeout(async () => {
      setProductLoading(true);
      setProductLoadingMore(false);
      const startedAt = performance.now();
      const catalogKey = `catalog:${selectedRegister.location_id}:${quote?.price_list_id ?? customer?.id ?? "default"}`;
      if (!online && storageScope) {
        const cached = (await readPosCachedValue<ProductSearchItem[]>(storageScope, catalogKey)) ?? [];
        if (request !== productRequestRef.current) return;
        const matches = searchCachedProducts(cached, search);
        setProducts(matches); setProductTotal(matches.length); setProductPage(1); setProductLoading(false);
        return;
      }
      const { data, error } = await getSupabaseClient().rpc("search_pos_cart_products", {
        p_cart_id: cartId,
        p_query: search || null,
        p_page: 1,
        p_page_size: 30,
      });
      if (request !== productRequestRef.current) return;
      const result = data as { items?: ProductSearchItem[]; total?: number; page?: number } | null;
      if (!error) {
        const items = result?.items ?? [];
        setProducts(items);
        setProductTotal(result?.total ?? 0);
        setProductPage(result?.page ?? 1);
        if (storageScope) {
          const cached = (await readPosCachedValue<ProductSearchItem[]>(storageScope, catalogKey)) ?? [];
          await writePosCache(storageScope, catalogKey, mergeCachedProducts(cached, items));
          setMetricP95(await recordPosMetric(storageScope, { name: "search", durationMs: performance.now() - startedAt, recordedAt: new Date().toISOString(), network: "online" }));
        }
      } else {
        const cached = storageScope ? (await readPosCachedValue<ProductSearchItem[]>(storageScope, catalogKey)) ?? [] : [];
        const matches = searchCachedProducts(cached, search);
        setProducts(matches); setProductTotal(matches.length); setProductPage(1);
        if (!matches.length) toast({ title: `No se pudo buscar ${productWords.plural}`, description: "Revisa la conexión e intenta nuevamente.", tone: "error" });
      }
      setProductLoading(false);
    }, search.trim() ? 120 : 0);
    return () => window.clearTimeout(timer);
  }, [cartId, companyId, customer?.id, online, productWords.plural, quote?.price_list_id, search, selectedRegister, storageScope, toast]);

  async function loadMoreProducts() {
    if (!online || !cartId || !selectedRegister || productLoading || productLoadingMore || products.length >= productTotal) return;
    const request = ++productRequestRef.current;
    const nextPage = productPage + 1;
    setProductLoadingMore(true);
    const { data, error } = await getSupabaseClient().rpc("search_pos_cart_products", {
      p_cart_id: cartId,
      p_query: search || null,
      p_page: nextPage,
      p_page_size: 30,
    });
    if (request !== productRequestRef.current) return;
    if (error) {
      toast({ title: `No se pudieron cargar más ${productWords.plural}`, description: rpcError(error, `Los ${productWords.plural} ya visibles permanecen disponibles.`), tone: "error" });
    } else {
      const result = data as { items?: ProductSearchItem[]; total?: number; page?: number } | null;
      setProducts((current) => {
        const merged = new Map(current.map((item) => [item.product_id, item]));
        for (const item of result?.items ?? []) merged.set(item.product_id, item);
        return [...merged.values()];
      });
      setProductTotal(result?.total ?? productTotal);
      setProductPage(result?.page ?? nextPage);
    }
    setProductLoadingMore(false);
  }

  useEffect(() => {
    if (!online || !selectedRegister || !search.trim()) {
      blockedRequestRef.current += 1;
      void Promise.resolve().then(() => { setBlockedOpen(false); setBlockedProducts([]); setBlockedTotal(0); setBlockedLoading(false); });
      return;
    }
    const request = ++blockedRequestRef.current;
    const timer = window.setTimeout(async () => {
      setBlockedLoading(true);
      const { data, error } = await getSupabaseClient().rpc("search_pos_cart_blocked_products", { p_cart_id: cartId, p_query: search.trim(), p_page: 1, p_page_size: 30 });
      if (request !== blockedRequestRef.current) return;
      if (error) {
        setBlockedProducts([]); setBlockedTotal(0); setBlockedOpen(false);
        toast({ title: `No se pudieron consultar los ${productWords.plural} agotados`, description: rpcError(error, "Intenta nuevamente."), tone: "error" });
      } else {
        const result = data as { items?: BlockedProductSearchItem[]; total?: number } | null;
        setBlockedProducts(result?.items ?? []); setBlockedTotal(result?.total ?? 0); setBlockedOpen(Boolean(result?.items?.length));
      }
      setBlockedLoading(false);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [cartId, online, productWords.plural, quote?.price_list_id, search, selectedRegister, toast]);

  useEffect(() => {
    if (!online || !customerQuery.trim()) { void Promise.resolve().then(() => { setCustomerResults([]); setCustomerPickerOpen(false); }); return; }
    const timer = window.setTimeout(async () => {
      const customerRpc = saleType === "credit" ? "search_sale_customers_credit" : "search_sale_customers";
      const { data, error } = await getSupabaseClient().rpc(customerRpc, { p_company_id: companyId, p_query: customerQuery, p_page: 1, p_page_size: 8 });
      if (error) { setCustomerResults([]); setCustomerPickerOpen(false); toast({ title: "No se pudo buscar clientes", description: rpcError(error, "No tienes acceso al crédito de clientes."), tone: "error" }); }
      else { const items = ((data as { items?: Customer[] })?.items ?? []); setCustomerResults(items); setCustomerPickerOpen(items.length > 0); }
    }, 150);
    return () => window.clearTimeout(timer);
  }, [companyId, customerQuery, online, saleType, toast]);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      if (target?.closest("[role='dialog']")) return;
      if (event.key === "F2") { event.preventDefault(); customerRef.current?.focus(); }
      if (event.key === "F4" && permissions.includes("apply_discount") && quote?.items.length && !busy) {
        event.preventDefault();
        setDiscountOpen(true);
      }
      if (event.key === "F8") {
        if (target?.matches("input, textarea, select, [contenteditable='true']")) return;
        event.preventDefault(); completeRef.current();
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [busy, permissions, quote?.items.length]);
  useDismissiblePopover(customerPickerRef, customerPickerOpen, () => setCustomerPickerOpen(false));

  const syncQueuedChanges = useCallback(async () => {
    if (!online || !storageScope || syncInFlightRef.current) return;
    syncInFlightRef.current = true;
    setSyncing(true);
    try {
      const queued = await readPosQueue<ProductSearchItem>(storageScope);
      setPendingChanges(queued.length);
      let authoritative = authoritativeQuoteRef.current;
      for (const group of groupConsecutiveCartChanges(queued)) {
        if (!authoritative || authoritative.cart_id !== group.cartId) {
          setSyncConflict({ message: "El carrito pendiente pertenece a otra sesión. Revisa la caja activa antes de continuar.", discardIds: group.ids });
          break;
        }
        if (group.quantityDelta === 0) {
          const remaining = await removePosQueueItems<ProductSearchItem>(storageScope, group.ids);
          setPendingChanges(remaining.length);
          continue;
        }
        const startedAt = performance.now();
        const { data, error } = await getSupabaseClient().rpc("change_sale_cart_item_and_quote", {
          p_cart_id: group.cartId,
          p_product_id: group.productId,
          p_quantity_delta: group.quantityDelta,
          p_expected_revision: authoritative.revision,
          p_client_request_id: group.requestId,
        });
        if (error || !data) {
          const message = rpcError(error, "El cambio sigue pendiente de sincronizar.");
          if (/fetch|network|conexi[oó]n/i.test(message)) setOnline(false);
          else setSyncConflict({ message: `${group.product.name}: ${message}`, discardIds: group.ids });
          break;
        }
        authoritative = data as CartQuote;
        authoritativeQuoteRef.current = authoritative;
        const serverItem = authoritative.items.find((item) => item.product_id === group.productId);
        const serverUnitTotal = serverItem && serverItem.quantity > 0 ? serverItem.total_amount / serverItem.quantity : null;
        const configuredDiscountFactor = serverItem && serverItem.discount_percent > 0 && serverItem.discount_percent < 100 ? 1 - serverItem.discount_percent / 100 : 1;
        const comparableServerUnitTotal = serverUnitTotal === null ? null : serverUnitTotal / configuredDiscountFactor;
        if (comparableServerUnitTotal !== null && Math.abs(comparableServerUnitTotal - group.expectedUnitTotal) > 0.01) {
          setSyncConflict({ message: `${group.product.name} cambió de ${money(group.expectedUnitTotal, authoritative.currency_code)} a ${money(comparableServerUnitTotal, authoritative.currency_code)}. Revisa el carrito antes de cobrar.` });
        }
        const remaining = await removePosQueueItems<ProductSearchItem>(storageScope, group.ids);
        setPendingChanges(remaining.length);
        let displayed = authoritative;
        for (const pending of remaining.filter((item) => item.cartId === authoritative?.cart_id)) displayed = optimisticCartChange(displayed, pending.product, pending.quantityDelta);
        setQuote(displayed);
        quoteRef.current = displayed;
        await Promise.all([
          writePosCache(storageScope, `cart:${group.cartId}`, authoritative),
          writePosCache(storageScope, "active-cart", { cartId: group.cartId, quote: authoritative }),
          recordPosMetric(storageScope, { name: "add_item", durationMs: performance.now() - startedAt, recordedAt: new Date().toISOString(), network: "online" }).then(setMetricP95),
        ]);
      }
    } finally {
      syncInFlightRef.current = false;
      setSyncing(false);
    }
  }, [online, storageScope]);

  async function resolveSyncConflict() {
    if (syncConflict?.discardIds?.length && storageScope) {
      const remaining = await removePosQueueItems<ProductSearchItem>(storageScope, syncConflict.discardIds);
      setPendingChanges(remaining.length);
      const authoritative = authoritativeQuoteRef.current;
      if (authoritative) {
        let displayed = authoritative;
        for (const pending of remaining.filter((item) => item.cartId === authoritative.cart_id)) displayed = optimisticCartChange(displayed, pending.product, pending.quantityDelta);
        setQuote(displayed);
        quoteRef.current = displayed;
      }
    }
    setSyncConflict(null);
    setQueueVersion((current) => current + 1);
  }

  useEffect(() => {
    if (!online || !storageScope || !pendingChanges) return;
    const timer = window.setTimeout(() => { void syncQueuedChanges(); }, 110);
    return () => window.clearTimeout(timer);
  }, [online, pendingChanges, queueVersion, storageScope, syncQueuedChanges]);

  useEffect(() => {
    if (!storageScope || !cartId || !quote || restoredQueueCartRef.current === cartId) return;
    restoredQueueCartRef.current = cartId;
    void readPosQueue<ProductSearchItem>(storageScope).then((queue) => {
      let restored = quote;
      for (const change of queue.filter((item) => item.cartId === cartId)) restored = optimisticCartChange(restored, change.product, change.quantityDelta);
      if (queue.length) { setQuote(restored); quoteRef.current = restored; setPendingChanges(queue.length); }
    });
  }, [cartId, quote, storageScope]);

  async function changeItem(productId: string, delta: number, clearProductSearch = false) {
    const currentQuote = quoteRef.current;
    if (!cartId || !currentQuote || !storageScope || delta === 0) return;
    const existing = currentQuote.items.find((item) => item.product_id === productId);
    const product = products.find((item) => item.product_id === productId) ?? (existing ? {
      product_id: existing.product_id,
      code: existing.code,
      name: existing.name,
      unit: existing.unit,
      inventory_tracked: existing.inventory_tracked,
      quantity_on_hand: existing.quantity_on_hand,
      base_price_amount: existing.unit_price_amount,
      tax_amount: existing.quantity > 0 ? existing.tax_amount / existing.quantity : 0,
      price_amount: existing.quantity > 0 ? existing.total_amount / existing.quantity : existing.unit_price_amount,
      currency_code: currentQuote.currency_code ?? "MXN",
    } satisfies ProductSearchItem : null);
    if (!product) return;
    const nextQuantity = Number(existing?.quantity ?? 0) + delta;
    if (nextQuantity < 0 || (product.inventory_tracked && nextQuantity > product.quantity_on_hand)) {
      toast({ title: "Cantidad no disponible", description: "Ajusta la cantidad a la existencia reciente mostrada.", tone: "error" });
      return;
    }
    const now = performance.now();
    const currentBatch = scannerBatchRef.current;
    const requestId = currentBatch && currentBatch.cartId === cartId && currentBatch.productId === productId && now - currentBatch.lastAt <= 110 ? currentBatch.requestId : crypto.randomUUID();
    scannerBatchRef.current = { cartId, productId, requestId, lastAt: now };
    const change: PosQueuedCartChange<ProductSearchItem> = {
      id: crypto.randomUUID(), requestId, companyId, cartId, productId, quantityDelta: delta, product,
      expectedUnitTotal: existing && existing.quantity > 0
        ? (existing.total_amount / existing.quantity) / (existing.discount_percent > 0 && existing.discount_percent < 100 ? 1 - existing.discount_percent / 100 : 1)
        : product.price_amount,
      createdAt: new Date().toISOString(),
    };
    const optimistic = optimisticCartChange(currentQuote, product, delta);
    setQuote(optimistic);
    quoteRef.current = optimistic;
    await appendPosQueue(storageScope, change);
    const queue = await readPosQueue<ProductSearchItem>(storageScope);
    setPendingChanges(queue.length);
    setQueueVersion((current) => current + 1);
    if (clearProductSearch) {
      setSearch("");
      searchRef.current?.focus();
    }
  }

  function setItemQuantity(productId: string, currentQuantity: number, input: HTMLInputElement) {
    const nextQuantity = Number(input.value.replace(",", "."));
    if (!Number.isFinite(nextQuantity) || nextQuantity < 0) {
      input.value = String(currentQuantity);
      toast({ title: "Cantidad inválida", description: "Captura una cantidad igual o mayor que cero.", tone: "error" });
      return;
    }
    if (nextQuantity === currentQuantity) return;
    void changeItem(productId, nextQuantity - currentQuantity);
  }

  async function loadLocationStock(product: ProductSearchItem, page = 1) {
    if (!selectedRegister) return;
    setLocationStockLoading(true);
    const { data, error } = await getSupabaseClient().rpc("list_pos_product_other_location_stock", {
      p_company_id: companyId,
      p_product_id: product.product_id,
      p_current_location_id: selectedRegister.location_id,
      p_page: page,
      p_page_size: 20,
    });
    if (error) {
      toast({ title: "No se pudieron consultar otras sucursales", description: rpcError(error, "Verifica que tengas acceso a inventario."), tone: "error" });
      setStockProduct(null);
      setLocationStock(null);
    } else setLocationStock(data as PosLocationStock);
    setLocationStockLoading(false);
  }

  function openLocationStock(product: ProductSearchItem) {
    setStockProduct(product);
    setLocationStock(null);
    void loadLocationStock(product);
  }

  async function selectCustomer(next: Customer | null) {
    if (!cartId || !quote) return;
    if (saleType === "credit" && next && (!next.credit_enabled || (next.alpha_external_code && next.migration_status !== "promoted"))) {
      toast({ title: "Crédito no disponible", description: "El cliente debe estar promovido y reconciliado para usar crédito.", tone: "error" });
      return;
    }
    setBusy(true);
    const { error } = await getSupabaseClient().rpc("set_sale_cart_customer", { p_cart_id: cartId, p_customer_id: next?.id ?? null, p_expected_revision: quote.revision });
    if (error) toast({ title: "No se pudo asignar el cliente", description: rpcError(error, "Intenta nuevamente."), tone: "error" });
    else { setCustomer(next); setCustomerQuery(""); setCustomerResults([]); setCustomerPickerOpen(false); await loadQuote(cartId); }
    setBusy(false);
  }

  async function selectItemPriceTier(item: CartItem, value: string) {
    if (!cartId || !quote || !online) return;
    const selectedTierId = value === "automatic" ? null : value;
    if ((item.price_tier_mode === "manual" ? item.price_tier_id : null) === selectedTierId) return;
    setBusy(true);
    const { error } = await getSupabaseClient().rpc("set_sale_cart_item_price_tier", {
      p_cart_id: cartId,
      p_cart_item_id: item.cart_item_id,
      p_price_tier_id: selectedTierId,
      p_expected_revision: quote.revision,
    });
    if (error) {
      toast({ title: "No se pudo cambiar el nivel", description: rpcError(error, "La partida conserva su precio anterior."), tone: "error" });
    } else {
      setReceived("");
      await loadQuote(cartId);
    }
    setBusy(false);
  }

  async function createQuickCustomer(event: React.FormEvent) {
    event.preventDefault();
    if (!selectedRegister || !cartId || !quickCustomerName.trim()) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("create_pos_cash_customer", {
      p_company_id: companyId,
      p_location_id: selectedRegister.location_id,
      p_display_name: quickCustomerName.trim(),
      p_tax_id: quickCustomerTaxId.trim() || null,
      p_phone: quickCustomerPhone.trim() || null,
    });
    if (error || !data) {
      toast({ title: "No se pudo crear el cliente", description: rpcError(error, "Verifica nombre, RFC y teléfono."), tone: "error" });
    } else {
      const nextCustomer = data as Customer;
      await selectCustomer(nextCustomer);
      setQuickCustomerOpen(false); setQuickCustomerName(""); setQuickCustomerPhone(""); setQuickCustomerTaxId("");
      toast({ title: "Cliente creado", description: "Quedó seleccionado para esta venta y permanece de contado.", tone: "success" });
    }
    setBusy(false);
  }

  async function complete() {
    if (!cartId || !quote || !quote.can_checkout) return;
    if (!checkoutReady) {
      toast({ title: "Venta pendiente de sincronizar", description: "Recupera la conexión y resuelve los cambios del carrito antes de cobrar.", tone: "info" });
      return;
    }
    if (saleType === "deferred") {
      if (!customer) {
        toast({ title: "Selecciona un cliente", description: "La orden necesita un cliente para conservar pagos, saldo y entrega.", tone: "error" });
        customerRef.current?.focus();
        return;
      }
      if (!validOrderPayment) {
        toast({ title: "Revisa el pago inicial", description: "Puede ser cero o cualquier importe hasta el total de la orden.", tone: "error" });
        return;
      }
      if (receivedAmount > 0 && (!selectedPayment || (selectedPayment.settlement_kind === "external" && !paymentReference.trim()))) {
        toast({ title: "Completa el pago inicial", description: "Selecciona forma de pago y captura la referencia cuando sea externa.", tone: "error" });
        return;
      }
      setBusy(true);
      const checkoutStartedAt = performance.now();
      const orderFingerprint = JSON.stringify({ cartId, revision: quote.revision, customerId: customer.id, expectedDeliveryDate: expectedDeliveryDate || null, paymentMethodId: receivedAmount > 0 ? paymentMethodId : null, amount: receivedAmount || 0, paymentReference });
      const { data, error } = await getSupabaseClient().rpc("create_sales_order_from_cart", {
        p_company_id: companyId,
        p_cart_id: cartId,
        p_expected_revision: quote.revision,
        p_expected_delivery_date: expectedDeliveryDate || null,
        p_initial_payment_method_id: receivedAmount > 0 ? paymentMethodId : null,
        p_initial_amount: receivedAmount || 0,
        p_payment_reference: paymentReference.trim() || null,
        p_client_request_id: idempotency.get("create-sales-order", orderFingerprint),
      });
      if (storageScope) setMetricP95(await recordPosMetric(storageScope, { name: "checkout", durationMs: performance.now() - checkoutStartedAt, recordedAt: new Date().toISOString(), network: "online" }));
      if (error || !data) {
        toast({ title: "No se creó la orden", description: rpcError(error, "No se hicieron cambios parciales."), tone: "error" });
      } else {
        idempotency.clear("create-sales-order");
        const order = data as { folio: string; paid_amount: number; outstanding_amount: number };
        toast({ title: `Orden ${order.folio} creada`, description: `${money(order.paid_amount)} pagado · ${money(order.outstanding_amount)} pendiente.`, tone: "success" });
        setCustomer(null); setSearch(""); setReceived(""); setPaymentReference(""); setExpectedDeliveryDate(""); setCartId(null); setQuote(null);
        await reloadContext();
        await ensureCart();
      }
      setBusy(false);
      return;
    }
    if (isCashPayment && !validReceivedAmount) {
      toast({ title: "Revisa el efectivo recibido", description: "El importe recibido debe cubrir el total de la venta.", tone: "error" });
      return;
    }
    if (saleType === "cash" && selectedPayment?.settlement_kind === "external" && !paymentReference.trim()) {
      toast({ title: "Falta la autorización", description: "Captura el folio o referencia emitido por la terminal.", tone: "error" });
      return;
    }
    if (saleType === "credit" && (!customer || !customer.credit_enabled || (customer.alpha_external_code && customer.migration_status !== "promoted") || !permissions.includes("view_customer_credit"))) {
      toast({ title: "Selecciona un cliente", description: "El crédito requiere cliente, límite y plazo vigentes.", tone: "error" });
      customerRef.current?.focus();
      return;
    }
    setBusy(true);
    const checkoutStartedAt = performance.now();
    const operationFingerprint = JSON.stringify({ cartId, revision: quote.revision, saleType, paymentMethodId: saleType === "cash" ? paymentMethodId : null, received: saleType === "cash" ? received : null, paymentReference: paymentReference.trim() || null, total: quote.total_amount });
    const { data, error } = await getSupabaseClient().rpc("complete_pos_sale", {
      p_cart_id: cartId,
      p_expected_revision: quote.revision,
      p_sale_type: saleType,
      p_payment_method_id: saleType === "cash" ? paymentMethodId : null,
      p_received_amount: saleType === "cash" && selectedPayment?.settlement_kind === "cash_drawer" ? Number(received || 0) : quote.total_amount,
      p_client_request_id: idempotency.get("complete-sale", operationFingerprint),
      p_payment_reference: saleType === "cash" && selectedPayment?.settlement_kind === "external" ? paymentReference.trim() : null,
    });
    if (storageScope) setMetricP95(await recordPosMetric(storageScope, { name: "checkout", durationMs: performance.now() - checkoutStartedAt, recordedAt: new Date().toISOString(), network: "online" }));
    if (error) {
      toast({ title: "La venta no se confirmó", description: rpcError(error, "No se hicieron cambios parciales."), tone: "error" });
    } else {
      idempotency.clear("complete-sale");
      const result = data as { folio: string; ticket: Record<string, unknown> };
      setTicket(result);
      setCustomer(null); setSearch(""); setReceived(""); setPaymentReference("");
      await reloadContext();
    }
    setBusy(false);
  }
  useEffect(() => { completeRef.current = () => { if (!busy && checkoutReady && quote?.can_checkout && (saleType !== "cash" || Boolean(paymentMethodId))) void complete(); }; });

  function finishTicket() {
    setTicket(null);
    void ensureCart();
    window.setTimeout(() => searchRef.current?.focus(), 0);
  }

  async function requestDiscount(event: React.FormEvent) {
    event.preventDefault();
    if (!cartId || !quote) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("request_cart_discount", {
      p_cart_id: cartId,
      p_scope: "sale",
      p_cart_item_id: null,
      p_percent: Number(discountPercent),
      p_reason: discountReason,
      p_expected_revision: quote.revision,
    });
    if (error) toast({ title: "No se pudo solicitar el descuento", description: rpcError(error, "Verifica el porcentaje y el motivo."), tone: "error" });
    else {
      const status = (data as { status: string }).status;
      toast({ title: status === "approved" ? "Descuento aplicado" : "Descuento pendiente de aprobación", description: status === "approved" ? "El total fue recalculado en el servidor." : "Un usuario autorizado debe aprobarlo antes de cobrar.", tone: status === "approved" ? "success" : "info" });
      setDiscountOpen(false); setDiscountPercent(""); setDiscountReason(""); await loadQuote(cartId);
    }
    setBusy(false);
  }

  async function cancelDiscount() {
    if (!cartId || !quote || pendingChanges > 0) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("cancel_own_cart_discount", {
      p_cart_id: cartId,
      p_expected_revision: quote.revision,
    });
    if (error || !data) {
      toast({ title: "No se pudo quitar el descuento", description: rpcError(error, "Actualiza la venta e intenta nuevamente."), tone: "error" });
    } else {
      const nextQuote = data as CartQuote;
      setQuote(nextQuote);
      quoteRef.current = nextQuote;
      authoritativeQuoteRef.current = nextQuote;
      if (storageScope) await Promise.all([
        writePosCache(storageScope, `cart:${cartId}`, nextQuote),
        writePosCache(storageScope, "active-cart", { cartId, quote: nextQuote }),
      ]);
      toast({ title: "Descuento eliminado", description: "La venta conserva sus productos y vuelve al precio normal.", tone: "success" });
    }
    setBusy(false);
  }

  async function discardCart() {
    if (!cartId || !quote || pendingChanges > 0) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("discard_own_sale_cart", {
      p_cart_id: cartId,
      p_expected_revision: quote.revision,
    });
    if (error || !data) {
      toast({ title: "No se pudo vaciar la venta", description: rpcError(error, "Actualiza la venta e intenta nuevamente."), tone: "error" });
    } else {
      const nextQuote = data as CartQuote;
      setCartId(nextQuote.cart_id);
      setQuote(nextQuote);
      quoteRef.current = nextQuote;
      authoritativeQuoteRef.current = nextQuote;
      setCustomer(null);
      setCustomerQuery("");
      setReceived("");
      setPaymentReference("");
      setDiscountOpen(false);
      setDiscountPercent("");
      setDiscountReason("");
      setDiscardCartOpen(false);
      if (storageScope) await writePosCache(storageScope, "active-cart", { cartId: nextQuote.cart_id, quote: nextQuote });
      toast({ title: "Venta vaciada", description: "Puedes comenzar una venta nueva en la misma caja.", tone: "success" });
      window.setTimeout(() => searchRef.current?.focus(), 0);
    }
    setBusy(false);
  }

  function resetUnconfirmedSettlement() {
    setCustomer(null);
    setCustomerQuery("");
    setCustomerResults([]);
    setCustomerPickerOpen(false);
    setSaleType("cash");
    setReceived("");
    setPaymentReference("");
    setExpectedDeliveryDate("");
    setDiscountOpen(false);
    setDiscountPercent("");
    setDiscountReason("");
  }

  async function holdCurrentSale() {
    if (!cartId || !quote || !quote.items.length || !checkoutReady) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("hold_own_sale_cart", {
      p_cart_id: cartId,
      p_expected_revision: quote.revision,
    });
    if (error || !data) {
      toast({ title: "No se pudo poner la venta en espera", description: rpcError(error, "Actualiza la venta e intenta nuevamente."), tone: "error" });
    } else {
      const result = data as { quote: CartQuote; held_count: number };
      setCartId(result.quote.cart_id);
      setQuote(result.quote);
      quoteRef.current = result.quote;
      authoritativeQuoteRef.current = result.quote;
      resetUnconfirmedSettlement();
      setSearch("");
      setHeldSales((current) => ({ ...current, total: result.held_count }));
      await loadHeldSales();
      if (storageScope) await writePosCache(storageScope, "active-cart", { cartId: result.quote.cart_id, quote: result.quote });
      toast({ title: "Venta en espera", description: "La venta quedó guardada y puedes atender al siguiente cliente.", tone: "success" });
      window.setTimeout(() => searchRef.current?.focus(), 0);
    }
    setBusy(false);
  }

  async function resumeHeldSale(item: HeldSaleCart) {
    if (!cartId || !quote || !checkoutReady) return;
    setBusy(true);
    const { data, error } = await getSupabaseClient().rpc("resume_own_held_sale_cart", {
      p_held_cart_id: item.cart_id,
      p_expected_held_revision: item.revision,
      p_active_cart_id: cartId,
      p_expected_active_revision: quote.revision,
    });
    if (error || !data) {
      toast({ title: "No se pudo retomar la venta", description: rpcError(error, "Actualiza las ventas en espera e intenta nuevamente."), tone: "error" });
      await loadHeldSales();
    } else {
      const result = data as { quote: CartQuote; held_count: number; previous_active_held: boolean };
      setCartId(result.quote.cart_id);
      setQuote(result.quote);
      quoteRef.current = result.quote;
      authoritativeQuoteRef.current = result.quote;
      resetUnconfirmedSettlement();
      if (result.quote.customer_id) {
        const { data: resumedCustomer } = await getSupabaseClient().from("customers").select("id, code, display_name, credit_enabled, price_list_id, credit_limit, credit_term_days, outstanding_amount, migration_status, alpha_external_code").eq("id", result.quote.customer_id).maybeSingle();
        if (resumedCustomer) setCustomer(resumedCustomer as Customer);
      }
      setSearch("");
      setResumeCart(null);
      setPosTab("current");
      setHeldSales((current) => ({ ...current, total: result.held_count }));
      await loadHeldSales();
      if (storageScope) await writePosCache(storageScope, "active-cart", { cartId: result.quote.cart_id, quote: result.quote });
      toast({ title: "Venta retomada", description: result.previous_active_held ? "La venta anterior quedó en espera." : "Revisa productos y total antes de cobrar.", tone: "success" });
      window.setTimeout(() => searchRef.current?.focus(), 0);
    }
    setBusy(false);
  }

  async function discardHeldSale(item: HeldSaleCart) {
    setBusy(true);
    const { error } = await getSupabaseClient().rpc("discard_own_held_sale_cart", {
      p_cart_id: item.cart_id,
      p_expected_revision: item.revision,
    });
    if (error) {
      toast({ title: "No se pudo descartar la venta", description: rpcError(error, "Actualiza las ventas en espera e intenta nuevamente."), tone: "error" });
    } else {
      setDiscardHeldCart(null);
      setHeldPreview(null);
      await loadHeldSales(heldSales.page);
      toast({ title: "Venta descartada", description: "La acción quedó registrada en la auditoría.", tone: "success" });
    }
    setBusy(false);
  }

  async function printCompletedTicket() {
    if (!ticket) return;
    setTicketDownloading(true);
    try {
      await printCompanyTicket(companyId, ticket.ticket);
      toast({ title: "Ticket listo", description: "Se abrió el diálogo de impresión.", tone: "success" });
    } catch {
      toast({ title: "No se pudo generar el ticket", description: "Intenta nuevamente; la venta permanece guardada.", tone: "error" });
    } finally {
      setTicketDownloading(false);
    }
  }

  if (contextLoading) return <div className="content-frame"><DataState loading error={null} hasData={0} empty="">{null}</DataState></div>;
  if (contextError || !context) return <div className="content-frame"><DataState loading={false} error={contextError ?? "No se pudo abrir el POS."} hasData={0} empty="" errorAction={<Button onClick={() => void reloadContext()}>Reintentar</Button>}>{null}</DataState></div>;
  if (!context.registers.length) return <div className="content-frame"><PosEmpty title="No hay cajas configuradas" description="Crea una caja activa y asígnala a una ubicación antes de vender." /></div>;

  return <div className="content-frame pos-page">
    <div className="pos-page__heading"><div><h1>Punto de venta</h1><p>{ownSession && selectedRegister ? `${selectedLocation?.name ?? selectedRegister.code} · ${selectedRegister.name} · ${cashierName}` : companyName}</p></div><Link className="pos-exit-link" href="/satrapy/ventas/historial">Salir del POS</Link></div>
    {(connectionDegraded || showSlowSyncStatus) && <div className="pos-connection-status" role="status" aria-live="polite"><CloudOff size={18} aria-hidden="true" /><div className="pos-connection-status__content"><strong>{connectionDegraded ? "Sin conexión: venta pendiente de sincronizar" : syncing ? "Sincronizando cambios pendientes" : "Venta pendiente de sincronizar"}</strong><small>{connectionDegraded ? "Puedes buscar en caché y preparar el carrito. El cobro, inventario y ticket se habilitan al recuperar la conexión." : `${pendingChanges} cambio${pendingChanges === 1 ? "" : "s"} en cola; el cobro se habilitará al terminar.`}</small></div>{connectionDegraded && <Button size="sm" variant="secondary" onClick={() => { setOnline(navigator.onLine); void reloadContext(); setQueueVersion((current) => current + 1); }}>Reintentar conexión</Button>}</div>}
    {syncConflict && <div className="pos-sync-conflict" role="alert"><AlertCircle size={18} aria-hidden="true" /><div className="pos-connection-status__content"><strong>Revisa el carrito</strong><small>{syncConflict.message}</small></div><Button size="sm" variant="secondary" onClick={() => void resolveSyncConflict()}>{syncConflict.discardIds?.length ? "Descartar cambio pendiente" : "Confirmar revisión"}</Button></div>}
    {!ownSession ? <section className="pos-start-card"><Banknote size={22} /><div><strong>Abre tu caja para iniciar.</strong><span>La apertura requiere un conteo formal por denominación. Si hay varias cajas, la selección se hace explícitamente en Caja.</span></div><Link href="/satrapy/ventas/caja" className="button button--primary">Ir a Caja</Link></section> : <>
      <div className="pos-workspace-tabs" role="tablist" aria-label="Ventas del punto de venta" onKeyDown={(event) => { if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return; event.preventDefault(); const next = posTab === "current" ? "held" : "current"; setPosTab(next); window.requestAnimationFrame(() => document.getElementById(`pos-tab-${next}`)?.focus()); }}>
        <button id="pos-tab-current" type="button" role="tab" aria-selected={posTab === "current"} aria-controls="pos-panel-current" tabIndex={posTab === "current" ? 0 : -1} className={posTab === "current" ? "is-active" : ""} onClick={() => setPosTab("current")}><ShoppingCart size={16} aria-hidden="true" /> Venta actual</button>
        <button id="pos-tab-held" type="button" role="tab" aria-selected={posTab === "held"} aria-controls="pos-panel-held" tabIndex={posTab === "held" ? 0 : -1} className={posTab === "held" ? "is-active" : ""} onClick={() => setPosTab("held")}><Clock3 size={16} aria-hidden="true" /> En espera <span>{heldSales.total}</span></button>
      </div>
      {posTab === "current" ? <div className="pos-shell" id="pos-panel-current" role="tabpanel" aria-labelledby="pos-tab-current">
        <section className="pos-catalog">
          <label className="pos-search-field"><span>Buscar {productWords.plural}</span><div className="pos-search"><Search size={20} aria-hidden="true" /><Input ref={searchRef} value={search} onChange={(event) => setSearch(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && productTotal === 1 && products.length === 1) { event.preventDefault(); void changeItem(products[0].product_id, 1, true); } }} placeholder="Escanea o busca por nombre, SKU o código" aria-label={`Buscar ${productWords.plural}`} autoFocus /><kbd>F2 cliente</kbd></div></label>
          <div className="pos-search-meta" role="status" aria-live="polite"><span>{productLoading ? "Buscando…" : `${products.length} de ${productTotal} resultados${!online ? " en caché" : ""}`}</span><span>Enter agrega la coincidencia única · p95 búsqueda {metricP95.search === null ? "—" : `${Math.round(metricP95.search)} ms`} · agregar {metricP95.add_item === null ? "—" : `${Math.round(metricP95.add_item)} ms`}</span></div>
          <div className="pos-shortcuts" aria-label="Atajos de teclado disponibles"><span><kbd>F2</kbd> Cliente</span>{permissions.includes("apply_discount") && quote?.items.length ? <span><kbd>F4</kbd> Descuento</span> : null}{quote?.items.length ? <><span><kbd>F8</kbd> Cobrar</span><span><kbd>Esc</kbd> Cerrar</span><span><kbd>+</kbd><kbd>−</kbd> Partida enfocada</span></> : null}</div>
          <div className="pos-product-list">
            {products.map((product) => <div className="pos-product-row" key={product.product_id}><button className="pos-product" disabled={busy} onClick={() => void changeItem(product.product_id, 1, true)}><span><strong>{highlightSearchMatch(product.name, search)}</strong><small>{highlightSearchMatch(product.code ?? "Sin código", search)} · {product.unit ?? "Unidad"}</small></span><span className="pos-product__right"><b>{money(product.price_amount, product.currency_code)}</b><small>Precio total</small>{product.inventory_tracked && <em className={product.quantity_on_hand <= 3 ? "is-low" : ""}>{product.quantity_on_hand} disp.</em>}</span></button>{product.inventory_tracked && permissions.includes("view_inventory") && <Button className="pos-product-stock" size="sm" variant="ghost" disabled={busy} onClick={() => openLocationStock(product)}><ClipboardList size={14} /> Otras sucursales</Button>}</div>)}
            {!productLoading && !products.length && <div className="pos-list-empty"><Search size={20} aria-hidden="true" /><strong>{search ? `Sin resultados para “${search}”` : `Sin ${productWords.plural} disponibles`}</strong><span>{search ? "Prueba con otro nombre, SKU o código." : `Los ${productWords.plural} listos para vender aparecerán aquí.`}</span>{search && <Button variant="secondary" size="sm" onClick={() => { setSearch(""); searchRef.current?.focus(); }}>Limpiar búsqueda</Button>}</div>}
            {!productLoading && products.length < productTotal && <Button className="pos-load-more" variant="secondary" loading={productLoadingMore} disabled={busy} onClick={() => void loadMoreProducts()}>Cargar más {productWords.plural}</Button>}
            {blockedLoading && <p className="pos-blocked-loading">Consultando existencias en otras sucursales…</p>}
            {blockedOpen && <section className="pos-blocked-results" aria-label={unavailableProductsLabel}><header><strong>{unavailableProductsLabel}</strong><span>{blockedTotal} coincidencias</span></header>{blockedProducts.map((product) => <article key={product.product_id}><span><strong>{highlightSearchMatch(product.name, search)}</strong><small>{highlightSearchMatch(product.code ?? "Sin código", search)} · {product.unit ?? "Sin unidad"}</small></span><div className="pos-blocked-actions"><div className="pos-blocked-status">{product.inventory_tracked && product.blockers.includes("out_of_stock") && <span className="pos-blocked-local">Agotado aquí</span>}{product.blockers.filter((blocker) => blocker !== "out_of_stock").map((blocker) => <span className="pos-blocked-reason" key={blocker}>{posBlockerLabel(blocker)}</span>)}{product.inventory_tracked && product.blockers.includes("out_of_stock") && permissions.includes("view_inventory") && product.other_location_stock_count !== undefined && <span className={product.other_location_stock_count > 0 ? "pos-blocked-remote" : "pos-blocked-remote is-empty"}>{product.other_location_stock_count > 0 ? `${Number(product.other_location_stock_quantity).toLocaleString("es-MX", { maximumFractionDigits: 3 })} ${product.unit ?? ""} · ${product.other_location_stock_count} sucursal${product.other_location_stock_count === 1 ? "" : "es"}` : "Sin stock en otras sucursales"}</span>}</div>{product.inventory_tracked && product.blockers.includes("out_of_stock") && permissions.includes("view_inventory") && product.other_location_stock_count !== 0 && <Button size="sm" variant="ghost" disabled={busy} onClick={() => openLocationStock(product)}><ClipboardList size={14} /> Ver existencias</Button>}</div></article>)}</section>}
          </div>
        </section>
        <aside className="pos-cart" id="pos-checkout">
          <div className="pos-cart__top"><div className="pos-cart__heading"><span className="eyebrow">Venta actual</span><div className="pos-cart__title-row"><h2>{quote?.items.length ?? 0} {(quote?.items.length ?? 0) === 1 ? "partida" : "partidas"}</h2>{discountLabel && <span className="pos-cart-discount">{discountLabel}</span>}</div></div><span className="pos-cart__actions">{permissions.includes("apply_discount") && (quote?.pending_discount_approval || Number(quote?.discount_amount ?? 0) > 0) ? <Button variant="ghost" size="sm" loading={busy} disabled={!checkoutReady} onClick={() => void cancelDiscount()}>Quitar descuento</Button> : permissions.includes("apply_discount") ? <Button variant="ghost" size="sm" disabled={!checkoutReady || !quote?.items.length} onClick={() => setDiscountOpen(true)}>Aplicar descuento</Button> : null}{Boolean(quote?.items.length) && <Button variant="ghost" size="sm" disabled={!checkoutReady || busy} onClick={() => void holdCurrentSale()}><Clock3 size={14} aria-hidden="true" /> Poner en espera</Button>}{Boolean(quote?.items.length) && <Button variant="ghost" size="sm" disabled={!checkoutReady || busy} onClick={() => setDiscardCartOpen(true)}><Trash2 size={14} aria-hidden="true" /> Vaciar venta</Button>}<Badge tone={pendingChanges ? "warning" : "success"}>{pendingChanges ? `${pendingChanges} pendiente${pendingChanges === 1 ? "" : "s"}` : "Caja abierta"}</Badge></span></div>
          <div ref={customerPickerRef} className="pos-customer-picker"><div className="pos-customer-picker__heading"><span>Cliente</span>{permissions.includes("manage_customers") && <button type="button" onClick={() => setQuickCustomerOpen(true)}><UserPlus size={13} aria-hidden="true" /> Crear cliente</button>}</div><Input ref={customerRef} role="combobox" aria-expanded={customerPickerOpen && customerResults.length > 0} value={customerQuery} onFocus={() => setCustomerPickerOpen(customerResults.length > 0)} onClick={() => setCustomerPickerOpen(customerResults.length > 0)} onChange={(event) => setCustomerQuery(event.target.value)} placeholder={customer ? customer.display_name : "Buscar cliente (F2)"} aria-label="Buscar cliente" aria-controls="pos-customer-options" aria-describedby="pos-customer-status" /><span id="pos-customer-status" className="sr-only" role="status" aria-live="polite">{customerQuery && customerResults.length ? `${customerResults.length} clientes disponibles.` : ""}</span>{customer && <button className="pos-customer-chip" aria-label={`Quitar cliente ${customer.display_name}`} onClick={() => void selectCustomer(null)}><span>{customer.display_name}</span><X size={14} aria-hidden="true" /></button>}{customerPickerOpen && customerResults.length > 0 && <div id="pos-customer-options" className="pos-customer-results" role="listbox">{customerResults.map((item) => <button role="option" aria-selected={customer?.id === item.id} key={item.id} disabled={saleType === "credit" && (!item.credit_enabled || Boolean(item.alpha_external_code && item.migration_status !== "promoted"))} onClick={() => void selectCustomer(item)}><strong>{item.display_name}</strong><small>{item.code}{saleType === "credit" && item.available_credit !== undefined ? ` · crédito disponible ${money(item.available_credit)}` : ""}{item.alpha_external_code && item.migration_status !== "promoted" ? " · migración pendiente" : ""}</small></button>)}</div>}</div>
          {customer && saleType === "credit" && customer.available_credit !== undefined && <div className="pos-credit-alert"><CircleDollarSign size={18} /><div><strong>Crédito disponible</strong><span>{money(customer.available_credit)} · plazo {customer.credit_term_days} días</span></div></div>}
          <div className="pos-cart-lines" role="region" aria-label={`${productWords.pluralTitle} en la venta`} tabIndex={(quote?.items.length ?? 0) > 2 ? 0 : undefined}>{quote?.items.length ? quote.items.map((item) => {
            const automaticTier = automaticPriceTier(item);
            const tiers = item.available_price_tiers ?? [];
            const tierValue = item.price_tier_mode === "manual" && item.price_tier_id ? item.price_tier_id : "automatic";
            const priceTierLabel = item.price_tier_name ? `${item.price_tier_mode === "manual" ? "Manual" : "Automático"}: ${item.price_tier_name}` : null;
            return <article key={item.cart_item_id} tabIndex={0} aria-label={`${item.name}, cantidad ${item.quantity}. Usa más o menos para ajustar la partida.`} onKeyDown={(event) => { if (busy || event.target !== event.currentTarget) return; if (event.key === "+") { event.preventDefault(); void changeItem(item.product_id, 1); } if (event.key === "-") { event.preventDefault(); void changeItem(item.product_id, -1); } }}><div><strong title={item.name}>{item.name}</strong><small>{item.code ?? ""}{priceTierLabel ? <> · <span className={item.price_tier_mode === "manual" ? "pos-price-tier-note is-manual" : "pos-price-tier-note"}>{priceTierLabel}</span></> : null}{priceTierLabel ? " · " : " · "}{money(item.total_amount / item.quantity, quote.currency_code ?? "MXN")} por unidad{item.discount_percent > 0 ? ` · −${item.discount_percent}%` : ""}</small>{tiers.length > 0 && <div className="pos-price-tier-control">{permissions.includes("apply_discount") ? <Select className="pos-price-tier-select" ariaLabel={`Nivel de precio de ${item.name}`} value={tierValue} onValueChange={(value) => void selectItemPriceTier(item, value)} disabled={busy || !online} options={[{ value: "automatic", label: automaticTier ? `Automático · ${automaticTier.name}` : "Automático" }, ...tiers.map((tier) => ({ value: tier.id, label: `${tier.name} · ${priceTierRange(tier)} · ${money(tier.amount, quote.currency_code ?? "MXN")}` }))]} /> : <span className="pos-price-tier-readonly">{priceTierLabel ?? "Precio automático"}</span>}</div>}</div><div className="pos-line-controls"><button aria-label={`Restar ${item.name}`} disabled={busy} onClick={() => void changeItem(item.product_id, -1)}><Minus size={14} aria-hidden="true" /></button><Input key={`${item.cart_item_id}:${quote.revision}`} className="pos-quantity-input" type="number" min="0" max={item.inventory_tracked ? item.quantity_on_hand : undefined} step="any" inputMode="decimal" defaultValue={item.quantity} aria-label={`Cantidad de ${item.name}`} disabled={busy} onBlur={(event) => setItemQuantity(item.product_id, item.quantity, event.currentTarget)} onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); if (event.key === "Escape") { event.currentTarget.value = String(item.quantity); event.currentTarget.blur(); } }} /><button aria-label={`Sumar ${item.name}`} disabled={busy} onClick={() => void changeItem(item.product_id, 1)}><Plus size={14} aria-hidden="true" /></button><strong>{money(item.total_amount, quote.currency_code ?? "MXN")}</strong></div></article>;
          }) : <div className="pos-cart-empty"><ShoppingCart size={22} aria-hidden="true" /><strong>Carrito vacío</strong><span>Busca o escanea un {productWords.singular} para comenzar.</span></div>}</div>
          <div className="pos-settlement">
            <div className="pos-cart-summary"><dl><div><dt>Subtotal</dt><dd>{money(quote?.subtotal_amount, quote?.currency_code ?? "MXN")}</dd></div><div><dt>Descuentos</dt><dd>−{money(quote?.discount_amount, quote?.currency_code ?? "MXN")}</dd></div><div><dt>Impuestos</dt><dd>{money(quote?.tax_amount, quote?.currency_code ?? "MXN")}</dd></div><div className="pos-cart-summary__total"><dt>Total</dt><dd>{money(quote?.total_amount, quote?.currency_code ?? "MXN")}</dd></div></dl></div>
            {quote?.pending_discount_approval && <div className="pos-credit-alert is-blocked"><AlertCircle size={18} /><div><strong>Descuento pendiente</strong><span>Otro usuario autorizado debe aprobarlo antes de cobrar.</span></div></div>}
            <div className="pos-checkout">
            <div className="pos-sale-type" role="group" aria-label="Tipo de venta">
              <button aria-pressed={saleType === "cash"} className={saleType === "cash" ? "is-active" : ""} onClick={() => setSaleType("cash")}>Contado</button>
              {permissions.includes("sell_credit") && <button aria-pressed={saleType === "credit"} className={saleType === "credit" ? "is-active" : ""} onClick={() => setSaleType("credit")}>Crédito</button>}
              {permissions.includes("manage_sales_orders") && <button aria-pressed={saleType === "deferred"} className={saleType === "deferred" ? "is-active" : ""} disabled={Boolean(quote?.price_list_overridden)} title={quote?.price_list_overridden ? "Restaura la lista automática para crear una orden." : undefined} onClick={() => { setSaleType("deferred"); setReceived(""); setPaymentReference(""); }}>Entrega posterior</button>}
            </div>
            {saleType === "cash" && <>
              <Select ariaLabel="Forma de pago" value={paymentMethodId} onValueChange={(value) => { setPaymentMethodId(value); setReceived(""); setPaymentReference(""); }} options={paymentMethods.map((method) => ({ value: method.id, label: method.name }))} />
              {selectedPayment && <div className="pos-payment-context">{selectedPayment.settlement_kind === "cash_drawer" ? <Banknote size={17} /> : <CreditCard size={17} />}<span><strong>{selectedPayment.name}</strong><small>{selectedPayment.settlement_kind === "cash_drawer" ? "Captura el importe entregado por el cliente." : "Confirma el cobro en la terminal antes de completar."}</small></span></div>}
              {selectedPayment?.settlement_kind === "cash_drawer" && <><label className="pos-received">Recibido<Input type="number" min="0" step="0.01" inputMode="decimal" value={received} onChange={(event) => setReceived(event.target.value)} placeholder="0.00" aria-describedby="pos-change-summary" /></label><div id="pos-change-summary" className={`pos-change-summary${received && !validReceivedAmount ? " is-insufficient" : ""}`} aria-live="polite"><span>{received && !validReceivedAmount ? "Falta por recibir" : "Cambio"}</span><strong>{money(received && !validReceivedAmount ? saleTotal - receivedAmount : changeAmount, quote?.currency_code ?? "MXN")}</strong></div>{(quickCashAmounts.fixedAmounts.length > 0 || quickCashAmounts.roundedAmount) && <div className="pos-quick-cash" role="group" aria-label="Importes rápidos de efectivo"><button type="button" disabled={busy} aria-pressed={receivedAmount === saleTotal} onClick={() => setReceived(String(saleTotal))}>Exacto</button>{quickCashAmounts.fixedAmounts.map((amount) => <button type="button" disabled={busy} aria-pressed={receivedAmount === amount} key={amount} onClick={() => setReceived(String(amount))}>{money(amount, quote?.currency_code ?? "MXN")}</button>)}{quickCashAmounts.roundedAmount && <button type="button" disabled={busy} aria-pressed={receivedAmount === quickCashAmounts.roundedAmount} onClick={() => setReceived(String(quickCashAmounts.roundedAmount))}>Siguiente redondo <strong>{money(quickCashAmounts.roundedAmount, quote?.currency_code ?? "MXN")}</strong></button>}</div>}</>}
              {selectedPayment?.settlement_kind === "external" && <label className="pos-payment-reference">Autorización o referencia<Input required value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} placeholder="Folio emitido por la terminal" /><small>Satrapy registra la evidencia; la terminal procesa el cobro.</small></label>}
            </>}
            {saleType === "credit" && <p className="pos-checkout-note">Se generará un cargo con el plazo configurado del cliente.</p>}
            {saleType === "deferred" && <section className="pos-deferred-sale">
              <div className="sales-order-notice pos-deferred-explainer">
                <ClipboardList size={18} aria-hidden="true" />
                <span>
                  <strong>Se guardará como orden de venta</strong>
                  <small>El inventario y el ticket se actualizan al confirmar la entrega.</small>
                </span>
              </div>
              <label>Entrega esperada<Input type="date" value={expectedDeliveryDate} onChange={(event) => setExpectedDeliveryDate(event.target.value)} /></label>
              <label>Pago inicial <small>Opcional</small><Input type="number" min="0" max={saleTotal} step="0.01" inputMode="decimal" value={received} onChange={(event) => setReceived(event.target.value)} placeholder="0.00" /></label>
              {Number(received || 0) > 0 && <><Select ariaLabel="Forma del pago inicial" value={paymentMethodId} onValueChange={(value) => { setPaymentMethodId(value); setPaymentReference(""); }} options={paymentMethods.map((method) => ({ value: method.id, label: method.name }))} />{selectedPayment?.settlement_kind === "external" && <label>Referencia<Input required value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} placeholder="Transferencia, depósito o terminal" /></label>}</>}
              <div className="pos-deferred-balance"><span>Saldo después del pago</span><strong>{money(Math.max(0, saleTotal - Number(received || 0)), quote?.currency_code ?? "MXN")}</strong></div>
            </section>}
            <Button variant="primary" size="lg" loading={busy} disabled={!checkoutReady || !quote?.can_checkout || (saleType === "cash" && (!paymentMethodId || (isCashPayment && !validReceivedAmount) || (selectedPayment?.settlement_kind === "external" && !paymentReference.trim()))) || (saleType === "credit" && (!customer?.credit_enabled || Boolean(customer.alpha_external_code && customer.migration_status !== "promoted"))) || (saleType === "deferred" && (!customer || !validOrderPayment))} onClick={() => void complete()}>{saleType === "cash" ? "Cobrar" : saleType === "credit" ? "Confirmar crédito" : "Crear orden"} <kbd>F8</kbd></Button>
          </div>
          </div>
        </aside>
      </div> : <section className="pos-held-workspace" id="pos-panel-held" role="tabpanel" aria-labelledby="pos-tab-held">
        <header className="pos-held-heading"><div><span className="eyebrow">Continuidad de atención</span><h2>Ventas en espera</h2><p>Estas ventas no reservan inventario. Precios, impuestos y existencias se vuelven a validar antes del cobro.</p></div><Button variant="secondary" size="sm" loading={heldLoading} disabled={!online} onClick={() => void loadHeldSales(heldSales.page)}>Actualizar</Button></header>
        <DataState loading={heldLoading && !heldSales.items.length} error={heldError} hasData={heldSales.items.length} empty="No hay ventas en espera en esta sesión de caja." errorAction={<Button size="sm" variant="secondary" onClick={() => void loadHeldSales(heldSales.page)}>Reintentar</Button>}>
          <div className="pos-held-layout">
            <div className="pos-held-list" role="list" aria-label="Ventas en espera">
              {heldSales.items.map((item) => <button type="button" role="listitem" aria-current={selectedHeldId === item.cart_id ? "true" : undefined} className={selectedHeldId === item.cart_id ? "is-selected" : ""} key={item.cart_id} onClick={() => setSelectedHeldId(item.cart_id)}><span className="pos-held-list__main"><strong>{item.customer_name ?? "Venta de mostrador"}</strong><small>{item.preview_items.join(" · ")}</small></span><span className="pos-held-list__meta"><b>{item.item_count} {item.item_count === 1 ? "partida" : "partidas"}</b><small>{heldFor(item.held_at)}</small>{item.pending_discount_approval && <em>Descuento pendiente</em>}</span></button>)}
              {heldSales.total > heldSales.page_size && <DataPagination page={heldSales.page} total={heldSales.total} pageSize={heldSales.page_size} label="ventas en espera" onChange={(page) => void loadHeldSales(page)} />}
            </div>
            <aside className="pos-held-detail" aria-live="polite">
              {heldPreviewLoading ? <DataState loading error={null} hasData={0} empty="">{null}</DataState> : heldPreview && selectedHeldId ? <><header><div><span className="eyebrow">Venta seleccionada</span><h3>{heldSales.items.find((item) => item.cart_id === selectedHeldId)?.customer_name ?? "Venta de mostrador"}</h3><small>{heldFor(heldSales.items.find((item) => item.cart_id === selectedHeldId)?.held_at ?? new Date().toISOString())}</small></div>{heldPreview.pending_discount_approval && <Badge tone="warning">Descuento pendiente</Badge>}</header><div className="pos-held-detail__lines">{heldPreview.items.map((item) => <article key={item.cart_item_id}><span><strong>{item.name}</strong><small>{item.code ?? "Sin código"} · {item.quantity} {item.unit ?? "unidad"}</small></span><b>{money(item.total_amount, heldPreview.currency_code)}</b></article>)}</div><div className="pos-held-detail__total"><span>Total actualizado</span><strong>{money(heldPreview.total_amount, heldPreview.currency_code)}</strong></div><footer><Button variant="secondary" disabled={busy || !checkoutReady} onClick={() => { const item = heldSales.items.find((entry) => entry.cart_id === selectedHeldId); if (item) setDiscardHeldCart(item); }}>Descartar</Button><Button variant="primary" disabled={busy || !checkoutReady} onClick={() => { const item = heldSales.items.find((entry) => entry.cart_id === selectedHeldId); if (!item) return; if (quote?.items.length) setResumeCart(item); else void resumeHeldSale(item); }}>Retomar venta</Button></footer></> : <div className="pos-held-detail__empty"><Clock3 size={24} aria-hidden="true" /><strong>Selecciona una venta</strong><span>Verás sus partidas y el total recalculado antes de retomarla.</span></div>}
            </aside>
          </div>
        </DataState>
      </section>}
    </>}
    <Modal open={Boolean(ticket)} onOpenChange={(open) => { if (!open) finishTicket(); }} eyebrow="Venta confirmada" title={`Ticket ${ticket?.folio ?? ""}`} description="El cliente ve precios totales; el desglose fiscal permanece disponible internamente." footer={<><Button variant="secondary" loading={ticketDownloading} onClick={() => void printCompletedTicket()}><Printer size={15} /> Imprimir ticket</Button><Button variant="primary" onClick={finishTicket}>Nueva venta</Button></>}><TicketPreview ticket={ticket?.ticket} /></Modal>
    <Modal className="pos-location-stock-dialog" open={Boolean(stockProduct)} onOpenChange={(open) => { if (!open) { setStockProduct(null); setLocationStock(null); } }} eyebrow="Inventario por sucursal" title={stockProduct?.name ?? "Otras sucursales"} description={`${productWords.singularTitle} ${stockProduct?.code ?? "sin código"} · Sucursal activa: ${selectedLocation?.name ?? selectedRegister?.name ?? "sin seleccionar"}. Solo lectura. La venta sigue usando la existencia de la sucursal activa.`} footer={<Button onClick={() => { setStockProduct(null); setLocationStock(null); }}>Cerrar <kbd>Esc</kbd></Button>}>{locationStockLoading ? <DataState loading error={null} hasData={0} empty="">{null}</DataState> : locationStock ? <section className="pos-location-stock"><header><span>Disponibilidad en otras sucursales</span><strong>{locationStock.total} {locationStock.total === 1 ? "sucursal" : "sucursales"}</strong></header>{otherLocationStockItems.length ? <div className="pos-location-stock__rows">{otherLocationStockItems.map((item) => { const quantity = Number(item.quantity_on_hand); const status = otherLocationStockStatus(quantity); return <article className={`is-${status.tone}`} key={item.location_id}><span className="pos-location-stock__location"><strong>{item.location_name}</strong><small>{item.location_code}</small></span><span className="pos-location-stock__quantity"><small>{status.label}</small><b>{quantity.toLocaleString("es-MX", { maximumFractionDigits: 3 })} <em>{locationStock.unit ?? stockProduct?.unit ?? ""}</em></b></span></article>; })}</div> : <p>No hay otras sucursales autorizadas para consultar.</p>}{locationStock.total > locationStock.page_size && <DataPagination page={locationStock.page} total={locationStock.total} pageSize={locationStock.page_size} label="sucursales" onChange={(page) => { if (stockProduct) void loadLocationStock(stockProduct, page); }} />}</section> : null}</Modal>
    <Drawer open={quickCustomerOpen} onOpenChange={setQuickCustomerOpen} title="Alta rápida de cliente"><form className="sales-form" onSubmit={createQuickCustomer}><p className="settings-note">Solo lo necesario para continuar la venta. Se crea de contado y hereda la lista de precios de esta ubicación.</p><label>Nombre<Input required autoFocus value={quickCustomerName} onChange={(event) => setQuickCustomerName(event.target.value)} /></label><label>Teléfono opcional<Input inputMode="tel" value={quickCustomerPhone} onChange={(event) => setQuickCustomerPhone(event.target.value)} /></label><label>RFC opcional<Input value={quickCustomerTaxId} onChange={(event) => setQuickCustomerTaxId(event.target.value.toUpperCase())} /></label><Button type="submit" variant="primary" loading={busy}>Crear y seleccionar</Button></form></Drawer>
    <Modal open={discountOpen} onOpenChange={setDiscountOpen} title="Solicitar descuento" description="El límite de tu rol se aplica automáticamente; si lo superas, el carrito queda pendiente de aprobación." footer={<Button type="submit" form="sale-discount-form" variant="primary" loading={busy}>Solicitar</Button>}><form id="sale-discount-form" className="sales-form" onSubmit={requestDiscount}><label>Porcentaje<Input required inputMode="decimal" min="0.01" max="100" value={discountPercent} onChange={(event) => setDiscountPercent(event.target.value)} /></label><label>Motivo<Input required value={discountReason} onChange={(event) => setDiscountReason(event.target.value)} placeholder="Motivo comercial" /></label></form></Modal>
    <Modal open={discardCartOpen} onOpenChange={(open) => { if (!busy) setDiscardCartOpen(open); }} eyebrow="Venta en preparación" title="Vaciar venta" description="Se descartarán todas las partidas y cualquier descuento pendiente. La acción quedará auditada." footer={<><Button variant="secondary" disabled={busy} onClick={() => setDiscardCartOpen(false)}>Conservar venta</Button><Button variant="danger" loading={busy} onClick={() => void discardCart()}><Trash2 size={15} aria-hidden="true" /> Vaciar venta</Button></>}></Modal>
    <Modal open={Boolean(resumeCart)} onOpenChange={(open) => { if (!open && !busy) setResumeCart(null); }} eyebrow="Cambio de atención" title="Retomar venta" description="La venta actual contiene partidas. Se pondrá en espera automáticamente antes de retomar la venta seleccionada; ninguna se sobrescribirá." footer={<><Button variant="secondary" disabled={busy} onClick={() => setResumeCart(null)}>Cancelar</Button><Button variant="primary" loading={busy} onClick={() => { if (resumeCart) void resumeHeldSale(resumeCart); }}>Intercambiar ventas</Button></>}></Modal>
    <Modal open={Boolean(discardHeldCart)} onOpenChange={(open) => { if (!open && !busy) setDiscardHeldCart(null); }} eyebrow="Venta en espera" title="Descartar venta" description={`Se descartará ${discardHeldCart?.customer_name ?? "la venta de mostrador"} con todas sus partidas. La acción quedará auditada.`} footer={<><Button variant="secondary" disabled={busy} onClick={() => setDiscardHeldCart(null)}>Conservar venta</Button><Button variant="danger" loading={busy} onClick={() => { if (discardHeldCart) void discardHeldSale(discardHeldCart); }}><Trash2 size={15} aria-hidden="true" /> Descartar venta</Button></>}></Modal>
  </div>;
}

export function SalesHistoryView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<SaleRow[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [ticket, setTicket] = useState<SaleTicketState | null>(null);
  const [ticketDownloading, setTicketDownloading] = useState(false);
  const [cancellationReason, setCancellationReason] = useState<string | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [returnContext, setReturnContext] = useState<SaleReturnContext | null>(null);
  const [returnOpen, setReturnOpen] = useState(false);
  const [returnReason, setReturnReason] = useState("");
  const [returnReference, setReturnReference] = useState("");
  const [returnLines, setReturnLines] = useState<Record<string, { quantity: string; restock: boolean }>>({});
  const [returning, setReturning] = useState(false);
  const [approvals, setApprovals] = useState<Array<{ id: string; scope: string; requested_percent: number; requested_reason: string; created_at: string }>>([]);
  const totalSnapshot = useRef<{ key: string; total: number } | null>(null);
  const latestLoad = useRef(0);
  const load = useCallback(async () => {
    const requestId = ++latestLoad.current;
    const totalKey = `${companyId}:${query.trim().toLocaleLowerCase("es-MX")}`;
    const cachedTotal = totalSnapshot.current?.key === totalKey ? totalSnapshot.current.total : undefined;
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("list_sales", { p_company_id: companyId, p_location_id: null, p_query: query || null, p_page: page, p_page_size: 50, p_include_total: cachedTotal === undefined });
    if (requestId !== latestLoad.current) return;
    if (loadError) setError("No se pudieron consultar las ventas.");
    else {
      const result = data as { items?: SaleRow[]; total?: number | null };
      if (typeof result.total === "number") totalSnapshot.current = { key: totalKey, total: result.total };
      setRows(result.items ?? []);
      setTotal(typeof result.total === "number" ? result.total : cachedTotal ?? 0);
      setError(null);
    }
    setLoading(false);
  }, [companyId, page, query]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 350); return () => window.clearTimeout(timer); }, [load]);
  const loadApprovals = useCallback(async () => {
    if (!permissions.includes("approve_discount")) return;
    const { data } = await getSupabaseClient().rpc("list_pending_discount_approvals", { p_company_id: companyId });
    setApprovals((data ?? []) as Array<{ id: string; scope: string; requested_percent: number; requested_reason: string; created_at: string }>);
  }, [companyId, permissions]);
  useEffect(() => { void Promise.resolve().then(loadApprovals); }, [loadApprovals]);
  async function openTicket(row: SaleRow) {
    const client = getSupabaseClient();
    const [{ data, error: ticketError }, { data: cancellation }, { data: postSale }] = await Promise.all([
      client.rpc("get_canonical_ticket", { p_sale_id: row.sale_id }),
      client.from("sale_cancellations").select("id, reason, cancelled_at").eq("company_id", companyId).eq("sale_id", row.sale_id).maybeSingle(),
      row.source_kind === "alpha_historical" ? Promise.resolve({ data: null }) : client.rpc("get_sale_return_context", { p_company_id: companyId, p_sale_id: row.sale_id }),
    ]);
    if (ticketError) { toast({ title: "No se pudo abrir el ticket", description: rpcError(ticketError, "Intenta nuevamente."), tone: "error" }); return; }
    setTicket({ saleId: row.sale_id, sourceKind: row.source_kind, payload: (data as { payload: Record<string, unknown> }).payload, cancellation });
    setReturnContext((postSale as SaleReturnContext | null) ?? null);
  }
  function beginReturn() {
    if (!returnContext) return;
    setReturnLines(Object.fromEntries(returnContext.items.map((item) => [item.sale_item_id, { quantity: "", restock: item.inventory_tracked }])));
    setReturnReason(""); setReturnReference(""); setTicket(null); setReturnOpen(true);
  }
  async function processReturn() {
    if (!returnContext) return;
    const items = returnContext.items.flatMap((item) => {
      const draft = returnLines[item.sale_item_id];
      const quantity = Number((draft?.quantity ?? "").replace(",", "."));
      return Number.isFinite(quantity) && quantity > 0 ? [{ sale_item_id: item.sale_item_id, quantity, restock: Boolean(draft?.restock) }] : [];
    });
    if (!returnReason.trim() || !items.length) return;
    setReturning(true);
    const { error: returnError } = await getSupabaseClient().rpc("process_sale_return", {
      p_company_id: companyId,
      p_sale_id: returnContext.sale.id,
      p_reason: returnReason.trim(),
      p_items: items,
      p_cash_session_id: returnContext.settlement_kind === "cash_drawer" ? returnContext.own_open_cash_session_id : null,
      p_external_reference: returnContext.settlement_kind === "external" ? returnReference.trim() || null : null,
      p_client_request_id: crypto.randomUUID(),
    });
    setReturning(false);
    if (returnError) { toast({ title: "No se pudo registrar la devolución", description: rpcError(returnError, "Verifica cantidades y liquidación."), tone: "error" }); return; }
    toast({ title: "Devolución registrada", description: "El ajuste financiero, inventario recibible y contabilidad quedaron ligados al ticket.", tone: "success" });
    setReturnOpen(false); setReturnContext(null); await load();
  }
  async function cancelSale() {
    if (!ticket || !cancellationReason?.trim()) return;
    setCancelling(true);
    const { error: cancellationError } = await getSupabaseClient().rpc("cancel_sale", { p_company_id: companyId, p_sale_id: ticket.saleId, p_reason: cancellationReason.trim(), p_client_request_id: crypto.randomUUID() });
    setCancelling(false);
    if (cancellationError) { toast({ title: "No se pudo cancelar la venta", description: rpcError(cancellationError, "Verifica que la caja original siga abierta."), tone: "error" }); return; }
    toast({ title: "Venta cancelada", description: "Inventario, caja y contabilidad quedaron revertidos.", tone: "success" });
    setCancellationReason(null); setTicket(null); await load();
  }
  async function decideDiscount(id: string, approve: boolean) { const { error: decisionError } = await getSupabaseClient().rpc("decide_cart_discount", { p_discount_approval_id: id, p_approve: approve, p_decision_reason: null }); if (decisionError) toast({ title: "No se pudo registrar la decisión", description: rpcError(decisionError, "Intenta nuevamente."), tone: "error" }); else { toast({ title: approve ? "Descuento aprobado" : "Descuento rechazado", tone: "success" }); await loadApprovals(); } }
  async function printHistoricalTicket() {
    if (!ticket) return;
    setTicketDownloading(true);
    try {
      await printCompanyTicket(companyId, ticket.payload);
      toast({ title: "Ticket listo", description: "Se abrió el diálogo de impresión.", tone: "success" });
    } catch {
      toast({ title: "No se pudo generar el ticket", description: "Intenta nuevamente; la venta permanece guardada.", tone: "error" });
    } finally {
      setTicketDownloading(false);
    }
  }
  const selectedReturnCount = Object.values(returnLines).filter((line) => Number(line.quantity.replace(",", ".")) > 0).length;
  const returnBlockedByCash = returnContext?.settlement_kind === "cash_drawer" && !returnContext.own_open_cash_session_id;
  return <div className="content-frame"><PageTitle eyebrow="Documentos inmutables" title="Ventas" description="Consulta tickets canónicos y registra postventa sin modificar la venta original." />{permissions.includes("approve_discount") && approvals.length > 0 && <section className="discount-approvals"><header><strong>Descuentos pendientes</strong><Badge tone="warning">{approvals.length}</Badge></header>{approvals.map((approval) => <article key={approval.id}><span><strong>{approval.requested_percent}% · {approval.scope === "sale" ? "Venta" : "Línea"}</strong><small>{approval.requested_reason} · {dateTime(approval.created_at)}</small></span><div><Button size="sm" variant="ghost" onClick={() => void decideDiscount(approval.id, false)}>Rechazar</Button><Button size="sm" variant="primary" onClick={() => void decideDiscount(approval.id, true)}>Aprobar</Button></div></article>)}</section>}<DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar folio o cliente" results={total} /><DataRefreshStatus loading={loading} hasData={rows.length}/><DataState loading={loading&&rows.length===0} error={error} errorAction={<Button size="sm" onClick={()=>void load()}>Reintentar</Button>} hasData={rows.length} emptyTitle={query?"No encontramos ventas.":"Aún no hay ventas."} empty={query?"Cambia o limpia la búsqueda para ampliar los resultados.":"Las ventas confirmadas aparecerán aquí."}><div className="sales-history">{rows.map((row) => <button key={row.sale_id} onClick={() => void openTicket(row)}><span><strong>{row.folio}</strong><small>{row.customer_name ?? "Venta de mostrador"} · {dateTime(row.completed_at)}{Number(row.returned_amount)>0 ? ` · Devuelto ${money(row.returned_amount,row.currency_code)}` : ""}</small></span><span>{row.source_kind === "alpha_historical" ? <Badge tone="info">Histórica</Badge> : row.cancelled ? <Badge tone="neutral">Cancelada</Badge> : Number(row.returned_amount)>0 ? <Badge tone="warning">Postventa</Badge> : <Badge tone={row.sale_type === "credit" ? "warning" : "success"}>{row.sale_type === "credit" ? "Crédito" : "Contado"}</Badge>}<b>{money(row.total_amount, row.currency_code)}</b></span></button>)}</div><SettingsPagination page={page} totalPages={Math.max(1, Math.ceil(total / 50))} onChange={setPage} /></DataState><Modal open={Boolean(ticket)} onOpenChange={(open) => { if (!open) setTicket(null); }} title="Ticket canónico" className="sales-ticket-detail-dialog" footer={<>{ticket?.sourceKind === "alpha_historical" ? <Badge tone="info">Histórica · solo consulta</Badge> : ticket?.cancellation ? <Badge tone="neutral">Venta cancelada</Badge> : returnContext?.can_process && returnContext.items.some((item) => Number(item.available_quantity)>0) ? <Button variant="secondary" onClick={beginReturn}>Registrar devolución</Button> : null}{ticket?.sourceKind !== "alpha_historical" && !ticket?.cancellation && !returnContext?.returns.length && permissions.includes("cancel_sales") ? <Button variant="danger" onClick={() => setCancellationReason("")}>Cancelar venta</Button> : null}<Button variant="secondary" loading={ticketDownloading} onClick={() => void printHistoricalTicket()}><Printer size={15} /> Imprimir ticket</Button><Button onClick={() => setTicket(null)}>Cerrar</Button></>}><TicketPreview ticket={ticket?.payload ?? null} />{ticket?.cancellation && <p className="settings-note">Cancelada: {ticket.cancellation.reason} · {dateTime(ticket.cancellation.cancelled_at)}</p>}{Boolean(returnContext?.returns.length) && <section className="sale-return-history"><h3>Devoluciones</h3>{returnContext?.returns.map((item) => <article key={item.id}><span><strong>{money(item.total_amount,returnContext.sale.currency_code)}</strong><small>{dateTime(item.returned_at)} · {item.reason}</small></span><Badge tone="warning">{item.items.reduce((sum,line)=>sum+Number(line.quantity),0)} devuelto</Badge></article>)}</section>}</Modal><Modal open={returnOpen} onOpenChange={(open) => { if (!open && !returning) setReturnOpen(false); }} eyebrow="Postventa auditada" title={`Devolución · ${returnContext?.sale.folio ?? ""}`} description="Captura en conjunto las partidas recibidas. La venta y el ticket originales no se editan." footer={<><Button disabled={returning} onClick={() => setReturnOpen(false)}>Volver</Button><Button variant="primary" loading={returning} disabled={!returnReason.trim() || selectedReturnCount===0 || returnBlockedByCash || (returnContext?.settlement_kind==="external"&&!returnReference.trim())} onClick={() => void processReturn()}>Confirmar devolución</Button></>}>{returnContext && <div className="sale-return-form"><div className="sale-return-lines">{returnContext.items.map((item) => { const draft=returnLines[item.sale_item_id]??{quantity:"",restock:item.inventory_tracked};const unavailable=Number(item.available_quantity)<=0;return <article key={item.sale_item_id} className={unavailable?"is-complete":undefined}><div><strong>{item.product_name}</strong><small>{item.product_code} · Vendido {item.sold_quantity} · Ya devuelto {item.returned_quantity} · Disponible {item.available_quantity} {item.unit_name??""}</small></div><label>Cantidad<Input disabled={unavailable} inputMode="decimal" value={draft.quantity} onChange={(event)=>setReturnLines((current)=>({...current,[item.sale_item_id]:{...draft,quantity:event.target.value}}))} placeholder="0" /></label><label className="sale-return-restock"><input type="checkbox" disabled={unavailable||!item.inventory_tracked} checked={draft.restock&&item.inventory_tracked} onChange={(event)=>setReturnLines((current)=>({...current,[item.sale_item_id]:{...draft,restock:event.target.checked}}))}/><span>Mercancía recibible<br/><small>{item.inventory_tracked?"Reintegrar a inventario":"Sin control de inventario"}</small></span></label></article>;})}</div>{returnBlockedByCash && <p className="settings-note is-danger">Abre una caja propia en la sucursal original antes de reembolsar en efectivo.</p>}{returnContext.settlement_kind==="external"&&<label>Referencia del reembolso externo<Input required value={returnReference} onChange={(event)=>setReturnReference(event.target.value)} placeholder="Folio o autorización del procesador" /></label>}<label>Motivo obligatorio<textarea rows={3} value={returnReason} onChange={(event)=>setReturnReason(event.target.value)} placeholder="Describe la causa de la devolución" /></label><p className="settings-note">{returnContext.settlement_kind==="receivable"?"El importe reducirá el saldo pendiente de esta venta.":"El reembolso seguirá el medio de pago original."} Sólo las partidas marcadas como recibibles regresarán a existencia.</p></div>}</Modal><Modal open={cancellationReason !== null} onOpenChange={(open) => { if (!open && !cancelling) setCancellationReason(null); }} eyebrow="Reversa auditada" title="Cancelar venta" description="Se devolverá el inventario y se generará la póliza inversa. El ticket original permanecerá inmutable." footer={<><Button disabled={cancelling} onClick={() => setCancellationReason(null)}>Volver</Button><Button variant="danger" loading={cancelling} disabled={!cancellationReason?.trim()} onClick={() => void cancelSale()}>Confirmar cancelación</Button></>}><label className="operation-reason">Motivo obligatorio<textarea rows={4} value={cancellationReason ?? ""} onChange={(event) => setCancellationReason(event.target.value)} placeholder="Ej. Venta de prueba controlada" /></label></Modal></div>;
}

export function CustomersView({ companyId, permissions, initialCustomerId = null, initialCreateOpen = false }: { companyId: string; permissions: string[]; initialCustomerId?: string | null; initialCreateOpen?: boolean }) {
  const router = useRouter();
  const canViewCredit = permissions.includes("view_customer_credit");
  const [query, setQuery] = useState(""); const [rows, setRows] = useState<Customer[]>([]); const [total, setTotal] = useState(0); const [page, setPage] = useState(1); const [loading, setLoading] = useState(true);
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(initialCustomerId); const [createOpen, setCreateOpen] = useState(initialCreateOpen); const initialRouteHandled = useRef(false);
  const load = useCallback(async () => { setLoading(true); const { data } = await getSupabaseClient().rpc(canViewCredit ? "search_sale_customers_credit" : "search_sale_customers", { p_company_id: companyId, p_query: query || null, p_page: page, p_page_size: 100 }); const result = data as { items?: Customer[]; total?: number } | null; setRows(result?.items ?? []); setTotal(result?.total ?? 0); setLoading(false); }, [canViewCredit, companyId, page, query]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 150); return () => window.clearTimeout(timer); }, [load]);
  function closeDrawer() { setSelectedCustomerId(null); setCreateOpen(false); if (!initialRouteHandled.current && (initialCustomerId || initialCreateOpen)) { initialRouteHandled.current = true; router.replace("/satrapy/ventas/clientes"); } }
  return <><div className="content-frame"><PageTitle eyebrow="Relación comercial" title="Clientes" description="Busca y administra la información comercial de cada cliente." action={permissions.includes("manage_customers") ? <Button variant="primary" onClick={() => setCreateOpen(true)}><UserPlus size={16} /> Nuevo cliente</Button> : undefined} /><DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar código, nombre, RFC o teléfono" results={total} /><DataState loading={loading} error={null} hasData={rows.length} empty="No se encontraron clientes."><div className="table-wrap surface-table"><table><thead><tr><th>Cliente</th><th>Condición de venta</th>{canViewCredit && <><th className="number-cell">Saldo pendiente</th><th className="number-cell">Crédito disponible</th></>}<th aria-label="Acciones" /></tr></thead><tbody>{rows.map((row) => { const creditConfigured = Number(row.credit_limit ?? 0) > 0 && Number(row.credit_term_days ?? 0) > 0; return <InteractiveTableRow key={row.id} label={`Ver cliente ${row.display_name}`} onActivate={() => setSelectedCustomerId(row.id)}><td><strong className="customer-name-link">{row.display_name}</strong><small className="table-subline">{row.code}</small></td><td>{row.credit_enabled ? <Badge tone={canViewCredit && !creditConfigured ? "warning" : "success"}>{canViewCredit ? (creditConfigured ? `Crédito · ${row.credit_term_days} días` : "Crédito incompleto") : "Crédito habilitado"}</Badge> : <Badge>Solo contado</Badge>}</td>{canViewCredit && <><td className="number-cell">{money(row.outstanding_amount)}</td><td className="number-cell">{row.credit_enabled ? money(row.available_credit) : "—"}</td></>}<td><Button size="sm" variant="ghost" onClick={() => setSelectedCustomerId(row.id)}>Ver cliente</Button></td></InteractiveTableRow>; })}</tbody></table></div><SettingsPagination page={page} totalPages={Math.max(1, Math.ceil(total / 100))} onChange={setPage} /></DataState></div><CustomerCreateDrawer companyId={companyId} permissions={permissions} open={createOpen} onOpenChange={(open) => { if (!open) closeDrawer(); else setCreateOpen(true); }} onCreated={(customerId) => { setCreateOpen(false); setSelectedCustomerId(customerId); void load(); }} />{selectedCustomerId && <CustomerDetailDrawer companyId={companyId} customerId={selectedCustomerId} permissions={permissions} open={Boolean(selectedCustomerId)} onOpenChange={(open) => { if (!open) closeDrawer(); }} />}</>;
}

function CustomerCreateDrawer({ companyId, permissions, open, onOpenChange, onCreated }: { companyId: string; permissions: string[]; open: boolean; onOpenChange: (open: boolean) => void; onCreated: (customerId: string) => void }) {
  const { toast } = useToast(); const [name, setName] = useState(""); const [phone, setPhone] = useState(""); const [taxId, setTaxId] = useState(""); const [email, setEmail] = useState(""); const [customerType, setCustomerType] = useState(""); const [notes, setNotes] = useState(""); const [saving, setSaving] = useState(false);
  async function createCustomer(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { data, error } = await getSupabaseClient().rpc("upsert_sale_customer", { p_company_id: companyId, p_customer_id: null, p_code: null, p_display_name: name, p_tax_id: taxId || null, p_email: email || null, p_phone: phone || null, p_price_list_id: null, p_credit_enabled: false, p_credit_limit: 0, p_credit_term_days: 0, p_customer_type: customerType || null, p_notes: notes || null }); setSaving(false); if (error || !data) { toast({ title: "No se pudo crear el cliente", description: rpcError(error, "Verifica los datos generales."), tone: "error" }); return; } toast({ title: "Cliente creado", description: "Quedó activo, en condición solo contado y con la lista de precios heredada.", tone: "success" }); onCreated(data as string); }
  if (!permissions.includes("manage_customers")) return null;
  return <Drawer open={open} onOpenChange={(next) => { if (!saving) onOpenChange(next); }} title="Nuevo cliente" className="customer-drawer"><header className="customer-drawer__heading"><div><span className="eyebrow">Relación comercial</span><p>Registra la información inicial. Después podrás completar sus datos comerciales.</p></div><Badge>Solo contado</Badge></header><form className="customer-master-form" onSubmit={createCustomer}><div className="customer-master-grid"><label>Nombre o razón social<Input required autoFocus value={name} onChange={(event) => setName(event.target.value)} /></label><label>Teléfono <small>Opcional, recomendado</small><Input inputMode="tel" value={phone} onChange={(event) => setPhone(event.target.value)} /></label><label>RFC <small>Opcional</small><Input value={taxId} onChange={(event) => setTaxId(event.target.value.toUpperCase())} placeholder="Se valida solo si lo capturas" /></label><label>Correo <small>Opcional</small><Input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label><label>Tipo de cliente <small>Opcional</small><Select ariaLabel="Tipo de cliente" value={customerType} onValueChange={setCustomerType} options={[{ value: "", label: "Sin especificar" }, { value: "persona_fisica", label: "Persona física" }, { value: "persona_moral", label: "Persona moral" }]} /></label><label className="is-wide">Notas <small>Opcionales</small><Input value={notes} onChange={(event) => setNotes(event.target.value)} /></label></div><p className="settings-note">Código interno y estado activo se asignan automáticamente. El cliente queda en condición solo contado y hereda la lista de precios de la ubicación o empresa.</p><div className="customer-drawer__actions"><Button type="button" variant="secondary" disabled={saving} onClick={() => onOpenChange(false)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving}>Crear cliente</Button></div></form></Drawer>;
}

type CustomerMasterTab = "general" | "addresses" | "contacts" | "commercial" | "receivables";

function CustomerDetailDrawer({ companyId, customerId, permissions, open, onOpenChange }: { companyId: string; customerId: string; permissions: string[]; open: boolean; onOpenChange: (open: boolean) => void }) {
  const { toast } = useToast();
  const canManage = permissions.includes("manage_customers"); const canViewCredit = permissions.includes("view_customer_credit");
  const [master, setMaster] = useState<CustomerMaster | null>(null); const [tab, setTab] = useState<CustomerMasterTab>("general"); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null); const [saving, setSaving] = useState(false);
  const [name, setName] = useState(""); const [taxId, setTaxId] = useState(""); const [customerType, setCustomerType] = useState(""); const [notes, setNotes] = useState("");
  const [addressId, setAddressId] = useState<string | null>(null); const [addressLabel, setAddressLabel] = useState("Principal"); const [addressLine, setAddressLine] = useState(""); const [neighborhood, setNeighborhood] = useState(""); const [municipality, setMunicipality] = useState(""); const [stateName, setStateName] = useState(""); const [postalCode, setPostalCode] = useState(""); const [addressPrimary, setAddressPrimary] = useState(false);
  const [contactId, setContactId] = useState<string | null>(null); const [contactName, setContactName] = useState(""); const [contactRole, setContactRole] = useState(""); const [contactPhone, setContactPhone] = useState(""); const [contactEmail, setContactEmail] = useState(""); const [contactPrimary, setContactPrimary] = useState(false);
  const [priceLists, setPriceLists] = useState<Array<{ id: string; name: string; currency_code: string }>>([]); const [priceListId, setPriceListId] = useState(""); const [paymentManager, setPaymentManager] = useState(""); const [salesAgent, setSalesAgent] = useState(""); const [credit, setCredit] = useState(false); const [creditLimit, setCreditLimit] = useState(""); const [creditDays, setCreditDays] = useState("");
  const [receipt, setReceipt] = useState<ReceivableReceipt | null>(null);
  const [adjustments, setAdjustments] = useState<CustomerMigrationAdjustment[]>([]); const [adjustmentOpen, setAdjustmentOpen] = useState(false); const [adjustmentField, setAdjustmentField] = useState("display_name"); const [adjustmentValue, setAdjustmentValue] = useState(""); const [adjustmentReason, setAdjustmentReason] = useState(""); const [adjustmentEvidence, setAdjustmentEvidence] = useState("");

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    const client = getSupabaseClient();
    const [masterResult, listResult] = await Promise.all([
      client.rpc("get_customer_master", { p_company_id: companyId, p_customer_id: customerId }),
      canManage ? client.rpc("list_customer_price_lists", { p_company_id: companyId }) : Promise.resolve({ data: [], error: null }),
    ]);
    if (masterResult.error || !masterResult.data) { setError(rpcError(masterResult.error, "No se pudo cargar el maestro del cliente.")); setMaster(null); setLoading(false); return; }
    const next = masterResult.data as CustomerMaster; setMaster(next); setName(next.display_name); setTaxId(next.tax_id ?? ""); setCustomerType(next.customer_type ?? ""); setNotes(next.notes ?? "");
    setPriceListId(next.commercial.price_list_id ?? ""); setPaymentManager(next.commercial.payment_manager ?? ""); setSalesAgent(next.commercial.sales_agent ?? ""); setCredit(Boolean(next.commercial.credit_enabled)); setCreditLimit(next.commercial.credit_limit ? String(next.commercial.credit_limit) : ""); setCreditDays(next.commercial.credit_term_days ? String(next.commercial.credit_term_days) : "");
    setPriceLists((listResult.data ?? []) as typeof priceLists); setLoading(false);
  }, [canManage, companyId, customerId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);

  const loadAdjustments = useCallback(async () => {
    if (!permissions.includes("import_data")) return;
    const { data } = await getSupabaseClient().rpc("list_customer_migration_adjustments", { p_company_id: companyId, p_customer_id: customerId });
    const result = data as { items?: CustomerMigrationAdjustment[] } | null;
    setAdjustments(result?.items ?? []);
  }, [companyId, customerId, permissions]);

  useEffect(() => { if (master?.is_imported) void Promise.resolve().then(loadAdjustments); }, [loadAdjustments, master?.is_imported]);

  const editable = Boolean(canManage && master && !master.is_imported);
  function resetAddress() { setAddressId(null); setAddressLabel("Principal"); setAddressLine(""); setNeighborhood(""); setMunicipality(""); setStateName(""); setPostalCode(""); setAddressPrimary(false); }
  function editAddress(address: CustomerAddress) { setAddressId(address.id); setAddressLabel(address.label); setAddressLine(address.address_line); setNeighborhood(address.neighborhood ?? ""); setMunicipality(address.municipality ?? ""); setStateName(address.state_name ?? ""); setPostalCode(address.postal_code ?? ""); setAddressPrimary(address.is_primary); }
  function resetContact() { setContactId(null); setContactName(""); setContactRole(""); setContactPhone(""); setContactEmail(""); setContactPrimary(false); }
  function editContact(contact: CustomerContact) { setContactId(contact.id); setContactName(contact.display_name); setContactRole(contact.role_name ?? ""); setContactPhone(contact.phone ?? ""); setContactEmail(contact.email ?? ""); setContactPrimary(contact.is_primary); }
  async function runSave(action: () => Promise<{ error: { message?: string } | null }>, success: string) { setSaving(true); const result = await action(); if (result.error) toast({ title: "No se pudo guardar", description: rpcError(result.error, "Verifica los datos."), tone: "error" }); else { toast({ title: success, tone: "success" }); await load(); } setSaving(false); return !result.error; }
  async function saveGeneral(event: React.FormEvent) { event.preventDefault(); await runSave(async () => getSupabaseClient().rpc("update_customer_general", { p_company_id: companyId, p_customer_id: customerId, p_display_name: name, p_tax_id: taxId || null, p_customer_type: customerType || null, p_notes: notes || null }), "Datos generales actualizados"); }
  async function saveAddress(event: React.FormEvent) { event.preventDefault(); const ok = await runSave(async () => getSupabaseClient().rpc("upsert_customer_address", { p_company_id: companyId, p_customer_id: customerId, p_address_id: addressId, p_label: addressLabel, p_address_line: addressLine, p_neighborhood: neighborhood || null, p_municipality: municipality || null, p_state_name: stateName || null, p_postal_code: postalCode || null, p_is_primary: addressPrimary }), "Dirección guardada"); if (ok) resetAddress(); }
  async function deleteAddress(id: string) { await runSave(async () => getSupabaseClient().rpc("delete_customer_address", { p_company_id: companyId, p_customer_id: customerId, p_address_id: id }), "Dirección eliminada"); }
  async function saveContact(event: React.FormEvent) { event.preventDefault(); const ok = await runSave(async () => getSupabaseClient().rpc("upsert_customer_contact", { p_company_id: companyId, p_customer_id: customerId, p_contact_id: contactId, p_display_name: contactName, p_role_name: contactRole || null, p_phone: contactPhone || null, p_email: contactEmail || null, p_is_primary: contactPrimary }), "Contacto guardado"); if (ok) resetContact(); }
  async function deleteContact(id: string) { await runSave(async () => getSupabaseClient().rpc("delete_customer_contact", { p_company_id: companyId, p_customer_id: customerId, p_contact_id: id }), "Contacto eliminado"); }
  async function saveCommercial(event: React.FormEvent) { event.preventDefault(); await runSave(async () => getSupabaseClient().rpc("update_customer_commercial", { p_company_id: companyId, p_customer_id: customerId, p_price_list_id: priceListId || null, p_payment_manager: paymentManager || null, p_sales_agent: salesAgent || null, p_credit_enabled: credit, p_credit_limit: Number(creditLimit || 0), p_credit_term_days: Number(creditDays || 0) }), "Condiciones comerciales actualizadas"); }
  async function requestAdjustment(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error: adjustmentError } = await getSupabaseClient().rpc("request_alpha_customer_migration_adjustment", { p_company_id: companyId, p_customer_id: customerId, p_receivable_id: null, p_field_name: adjustmentField, p_proposed_value: JSON.stringify(adjustmentValue), p_reason: adjustmentReason, p_evidence: adjustmentEvidence }); setSaving(false); if (adjustmentError) { toast({ title: "No se pudo solicitar el ajuste", description: rpcError(adjustmentError, "Verifica el campo, motivo y evidencia."), tone: "error" }); return; } setAdjustmentOpen(false); setAdjustmentValue(""); setAdjustmentReason(""); setAdjustmentEvidence(""); toast({ title: "Ajuste solicitado", description: "El dato protegido no cambia hasta que se revise y apruebe.", tone: "success" }); await Promise.all([load(), loadAdjustments()]); }

  if (loading && !master) return <Drawer open={open} onOpenChange={onOpenChange} title="Cliente" className="customer-drawer"><DataState loading error={null} hasData={0} empty="">{null}</DataState></Drawer>;
  if (error || !master) return <Drawer open={open} onOpenChange={onOpenChange} title="Cliente" className="customer-drawer"><DataState loading={false} error={error ?? "Cliente no disponible."} hasData={0} empty="" errorAction={<Button onClick={() => void load()}>Reintentar</Button>}>{null}</DataState></Drawer>;
  const tabs: Array<{ id: CustomerMasterTab; label: string }> = [{ id: "general", label: "General" }, { id: "addresses", label: "Direcciones" }, { id: "contacts", label: "Contactos" }, { id: "commercial", label: "Comercial" }, { id: "receivables", label: "Crédito y cobranza" }];
  return <Drawer open={open} onOpenChange={(next) => { if (!saving) onOpenChange(next); }} title={master.display_name} className="customer-drawer"><header className="customer-drawer__heading"><div><span className="eyebrow">Cliente</span><p>{master.code} · {master.commercial.credit_enabled ? "Crédito" : "Contado"}</p></div>{master.is_imported && <Badge tone={master.migration_status === "adjustment_pending" ? "warning" : "info"}>Datos protegidos</Badge>}</header>{master.is_imported && <div className="inline-status"><span>Los datos promovidos conservan trazabilidad y solo cambian mediante un ajuste auditado.</span>{permissions.includes("import_data") && <Button size="sm" variant="secondary" onClick={() => setAdjustmentOpen(true)}>Solicitar ajuste</Button>}</div>}<nav className="customer-master__tabs" aria-label="Secciones del cliente">{tabs.map((item) => <button className={tab === item.id ? "is-active" : ""} aria-current={tab === item.id ? "page" : undefined} onClick={() => setTab(item.id)} key={item.id}>{item.label}</button>)}</nav><section className="customer-master__panel">{tab === "general" && <form className="customer-master-form" onSubmit={saveGeneral}><div className="customer-master-grid"><label>Nombre<Input value={name} onChange={(event) => setName(event.target.value)} disabled={!editable} /></label><label>RFC<Input value={taxId} onChange={(event) => setTaxId(event.target.value.toUpperCase())} disabled={!editable} /></label><label>Código interno<Input value={master.code} disabled /></label>{master.source_reference && <label>Referencia de origen<Input value={master.source_reference} disabled /></label>}</div>{editable && <Button type="submit" variant="primary" loading={saving}>Guardar información</Button>}</form>}
    {tab === "addresses" && <><div className="customer-record-list">{master.addresses.length ? master.addresses.map((address) => <article key={address.id}><span><strong>{address.label}{address.is_primary ? " · Principal" : ""}</strong><small>{[address.address_line,address.neighborhood,address.municipality,address.state_name,address.postal_code].filter(Boolean).join(", ")}</small></span>{editable && <div><Button size="sm" variant="ghost" onClick={() => editAddress(address)}><Pencil size={14} /> Editar</Button><Button size="sm" variant="ghost" onClick={() => void deleteAddress(address.id)}><Trash2 size={14} /></Button></div>}</article>) : <p>Sin direcciones registradas.</p>}</div>{editable && <form className="customer-master-form" onSubmit={saveAddress}><h3>{addressId ? "Editar dirección" : "Agregar dirección"}</h3><div className="customer-master-grid"><label>Etiqueta<Input required value={addressLabel} onChange={(event) => setAddressLabel(event.target.value)} /></label><label className="is-wide">Dirección<Input required value={addressLine} onChange={(event) => setAddressLine(event.target.value)} /></label><label>Colonia<Input value={neighborhood} onChange={(event) => setNeighborhood(event.target.value)} /></label><label>Municipio<Input value={municipality} onChange={(event) => setMunicipality(event.target.value)} /></label><label>Estado<Input value={stateName} onChange={(event) => setStateName(event.target.value)} /></label><label>Código postal<Input value={postalCode} onChange={(event) => setPostalCode(event.target.value)} /></label></div><label className="sales-checkbox"><input type="checkbox" checked={addressPrimary} onChange={(event) => setAddressPrimary(event.target.checked)} /> Dirección principal</label><div className="customer-master-actions">{addressId && <Button type="button" variant="ghost" onClick={resetAddress}>Cancelar</Button>}<Button type="submit" variant="primary" loading={saving}>Guardar dirección</Button></div></form>}</>}
    {tab === "contacts" && <><div className="customer-record-list">{master.contacts.length ? master.contacts.map((contact) => <article key={contact.id}><span><strong>{contact.display_name}{contact.is_primary ? " · Principal" : ""}</strong><small>{[contact.role_name,contact.phone,contact.email].filter(Boolean).join(" · ")}</small></span>{editable && <div><Button size="sm" variant="ghost" onClick={() => editContact(contact)}><Pencil size={14} /> Editar</Button><Button size="sm" variant="ghost" onClick={() => void deleteContact(contact.id)}><Trash2 size={14} /></Button></div>}</article>) : <p>Sin contactos registrados.</p>}</div>{editable && <form className="customer-master-form" onSubmit={saveContact}><h3>{contactId ? "Editar contacto" : "Agregar contacto"}</h3><div className="customer-master-grid"><label>Nombre<Input required value={contactName} onChange={(event) => setContactName(event.target.value)} /></label><label>Función<Input value={contactRole} onChange={(event) => setContactRole(event.target.value)} /></label><label>Teléfono<Input value={contactPhone} onChange={(event) => setContactPhone(event.target.value)} /></label><label>Correo<Input type="email" value={contactEmail} onChange={(event) => setContactEmail(event.target.value)} /></label></div><label className="sales-checkbox"><input type="checkbox" checked={contactPrimary} onChange={(event) => setContactPrimary(event.target.checked)} /> Contacto principal</label><div className="customer-master-actions">{contactId && <Button type="button" variant="ghost" onClick={resetContact}>Cancelar</Button>}<Button type="submit" variant="primary" loading={saving}>Guardar contacto</Button></div></form>}</>}
    {tab === "commercial" && <form className="customer-master-form" onSubmit={saveCommercial}><div className="customer-master-grid"><label>Lista de precios<Select ariaLabel="Lista de precios" value={priceListId} onValueChange={setPriceListId} disabled={!editable} options={[{ value: "", label: "Heredar de ubicación o empresa" }, ...priceLists.map((list) => ({ value: list.id, label: `${list.name} · ${list.currency_code}` }))]} /></label><label>Encargado de pagos<Input value={paymentManager} onChange={(event) => setPaymentManager(event.target.value)} disabled={!editable} /></label><label>Agente<Input value={salesAgent} onChange={(event) => setSalesAgent(event.target.value)} disabled={!editable} /></label>{canViewCredit && <><label className="sales-checkbox"><input type="checkbox" checked={credit} onChange={(event) => setCredit(event.target.checked)} disabled={!editable} /> Habilitar crédito</label>{credit && <><label>Límite<Input inputMode="decimal" value={creditLimit} onChange={(event) => setCreditLimit(event.target.value)} disabled={!editable} /></label><label>Días<Input inputMode="numeric" value={creditDays} onChange={(event) => setCreditDays(event.target.value)} disabled={!editable} /></label></>}</>}</div>{canViewCredit && <div className="customer-financial-summary"><span>Saldo <strong>{money(master.commercial.outstanding_amount)}</strong></span><span>Disponible <strong>{master.commercial.credit_enabled ? money(master.commercial.available_credit) : "—"}</strong></span></div>}{editable && <Button type="submit" variant="primary" loading={saving}>Guardar Comercial</Button>}</form>}
    {tab === "receivables" && <>{canViewCredit ? <section className="customer-credit-summary"><div className="customer-financial-summary"><span>Documentos abiertos <strong>{master.receivables_summary?.document_count ?? 0}</strong></span><span>Saldo <strong>{money(master.receivables_summary?.outstanding_amount)}</strong></span><span>Vencidos <strong>{master.receivables_summary?.overdue_count ?? 0} · {money(master.receivables_summary?.overdue_amount)}</strong></span></div><p className="settings-note">Consulta documentos, recibos y registra abonos desde Cuentas por cobrar para conservar un solo flujo operativo.</p><Link className="ui-button ui-button--secondary ui-button--md" href={`/satrapy/ventas/cuentas-por-cobrar?customer=${customerId}`}><span className="ui-button__content">Abrir cuentas por cobrar</span></Link></section> : <p>No tienes permiso para consultar información financiera.</p>}</>}
  </section>{master.is_imported && permissions.includes("import_data") && <section className="customer-adjustment-history"><h3>Solicitudes de ajuste</h3>{adjustments.length ? adjustments.map((item) => <article key={item.id}><span><strong>{adjustmentFieldLabel(item.field_name)}</strong><small>{item.status} · {dateTime(item.created_at)} · {item.reason}</small></span><Badge tone={item.status === "approved" ? "success" : item.status === "rejected" ? "danger" : "warning"}>{item.status === "pending" ? "Pendiente" : item.status === "approved" ? "Aprobado" : "Rechazado"}</Badge></article>) : <p className="customer-master-empty">Sin solicitudes de ajuste.</p>}</section>}<Modal open={adjustmentOpen} onOpenChange={setAdjustmentOpen} eyebrow="Datos protegidos" title="Solicitar ajuste auditado" description="El valor no se modifica hasta que otro administrador autorizado lo revise." footer={<Button type="submit" form="customer-adjustment-form" variant="primary" loading={saving}>Enviar solicitud</Button>}><form id="customer-adjustment-form" className="sales-form" onSubmit={requestAdjustment}><Select ariaLabel="Campo protegido" value={adjustmentField} onValueChange={setAdjustmentField} options={[{ value: "display_name", label: "Nombre" }, { value: "tax_id", label: "RFC" }, { value: "phone", label: "Teléfono principal" }, { value: "address_line", label: "Dirección principal" }, { value: "contact_name", label: "Contacto principal" }, { value: "credit_limit", label: "Límite de crédito" }, { value: "credit_term_days", label: "Días de crédito" }]} /><label>Valor propuesto<Input required value={adjustmentValue} onChange={(event) => setAdjustmentValue(event.target.value)} /></label><label>Motivo<Input required value={adjustmentReason} onChange={(event) => setAdjustmentReason(event.target.value)} /></label><label>Evidencia<Input required value={adjustmentEvidence} onChange={(event) => setAdjustmentEvidence(event.target.value)} placeholder="Documento, archivo o referencia de validación" /></label></form></Modal><Modal open={Boolean(receipt)} onOpenChange={(next) => { if (!next) setReceipt(null); }} eyebrow="Recibo de cobranza" title={receipt?.folio ?? "Recibo"} description="Documento canónico guardado; sus aplicaciones no se pueden modificar." footer={<Button variant="primary" onClick={() => setReceipt(null)}>Cerrar</Button>}>{receipt && <div className="receivable-receipt"><p><span>Cliente</span><strong>{receipt.customer_name}</strong></p><p><span>Fecha</span><strong>{dateTime(receipt.issued_at)}</strong></p><p><span>Forma de pago</span><strong>{receipt.payment_method}</strong></p>{receipt.payment_reference && <p><span>Referencia</span><strong>{receipt.payment_reference}</strong></p>}<p><span>Total</span><strong>{money(receipt.amount, receipt.currency_code)}</strong></p><div>{receipt.applications.map((application, index) => <p key={`${application.reference}-${index}`}><span>{application.reference ?? "Sin referencia"}</span><strong>{money(application.amount_applied, receipt.currency_code)}</strong></p>)}</div></div>}</Modal></Drawer>;
}

export function ReceivablesView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const searchParams = useSearchParams();
  const requestedCustomerId = searchParams.get("customer");
  const { context, loading: contextLoading, error: contextError } = usePosContext(companyId);
  const [query, setQuery] = useState("");
  const [priority, setPriority] = useState<"largest_balance" | "smallest_balance" | "most_overdue" | "least_overdue" | "due_first">("largest_balance");
  const [summary, setSummary] = useState<{ total_outstanding: number; overdue: number; due_next_7_days: number; customers: number } | null>(null);
  const [integrity, setIntegrity] = useState<{ duplicate_document_keys: number; duplicate_sales: number; duplicate_imported_customer_keys: number } | null>(null);
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [customerTotal, setCustomerTotal] = useState(0);
  const [customerPage, setCustomerPage] = useState(1);
  const [customerLoading, setCustomerLoading] = useState(true);
  const [customerLoadingMore, setCustomerLoadingMore] = useState(false);
  const [selected, setSelected] = useState<Customer | null>(null);
  const [customerContext, setCustomerContext] = useState<ReceivableCustomerContext | null>(null);
  const [customerContextLoading, setCustomerContextLoading] = useState(false);
  const [customerContextError, setCustomerContextError] = useState<string | null>(null);
  const [methodId, setMethodId] = useState("");
  const [financialAccounts, setFinancialAccounts] = useState<ReceivableFinancialAccount[]>([]);
  const [financialAccountId, setFinancialAccountId] = useState("");
  const [amount, setAmount] = useState("");
  const [paymentReference, setPaymentReference] = useState("");
  const [documents, setDocuments] = useState<ReceivableDocument[]>([]);
  const [documentTotal, setDocumentTotal] = useState(0);
  const [documentPage, setDocumentPage] = useState(1);
  const [documentQuery, setDocumentQuery] = useState("");
  const [documentDue, setDocumentDue] = useState("all");
  const [preview, setPreview] = useState<FifoPreview[]>([]);
  const [documentsLoading, setDocumentsLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [receipt, setReceipt] = useState<ReceivableReceipt | null>(null);
  const customerRequestRef = useRef(0);
  const idempotency = useRef(new OperationIdempotencyKeys()).current;

  const loadReceivableCustomers = useCallback(async (requestedPage: number, append: boolean, requestedQuery = query) => {
    const request = ++customerRequestRef.current;
    if (append) setCustomerLoadingMore(true); else { setCustomerLoading(true); setCustomerLoadingMore(false); }
    const { data, error: loadError } = await getSupabaseClient().rpc("list_receivable_customers", { p_company_id: companyId, p_query: requestedQuery || null, p_page: requestedPage, p_page_size: 50, p_sort: priority });
    if (request !== customerRequestRef.current) return;
    if (loadError) {
      if (!append) { setCustomers([]); setCustomerTotal(0); setCustomerPage(1); }
      toast({ title: append ? "No se pudieron cargar más clientes" : "No se pudieron cargar las cuentas por cobrar", description: rpcError(loadError, "Los resultados ya visibles permanecen sin cambios."), tone: "error" });
    } else {
      const result = data as { items?: Customer[]; total?: number; page?: number; summary?: typeof summary } | null;
      const nextItems = result?.items ?? [];
      setCustomers((current) => {
        if (!append) return nextItems;
        const merged = new Map(current.map((customer) => [customer.id, customer]));
        for (const customer of nextItems) merged.set(customer.id, customer);
        return [...merged.values()];
      });
      setCustomerTotal(result?.total ?? 0);
      setSummary(result?.summary ?? null);
      setCustomerPage(result?.page ?? requestedPage);
    }
    setCustomerLoading(false); setCustomerLoadingMore(false);
  }, [companyId, priority, query, toast]);

  useEffect(() => { customerRequestRef.current += 1; const timer = window.setTimeout(() => { void loadReceivableCustomers(1, false); }, 120); return () => window.clearTimeout(timer); }, [loadReceivableCustomers]);
  useEffect(() => {
    if (!requestedCustomerId || selected?.id === requestedCustomerId) return;
    let active = true;
    void getSupabaseClient().rpc("get_receivable_customer_context", { p_company_id: companyId, p_customer_id: requestedCustomerId }).then(({ data, error }) => {
      if (!active || error || !data) return;
      const context = data as ReceivableCustomerContext;
      setSelected({ id: context.customer.id, code: context.customer.code, display_name: context.customer.display_name, credit_enabled: true, credit_term_days: context.customer.credit_term_days ?? 0, outstanding_amount: context.summary.outstanding_amount, overdue_amount: context.summary.overdue_amount });
    });
    return () => { active = false; };
  }, [companyId, requestedCustomerId, selected?.id]);
  useEffect(() => { let active = true; void getSupabaseClient().rpc("get_receivable_integrity_audit", { p_company_id: companyId }).then(({ data, error }) => { if (!active || error) return; setIntegrity(data as typeof integrity); }); return () => { active = false; }; }, [companyId]);
  useEffect(() => { if (context) void Promise.resolve().then(() => setMethodId((current) => context.payment_methods.some((method) => method.id === current) ? current : context.payment_methods[0]?.id ?? "")); }, [context]);
  useEffect(() => {
    let active = true;
    void getSupabaseClient().rpc("list_receivable_financial_accounts", { p_company_id: companyId }).then(({ data, error }) => {
      if (!active) return;
      const accounts = error ? [] : (data ?? []) as ReceivableFinancialAccount[];
      setFinancialAccounts(accounts);
      setFinancialAccountId((current) => accounts.some((account) => account.id === current) ? current : accounts.length === 1 ? accounts[0].id : "");
    });
    return () => { active = false; };
  }, [companyId]);

  const method = context?.payment_methods.find((item) => item.id === methodId) ?? null;
  const cashSession = context?.own_open_session?.status === "open" ? context.own_open_session : null;
  const hasIntegrityIssues = Boolean((integrity?.duplicate_document_keys ?? 0) + (integrity?.duplicate_sales ?? 0) + (integrity?.duplicate_imported_customer_keys ?? 0));
  const debtorItemStyle = { display: "grid", gap: 4, minWidth: 0, border: "1px solid var(--line)", borderRadius: "var(--radius-md)", background: "var(--surface-subtle)", padding: "12px 13px" } as const;
  const debtorLabelStyle = { color: "var(--muted)", fontSize: 10, fontWeight: 650, letterSpacing: ".04em", textTransform: "uppercase" as const };
  const debtorValueStyle = { color: "var(--ink)", fontSize: 12, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" as const };
  const debtorHelpStyle = { color: "var(--muted)", fontSize: 10, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" as const };

  useEffect(() => {
    if (!selected) return;
    let active = true;
    void Promise.resolve().then(async () => {
      if (!active) return;
      setCustomerContextLoading(true); setCustomerContextError(null);
      const { data, error } = await getSupabaseClient().rpc("get_receivable_customer_context", { p_company_id: companyId, p_customer_id: selected.id });
      if (!active) return;
      setCustomerContextLoading(false);
      if (error) { setCustomerContext(null); setCustomerContextError(rpcError(error, "No se pudo cargar la ficha del cliente.")); }
      else setCustomerContext(data as ReceivableCustomerContext);
    });
    return () => { active = false; };
  }, [companyId, selected]);

  useEffect(() => {
    if (!selected) return;
    let active = true;
    const timer = window.setTimeout(() => { setDocumentsLoading(true); void getSupabaseClient().rpc("list_customer_open_receivables_page", { p_company_id: companyId, p_customer_id: selected.id, p_query: documentQuery || null, p_due_status: documentDue, p_page: documentPage, p_page_size: 25 }).then(({ data, error }) => {
      if (!active) return; setDocumentsLoading(false);
      if (error) { setDocuments([]); setDocumentTotal(0); toast({ title: "No se pudieron cargar los documentos", description: rpcError(error, "Intenta nuevamente."), tone: "error" }); }
      else { const result = data as ReceivablesPage | null; setDocuments(result?.items ?? []); setDocumentTotal(result?.pagination?.total ?? 0); }
    }); }, 150);
    return () => { active = false; window.clearTimeout(timer); };
  }, [companyId, documentDue, documentPage, documentQuery, selected, toast]);

  useEffect(() => {
    const numericAmount = Number(amount);
    if (!selected || !Number.isFinite(numericAmount) || numericAmount <= 0) return;
    let active = true;
    const timer = window.setTimeout(() => { void getSupabaseClient().rpc("preview_receivable_payment_fifo", { p_company_id: companyId, p_customer_id: selected.id, p_amount: numericAmount }).then(({ data, error }) => { if (!active) return; setPreview(error ? [] : (data ?? []) as FifoPreview[]); }); }, 220);
    return () => { active = false; window.clearTimeout(timer); };
  }, [amount, companyId, selected]);

  async function recordPayment(event: React.FormEvent) {
    event.preventDefault(); if (!selected || !method) return;
    if (method.settlement_kind === "cash_drawer" && !cashSession) { toast({ title: "Abre una caja", description: "Un abono en efectivo requiere una sesión propia abierta.", tone: "error" }); return; }
    if (method.settlement_kind === "external" && !paymentReference.trim()) { toast({ title: "Falta la referencia", description: "Los pagos externos requieren una referencia bancaria o documental.", tone: "error" }); return; }
    if (method.settlement_kind === "external" && !financialAccountId) { toast({ title: "Falta la cuenta receptora", description: "Indica en qué cuenta financiera se recibió el cobro.", tone: "error" }); return; }
    setBusy(true);
    const operationFingerprint = JSON.stringify({ companyId, customerId: selected.id, methodId: method.id, amount: Number(amount), cashSessionId: method.settlement_kind === "cash_drawer" ? cashSession?.id : null, paymentReference: paymentReference.trim() || null, financialAccountId: method.settlement_kind === "external" ? financialAccountId : null });
    const { data, error } = await getSupabaseClient().rpc("record_receivable_payment_to_account", { p_company_id: companyId, p_customer_id: selected.id, p_payment_method_id: method.id, p_amount: Number(amount), p_cash_session_id: method.settlement_kind === "cash_drawer" ? cashSession?.id : null, p_client_request_id: idempotency.get("receivable-payment", operationFingerprint), p_payment_reference: paymentReference.trim() || null, p_financial_account_id: method.settlement_kind === "external" ? financialAccountId : null });
    if (error) toast({ title: "No se pudo registrar el abono", description: rpcError(error, "Verifica el saldo y la forma de pago."), tone: "error" });
    else {
      idempotency.clear("receivable-payment"); const result = data as { receipt?: ReceivableReceipt };
      setReceipt(result.receipt ?? null); toast({ title: "Abono aplicado", description: "La aplicación FIFO y el recibo quedaron guardados.", tone: "success" });
      setAmount(""); setPaymentReference(""); setPreview([]); setSelected(null); setCustomerContext(null); setCustomerContextError(null); setQuery(""); await loadReceivableCustomers(1, false, "");
    }
    setBusy(false);
  }

  function selectCustomer(customer: Customer) {
    setSelected(customer); setCustomerContext(null); setCustomerContextError(null); setDocuments([]); setDocumentTotal(0); setDocumentPage(1); setDocumentQuery(""); setDocumentDue("all"); setPreview([]); setDocumentsLoading(true);
  }

  if (contextLoading) return <div className="content-frame receivables-page">
    <ReceivablesModuleHeader active="cartera" title="Cuentas por cobrar" description="Localiza al cliente con saldo pendiente, confirma sus datos de cobranza y registra el abono con aplicación FIFO." showGestiones={permissions.includes("view_collection_automation")} tabsLabel="Vistas de cuentas por cobrar" />
    <div aria-busy="true" aria-live="polite"><div className="receivables-loading-overview" aria-hidden="true"><i /><i /><i /><i /></div><div className="receivables-loading-grid"><DataState loading error={null} hasData={0} empty="">{null}</DataState><DataState loading error={null} hasData={0} empty="">{null}</DataState></div></div>
  </div>;
  if (contextError || !context) return <div className="content-frame receivables-page">
    <ReceivablesModuleHeader active="cartera" title="Cuentas por cobrar" description="Localiza al cliente con saldo pendiente, confirma sus datos de cobranza y registra el abono con aplicación FIFO." showGestiones={permissions.includes("view_collection_automation")} tabsLabel="Vistas de cuentas por cobrar" />
    <DataState loading={false} error={contextError ?? "No se pudo cargar cuentas por cobrar."} hasData={0} empty="">{null}</DataState>
  </div>;

  return <div className="content-frame receivables-page">
    <ReceivablesModuleHeader active="cartera" title="Cuentas por cobrar" description="Localiza al cliente con saldo pendiente, confirma sus datos de cobranza y registra el abono con aplicación FIFO." showGestiones={permissions.includes("view_collection_automation")} tabsLabel="Vistas de cuentas por cobrar" />
    <section className="receivables-overview" aria-label="Resumen de cobranza" style={{ display: "grid", gridTemplateColumns: "repeat(4, minmax(0, 1fr))", gap: 12, marginBottom: 20 }}>
      <article style={{ display: "grid", gap: 5, border: "1px solid var(--line)", borderRadius: "var(--radius-lg)", background: "var(--surface)", padding: "14px 16px" }}><span>Saldo total</span><strong>{money(summary?.total_outstanding)}</strong><small>{summary?.customers ?? 0} clientes con saldo pendiente</small></article>
      <article style={{ display: "grid", gap: 5, border: "1px solid var(--line)", borderRadius: "var(--radius-lg)", background: "var(--surface)", padding: "14px 16px" }}><span>Vencido</span><strong>{money(summary?.overdue)}</strong><small>requiere seguimiento prioritario</small></article>
      <article style={{ display: "grid", gap: 5, border: "1px solid var(--line)", borderRadius: "var(--radius-lg)", background: "var(--surface)", padding: "14px 16px" }}><span>Vence en 7 días</span><strong>{money(summary?.due_next_7_days)}</strong><small>preparar recordatorio</small></article>
      <article className={hasIntegrityIssues ? "is-warning" : ""} style={{ display: "grid", gap: 5, border: `1px solid ${hasIntegrityIssues ? "#ecd79f" : "var(--line)"}`, borderRadius: "var(--radius-lg)", background: hasIntegrityIssues ? "var(--warning-soft)" : "var(--surface)", padding: "14px 16px" }}><span>Integridad</span><strong>{hasIntegrityIssues ? "Revisar" : integrity ? "Verificado" : "Validando"}</strong><small>{hasIntegrityIssues ? "Hay duplicados que requieren revisión." : integrity ? "Sin duplicados detectados." : "Comprobando saldos."}</small></article>
    </section>
    <div className="receivables-layout">
      <section className="receivables-search" aria-label="Selector de clientes con saldo pendiente" style={{ gap: 10 }}>
        <div className="receivables-search__heading" style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr) auto", alignItems: "center", gap: 12 }}>
          <div style={{ minWidth: 0 }}><h2 style={{ margin: 0, fontSize: 18 }}>Clientes con saldo pendiente</h2></div>
          <Select ariaLabel="Priorizar cobranza" value={priority} onValueChange={(value) => { setPriority(value as typeof priority); setCustomerPage(1); }} options={[{ value: "largest_balance", label: "Mayor saldo pendiente" }, { value: "smallest_balance", label: "Menor saldo pendiente" }, { value: "most_overdue", label: "Mayor saldo vencido" }, { value: "least_overdue", label: "Menor saldo vencido" }, { value: "due_first", label: "Vencimiento más próximo" }]} style={{ width: 190, minHeight: 36 }} />
        </div>
        <label>Buscar cliente con saldo pendiente<Input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Nombre, código, teléfono o correo" /></label>
        <small className="settings-note">{customerLoading ? "Buscando…" : `${customers.length} de ${customerTotal} clientes con saldo pendiente`}</small>
        <div className="receivables-customer-list">
          {customers.length ? customers.map((customer) => <button className={selected?.id === customer.id ? "is-selected" : ""} key={customer.id} onClick={() => selectCustomer(customer)}><span><strong>{customer.display_name}</strong><small>{customer.code}{customer.next_due_date ? ` · vence ${new Date(`${customer.next_due_date}T12:00:00`).toLocaleDateString("es-MX")}` : ""}</small></span><em>{customer.overdue_amount ? "Vencido" : "Al corriente"}</em><b>{money(customer.outstanding_amount)}</b></button>) : !customerLoading && <p>Sin clientes con saldo pendiente para esta búsqueda.</p>}
          {!customerLoading && customers.length < customerTotal && <Button className="receivables-load-more" variant="secondary" loading={customerLoadingMore} onClick={() => void loadReceivableCustomers(customerPage + 1, true)}>Cargar más clientes</Button>}
        </div>
      </section>
      <section className={`receivables-payment${selected && (selected.outstanding_amount ?? 0) <= 0 ? " is-settled" : ""}`}>
        {!selected && <div className="receivables-empty"><strong>Selecciona un cliente con saldo pendiente</strong><p>Aquí verás sus datos de contacto, documentos abiertos y el registro de abonos.</p></div>}
        {selected && <>
          <header className="receivables-payment__heading" style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 16, borderBottom: "1px solid var(--line)", paddingBottom: 14 }}><div style={{ minWidth: 0 }}><span className="eyebrow">Expediente de cobranza</span><h2 style={{ margin: "4px 0", fontSize: 21, letterSpacing: "-.03em" }}>{customerContext?.customer.display_name ?? selected.display_name}</h2><p style={{ margin: 0, color: "var(--muted)", fontSize: 12 }}>{customerContext?.customer.code ?? selected.code} · Saldo abierto <strong style={{ color: "var(--ink)" }}>{money(selected.outstanding_amount)}</strong></p></div><Link href={`/satrapy/ventas/clientes/${selected.id}`} className="receivables-customer-link" style={{ flex: "0 0 auto", border: "1px solid var(--line-strong)", borderRadius: "var(--radius-sm)", padding: "8px 10px", color: "var(--accent-strong)", fontSize: 11, fontWeight: 650, textDecoration: "none" }}>Ver cliente</Link></header>
          {customerContextLoading && <p className="customer-master-empty">Cargando datos de contacto…</p>}
          {customerContextError && <p className="receivables-context-error">{customerContextError}</p>}
          {customerContext && <section className="receivables-debtor-card" aria-label="Datos para cobranza" style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 8 }}><div style={debtorItemStyle}><span style={debtorLabelStyle}>Contacto principal</span><strong style={debtorValueStyle}>{customerContext.contact?.display_name ?? "Sin contacto"}</strong><small style={debtorHelpStyle}>{[customerContext.contact?.role_name, customerContext.contact?.phone, customerContext.contact?.email].filter(Boolean).join(" · ") || "Registra teléfono o correo en el cliente."}</small></div><div style={debtorItemStyle}><span style={debtorLabelStyle}>Dirección</span><strong style={debtorValueStyle}>{customerContext.address?.label ?? "Sin dirección"}</strong><small style={debtorHelpStyle}>{customerContext.address ? [customerContext.address.address_line, customerContext.address.neighborhood, customerContext.address.municipality, customerContext.address.state_name, customerContext.address.postal_code].filter(Boolean).join(", ") : "Registra una dirección en el cliente."}</small></div><div style={debtorItemStyle}><span style={debtorLabelStyle}>Condición</span><strong style={debtorValueStyle}>{customerContext.customer.credit_term_days ? `${customerContext.customer.credit_term_days} días de crédito` : "Sin plazo registrado"}</strong><small style={debtorHelpStyle}>{customerContext.customer.payment_manager ? `Encargado: ${customerContext.customer.payment_manager}` : "Sin encargado de pagos"}</small></div><div style={debtorItemStyle}><span style={debtorLabelStyle}>Saldo vencido</span><strong style={debtorValueStyle}>{money(customerContext.summary.overdue_amount)}</strong><small style={debtorHelpStyle}>{customerContext.summary.overdue_count} documento(s) vencido(s)</small></div></section>}
          <DataToolbar search={documentQuery} onSearchChange={(value) => { setDocumentQuery(value); setDocumentPage(1); }} placeholder="Buscar referencia" filters={<Select ariaLabel="Filtrar documentos por vencimiento" value={documentDue} onValueChange={(value) => { setDocumentDue(value); setDocumentPage(1); }} options={[{ value: "all", label: "Todos" }, { value: "overdue", label: "Vencidos" }, { value: "due_7_days", label: "Vencen en 7 días" }, { value: "future", label: "Posteriores" }]} />} activeFilters={(documentQuery ? 1 : 0) + (documentDue !== "all" ? 1 : 0)} onClear={() => { setDocumentQuery(""); setDocumentDue("all"); setDocumentPage(1); }} results={documentTotal} />
          <div className="table-wrap surface-table receivables-documents"><table><thead><tr><th>Documento</th><th>Emisión</th><th>Vencimiento</th><th className="number-cell">Importe</th><th className="number-cell">Saldo</th></tr></thead><tbody>{documents.map((document) => <tr key={document.id}><td className="mono">{document.reference ?? "Sin referencia"}</td><td>{new Date(document.issued_at).toLocaleDateString("es-MX")}</td><td>{new Date(`${document.due_date}T12:00:00`).toLocaleDateString("es-MX")}</td><td className="number-cell">{money(document.original_amount, document.currency_code)}</td><td className="number-cell"><strong>{money(document.outstanding_amount, document.currency_code)}</strong></td></tr>)}</tbody></table>{documentsLoading && <p className="customer-master-empty">Cargando documentos…</p>}{!documentsLoading && !documents.length && <p className="customer-master-empty">Sin documentos abiertos para estos filtros.</p>}</div>
          <Pagination page={documentPage} total={documentTotal} pageSize={25} onChange={setDocumentPage} />
          <form className="sales-form receivables-payment-form" onSubmit={recordPayment}><h3>Registrar abono</h3><Select ariaLabel="Forma de pago del abono" value={methodId} onValueChange={setMethodId} options={context.payment_methods.map((payment) => ({ value: payment.id, label: payment.name }))} />{method?.settlement_kind === "external" && <Select ariaLabel="Cuenta financiera receptora" value={financialAccountId} onValueChange={setFinancialAccountId} placeholder="Cuenta receptora" options={financialAccounts.map((account) => ({ value: account.id, label: `${account.alias} · ${account.currency_code} · ${account.masked_ending}` }))} />}<div className="sales-form__row"><label><span className="field-label-with-help">Importe<span className="fifo-help fifo-help--inline"><button type="button" aria-describedby="fifo-help-text" aria-label="Cómo se aplica este abono"><CircleHelp size={15} strokeWidth={2} aria-hidden="true" /></button><span id="fifo-help-text" className="fifo-help__tooltip" role="tooltip">El abono se aplica primero a los documentos con vencimiento más antiguo.</span></span></span><CurrencyInput required value={amount} onValueChange={(value) => { setAmount(value); setPreview([]); }} currency="MXN" aria-label="Importe del abono" placeholder={money(selected.outstanding_amount)} /></label><label>Referencia {method?.settlement_kind === "external" ? "obligatoria" : "opcional"}<Input required={method?.settlement_kind === "external"} value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} placeholder={method?.settlement_kind === "external" ? "Transferencia, depósito o terminal" : "Nota del cobro"} /></label></div>{method?.settlement_kind === "cash_drawer" && <small className="settings-note">Este abono afectará la caja abierta.</small>}{preview.length > 0 && <div className="fifo-preview"><div className="fifo-preview__heading"><strong>Aplicación FIFO prevista</strong></div>{preview.map((item) => <span key={item.receivable_id}><b>{item.reference ?? "Sin referencia"}</b><small>{money(item.amount_applied)} · saldo posterior {money(item.remaining_after)}</small></span>)}</div>}<Button type="submit" variant="primary" loading={busy} disabled={!preview.length || method?.settlement_kind === "external" && !financialAccountId}>Registrar abono y generar recibo</Button></form>
        </>}
      </section>
    </div>
    <Modal open={Boolean(receipt)} onOpenChange={(open) => { if (!open) setReceipt(null); }} eyebrow="Recibo de cobranza" title={receipt?.folio ?? "Recibo"} description="Documento canónico guardado; sus aplicaciones no se pueden modificar." footer={<Button variant="primary" onClick={() => setReceipt(null)}>Cerrar</Button>}>{receipt && <div className="receivable-receipt"><p><span>Cliente</span><strong>{receipt.customer_name}</strong></p><p><span>Fecha</span><strong>{dateTime(receipt.issued_at)}</strong></p><p><span>Forma de pago</span><strong>{receipt.payment_method}</strong></p>{receipt.payment_reference && <p><span>Referencia</span><strong>{receipt.payment_reference}</strong></p>}<p><span>Total</span><strong>{money(receipt.amount, receipt.currency_code)}</strong></p><div>{receipt.applications.map((application, index) => <p key={`${application.reference}-${index}`}><span>{application.reference ?? "Sin referencia"}</span><strong>{money(application.amount_applied, receipt.currency_code)}</strong></p>)}</div></div>}</Modal>
  </div>;
}

export function CashDeskView({ companyId }: { companyId: string }) {
  const { toast } = useToast(); const { context, loading, error, reload } = usePosContext(companyId); const [registerId, setRegisterId] = useState(""); const [denominations, setDenominations] = useState<Array<{ id: string; value: number; display_name: string }>>([]); const [counts, setCounts] = useState<Record<string, string>>({}); const [reason, setReason] = useState(""); const [busy, setBusy] = useState(false); const [result, setResult] = useState<{ status: string; expected_amount?: number; counted_amount?: number; variance_amount?: number } | null>(null); const [dashboard, setDashboard] = useState<CashDashboard | null>(null); const [movements, setMovements] = useState<Array<{ id: string; movement_type: string; amount: number; reason: string | null; occurred_at: string }>>([]); const [movementPage, setMovementPage] = useState(1); const [movementTotal, setMovementTotal] = useState(0); const [movementType, setMovementType] = useState<"paid_in" | "paid_out">("paid_in"); const [movementAmount, setMovementAmount] = useState(""); const [movementReason, setMovementReason] = useState(""); const [variances, setVariances] = useState<Array<{ cash_session_id: string; variance_amount: number; variance_reason: string | null }>>([]); const idempotency = useRef(new OperationIdempotencyKeys()).current;
  useEffect(() => { if (!context) return; const own = context.own_open_session; void Promise.resolve().then(() => setRegisterId(own?.cash_register_id ?? (context.registers.length === 1 ? context.registers[0].id : ""))); }, [context]);
  const register = context?.registers.find((item) => item.id === registerId) ?? null; const session = context?.own_open_session?.status === "open" && context.own_open_session.cash_register_id === registerId ? context.own_open_session : null;
  useEffect(() => { if (!register) return; void (async () => { const { data } = await getSupabaseClient().from("cash_denominations").select("id, value, display_name").eq("company_id", companyId).eq("currency_code", register.currency_code).eq("is_active", true).order("value", { ascending: false }); setDenominations((data ?? []) as Array<{ id: string; value: number; display_name: string }>); })(); }, [companyId, register]);
  const countLines = useMemo(() => denominations.map((denomination) => ({ denomination_id: denomination.id, quantity: Number(counts[denomination.id] || 0) })), [counts, denominations]);
  const counted = useMemo(() => denominations.reduce((sum, denomination) => sum + denomination.value * Number(counts[denomination.id] || 0), 0), [counts, denominations]);
  async function open() { if (!register) return; setBusy(true); const fingerprint = JSON.stringify({ companyId, registerId: register.id, countLines }); const { error: openError } = await getSupabaseClient().rpc("open_cash_session", { p_company_id: companyId, p_cash_register_id: register.id, p_count_lines: countLines, p_client_request_id: idempotency.get("open-cash-session", fingerprint) }); if (openError) toast({ title: "No se pudo abrir", description: rpcError(openError, "Intenta nuevamente."), tone: "error" }); else { idempotency.clear("open-cash-session"); toast({ title: "Caja abierta", tone: "success" }); setCounts({}); await reload(); } setBusy(false); }
  async function close() { if (!session) return; setBusy(true); const fingerprint = JSON.stringify({ sessionId: session.id, countLines, reason: reason || null }); const { data, error: closeError } = await getSupabaseClient().rpc("close_cash_session", { p_cash_session_id: session.id, p_count_lines: countLines, p_variance_reason: reason || null, p_client_request_id: idempotency.get("close-cash-session", fingerprint) }); if (closeError) toast({ title: "No se pudo cerrar", description: rpcError(closeError, "Revisa el conteo y el motivo."), tone: "error" }); else { idempotency.clear("close-cash-session"); setResult(data as { status: string; expected_amount?: number; counted_amount?: number; variance_amount?: number }); await reload(); } setBusy(false); }
  const loadOperations = useCallback(async () => { if (session) { const client = getSupabaseClient(); const [{ data: dashboardData }, { data: movementData }] = await Promise.all([client.rpc("get_cash_session_dashboard", { p_cash_session_id: session.id }), client.rpc("list_cash_session_movements_page", { p_cash_session_id: session.id, p_page: movementPage, p_page_size: 25 })]); setDashboard((dashboardData ?? null) as CashDashboard | null); const movementResult = movementData as { items?: typeof movements; total?: number } | null; setMovements((movementResult?.items ?? []).map((movement) => ({ ...movement, movement_type: cashMovementLabel(movement.movement_type) }))); setMovementTotal(movementResult?.total ?? 0); } else { setDashboard(null); setMovements([]); setMovementTotal(0); } const { data } = await getSupabaseClient().rpc("list_pending_cash_variances", { p_company_id: companyId }); setVariances((data ?? []) as typeof variances); }, [companyId, movementPage, session]);
  useEffect(() => { void Promise.resolve().then(loadOperations); }, [loadOperations]);
  async function recordMovement(event: React.FormEvent) { event.preventDefault(); if (!session) return; setBusy(true); const { error: movementError } = await getSupabaseClient().rpc("record_cash_drawer_movement", { p_cash_session_id: session.id, p_movement_type: movementType, p_amount: Number(movementAmount), p_reason: movementReason }); if (movementError) toast({ title: "No se pudo registrar el movimiento", description: rpcError(movementError, "Verifica importe y motivo."), tone: "error" }); else { setMovementAmount(""); setMovementReason(""); await loadOperations(); toast({ title: "Movimiento registrado", tone: "success" }); } setBusy(false); }
  async function approveVariance(id: string) { setBusy(true); const fingerprint = JSON.stringify({ cashSessionId: id }); const { error: approvalError } = await getSupabaseClient().rpc("approve_cash_variance", { p_cash_session_id: id, p_approval_reason: null, p_client_request_id: idempotency.get("approve-cash-variance", fingerprint) }); if (approvalError) toast({ title: "No se pudo aprobar la diferencia", description: rpcError(approvalError, "Revisa permisos y ubicación."), tone: "error" }); else { idempotency.clear("approve-cash-variance"); await loadOperations(); toast({ title: "Diferencia aprobada", tone: "success" }); } setBusy(false); }
  if (loading) return <div className="content-frame"><DataState loading error={null} hasData={0} empty="">{null}</DataState></div>; if (error || !context) return <div className="content-frame"><DataState loading={false} error={error ?? "No se pudo cargar Caja."} hasData={0} empty="">{null}</DataState></div>;
  const multipleRegistersNeedChoice = !context.own_open_session && context.registers.length > 1 && !registerId;
  const currency = dashboard?.currency_code ?? register?.currency_code ?? "MXN"; const realtimeVariance = counted - Number(dashboard?.expected_cash ?? 0);
  return <div className="content-frame"><PageTitle eyebrow="Turno y arqueo" title="Caja" description="Apertura, movimientos y cierre del turno con cálculo definitivo en servidor." />{dashboard && <section className="cash-session-context"><span><small>Caja</small><strong>{dashboard.register_name} · {dashboard.register_code}</strong></span><span><small>Ubicación</small><strong>{dashboard.location_name}</strong></span><span><small>Cajero</small><strong>{dashboard.cashier_name}</strong></span><span><small>Apertura</small><strong>{dateTime(dashboard.opened_at)}</strong></span></section>} {dashboard && <section className="cash-live-summary"><article><span>Efectivo esperado</span><strong>{money(dashboard.expected_cash, currency)}</strong></article><article><span>Total contado</span><strong>{money(counted, currency)}</strong></article><article className={realtimeVariance === 0 ? "" : "is-warning"}><span>Diferencia en tiempo real</span><strong>{money(realtimeVariance, currency)}</strong></article><article><span>Ventas de contado</span><strong>{money(dashboard.cash_sales, currency)}</strong></article></section>}<div className="cash-workspace"><section className="cash-card">{context.own_open_session ? <p className="settings-note">Tu sesión está ligada a esta caja y no puede cambiarse desde el POS.</p> : <Select ariaLabel="Caja" value={registerId} onValueChange={setRegisterId} options={[{ value: "", label: multipleRegistersNeedChoice ? "Selecciona una caja" : "Sin cajas disponibles" }, ...context.registers.map((item) => ({ value: item.id, label: `${item.name} · ${item.code}` }))]} />}{session ? <Badge tone="success">Sesión abierta</Badge> : <Badge>Sin sesión abierta</Badge>}<h2>{session ? "Arqueo de cierre" : "Apertura de caja"}</h2>{multipleRegistersNeedChoice ? <p>Selecciona explícitamente la caja física que abrirás.</p> : !register ? <p>No hay una caja disponible para tu ubicación.</p> : <><p>Confirma todas las denominaciones, incluyendo las que tienen cantidad cero. El total definitivo se calcula en servidor.</p><DenominationCount denominations={denominations} counts={counts} onChange={setCounts} currency={register.currency_code} /><div className="cash-count-total">Total contado <strong>{money(counted, register.currency_code)}</strong></div>{session && <label className="cash-reason">Motivo de diferencia si aplica<Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Obligatorio si hay diferencia" /></label>}<Button variant="primary" loading={busy} onClick={() => void (session ? close() : open())}>{session ? "Solicitar cierre" : "Abrir caja"}</Button></>}</section><section className="cash-card cash-card--info"><ClipboardList size={22} /><h2>Movimientos del turno</h2>{session && <form className="cash-movement-form" onSubmit={recordMovement}><Select ariaLabel="Tipo de movimiento" value={movementType} onValueChange={(value) => setMovementType(value as "paid_in" | "paid_out")} options={[{ value: "paid_in", label: "Ingreso de efectivo" }, { value: "paid_out", label: "Salida de efectivo" }]} /><label>Importe<Input required min="0.01" step="0.01" inputMode="decimal" value={movementAmount} onChange={(event) => setMovementAmount(event.target.value)} /></label><label>Motivo<Input required value={movementReason} onChange={(event) => setMovementReason(event.target.value)} /></label><Button type="submit" loading={busy}>Registrar</Button></form>}{movements.length > 0 && <div className="cash-movement-list">{movements.map((movement) => <p key={movement.id}><span><b>{movement.movement_type}</b><small>{dateTime(movement.occurred_at)} · {movement.reason ?? "Sin motivo"}</small></span><strong>{money(movement.amount, currency)}</strong></p>)}</div>}<Pagination page={movementPage} total={movementTotal} pageSize={25} onChange={setMovementPage} />{variances.length > 0 && <div className="cash-movement-list"><strong>Diferencias pendientes</strong>{variances.map((variance) => <p key={variance.cash_session_id}><span>{money(variance.variance_amount)} · {variance.variance_reason ?? "Sin motivo"}</span><Button size="sm" onClick={() => void approveVariance(variance.cash_session_id)}>Aprobar</Button></p>)}</div>}<ul><li>Una diferencia nunca se cierra automáticamente.</li><li>La aprobación debe hacerla otra persona autorizada.</li></ul>{result && <div className={result.variance_amount ? "cash-result is-warning" : "cash-result"}><strong>{result.status === "closed" ? "Caja cerrada" : "Aprobación pendiente"}</strong>{result.expected_amount !== undefined && <span>Esperado {money(result.expected_amount)} · contado {money(result.counted_amount)} · diferencia {money(result.variance_amount)}</span>}</div>}</section></div></div>;
}

export function SalesSettingsView({ companyId, permissions, experience="core", initialResource }: { companyId: string; permissions: string[]; experience?: ProductExperience; initialResource?: SettingsResourceKey }) {
  const { toast } = useToast();
  const router = useRouter();
  const searchParams = useSearchParams();
  const canPayments = permissions.includes("manage_payment_methods"); const canRegisters = permissions.includes("manage_locations"); const canPrices = permissions.includes("manage_prices"); const canAssortments = permissions.includes("manage_assortments"); const canDiscounts = permissions.includes("manage_discount_policies"); const canTicketBranding = permissions.includes("manage_ticket_branding"); const canQuoteBranding = experience === "core" && permissions.includes("manage_quote_branding");
  const allowedResources: SettingsResourceKey[] = [...(canPayments ? ["payments" as const, "denominations" as const] : []), ...(canRegisters ? ["registers" as const] : []), ...(canPrices ? ["prices" as const] : []), ...(canAssortments ? ["assortments" as const] : []), ...(canDiscounts ? ["volume" as const, "discounts" as const] : []), ...(canTicketBranding ? ["ticket" as const] : []), ...(canQuoteBranding ? ["quote" as const] : [])];
  const requestedCandidate = settingsResourceFromQuery(searchParams.get("seccion")) ?? initialResource;
  const requestedResource = requestedCandidate && allowedResources.includes(requestedCandidate) ? requestedCandidate : allowedResources[0] ?? "payments";
  const [payments, setPayments] = useState<Array<{ id: string; code: string; display_name: string; settlement_kind: string; is_active: boolean }>>([]);
  const [registers, setRegisters] = useState<Array<{ id: string; code: string; display_name: string; location_id: string; currency_code: string; is_active: boolean }>>([]);
  const [denominations, setDenominations] = useState<Array<{ id: string; value: number; display_name: string; currency_code: string; is_active: boolean }>>([]);
  const [locations, setLocations] = useState<Array<{ id: string; name: string; external_code: string; default_price_list_id: string | null }>>([]);
  const [priceLists, setPriceLists] = useState<Array<{ id: string; name: string; currency_code: string }>>([]);
  const [roles, setRoles] = useState<Array<{ id: string; display_name: string }>>([]);
  const [discountLimits, setDiscountLimits] = useState<Array<{ id: string; role_id: string; scope: "sale" | "line"; max_percent: number; valid_from: string; valid_to: string | null }>>([]);
  const [activeAssortmentCount, setActiveAssortmentCount] = useState(0);
  const [loading, setLoading] = useState(true); const [loadError, setLoadError] = useState<string | null>(null); const [saving, setSaving] = useState(false);
  const [starterBusy, setStarterBusy] = useState(false);
  const [setupExpanded, setSetupExpanded] = useState(false);
  const resource = requestedResource; const [query, setQuery] = useState(""); const [statusFilter, setStatusFilter] = useState("all"); const [page, setPage] = useState(1);
  const [drawer, setDrawer] = useState<SettingsDrawer | null>(null); const [confirmation, setConfirmation] = useState<SettingsConfirmation | null>(null);
  const [paymentId, setPaymentId] = useState<string | null>(null); const [paymentCode, setPaymentCode] = useState(""); const [paymentName, setPaymentName] = useState(""); const [paymentKind, setPaymentKind] = useState("cash_drawer"); const [paymentActive, setPaymentActive] = useState(true);
  const [registerEditId, setRegisterEditId] = useState<string | null>(null); const [registerCode, setRegisterCode] = useState(""); const [registerName, setRegisterName] = useState(""); const [registerLocationId, setRegisterLocationId] = useState(""); const [registerActive, setRegisterActive] = useState(true);
  const [denominationId, setDenominationId] = useState<string | null>(null); const [denominationValue, setDenominationValue] = useState(""); const [denominationName, setDenominationName] = useState(""); const [denominationActive, setDenominationActive] = useState(true);
  const [locationPriceLocationId, setLocationPriceLocationId] = useState(""); const [locationPriceListId, setLocationPriceListId] = useState("");
  const [roleId, setRoleId] = useState(""); const [discountScope, setDiscountScope] = useState("sale"); const [discountLimit, setDiscountLimit] = useState(""); const [discountValidFrom, setDiscountValidFrom] = useState(""); const [discountValidTo, setDiscountValidTo] = useState("");
  const load = useCallback(async () => {
    setLoading(true);
    const client = getSupabaseClient();
    const [paymentResult, registerResult, denominationResult, locationResult, listResult, roleResult, discountResult, assortmentResult] = await Promise.all([
      client.from("payment_methods").select("id, code, display_name, settlement_kind, is_active").eq("company_id", companyId).order("display_name"),
      client.from("cash_registers").select("id, code, display_name, location_id, currency_code, is_active").eq("company_id", companyId).order("display_name"),
      client.from("cash_denominations").select("id, value, display_name, currency_code, is_active").eq("company_id", companyId).order("value", { ascending: false }),
      client.from("locations").select("id, name, external_code, default_price_list_id").eq("company_id", companyId).eq("is_active", true).order("name"),
      client.from("price_lists").select("id, name, currency_code").eq("company_id", companyId).eq("is_active", true).eq("status", "active").order("name"),
      client.from("roles").select("id, display_name").order("display_name"),
      client.from("discount_role_limits").select("id, role_id, scope, max_percent, valid_from, valid_to").eq("company_id", companyId).order("valid_from", { ascending: false }),
      client.from("sales_assortments").select("id", { count: "exact", head: true }).eq("company_id", companyId).eq("status", "active"),
    ]);
    setPayments((paymentResult.data ?? []) as typeof payments); setRegisters((registerResult.data ?? []) as typeof registers); setDenominations((denominationResult.data ?? []) as typeof denominations); setLocations((locationResult.data ?? []) as typeof locations); setPriceLists((listResult.data ?? []) as typeof priceLists); setRoles((roleResult.data ?? []) as typeof roles);
    setDiscountLimits((discountResult.data ?? []) as typeof discountLimits);
    setActiveAssortmentCount(assortmentResult.count ?? 0);
    setLoadError([paymentResult.error, registerResult.error, denominationResult.error, locationResult.error, listResult.error, roleResult.error, discountResult.error].find(Boolean)?.message ?? null);
    setRegisterLocationId((current) => current || (locationResult.data?.[0]?.id ?? "")); setLocationPriceLocationId((current) => current || (locationResult.data?.[0]?.id ?? "")); setLocationPriceListId((current) => current || (listResult.data?.[0]?.id ?? "")); setRoleId((current) => current || (roleResult.data?.[0]?.id ?? "")); setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  function changeResource(next: SettingsResourceKey) { setPage(1); setStatusFilter("all"); setQuery(""); const nextIsWide = next === "assortments" || next === "prices" || next === "volume"; router.push(next === "payments" ? "/satrapy/configuracion/ventas" : `/satrapy/configuracion/ventas?seccion=${next}`, { scroll: nextIsWide }); }
  function closeDrawer() { setDrawer(null); }
  function openPayment(item?: typeof payments[number]) { setPaymentId(item?.id ?? null); setPaymentCode(item?.code ?? ""); setPaymentName(item?.display_name ?? ""); setPaymentKind(item?.settlement_kind ?? "cash_drawer"); setPaymentActive(item?.is_active ?? true); setDrawer("payment"); }
  function openRegister(item?: typeof registers[number]) { setRegisterEditId(item?.id ?? null); setRegisterCode(item?.code ?? ""); setRegisterName(item?.display_name ?? ""); setRegisterLocationId(item?.location_id ?? locations[0]?.id ?? ""); setRegisterActive(item?.is_active ?? true); setDrawer("register"); }
  function openDenomination(item?: typeof denominations[number]) { setDenominationId(item?.id ?? null); setDenominationValue(item ? String(item.value) : ""); setDenominationName(item?.display_name ?? ""); setDenominationActive(item?.is_active ?? true); setDrawer("denomination"); }
  function openAssignment(location?: typeof locations[number]) { setLocationPriceLocationId(location?.id ?? locations[0]?.id ?? ""); setLocationPriceListId(location?.default_price_list_id ?? priceLists[0]?.id ?? ""); setDrawer("assignment"); }
  function openDiscount() { setRoleId(roles[0]?.id ?? ""); setDiscountScope("sale"); setDiscountLimit(""); setDiscountValidFrom(""); setDiscountValidTo(""); setDrawer("discount"); }
  async function submitPayment(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_payment_method", { p_company_id: companyId, p_payment_method_id: paymentId, p_code: paymentCode, p_display_name: paymentName, p_settlement_kind: paymentKind, p_is_active: paymentActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica el medio de pago."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: paymentId ? "Forma de pago actualizada" : "Forma de pago creada", tone: "success" }); } setSaving(false); }
  async function submitRegister(event: React.FormEvent) { event.preventDefault(); if (!registerLocationId) { toast({ title: "Primero crea una sucursal", description: "Cada caja debe pertenecer a una sucursal activa.", tone: "error" }); return; } setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_register", { p_company_id: companyId, p_cash_register_id: registerEditId, p_location_id: registerLocationId, p_code: registerCode, p_display_name: registerName, p_currency_code: "MXN", p_is_active: registerActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica la caja."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: registerEditId ? "Caja actualizada" : "Caja creada", tone: "success" }); } setSaving(false); }
  async function submitDenomination(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_denomination", { p_company_id: companyId, p_denomination_id: denominationId, p_currency_code: "MXN", p_value: Number(denominationValue), p_display_name: denominationName || money(Number(denominationValue)), p_is_active: denominationActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica la denominación."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: denominationId ? "Denominación actualizada" : "Denominación creada", tone: "success" }); } setSaving(false); }
  async function configureStandardDenominations() {
    setStarterBusy(true);
    const { data, error } = await getSupabaseClient().rpc("configure_standard_cash_denominations", { p_company_id: companyId, p_currency_code: "MXN" });
    if (error) {
      toast({ title: "No se pudieron completar las denominaciones", description: rpcError(error, "Aplica la migración de puesta en marcha e intenta nuevamente."), tone: "error" });
    } else {
      const result = data as { added?: number; reactivated?: number } | null;
      await load();
      toast({ title: "Denominaciones MXN listas", description: `${Number(result?.added ?? 0)} agregadas y ${Number(result?.reactivated ?? 0)} reactivadas.`, tone: "success" });
    }
    setStarterBusy(false);
  }
  async function assignPriceList(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("set_location_sale_price_list", { p_company_id: companyId, p_location_id: locationPriceLocationId, p_price_list_id: locationPriceListId || null }); if (error) toast({ title: "No se pudo asignar", description: rpcError(error, "Verifica la lista de precios."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: "Lista asignada", tone: "success" }); } setSaving(false); }
  async function setDiscountPolicy(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_discount_role_limit", { p_company_id: companyId, p_role_id: roleId, p_scope: discountScope, p_max_percent: Number(discountLimit), p_valid_from: discountValidFrom ? new Date(discountValidFrom).toISOString() : null, p_valid_to: discountValidTo ? new Date(discountValidTo).toISOString() : null }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica el límite."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: "Límite configurado", tone: "success" }); } setSaving(false); }
  function requestPaymentToggle(item: typeof payments[number]) { setConfirmation({ title: `${item.is_active ? "Desactivar" : "Activar"} forma de pago`, description: item.is_active ? "Ya no estará disponible al cobrar. Las ventas existentes no cambian." : "Volverá a estar disponible para nuevas ventas.", confirmLabel: item.is_active ? "Desactivar" : "Activar", tone: item.is_active ? "danger" : "primary", onConfirm: async () => { setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_payment_method", { p_company_id: companyId, p_payment_method_id: item.id, p_code: item.code, p_display_name: item.display_name, p_settlement_kind: item.settlement_kind, p_is_active: !item.is_active }); if (error) toast({ title: "No se pudo actualizar", description: rpcError(error, "Intenta nuevamente."), tone: "error" }); else { await load(); } setSaving(false); } }); }
  function requestRegisterToggle(item: typeof registers[number]) { setConfirmation({ title: `${item.is_active ? "Desactivar" : "Activar"} caja`, description: item.is_active ? "La caja dejará de estar disponible para nuevas sesiones. No se puede alterar una sesión pendiente." : "La caja volverá a estar disponible para nuevas sesiones.", confirmLabel: item.is_active ? "Desactivar" : "Activar", tone: item.is_active ? "danger" : "primary", onConfirm: async () => { setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_register", { p_company_id: companyId, p_cash_register_id: item.id, p_location_id: item.location_id, p_code: item.code, p_display_name: item.display_name, p_currency_code: item.currency_code, p_is_active: !item.is_active }); if (error) toast({ title: "No se pudo actualizar", description: rpcError(error, "Intenta nuevamente."), tone: "error" }); else { await load(); } setSaving(false); } }); }
  function requestDenominationToggle(item: typeof denominations[number]) { setConfirmation({ title: `${item.is_active ? "Desactivar" : "Activar"} denominación`, description: item.is_active ? "Dejará de aparecer en nuevos conteos; los arqueos anteriores permanecen intactos." : "Volverá a estar disponible en los conteos de caja.", confirmLabel: item.is_active ? "Desactivar" : "Activar", tone: item.is_active ? "danger" : "primary", onConfirm: async () => { setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_denomination", { p_company_id: companyId, p_denomination_id: item.id, p_currency_code: item.currency_code, p_value: item.value, p_display_name: item.display_name, p_is_active: !item.is_active }); if (error) toast({ title: "No se pudo actualizar", description: rpcError(error, "Intenta nuevamente."), tone: "error" }); else { await load(); } setSaving(false); } }); }
  if (loading) return <div className="content-frame"><DataState loading error={null} hasData={0} empty="">{null}</DataState></div>;
  const locationOptions = locations.map((location) => ({ value: location.id, label: `${location.name} · ${location.external_code}` }));
  const priceListById = new Map(priceLists.map((list) => [list.id, list]));
  const search = query.trim().toLocaleLowerCase("es-MX");
  const matches = (value: string) => !search || value.toLocaleLowerCase("es-MX").includes(search);
  const discountStatus = (item: typeof discountLimits[number]) => discountLimitStatus(item.valid_from, item.valid_to);
  const activeDenominationValues = new Set(denominations.filter((item) => item.is_active && item.currency_code === "MXN").map((item) => Number(item.value)));
  const missingStandardDenominations = STANDARD_MXN_DENOMINATIONS.filter((value) => !activeDenominationValues.has(value));
  const assignedPriceLocations = locations.filter((location) => Boolean(location.default_price_list_id)).length;
  const firstSaleReady = [
    locations.length > 0,
    payments.some((item) => item.is_active) && registers.some((item) => item.is_active) && missingStandardDenominations.length === 0,
    priceLists.length > 0 && assignedPriceLocations > 0,
    activeAssortmentCount > 0,
  ];
  const firstSaleCompleted = firstSaleReady.filter(Boolean).length;
  const firstSaleComplete = firstSaleCompleted === firstSaleReady.length;
  const resourceRows = resource === "ticket" || resource === "quote" || resource === "volume" ? [] : resource === "payments" ? payments.filter((item) => matches(`${item.display_name} ${item.code} ${item.settlement_kind}`) && matchesStatus(statusFilter, item.is_active)) : resource === "registers" ? registers.filter((item) => matches(`${item.display_name} ${item.code}`) && matchesStatus(statusFilter, item.is_active)) : resource === "denominations" ? denominations.filter((item) => matches(`${item.display_name} ${item.value}`) && matchesStatus(statusFilter, item.is_active)) : resource === "prices" ? locations.filter((item) => matches(`${item.name} ${item.external_code} ${priceListById.get(item.default_price_list_id ?? "")?.name ?? ""}`) && (statusFilter === "all" || statusFilter === "assigned" ? Boolean(item.default_price_list_id) : !item.default_price_list_id)) : discountLimits.filter((item) => matches(`${roles.find((role) => role.id === item.role_id)?.display_name ?? ""} ${item.scope} ${item.max_percent}`) && (statusFilter === "all" || discountStatus(item) === statusFilter));
  const totalPages = Math.max(1, Math.ceil(resourceRows.length / SETTINGS_PAGE_SIZE)); const visibleRows = resourceRows.slice((page - 1) * SETTINGS_PAGE_SIZE, page * SETTINGS_PAGE_SIZE);
  const statusOptions = resource === "discounts" ? [{ value: "all", label: "Todos los estados" }, { value: "vigente", label: "Vigentes" }, { value: "futuro", label: "Futuros" }, { value: "vencido", label: "Vencidos" }] : resource === "prices" ? [{ value: "all", label: "Todas las ubicaciones" }, { value: "assigned", label: "Con lista asignada" }, { value: "unassigned", label: "Sin lista" }] : [{ value: "all", label: "Todos los estados" }, { value: "active", label: "Activos" }, { value: "inactive", label: "Desactivados" }];
  const resourceMeta: Record<SettingsResourceKey, { title: string; description: string; count: number; action: () => void; actionLabel: string }> = {
    payments: { title: "Formas de pago", description: "Define cómo se liquida una venta y si debe impactar una caja física.", count: payments.length, action: () => openPayment(), actionLabel: "Nueva forma de pago" },
    registers: { title: "Cajas", description: "Administra cajas físicas por ubicación y su disponibilidad para abrir turnos.", count: registers.length, action: () => openRegister(), actionLabel: "Nueva caja" },
    denominations: { title: "Denominaciones", description: "Catálogo de valores disponibles para aperturas, cierres y arqueos.", count: denominations.length, action: () => openDenomination(), actionLabel: "Agregar denominación" },
    prices: { title: "Listas y precios", description: "Administra listas canónicas, vigencias de precio y su asignación operativa.", count: priceLists.length, action: () => openAssignment(), actionLabel: "Asignar lista" },
    assortments: { title: "Productos por sucursal", description: "Elige qué productos puede vender cada sucursal.", count: activeAssortmentCount, action: () => undefined, actionLabel: "" },
    volume: { title: "Descuentos por volumen", description: "Define descuentos automáticos por cantidad para esta empresa.", count: 0, action: () => undefined, actionLabel: "" },
    discounts: { title: "Límites de descuento", description: "Políticas append-only por rol. La venta resuelve la vigente en el servidor.", count: discountLimits.length, action: openDiscount, actionLabel: "Nuevo límite" },
    ticket: { title: "Ticket", description: "Configura los datos visibles al imprimir.", count: 1, action: () => undefined, actionLabel: "" },
    quote: { title: "Cotización", description: "Configura la presentación imprimible de propuestas comerciales.", count: 1, action: () => undefined, actionLabel: "" },
  };
  const meta = resourceMeta[resource];
  const isWideResource = resource === "assortments" || resource === "prices" || resource === "volume";
  return <div className={`content-frame${isWideResource ? " sales-settings-wide" : ""}`}>{isWideResource ? <>
    <nav className="sales-settings-wide__return" aria-label="Regresar a la configuración de ventas"><Button variant="ghost" onClick={() => router.push("/satrapy/configuracion/ventas#sales-settings-options")}><ArrowLeft size={16} /> Volver a Ventas y caja</Button></nav>
    {resource === "assortments" ? <CommercialAssortmentsView companyId={companyId} embedded /> : resource === "prices" ? <PriceCatalogManagement companyId={companyId} locations={locations} onAssignLocation={openAssignment} onChanged={load} /> : <VolumeDiscountSettings companyId={companyId} />}
  </> : <><PageTitle eyebrow="Operación comercial" title="Ventas y caja" description="Configura pagos, cajas, precios, descuentos y documentos para nuevas ventas." />
  <section className={`first-sale-setup${firstSaleComplete && !setupExpanded ? " is-collapsed" : ""}`} aria-labelledby="first-sale-setup-title">
    <header><div><span className="eyebrow">Inicio compartido</span><h2 id="first-sale-setup-title">{firstSaleComplete ? "Preparación inicial completa" : "Preparar primera venta"}</h2><p>{firstSaleComplete ? "Sucursal, caja, precios y productos están listos." : "Completa estos pasos una vez para comenzar a vender."}</p></div><div className="first-sale-setup__status"><Badge tone={firstSaleComplete ? "success" : "info"}>{firstSaleCompleted} de {firstSaleReady.length}</Badge>{firstSaleComplete && <button type="button" aria-expanded={setupExpanded} onClick={() => setSetupExpanded((current) => !current)}>{setupExpanded ? "Ocultar pasos" : "Ver pasos"}</button>}</div></header>
    {(!firstSaleComplete || setupExpanded) && <div className="first-sale-setup__steps">
      <FirstSaleStep number={1} ready={firstSaleReady[0]} title="Sucursal" description={locations.length ? `${locations.length} sucursal${locations.length === 1 ? "" : "es"} activa${locations.length === 1 ? "" : "s"}.` : "Crea la ubicación donde se venderá."} action={<Link href="/satrapy/configuracion/empresa/sucursales">Configurar sucursales</Link>} />
      <FirstSaleStep number={2} ready={firstSaleReady[1]} title="Caja y cobro" description={missingStandardDenominations.length ? `Faltan ${missingStandardDenominations.length} denominaciones MXN.` : "Caja, pago y denominaciones disponibles."} action={<button type="button" onClick={() => changeResource("denominations")}>Revisar caja y cobro</button>} />
      <FirstSaleStep number={3} ready={firstSaleReady[2]} title="Precios" description={assignedPriceLocations ? `${assignedPriceLocations} sucursal${assignedPriceLocations === 1 ? "" : "es"} con lista asignada. Define cuánto cuesta.` : "Crea una lista y define cuánto cuesta."} action={<button type="button" onClick={() => changeResource("prices")}>Configurar precios</button>} />
      <FirstSaleStep number={4} ready={firstSaleReady[3]} title="Productos por sucursal" description={activeAssortmentCount ? `${activeAssortmentCount} catálogo${activeAssortmentCount === 1 ? "" : "s"} activo${activeAssortmentCount === 1 ? "" : "s"}. Define qué se vende y dónde.` : "Elige qué se vende y dónde."} action={<button type="button" onClick={() => changeResource("assortments")}>Elegir productos</button>} />
    </div>}
  </section>
  <div className="settings-workspace" id="sales-settings-options">
    <nav className="settings-resource-nav" aria-label="Configuración de ventas">
      {(canAssortments || canPrices || canDiscounts) && <section className="settings-resource-nav__group" aria-labelledby="sales-offer-nav-title">
        <h2 id="sales-offer-nav-title">Oferta por sucursal</h2>
        {canAssortments && <button onClick={() => changeResource("assortments")}>Productos por sucursal <span>{activeAssortmentCount}</span></button>}
        {canPrices && <button onClick={() => changeResource("prices")}>Listas y precios <span>{priceLists.length}</span></button>}
        {canDiscounts && <button onClick={() => changeResource("volume")}>Descuentos por volumen</button>}
        {canDiscounts && <button className={resource === "discounts" ? "is-active" : ""} onClick={() => changeResource("discounts")}>Límites de descuento <span>{discountLimits.length}</span></button>}
      </section>}
      {(canPayments || canRegisters) && <section className="settings-resource-nav__group" aria-labelledby="sales-checkout-nav-title">
        <h2 id="sales-checkout-nav-title">Caja y cobro</h2>
        {canPayments && <button className={resource === "payments" ? "is-active" : ""} onClick={() => changeResource("payments")}>Formas de pago <span>{payments.length}</span></button>}
        {canRegisters && <button className={resource === "registers" ? "is-active" : ""} onClick={() => changeResource("registers")}>Cajas <span>{registers.length}</span></button>}
        {canPayments && <button className={resource === "denominations" ? "is-active" : ""} onClick={() => changeResource("denominations")}>Denominaciones <span>{denominations.length}</span></button>}
      </section>}
      {(canTicketBranding || canQuoteBranding) && <section className="settings-resource-nav__group" aria-labelledby="sales-documents-nav-title">
        <h2 id="sales-documents-nav-title">Documentos</h2>
        {canTicketBranding && <button className={resource === "ticket" ? "is-active" : ""} onClick={() => changeResource("ticket")}>Ticket</button>}
        {canQuoteBranding && <button className={resource === "quote" ? "is-active" : ""} onClick={() => changeResource("quote")}>Cotización</button>}
      </section>}
    </nav>
    {resource === "ticket" ? <TicketBrandingSettings companyId={companyId} /> : resource === "quote" ? <QuoteBrandingSettings companyId={companyId} /> : <SettingsResource title={meta.title} description={meta.description} count={meta.count} action={meta.action} actionLabel={meta.actionLabel}>{resource === "denominations" && missingStandardDenominations.length > 0 && <div className="settings-starter"><div><strong>Completa las denominaciones MXN</strong><p>Agrega únicamente las que faltan: {missingStandardDenominations.map((value) => money(value, "MXN")).join(", ")}.</p></div><Button variant="primary" loading={starterBusy} onClick={() => void configureStandardDenominations()}>Completar MXN</Button></div>}<DataToolbar search={query} onSearchChange={setQuery} placeholder={`Buscar en ${meta.title.toLocaleLowerCase("es-MX")}`} filters={<Select ariaLabel="Filtrar registros" value={statusFilter} onValueChange={setStatusFilter} options={statusOptions} />} activeFilters={statusFilter === "all" ? 0 : 1} onClear={() => setStatusFilter("all")} results={resourceRows.length} /><DataState loading={false} error={loadError} hasData={resourceRows.length} empty={emptySettingsMessage(resource)} emptyAction={<Button size="sm" variant="primary" onClick={meta.action}>{meta.actionLabel}</Button>} errorAction={<Button size="sm" variant="secondary" onClick={() => void load()}>Reintentar</Button>}>
      {resource === "payments" && <SettingsTable><thead><tr><th>Forma de pago</th><th>Liquidación</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof payments).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small className="mono">{item.code}</small></td><td><Badge tone={item.settlement_kind === "cash_drawer" ? "success" : "neutral"}>{item.settlement_kind === "cash_drawer" ? "Afecta caja" : "Externo"}</Badge></td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openPayment(item)} onToggle={() => requestPaymentToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "registers" && <SettingsTable><thead><tr><th>Caja</th><th>Ubicación</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof registers).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small className="mono">{item.code} · {item.currency_code}</small></td><td>{locations.find((location) => location.id === item.location_id)?.name ?? "Ubicación no disponible"}</td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openRegister(item)} onToggle={() => requestRegisterToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "denominations" && <SettingsTable><thead><tr><th>Denominación</th><th className="number-cell">Valor</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof denominations).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small>{item.currency_code}</small></td><td className="number-cell">{money(item.value, item.currency_code)}</td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openDenomination(item)} onToggle={() => requestDenominationToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "discounts" && <SettingsTable><thead><tr><th>Rol</th><th>Alcance</th><th className="number-cell">Máximo</th><th>Vigencia</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof discountLimits).map((item) => <tr key={item.id}><td><strong>{roles.find((role) => role.id === item.role_id)?.display_name ?? "Rol no disponible"}</strong></td><td>{item.scope === "sale" ? "Venta completa" : "Línea"}</td><td className="number-cell">{item.max_percent}%</td><td><strong>{dateTime(item.valid_from)}</strong><small>{item.valid_to ? `Hasta ${dateTime(item.valid_to)}` : "Sin vencimiento"}</small></td><td><DiscountStatusBadge status={discountStatus(item)} /></td><td className="settings-row-actions">{permissions.includes("view_sales_audit") ? <Link className="settings-audit-link" href="/satrapy/configuracion/auditoria-comercial">Auditoría <ExternalLink size={13} /></Link> : <span className="settings-muted">Auditable</span>}</td></tr>)}</tbody></SettingsTable>}
      <SettingsPagination page={page} totalPages={totalPages} onChange={setPage} />
    </DataState></SettingsResource>}
  </div></>}
  <Drawer open={drawer === "payment"} onOpenChange={(open) => !open && closeDrawer()} title={paymentId ? "Editar forma de pago" : "Nueva forma de pago"}><SettingsDrawerIntro text="Alta manual pensada para pocos medios de pago. Cada cambio queda auditado." /><form className="sales-form" onSubmit={submitPayment}>{paymentId&&<p className="settings-drawer-intro">Código: {paymentCode}</p>}<label>Nombre<Input required value={paymentName} onChange={(event) => setPaymentName(event.target.value)} placeholder="Efectivo" /></label><Select ariaLabel="Liquidación" value={paymentKind} onValueChange={setPaymentKind} options={[{ value: "cash_drawer", label: "Afecta caja" }, { value: "external", label: "Externo (tarjeta, transferencia o terminal)" }]} /><label className="sales-checkbox"><input type="checkbox" checked={paymentActive} onChange={(event) => setPaymentActive(event.target.checked)} /> Activa para nuevas ventas</label><Button type="submit" variant="primary" loading={saving}>Guardar forma de pago</Button></form></Drawer>
  <Drawer open={drawer === "register"} onOpenChange={(open) => !open && closeDrawer()} title={registerEditId ? "Editar caja" : "Nueva caja"}><SettingsDrawerIntro text="Una caja representa un cajón físico por ubicación. Para volúmenes altos, configura desde una carga controlada." /><form className="sales-form" onSubmit={submitRegister}>{locations.length ? <Select ariaLabel="Ubicación de caja" value={registerLocationId} onValueChange={setRegisterLocationId} options={locationOptions} /> : <div className="settings-prerequisite" role="status"><AlertCircle size={18} aria-hidden="true" /><div><strong>Crea una sucursal antes de agregar la caja</strong><p>Cada caja debe pertenecer a una sucursal activa.</p></div><Link href="/satrapy/configuracion/empresa/sucursales">Crear sucursal <ExternalLink size={14} aria-hidden="true" /></Link></div>}{registerEditId&&<p className="settings-drawer-intro">Código: {registerCode}</p>}<label>Nombre<Input required value={registerName} onChange={(event) => setRegisterName(event.target.value)} placeholder="Caja principal" /></label><label className="sales-checkbox"><input type="checkbox" checked={registerActive} onChange={(event) => setRegisterActive(event.target.checked)} /> Disponible para nuevas sesiones</label><Button type="submit" variant="primary" loading={saving} disabled={!registerLocationId}>Guardar caja</Button></form></Drawer>
  <Drawer open={drawer === "denomination"} onOpenChange={(open) => !open && closeDrawer()} title={denominationId ? "Editar denominación" : "Agregar denominación"}><SettingsDrawerIntro text="El catálogo se usa en conteos de caja. Las operaciones anteriores no se modifican." /><form className="sales-form" onSubmit={submitDenomination}><label>Valor<Input required inputMode="decimal" value={denominationValue} onChange={(event) => setDenominationValue(event.target.value)} placeholder="100" /></label><label>Nombre<Input required value={denominationName} onChange={(event) => setDenominationName(event.target.value)} placeholder="$100" /></label><label className="sales-checkbox"><input type="checkbox" checked={denominationActive} onChange={(event) => setDenominationActive(event.target.checked)} /> Disponible en nuevos conteos</label><Button type="submit" variant="primary" loading={saving}>Guardar denominación</Button></form></Drawer>
  <Drawer open={drawer === "assignment"} onOpenChange={(open) => !open && closeDrawer()} title="Asignar lista por ubicación"><SettingsDrawerIntro text="La asignación afecta precios disponibles para nuevas ventas en esa ubicación; no modifica ventas confirmadas." /><form className="sales-form" onSubmit={assignPriceList}><Select ariaLabel="Ubicación" value={locationPriceLocationId} onValueChange={setLocationPriceLocationId} options={locationOptions} /><Select ariaLabel="Lista de precios" value={locationPriceListId} onValueChange={setLocationPriceListId} options={priceLists.map((list) => ({ value: list.id, label: `${list.name} · ${list.currency_code}` }))} /><Button type="submit" variant="primary" loading={saving}>Guardar asignación</Button></form></Drawer>
  <Drawer open={drawer === "discount"} onOpenChange={(open) => !open && closeDrawer()} title="Nuevo límite de descuento"><SettingsDrawerIntro text="La nueva política conserva auditoría y cierra automáticamente la vigente del mismo rol y alcance; no se permiten traslapes." /><form className="sales-form" onSubmit={setDiscountPolicy}><Select ariaLabel="Rol" value={roleId} onValueChange={setRoleId} options={roles.map((role) => ({ value: role.id, label: role.display_name }))} /><Select ariaLabel="Alcance" value={discountScope} onValueChange={setDiscountScope} options={[{ value: "sale", label: "Venta completa" }, { value: "line", label: "Línea" }]} /><label>Máximo %<Input required inputMode="decimal" value={discountLimit} onChange={(event) => setDiscountLimit(event.target.value)} placeholder="10" /></label><label>Vigente desde (opcional)<Input type="datetime-local" value={discountValidFrom} onChange={(event) => setDiscountValidFrom(event.target.value)} /></label><label>Vence el (opcional)<Input type="datetime-local" value={discountValidTo} onChange={(event) => setDiscountValidTo(event.target.value)} /></label><Button type="submit" variant="primary" loading={saving}>Crear límite</Button></form></Drawer>
  <Modal open={Boolean(confirmation)} onOpenChange={(open) => !open && setConfirmation(null)} title={confirmation?.title ?? "Confirmar cambio"} description={confirmation?.description} footer={<><Button variant="secondary" onClick={() => setConfirmation(null)}>Cancelar</Button><Button variant={confirmation?.tone ?? "primary"} loading={saving} onClick={() => { const action = confirmation?.onConfirm; setConfirmation(null); if (action) void action(); }}>{confirmation?.confirmLabel ?? "Confirmar"}</Button></>}>{null}</Modal>
  </div>;
}

function VolumeDiscountSettings({ companyId }: { companyId: string }) {
  const { toast } = useToast();
  const defaults: VolumeDiscountTier[] = [
    { tier_number: 1, min_quantity: 2, max_quantity: 4, discount_percent: 3, is_active: true },
    { tier_number: 2, min_quantity: 5, max_quantity: 9, discount_percent: 6, is_active: true },
    { tier_number: 3, min_quantity: 10, max_quantity: null, discount_percent: 12, is_active: true },
  ];
  const [tiers, setTiers] = useState<VolumeDiscountTier[]>([]);
  const [drafting, setDrafting] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const validationError = useMemo(() => {
    if (tiers.length !== 3) return "Configura los tres niveles de la política.";
    const ordered = [...tiers].sort((left, right) => left.tier_number - right.tier_number);
    for (let index = 0; index < ordered.length; index += 1) {
      const tier = ordered[index];
      if (tier.tier_number !== index + 1 || !Number.isFinite(tier.min_quantity) || tier.min_quantity <= 0 || !Number.isFinite(tier.discount_percent) || tier.discount_percent <= 0 || tier.discount_percent >= 100) return "Revisa las cantidades y porcentajes de cada nivel.";
      if (tier.max_quantity !== null && (!Number.isFinite(tier.max_quantity) || tier.max_quantity < tier.min_quantity)) return "La cantidad máxima debe ser igual o mayor que la mínima.";
      if (index > 0) {
        const previous = ordered[index - 1];
        if (previous.max_quantity === null || tier.min_quantity !== previous.max_quantity + 1) return "Los rangos deben ser consecutivos, sin huecos ni traslapes.";
        if (tier.discount_percent <= previous.discount_percent) return "Cada nivel debe ofrecer un descuento mayor al anterior.";
      }
      if (index < ordered.length - 1 && tier.max_quantity === null) return "Solo el último nivel puede quedar sin límite.";
    }
    return null;
  }, [tiers]);
  useEffect(() => {
    let active = true;
    void getSupabaseClient().rpc("list_pos_volume_discount_tiers", { p_company_id: companyId }).then(({ data, error }) => {
      if (!active) return;
      if (error) setLoadError(rpcError(error, "No se pudo cargar la política."));
      else { setLoadError(null); setTiers(Array.isArray(data) ? data as VolumeDiscountTier[] : []); }
      setLoading(false);
    });
    return () => { active = false; };
  }, [companyId]);
  function updateTier(index: number, field: "min_quantity" | "max_quantity" | "discount_percent", value: string) {
    setDrafting(true);
    setTiers((current) => current.map((tier, tierIndex) => tierIndex === index ? { ...tier, [field]: field === "max_quantity" && value === "" ? null : Number(value) } : tier));
  }
  async function save() {
    if (validationError) return;
    setSaving(true);
    const { data, error } = await getSupabaseClient().rpc("save_pos_volume_discount_tiers", { p_company_id: companyId, p_tiers: tiers });
    if (error) toast({ title: "No se guardó la política", description: rpcError(error, "Revisa los rangos y porcentajes."), tone: "error" });
    else { setTiers(data as VolumeDiscountTier[]); setDrafting(false); toast({ title: "Descuentos por volumen actualizados", description: "El POS recalculará las partidas abiertas automáticamente.", tone: "success" }); }
    setSaving(false);
  }
  return <section className="volume-discount-settings" aria-labelledby="volume-discount-title">
    <header>
      <div>
        <span className="eyebrow">Política automática</span>
        <h2 id="volume-discount-title">Descuentos por volumen</h2>
        <p>Se aplican automáticamente a todas las sucursales cuando el producto no usa precios escalonados ni un descuento especial autorizado.</p>
      </div>
    </header>
    <p className="volume-discount-context">Los precios escalonados y los descuentos especiales sustituyen esta política. <Link href="/satrapy/configuracion/ventas?seccion=prices">Revisar precios de productos</Link></p>
    {loadError ? <div className="settings-prerequisite" role="alert"><AlertCircle size={18} aria-hidden="true" /><div><strong>No se pudo consultar la política</strong><p>{loadError}</p></div></div> : !loading && tiers.length === 0 ? <div className="volume-discount-empty"><div><strong>Aún no hay descuentos por volumen</strong><p>Configura tres rangos consecutivos. El último puede quedar sin límite.</p></div><Button variant="secondary" onClick={() => { setTiers(defaults); setDrafting(true); }}>Configurar 3 niveles</Button></div> : <>
      <div className="volume-discount-grid">{tiers.map((tier, index) => <fieldset key={tier.tier_number} disabled={loading || saving}><legend>Nivel {tier.tier_number}</legend><label>Cantidad mínima<Input type="number" min="1" step="1" inputMode="numeric" value={tier.min_quantity} onChange={(event) => updateTier(index, "min_quantity", event.target.value)} /></label><label>Cantidad máxima<Input type="number" min={tier.min_quantity} step="1" inputMode="numeric" value={tier.max_quantity ?? ""} placeholder="Sin límite" onChange={(event) => updateTier(index, "max_quantity", event.target.value)} /></label><label>Descuento %<Input type="number" min="0.01" max="99.99" step="0.01" inputMode="decimal" value={tier.discount_percent} onChange={(event) => updateTier(index, "discount_percent", event.target.value)} /></label></fieldset>)}</div>
      {validationError && <p className="volume-discount-validation" role="alert"><AlertCircle size={15} aria-hidden="true" />{validationError}</p>}
      <footer className="volume-discount-footer">
        <p className={`volume-discount-note${drafting ? " is-draft" : ""}`}>{drafting ? <AlertCircle size={15} aria-hidden="true" /> : <CheckCircle2 size={15} aria-hidden="true" />} {drafting ? "Cambios sin aplicar. Guarda los niveles para activarlos en todas las sucursales." : "Política activa. El POS recalcula el descuento al cambiar la cantidad cuando el producto no tiene precios escalonados."}</p>
        {drafting && <Button size="sm" variant="secondary" loading={saving} disabled={loading || Boolean(validationError)} onClick={() => void save()}>Guardar niveles</Button>}
      </footer>
    </>}
  </section>;
}

type SettingsResourceKey = "assortments" | "payments" | "registers" | "denominations" | "prices" | "volume" | "discounts" | "ticket" | "quote";
function settingsResourceFromQuery(value: string | null): SettingsResourceKey | null { return value === "assortments" || value === "payments" || value === "registers" || value === "denominations" || value === "prices" || value === "volume" || value === "discounts" || value === "ticket" || value === "quote" ? value : null; }
type SettingsDrawer = "payment" | "register" | "denomination" | "assignment" | "discount";
type SettingsConfirmation = { title: string; description: string; confirmLabel: string; tone: "primary" | "danger"; onConfirm: () => Promise<void> };
const SETTINGS_PAGE_SIZE = 12;
const STANDARD_MXN_DENOMINATIONS = [0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000];

function FirstSaleStep({ number, ready, title, description, action }: { number: number; ready: boolean; title: string; description: string; action: ReactNode }) {
  return <article className={ready ? "is-ready" : ""}><span className="first-sale-setup__number">{ready ? <CheckCircle2 size={18} aria-label="Completo" /> : number}</span><div><strong>{title}</strong><p>{description}</p>{action}</div></article>;
}

function SettingsResource({ title, description, count, action, actionLabel, children }: { title: string; description: string; count: number; action: () => void; actionLabel: string; children: ReactNode }) { return <section className="settings-resource"><header><div><h2>{title}</h2><p>{description}</p></div><div><Badge>{count}</Badge><Button variant="primary" onClick={action}><Plus size={16} /> {actionLabel}</Button></div></header>{children}</section>; }
function SettingsTable({ children }: { children: ReactNode }) { return <Table className="settings-table">{children}</Table>; }
function SettingsDrawerIntro({ text }: { text: string }) { return <p className="settings-drawer-intro">{text}</p>; }
function StatusBadge({ active }: { active: boolean }) { return <Badge tone={active ? "success" : "neutral"}>{active ? "Activo" : "Desactivado"}</Badge>; }
function DiscountStatusBadge({ status }: { status: "vigente" | "futuro" | "vencido" }) { return <Badge tone={status === "vigente" ? "success" : status === "futuro" ? "info" : "neutral"}>{status === "vigente" ? "Vigente" : status === "futuro" ? "Futuro" : "Vencido"}</Badge>; }
function RowActions({ onEdit, onToggle, active }: { onEdit: () => void; onToggle: () => void; active: boolean }) { return <div className="settings-row-actions"><Button size="sm" variant="ghost" onClick={onEdit}><Pencil size={14} /> Editar</Button><Button size="sm" variant="ghost" onClick={onToggle}><Power size={14} /> {active ? "Desactivar" : "Activar"}</Button></div>; }
function SettingsPagination({ page, totalPages, onChange }: { page: number; totalPages: number; onChange: (page: number) => void }) { return <DataPagination page={page} totalPages={totalPages} onChange={onChange} showTotal={false} />; }
function matchesStatus(filter: string, active: boolean) { return filter === "all" || (filter === "active" ? active : !active); }
function discountLimitStatus(validFrom: string, validTo: string | null): "vigente" | "futuro" | "vencido" { const now = Date.now(); if (new Date(validFrom).getTime() > now) return "futuro"; if (validTo && new Date(validTo).getTime() < now) return "vencido"; return "vigente"; }
function emptySettingsMessage(resource: SettingsResourceKey) { return resource === "payments" ? "Crea la primera forma de pago para cobrar en el POS." : resource === "registers" ? "Crea una caja física y asígnala a una ubicación antes de abrir turnos." : resource === "denominations" ? "Agrega las denominaciones que se contarán en aperturas y arqueos." : resource === "prices" ? "No hay ubicaciones que coincidan con esta búsqueda o filtro." : "No hay límites de descuento que coincidan. Crea una política nueva para un rol."; }

type SalesAuditRow = { id: string; action: string; entity_type: string; entity_id: string | null; metadata: Record<string, unknown>; created_at: string };

export function SalesAuditView({ companyId }: { companyId: string }) {
  const [rows, setRows] = useState<SalesAuditRow[]>([]); const [total, setTotal] = useState(0); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null); const [page, setPage] = useState(1);
  const load = useCallback(async () => { setLoading(true); const from = (page - 1) * SETTINGS_PAGE_SIZE; const { data, error: loadError, count } = await getSupabaseClient().from("audit_log").select("id, action, entity_type, entity_id, metadata, created_at", { count: "exact" }).eq("company_id", companyId).in("entity_type", ["payment_methods", "cash_registers", "cash_denominations", "discount_role_limits", "locations"]).order("created_at", { ascending: false }).range(from, from + SETTINGS_PAGE_SIZE - 1); setRows((data ?? []) as SalesAuditRow[]); setTotal(count ?? 0); setError(loadError ? rpcError(loadError, "No se pudo cargar la auditoría comercial.") : null); setLoading(false); }, [companyId, page]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  const totalPages = Math.max(1, Math.ceil(total / SETTINGS_PAGE_SIZE));
  return <div className="content-frame"><PageTitle eyebrow="Trazabilidad comercial" title="Auditoría comercial" description="Consulta cambios de configuración de ventas y caja. Esta vista lee el registro de auditoría existente y no altera operaciones." action={<Button variant="secondary" onClick={() => void load()}>Actualizar</Button>} /><DataState loading={loading && !rows.length} error={error} hasData={rows.length} empty="Aún no hay cambios de configuración comercial auditados." errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>}><SettingsTable><thead><tr><th>Evento</th><th>Recurso</th><th>Detalle</th><th>Fecha</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id}><td><strong>{salesAuditAction(row.action)}</strong><small className="mono">{row.action}</small></td><td>{salesAuditEntity(row.entity_type)}</td><td>{salesAuditDetail(row.metadata)}</td><td>{dateTime(row.created_at)}</td></tr>)}</tbody></SettingsTable><SettingsPagination page={page} totalPages={totalPages} onChange={setPage} /></DataState></div>;
}

function salesAuditAction(action: string) { return action === "payment_method.configured" ? "Forma de pago configurada" : action === "cash_register.configured" ? "Caja configurada" : action === "cash_denomination.configured" ? "Denominación configurada" : action === "location.price_list_assigned" ? "Lista asignada a ubicación" : action === "discount_limit.created" ? "Límite de descuento creado" : action; }
function salesAuditEntity(entity: string) { return entity === "payment_methods" ? "Formas de pago" : entity === "cash_registers" ? "Cajas" : entity === "cash_denominations" ? "Denominaciones" : entity === "discount_role_limits" ? "Límites de descuento" : entity === "locations" ? "Listas por ubicación" : entity; }
function salesAuditDetail(metadata: Record<string, unknown>) { const pairs = Object.entries(metadata).filter(([, value]) => value !== null && value !== undefined).slice(0, 3); return pairs.length ? pairs.map(([key, value]) => `${key}: ${String(value)}`).join(" · ") : "Sin detalle adicional"; }

function DenominationCount({ denominations, counts, onChange, currency }: { denominations: Array<{ id: string; value: number; display_name: string }>; counts: Record<string, string>; onChange: (counts: Record<string, string>) => void; currency: string }) { return <div className="denomination-list">{denominations.length ? denominations.map((denomination) => <label key={denomination.id}><span>{denomination.display_name || money(denomination.value, currency)}<small>{money(denomination.value, currency)}</small></span><Input inputMode="numeric" value={counts[denomination.id] ?? ""} onChange={(event) => onChange({ ...counts, [denomination.id]: event.target.value.replace(/[^0-9]/g, "") })} placeholder="0" /></label>) : <p>Configura denominaciones activas antes de abrir o cerrar esta caja.</p>}</div>; }

function TicketPreview({ ticket }: { ticket: Record<string, unknown> | null | undefined }) { if (!ticket) return null; const sale = ticket.sale as { total_amount?: number; currency_code?: string; customer?: { display_name?: string } | null } | undefined; const payment = ticket.payment as { method_code?: string; received_amount?: number; change_amount?: number; reference?: string; type?: string; source_status?: string } | undefined; const items = (ticket.items ?? []) as Array<{ product_name?: string; quantity?: number; total_amount?: number }>; const renderItem=(item:{product_name?:string;quantity?:number;total_amount?:number},key:number)=><p key={key}><span>{item.quantity} × {item.product_name}</span><b>{money(item.total_amount,sale?.currency_code)}</b></p>; return <div className="historical-ticket-preview"><div><strong>{String(ticket.folio ?? "")}</strong><span>{sale?.customer?.display_name ?? "Venta de mostrador"}</span><span>{ticket.issued_at ? dateTime(String(ticket.issued_at)) : ""}</span></div><div className="ticket-screen-items"><PagedCollection items={items} resetKey={String(ticket.folio ?? "")} label="partidas">{(visibleItems,startIndex)=><>{visibleItems.map((item,index)=>renderItem(item,startIndex+index))}</>}</PagedCollection></div><footer>Total <strong>{money(sale?.total_amount, sale?.currency_code)}</strong></footer>{payment?.type === "historical_evidence" && <p className="historical-ticket-preview__payment"><span>Histórica · {payment.source_status ?? "estado de origen conservado"}</span><b>Solo consulta</b></p>}{payment?.method_code && <p className="historical-ticket-preview__payment"><span>Pago: {payment.method_code}</span><b>{payment.received_amount != null ? money(payment.received_amount, sale?.currency_code) : ""}</b></p>}{payment?.reference && <p className="historical-ticket-preview__payment"><span>Autorización</span><b>{payment.reference}</b></p>}{Number(payment?.change_amount ?? 0) > 0 && <p className="historical-ticket-preview__change"><span>Cambio</span><b>{money(payment?.change_amount, sale?.currency_code)}</b></p>}</div>; }

function PosEmpty({ title, description }: { title: string; description: string }) { return <section className="pos-empty"><AlertCircle size={24} /><h1>{title}</h1><p>{description}</p><div className="pos-empty__actions"><Link className="ui-button ui-button--primary ui-button--md" href="/satrapy/configuracion/ventas">Configurar ventas y caja</Link><Link className="pos-exit-link" href="/satrapy/configuracion">Volver a configuración</Link></div></section>; }
