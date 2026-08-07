"use client";

import {
  AlertCircle,
  Banknote,
  CircleDollarSign,
  ClipboardList,
  CircleHelp,
  CreditCard,
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
import { presentImportedSourceText } from "@/app/lib/presentation-text";
import { PriceCatalogManagement } from "@/app/components/PriceCatalogManagement";
import { printTicketPdf, type TicketBranding } from "@/app/lib/ticket-pdf";
import { TicketBrandingSettings } from "@/app/components/TicketBrandingSettings";
import { QuoteBrandingSettings } from "@/app/components/QuoteBrandingSettings";

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
type ReceivablesSummary = { document_count: number; outstanding_amount: number; overdue_count: number; overdue_amount: number; next_due_date?: string | null };
type ReceivablesPage = { items?: ReceivableDocument[]; summary?: ReceivablesSummary; pagination?: { page: number; page_size: number; total: number } };
type ReceivableCustomerContext = { customer: { id: string; code: string; display_name: string; tax_id: string | null; payment_manager: string | null; credit_term_days: number | null }; contact: CustomerContact | null; address: CustomerAddress | null; summary: ReceivablesSummary };
type CustomerMaster = { id: string; code: string; display_name: string; tax_id: string | null; customer_type: "persona_fisica" | "persona_moral" | null; notes: string | null; is_active: boolean; is_imported: boolean; source_reference: string | null; migration_status: string; addresses: CustomerAddress[]; contacts: CustomerContact[]; commercial: { price_list_id: string | null; price_list_name: string | null; payment_manager: string | null; sales_agent: string | null; credit_enabled: boolean | null; credit_limit: number | null; credit_term_days: number | null; outstanding_amount: number | null; available_credit: number | null }; receivables_summary: ReceivablesSummary | null; open_receivables: CustomerReceivable[] };
type CartItem = { cart_item_id: string; product_id: string; code: string | null; name: string; unit: string | null; quantity: number; quantity_on_hand: number; inventory_tracked: boolean; unit_price_amount: number; discount_percent: number; total_amount: number };
type CartQuote = { cart_id: string; revision: number; customer_id: string | null; currency_code: string | null; items: CartItem[]; subtotal_amount: number; discount_amount: number; tax_amount: number; total_amount: number; can_checkout: boolean; pending_discount_approval: boolean };
type SaleRow = { sale_id: string; folio: string; location_id: string; sale_type: "cash" | "credit"; customer_name: string | null; currency_code: string; total_amount: number; returned_amount: number; cancelled: boolean; completed_at: string };
type SaleTicketState = { saleId: string; payload: Record<string, unknown>; cancellation: { id: string; reason: string; cancelled_at: string } | null };
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

function dateTime(value: string) {
  return new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
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
  const logoUrl = branding?.logo_path ? getSupabaseClient().storage.from("ticket-branding-assets").getPublicUrl(branding.logo_path).data.publicUrl : null;
  await printTicketPdf(ticket, { ...branding, logo_url: logoUrl }, printWindow);
}

function posBlockerLabel(code: string) {
  const labels: Record<string, string> = { outside_assortment: "Fuera del surtido de esta sucursal", inactive: "Producto inactivo", not_sellable: "No habilitado para venta", commercial_review_required: "Revisión comercial pendiente", missing_sales_unit: "Falta unidad de venta", missing_tax_category: "Falta categoría fiscal", missing_current_tax_rate: "Falta impuesto vigente", missing_or_zero_price: "Falta precio vigente", out_of_stock: "Sin existencia en esta sucursal" };
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

function usePosContext(companyId: string) {
  const [context, setContext] = useState<PosContext | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("get_pos_context", { p_company_id: companyId });
    if (loadError) {
      setError(rpcError(loadError, "No se pudo cargar el contexto POS."));
      setContext(null);
    } else {
      setContext(data as PosContext);
      setError(null);
    }
    setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  return { context, loading, error, reload: load };
}

export function PosSalesView({ companyId, companyName, cashierName, permissions }: { companyId: string; companyName: string; cashierName: string; permissions: string[] }) {
  const { toast } = useToast();
  const { context, loading: contextLoading, error: contextError, reload: reloadContext } = usePosContext(companyId);
  const [cartId, setCartId] = useState<string | null>(null);
  const [quote, setQuote] = useState<CartQuote | null>(null);
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
  const searchRef = useRef<HTMLInputElement>(null);
  const customerRef = useRef<HTMLInputElement>(null);
  const customerPickerRef = useRef<HTMLDivElement>(null);
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const cartRecoveryInFlight = useRef(false);
  const completeRef = useRef<() => void>(() => undefined);
  const productRequestRef = useRef(0);
  const blockedRequestRef = useRef(0);

  const ownSession = context?.own_open_session?.status === "open" ? context.own_open_session : null;
  const selectedRegister = context?.registers.find((item) => item.id === ownSession?.cash_register_id) ?? null;
  const selectedLocation = context?.locations.find((item) => item.id === ownSession?.location_id) ?? null;
  const paymentMethods = context?.payment_methods ?? [];
  const selectedPayment = paymentMethods.find((method) => method.id === paymentMethodId) ?? null;
  const receivedAmount = Number(received.replace(",", "."));
  const saleTotal = Number(quote?.total_amount ?? 0);
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

  useEffect(() => {
    if (!context) return;
    void Promise.resolve().then(() => {
      setPaymentMethodId((current) => context.payment_methods.some((method) => method.id === current) ? current : context.payment_methods[0]?.id ?? "");
    });
  }, [context]);

  const loadQuote = useCallback(async (id: string) => {
    const { data, error } = await getSupabaseClient().rpc("quote_sale_cart", { p_cart_id: id });
    if (error) {
      toast({ title: "No pudimos cotizar el carrito", description: rpcError(error, "Intenta nuevamente."), tone: "error" });
      return;
    }
    setQuote(data as CartQuote);
  }, [toast]);

  const ensureCart = useCallback(async () => {
    if (cartRecoveryInFlight.current) return;
    cartRecoveryInFlight.current = true;
    try {
      if (!ownSession) { setCartId(null); setQuote(null); return; }
      const { data, error } = await getSupabaseClient().rpc("get_or_create_sale_cart", { p_company_id: companyId, p_cash_session_id: ownSession.id });
      if (error) { setCartId(null); setQuote(null); toast({ title: "No se pudo recuperar tu sesión", description: rpcError(error, "Abre una caja propia antes de vender."), tone: "error" }); return; }
      const nextCartId = (data as { cart_id: string }).cart_id;
      setCartId(nextCartId);
      await loadQuote(nextCartId);
    } finally {
      cartRecoveryInFlight.current = false;
    }
  }, [companyId, loadQuote, ownSession, toast]);

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
      const { data, error } = await getSupabaseClient().rpc("search_pos_sale_products", {
        p_company_id: companyId,
        p_location_id: selectedRegister.location_id,
        p_customer_id: customer?.id ?? null,
        p_query: search || null,
        p_page: 1,
        p_page_size: 30,
      });
      if (request !== productRequestRef.current) return;
      const result = data as { items?: ProductSearchItem[]; total?: number; page?: number } | null;
      if (!error) {
        setProducts(result?.items ?? []);
        setProductTotal(result?.total ?? 0);
        setProductPage(result?.page ?? 1);
      } else {
        setProducts([]); setProductTotal(0); setProductPage(1);
        toast({ title: "No se pudo buscar productos", description: rpcError(error, "Revisa acceso, precios y readiness de la ubicación."), tone: "error" });
      }
      setProductLoading(false);
    }, search.trim() ? 120 : 0);
    return () => window.clearTimeout(timer);
  }, [cartId, companyId, customer?.id, search, selectedRegister, toast]);

  async function loadMoreProducts() {
    if (!cartId || !selectedRegister || productLoading || productLoadingMore || products.length >= productTotal) return;
    const request = ++productRequestRef.current;
    const nextPage = productPage + 1;
    setProductLoadingMore(true);
    const { data, error } = await getSupabaseClient().rpc("search_pos_sale_products", {
      p_company_id: companyId,
      p_location_id: selectedRegister.location_id,
      p_customer_id: customer?.id ?? null,
      p_query: search || null,
      p_page: nextPage,
      p_page_size: 30,
    });
    if (request !== productRequestRef.current) return;
    if (error) {
      toast({ title: "No se pudieron cargar más productos", description: rpcError(error, "Los productos ya visibles permanecen disponibles."), tone: "error" });
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
    if (!selectedRegister || !search.trim()) {
      blockedRequestRef.current += 1;
      void Promise.resolve().then(() => { setBlockedOpen(false); setBlockedProducts([]); setBlockedTotal(0); setBlockedLoading(false); });
      return;
    }
    const request = ++blockedRequestRef.current;
    const timer = window.setTimeout(async () => {
      setBlockedLoading(true);
      const { data, error } = await getSupabaseClient().rpc("search_pos_blocked_products", { p_company_id: companyId, p_location_id: selectedRegister.location_id, p_customer_id: customer?.id ?? null, p_query: search.trim(), p_page: 1, p_page_size: 30 });
      if (request !== blockedRequestRef.current) return;
      if (error) {
        setBlockedProducts([]); setBlockedTotal(0); setBlockedOpen(false);
        toast({ title: "No se pudieron consultar los productos agotados", description: rpcError(error, "Intenta nuevamente."), tone: "error" });
      } else {
        const result = data as { items?: BlockedProductSearchItem[]; total?: number } | null;
        setBlockedProducts(result?.items ?? []); setBlockedTotal(result?.total ?? 0); setBlockedOpen(Boolean(result?.items?.length));
      }
      setBlockedLoading(false);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [companyId, customer?.id, search, selectedRegister, toast]);

  useEffect(() => {
    if (!customerQuery.trim()) { void Promise.resolve().then(() => { setCustomerResults([]); setCustomerPickerOpen(false); }); return; }
    const timer = window.setTimeout(async () => {
      const customerRpc = saleType === "credit" ? "search_sale_customers_credit" : "search_sale_customers";
      const { data, error } = await getSupabaseClient().rpc(customerRpc, { p_company_id: companyId, p_query: customerQuery, p_page: 1, p_page_size: 8 });
      if (error) { setCustomerResults([]); setCustomerPickerOpen(false); toast({ title: "No se pudo buscar clientes", description: rpcError(error, "No tienes acceso al crédito de clientes."), tone: "error" }); }
      else { const items = ((data as { items?: Customer[] })?.items ?? []); setCustomerResults(items); setCustomerPickerOpen(items.length > 0); }
    }, 150);
    return () => window.clearTimeout(timer);
  }, [companyId, customerQuery, saleType, toast]);

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

  async function changeItem(productId: string, delta: number, clearProductSearch = false) {
    if (!cartId || !quote) return;
    setBusy(true);
    const { error } = await getSupabaseClient().rpc("change_sale_cart_item", { p_cart_id: cartId, p_product_id: productId, p_quantity_delta: delta, p_expected_revision: quote.revision });
    if (error) toast({ title: "No se pudo modificar el carrito", description: rpcError(error, "Actualiza la vista e intenta nuevamente."), tone: "error" });
    else {
      await loadQuote(cartId);
      if (clearProductSearch) {
        setSearch("");
        searchRef.current?.focus();
      }
    }
    setBusy(false);
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
  useEffect(() => { completeRef.current = () => { if (!busy && quote?.can_checkout && (saleType !== "cash" || Boolean(paymentMethodId))) void complete(); }; });

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
    <div className="pos-page__heading"><div><span className="eyebrow">Venta transaccional</span><h1>Punto de venta</h1><p>Precios, impuestos y existencias se validan al cobrar.</p></div><Link className="pos-exit-link" href="/satrapy/ventas/historial">Salir del POS</Link></div>
    {ownSession && selectedRegister && <div className="pos-context-strip"><span><small>Empresa</small><strong>{companyName}</strong></span><span><small>Sucursal</small><strong>{selectedLocation?.name ?? selectedRegister.code}</strong></span><span><small>Caja</small><strong>{selectedRegister.name}</strong></span><span><small>Cajero</small><strong>{cashierName}</strong></span><span><small>Sesión</small><strong>{ownSession.opened_at ? `Desde ${new Date(ownSession.opened_at).toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" })}` : "Abierta"}</strong></span></div>}
    {!ownSession ? <section className="pos-start-card"><Banknote size={22} /><div><strong>Abre tu caja para iniciar.</strong><span>La apertura requiere un conteo formal por denominación. Si hay varias cajas, la selección se hace explícitamente en Caja.</span></div><Link href="/satrapy/ventas/caja" className="button button--primary">Ir a Caja</Link></section> : <>
      <div className="pos-shell">
        <section className="pos-catalog">
          <label className="pos-search-field"><span>Buscar productos</span><div className="pos-search"><Search size={20} aria-hidden="true" /><Input ref={searchRef} value={search} onChange={(event) => setSearch(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && productTotal === 1 && products.length === 1) { event.preventDefault(); void changeItem(products[0].product_id, 1, true); } }} placeholder="Escanea o busca por nombre, SKU o código" aria-label="Buscar productos" autoFocus /><kbd>F2 cliente</kbd></div></label>
          <div className="pos-search-meta" role="status" aria-live="polite"><span>{productLoading ? "Buscando…" : `${products.length} de ${productTotal} resultados`}</span><span>Enter agrega la coincidencia única</span></div>
          <div className="pos-shortcuts" aria-label="Atajos de teclado disponibles"><span><kbd>F2</kbd> Cliente</span>{permissions.includes("apply_discount") && quote?.items.length ? <span><kbd>F4</kbd> Descuento</span> : null}{quote?.items.length ? <><span><kbd>F8</kbd> Cobrar</span><span><kbd>Esc</kbd> Cerrar</span><span><kbd>+</kbd><kbd>−</kbd> Partida enfocada</span></> : null}</div>
          <div className="pos-product-list">
            {products.map((product) => <div className="pos-product-row" key={product.product_id}><button className="pos-product" disabled={busy} onClick={() => void changeItem(product.product_id, 1, true)}><span><strong>{highlightSearchMatch(product.name, search)}</strong><small>{highlightSearchMatch(product.code ?? "Sin código", search)} · {product.unit ?? "Unidad"}</small></span><span className="pos-product__right"><b>{money(product.price_amount, product.currency_code)}</b><small>Precio total</small>{product.inventory_tracked && <em className={product.quantity_on_hand <= 3 ? "is-low" : ""}>{product.quantity_on_hand} disp.</em>}</span></button>{product.inventory_tracked && permissions.includes("view_inventory") && <Button className="pos-product-stock" size="sm" variant="ghost" disabled={busy} onClick={() => openLocationStock(product)}><ClipboardList size={14} /> Otras sucursales</Button>}</div>)}
            {!productLoading && !products.length && <div className="pos-list-empty"><Search size={20} aria-hidden="true" /><strong>{search ? `Sin resultados para “${search}”` : "Sin productos disponibles"}</strong><span>{search ? "Prueba con otro nombre, SKU o código." : "Los productos listos para vender aparecerán aquí."}</span>{search && <Button variant="secondary" size="sm" onClick={() => { setSearch(""); searchRef.current?.focus(); }}>Limpiar búsqueda</Button>}</div>}
            {!productLoading && products.length < productTotal && <Button className="pos-load-more" variant="secondary" loading={productLoadingMore} disabled={busy} onClick={() => void loadMoreProducts()}>Cargar más productos</Button>}
            {blockedLoading && <p className="pos-blocked-loading">Consultando existencias en otras sucursales…</p>}
            {blockedOpen && <section className="pos-blocked-results" aria-label="Productos no disponibles"><header><strong>Productos no disponibles</strong><span>{blockedTotal} coincidencias</span></header>{blockedProducts.map((product) => <article key={product.product_id}><span><strong>{highlightSearchMatch(product.name, search)}</strong><small>{highlightSearchMatch(product.code ?? "Sin código", search)} · {product.unit ?? "Sin unidad"}</small></span><div className="pos-blocked-actions"><div className="pos-blocked-status">{product.inventory_tracked && product.blockers.includes("out_of_stock") && <span className="pos-blocked-local">Agotado aquí</span>}{product.blockers.filter((blocker) => blocker !== "out_of_stock").map((blocker) => <span className="pos-blocked-reason" key={blocker}>{posBlockerLabel(blocker)}</span>)}{product.inventory_tracked && product.blockers.includes("out_of_stock") && permissions.includes("view_inventory") && product.other_location_stock_count !== undefined && <span className={product.other_location_stock_count > 0 ? "pos-blocked-remote" : "pos-blocked-remote is-empty"}>{product.other_location_stock_count > 0 ? `${Number(product.other_location_stock_quantity).toLocaleString("es-MX", { maximumFractionDigits: 3 })} ${product.unit ?? ""} · ${product.other_location_stock_count} sucursal${product.other_location_stock_count === 1 ? "" : "es"}` : "Sin stock en otras sucursales"}</span>}</div>{product.inventory_tracked && product.blockers.includes("out_of_stock") && permissions.includes("view_inventory") && product.other_location_stock_count !== 0 && <Button size="sm" variant="ghost" disabled={busy} onClick={() => openLocationStock(product)}><ClipboardList size={14} /> Ver existencias</Button>}</div></article>)}</section>}
          </div>
        </section>
        <aside className="pos-cart" id="pos-checkout">
          <div className="pos-cart__top"><div><span className="eyebrow">Venta actual</span><h2>{quote?.items.length ?? 0} {(quote?.items.length ?? 0) === 1 ? "partida" : "partidas"}</h2></div><span className="pos-cart__actions">{permissions.includes("apply_discount") && <Button variant="ghost" size="sm" disabled={!quote?.items.length} onClick={() => setDiscountOpen(true)}>Aplicar descuento</Button>}<Badge tone="success">Caja abierta</Badge></span></div>
          <div ref={customerPickerRef} className="pos-customer-picker"><div className="pos-customer-picker__heading"><span>Cliente</span>{permissions.includes("manage_customers") && <button type="button" onClick={() => setQuickCustomerOpen(true)}><UserPlus size={13} aria-hidden="true" /> Crear cliente</button>}</div><Input ref={customerRef} value={customerQuery} onFocus={() => setCustomerPickerOpen(customerResults.length > 0)} onClick={() => setCustomerPickerOpen(customerResults.length > 0)} onChange={(event) => setCustomerQuery(event.target.value)} placeholder={customer ? customer.display_name : "Buscar cliente (F2)"} aria-label="Buscar cliente" aria-controls="pos-customer-options" aria-describedby="pos-customer-status" /><span id="pos-customer-status" className="sr-only" role="status" aria-live="polite">{customerQuery && customerResults.length ? `${customerResults.length} clientes disponibles.` : ""}</span>{customer && <button className="pos-customer-chip" aria-label={`Quitar cliente ${customer.display_name}`} onClick={() => void selectCustomer(null)}><span>{customer.display_name}</span><X size={14} aria-hidden="true" /></button>}{customerPickerOpen && customerResults.length > 0 && <div id="pos-customer-options" className="pos-customer-results">{customerResults.map((item) => <button key={item.id} disabled={saleType === "credit" && (!item.credit_enabled || Boolean(item.alpha_external_code && item.migration_status !== "promoted"))} onClick={() => void selectCustomer(item)}><strong>{item.display_name}</strong><small>{item.code}{saleType === "credit" && item.available_credit !== undefined ? ` · crédito disponible ${money(item.available_credit)}` : ""}{item.alpha_external_code && item.migration_status !== "promoted" ? " · migración pendiente" : ""}</small></button>)}</div>}</div>
          {customer && saleType === "credit" && customer.available_credit !== undefined && <div className="pos-credit-alert"><CircleDollarSign size={18} /><div><strong>Crédito disponible</strong><span>{money(customer.available_credit)} · plazo {customer.credit_term_days} días</span></div></div>}
          <div className="pos-cart-lines" role="region" aria-label="Productos en la venta" tabIndex={(quote?.items.length ?? 0) > 2 ? 0 : undefined}>{quote?.items.length ? quote.items.map((item) => <article key={item.cart_item_id} tabIndex={0} aria-label={`${item.name}, cantidad ${item.quantity}. Usa más o menos para ajustar la partida.`} onKeyDown={(event) => { if (busy || event.target !== event.currentTarget) return; if (event.key === "+") { event.preventDefault(); void changeItem(item.product_id, 1); } if (event.key === "-") { event.preventDefault(); void changeItem(item.product_id, -1); } }}><div><strong>{item.name}</strong><small>{item.code ?? ""} · {money(item.total_amount / item.quantity, quote.currency_code ?? "MXN")} por unidad</small></div><div className="pos-line-controls"><button aria-label={`Restar ${item.name}`} disabled={busy} onClick={() => void changeItem(item.product_id, -1)}><Minus size={14} aria-hidden="true" /></button><Input key={`${item.cart_item_id}:${quote.revision}`} className="pos-quantity-input" type="number" min="0" max={item.inventory_tracked ? item.quantity_on_hand : undefined} step="any" inputMode="decimal" defaultValue={item.quantity} aria-label={`Cantidad de ${item.name}`} disabled={busy} onBlur={(event) => setItemQuantity(item.product_id, item.quantity, event.currentTarget)} onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); if (event.key === "Escape") { event.currentTarget.value = String(item.quantity); event.currentTarget.blur(); } }} /><button aria-label={`Sumar ${item.name}`} disabled={busy} onClick={() => void changeItem(item.product_id, 1)}><Plus size={14} aria-hidden="true" /></button><strong>{money(item.total_amount, quote.currency_code ?? "MXN")}</strong></div></article>) : <div className="pos-cart-empty"><ShoppingCart size={22} aria-hidden="true" /><strong>Carrito vacío</strong><span>Busca o escanea un producto para comenzar.</span></div>}</div>
          <div className="pos-settlement">
            <div className="pos-cart-summary"><dl><div><dt>Subtotal</dt><dd>{money(quote?.subtotal_amount, quote?.currency_code ?? "MXN")}</dd></div><div><dt>Descuentos</dt><dd>−{money(quote?.discount_amount, quote?.currency_code ?? "MXN")}</dd></div><div><dt>Impuestos</dt><dd>{money(quote?.tax_amount, quote?.currency_code ?? "MXN")}</dd></div><div className="pos-cart-summary__total"><dt>Total</dt><dd>{money(quote?.total_amount, quote?.currency_code ?? "MXN")}</dd></div></dl></div>
            {quote?.pending_discount_approval && <div className="pos-credit-alert is-blocked"><AlertCircle size={18} /><div><strong>Descuento pendiente</strong><span>Otro usuario autorizado debe aprobarlo antes de cobrar.</span></div></div>}
            <div className="pos-checkout">
            <div className="pos-sale-type" role="group" aria-label="Tipo de venta">
              <button aria-pressed={saleType === "cash"} className={saleType === "cash" ? "is-active" : ""} onClick={() => setSaleType("cash")}>Contado</button>
              {permissions.includes("sell_credit") && <button aria-pressed={saleType === "credit"} className={saleType === "credit" ? "is-active" : ""} onClick={() => setSaleType("credit")}>Crédito</button>}
              {permissions.includes("manage_sales_orders") && <button aria-pressed={saleType === "deferred"} className={saleType === "deferred" ? "is-active" : ""} onClick={() => { setSaleType("deferred"); setReceived(""); setPaymentReference(""); }}>Entrega posterior</button>}
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
            <Button variant="primary" size="lg" loading={busy} disabled={!quote?.can_checkout || (saleType === "cash" && (!paymentMethodId || (isCashPayment && !validReceivedAmount) || (selectedPayment?.settlement_kind === "external" && !paymentReference.trim()))) || (saleType === "credit" && (!customer?.credit_enabled || Boolean(customer.alpha_external_code && customer.migration_status !== "promoted"))) || (saleType === "deferred" && (!customer || !validOrderPayment))} onClick={() => void complete()}>{saleType === "cash" ? "Cobrar" : saleType === "credit" ? "Confirmar crédito" : "Crear orden"} <kbd>F8</kbd></Button>
            </div>
          </div>
        </aside>
      </div>
    </>}
    <Modal open={Boolean(ticket)} onOpenChange={(open) => { if (!open) finishTicket(); }} eyebrow="Venta confirmada" title={`Ticket ${ticket?.folio ?? ""}`} description="El cliente ve precios totales; el desglose fiscal permanece disponible internamente." footer={<><Button variant="secondary" loading={ticketDownloading} onClick={() => void printCompletedTicket()}><Printer size={15} /> Imprimir ticket</Button><Button variant="primary" onClick={finishTicket}>Nueva venta</Button></>}><TicketPreview ticket={ticket?.ticket} /></Modal>
    <Modal className="pos-location-stock-dialog" open={Boolean(stockProduct)} onOpenChange={(open) => { if (!open) { setStockProduct(null); setLocationStock(null); } }} eyebrow="Inventario por sucursal" title={stockProduct?.name ?? "Otras sucursales"} description={`Producto ${stockProduct?.code ?? "sin código"} · Sucursal activa: ${selectedLocation?.name ?? selectedRegister?.name ?? "sin seleccionar"}. Solo lectura.`} footer={<Button onClick={() => { setStockProduct(null); setLocationStock(null); }}>Cerrar <kbd>Esc</kbd></Button>}>{locationStockLoading ? <DataState loading error={null} hasData={0} empty="">{null}</DataState> : locationStock ? <section className="pos-location-stock"><header><span>Disponibilidad en otras sucursales</span><strong>{locationStock.total} {locationStock.total === 1 ? "sucursal" : "sucursales"}</strong></header>{otherLocationStockItems.length ? <div className="pos-location-stock__rows">{otherLocationStockItems.map((item) => { const quantity = Number(item.quantity_on_hand); const status = otherLocationStockStatus(quantity); return <article className={`is-${status.tone}`} key={item.location_id}><span className="pos-location-stock__location"><strong>{item.location_name}</strong><small>{item.location_code}</small></span><span className="pos-location-stock__quantity"><small>{status.label}</small><b>{quantity.toLocaleString("es-MX", { maximumFractionDigits: 3 })} <em>{locationStock.unit ?? stockProduct?.unit ?? ""}</em></b></span></article>; })}</div> : <p>No hay otras sucursales autorizadas para consultar.</p>}{locationStock.total > locationStock.page_size && <DataPagination page={locationStock.page} total={locationStock.total} pageSize={locationStock.page_size} label="sucursales" onChange={(page) => { if (stockProduct) void loadLocationStock(stockProduct, page); }} />}</section> : null}</Modal>
    <Drawer open={quickCustomerOpen} onOpenChange={setQuickCustomerOpen} title="Alta rápida de cliente"><form className="sales-form" onSubmit={createQuickCustomer}><p className="settings-note">Solo lo necesario para continuar la venta. Se crea de contado y hereda la lista de precios de esta ubicación.</p><label>Nombre<Input required autoFocus value={quickCustomerName} onChange={(event) => setQuickCustomerName(event.target.value)} /></label><label>Teléfono opcional<Input inputMode="tel" value={quickCustomerPhone} onChange={(event) => setQuickCustomerPhone(event.target.value)} /></label><label>RFC opcional<Input value={quickCustomerTaxId} onChange={(event) => setQuickCustomerTaxId(event.target.value.toUpperCase())} /></label><Button type="submit" variant="primary" loading={busy}>Crear y seleccionar</Button></form></Drawer>
    <Modal open={discountOpen} onOpenChange={setDiscountOpen} title="Solicitar descuento" description="El límite de tu rol se aplica automáticamente; si lo superas, el carrito queda pendiente de aprobación." footer={<Button type="submit" form="sale-discount-form" variant="primary" loading={busy}>Solicitar</Button>}><form id="sale-discount-form" className="sales-form" onSubmit={requestDiscount}><label>Porcentaje<Input required inputMode="decimal" min="0.01" max="100" value={discountPercent} onChange={(event) => setDiscountPercent(event.target.value)} /></label><label>Motivo<Input required value={discountReason} onChange={(event) => setDiscountReason(event.target.value)} placeholder="Motivo comercial" /></label></form></Modal>
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
  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("list_sales", { p_company_id: companyId, p_location_id: null, p_query: query || null, p_page: page, p_page_size: 50 });
    if (loadError) setError("No se pudieron consultar las ventas.");
    else { const result = data as { items?: SaleRow[]; total?: number }; setRows(result.items ?? []); setTotal(result.total ?? 0); setError(null); }
    setLoading(false);
  }, [companyId, page, query]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 150); return () => window.clearTimeout(timer); }, [load]);
  const loadApprovals = useCallback(async () => {
    if (!permissions.includes("approve_discount")) return;
    const { data } = await getSupabaseClient().rpc("list_pending_discount_approvals", { p_company_id: companyId });
    setApprovals((data ?? []) as Array<{ id: string; scope: string; requested_percent: number; requested_reason: string; created_at: string }>);
  }, [companyId, permissions]);
  useEffect(() => { void Promise.resolve().then(loadApprovals); }, [loadApprovals]);
  async function openTicket(saleId: string) {
    const client = getSupabaseClient();
    const [{ data, error: ticketError }, { data: cancellation }, { data: postSale }] = await Promise.all([
      client.rpc("get_canonical_ticket", { p_sale_id: saleId }),
      client.from("sale_cancellations").select("id, reason, cancelled_at").eq("company_id", companyId).eq("sale_id", saleId).maybeSingle(),
      client.rpc("get_sale_return_context", { p_company_id: companyId, p_sale_id: saleId }),
    ]);
    if (ticketError) { toast({ title: "No se pudo abrir el ticket", description: rpcError(ticketError, "Intenta nuevamente."), tone: "error" }); return; }
    setTicket({ saleId, payload: (data as { payload: Record<string, unknown> }).payload, cancellation });
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
  return <div className="content-frame"><PageTitle eyebrow="Documentos inmutables" title="Ventas" description="Consulta tickets canónicos y registra postventa sin modificar la venta original." />{permissions.includes("approve_discount") && approvals.length > 0 && <section className="discount-approvals"><header><strong>Descuentos pendientes</strong><Badge tone="warning">{approvals.length}</Badge></header>{approvals.map((approval) => <article key={approval.id}><span><strong>{approval.requested_percent}% · {approval.scope === "sale" ? "Venta" : "Línea"}</strong><small>{approval.requested_reason} · {dateTime(approval.created_at)}</small></span><div><Button size="sm" variant="ghost" onClick={() => void decideDiscount(approval.id, false)}>Rechazar</Button><Button size="sm" variant="primary" onClick={() => void decideDiscount(approval.id, true)}>Aprobar</Button></div></article>)}</section>}<DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar folio o cliente" results={total} /><DataRefreshStatus loading={loading} hasData={rows.length}/><DataState loading={loading&&rows.length===0} error={error} errorAction={<Button size="sm" onClick={()=>void load()}>Reintentar</Button>} hasData={rows.length} emptyTitle={query?"No encontramos ventas.":"Aún no hay ventas."} empty={query?"Cambia o limpia la búsqueda para ampliar los resultados.":"Las ventas confirmadas aparecerán aquí."}><div className="sales-history">{rows.map((row) => <button key={row.sale_id} onClick={() => void openTicket(row.sale_id)}><span><strong>{row.folio}</strong><small>{row.customer_name ?? "Venta de mostrador"} · {dateTime(row.completed_at)}{Number(row.returned_amount)>0 ? ` · Devuelto ${money(row.returned_amount,row.currency_code)}` : ""}</small></span><span>{row.cancelled ? <Badge tone="neutral">Cancelada</Badge> : Number(row.returned_amount)>0 ? <Badge tone="warning">Postventa</Badge> : <Badge tone={row.sale_type === "credit" ? "warning" : "success"}>{row.sale_type === "credit" ? "Crédito" : "Contado"}</Badge>}<b>{money(row.total_amount, row.currency_code)}</b></span></button>)}</div><SettingsPagination page={page} totalPages={Math.max(1, Math.ceil(total / 50))} onChange={setPage} /></DataState><Modal open={Boolean(ticket)} onOpenChange={(open) => { if (!open) setTicket(null); }} title="Ticket canónico" className="sales-ticket-detail-dialog" footer={<>{ticket?.cancellation ? <Badge tone="neutral">Venta cancelada</Badge> : returnContext?.can_process && returnContext.items.some((item) => Number(item.available_quantity)>0) ? <Button variant="secondary" onClick={beginReturn}>Registrar devolución</Button> : null}{!ticket?.cancellation && !returnContext?.returns.length && permissions.includes("cancel_sales") ? <Button variant="danger" onClick={() => setCancellationReason("")}>Cancelar venta</Button> : null}<Button variant="secondary" loading={ticketDownloading} onClick={() => void printHistoricalTicket()}><Printer size={15} /> Imprimir ticket</Button><Button onClick={() => setTicket(null)}>Cerrar</Button></>}><TicketPreview ticket={ticket?.payload ?? null} />{ticket?.cancellation && <p className="settings-note">Cancelada: {ticket.cancellation.reason} · {dateTime(ticket.cancellation.cancelled_at)}</p>}{Boolean(returnContext?.returns.length) && <section className="sale-return-history"><h3>Devoluciones</h3>{returnContext?.returns.map((item) => <article key={item.id}><span><strong>{money(item.total_amount,returnContext.sale.currency_code)}</strong><small>{dateTime(item.returned_at)} · {item.reason}</small></span><Badge tone="warning">{item.items.reduce((sum,line)=>sum+Number(line.quantity),0)} devuelto</Badge></article>)}</section>}</Modal><Modal open={returnOpen} onOpenChange={(open) => { if (!open && !returning) setReturnOpen(false); }} eyebrow="Postventa auditada" title={`Devolución · ${returnContext?.sale.folio ?? ""}`} description="Captura en conjunto las partidas recibidas. La venta y el ticket originales no se editan." footer={<><Button disabled={returning} onClick={() => setReturnOpen(false)}>Volver</Button><Button variant="primary" loading={returning} disabled={!returnReason.trim() || selectedReturnCount===0 || returnBlockedByCash || (returnContext?.settlement_kind==="external"&&!returnReference.trim())} onClick={() => void processReturn()}>Confirmar devolución</Button></>}>{returnContext && <div className="sale-return-form"><div className="sale-return-lines">{returnContext.items.map((item) => { const draft=returnLines[item.sale_item_id]??{quantity:"",restock:item.inventory_tracked};const unavailable=Number(item.available_quantity)<=0;return <article key={item.sale_item_id} className={unavailable?"is-complete":undefined}><div><strong>{item.product_name}</strong><small>{item.product_code} · Vendido {item.sold_quantity} · Ya devuelto {item.returned_quantity} · Disponible {item.available_quantity} {item.unit_name??""}</small></div><label>Cantidad<Input disabled={unavailable} inputMode="decimal" value={draft.quantity} onChange={(event)=>setReturnLines((current)=>({...current,[item.sale_item_id]:{...draft,quantity:event.target.value}}))} placeholder="0" /></label><label className="sale-return-restock"><input type="checkbox" disabled={unavailable||!item.inventory_tracked} checked={draft.restock&&item.inventory_tracked} onChange={(event)=>setReturnLines((current)=>({...current,[item.sale_item_id]:{...draft,restock:event.target.checked}}))}/><span>Mercancía recibible<br/><small>{item.inventory_tracked?"Reintegrar a inventario":"Sin control de inventario"}</small></span></label></article>;})}</div>{returnBlockedByCash && <p className="settings-note is-danger">Abre una caja propia en la sucursal original antes de reembolsar en efectivo.</p>}{returnContext.settlement_kind==="external"&&<label>Referencia del reembolso externo<Input required value={returnReference} onChange={(event)=>setReturnReference(event.target.value)} placeholder="Folio o autorización del procesador" /></label>}<label>Motivo obligatorio<textarea rows={3} value={returnReason} onChange={(event)=>setReturnReason(event.target.value)} placeholder="Describe la causa de la devolución" /></label><p className="settings-note">{returnContext.settlement_kind==="receivable"?"El importe reducirá el saldo pendiente de esta venta.":"El reembolso seguirá el medio de pago original."} Sólo las partidas marcadas como recibibles regresarán a existencia.</p></div>}</Modal><Modal open={cancellationReason !== null} onOpenChange={(open) => { if (!open && !cancelling) setCancellationReason(null); }} eyebrow="Reversa auditada" title="Cancelar venta" description="Se devolverá el inventario y se generará la póliza inversa. El ticket original permanecerá inmutable." footer={<><Button disabled={cancelling} onClick={() => setCancellationReason(null)}>Volver</Button><Button variant="danger" loading={cancelling} disabled={!cancellationReason?.trim()} onClick={() => void cancelSale()}>Confirmar cancelación</Button></>}><label className="operation-reason">Motivo obligatorio<textarea rows={4} value={cancellationReason ?? ""} onChange={(event) => setCancellationReason(event.target.value)} placeholder="Ej. Venta de prueba controlada" /></label></Modal></div>;
}

export function CustomersView({ companyId, permissions, initialCustomerId = null, initialCreateOpen = false }: { companyId: string; permissions: string[]; initialCustomerId?: string | null; initialCreateOpen?: boolean }) {
  const router = useRouter();
  const canViewCredit = permissions.includes("view_customer_credit");
  const [query, setQuery] = useState(""); const [rows, setRows] = useState<Customer[]>([]); const [total, setTotal] = useState(0); const [page, setPage] = useState(1); const [loading, setLoading] = useState(true);
  const [selectedCustomerId, setSelectedCustomerId] = useState<string | null>(initialCustomerId); const [createOpen, setCreateOpen] = useState(initialCreateOpen); const initialRouteHandled = useRef(false);
  const load = useCallback(async () => { setLoading(true); const { data } = await getSupabaseClient().rpc(canViewCredit ? "search_sale_customers_credit" : "search_sale_customers", { p_company_id: companyId, p_query: query || null, p_page: page, p_page_size: 100 }); const result = data as { items?: Customer[]; total?: number } | null; setRows(result?.items ?? []); setTotal(result?.total ?? 0); setLoading(false); }, [canViewCredit, companyId, page, query]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 150); return () => window.clearTimeout(timer); }, [load]);
  function closeDrawer() { setSelectedCustomerId(null); setCreateOpen(false); if (!initialRouteHandled.current && (initialCustomerId || initialCreateOpen)) { initialRouteHandled.current = true; router.replace("/satrapy/ventas/clientes"); } }
  return <><div className="content-frame"><PageTitle eyebrow="Relación comercial" title="Clientes" description="Busca y administra la información comercial de cada cliente." action={permissions.includes("manage_customers") ? <Button variant="primary" onClick={() => setCreateOpen(true)}><UserPlus size={16} /> Nuevo cliente</Button> : undefined} /><DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar código, nombre, RFC o teléfono" results={total} /><DataState loading={loading} error={null} hasData={rows.length} empty="No se encontraron clientes."><div className="table-wrap surface-table"><table><thead><tr><th>Cliente</th><th>Crédito</th>{canViewCredit && <><th className="number-cell">Saldo</th><th className="number-cell">Disponible</th></>}<th aria-label="Acciones" /></tr></thead><tbody>{rows.map((row) => <InteractiveTableRow key={row.id} label={`Ver cliente ${row.display_name}`} onActivate={() => setSelectedCustomerId(row.id)}><td><strong className="customer-name-link">{row.display_name}</strong><small className="table-subline">{row.code}</small></td><td>{row.credit_enabled ? <Badge tone="success">{canViewCredit ? `${row.credit_term_days} días` : "Habilitado"}</Badge> : <Badge>Contado</Badge>}</td>{canViewCredit && <><td className="number-cell">{money(row.outstanding_amount)}</td><td className="number-cell">{row.credit_enabled ? money(row.available_credit) : "—"}</td></>}<td><Button size="sm" variant="ghost" onClick={() => setSelectedCustomerId(row.id)}>Ver cliente</Button></td></InteractiveTableRow>)}</tbody></table></div><SettingsPagination page={page} totalPages={Math.max(1, Math.ceil(total / 100))} onChange={setPage} /></DataState></div><CustomerCreateDrawer companyId={companyId} permissions={permissions} open={createOpen} onOpenChange={(open) => { if (!open) closeDrawer(); else setCreateOpen(true); }} onCreated={(customerId) => { setCreateOpen(false); setSelectedCustomerId(customerId); void load(); }} />{selectedCustomerId && <CustomerDetailDrawer companyId={companyId} customerId={selectedCustomerId} permissions={permissions} open={Boolean(selectedCustomerId)} onOpenChange={(open) => { if (!open) closeDrawer(); }} />}</>;
}

function CustomerCreateDrawer({ companyId, permissions, open, onOpenChange, onCreated }: { companyId: string; permissions: string[]; open: boolean; onOpenChange: (open: boolean) => void; onCreated: (customerId: string) => void }) {
  const { toast } = useToast(); const [name, setName] = useState(""); const [phone, setPhone] = useState(""); const [taxId, setTaxId] = useState(""); const [email, setEmail] = useState(""); const [customerType, setCustomerType] = useState(""); const [notes, setNotes] = useState(""); const [saving, setSaving] = useState(false);
  async function createCustomer(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { data, error } = await getSupabaseClient().rpc("upsert_sale_customer", { p_company_id: companyId, p_customer_id: null, p_code: null, p_display_name: name, p_tax_id: taxId || null, p_email: email || null, p_phone: phone || null, p_price_list_id: null, p_credit_enabled: false, p_credit_limit: 0, p_credit_term_days: 0, p_customer_type: customerType || null, p_notes: notes || null }); setSaving(false); if (error || !data) { toast({ title: "No se pudo crear el cliente", description: rpcError(error, "Verifica los datos generales."), tone: "error" }); return; } toast({ title: "Cliente creado", description: "Quedó activo, de contado y con la lista de precios heredada.", tone: "success" }); onCreated(data as string); }
  if (!permissions.includes("manage_customers")) return null;
  return <Drawer open={open} onOpenChange={(next) => { if (!saving) onOpenChange(next); }} title="Nuevo cliente" className="customer-drawer"><header className="customer-drawer__heading"><div><span className="eyebrow">Relación comercial</span><p>Registra la información inicial. Después podrás completar sus datos comerciales.</p></div><Badge>Contado</Badge></header><form className="customer-master-form" onSubmit={createCustomer}><div className="customer-master-grid"><label>Nombre o razón social<Input required autoFocus value={name} onChange={(event) => setName(event.target.value)} /></label><label>Teléfono <small>Opcional, recomendado</small><Input inputMode="tel" value={phone} onChange={(event) => setPhone(event.target.value)} /></label><label>RFC <small>Opcional</small><Input value={taxId} onChange={(event) => setTaxId(event.target.value.toUpperCase())} placeholder="Se valida solo si lo capturas" /></label><label>Correo <small>Opcional</small><Input type="email" value={email} onChange={(event) => setEmail(event.target.value)} /></label><label>Tipo de cliente <small>Opcional</small><Select ariaLabel="Tipo de cliente" value={customerType} onValueChange={setCustomerType} options={[{ value: "", label: "Sin especificar" }, { value: "persona_fisica", label: "Persona física" }, { value: "persona_moral", label: "Persona moral" }]} /></label><label className="is-wide">Notas <small>Opcionales</small><Input value={notes} onChange={(event) => setNotes(event.target.value)} /></label></div><p className="settings-note">Código interno y estado activo se asignan automáticamente. El cliente queda de contado y hereda la lista de precios de la ubicación o empresa.</p><div className="customer-drawer__actions"><Button type="button" variant="secondary" disabled={saving} onClick={() => onOpenChange(false)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving}>Crear cliente</Button></div></form></Drawer>;
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

export function ReceivablesView({ companyId }: { companyId: string }) {
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

  if (contextLoading) return <div className="content-frame"><DataState loading error={null} hasData={0} empty="">{null}</DataState></div>;
  if (contextError || !context) return <div className="content-frame"><DataState loading={false} error={contextError ?? "No se pudo cargar cuentas por cobrar."} hasData={0} empty="">{null}</DataState></div>;

  return <div className="content-frame receivables-page">
    <PageTitle eyebrow="Cobranza" title="Cuentas por cobrar" description="Localiza al cliente con saldo pendiente, confirma sus datos de cobranza y registra el abono con aplicación FIFO." />
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
  const loadOperations = useCallback(async () => { if (session) { const client = getSupabaseClient(); const [{ data: dashboardData }, { data: movementData }] = await Promise.all([client.rpc("get_cash_session_dashboard", { p_cash_session_id: session.id }), client.rpc("list_cash_session_movements_page", { p_cash_session_id: session.id, p_page: movementPage, p_page_size: 25 })]); setDashboard((dashboardData ?? null) as CashDashboard | null); const movementResult = movementData as { items?: typeof movements; total?: number } | null; setMovements(movementResult?.items ?? []); setMovementTotal(movementResult?.total ?? 0); } else { setDashboard(null); setMovements([]); setMovementTotal(0); } const { data } = await getSupabaseClient().rpc("list_pending_cash_variances", { p_company_id: companyId }); setVariances((data ?? []) as typeof variances); }, [companyId, movementPage, session]);
  useEffect(() => { void Promise.resolve().then(loadOperations); }, [loadOperations]);
  async function recordMovement(event: React.FormEvent) { event.preventDefault(); if (!session) return; setBusy(true); const { error: movementError } = await getSupabaseClient().rpc("record_cash_drawer_movement", { p_cash_session_id: session.id, p_movement_type: movementType, p_amount: Number(movementAmount), p_reason: movementReason }); if (movementError) toast({ title: "No se pudo registrar el movimiento", description: rpcError(movementError, "Verifica importe y motivo."), tone: "error" }); else { setMovementAmount(""); setMovementReason(""); await loadOperations(); toast({ title: "Movimiento registrado", tone: "success" }); } setBusy(false); }
  async function approveVariance(id: string) { setBusy(true); const fingerprint = JSON.stringify({ cashSessionId: id }); const { error: approvalError } = await getSupabaseClient().rpc("approve_cash_variance", { p_cash_session_id: id, p_approval_reason: null, p_client_request_id: idempotency.get("approve-cash-variance", fingerprint) }); if (approvalError) toast({ title: "No se pudo aprobar la diferencia", description: rpcError(approvalError, "Revisa permisos y ubicación."), tone: "error" }); else { idempotency.clear("approve-cash-variance"); await loadOperations(); toast({ title: "Diferencia aprobada", tone: "success" }); } setBusy(false); }
  if (loading) return <div className="content-frame"><DataState loading error={null} hasData={0} empty="">{null}</DataState></div>; if (error || !context) return <div className="content-frame"><DataState loading={false} error={error ?? "No se pudo cargar Caja."} hasData={0} empty="">{null}</DataState></div>;
  const multipleRegistersNeedChoice = !context.own_open_session && context.registers.length > 1 && !registerId;
  const currency = dashboard?.currency_code ?? register?.currency_code ?? "MXN"; const realtimeVariance = counted - Number(dashboard?.expected_cash ?? 0);
  return <div className="content-frame"><PageTitle eyebrow="Turno y arqueo" title="Caja" description="Apertura, movimientos y cierre del turno con cálculo definitivo en servidor." />{dashboard && <section className="cash-session-context"><span><small>Caja</small><strong>{dashboard.register_name} · {dashboard.register_code}</strong></span><span><small>Ubicación</small><strong>{dashboard.location_name}</strong></span><span><small>Cajero</small><strong>{dashboard.cashier_name}</strong></span><span><small>Apertura</small><strong>{dateTime(dashboard.opened_at)}</strong></span></section>} {dashboard && <section className="cash-live-summary"><article><span>Efectivo esperado</span><strong>{money(dashboard.expected_cash, currency)}</strong></article><article><span>Total contado</span><strong>{money(counted, currency)}</strong></article><article className={realtimeVariance === 0 ? "" : "is-warning"}><span>Diferencia en tiempo real</span><strong>{money(realtimeVariance, currency)}</strong></article><article><span>Ventas de contado</span><strong>{money(dashboard.cash_sales, currency)}</strong></article></section>}<div className="cash-workspace"><section className="cash-card">{context.own_open_session ? <p className="settings-note">Tu sesión está ligada a esta caja y no puede cambiarse desde el POS.</p> : <Select ariaLabel="Caja" value={registerId} onValueChange={setRegisterId} options={[{ value: "", label: multipleRegistersNeedChoice ? "Selecciona una caja" : "Sin cajas disponibles" }, ...context.registers.map((item) => ({ value: item.id, label: `${item.name} · ${item.code}` }))]} />}{session ? <Badge tone="success">Sesión abierta</Badge> : <Badge>Sin sesión abierta</Badge>}<h2>{session ? "Arqueo de cierre" : "Apertura de caja"}</h2>{multipleRegistersNeedChoice ? <p>Selecciona explícitamente la caja física que abrirás.</p> : !register ? <p>No hay una caja disponible para tu ubicación.</p> : <><p>Confirma todas las denominaciones, incluyendo las que tienen cantidad cero. El total definitivo se calcula en servidor.</p><DenominationCount denominations={denominations} counts={counts} onChange={setCounts} currency={register.currency_code} /><div className="cash-count-total">Total contado <strong>{money(counted, register.currency_code)}</strong></div>{session && <label className="cash-reason">Motivo de diferencia si aplica<Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Obligatorio si hay diferencia" /></label>}<Button variant="primary" loading={busy} onClick={() => void (session ? close() : open())}>{session ? "Solicitar cierre" : "Abrir caja"}</Button></>}</section><section className="cash-card cash-card--info"><ClipboardList size={22} /><h2>Movimientos del turno</h2>{session && <form className="cash-movement-form" onSubmit={recordMovement}><Select ariaLabel="Tipo de movimiento" value={movementType} onValueChange={(value) => setMovementType(value as "paid_in" | "paid_out")} options={[{ value: "paid_in", label: "Ingreso de efectivo" }, { value: "paid_out", label: "Salida de efectivo" }]} /><label>Importe<Input required min="0.01" step="0.01" inputMode="decimal" value={movementAmount} onChange={(event) => setMovementAmount(event.target.value)} /></label><label>Motivo<Input required value={movementReason} onChange={(event) => setMovementReason(event.target.value)} /></label><Button type="submit" loading={busy}>Registrar</Button></form>}{movements.length > 0 && <div className="cash-movement-list">{movements.map((movement) => <p key={movement.id}><span><b>{movement.movement_type}</b><small>{dateTime(movement.occurred_at)} · {movement.reason ?? "Sin motivo"}</small></span><strong>{money(movement.amount, currency)}</strong></p>)}</div>}<Pagination page={movementPage} total={movementTotal} pageSize={25} onChange={setMovementPage} />{variances.length > 0 && <div className="cash-movement-list"><strong>Diferencias pendientes</strong>{variances.map((variance) => <p key={variance.cash_session_id}><span>{money(variance.variance_amount)} · {variance.variance_reason ?? "Sin motivo"}</span><Button size="sm" onClick={() => void approveVariance(variance.cash_session_id)}>Aprobar</Button></p>)}</div>}<ul><li>Una diferencia nunca se cierra automáticamente.</li><li>La aprobación debe hacerla otra persona autorizada.</li></ul>{result && <div className={result.variance_amount ? "cash-result is-warning" : "cash-result"}><strong>{result.status === "closed" ? "Caja cerrada" : "Aprobación pendiente"}</strong>{result.expected_amount !== undefined && <span>Esperado {money(result.expected_amount)} · contado {money(result.counted_amount)} · diferencia {money(result.variance_amount)}</span>}</div>}</section></div></div>;
}

export function SalesSettingsView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const [payments, setPayments] = useState<Array<{ id: string; code: string; display_name: string; settlement_kind: string; is_active: boolean }>>([]);
  const [registers, setRegisters] = useState<Array<{ id: string; code: string; display_name: string; location_id: string; currency_code: string; is_active: boolean }>>([]);
  const [denominations, setDenominations] = useState<Array<{ id: string; value: number; display_name: string; currency_code: string; is_active: boolean }>>([]);
  const [locations, setLocations] = useState<Array<{ id: string; name: string; external_code: string; default_price_list_id: string | null }>>([]);
  const [priceLists, setPriceLists] = useState<Array<{ id: string; name: string; currency_code: string }>>([]);
  const [roles, setRoles] = useState<Array<{ id: string; display_name: string }>>([]);
  const [discountLimits, setDiscountLimits] = useState<Array<{ id: string; role_id: string; scope: "sale" | "line"; max_percent: number; valid_from: string; valid_to: string | null }>>([]);
  const [loading, setLoading] = useState(true); const [loadError, setLoadError] = useState<string | null>(null); const [saving, setSaving] = useState(false);
  const [resource, setResource] = useState<SettingsResourceKey>("payments"); const [query, setQuery] = useState(""); const [statusFilter, setStatusFilter] = useState("all"); const [page, setPage] = useState(1);
  const [drawer, setDrawer] = useState<SettingsDrawer | null>(null); const [confirmation, setConfirmation] = useState<SettingsConfirmation | null>(null);
  const [paymentId, setPaymentId] = useState<string | null>(null); const [paymentCode, setPaymentCode] = useState(""); const [paymentName, setPaymentName] = useState(""); const [paymentKind, setPaymentKind] = useState("cash_drawer"); const [paymentActive, setPaymentActive] = useState(true);
  const [registerEditId, setRegisterEditId] = useState<string | null>(null); const [registerCode, setRegisterCode] = useState(""); const [registerName, setRegisterName] = useState(""); const [registerLocationId, setRegisterLocationId] = useState(""); const [registerActive, setRegisterActive] = useState(true);
  const [denominationId, setDenominationId] = useState<string | null>(null); const [denominationValue, setDenominationValue] = useState(""); const [denominationName, setDenominationName] = useState(""); const [denominationActive, setDenominationActive] = useState(true);
  const [locationPriceLocationId, setLocationPriceLocationId] = useState(""); const [locationPriceListId, setLocationPriceListId] = useState("");
  const [roleId, setRoleId] = useState(""); const [discountScope, setDiscountScope] = useState("sale"); const [discountLimit, setDiscountLimit] = useState(""); const [discountValidFrom, setDiscountValidFrom] = useState(""); const [discountValidTo, setDiscountValidTo] = useState("");
  const canPayments = permissions.includes("manage_payment_methods"); const canRegisters = permissions.includes("manage_locations"); const canPrices = permissions.includes("manage_prices"); const canDiscounts = permissions.includes("manage_discount_policies"); const canTicketBranding = permissions.includes("manage_ticket_branding"); const canQuoteBranding = permissions.includes("manage_quote_branding");
  const load = useCallback(async () => {
    setLoading(true);
    const client = getSupabaseClient();
    const [paymentResult, registerResult, denominationResult, locationResult, listResult, roleResult, discountResult] = await Promise.all([
      client.from("payment_methods").select("id, code, display_name, settlement_kind, is_active").eq("company_id", companyId).order("display_name"),
      client.from("cash_registers").select("id, code, display_name, location_id, currency_code, is_active").eq("company_id", companyId).order("display_name"),
      client.from("cash_denominations").select("id, value, display_name, currency_code, is_active").eq("company_id", companyId).order("value", { ascending: false }),
      client.from("locations").select("id, name, external_code, default_price_list_id").eq("company_id", companyId).eq("is_active", true).order("name"),
      client.from("price_lists").select("id, name, currency_code").eq("company_id", companyId).eq("is_active", true).eq("status", "active").order("name"),
      client.from("roles").select("id, display_name").order("display_name"),
      client.from("discount_role_limits").select("id, role_id, scope, max_percent, valid_from, valid_to").eq("company_id", companyId).order("valid_from", { ascending: false }),
    ]);
    setPayments((paymentResult.data ?? []) as typeof payments); setRegisters((registerResult.data ?? []) as typeof registers); setDenominations((denominationResult.data ?? []) as typeof denominations); setLocations((locationResult.data ?? []) as typeof locations); setPriceLists((listResult.data ?? []) as typeof priceLists); setRoles((roleResult.data ?? []) as typeof roles);
    setDiscountLimits((discountResult.data ?? []) as typeof discountLimits);
    setLoadError([paymentResult.error, registerResult.error, denominationResult.error, locationResult.error, listResult.error, roleResult.error, discountResult.error].find(Boolean)?.message ?? null);
    setRegisterLocationId((current) => current || (locationResult.data?.[0]?.id ?? "")); setLocationPriceLocationId((current) => current || (locationResult.data?.[0]?.id ?? "")); setLocationPriceListId((current) => current || (listResult.data?.[0]?.id ?? "")); setRoleId((current) => current || (roleResult.data?.[0]?.id ?? "")); setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  function changeResource(next: SettingsResourceKey) { setResource(next); setPage(1); setStatusFilter("all"); setQuery(""); }
  function closeDrawer() { setDrawer(null); }
  function openPayment(item?: typeof payments[number]) { setPaymentId(item?.id ?? null); setPaymentCode(item?.code ?? ""); setPaymentName(item?.display_name ?? ""); setPaymentKind(item?.settlement_kind ?? "cash_drawer"); setPaymentActive(item?.is_active ?? true); setDrawer("payment"); }
  function openRegister(item?: typeof registers[number]) { setRegisterEditId(item?.id ?? null); setRegisterCode(item?.code ?? ""); setRegisterName(item?.display_name ?? ""); setRegisterLocationId(item?.location_id ?? locations[0]?.id ?? ""); setRegisterActive(item?.is_active ?? true); setDrawer("register"); }
  function openDenomination(item?: typeof denominations[number]) { setDenominationId(item?.id ?? null); setDenominationValue(item ? String(item.value) : ""); setDenominationName(item?.display_name ?? ""); setDenominationActive(item?.is_active ?? true); setDrawer("denomination"); }
  function openAssignment(location?: typeof locations[number]) { setLocationPriceLocationId(location?.id ?? locations[0]?.id ?? ""); setLocationPriceListId(location?.default_price_list_id ?? priceLists[0]?.id ?? ""); setDrawer("assignment"); }
  function openDiscount() { setRoleId(roles[0]?.id ?? ""); setDiscountScope("sale"); setDiscountLimit(""); setDiscountValidFrom(""); setDiscountValidTo(""); setDrawer("discount"); }
  async function submitPayment(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_payment_method", { p_company_id: companyId, p_payment_method_id: paymentId, p_code: paymentCode, p_display_name: paymentName, p_settlement_kind: paymentKind, p_is_active: paymentActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica el medio de pago."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: paymentId ? "Forma de pago actualizada" : "Forma de pago creada", tone: "success" }); } setSaving(false); }
  async function submitRegister(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_register", { p_company_id: companyId, p_cash_register_id: registerEditId, p_location_id: registerLocationId, p_code: registerCode, p_display_name: registerName, p_currency_code: "MXN", p_is_active: registerActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica la caja."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: registerEditId ? "Caja actualizada" : "Caja creada", tone: "success" }); } setSaving(false); }
  async function submitDenomination(event: React.FormEvent) { event.preventDefault(); setSaving(true); const { error } = await getSupabaseClient().rpc("upsert_cash_denomination", { p_company_id: companyId, p_denomination_id: denominationId, p_currency_code: "MXN", p_value: Number(denominationValue), p_display_name: denominationName || money(Number(denominationValue)), p_is_active: denominationActive }); if (error) toast({ title: "No se pudo guardar", description: rpcError(error, "Verifica la denominación."), tone: "error" }); else { await load(); closeDrawer(); toast({ title: denominationId ? "Denominación actualizada" : "Denominación creada", tone: "success" }); } setSaving(false); }
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
  const resourceRows = resource === "ticket" || resource === "quote" ? [] : resource === "payments" ? payments.filter((item) => matches(`${item.display_name} ${item.code} ${item.settlement_kind}`) && matchesStatus(statusFilter, item.is_active)) : resource === "registers" ? registers.filter((item) => matches(`${item.display_name} ${item.code}`) && matchesStatus(statusFilter, item.is_active)) : resource === "denominations" ? denominations.filter((item) => matches(`${item.display_name} ${item.value}`) && matchesStatus(statusFilter, item.is_active)) : resource === "prices" ? locations.filter((item) => matches(`${item.name} ${item.external_code} ${priceListById.get(item.default_price_list_id ?? "")?.name ?? ""}`) && (statusFilter === "all" || statusFilter === "assigned" ? Boolean(item.default_price_list_id) : !item.default_price_list_id)) : discountLimits.filter((item) => matches(`${roles.find((role) => role.id === item.role_id)?.display_name ?? ""} ${item.scope} ${item.max_percent}`) && (statusFilter === "all" || discountStatus(item) === statusFilter));
  const totalPages = Math.max(1, Math.ceil(resourceRows.length / SETTINGS_PAGE_SIZE)); const visibleRows = resourceRows.slice((page - 1) * SETTINGS_PAGE_SIZE, page * SETTINGS_PAGE_SIZE);
  const statusOptions = resource === "discounts" ? [{ value: "all", label: "Todos los estados" }, { value: "vigente", label: "Vigentes" }, { value: "futuro", label: "Futuros" }, { value: "vencido", label: "Vencidos" }] : resource === "prices" ? [{ value: "all", label: "Todas las ubicaciones" }, { value: "assigned", label: "Con lista asignada" }, { value: "unassigned", label: "Sin lista" }] : [{ value: "all", label: "Todos los estados" }, { value: "active", label: "Activos" }, { value: "inactive", label: "Desactivados" }];
  const resourceMeta: Record<SettingsResourceKey, { title: string; description: string; count: number; action: () => void; actionLabel: string }> = {
    payments: { title: "Formas de pago", description: "Define cómo se liquida una venta y si debe impactar una caja física.", count: payments.length, action: () => openPayment(), actionLabel: "Nueva forma de pago" },
    registers: { title: "Cajas", description: "Administra cajas físicas por ubicación y su disponibilidad para abrir turnos.", count: registers.length, action: () => openRegister(), actionLabel: "Nueva caja" },
    denominations: { title: "Denominaciones", description: "Catálogo de valores disponibles para aperturas, cierres y arqueos.", count: denominations.length, action: () => openDenomination(), actionLabel: "Agregar denominación" },
    prices: { title: "Listas y precios", description: "Administra listas canónicas, vigencias de precio y su asignación operativa.", count: priceLists.length, action: () => openAssignment(), actionLabel: "Asignar lista" },
    discounts: { title: "Límites de descuento", description: "Políticas append-only por rol. La venta resuelve la vigente en el servidor.", count: discountLimits.length, action: openDiscount, actionLabel: "Nuevo límite" },
    ticket: { title: "Ticket", description: "Configura los datos visibles al imprimir.", count: 1, action: () => undefined, actionLabel: "" },
    quote: { title: "Cotización", description: "Configura la presentación imprimible de propuestas comerciales.", count: 1, action: () => undefined, actionLabel: "" },
  };
  const meta = resourceMeta[resource];
  return <div className="content-frame"><PageTitle eyebrow="Operación comercial" title="Ventas y caja" description="Configura pagos, cajas, precios, descuentos y documentos para nuevas ventas." /><div className="settings-workspace">
    <nav className="settings-resource-nav" aria-label="Módulos de configuración">{canPayments && <button className={resource === "payments" ? "is-active" : ""} onClick={() => changeResource("payments")}>Formas de pago <span>{payments.length}</span></button>}{canRegisters && <button className={resource === "registers" ? "is-active" : ""} onClick={() => changeResource("registers")}>Cajas <span>{registers.length}</span></button>}{canPayments && <button className={resource === "denominations" ? "is-active" : ""} onClick={() => changeResource("denominations")}>Denominaciones <span>{denominations.length}</span></button>}{canPrices && <button className={resource === "prices" ? "is-active" : ""} onClick={() => changeResource("prices")}>Listas y precios <span>{priceLists.length}</span></button>}{canDiscounts && <button className={resource === "discounts" ? "is-active" : ""} onClick={() => changeResource("discounts")}>Límites de descuento <span>{discountLimits.length}</span></button>}{canTicketBranding && <button className={resource === "ticket" ? "is-active" : ""} onClick={() => changeResource("ticket")}>Ticket</button>}{canQuoteBranding && <button className={resource === "quote" ? "is-active" : ""} onClick={() => changeResource("quote")}>Cotización</button>}</nav>
    {resource === "ticket" ? <TicketBrandingSettings companyId={companyId} /> : resource === "quote" ? <QuoteBrandingSettings companyId={companyId} /> : resource === "prices" ? <PriceCatalogManagement companyId={companyId} locations={locations} onAssignLocation={openAssignment} onChanged={load} /> : <SettingsResource title={meta.title} description={meta.description} count={meta.count} action={meta.action} actionLabel={meta.actionLabel}><DataToolbar search={query} onSearchChange={setQuery} placeholder={`Buscar en ${meta.title.toLocaleLowerCase("es-MX")}`} filters={<Select ariaLabel="Filtrar registros" value={statusFilter} onValueChange={setStatusFilter} options={statusOptions} />} activeFilters={statusFilter === "all" ? 0 : 1} onClear={() => setStatusFilter("all")} results={resourceRows.length} /><DataState loading={false} error={loadError} hasData={resourceRows.length} empty={emptySettingsMessage(resource)} emptyAction={<Button size="sm" variant="primary" onClick={meta.action}>{meta.actionLabel}</Button>} errorAction={<Button size="sm" variant="secondary" onClick={() => void load()}>Reintentar</Button>}>
      {resource === "payments" && <SettingsTable><thead><tr><th>Forma de pago</th><th>Liquidación</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof payments).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small className="mono">{item.code}</small></td><td><Badge tone={item.settlement_kind === "cash_drawer" ? "success" : "neutral"}>{item.settlement_kind === "cash_drawer" ? "Afecta caja" : "Externo"}</Badge></td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openPayment(item)} onToggle={() => requestPaymentToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "registers" && <SettingsTable><thead><tr><th>Caja</th><th>Ubicación</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof registers).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small className="mono">{item.code} · {item.currency_code}</small></td><td>{locations.find((location) => location.id === item.location_id)?.name ?? "Ubicación no disponible"}</td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openRegister(item)} onToggle={() => requestRegisterToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "denominations" && <SettingsTable><thead><tr><th>Denominación</th><th className="number-cell">Valor</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof denominations).map((item) => <tr key={item.id}><td><strong>{item.display_name}</strong><small>{item.currency_code}</small></td><td className="number-cell">{money(item.value, item.currency_code)}</td><td><StatusBadge active={item.is_active} /></td><td><RowActions onEdit={() => openDenomination(item)} onToggle={() => requestDenominationToggle(item)} active={item.is_active} /></td></tr>)}</tbody></SettingsTable>}
      {resource === "discounts" && <SettingsTable><thead><tr><th>Rol</th><th>Alcance</th><th className="number-cell">Máximo</th><th>Vigencia</th><th>Estado</th><th aria-label="Acciones" /></tr></thead><tbody>{(visibleRows as typeof discountLimits).map((item) => <tr key={item.id}><td><strong>{roles.find((role) => role.id === item.role_id)?.display_name ?? "Rol no disponible"}</strong></td><td>{item.scope === "sale" ? "Venta completa" : "Línea"}</td><td className="number-cell">{item.max_percent}%</td><td><strong>{dateTime(item.valid_from)}</strong><small>{item.valid_to ? `Hasta ${dateTime(item.valid_to)}` : "Sin vencimiento"}</small></td><td><DiscountStatusBadge status={discountStatus(item)} /></td><td className="settings-row-actions">{permissions.includes("view_sales_audit") ? <Link className="settings-audit-link" href="/satrapy/configuracion/auditoria-comercial">Auditoría <ExternalLink size={13} /></Link> : <span className="settings-muted">Auditable</span>}</td></tr>)}</tbody></SettingsTable>}
      <SettingsPagination page={page} totalPages={totalPages} onChange={setPage} />
    </DataState></SettingsResource>}
  </div>
  <Drawer open={drawer === "payment"} onOpenChange={(open) => !open && closeDrawer()} title={paymentId ? "Editar forma de pago" : "Nueva forma de pago"}><SettingsDrawerIntro text="Alta manual pensada para pocos medios de pago. Cada cambio queda auditado." /><form className="sales-form" onSubmit={submitPayment}><label>Código<Input required value={paymentCode} onChange={(event) => setPaymentCode(event.target.value)} placeholder="EFECTIVO" /></label><label>Nombre<Input required value={paymentName} onChange={(event) => setPaymentName(event.target.value)} placeholder="Efectivo" /></label><Select ariaLabel="Liquidación" value={paymentKind} onValueChange={setPaymentKind} options={[{ value: "cash_drawer", label: "Afecta caja" }, { value: "external", label: "Externo (tarjeta, transferencia o terminal)" }]} /><label className="sales-checkbox"><input type="checkbox" checked={paymentActive} onChange={(event) => setPaymentActive(event.target.checked)} /> Activa para nuevas ventas</label><Button type="submit" variant="primary" loading={saving}>Guardar forma de pago</Button></form></Drawer>
  <Drawer open={drawer === "register"} onOpenChange={(open) => !open && closeDrawer()} title={registerEditId ? "Editar caja" : "Nueva caja"}><SettingsDrawerIntro text="Una caja representa un cajón físico por ubicación. Para volúmenes altos, configura desde una carga controlada." /><form className="sales-form" onSubmit={submitRegister}><Select ariaLabel="Ubicación de caja" value={registerLocationId} onValueChange={setRegisterLocationId} options={locationOptions} /><label>Código<Input required value={registerCode} onChange={(event) => setRegisterCode(event.target.value)} placeholder="CAJA-01" /></label><label>Nombre<Input required value={registerName} onChange={(event) => setRegisterName(event.target.value)} placeholder="Caja principal" /></label><label className="sales-checkbox"><input type="checkbox" checked={registerActive} onChange={(event) => setRegisterActive(event.target.checked)} /> Disponible para nuevas sesiones</label><Button type="submit" variant="primary" loading={saving}>Guardar caja</Button></form></Drawer>
  <Drawer open={drawer === "denomination"} onOpenChange={(open) => !open && closeDrawer()} title={denominationId ? "Editar denominación" : "Agregar denominación"}><SettingsDrawerIntro text="El catálogo se usa en conteos de caja. Las operaciones anteriores no se modifican." /><form className="sales-form" onSubmit={submitDenomination}><label>Valor<Input required inputMode="decimal" value={denominationValue} onChange={(event) => setDenominationValue(event.target.value)} placeholder="100" /></label><label>Nombre<Input required value={denominationName} onChange={(event) => setDenominationName(event.target.value)} placeholder="$100" /></label><label className="sales-checkbox"><input type="checkbox" checked={denominationActive} onChange={(event) => setDenominationActive(event.target.checked)} /> Disponible en nuevos conteos</label><Button type="submit" variant="primary" loading={saving}>Guardar denominación</Button></form></Drawer>
  <Drawer open={drawer === "assignment"} onOpenChange={(open) => !open && closeDrawer()} title="Asignar lista por ubicación"><SettingsDrawerIntro text="La asignación afecta precios disponibles para nuevas ventas en esa ubicación; no modifica ventas confirmadas." /><form className="sales-form" onSubmit={assignPriceList}><Select ariaLabel="Ubicación" value={locationPriceLocationId} onValueChange={setLocationPriceLocationId} options={locationOptions} /><Select ariaLabel="Lista de precios" value={locationPriceListId} onValueChange={setLocationPriceListId} options={priceLists.map((list) => ({ value: list.id, label: `${list.name} · ${list.currency_code}` }))} /><Button type="submit" variant="primary" loading={saving}>Guardar asignación</Button></form></Drawer>
  <Drawer open={drawer === "discount"} onOpenChange={(open) => !open && closeDrawer()} title="Nuevo límite de descuento"><SettingsDrawerIntro text="La nueva política conserva auditoría y cierra automáticamente la vigente del mismo rol y alcance; no se permiten traslapes." /><form className="sales-form" onSubmit={setDiscountPolicy}><Select ariaLabel="Rol" value={roleId} onValueChange={setRoleId} options={roles.map((role) => ({ value: role.id, label: role.display_name }))} /><Select ariaLabel="Alcance" value={discountScope} onValueChange={setDiscountScope} options={[{ value: "sale", label: "Venta completa" }, { value: "line", label: "Línea" }]} /><label>Máximo %<Input required inputMode="decimal" value={discountLimit} onChange={(event) => setDiscountLimit(event.target.value)} placeholder="10" /></label><label>Vigente desde (opcional)<Input type="datetime-local" value={discountValidFrom} onChange={(event) => setDiscountValidFrom(event.target.value)} /></label><label>Vence el (opcional)<Input type="datetime-local" value={discountValidTo} onChange={(event) => setDiscountValidTo(event.target.value)} /></label><Button type="submit" variant="primary" loading={saving}>Crear límite</Button></form></Drawer>
  <Modal open={Boolean(confirmation)} onOpenChange={(open) => !open && setConfirmation(null)} title={confirmation?.title ?? "Confirmar cambio"} description={confirmation?.description} footer={<><Button variant="secondary" onClick={() => setConfirmation(null)}>Cancelar</Button><Button variant={confirmation?.tone ?? "primary"} loading={saving} onClick={() => { const action = confirmation?.onConfirm; setConfirmation(null); if (action) void action(); }}>{confirmation?.confirmLabel ?? "Confirmar"}</Button></>}>{null}</Modal>
  </div>;
}

type SettingsResourceKey = "payments" | "registers" | "denominations" | "prices" | "discounts" | "ticket" | "quote";
type SettingsDrawer = "payment" | "register" | "denomination" | "assignment" | "discount";
type SettingsConfirmation = { title: string; description: string; confirmLabel: string; tone: "primary" | "danger"; onConfirm: () => Promise<void> };
const SETTINGS_PAGE_SIZE = 12;

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

function TicketPreview({ ticket }: { ticket: Record<string, unknown> | null | undefined }) { if (!ticket) return null; const sale = ticket.sale as { total_amount?: number; currency_code?: string; customer?: { display_name?: string } | null } | undefined; const payment = ticket.payment as { method_code?: string; received_amount?: number; change_amount?: number; reference?: string; type?: string } | undefined; const items = (ticket.items ?? []) as Array<{ product_name?: string; quantity?: number; total_amount?: number }>; const renderItem=(item:{product_name?:string;quantity?:number;total_amount?:number},key:number)=><p key={key}><span>{item.quantity} × {item.product_name}</span><b>{money(item.total_amount,sale?.currency_code)}</b></p>; return <div className="historical-ticket-preview"><div><strong>{String(ticket.folio ?? "")}</strong><span>{sale?.customer?.display_name ?? "Venta de mostrador"}</span><span>{ticket.issued_at ? dateTime(String(ticket.issued_at)) : ""}</span></div><div className="ticket-screen-items"><PagedCollection items={items} resetKey={String(ticket.folio ?? "")} label="partidas">{(visibleItems,startIndex)=><>{visibleItems.map((item,index)=>renderItem(item,startIndex+index))}</>}</PagedCollection></div><footer>Total <strong>{money(sale?.total_amount, sale?.currency_code)}</strong></footer>{payment?.method_code && <p className="historical-ticket-preview__payment"><span>Pago: {payment.method_code}</span><b>{payment.received_amount != null ? money(payment.received_amount, sale?.currency_code) : ""}</b></p>}{payment?.reference && <p className="historical-ticket-preview__payment"><span>Autorización</span><b>{payment.reference}</b></p>}{Number(payment?.change_amount ?? 0) > 0 && <p className="historical-ticket-preview__change"><span>Cambio</span><b>{money(payment?.change_amount, sale?.currency_code)}</b></p>}</div>; }

function PosEmpty({ title, description }: { title: string; description: string }) { return <section className="pos-empty"><AlertCircle size={24} /><h1>{title}</h1><p>{description}</p><div className="pos-empty__actions"><Link className="ui-button ui-button--primary ui-button--md" href="/satrapy/configuracion/ventas">Configurar ventas y caja</Link><Link className="pos-exit-link" href="/satrapy/configuracion">Volver a configuración</Link></div></section>; }
