"use client";

import { AlertTriangle, ChevronLeft, ChevronRight, ExternalLink, FilePlus2, FileText, Plus, RefreshCw, RotateCcw, Trash2, Upload } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, PagedCollection, Table } from "@/app/components/ui/data";
import { Badge, Button, Drawer, Field, Input, Modal, Select, Tabs, useToast } from "@/app/components/ui/primitives";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { getSupabaseClient } from "@/app/lib/supabase";

type InvoiceStatus = "draft" | "confirmed" | "reversed";
type InvoiceSource = "receipt" | "expense";
type InvoiceRow = {
  id: string; series: string | null; folio: string; fiscal_uuid: string | null; status: InvoiceStatus;
  source_kind?: InvoiceSource; issued_date: string; due_date: string; currency_code: string; exchange_rate?: number;
  total: number; differences: unknown[]; supplier_name: string; purchase_order_folio: string | null;
  payable_id: string | null; outstanding_amount: number | null;
};
type ReceiptCandidate = { id: string; receipt_folio: string; receipt_date: string; purchase_order_id: string; purchase_order_folio: string; currency_code: string; supplier_id: string; supplier_name: string };
type SupplierOption = { id: string; code: string; display_name: string; tax_id: string | null };
type InvoiceableLine = { purchase_receipt_line_id: string; purchase_receipt_id: string; purchase_receipt_folio: string; line_number: number; description: string; ordered_quantity: number; received_quantity: number; previously_invoiced: number; available_quantity: number; order_unit_cost: number; received_unit_cost: number };
type Candidate = { purchase_order_id: string; folio: string; supplier_id: string; currency_code: string; lines: InvoiceableLine[] };
type InvoiceDocument = { id: string; document_role: "cfdi_xml" | "representation_pdf"; original_file_name: string; validation_status: "not_applicable" | "verified_local" | "mismatch" | "unreadable"; validation_issues: Array<{ field?: string }>; sat_status: "not_checked" | "valid" | "cancelled" | "not_found"; created_at: string; download_path: string };
type ExpenseTax = { id: string; kind: "transferred" | "withheld"; taxCode: string; factorType: string; rate: string; base: string; amount: string };
type ExpenseLine = {
  id: string; productServiceCode: string; identificationNumber: string; quantity: string; unitCode: string; unitName: string;
  description: string; unitValue: string; subtotal: string; discount: string; taxObjectCode: string; taxDetails: ExpenseTax[];
  expenseCategory: string; costCenterReference: string; projectReference: string;
};
type CfdiConcept = {
  product_service_code: string; identification_number: string | null; quantity: string; unit_code: string; unit_name: string | null;
  description: string; unit_value: string; subtotal: string; discount_amount: string; tax_object_code: string;
  transferred_tax_amount: string; withheld_tax_amount: string; tax_details: Array<{ kind: "transferred" | "withheld"; tax_code: string; factor_type: string; rate: string; base: string; amount: string }>;
};
type CfdiData = {
  version: string | null; series: string | null; folio: string | null; issued_at: string | null; currency: string | null;
  subtotal: string | null; discount_total: string; transferred_tax_total: string; withheld_tax_total: string; total: string | null;
  document_type: string | null; payment_method_code: string | null; payment_form_code: string | null; issuer_rfc: string | null;
  issuer_name: string | null; issuer_regime_code: string | null; receiver_rfc: string | null; receiver_name: string | null;
  receiver_regime_code: string | null; receiver_postal_code: string | null; cfdi_use_code: string | null; export_code: string | null;
  uuid: string | null; concepts: CfdiConcept[];
};
type Detail = InvoiceRow & {
  source_kind: InvoiceSource; exchange_rate: number; base_currency_code: string; base_total: number;
  payment_method_code: string | null; payment_form_code: string | null; expense_approved_at: string | null;
  supplier: { code: string; display_name: string; tax_id: string | null; country_code: string };
  purchase_order: { id: string; folio: string; status: string } | null;
  receipts: Array<{ id: string; folio: string; status: string; receipt_date: string }>;
  lines: Array<InvoiceableLine & { id: string; quantity: number; invoiced_unit_price: number; invoice_discount_amount: number; invoice_tax_amount: number; differences: unknown[] }>;
  expense_lines: Array<{ id: string; line_number: number; product_service_code: string | null; quantity: number; unit_code: string | null; unit_name: string | null; description: string; unit_value: number; subtotal: number; discount_amount: number; tax_amount: number; withheld_tax_amount: number; tax_object_code: string | null; expense_category: string | null; cost_center_reference: string | null; project_reference: string | null; total: number }>;
  documents: InvoiceDocument[];
  payable: { id: string; original_amount: number; outstanding_amount: number; condition: string; adjustments: Array<{ id: string; adjustment_type: string; amount: number; reason: string | null; occurred_at: string }> } | null;
  audit: Array<{ id: string; action: string; created_at: string; metadata: Record<string, unknown> }>;
  differences_authorized_at: string | null; differences_authorization_reason: string | null; reversal_reason: string | null;
};
type ExceptionRow = { id: string; kind: string; status: string; supplier_name: string; invoice_folio: string | null; detected_at: string; evidence: Record<string, unknown> };
type AgingRow = { currency_code: string; document_count: number; total: number; not_due: number | null; days_1_30: number | null; days_31_60: number | null; days_61_90: number | null; days_over_90: number | null };
type DueBucket = "overdue" | "upcoming" | "future";
type DuePayableRow = {
  id: string; supplier_id: string; supplier_code: string; supplier_name: string; supplier_invoice_id: string;
  invoice_number: string; currency_code: string; original_amount: number; outstanding_amount: number;
  issued_date: string; due_date: string; due_bucket: DueBucket;
};
type HistoricalPayableRow = {
  id: string; folio: string; supplier_external_code: string; supplier_name: string;
  issued_date: string; due_date: string; outstanding_amount: number; currency_code: string;
  condition_at_snapshot: "overdue" | "not_due";
};
type HistoricalPayableTotal = { currency_code: string; document_count: number; outstanding_amount: number };
type ProposalStatus = "draft" | "submitted" | "approved" | "rejected" | "cancelled";
type ProposalRow = {
  id: string; supplier_id: string; supplier_code: string; supplier_name: string; currency_code: string;
  status: ProposalStatus; total_proposed: number; line_count: number; created_at: string; updated_at: string;
};
type ProposalLine = {
  id: string; accounts_payable_id: string; supplier_invoice_id: string; invoice_number: string; issued_date: string;
  due_date: string; proposed_amount: number; balance_snapshot: number; projected_balance_snapshot: number;
  current_balance: number; projected_balance: number; payable_reversed_at: string | null;
};
type ProposalDetail = ProposalRow & {
  supplier: { id: string; code: string; display_name: string }; lines: ProposalLine[];
  submitted_at: string | null; approved_at: string | null; rejected_at: string | null; cancelled_at: string | null;
  rejection_reason: string | null; cancellation_reason: string | null;
  audit: Array<{ id: string; action: string; created_at: string; metadata: Record<string, unknown> }>;
};
type PaymentCalendarView = "week" | "month" | "table";
type PaymentCalendarState = "overdue" | "due_today" | "upcoming" | "future" | "scheduled";
type PaymentCalendarRow = {
  id: string; supplier_id: string; supplier_code: string; supplier_name: string; supplier_invoice_id: string;
  invoice_number: string; currency_code: string; original_amount: number; outstanding_amount: number;
  issued_date: string; due_date: string; state: PaymentCalendarState;
  proposal_id: string | null; proposal_status: ProposalStatus | null; payment_id: string | null; payment_reference: string | null;
};
type PaymentCalendarTotal = { due_date: string; currency_code: string; document_count: number; outstanding_amount: number };
type PayingAccount = { id: string; bank_name: string; alias: string; currency_code: string; account_last4: string; masked_ending: string; is_active: boolean; updated_at: string };
type RepStatus = "not_required" | "pending" | "received" | "differences";
type PaymentDocument = { id: string; document_role: "bank_receipt" | "rep_xml"; original_file_name: string; mime_type: string; size_bytes: number; sha256: string; fiscal_uuid: string | null; local_validation_status: "not_applicable" | "verified_local" | "mismatch" | "unreadable"; local_validation_issues: Array<{ field?: string; expected?: unknown; actual?: unknown; invoice_uuid?: string }>; created_at: string; download_path: string; sat_verification: { id: string; sat_status: "valid" | "cancelled" | "not_found"; checked_at: string; evidence: Record<string, unknown> } | null };
type RepData = { cfdi_version: string | null; complement_version: string | null; document_type: string | null; currency: string | null; total: string | null; issued_at: string | null; uuid: string | null; issuer_rfc: string | null; receiver_rfc: string | null; payment: { date: string | null; payment_form: string | null; currency: string | null; exchange_rate: string | null; amount: string | null }; related_documents: Array<{ document_uuid: string | null; currency: string | null; equivalence: string | null; partiality: string | null; previous_balance: string | null; paid_amount: string | null; remaining_balance: string | null }> };
type SupplierPaymentRow = { id: string; proposal_id: string; supplier_id: string; supplier_code: string; supplier_name: string; currency_code: string; effective_date: string; payment_method: string; payment_form_code: string | null; reference: string; total_amount: number; status: "confirmed" | "reversed"; rep_status: RepStatus; reconciliation_status: "unreconciled"; confirmed_at: string; reversed_at: string | null; account_alias: string; bank_name: string; masked_ending: string; application_count: number };
type SupplierPaymentDetail = SupplierPaymentRow & { reversal_reason: string | null; paying_account: PayingAccount; supplier: { id: string; code: string; display_name: string; tax_id: string | null }; applications: Array<{ id: string; accounts_payable_id: string; invoice_number: string; invoice_uuid: string | null; payment_method_code: string | null; due_date: string; amount: number; balance_before: number; balance_after: number; current_balance: number }>; documents: PaymentDocument[]; audit: Array<{ id: string; action: string; created_at: string; metadata: Record<string, unknown> }> };
type Draft = {
  sourceKind: InvoiceSource; receiptId: string; supplierId: string; series: string; folio: string; fiscalUuid: string;
  issuedDate: string; dueDate: string; currencyCode: string; exchangeRate: string; reference: string;
  paymentMethodCode: string; paymentFormCode: string; quantities: Record<string, string>; prices: Record<string, string>;
  discounts: Record<string, string>; taxes: Record<string, string>; expenseLines: ExpenseLine[];
};
type Action = { kind: "authorize" | "approve_expense" | "reverse" | "credit" | "sat"; reason: string; amount: string; series: string; folio: string; satStatus: "valid" | "cancelled" | "not_found" };

const PAGE_SIZE = 25;
const OTHER_CURRENCY = "__other_currency__";
const COMMON_CURRENCIES = [
  { value: "MXN", label: "MXN · Peso mexicano" },
  { value: "USD", label: "USD · Dólar estadounidense" },
  { value: "EUR", label: "EUR · Euro" },
];
const PAYMENT_METHODS = [
  { value: "PUE", label: "PUE · Pago en una sola exhibición" },
  { value: "PPD", label: "PPD · Pago en parcialidades o diferido" },
];
const PAYMENT_FORMS = [
  { value: "01", label: "01 · Efectivo" },
  { value: "02", label: "02 · Cheque nominativo" },
  { value: "03", label: "03 · Transferencia electrónica de fondos" },
  { value: "04", label: "04 · Tarjeta de crédito" },
  { value: "05", label: "05 · Monedero electrónico" },
  { value: "06", label: "06 · Dinero electrónico" },
  { value: "08", label: "08 · Vales de despensa" },
  { value: "12", label: "12 · Dación en pago" },
  { value: "13", label: "13 · Pago por subrogación" },
  { value: "14", label: "14 · Pago por consignación" },
  { value: "15", label: "15 · Condonación" },
  { value: "17", label: "17 · Compensación" },
  { value: "23", label: "23 · Novación" },
  { value: "24", label: "24 · Confusión" },
  { value: "25", label: "25 · Remisión de deuda" },
  { value: "26", label: "26 · Prescripción o caducidad" },
  { value: "27", label: "27 · A satisfacción del acreedor" },
  { value: "28", label: "28 · Tarjeta de débito" },
  { value: "29", label: "29 · Tarjeta de servicios" },
  { value: "30", label: "30 · Aplicación de anticipos" },
  { value: "31", label: "31 · Intermediario de pagos" },
  { value: "99", label: "99 · Por definir" },
];
const TAX_OBJECTS = [
  { value: "01", label: "01 · No objeto de impuesto" },
  { value: "02", label: "02 · Sí objeto de impuesto" },
  { value: "03", label: "03 · Sí objeto, sin desglose" },
  { value: "04", label: "04 · Sí objeto y no causa impuesto" },
  { value: "05", label: "05 · IVA crédito PODEBI" },
  { value: "06", label: "06 · Sí objeto IVA, sin traslado" },
  { value: "07", label: "07 · Sin IVA, con desglose IEPS" },
  { value: "08", label: "08 · Sin IVA ni desglose IEPS" },
];
const TAX_CODES = [{ value: "001", label: "001 · ISR" }, { value: "002", label: "002 · IVA" }, { value: "003", label: "003 · IEPS" }];
const TAX_FACTORS = [{ value: "Tasa", label: "Tasa" }, { value: "Cuota", label: "Cuota" }, { value: "Exento", label: "Exento" }];
const today = () => new Date().toISOString().slice(0, 10);
const addDays = (value: string, days: number) => { const result = new Date(`${value}T00:00:00Z`); result.setUTCDate(result.getUTCDate() + days); return result.toISOString().slice(0, 10); };
const startOfWeek = (value: string) => { const result = new Date(`${value}T00:00:00Z`); const weekday = result.getUTCDay() || 7; result.setUTCDate(result.getUTCDate() - weekday + 1); return result.toISOString().slice(0, 10); };
const startOfMonthGrid = (value: string) => startOfWeek(`${value.slice(0, 7)}-01`);
const money = (value: number | null | undefined, currency: string) => new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(value ?? 0));
const date = (value: string) => new Date(`${value}T00:00:00`).toLocaleDateString("es-MX");
const blankExpenseLine = (): ExpenseLine => ({ id: crypto.randomUUID(), productServiceCode: "", identificationNumber: "", quantity: "1", unitCode: "", unitName: "", description: "", unitValue: "", subtotal: "", discount: "0", taxObjectCode: "02", taxDetails: [], expenseCategory: "", costCenterReference: "", projectReference: "" });
const blankExpenseTax = (): ExpenseTax => ({ id: crypto.randomUUID(), kind: "transferred", taxCode: "002", factorType: "Tasa", rate: "0.160000", base: "", amount: "" });

export function SupplierInvoicesView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const keys = useRef(new OperationIdempotencyKeys());
  const fileInput = useRef<HTMLInputElement>(null);
  const draftXmlInput = useRef<HTMLInputElement>(null);
  const [tab, setTab] = useState("invoices");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<InvoiceRow[]>([]);
  const [exceptions, setExceptions] = useState<ExceptionRow[]>([]);
  const [exceptionTotal, setExceptionTotal] = useState(0);
  const [exceptionPage, setExceptionPage] = useState(1);
  const [showExceptions, setShowExceptions] = useState(false);
  const [aging, setAging] = useState<AgingRow[]>([]);
  const [duePayables, setDuePayables] = useState<DuePayableRow[]>([]);
  const [historicalPayables, setHistoricalPayables] = useState<HistoricalPayableRow[]>([]);
  const [historicalTotals, setHistoricalTotals] = useState<HistoricalPayableTotal[]>([]);
  const [historicalSnapshotDate, setHistoricalSnapshotDate] = useState<string | null>(null);
  const [proposals, setProposals] = useState<ProposalRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [receipts, setReceipts] = useState<ReceiptCandidate[]>([]);
  const [suppliers, setSuppliers] = useState<SupplierOption[]>([]);
  const [receiptQuery, setReceiptQuery] = useState("");
  const [receiptTotal, setReceiptTotal] = useState(0);
  const [receiptSearching, setReceiptSearching] = useState(false);
  const [receiptPickerOpen, setReceiptPickerOpen] = useState(false);
  const [draftSupplierQuery, setDraftSupplierQuery] = useState("");
  const [draftSupplierTotal, setDraftSupplierTotal] = useState(0);
  const [draftSupplierSearching, setDraftSupplierSearching] = useState(false);
  const [draftSupplierPickerOpen, setDraftSupplierPickerOpen] = useState(false);
  const [filterSuppliers, setFilterSuppliers] = useState<SupplierOption[]>([]);
  const [filterSupplierQuery, setFilterSupplierQuery] = useState("");
  const [filterSupplierTotal, setFilterSupplierTotal] = useState(0);
  const [filterSupplierSearching, setFilterSupplierSearching] = useState(false);
  const [filterSupplierPickerOpen, setFilterSupplierPickerOpen] = useState(false);
  const [candidate, setCandidate] = useState<Candidate | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [draftXml, setDraftXml] = useState<{ file: File; sha256: string; extracted: CfdiData } | null>(null);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [busy, setBusy] = useState(false);
  const [action, setAction] = useState<Action | null>(null);
  const [dueBucket, setDueBucket] = useState<"all" | DueBucket>("overdue");
  const [dueSupplier, setDueSupplier] = useState("");
  const [dueCurrency, setDueCurrency] = useState("");
  const [dueFrom, setDueFrom] = useState("");
  const [dueTo, setDueTo] = useState("");
  const [minBalance, setMinBalance] = useState("");
  const [maxBalance, setMaxBalance] = useState("");
  const [selectedPayables, setSelectedPayables] = useState<Record<string, DuePayableRow>>({});
  const [proposedAmounts, setProposedAmounts] = useState<Record<string, string>>({});
  const [proposalDraftId, setProposalDraftId] = useState<string | null>(null);
  const [proposalExpectedUpdatedAt, setProposalExpectedUpdatedAt] = useState<string | null>(null);
  const [proposalBuilderOpen, setProposalBuilderOpen] = useState(false);
  const [proposalDetail, setProposalDetail] = useState<ProposalDetail | null>(null);
  const [proposalAction, setProposalAction] = useState<{ kind: "submit" | "approve" | "reject" | "cancel"; reason: string } | null>(null);
  const [calendarView, setCalendarView] = useState<PaymentCalendarView>("month");
  const [calendarAnchor, setCalendarAnchor] = useState(today());
  const [calendarRows, setCalendarRows] = useState<PaymentCalendarRow[]>([]);
  const [calendarTotals, setCalendarTotals] = useState<PaymentCalendarTotal[]>([]);
  const [calendarPaymentId, setCalendarPaymentId] = useState<string | null>(null);
  const [paymentsSection, setPaymentsSection] = useState<"proposals" | "agenda" | "confirmed">(
    permissions.includes("prepare_supplier_payment_proposals") || permissions.includes("approve_supplier_payment_proposals") ? "proposals" : "confirmed",
  );
  const [payablesSection, setPayablesSection] = useState<"current" | "history">("current");
  const draftOpen = draft !== null;
  const draftSourceKind = draft?.sourceKind ?? null;
  const supplierFilterRelevant = tab === "payables" && payablesSection === "current"
    || tab === "payments" && (paymentsSection === "proposals" || paymentsSection === "agenda");

  const canDraft = permissions.includes("manage_supplier_invoice_drafts");
  const canExpense = permissions.includes("manage_supplier_expense_invoices");
  const canDocuments = permissions.includes("manage_supplier_invoice_documents");
  const canVerifySat = permissions.includes("verify_supplier_invoice_cfdi");
  const canConfirm = permissions.includes("confirm_supplier_invoices");
  const canAuthorize = permissions.includes("authorize_supplier_invoice_differences");
  const canReverse = permissions.includes("reverse_supplier_invoices");
  const canCredit = permissions.includes("manage_supplier_credit_notes");
  const canCost = permissions.includes("view_costs");
  const canPrepareProposals = permissions.includes("prepare_supplier_payment_proposals");
  const canApproveProposals = permissions.includes("approve_supplier_payment_proposals");
  const canViewPayments = permissions.includes("view_supplier_payments");

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    if (tab === "invoices") {
      const [invoiceResult, exceptionResult] = await Promise.all([
        getSupabaseClient().rpc("search_supplier_invoices", { p_company_id: companyId, p_query: query || null, p_status: status === "all" ? null : status, p_supplier_id: null, p_purchase_order_id: null, p_receipt_id: null, p_date_from: null, p_date_to: null, p_page: page, p_page_size: PAGE_SIZE }),
        getSupabaseClient().rpc("list_supplier_invoice_exceptions", { p_company_id: companyId, p_status: null, p_page: exceptionPage, p_page_size: PAGE_SIZE }),
      ]);
      const result = invoiceResult.data as { items?: InvoiceRow[]; pagination?: { total: number } } | null;
      const exceptionData = exceptionResult.data as { items?: ExceptionRow[]; pagination?: { total: number } } | null;
      if (!invoiceResult.error && !exceptionResult.error) {
        setRows(result?.items ?? []); setTotal(result?.pagination?.total ?? 0);
        setExceptions(exceptionData?.items ?? []); setExceptionTotal(exceptionData?.pagination?.total ?? 0);
      }
      setError(invoiceResult.error || exceptionResult.error ? "No se pudieron cargar las facturas y sus excepciones." : null);
    } else if (tab === "payables" && payablesSection === "current") {
      const [agingResult, dueResult] = await Promise.all([
        getSupabaseClient().rpc("get_accounts_payable_aging", { p_company_id: companyId, p_as_of_date: today() }),
        getSupabaseClient().rpc("search_supplier_payable_due_inbox", {
          p_company_id: companyId, p_query: query || null, p_supplier_id: dueSupplier || null,
          p_currency_code: dueCurrency || null, p_due_bucket: dueBucket === "all" ? null : dueBucket,
          p_due_from: dueFrom || null, p_due_to: dueTo || null,
          p_min_balance: minBalance === "" ? null : Number(minBalance), p_max_balance: maxBalance === "" ? null : Number(maxBalance),
          p_page: page, p_page_size: PAGE_SIZE,
        }),
      ]);
      const agingData = agingResult.data as { items?: AgingRow[] } | null;
      const dueData = dueResult.data as { items?: DuePayableRow[]; pagination?: { total: number } } | null;
      if (!agingResult.error && !dueResult.error) { setAging(agingData?.items ?? []); setDuePayables(dueData?.items ?? []); setTotal(dueData?.pagination?.total ?? 0); }
      setError(agingResult.error || dueResult.error ? "No se pudieron cargar las cuentas por pagar." : null);
    } else if (tab === "payables") {
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_historical_accounts_payable", {
        p_company_id: companyId, p_query: query || null, p_page: page, p_page_size: PAGE_SIZE,
      });
      const result = data as { items?: HistoricalPayableRow[]; totals?: HistoricalPayableTotal[]; snapshot_date?: string | null; pagination?: { total: number } } | null;
      if (!rpcError) {
        setHistoricalPayables(result?.items ?? []); setHistoricalTotals(result?.totals ?? []);
        setHistoricalSnapshotDate(result?.snapshot_date ?? null); setTotal(result?.pagination?.total ?? 0);
      }
      setError(rpcError ? "No se pudo cargar el historial de cuentas por pagar." : null);
    } else if (tab === "payments" && paymentsSection === "agenda") {
      const rangeStart = calendarView === "week" ? startOfWeek(calendarAnchor) : calendarView === "month" ? startOfMonthGrid(calendarAnchor) : dueFrom || addDays(today(), -30);
      const rangeEnd = calendarView === "week" ? addDays(rangeStart, 6) : calendarView === "month" ? addDays(rangeStart, 41) : dueTo || addDays(today(), 60);
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_supplier_payment_calendar", {
        p_company_id: companyId, p_query: query || null, p_supplier_id: dueSupplier || null, p_currency_code: dueCurrency || null,
        p_due_from: rangeStart, p_due_to: rangeEnd, p_page: page, p_page_size: calendarView === "table" ? PAGE_SIZE : 100,
      });
      const result = data as { items?: PaymentCalendarRow[]; totals?: PaymentCalendarTotal[]; pagination?: { total: number } } | null;
      if (!rpcError) { setCalendarRows(result?.items ?? []); setCalendarTotals(result?.totals ?? []); setTotal(result?.pagination?.total ?? 0); }
      setError(rpcError ? "No se pudo cargar la agenda de pagos." : null);
    } else if (tab === "payments" && paymentsSection === "proposals") {
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_supplier_payment_proposals", {
        p_company_id: companyId, p_status: status === "all" ? null : status, p_supplier_id: dueSupplier || null,
        p_currency_code: dueCurrency || null, p_page: page, p_page_size: PAGE_SIZE,
      });
      const result = data as { items?: ProposalRow[]; pagination?: { total: number } } | null;
      if (!rpcError) { setProposals(result?.items ?? []); setTotal(result?.pagination?.total ?? 0); }
      setError(rpcError ? "No se pudieron cargar las propuestas de pago." : null);
    } else if (tab === "payments") {
      setTotal(0);
    }
    setLoading(false);
  }, [calendarAnchor, calendarView, companyId, dueBucket, dueCurrency, dueFrom, dueSupplier, dueTo, exceptionPage, maxBalance, minBalance, page, payablesSection, paymentsSection, query, status, tab]);

  useEffect(() => { const timer = setTimeout(() => void load(), 180); return () => clearTimeout(timer); }, [load]);

  useEffect(() => {
    if (!draftOpen || draftSourceKind !== "receipt") return;
    const timer = window.setTimeout(async () => {
      setReceiptSearching(true);
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_invoiceable_receipts", {
        p_company_id: companyId, p_query: receiptQuery.trim() || null, p_supplier_id: null,
        p_purchase_order_id: null, p_page: 1, p_page_size: 30,
      });
      const result = data as { items?: ReceiptCandidate[]; pagination?: { total: number } } | null;
      if (!rpcError) { setReceipts(result?.items ?? []); setReceiptTotal(result?.pagination?.total ?? 0); }
      setReceiptSearching(false);
    }, 200);
    return () => window.clearTimeout(timer);
  }, [companyId, draftOpen, draftSourceKind, receiptQuery]);

  useEffect(() => {
    if (!draftOpen || draftSourceKind !== "expense") return;
    const timer = window.setTimeout(async () => {
      setDraftSupplierSearching(true);
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_supplier_options", {
        p_company_id: companyId, p_query: draftSupplierQuery.trim() || null, p_limit: 30,
      });
      const result = data as { items?: SupplierOption[] } | null;
      if (!rpcError) { const items = result?.items ?? []; setSuppliers(items); setDraftSupplierTotal(items.length); }
      setDraftSupplierSearching(false);
    }, 200);
    return () => window.clearTimeout(timer);
  }, [companyId, draftOpen, draftSourceKind, draftSupplierQuery]);

  useEffect(() => {
    if (!supplierFilterRelevant) return;
    const timer = window.setTimeout(async () => {
      setFilterSupplierSearching(true);
      const { data, error: rpcError } = await getSupabaseClient().rpc("search_supplier_options", {
        p_company_id: companyId, p_query: filterSupplierQuery.trim() || null, p_limit: 30,
      });
      const result = data as { items?: SupplierOption[] } | null;
      if (!rpcError) { const items = result?.items ?? []; setFilterSuppliers(items); setFilterSupplierTotal(items.length); }
      setFilterSupplierSearching(false);
    }, 200);
    return () => window.clearTimeout(timer);
  }, [companyId, filterSupplierQuery, supplierFilterRelevant]);

  function changeTab(value: string) { setTab(value); setStatus("all"); setQuery(""); setPage(1); }

  function openNew() {
    setCandidate(null);
    setDraftXml(null);
    setReceipts([]); setReceiptQuery(""); setReceiptTotal(0); setReceiptPickerOpen(false);
    setSuppliers([]); setDraftSupplierQuery(""); setDraftSupplierTotal(0); setDraftSupplierPickerOpen(false);
    setDraft({ sourceKind: "receipt", receiptId: "", supplierId: "", series: "", folio: "", fiscalUuid: "", issuedDate: today(), dueDate: today(), currencyCode: "MXN", exchangeRate: "1", reference: "", paymentMethodCode: "PPD", paymentFormCode: "99", quantities: {}, prices: {}, discounts: {}, taxes: {}, expenseLines: [blankExpenseLine()] });
  }

  async function chooseReceipt(receiptId: string) {
    if (!draft) return;
    setDraft({ ...draft, receiptId, quantities: {}, prices: {}, discounts: {}, taxes: {} });
    const receipt = receipts.find(item => item.id === receiptId);
    if (!receipt) { setCandidate(null); return; }
    const { data, error: rpcError } = await getSupabaseClient().rpc("get_invoiceable_purchase_order", { p_company_id: companyId, p_purchase_order_id: receipt.purchase_order_id });
    if (rpcError) { toast({ title: "No se abrió la conciliación", description: rpcError.message, tone: "error" }); return; }
    const next = data as Candidate;
    setCandidate(next);
    setDraft(current => current ? { ...current, receiptId, supplierId: next.supplier_id, currencyCode: next.currency_code, exchangeRate: "1", prices: Object.fromEntries(next.lines.map(line => [line.purchase_receipt_line_id, String(line.received_unit_cost)])) } : current);
  }

  async function readDraftXml(file: File) {
    if (!draft || !file.name.toLowerCase().endsWith(".xml") || file.size > 10 * 1024 * 1024) { toast({ title: "XML no permitido", description: "Adjunta un XML CFDI de hasta 10 MB.", tone: "error" }); return; }
    try {
      const bytes = await file.arrayBuffer();
      const extracted = parseCfdi(new TextDecoder().decode(bytes));
      if (extracted.version !== "4.0" || extracted.document_type !== "I") throw new Error("El archivo debe ser un CFDI 4.0 de ingreso.");
      const sha256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(value => value.toString(16).padStart(2, "0")).join("");
      let supplier = suppliers.find(item => item.tax_id && item.tax_id.toUpperCase() === extracted.issuer_rfc?.toUpperCase());
      if (!supplier && extracted.issuer_rfc) {
        const { data } = await getSupabaseClient().rpc("search_supplier_options", {
          p_company_id: companyId, p_query: extracted.issuer_rfc, p_limit: 10,
        });
        supplier = ((data as { items?: SupplierOption[] } | null)?.items ?? []).find(
          item => item.tax_id?.toUpperCase() === extracted.issuer_rfc?.toUpperCase(),
        );
        if (supplier) setSuppliers(current => current.some(item => item.id === supplier?.id) ? current : [supplier!, ...current]);
      }
      const issuedDate = extracted.issued_at?.slice(0, 10) ?? draft.issuedDate;
      const expenseLines = extracted.concepts.map(concept => ({
        id: crypto.randomUUID(), productServiceCode: concept.product_service_code, identificationNumber: concept.identification_number ?? "",
        quantity: concept.quantity, unitCode: concept.unit_code, unitName: concept.unit_name ?? "", description: concept.description,
        unitValue: concept.unit_value, subtotal: concept.subtotal, discount: concept.discount_amount, taxObjectCode: concept.tax_object_code,
        taxDetails: concept.tax_details.map(tax => ({ id: crypto.randomUUID(), kind: tax.kind, taxCode: tax.tax_code, factorType: tax.factor_type, rate: tax.rate, base: tax.base, amount: tax.amount })),
        expenseCategory: "", costCenterReference: "", projectReference: "",
      }));
      setDraft(current => current ? { ...current, supplierId: supplier?.id ?? current.supplierId, series: extracted.series ?? "", folio: extracted.folio ?? "", fiscalUuid: extracted.uuid ?? "", issuedDate, dueDate: current.dueDate < issuedDate ? issuedDate : current.dueDate, currencyCode: extracted.currency ?? current.currencyCode, paymentMethodCode: extracted.payment_method_code ?? current.paymentMethodCode, paymentFormCode: extracted.payment_form_code ?? current.paymentFormCode, expenseLines: expenseLines.length ? expenseLines : current.expenseLines } : current);
      if (supplier) setDraftSupplierQuery(`${supplier.code} · ${supplier.display_name}`);
      setDraftXml({ file, sha256, extracted });
      toast({ title: "XML leído", description: `${expenseLines.length} concepto${expenseLines.length === 1 ? "" : "s"} autollenado${expenseLines.length === 1 ? "" : "s"}${supplier ? " y proveedor identificado" : "; selecciona el proveedor"}.`, tone: supplier ? "success" : "info" });
    } catch (cause) { setDraftXml(null); toast({ title: "No se pudo leer el XML", description: cause instanceof Error ? cause.message : "Archivo CFDI inválido.", tone: "error" }); }
    finally { if (draftXmlInput.current) draftXmlInput.current.value = ""; }
  }

  async function uploadDraftXml(invoiceId: string, payload: { file: File; sha256: string; extracted: CfdiData }) {
    const safeName = payload.file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
    const path = `${companyId}/${invoiceId}/${crypto.randomUUID()}-${safeName}`;
    const client = getSupabaseClient();
    const { error: uploadError } = await client.storage.from("supplier-invoice-documents").upload(path, payload.file, { contentType: payload.file.type || "application/xml", upsert: false });
    if (uploadError) throw uploadError;
    const { data, error: rpcError } = await client.rpc("register_supplier_invoice_document", { p_company_id: companyId, p_invoice_id: invoiceId, p_document_role: "cfdi_xml", p_original_file_name: payload.file.name, p_storage_path: path, p_mime_type: payload.file.type || "application/xml", p_size_bytes: payload.file.size, p_sha256: payload.sha256, p_extracted_data: payload.extracted });
    if (rpcError) { await client.storage.from("supplier-invoice-documents").remove([path]); throw rpcError; }
    return data as { status: string; issues?: unknown[] };
  }

  function updateExpenseLine(lineId: string, patch: Partial<ExpenseLine>) {
    setDraft(current => current ? { ...current, expenseLines: current.expenseLines.map(line => line.id === lineId ? { ...line, ...patch } : line) } : current);
  }

  function updateExpenseTax(lineId: string, taxId: string, patch: Partial<ExpenseTax>) {
    setDraft(current => current ? { ...current, expenseLines: current.expenseLines.map(line => line.id === lineId ? { ...line, taxDetails: line.taxDetails.map(tax => tax.id === taxId ? { ...tax, ...patch } : tax) } : line) } : current);
  }

  async function saveDraft() {
    if (!draft || !draft.folio.trim()) return;
    if (!/^[A-Z]{3}$/.test(draft.currencyCode) || !Number.isFinite(Number(draft.exchangeRate)) || Number(draft.exchangeRate) <= 0) {
      toast({ title: "Revisa moneda y tipo de cambio", description: "Usa un código de moneda de tres letras y un tipo de cambio mayor a cero.", tone: "info" }); return;
    }
    setBusy(true);
    let data: unknown = null; let rpcError: { message: string } | null = null;
    if (draft.sourceKind === "receipt") {
      if (!candidate) { setBusy(false); return; }
      const lines = candidate.lines.filter(line => Number(draft.quantities[line.purchase_receipt_line_id] ?? 0) > 0).map(line => ({ purchase_receipt_line_id: line.purchase_receipt_line_id, quantity: Number(draft.quantities[line.purchase_receipt_line_id]), unit_price: Number(draft.prices[line.purchase_receipt_line_id] ?? line.received_unit_cost), discount_amount: Number(draft.discounts[line.purchase_receipt_line_id] ?? 0), tax_amount: Number(draft.taxes[line.purchase_receipt_line_id] ?? 0) }));
      if (!lines.length) { setBusy(false); toast({ title: "Selecciona cantidades", description: "Incluye al menos una cantidad recibida pendiente.", tone: "info" }); return; }
      const fingerprint = JSON.stringify({ candidate: candidate.purchase_order_id, folio: draft.folio, lines });
      ({ data, error: rpcError } = await getSupabaseClient().rpc("save_supplier_invoice_v2", { p_company_id: companyId, p_invoice_id: null, p_supplier_id: candidate.supplier_id, p_purchase_order_id: candidate.purchase_order_id, p_series: draft.series || null, p_folio: draft.folio, p_fiscal_uuid: draft.fiscalUuid || null, p_issued_date: draft.issuedDate, p_due_date: draft.dueDate, p_currency_code: draft.currencyCode.toUpperCase(), p_exchange_rate: Number(draft.exchangeRate), p_supplier_reference: draft.reference || null, p_payment_method_code: draft.paymentMethodCode || null, p_payment_form_code: draft.paymentFormCode || null, p_lines: lines, p_client_request_id: keys.current.get("supplier-invoice-save", fingerprint), p_expected_updated_at: null }));
    } else {
      const lines = draft.expenseLines.filter(line => line.description.trim() || line.productServiceCode.trim()).map(line => ({
        product_service_code: line.productServiceCode, identification_number: line.identificationNumber || null, quantity: Number(line.quantity),
        unit_code: line.unitCode, unit_name: line.unitName || null, description: line.description.trim(), unit_value: Number(line.unitValue),
        subtotal: Number(line.subtotal || Number(line.quantity) * Number(line.unitValue)), discount_amount: Number(line.discount || 0),
        transferred_tax_amount: line.taxDetails.filter(tax => tax.kind === "transferred").reduce((sum, tax) => sum + Number(tax.amount || 0), 0),
        withheld_tax_amount: line.taxDetails.filter(tax => tax.kind === "withheld").reduce((sum, tax) => sum + Number(tax.amount || 0), 0),
        tax_object_code: line.taxObjectCode,
        tax_details: line.taxDetails.map(tax => ({ kind: tax.kind, tax_code: tax.taxCode, factor_type: tax.factorType, rate: tax.factorType === "Exento" ? "0" : tax.rate, base: tax.base, amount: tax.factorType === "Exento" ? "0" : tax.amount })),
        expense_category: line.expenseCategory || null, cost_center_reference: line.costCenterReference || null, project_reference: line.projectReference || null,
      }));
      if (!draft.supplierId || !lines.length) { setBusy(false); toast({ title: "Completa la factura", description: "Selecciona proveedor y captura al menos un concepto.", tone: "info" }); return; }
      ({ data, error: rpcError } = await getSupabaseClient().rpc("save_supplier_expense_invoice", { p_company_id: companyId, p_invoice_id: null, p_supplier_id: draft.supplierId, p_series: draft.series || null, p_folio: draft.folio, p_fiscal_uuid: draft.fiscalUuid || null, p_issued_date: draft.issuedDate, p_due_date: draft.dueDate, p_currency_code: draft.currencyCode.toUpperCase(), p_exchange_rate: Number(draft.exchangeRate), p_supplier_reference: draft.reference || null, p_payment_method_code: draft.paymentMethodCode || null, p_payment_form_code: draft.paymentFormCode || null, p_lines: lines, p_expected_updated_at: null }));
    }
    setBusy(false);
    if (rpcError) { toast({ title: "No se guardó la factura", description: rpcError.message, tone: "error" }); return; }
    const result = data as { id?: string; status: string; kind?: string };
    if (result.status === "exception") { toast({ title: "Duplicado bloqueado", description: "El documento quedó en excepciones; no se fusionó ni sobrescribió.", tone: "error" }); setDraft(null); changeTab("exceptions"); return; }
    if (result.id && draftXml) {
      try {
        const documentResult = await uploadDraftXml(result.id, draftXml);
        toast({ title: documentResult.status === "verified_local" ? "XML conciliado" : "XML con diferencias", description: documentResult.status === "verified_local" ? "Encabezado y conceptos coinciden con el borrador." : "El borrador se guardó, pero debe corregirse antes de confirmar.", tone: documentResult.status === "verified_local" ? "success" : "error" });
      } catch (cause) { toast({ title: "Borrador guardado sin XML", description: cause instanceof Error ? cause.message : "Adjunta nuevamente el XML desde el detalle.", tone: "error" }); }
    }
    keys.current.clear("supplier-invoice-save"); setDraft(null); setDraftXml(null);
    toast({ title: "Borrador guardado", description: "Aún no existe una cuenta por pagar.", tone: "success" });
    await load(); if (result.id) await openDetail(result.id);
  }

  async function openDetail(id: string) {
    const { data, error: rpcError } = await getSupabaseClient().rpc("get_supplier_invoice_detail", { p_company_id: companyId, p_invoice_id: id });
    if (rpcError) toast({ title: "No se abrió la factura", description: rpcError.message, tone: "error" }); else setDetail(data as Detail);
  }

  async function confirm() {
    if (!detail) return; setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("confirm_supplier_invoice", { p_company_id: companyId, p_invoice_id: detail.id, p_client_request_id: keys.current.get("supplier-invoice-confirm", detail.id) });
    setBusy(false);
    if (rpcError) { toast({ title: "No se confirmó la factura", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear("supplier-invoice-confirm"); toast({ title: "Factura y CxP confirmadas", description: "La obligación se creó una vez; inventario y costo no cambiaron.", tone: "success" }); await load(); await openDetail(detail.id);
  }

  async function submitAction() {
    if (!detail || !action || !action.reason.trim()) return;
    setBusy(true); let rpcError: { message: string } | null = null;
    if (action.kind === "authorize") ({ error: rpcError } = await getSupabaseClient().rpc("authorize_supplier_invoice_differences", { p_company_id: companyId, p_invoice_id: detail.id, p_reason: action.reason }));
    else if (action.kind === "approve_expense") ({ error: rpcError } = await getSupabaseClient().rpc("approve_supplier_expense_invoice", { p_company_id: companyId, p_invoice_id: detail.id, p_reason: action.reason }));
    else if (action.kind === "reverse") ({ error: rpcError } = await getSupabaseClient().rpc("reverse_supplier_invoice", { p_company_id: companyId, p_invoice_id: detail.id, p_reason: action.reason, p_client_request_id: keys.current.get("supplier-invoice-reverse", `${detail.id}:${action.reason}`) }));
    else if (action.kind === "sat") ({ error: rpcError } = await getSupabaseClient().rpc("record_supplier_invoice_sat_verification", { p_company_id: companyId, p_invoice_id: detail.id, p_status: action.satStatus, p_checked_at: new Date().toISOString(), p_evidence: { source: "SAT verifier", note: action.reason } }));
    else ({ error: rpcError } = await getSupabaseClient().rpc("create_supplier_credit_note", { p_company_id: companyId, p_original_invoice_id: detail.id, p_series: action.series || null, p_folio: action.folio, p_fiscal_uuid: null, p_issued_date: today(), p_amount: Number(action.amount), p_reason: action.reason, p_client_request_id: keys.current.get("supplier-credit-note", `${detail.id}:${action.folio}:${action.amount}`) }));
    setBusy(false);
    if (rpcError) { toast({ title: "No se completó la operación", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear(action.kind === "reverse" ? "supplier-invoice-reverse" : "supplier-credit-note");
    const title = action.kind === "authorize" ? "Diferencia autorizada" : action.kind === "approve_expense" ? "Gasto aprobado" : action.kind === "reverse" ? "Factura revertida" : action.kind === "sat" ? "Evidencia SAT registrada" : "Nota de crédito confirmada";
    setAction(null); toast({ title, description: "La decisión quedó auditada sin crear pagos ni modificar inventario.", tone: "success" }); await load(); await openDetail(detail.id);
  }

  async function attachDocument(file: File) {
    if (!detail || !canDocuments) return;
    const isPdf = file.type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf");
    const isXml = ["application/xml", "text/xml"].includes(file.type) || file.name.toLowerCase().endsWith(".xml");
    const role = isPdf ? "representation_pdf" : "cfdi_xml";
    if (!(isPdf || isXml) || file.size > 10 * 1024 * 1024) { toast({ title: "Archivo no permitido", description: "Adjunta XML o PDF de hasta 10 MB.", tone: "error" }); return; }
    setBusy(true);
    try {
      const bytes = await file.arrayBuffer();
      const sha256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(value => value.toString(16).padStart(2, "0")).join("");
      const extracted = role === "cfdi_xml" ? parseCfdi(new TextDecoder().decode(bytes)) : {};
      const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_");
      const path = `${companyId}/${detail.id}/${crypto.randomUUID()}-${safeName}`;
      const client = getSupabaseClient();
      const mimeType = file.type || (isPdf ? "application/pdf" : "application/xml");
      const { error: uploadError } = await client.storage.from("supplier-invoice-documents").upload(path, file, { contentType: mimeType, upsert: false });
      if (uploadError && !/already exists|duplicate/i.test(uploadError.message)) throw uploadError;
      const { data, error: rpcError } = await client.rpc("register_supplier_invoice_document", { p_company_id: companyId, p_invoice_id: detail.id, p_document_role: role, p_original_file_name: file.name, p_storage_path: path, p_mime_type: mimeType, p_size_bytes: file.size, p_sha256: sha256, p_extracted_data: extracted });
      if (rpcError) { await client.storage.from("supplier-invoice-documents").remove([path]); throw rpcError; }
      const result = data as { status: string; issues?: unknown[] };
      toast({ title: role === "cfdi_xml" ? "XML incorporado" : "PDF incorporado", description: result.status === "mismatch" ? "El expediente detectó diferencias y bloquea la confirmación." : "Documento resguardado con huella única.", tone: result.status === "mismatch" ? "error" : "success" });
      await openDetail(detail.id);
    } catch (cause) { toast({ title: "No se adjuntó el documento", description: cause instanceof Error ? cause.message : "No se pudo procesar el archivo.", tone: "error" }); }
    finally { setBusy(false); if (fileInput.current) fileInput.current.value = ""; }
  }

  async function downloadDocument(document: InvoiceDocument) {
    const { data, error: storageError } = await getSupabaseClient().storage.from("supplier-invoice-documents").createSignedUrl(document.download_path, 60);
    if (storageError) toast({ title: "No se abrió el documento", description: storageError.message, tone: "error" }); else window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  function togglePayable(row: DuePayableRow) {
    if (selectedPayables[row.id]) {
      const next = { ...selectedPayables }; delete next[row.id]; setSelectedPayables(next);
      const nextAmounts = { ...proposedAmounts }; delete nextAmounts[row.id]; setProposedAmounts(nextAmounts); return;
    }
    const first = Object.values(selectedPayables)[0];
    if (first && (first.supplier_id !== row.supplier_id || first.currency_code !== row.currency_code)) {
      toast({ title: "Proveedor o moneda distintos", description: "Cada propuesta admite CxP de un solo proveedor y una sola moneda.", tone: "info" }); return;
    }
    setSelectedPayables({ ...selectedPayables, [row.id]: row });
    setProposedAmounts({ ...proposedAmounts, [row.id]: String(row.outstanding_amount) });
  }

  function openProposalBuilder() {
    if (!Object.keys(selectedPayables).length) return;
    setProposalDraftId(null); setProposalExpectedUpdatedAt(null); setProposalBuilderOpen(true);
  }

  async function saveProposal() {
    const selected = Object.values(selectedPayables); if (!selected.length) return;
    const lines = selected.map(row => ({ accounts_payable_id: row.id, proposed_amount: Number(proposedAmounts[row.id]) }));
    if (lines.some((line, index) => !Number.isFinite(line.proposed_amount) || line.proposed_amount <= 0 || line.proposed_amount > selected[index].outstanding_amount)) {
      toast({ title: "Revisa los importes", description: "Cada importe debe ser positivo y no superar el saldo actual.", tone: "info" }); return;
    }
    const first = selected[0]; const fingerprint = JSON.stringify({ proposalDraftId, lines }); setBusy(true);
    const { data, error: rpcError } = await getSupabaseClient().rpc("save_supplier_payment_proposal", {
      p_company_id: companyId, p_proposal_id: proposalDraftId, p_supplier_id: first.supplier_id,
      p_currency_code: first.currency_code, p_lines: lines,
      p_client_request_id: keys.current.get("supplier-payment-proposal-save", fingerprint), p_expected_updated_at: proposalExpectedUpdatedAt,
    });
    setBusy(false);
    if (rpcError) { toast({ title: "No se guardó la propuesta", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear("supplier-payment-proposal-save"); const result = data as { id: string };
    setProposalBuilderOpen(false); setSelectedPayables({}); setProposedAmounts({}); setProposalDraftId(null); setProposalExpectedUpdatedAt(null);
    toast({ title: "Propuesta guardada", description: "Quedó en borrador; ningún saldo fue modificado.", tone: "success" });
    setTab("payments"); setPaymentsSection("proposals"); setStatus("all"); setQuery(""); setPage(1); await openProposalDetail(result.id);
  }

  async function openProposalDetail(id: string) {
    const { data, error: rpcError } = await getSupabaseClient().rpc("get_supplier_payment_proposal_detail", { p_company_id: companyId, p_proposal_id: id });
    if (rpcError) toast({ title: "No se abrió la propuesta", description: rpcError.message, tone: "error" }); else setProposalDetail(data as ProposalDetail);
  }

  async function openCalendarItem(item: PaymentCalendarRow) {
    if (item.payment_id && canViewPayments) {
      setCalendarPaymentId(item.payment_id); setPaymentsSection("confirmed"); setPage(1); return;
    }
    if (item.proposal_id && (canPrepareProposals || canApproveProposals)) {
      await openProposalDetail(item.proposal_id); return;
    }
    if (!canPrepareProposals) {
      toast({ title: "Consulta de vencimiento", description: "No tienes permiso para preparar propuestas de pago.", tone: "info" }); return;
    }
    const payable: DuePayableRow = {
      id: item.id, supplier_id: item.supplier_id, supplier_code: item.supplier_code, supplier_name: item.supplier_name,
      supplier_invoice_id: item.supplier_invoice_id, invoice_number: item.invoice_number, currency_code: item.currency_code,
      original_amount: item.original_amount, outstanding_amount: item.outstanding_amount, issued_date: item.issued_date,
      due_date: item.due_date, due_bucket: item.due_date < today() ? "overdue" : item.due_date <= addDays(today(), 15) ? "upcoming" : "future",
    };
    setSelectedPayables({ [item.id]: payable }); setProposedAmounts({ [item.id]: String(item.outstanding_amount) });
    setProposalDraftId(null); setProposalExpectedUpdatedAt(null); setProposalBuilderOpen(true);
  }

  function editProposal(detail: ProposalDetail) {
    const rows = Object.fromEntries(detail.lines.map(line => [line.accounts_payable_id, {
      id: line.accounts_payable_id, supplier_id: detail.supplier.id, supplier_code: detail.supplier.code,
      supplier_name: detail.supplier.display_name, supplier_invoice_id: line.supplier_invoice_id, invoice_number: line.invoice_number,
      currency_code: detail.currency_code, original_amount: line.balance_snapshot, outstanding_amount: line.current_balance,
      issued_date: line.issued_date, due_date: line.due_date,
      due_bucket: line.due_date < today() ? "overdue" : line.due_date <= addDays(today(), 15) ? "upcoming" : "future",
    } satisfies DuePayableRow]));
    setSelectedPayables(rows); setProposedAmounts(Object.fromEntries(detail.lines.map(line => [line.accounts_payable_id, String(line.proposed_amount)])));
    setProposalDraftId(detail.id); setProposalExpectedUpdatedAt(detail.updated_at); setProposalBuilderOpen(true); setProposalDetail(null);
  }

  async function executeProposalAction() {
    if (!proposalDetail || !proposalAction) return;
    if (["reject", "cancel"].includes(proposalAction.kind) && !proposalAction.reason.trim()) return;
    const actionKey = `${proposalDetail.id}:${proposalAction.kind}:${proposalAction.reason}`; setBusy(true);
    const client = getSupabaseClient(); let rpcError: { message: string } | null = null;
    if (proposalAction.kind === "submit") ({ error: rpcError } = await client.rpc("submit_supplier_payment_proposal", { p_company_id: companyId, p_proposal_id: proposalDetail.id, p_client_request_id: keys.current.get("supplier-payment-proposal-submit", actionKey) }));
    else if (proposalAction.kind === "cancel") ({ error: rpcError } = await client.rpc("cancel_supplier_payment_proposal", { p_company_id: companyId, p_proposal_id: proposalDetail.id, p_reason: proposalAction.reason, p_client_request_id: keys.current.get("supplier-payment-proposal-cancel", actionKey) }));
    else ({ error: rpcError } = await client.rpc("decide_supplier_payment_proposal", { p_company_id: companyId, p_proposal_id: proposalDetail.id, p_decision: proposalAction.kind === "approve" ? "approved" : "rejected", p_reason: proposalAction.reason || null, p_client_request_id: keys.current.get(`supplier-payment-proposal-${proposalAction.kind}`, actionKey) }));
    setBusy(false);
    if (rpcError) { toast({ title: "No se actualizó la propuesta", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear(`supplier-payment-proposal-${proposalAction.kind}`); const id = proposalDetail.id; setProposalAction(null);
    toast({ title: proposalAction.kind === "submit" ? "Propuesta enviada" : proposalAction.kind === "approve" ? "Propuesta aprobada" : proposalAction.kind === "reject" ? "Propuesta rechazada" : "Propuesta cancelada", description: "La decisión quedó auditada y los saldos permanecen sin cambios.", tone: "success" });
    await load(); await openProposalDetail(id);
  }

  const statusOptions = tab === "invoices"
    ? [{ value: "all", label: "Todos" }, { value: "draft", label: "Borrador" }, { value: "confirmed", label: "Confirmada" }, { value: "reversed", label: "Revertida" }]
    : [{ value: "all", label: "Todas" }, { value: "draft", label: "Borrador" }, { value: "submitted", label: "En aprobación" }, { value: "approved", label: "Aprobadas" }, { value: "rejected", label: "Rechazadas" }, { value: "cancelled", label: "Canceladas" }];
  const supplierFilterPicker = <div className="purchase-order-supplier-picker">
    <Input role="combobox" aria-label="Proveedor" aria-expanded={filterSupplierPickerOpen} autoComplete="off"
      value={filterSupplierQuery} placeholder="Todos los proveedores"
      onFocus={() => setFilterSupplierPickerOpen(true)}
      onBlur={() => window.setTimeout(() => setFilterSupplierPickerOpen(false), 120)}
      onChange={event => { setFilterSupplierQuery(event.target.value); setDueSupplier(""); setFilterSupplierPickerOpen(true); setPage(1); }} />
    {filterSupplierPickerOpen && <div className="purchase-order-supplier-options" role="listbox">
      <button type="button" role="option" aria-selected={!dueSupplier} onMouseDown={event => event.preventDefault()} onClick={() => { setDueSupplier(""); setFilterSupplierQuery(""); setFilterSupplierPickerOpen(false); setPage(1); }}><strong>Todos los proveedores</strong><small>Sin filtro de proveedor</small></button>
      {filterSuppliers.map(item => <button type="button" role="option" aria-selected={dueSupplier === item.id} key={item.id} onMouseDown={event => event.preventDefault()} onClick={() => { setDueSupplier(item.id); setFilterSupplierQuery(`${item.code} · ${item.display_name}`); setFilterSupplierPickerOpen(false); setPage(1); }}><strong>{item.display_name}</strong><small>{item.code}{item.tax_id ? ` · ${item.tax_id}` : ""}</small></button>)}
      {!filterSupplierSearching && filterSuppliers.length === 0 && <p>No se encontraron proveedores.</p>}
      <p>{filterSupplierSearching ? "Buscando…" : `${filterSupplierTotal} proveedores coinciden; escribe para refinar.`}</p>
    </div>}
  </div>;
  const visibleDataCount = tab === "invoices" ? rows.length : tab === "payables" && payablesSection === "current" ? duePayables.length + aging.length : tab === "payables" ? historicalPayables.length : paymentsSection === "proposals" ? proposals.length : paymentsSection === "agenda" ? calendarRows.length : 0;

  return <div className="content-frame supplier-invoice-module">
    <div className="page-heading"><div><span className="eyebrow">Compras</span><h1>Facturas y cuentas por pagar</h1><p>Flujo operativo: factura, cuenta por pagar y pago; sin duplicar capturas ni modificar reglas de negocio.</p></div><div className="page-heading-actions"><Button loading={loading} onClick={() => void load()}><RefreshCw size={16} /> Actualizar</Button>{tab === "payables" && payablesSection === "current" && canPrepareProposals && Object.keys(selectedPayables).length > 0 && <Button variant="primary" onClick={openProposalBuilder}>Crear propuesta ({Object.keys(selectedPayables).length})</Button>}{(canDraft || canExpense) && tab === "invoices" && <Button variant="primary" onClick={() => void openNew()}><FilePlus2 size={16} /> Nueva factura</Button>}</div></div>
    <Tabs value={tab} onValueChange={changeTab} items={[{ value: "invoices", label: "Facturas" }, { value: "payables", label: "Cuentas por pagar" }, ...((canPrepareProposals || canApproveProposals || canViewPayments) ? [{ value: "payments", label: "Pagos" }] : [])]} />
    {tab === "payables" && <Tabs value={payablesSection} onValueChange={value => { setPayablesSection(value as "current" | "history"); setQuery(""); setPage(1); }} items={[{ value: "current", label: "Por pagar" }, { value: "history", label: "Historial" }]} />}
    {tab === "payments" && <Tabs value={paymentsSection} onValueChange={value => { setPaymentsSection(value as "proposals" | "agenda" | "confirmed"); setStatus("all"); setPage(1); }} items={[...((canPrepareProposals || canApproveProposals) ? [{ value: "proposals", label: "Propuestas" }] : []), { value: "agenda", label: "Agenda" }, ...(canViewPayments ? [{ value: "confirmed", label: "Pagos realizados" }] : [])]} />}
    {tab === "payables" && payablesSection === "current" && <DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Proveedor o factura" results={total} activeFilters={[dueBucket !== "all", dueSupplier, dueCurrency, dueFrom, dueTo, minBalance, maxBalance].filter(Boolean).length} onClear={() => { setDueBucket("all"); setDueSupplier(""); setFilterSupplierQuery(""); setDueCurrency(""); setDueFrom(""); setDueTo(""); setMinBalance(""); setMaxBalance(""); }} filters={<div className="payment-proposal-filters"><Select ariaLabel="Vencimiento" value={dueBucket} onValueChange={value => { setDueBucket(value as "all" | DueBucket); setPage(1); }} options={[{ value: "all", label: "Todos los vencimientos" }, { value: "overdue", label: "Vencidas" }, { value: "upcoming", label: "Próximos 15 días" }, { value: "future", label: "Futuras" }]} />{supplierFilterPicker}<Input aria-label="Moneda" placeholder="Moneda" maxLength={3} value={dueCurrency} onChange={event => { setDueCurrency(event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase()); setPage(1); }} /><Input aria-label="Vence desde" type="date" value={dueFrom} onChange={event => { setDueFrom(event.target.value); setPage(1); }} /><Input aria-label="Vence hasta" type="date" value={dueTo} onChange={event => { setDueTo(event.target.value); setPage(1); }} /><Input aria-label="Saldo mínimo" type="number" min="0" step="0.01" placeholder="Saldo mín." value={minBalance} onChange={event => { setMinBalance(event.target.value); setPage(1); }} /><Input aria-label="Saldo máximo" type="number" min="0" step="0.01" placeholder="Saldo máx." value={maxBalance} onChange={event => { setMaxBalance(event.target.value); setPage(1); }} /></div>} />}
    {tab === "payables" && payablesSection === "history" && <DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Proveedor o factura" results={total} activeFilters={query ? 1 : 0} onClear={() => setQuery("")} />}
    {tab === "payments" && paymentsSection === "proposals" && <DataToolbar results={total} activeFilters={[status !== "all", dueSupplier, dueCurrency].filter(Boolean).length} onClear={() => { setStatus("all"); setDueSupplier(""); setFilterSupplierQuery(""); setDueCurrency(""); }} filters={<div className="payment-proposal-filters compact"><Select ariaLabel="Estado de la propuesta" value={status} onValueChange={value => { setStatus(value); setPage(1); }} options={statusOptions} />{supplierFilterPicker}<Input aria-label="Moneda" placeholder="Moneda" maxLength={3} value={dueCurrency} onChange={event => { setDueCurrency(event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase()); setPage(1); }} /></div>} />}
    {tab === "payments" && paymentsSection === "agenda" && <DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Proveedor o factura" results={total} activeFilters={[dueSupplier, dueCurrency, calendarView === "table" && dueFrom, calendarView === "table" && dueTo].filter(Boolean).length} onClear={() => { setQuery(""); setDueSupplier(""); setFilterSupplierQuery(""); setDueCurrency(""); setDueFrom(""); setDueTo(""); }} filters={<div className="payment-calendar-filters">{supplierFilterPicker}<Input aria-label="Moneda" placeholder="Moneda" maxLength={3} value={dueCurrency} onChange={event => { setDueCurrency(event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase()); setPage(1); }} />{calendarView === "table" && <><Input aria-label="Vence desde" type="date" value={dueFrom} onChange={event => { setDueFrom(event.target.value); setPage(1); }} /><Input aria-label="Vence hasta" type="date" value={dueTo} onChange={event => { setDueTo(event.target.value); setPage(1); }} /></>}</div>} />}
    {tab === "invoices" && <DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Proveedor, folio, UUID u OC" results={total} activeFilters={status === "all" ? 0 : 1} onClear={() => setStatus("all")} filters={<Select ariaLabel="Estado" value={status} onValueChange={value => { setStatus(value); setPage(1); }} options={statusOptions} />} />}
    <DataRefreshStatus loading={loading} hasData={visibleDataCount} />

    {tab === "invoices" && <><div className="supplier-invoice-exception-summary"><Button size="sm" aria-expanded={showExceptions} onClick={() => setShowExceptions(value => !value)}><AlertTriangle size={15} /> Excepciones ({exceptionTotal})</Button><span>Alertas documentales integradas; no alteran el estado de la factura.</span></div>{showExceptions && <DataState loading={loading} error={error} hasData={exceptions.length} empty="No hay excepciones registradas."><div className="supplier-invoice-exceptions">{exceptions.map(item => <article key={item.id}><AlertTriangle size={18} /><span><strong>{exceptionLabel(item.kind)} · {item.supplier_name}</strong><small>{item.invoice_folio ? `Factura ${item.invoice_folio}` : "Documento bloqueado antes de crearse"} · {new Date(item.detected_at).toLocaleString("es-MX")}</small></span><Badge tone={item.status === "pending" ? "warning" : "success"}>{item.status === "pending" ? "Pendiente" : "Resuelta"}</Badge></article>)}</div><Pagination page={exceptionPage} total={exceptionTotal} setPage={setExceptionPage} /></DataState>}<DataState loading={loading} error={error} hasData={rows.length} emptyTitle="No hay facturas." empty="No hay facturas con estos filtros."><Table><thead><tr><th>Factura</th><th>Proveedor / origen</th><th>Emisión / vencimiento</th><th>Diferencias</th><th>Estado</th><th className="number-cell">Total / saldo</th></tr></thead><tbody>{rows.map(row => <InteractiveTableRow key={row.id} className="purchase-order-row" label={`Abrir factura ${[row.series, row.folio].filter(Boolean).join("-")}`} onActivate={() => void openDetail(row.id)}><td><strong>{[row.series, row.folio].filter(Boolean).join("-")}</strong><small>{row.fiscal_uuid ?? "Sin UUID fiscal"}</small></td><td><strong>{row.supplier_name}</strong><small>{row.purchase_order_folio ?? "Gasto o servicio sin recepción"}</small></td><td>{date(row.issued_date)}<small>{date(row.due_date)}</small></td><td>{row.differences.length ? <Badge tone="warning">{row.differences.length} por revisar</Badge> : <Badge tone="success">Sin diferencias</Badge>}</td><td><InvoiceBadge status={row.status} /></td><td className="number-cell"><strong>{money(row.total, row.currency_code)}</strong><small>{row.outstanding_amount === null ? "Sin CxP" : `Saldo ${money(row.outstanding_amount, row.currency_code)}`}</small></td></InteractiveTableRow>)}</tbody></Table><Pagination page={page} total={total} setPage={setPage} /></DataState></>}
    {tab === "payables" && payablesSection === "current" && <><section className="supplier-payments-list-heading"><h2>Resumen de antigüedad</h2><p>Saldos abiertos agrupados por moneda y días de vencimiento.</p></section><DataState loading={loading} error={error} hasData={aging.length} empty="No hay saldos abiertos para calcular antigüedad."><div className="payables-aging-grid">{aging.map(item => <article key={item.currency_code}><header><span>{item.document_count} documentos</span><strong>{money(item.total, item.currency_code)}</strong><Badge tone="info">{item.currency_code}</Badge></header><dl><div><dt>Por vencer</dt><dd>{money(item.not_due, item.currency_code)}</dd></div><div><dt>1–30 días</dt><dd>{money(item.days_1_30, item.currency_code)}</dd></div><div><dt>31–60 días</dt><dd>{money(item.days_31_60, item.currency_code)}</dd></div><div><dt>61–90 días</dt><dd>{money(item.days_61_90, item.currency_code)}</dd></div><div><dt>Más de 90</dt><dd>{money(item.days_over_90, item.currency_code)}</dd></div></dl></article>)}</div></DataState><section className="supplier-payments-list-heading"><h2>Vencimientos y saldos</h2><p>Filtra y selecciona CxP abiertas para preparar una propuesta sin modificar sus saldos.</p></section><DataState loading={loading} error={error} hasData={duePayables.length} empty="No hay CxP abiertas con estos filtros."><Table><thead><tr>{canPrepareProposals && <th>Elegir</th>}<th>Factura</th><th>Proveedor</th><th>Vencimiento</th><th>Clasificación</th><th className="number-cell">Saldo actual</th></tr></thead><tbody>{duePayables.map(row => <tr key={row.id}>{canPrepareProposals && <td><input aria-label={`Seleccionar ${row.invoice_number}`} type="checkbox" checked={Boolean(selectedPayables[row.id])} disabled={Boolean(Object.values(selectedPayables)[0] && (Object.values(selectedPayables)[0].supplier_id !== row.supplier_id || Object.values(selectedPayables)[0].currency_code !== row.currency_code))} onChange={() => togglePayable(row)} /></td>}<td><strong>{row.invoice_number}</strong><small>{date(row.issued_date)}</small></td><td><strong>{row.supplier_name}</strong><small>{row.supplier_code}</small></td><td>{date(row.due_date)}</td><td><DueBucketBadge bucket={row.due_bucket} /></td><td className="number-cell"><strong>{money(row.outstanding_amount, row.currency_code)}</strong></td></tr>)}</tbody></Table><Pagination page={page} total={total} setPage={setPage} /></DataState></>}
    {tab === "payables" && payablesSection === "history" && <><section className="historical-payables-heading"><div><h2>Historial de cuentas por pagar</h2><p>Consulta del último corte conservado. No modifica saldos ni permite preparar pagos.</p></div>{historicalSnapshotDate && <Badge tone="info">Corte {date(historicalSnapshotDate)}</Badge>}</section>{historicalTotals.length > 0 && <div className="historical-payables-totals">{historicalTotals.map(item => <article key={item.currency_code}><span>{item.document_count} documentos · {item.currency_code}</span><strong>{money(item.outstanding_amount, item.currency_code)}</strong></article>)}</div>}<DataState loading={loading} error={error} hasData={historicalPayables.length} empty="No hay cuentas por pagar conservadas para consultar."><Table><thead><tr><th>Factura</th><th>Proveedor</th><th>Emisión</th><th>Fecha límite</th><th>Condición al corte</th><th className="number-cell">Saldo al corte</th></tr></thead><tbody>{historicalPayables.map(row => <tr key={row.id}><td><strong>{row.folio}</strong></td><td><strong>{row.supplier_name}</strong><small>{row.supplier_external_code}</small></td><td>{date(row.issued_date)}</td><td>{date(row.due_date)}</td><td><Badge tone={row.condition_at_snapshot === "overdue" ? "danger" : "info"}>{row.condition_at_snapshot === "overdue" ? "Vencida al corte" : "En plazo al corte"}</Badge></td><td className="number-cell"><strong>{money(row.outstanding_amount, row.currency_code)}</strong></td></tr>)}</tbody></Table><Pagination page={page} total={total} setPage={setPage} /></DataState></>}
    {tab === "payments" && paymentsSection === "proposals" && <><section className="supplier-payments-list-heading"><h2>Propuestas de pago</h2><p>Preparación y aprobación previas; no crean pagos ni aplicaciones.</p></section><DataState loading={loading} error={error} hasData={proposals.length} empty="No hay propuestas con estos filtros."><Table><thead><tr><th>Propuesta</th><th>Proveedor</th><th>Estado</th><th>CxP</th><th>Creada</th><th className="number-cell">Importe propuesto</th></tr></thead><tbody>{proposals.map(row => <InteractiveTableRow key={row.id} className="purchase-order-row" label={`Abrir propuesta ${row.id.slice(0, 8).toUpperCase()}`} onActivate={() => void openProposalDetail(row.id)}><td><strong>{row.id.slice(0, 8).toUpperCase()}</strong><small>{row.currency_code}</small></td><td><strong>{row.supplier_name}</strong><small>{row.supplier_code}</small></td><td><ProposalBadge status={row.status} /></td><td>{row.line_count}</td><td>{new Date(row.created_at).toLocaleString("es-MX")}</td><td className="number-cell"><strong>{money(row.total_proposed, row.currency_code)}</strong></td></InteractiveTableRow>)}</tbody></Table><Pagination page={page} total={total} setPage={setPage} /></DataState></>}
    {tab === "payments" && paymentsSection === "agenda" && <PaymentCalendar rows={calendarRows} totals={calendarTotals} total={total} loading={loading} error={error} view={calendarView} anchor={calendarAnchor} page={page} onPage={setPage} onView={value => { setCalendarView(value); setPage(1); }} onAnchor={value => { setCalendarAnchor(value); setPage(1); }} onOpen={item => void openCalendarItem(item)} />}
    {tab === "payments" && paymentsSection === "confirmed" && <SupplierPaymentsWorkspace companyId={companyId} permissions={permissions} mode="payments" initialPaymentId={calendarPaymentId} onInitialPaymentOpened={() => setCalendarPaymentId(null)} />}

    <Drawer open={proposalBuilderOpen} onOpenChange={open => !open && !busy && setProposalBuilderOpen(false)} title={proposalDraftId ? "Editar propuesta de pago" : "Nueva propuesta de pago"} className="purchase-order-drawer payment-proposal-drawer">{proposalBuilderOpen && <div className="purchase-order-form"><div className="proposal-scope"><div><span>Proveedor</span><strong>{Object.values(selectedPayables)[0]?.supplier_name}</strong></div><div><span>Moneda</span><strong>{Object.values(selectedPayables)[0]?.currency_code}</strong></div><div><span>Total propuesto</span><strong>{money(Object.values(selectedPayables).reduce((sum, row) => sum + Number(proposedAmounts[row.id] || 0), 0), Object.values(selectedPayables)[0]?.currency_code ?? "MXN")}</strong></div></div><PagedCollection items={Object.values(selectedPayables).sort((a, b) => a.due_date.localeCompare(b.due_date))} resetKey={proposalDraftId ?? "new"} label="CxP seleccionadas">{visiblePayables=><Table><thead><tr><th>Factura</th><th>Vencimiento</th><th className="number-cell">Saldo actual</th><th>Importe propuesto</th><th className="number-cell">Saldo proyectado</th><th></th></tr></thead><tbody>{visiblePayables.map(row => { const proposed = Number(proposedAmounts[row.id] || 0); return <tr key={row.id}><td><strong>{row.invoice_number}</strong></td><td>{date(row.due_date)}</td><td className="number-cell">{money(row.outstanding_amount, row.currency_code)}</td><td><Input aria-label={`Importe propuesto ${row.invoice_number}`} type="number" min="0.000001" max={row.outstanding_amount} step="0.000001" value={proposedAmounts[row.id] ?? ""} onChange={event => setProposedAmounts({ ...proposedAmounts, [row.id]: event.target.value })} /></td><td className="number-cell"><strong>{money(row.outstanding_amount - proposed, row.currency_code)}</strong></td><td><Button size="sm" onClick={() => togglePayable(row)}>Quitar</Button></td></tr>; })}</tbody></Table>}</PagedCollection><p className="proposal-no-impact">Guardar o enviar esta propuesta no modifica los saldos mostrados. La selección completa se conserva entre páginas.</p><div className="purchase-order-actions"><Button disabled={busy} onClick={() => setProposalBuilderOpen(false)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!Object.keys(selectedPayables).length} onClick={() => void saveProposal()}>Guardar borrador</Button></div></div>}</Drawer>

    <Drawer open={Boolean(proposalDetail)} onOpenChange={open => !open && !busy && setProposalDetail(null)} title={proposalDetail ? `Propuesta ${proposalDetail.id.slice(0, 8).toUpperCase()}` : "Propuesta"} className="purchase-order-detail-drawer payment-proposal-drawer">{proposalDetail && <div className="purchase-order-detail"><header><div><ProposalBadge status={proposalDetail.status} /> <Badge tone="info">{proposalDetail.currency_code}</Badge></div><strong>{money(proposalDetail.total_proposed, proposalDetail.currency_code)}</strong></header><dl><div><dt>Proveedor</dt><dd>{proposalDetail.supplier.display_name} · {proposalDetail.supplier.code}</dd></div><div><dt>Creada</dt><dd>{new Date(proposalDetail.created_at).toLocaleString("es-MX")}</dd></div><div><dt>CxP incluidas</dt><dd>{proposalDetail.lines.length}</dd></div><div><dt>Efecto financiero</dt><dd>Ninguno: no es pago ni aplicación</dd></div></dl><PagedCollection items={proposalDetail.lines} resetKey={proposalDetail.id} label="CxP incluidas">{visibleLines=><Table><thead><tr><th>Factura</th><th>Vencimiento</th><th className="number-cell">Saldo al preparar</th><th className="number-cell">Saldo actual</th><th className="number-cell">Propuesto</th><th className="number-cell">Proyectado</th></tr></thead><tbody>{visibleLines.map(line => <tr key={line.id}><td><strong>{line.invoice_number}</strong></td><td>{date(line.due_date)}</td><td className="number-cell">{money(line.balance_snapshot, proposalDetail.currency_code)}</td><td className="number-cell"><strong>{money(line.current_balance, proposalDetail.currency_code)}</strong></td><td className="number-cell">{money(line.proposed_amount, proposalDetail.currency_code)}</td><td className="number-cell"><strong>{money(line.projected_balance, proposalDetail.currency_code)}</strong></td></tr>)}</tbody></Table>}</PagedCollection>{(proposalDetail.rejection_reason || proposalDetail.cancellation_reason) && <section className="proposal-decision-reason"><strong>{proposalDetail.rejection_reason ? "Motivo de rechazo" : "Motivo de cancelación"}</strong><p>{proposalDetail.rejection_reason ?? proposalDetail.cancellation_reason}</p></section>}<section className="purchase-order-history"><h3>Historial auditado</h3><PagedCollection items={proposalDetail.audit} resetKey={proposalDetail.id} label="eventos">{visibleAudit=><>{visibleAudit.map(item => <article key={item.id}><span><strong>{proposalAuditLabel(item.action)}</strong><small>{new Date(item.created_at).toLocaleString("es-MX")}</small></span></article>)}</>}</PagedCollection></section><div className="purchase-order-actions">{canPrepareProposals && proposalDetail.status === "draft" && <Button onClick={() => editProposal(proposalDetail)}>Editar</Button>}{canPrepareProposals && proposalDetail.status === "draft" && <Button variant="primary" onClick={() => setProposalAction({ kind: "submit", reason: "" })}>Enviar a aprobación</Button>}{canApproveProposals && proposalDetail.status === "submitted" && <Button variant="primary" onClick={() => setProposalAction({ kind: "approve", reason: "" })}>Aprobar</Button>}{canApproveProposals && proposalDetail.status === "submitted" && <Button variant="danger" onClick={() => setProposalAction({ kind: "reject", reason: "" })}>Rechazar</Button>}{canPrepareProposals && ["draft", "submitted"].includes(proposalDetail.status) && <Button onClick={() => setProposalAction({ kind: "cancel", reason: "" })}>Cancelar propuesta</Button>}</div></div>}</Drawer>

    <Modal open={Boolean(proposalAction)} onOpenChange={open => !open && !busy && setProposalAction(null)} eyebrow="Propuesta auditada" title={proposalAction?.kind === "submit" ? "Enviar a aprobación" : proposalAction?.kind === "approve" ? "Aprobar propuesta" : proposalAction?.kind === "reject" ? "Rechazar propuesta" : "Cancelar propuesta"} description="La transición no crea pagos ni modifica saldos de CxP." footer={<><Button disabled={busy} onClick={() => setProposalAction(null)}>Volver</Button><Button variant={proposalAction?.kind === "reject" ? "danger" : "primary"} loading={busy} disabled={Boolean(proposalAction && ["reject", "cancel"].includes(proposalAction.kind) && !proposalAction.reason.trim())} onClick={() => void executeProposalAction()}>Confirmar</Button></>}>{proposalAction && ["reject", "cancel"].includes(proposalAction.kind) && <label className="operation-reason">Motivo obligatorio<textarea rows={4} value={proposalAction.reason} onChange={event => setProposalAction({ ...proposalAction, reason: event.target.value })} /></label>}</Modal>

    <Drawer open={Boolean(draft)} onOpenChange={open => !open && !busy && setDraft(null)} title="Nueva factura de proveedor" className="purchase-order-drawer supplier-invoice-drawer">{draft && <form className="purchase-order-form" onSubmit={event => { event.preventDefault(); void saveDraft(); }}>
      <div className="invoice-source-switch"><Button type="button" variant={draft.sourceKind === "receipt" ? "primary" : "secondary"} onClick={() => { setCandidate(null); setDraftXml(null); setReceiptQuery(""); setReceiptPickerOpen(false); setDraft({ ...draft, sourceKind: "receipt", supplierId: "", receiptId: "" }); }}>Contra recepción</Button>{canExpense && <Button type="button" variant={draft.sourceKind === "expense" ? "primary" : "secondary"} onClick={() => { setCandidate(null); setDraftXml(null); setDraftSupplierQuery(""); setDraftSupplierPickerOpen(false); setDraft({ ...draft, sourceKind: "expense", receiptId: "", supplierId: "" }); }}>Gasto o servicio</Button>}</div>
      <p className="invoice-source-note">{draft.sourceKind === "receipt" ? "Usa exclusivamente cantidades de recepciones confirmadas aún no facturadas." : "Para servicios, rentas y gastos sin recepción. Requiere aprobación antes de crear CxP."}</p>
      {draft.sourceKind === "expense" && <section className={`draft-cfdi-loader${draftXml ? " is-loaded" : ""}`}><input ref={draftXmlInput} hidden type="file" accept=".xml,application/xml,text/xml" onChange={event => event.target.files?.[0] && void readDraftXml(event.target.files[0])} /><div><strong>{draftXml ? draftXml.file.name : "XML CFDI 4.0"}</strong><small>{draftXml ? `${draftXml.extracted.concepts.length} conceptos · ${draftXml.extracted.issuer_rfc ?? "RFC no disponible"}` : "Recomendado: carga el XML para autollenar proveedor, encabezado, conceptos e impuestos."}</small></div><Button type="button" size="sm" onClick={() => draftXmlInput.current?.click()}><Upload size={14} /> {draftXml ? "Cambiar XML" : "Cargar XML"}</Button></section>}
      <div className="purchase-order-grid">
        {draft.sourceKind === "receipt" ? <Field label="Recepción confirmada" hint={receiptSearching ? "Buscando…" : `${receiptTotal} recepciones disponibles; busca por recepción, OC o proveedor.`}><div className="purchase-order-supplier-picker"><Input role="combobox" aria-label="Recepción confirmada" aria-expanded={receiptPickerOpen} autoComplete="off" value={receiptQuery} placeholder="Buscar recepción confirmada" onFocus={() => setReceiptPickerOpen(true)} onBlur={() => window.setTimeout(() => setReceiptPickerOpen(false), 120)} onChange={event => { setReceiptQuery(event.target.value); setReceiptPickerOpen(true); if (draft.receiptId) { setDraft({ ...draft, receiptId: "" }); setCandidate(null); } }} />{receiptPickerOpen && <div className="purchase-order-supplier-options" role="listbox">{receipts.map(item => <button type="button" role="option" aria-selected={draft.receiptId === item.id} key={item.id} onMouseDown={event => event.preventDefault()} onClick={() => { setReceiptQuery(`${item.receipt_folio} · ${item.purchase_order_folio} · ${item.supplier_name}`); setReceiptPickerOpen(false); void chooseReceipt(item.id); }}><strong>{item.receipt_folio} · {item.purchase_order_folio}</strong><small>{item.supplier_name} · {date(item.receipt_date)}</small></button>)}{!receiptSearching && receipts.length === 0 && <p>No se encontraron recepciones facturables.</p>}</div>}</div></Field> : <Field label="Proveedor" hint={draftSupplierSearching ? "Buscando…" : `${draftSupplierTotal} proveedores activos; busca por nombre, clave o RFC.`}><div className="purchase-order-supplier-picker"><Input role="combobox" aria-label="Proveedor" aria-expanded={draftSupplierPickerOpen} autoComplete="off" value={draftSupplierQuery} placeholder="Buscar proveedor" onFocus={() => setDraftSupplierPickerOpen(true)} onBlur={() => window.setTimeout(() => setDraftSupplierPickerOpen(false), 120)} onChange={event => { setDraftSupplierQuery(event.target.value); setDraftSupplierPickerOpen(true); if (draft.supplierId) setDraft({ ...draft, supplierId: "" }); }} />{draftSupplierPickerOpen && <div className="purchase-order-supplier-options" role="listbox">{suppliers.map(item => <button type="button" role="option" aria-selected={draft.supplierId === item.id} key={item.id} onMouseDown={event => event.preventDefault()} onClick={() => { setDraftSupplierQuery(`${item.code} · ${item.display_name}`); setDraftSupplierPickerOpen(false); setDraft({ ...draft, supplierId: item.id }); }}><strong>{item.display_name}</strong><small>{item.code}{item.tax_id ? ` · ${item.tax_id}` : ""}</small></button>)}{!draftSupplierSearching && suppliers.length === 0 && <p>No se encontraron proveedores activos.</p>}</div>}</div></Field>}
        <Field label="Serie"><Input value={draft.series} onChange={event => setDraft({ ...draft, series: event.target.value })} /></Field>
        <Field label="Folio"><Input required value={draft.folio} onChange={event => setDraft({ ...draft, folio: event.target.value })} /></Field>
        <Field label="UUID fiscal" hint="Se valida nuevamente al adjuntar XML."><Input value={draft.fiscalUuid} onChange={event => setDraft({ ...draft, fiscalUuid: event.target.value })} /></Field>
        <Field label="Emisión"><Input type="date" value={draft.issuedDate} onChange={event => setDraft({ ...draft, issuedDate: event.target.value, dueDate: draft.dueDate < event.target.value ? event.target.value : draft.dueDate })} /></Field>
        <Field label="Vencimiento"><Input type="date" min={draft.issuedDate} value={draft.dueDate} onChange={event => setDraft({ ...draft, dueDate: event.target.value })} /></Field>
        <Field label="Moneda"><div className="invoice-currency-field"><Select ariaLabel="Moneda" value={COMMON_CURRENCIES.some(option => option.value === draft.currencyCode) ? draft.currencyCode : OTHER_CURRENCY} onValueChange={value => setDraft({ ...draft, currencyCode: value === OTHER_CURRENCY ? "" : value, exchangeRate: value === "MXN" ? "1" : draft.exchangeRate })} options={[...COMMON_CURRENCIES, { value: OTHER_CURRENCY, label: "Otra moneda…" }]} />{!COMMON_CURRENCIES.some(option => option.value === draft.currencyCode) && <Input aria-label="Código de otra moneda" placeholder="Ej. CAD" maxLength={3} value={draft.currencyCode} onChange={event => { const currencyCode = event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase(); setDraft({ ...draft, currencyCode, exchangeRate: currencyCode === "MXN" ? "1" : draft.exchangeRate }); }} />}</div></Field>
        <Field label="Tipo de cambio" hint="Moneda de factura → moneda base."><Input type="number" min="0.000001" step="0.000001" disabled={draft.currencyCode === "MXN"} value={draft.exchangeRate} onChange={event => setDraft({ ...draft, exchangeRate: event.target.value })} /></Field>
        <Field label="Método CFDI"><Select ariaLabel="Método CFDI" value={draft.paymentMethodCode} onValueChange={value => setDraft({ ...draft, paymentMethodCode: value })} options={PAYMENT_METHODS} /></Field>
        <Field label="Forma CFDI"><Select ariaLabel="Forma CFDI" value={draft.paymentFormCode} onValueChange={value => setDraft({ ...draft, paymentFormCode: value })} options={PAYMENT_FORMS} /></Field>
        <Field label="Referencia"><Input value={draft.reference} onChange={event => setDraft({ ...draft, reference: event.target.value })} /></Field>
      </div>
      {draft.sourceKind === "receipt" && candidate && <ThreeWay candidate={candidate} draft={draft} setDraft={setDraft} canCost={canCost} />}
      {draft.sourceKind === "expense" && <section className="expense-lines-editor"><header><div><strong>Conceptos de gasto o servicio</strong><small>El XML autollena la información fiscal; la distribución interna puede completarse aquí.</small></div><Button type="button" size="sm" onClick={() => setDraft({ ...draft, expenseLines: [...draft.expenseLines, blankExpenseLine()] })}><Plus size={14} /> Concepto</Button></header>{draft.expenseLines.map((line, index) => <article key={line.id} className="expense-line-card"><header><div><strong>Concepto {index + 1}</strong><small>{line.productServiceCode || "Sin clave SAT"}</small></div><Button type="button" size="sm" disabled={draft.expenseLines.length === 1} onClick={() => setDraft({ ...draft, expenseLines: draft.expenseLines.filter(item => item.id !== line.id) })}><Trash2 size={14} /> Quitar</Button></header><Field label="Descripción del bien o servicio"><Input value={line.description} onChange={event => updateExpenseLine(line.id, { description: event.target.value })} /></Field><div className="expense-line-grid"><Field label="Clave SAT"><Input inputMode="numeric" maxLength={8} placeholder="81112100" value={line.productServiceCode} onChange={event => updateExpenseLine(line.id, { productServiceCode: event.target.value.replace(/\D/g, "") })} /></Field><Field label="No. identificación"><Input value={line.identificationNumber} onChange={event => updateExpenseLine(line.id, { identificationNumber: event.target.value })} /></Field><Field label="Cantidad"><Input type="number" min="0.000001" step="0.000001" value={line.quantity} onChange={event => updateExpenseLine(line.id, { quantity: event.target.value })} /></Field><Field label="Clave unidad"><Input placeholder="E48" value={line.unitCode} onChange={event => updateExpenseLine(line.id, { unitCode: event.target.value.toUpperCase() })} /></Field><Field label="Unidad"><Input placeholder="Unidad de servicio" value={line.unitName} onChange={event => updateExpenseLine(line.id, { unitName: event.target.value })} /></Field><Field label="Valor unitario"><Input type="number" min="0" step="0.000001" value={line.unitValue} onChange={event => updateExpenseLine(line.id, { unitValue: event.target.value, subtotal: String(Number(line.quantity || 0) * Number(event.target.value || 0)) })} /></Field><Field label="Importe"><Input type="number" min="0" step="0.000001" value={line.subtotal} onChange={event => updateExpenseLine(line.id, { subtotal: event.target.value })} /></Field><Field label="Descuento"><Input type="number" min="0" step="0.000001" value={line.discount} onChange={event => updateExpenseLine(line.id, { discount: event.target.value })} /></Field><Field label="Objeto de impuesto"><Select ariaLabel={`Objeto de impuesto concepto ${index + 1}`} value={line.taxObjectCode} onValueChange={value => updateExpenseLine(line.id, { taxObjectCode: value })} options={TAX_OBJECTS} /></Field><Field label="Categoría interna"><Input placeholder="Ej. Servicios profesionales" value={line.expenseCategory} onChange={event => updateExpenseLine(line.id, { expenseCategory: event.target.value })} /></Field><Field label="Centro de costo"><Input placeholder="Opcional" value={line.costCenterReference} onChange={event => updateExpenseLine(line.id, { costCenterReference: event.target.value })} /></Field><Field label="Proyecto"><Input placeholder="Opcional" value={line.projectReference} onChange={event => updateExpenseLine(line.id, { projectReference: event.target.value })} /></Field></div><section className="expense-tax-editor"><header><div><strong>Impuestos del concepto</strong><small>Traslados y retenciones se conservan con base, factor, tasa e importe.</small></div><Button type="button" size="sm" onClick={() => updateExpenseLine(line.id, { taxDetails: [...line.taxDetails, blankExpenseTax()] })}><Plus size={14} /> Impuesto</Button></header>{line.taxDetails.length ? line.taxDetails.map(tax => <div key={tax.id} className="expense-tax-row"><Select ariaLabel={`Tipo de impuesto concepto ${index + 1}`} value={tax.kind} onValueChange={value => updateExpenseTax(line.id, tax.id, { kind: value as ExpenseTax["kind"] })} options={[{ value: "transferred", label: "Traslado" }, { value: "withheld", label: "Retención" }]} /><Select ariaLabel={`Impuesto concepto ${index + 1}`} value={tax.taxCode} onValueChange={value => updateExpenseTax(line.id, tax.id, { taxCode: value })} options={TAX_CODES} /><Select ariaLabel={`Factor concepto ${index + 1}`} value={tax.factorType} onValueChange={value => updateExpenseTax(line.id, tax.id, { factorType: value })} options={TAX_FACTORS} /><Input aria-label={`Base impuesto concepto ${index + 1}`} type="number" min="0" step="0.000001" placeholder="Base" value={tax.base} onChange={event => updateExpenseTax(line.id, tax.id, { base: event.target.value })} /><Input aria-label={`Tasa impuesto concepto ${index + 1}`} type="number" min="0" step="0.000001" placeholder="Tasa" disabled={tax.factorType === "Exento"} value={tax.rate} onChange={event => updateExpenseTax(line.id, tax.id, { rate: event.target.value })} /><Input aria-label={`Importe impuesto concepto ${index + 1}`} type="number" min="0" step="0.000001" placeholder="Importe" disabled={tax.factorType === "Exento"} value={tax.amount} onChange={event => updateExpenseTax(line.id, tax.id, { amount: event.target.value })} /><Button type="button" size="sm" onClick={() => updateExpenseLine(line.id, { taxDetails: line.taxDetails.filter(item => item.id !== tax.id) })}><Trash2 size={14} /></Button></div>) : <p>Sin impuestos desglosados.</p>}</section></article>)}</section>}
      <div className="purchase-order-actions"><Button disabled={busy} onClick={() => setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={busy} disabled={!draft.folio.trim() || draft.sourceKind === "receipt" && !candidate || draft.sourceKind === "expense" && !draft.supplierId}>Guardar borrador</Button></div>
    </form>}</Drawer>

    <Drawer open={Boolean(detail)} onOpenChange={open => !open && !busy && setDetail(null)} title={detail ? `Factura ${[detail.series, detail.folio].filter(Boolean).join("-")}` : "Factura"} className="purchase-order-detail-drawer">{detail && <div className="purchase-order-detail supplier-invoice-detail">
      <header><div><InvoiceBadge status={detail.status} /> <Badge tone={detail.source_kind === "receipt" ? "info" : "neutral"}>{detail.source_kind === "receipt" ? "Contra recepción" : "Gasto/servicio"}</Badge>{detail.differences.length > 0 && <Badge tone={detail.differences_authorized_at ? "success" : "warning"}>{detail.differences_authorized_at ? "Diferencias autorizadas" : "Diferencias pendientes"}</Badge>}</div><strong>{money(detail.total, detail.currency_code)}</strong></header>
      <dl><div><dt>Proveedor</dt><dd>{detail.supplier.display_name} · {detail.supplier.code}</dd></div><div><dt>Origen</dt><dd>{detail.purchase_order ? `OC ${detail.purchase_order.folio} · ${detail.receipts.map(item => item.folio).join(", ")}` : "Gasto o servicio aprobado sin recepción"}</dd></div><div><dt>Emisión / vencimiento</dt><dd>{date(detail.issued_date)} / {date(detail.due_date)}</dd></div><div><dt>Moneda / tipo de cambio</dt><dd>{detail.currency_code} · {detail.exchange_rate} → {detail.base_currency_code} ({money(detail.base_total, detail.base_currency_code)})</dd></div><div><dt>CxP</dt><dd>{detail.payable ? `${money(detail.payable.outstanding_amount, detail.currency_code)} · ${conditionLabel(detail.payable.condition)}` : "No generada mientras sea borrador"}</dd></div></dl>
      {detail.source_kind === "receipt" ? <PagedCollection items={detail.lines} resetKey={detail.id} label="partidas">{visibleLines=><Table><thead><tr><th>Recepción / partida</th><th className="number-cell">Ordenada</th><th className="number-cell">Recibida</th><th className="number-cell">Previamente facturada</th><th className="number-cell">Actual</th>{canCost && <><th className="number-cell">Costo OC</th><th className="number-cell">Costo recibido</th></>}<th className="number-cell">Precio factura</th><th>Diferencias</th></tr></thead><tbody>{visibleLines.map(line => <tr key={line.id}><td><strong>{line.purchase_receipt_folio} · #{line.line_number}</strong><small>{line.description}</small></td><td className="number-cell">{line.ordered_quantity}</td><td className="number-cell">{line.received_quantity}</td><td className="number-cell">{line.previously_invoiced}</td><td className="number-cell">{line.quantity}</td>{canCost && <><td className="number-cell">{money(line.order_unit_cost, detail.currency_code)}</td><td className="number-cell">{money(line.received_unit_cost, detail.currency_code)}</td></>}<td className="number-cell">{money(line.invoiced_unit_price, detail.currency_code)}</td><td>{line.differences.length ? <Badge tone="warning">Visible</Badge> : <Badge tone="success">Conciliada</Badge>}</td></tr>)}</tbody></Table>}</PagedCollection> : <PagedCollection items={detail.expense_lines} resetKey={detail.id} label="conceptos fiscales">{visibleLines=><Table><thead><tr><th>Concepto fiscal</th><th>Cantidad / unidad</th><th>Distribución interna</th><th className="number-cell">Subtotal</th><th className="number-cell">Traslados</th><th className="number-cell">Retenciones</th><th className="number-cell">Total</th></tr></thead><tbody>{visibleLines.map(line => <tr key={line.id}><td><strong>{line.product_service_code ?? "Sin clave SAT"}</strong><small>{line.description} · Objeto {line.tax_object_code ?? "—"}</small></td><td>{line.quantity}<small>{line.unit_code ?? "—"} · {line.unit_name ?? "Sin unidad"}</small></td><td>{line.expense_category ?? "Sin categoría"}<small>{[line.cost_center_reference, line.project_reference].filter(Boolean).join(" · ") || "Sin centro/proyecto"}</small></td><td className="number-cell">{money(line.subtotal - line.discount_amount, detail.currency_code)}</td><td className="number-cell">{money(line.tax_amount, detail.currency_code)}</td><td className="number-cell">{money(line.withheld_tax_amount, detail.currency_code)}</td><td className="number-cell"><strong>{money(line.total, detail.currency_code)}</strong></td></tr>)}</tbody></Table>}</PagedCollection>}

      <section className="invoice-document-dossier"><header><div><h3>Expediente fiscal</h3><p>La validación local compara XML, proveedor, UUID, moneda, fecha y total. El estatus SAT exige evidencia separada.</p></div>{canDocuments && <><input ref={fileInput} hidden type="file" accept=".xml,.pdf,application/xml,text/xml,application/pdf" onChange={event => event.target.files?.[0] && void attachDocument(event.target.files[0])} /><Button size="sm" loading={busy} onClick={() => fileInput.current?.click()}><Upload size={14} /> Adjuntar XML/PDF</Button></>}</header>
        {detail.documents.length ? <div className="invoice-document-list">{detail.documents.map(document => <article key={document.id}><FileText size={18} /><span><strong>{document.original_file_name}</strong><small>{document.document_role === "cfdi_xml" ? "XML CFDI" : "Representación PDF"} · {new Date(document.created_at).toLocaleString("es-MX")}</small></span><Badge tone={document.validation_status === "mismatch" || document.validation_status === "unreadable" ? "danger" : document.validation_status === "verified_local" ? "success" : "neutral"}>{document.validation_status === "verified_local" ? "Coincide" : document.validation_status === "mismatch" ? `${document.validation_issues.length} diferencias` : document.validation_status === "unreadable" ? "No legible" : "Adjunto"}</Badge>{document.document_role === "cfdi_xml" && <Badge tone={document.sat_status === "valid" ? "success" : document.sat_status === "cancelled" ? "danger" : "neutral"}>SAT: {document.sat_status === "not_checked" ? "sin verificar" : document.sat_status === "valid" ? "vigente" : document.sat_status === "cancelled" ? "cancelado" : "no encontrado"}</Badge>}<Button size="sm" onClick={() => void downloadDocument(document)}>Abrir</Button></article>)}</div> : <p className="invoice-document-empty">Aún no hay XML ni PDF en el expediente.</p>}
        {canVerifySat && detail.documents.some(item => item.document_role === "cfdi_xml") && <div className="sat-verification-actions"><a href="https://verificacfdi.facturaelectronica.sat.gob.mx/" target="_blank" rel="noreferrer">Verificar en SAT <ExternalLink size={13} /></a><Button size="sm" onClick={() => setAction({ kind: "sat", reason: "", amount: "", series: "", folio: "", satStatus: "valid" })}>Registrar resultado</Button></div>}
      </section>

      {detail.payable && <section className="purchase-order-history"><h3>Cuentas por pagar y ajustes</h3><p>Importe original {money(detail.payable.original_amount, detail.currency_code)} · saldo {money(detail.payable.outstanding_amount, detail.currency_code)} · {conditionLabel(detail.payable.condition)}.</p>{detail.payable.adjustments.map(item => <article key={item.id}><span><strong>{item.adjustment_type === "credit_note" ? "Nota de crédito" : "Reversa"} · {money(item.amount, detail.currency_code)}</strong><small>{new Date(item.occurred_at).toLocaleString("es-MX")}</small></span><p>{item.reason ?? "Sin motivo"}</p></article>)}</section>}
      <section className="purchase-order-history"><h3>Historial auditado</h3><PagedCollection items={detail.audit} resetKey={detail.id} label="eventos">{visibleAudit=><>{visibleAudit.map(item => <article key={item.id}><span><strong>{auditLabel(item.action)}</strong><small>{new Date(item.created_at).toLocaleString("es-MX")}</small></span></article>)}</>}</PagedCollection></section>
      <div className="purchase-order-actions">{canAuthorize && detail.status === "draft" && detail.differences.length > 0 && !detail.differences_authorized_at && <Button onClick={() => setAction({ kind: "authorize", reason: "", amount: "", series: "", folio: "", satStatus: "valid" })}>Autorizar diferencias</Button>}{canExpense && detail.status === "draft" && detail.source_kind === "expense" && !detail.expense_approved_at && <Button onClick={() => setAction({ kind: "approve_expense", reason: "", amount: "", series: "", folio: "", satStatus: "valid" })}>Aprobar gasto</Button>}{canConfirm && detail.status === "draft" && (detail.source_kind === "receipt" || Boolean(detail.expense_approved_at)) && <Button variant="primary" loading={busy} onClick={() => void confirm()}>Confirmar y crear CxP</Button>}{canCredit && detail.status === "confirmed" && detail.payable && detail.payable.outstanding_amount > 0 && <Button onClick={() => setAction({ kind: "credit", reason: "", amount: "", series: "NC", folio: "", satStatus: "valid" })}>Nota de crédito</Button>}{canReverse && detail.status === "confirmed" && detail.payable?.outstanding_amount === detail.payable?.original_amount && <Button variant="danger" onClick={() => setAction({ kind: "reverse", reason: "", amount: "", series: "", folio: "", satStatus: "valid" })}><RotateCcw size={15} /> Revertir</Button>}</div>
    </div>}</Drawer>

    <Modal open={Boolean(action)} onOpenChange={open => !open && !busy && setAction(null)} eyebrow="Procedimiento auditado" title={actionTitle(action?.kind)} description="Se registrarán actor, fecha, motivo y valores originales; no se modificará inventario ni costo." footer={<><Button disabled={busy} onClick={() => setAction(null)}>Cancelar</Button><Button variant={action?.kind === "reverse" ? "danger" : "primary"} loading={busy} disabled={!action?.reason.trim() || action.kind === "credit" && (!action.folio.trim() || Number(action.amount) <= 0)} onClick={() => void submitAction()}>Confirmar</Button></>}>{action && <div className="credit-note-form">{action.kind === "credit" && <div className="purchase-order-grid"><Field label="Serie"><Input value={action.series} onChange={event => setAction({ ...action, series: event.target.value })} /></Field><Field label="Folio"><Input value={action.folio} onChange={event => setAction({ ...action, folio: event.target.value })} /></Field><Field label="Importe"><Input type="number" min="0.000001" max={detail?.payable?.outstanding_amount} step="0.000001" value={action.amount} onChange={event => setAction({ ...action, amount: event.target.value })} /></Field></div>}{action.kind === "sat" && <Field label="Resultado SAT"><Select ariaLabel="Resultado SAT" value={action.satStatus} onValueChange={value => setAction({ ...action, satStatus: value as Action["satStatus"] })} options={[{ value: "valid", label: "Vigente" }, { value: "cancelled", label: "Cancelado" }, { value: "not_found", label: "No encontrado" }]} /></Field>}<label className="operation-reason">{action.kind === "sat" ? "Evidencia o referencia de la consulta" : "Motivo"}<textarea rows={4} value={action.reason} onChange={event => setAction({ ...action, reason: event.target.value })} /></label></div>}</Modal>
  </div>;
}

export function SupplierPayingAccountsView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  return <div className="content-frame supplier-invoice-module">
    <div className="page-heading"><div><span className="eyebrow">Configuración</span><h1>Cuentas bancarias</h1><p>Catálogo de cuentas pagadoras para Compras; no consulta saldos ni credenciales bancarias.</p></div></div>
    <SupplierPaymentsWorkspace companyId={companyId} permissions={permissions} mode="accounts" />
  </div>;
}

function PaymentCalendar({ rows, totals, total, loading, error, view, anchor, page, onPage, onView, onAnchor, onOpen }: {
  rows: PaymentCalendarRow[]; totals: PaymentCalendarTotal[]; total: number; loading: boolean; error: string | null;
  view: PaymentCalendarView; anchor: string; page: number; onPage: React.Dispatch<React.SetStateAction<number>>;
  onView: (view: PaymentCalendarView) => void; onAnchor: (date: string) => void; onOpen: (item: PaymentCalendarRow) => void;
}) {
  const rangeStart = view === "week" ? startOfWeek(anchor) : startOfMonthGrid(anchor);
  const dayCount = view === "week" ? 7 : 42;
  const days = Array.from({ length: dayCount }, (_, index) => addDays(rangeStart, index));
  const shift = (direction: number) => {
    if (view === "week") { onAnchor(addDays(anchor, direction * 7)); return; }
    const next = new Date(`${anchor}T00:00:00Z`); next.setUTCMonth(next.getUTCMonth() + direction); onAnchor(next.toISOString().slice(0, 10));
  };
  const title = view === "week"
    ? `${date(days[0])} – ${date(days[6])}`
    : new Date(`${anchor}T00:00:00`).toLocaleDateString("es-MX", { month: "long", year: "numeric" });
  const weekdayLabels = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];

  return <section className="payment-calendar-workspace">
    <header className="payment-calendar-heading payment-calendar-toolbar"><div className="payment-calendar-navigation">{view !== "table" && <><Button size="sm" aria-label="Periodo anterior" onClick={() => shift(-1)}><ChevronLeft size={16} /></Button><strong>{title}</strong><Button size="sm" aria-label="Periodo siguiente" onClick={() => shift(1)}><ChevronRight size={16} /></Button><Button size="sm" onClick={() => onAnchor(today())}>Hoy</Button></>}</div><div className="payment-calendar-views"><Button size="sm" variant={view === "week" ? "primary" : "secondary"} onClick={() => onView("week")}>Semana</Button><Button size="sm" variant={view === "month" ? "primary" : "secondary"} onClick={() => onView("month")}>Mes</Button><Button size="sm" variant={view === "table" ? "primary" : "secondary"} onClick={() => onView("table")}>Tabla</Button></div></header>
    {view === "table" ? <DataState loading={loading} error={error} hasData={rows.length} empty="No hay CxP con vencimiento en este periodo."><><Table><thead><tr><th>Vencimiento</th><th>Proveedor</th><th>Factura</th><th>Moneda</th><th>Estado</th><th className="number-cell">Saldo</th></tr></thead><tbody>{rows.map(item => <InteractiveTableRow key={item.id} className="payment-calendar-table-row" label={`Abrir cuenta por pagar ${item.invoice_number} de ${item.supplier_name}`} onActivate={() => onOpen(item)}><td>{date(item.due_date)}</td><td><strong>{item.supplier_name}</strong><small>{item.supplier_code}</small></td><td><strong>{item.invoice_number}</strong>{item.payment_reference && <small>Pago {item.payment_reference}</small>}</td><td><Badge tone="info">{item.currency_code}</Badge></td><td><PaymentCalendarBadge item={item} /></td><td className="number-cell"><strong>{money(item.outstanding_amount, item.currency_code)}</strong></td></InteractiveTableRow>)}</tbody></Table><Pagination page={page} total={total} setPage={onPage} /></></DataState> : <div className="payment-calendar-shell">
      <div className="payment-calendar-grid payment-calendar-weekdays">{weekdayLabels.map(label => <span key={label}>{label}</span>)}</div>
      <div className={`payment-calendar-grid is-${view}`}>
        {days.map(day => {
          const dayRows = rows.filter(item => item.due_date === day);
          const dayTotals = totals.filter(item => item.due_date === day);
          const visibleLimit = view === "week" ? 8 : 3;
          const hiddenCount = Math.max(0, dayTotals.reduce((sum, item) => sum + Number(item.document_count), 0) - Math.min(dayRows.length, visibleLimit));
          const outsideMonth = view === "month" && day.slice(0, 7) !== anchor.slice(0, 7);
          return <article key={day} className={`${outsideMonth ? "is-outside" : ""} ${day === today() ? "is-today" : ""}`}><header><strong>{Number(day.slice(8, 10))}</strong>{day === today() && <span>Hoy</span>}</header><div className="payment-calendar-day-items">{dayRows.slice(0, visibleLimit).map(item => <button key={item.id} className={`is-${item.state}`} onClick={() => onOpen(item)}><span><strong>{item.supplier_name}</strong><small>{item.invoice_number}</small></span><b>{money(item.outstanding_amount, item.currency_code)}</b><PaymentCalendarBadge item={item} /></button>)}{hiddenCount > 0 && <small className="payment-calendar-more">+{hiddenCount} CxP; consulta la tabla</small>}</div>{dayTotals.length > 0 && <footer>{dayTotals.map(item => <span key={item.currency_code}><b>{item.currency_code}</b> {money(item.outstanding_amount, item.currency_code)} <small>· {item.document_count}</small></span>)}</footer>}</article>;
        })}
      </div>
      {loading && <div className="payment-calendar-overlay">Cargando vencimientos…</div>}
      {error && <div className="payment-calendar-overlay is-error">{error}</div>}
      {!loading && !error && total === 0 && <div className="payment-calendar-empty">Sin CxP con vencimiento en este periodo.</div>}
    </div>}
    <div className="payment-calendar-legend"><span className="is-overdue">Vencida</span><span className="is-today">Vence hoy</span><span className="is-upcoming">Próxima</span><span className="is-future">Futura</span><span className="is-scheduled">Programada / aprobada</span></div>
  </section>;
}

function SupplierPaymentsWorkspace({ companyId, permissions, mode, initialPaymentId = null, onInitialPaymentOpened }: { companyId: string; permissions: string[]; mode: "payments" | "accounts"; initialPaymentId?: string | null; onInitialPaymentOpened?: () => void }) {
  const { toast } = useToast();
  const keys = useRef(new OperationIdempotencyKeys());
  const bankReceiptInput = useRef<HTMLInputElement>(null);
  const repInput = useRef<HTMLInputElement>(null);
  const [payments, setPayments] = useState<SupplierPaymentRow[]>([]);
  const [approved, setApproved] = useState<ProposalRow[]>([]);
  const [approvedTotal, setApprovedTotal] = useState(0);
  const [approvedPage, setApprovedPage] = useState(1);
  const [accounts, setAccounts] = useState<PayingAccount[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const [busy, setBusy] = useState(false);
  const [accountDraft, setAccountDraft] = useState<{ id: string | null; bankName: string; alias: string; currencyCode: string; last4: string; isActive: boolean } | null>(null);
  const [confirmDraft, setConfirmDraft] = useState<{ proposal: ProposalRow; accountId: string; effectiveDate: string; paymentMethod: string; reference: string } | null>(null);
  const [paymentDetail, setPaymentDetail] = useState<SupplierPaymentDetail | null>(null);
  const [reversalReason, setReversalReason] = useState<string | null>(null);
  const [repSatDraft, setRepSatDraft] = useState<{ documentId: string; status: "valid" | "cancelled" | "not_found"; evidence: string } | null>(null);
  const canManageAccounts = permissions.includes("manage_supplier_paying_accounts");
  const canConfirm = permissions.includes("confirm_supplier_payments");
  const canReverse = permissions.includes("reverse_supplier_payments");
  const canManageDocuments = permissions.includes("manage_supplier_payment_documents");
  const canVerifyRepSat = permissions.includes("verify_supplier_payment_rep_sat");

  const load = useCallback(async () => {
    setLoading(true); setError(null);
    const client = getSupabaseClient();
    if (mode === "accounts") {
      const { data, error: rpcError } = await client.rpc("search_supplier_paying_accounts", { p_company_id: companyId, p_currency_code: null, p_active_only: false });
      if (!rpcError) { setAccounts(((data as { items?: PayingAccount[] } | null)?.items ?? [])); setTotal(((data as { items?: PayingAccount[] } | null)?.items ?? []).length); }
      setError(rpcError ? "No se pudieron cargar las cuentas pagadoras." : null);
    } else {
      const [paymentResult, proposalResult, accountResult] = await Promise.all([
        client.rpc("search_supplier_payments", { p_company_id: companyId, p_query: query || null, p_status: status === "all" ? null : status, p_supplier_id: null, p_currency_code: null, p_page: page, p_page_size: PAGE_SIZE }),
        client.rpc("search_supplier_payment_proposals", { p_company_id: companyId, p_status: "approved", p_supplier_id: null, p_currency_code: null, p_page: approvedPage, p_page_size: PAGE_SIZE }),
        client.rpc("search_supplier_paying_accounts", { p_company_id: companyId, p_currency_code: null, p_active_only: true }),
      ]);
      const paymentData = paymentResult.data as { items?: SupplierPaymentRow[]; pagination?: { total: number } } | null;
      const proposalData = proposalResult.data as { items?: ProposalRow[]; pagination?: { total: number } } | null;
      if (!paymentResult.error && !proposalResult.error && !accountResult.error) {
        setPayments(paymentData?.items ?? []); setTotal(paymentData?.pagination?.total ?? 0);
        setApproved(proposalData?.items ?? []); setApprovedTotal(proposalData?.pagination?.total ?? 0);
        setAccounts(((accountResult.data as { items?: PayingAccount[] } | null)?.items ?? []));
      }
      setError(paymentResult.error || proposalResult.error || accountResult.error ? "No se pudieron cargar los pagos a proveedores." : null);
    }
    setLoading(false);
  }, [approvedPage, companyId, mode, page, query, status]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);

  async function saveAccount() {
    if (!accountDraft || !accountDraft.bankName.trim() || !accountDraft.alias.trim() || !/^[A-Z]{3}$/.test(accountDraft.currencyCode) || !/^[0-9A-Z]{4}$/.test(accountDraft.last4)) return;
    setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("save_supplier_paying_account", { p_company_id: companyId, p_account_id: accountDraft.id, p_bank_name: accountDraft.bankName, p_alias: accountDraft.alias, p_currency_code: accountDraft.currencyCode, p_account_last4: accountDraft.last4, p_is_active: accountDraft.isActive });
    setBusy(false);
    if (rpcError) { toast({ title: "No se guardó la cuenta", description: rpcError.message, tone: "error" }); return; }
    toast({ title: "Cuenta pagadora guardada", description: "Solo se conservaron banco, alias, moneda y terminación enmascarada.", tone: "success" }); setAccountDraft(null); await load();
  }

  async function openApprovedProposal(proposal: ProposalRow) {
    setBusy(true);
    const { data, error: rpcError } = await getSupabaseClient().rpc("get_supplier_payment_by_proposal", { p_company_id: companyId, p_proposal_id: proposal.id });
    setBusy(false);
    if (rpcError) { toast({ title: "No se validó la propuesta", description: rpcError.message, tone: "error" }); return; }
    if (data) { setPaymentDetail(data as SupplierPaymentDetail); return; }
    const compatible = accounts.filter(account => account.is_active && account.currency_code === proposal.currency_code);
    setConfirmDraft({ proposal, accountId: compatible[0]?.id ?? "", effectiveDate: today(), paymentMethod: "", reference: "" });
  }

  async function confirmPayment() {
    if (!confirmDraft || !confirmDraft.accountId || !confirmDraft.paymentMethod.trim() || !confirmDraft.reference.trim()) return;
    const fingerprint = JSON.stringify(confirmDraft); setBusy(true);
    const { data, error: rpcError } = await getSupabaseClient().rpc("confirm_supplier_payment", { p_company_id: companyId, p_proposal_id: confirmDraft.proposal.id, p_paying_account_id: confirmDraft.accountId, p_effective_date: confirmDraft.effectiveDate, p_payment_method: confirmDraft.paymentMethod, p_reference: confirmDraft.reference, p_client_request_id: keys.current.get("supplier-payment-confirm", fingerprint) });
    setBusy(false);
    if (rpcError) { toast({ title: "No se confirmó el pago", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear("supplier-payment-confirm"); const id = (data as { id: string }).id; setConfirmDraft(null);
    toast({ title: "Pago confirmado", description: "Las aplicaciones redujeron las CxP; el pago quedó confirmado y no conciliado.", tone: "success" }); await load(); await openPayment(id);
  }

  async function openPayment(id: string) {
    const { data, error: rpcError } = await getSupabaseClient().rpc("get_supplier_payment_detail", { p_company_id: companyId, p_payment_id: id });
    if (rpcError) toast({ title: "No se abrió el pago", description: rpcError.message, tone: "error" }); else setPaymentDetail(data as SupplierPaymentDetail);
  }

  useEffect(() => {
    if (mode !== "payments" || !initialPaymentId) return;
    void openPayment(initialPaymentId).finally(() => onInitialPaymentOpened?.());
    // The id is an explicit navigation request; consuming it once prevents reopening after refreshes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialPaymentId, mode]);

  async function reversePayment() {
    if (!paymentDetail || !reversalReason?.trim()) return;
    const fingerprint = `${paymentDetail.id}:${reversalReason}`; setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("reverse_supplier_payment", { p_company_id: companyId, p_payment_id: paymentDetail.id, p_reason: reversalReason, p_client_request_id: keys.current.get("supplier-payment-reverse", fingerprint) });
    setBusy(false);
    if (rpcError) { toast({ title: "No se revirtió el pago", description: rpcError.message, tone: "error" }); return; }
    keys.current.clear("supplier-payment-reverse"); const id = paymentDetail.id; setReversalReason(null);
    toast({ title: "Pago revertido", description: "Cada aplicación restauró su CxP exactamente una vez.", tone: "success" }); await load(); await openPayment(id);
  }

  async function attachPaymentDocument(file: File, role: "bank_receipt" | "rep_xml") {
    if (!paymentDetail || paymentDetail.status !== "confirmed") return;
    const isRepXml = ["application/xml", "text/xml"].includes(file.type) || file.name.toLowerCase().endsWith(".xml");
    const allowedReceipt = ["application/pdf", "image/jpeg", "image/png"].includes(file.type);
    const sizeLimit = role === "rep_xml" ? 5 * 1024 * 1024 : 10 * 1024 * 1024;
    if (file.size < 1 || file.size > sizeLimit || role === "rep_xml" && !isRepXml || role === "bank_receipt" && !allowedReceipt) {
      toast({ title: "Archivo no permitido", description: role === "rep_xml" ? "El REP debe ser XML y pesar hasta 5 MB." : "El comprobante debe ser PDF, JPEG o PNG y pesar hasta 10 MB.", tone: "error" }); return;
    }
    setBusy(true);
    try {
      const bytes = await file.arrayBuffer();
      const sha256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map(value => value.toString(16).padStart(2, "0")).join("");
      const client = getSupabaseClient();
      const { data: duplicateData, error: duplicateError } = await client.rpc("check_supplier_payment_document_duplicate", { p_company_id: companyId, p_sha256: sha256 });
      if (duplicateError) throw duplicateError;
      const duplicate = duplicateData as { duplicate?: boolean; payment_id?: string; document_role?: string } | null;
      if (duplicate?.duplicate) {
        if (duplicate.payment_id === paymentDetail.id && duplicate.document_role === role) toast({ title: "Archivo ya adjuntado", description: "El SHA-256 coincide con la evidencia existente; no se creó un duplicado.", tone: "success" });
        else toast({ title: "Archivo duplicado", description: "El mismo contenido ya pertenece a otro expediente de pago.", tone: "error" });
        return;
      }
      if (role === "rep_xml") parseRep(new TextDecoder().decode(bytes));
      const mimeType = role === "rep_xml" ? (file.type || "application/xml") : file.type;
      const extension = role === "rep_xml" ? "xml" : mimeType === "application/pdf" ? "pdf" : mimeType === "image/png" ? "png" : "jpg";
      const path = `${companyId}/${sha256}.${extension}`;
      const { error: uploadError } = await client.storage.from("supplier-payment-documents").upload(path, file, { contentType: mimeType, upsert: false });
      if (uploadError && !/already exists|duplicate/i.test(uploadError.message)) throw uploadError;
      const registration = role === "rep_xml"
        ? await client.rpc("register_supplier_payment_rep_xml", { p_company_id: companyId, p_payment_id: paymentDetail.id, p_original_file_name: file.name, p_storage_path: path, p_mime_type: mimeType, p_size_bytes: file.size, p_sha256: sha256, p_file_base64: arrayBufferToBase64(bytes) })
        : await client.rpc("register_supplier_payment_document", { p_company_id: companyId, p_payment_id: paymentDetail.id, p_document_role: role, p_original_file_name: file.name, p_storage_path: path, p_mime_type: mimeType, p_size_bytes: file.size, p_sha256: sha256, p_extracted_data: {} });
      const { data, error: rpcError } = registration;
      if (rpcError) throw rpcError;
      const result = data as { status?: string; issues?: unknown[] };
      toast({ title: role === "rep_xml" ? result.status === "verified_local" ? "REP recibido y validado" : "REP recibido con diferencias" : "Comprobante bancario adjuntado", description: role === "rep_xml" ? `${result.issues?.length ?? 0} diferencias locales. La vigencia SAT se registra por separado.` : "El archivo quedó privado, auditado e inmutable.", tone: result.status === "mismatch" ? "error" : "success" });
      await openPayment(paymentDetail.id); await load();
    } catch (caught) {
      toast({ title: "No se adjuntó el archivo", description: caught instanceof Error ? caught.message : "No fue posible conservar la evidencia.", tone: "error" });
    } finally {
      setBusy(false); if (bankReceiptInput.current) bankReceiptInput.current.value = ""; if (repInput.current) repInput.current.value = "";
    }
  }

  async function openPaymentDocument(document: PaymentDocument) {
    const { data, error: storageError } = await getSupabaseClient().storage.from("supplier-payment-documents").createSignedUrl(document.download_path, 60);
    if (storageError) toast({ title: "No se abrió el documento", description: storageError.message, tone: "error" }); else window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }

  async function recordRepSatVerification() {
    if (!paymentDetail || !repSatDraft?.evidence.trim()) return;
    setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc("record_supplier_payment_rep_sat_verification", { p_company_id: companyId, p_document_id: repSatDraft.documentId, p_status: repSatDraft.status, p_checked_at: new Date().toISOString(), p_evidence: { reference: repSatDraft.evidence.trim(), source: "SAT" } });
    setBusy(false);
    if (rpcError) { toast({ title: "No se registró la verificación SAT", description: rpcError.message, tone: "error" }); return; }
    const paymentId = paymentDetail.id; setRepSatDraft(null); toast({ title: "Verificación SAT registrada", description: "La evidencia oficial quedó separada de la validación local del XML.", tone: "success" }); await openPayment(paymentId); await load();
  }

  if (mode === "accounts") return <section className="supplier-payments-workspace"><header className="supplier-payments-heading"><div><h2>Cuentas bancarias pagadoras</h2><p>No se almacenan credenciales ni se consultan saldos bancarios.</p></div>{canManageAccounts && <Button variant="primary" onClick={() => setAccountDraft({ id: null, bankName: "", alias: "", currencyCode: "MXN", last4: "", isActive: true })}>Nueva cuenta</Button>}</header><DataState loading={loading} error={error} hasData={accounts.length} empty="No hay cuentas pagadoras registradas."><Table><thead><tr><th>Alias</th><th>Banco</th><th>Moneda</th><th>Terminación</th><th>Estado</th></tr></thead><tbody>{accounts.map(account => <InteractiveTableRow key={account.id} disabled={!canManageAccounts} className={canManageAccounts ? "purchase-order-row" : ""} label={`Editar cuenta pagadora ${account.alias}`} onActivate={() => setAccountDraft({ id: account.id, bankName: account.bank_name, alias: account.alias, currencyCode: account.currency_code, last4: account.account_last4, isActive: account.is_active })}><td><strong>{account.alias}</strong></td><td>{account.bank_name}</td><td><Badge tone="info">{account.currency_code}</Badge></td><td>{account.masked_ending}</td><td><Badge tone={account.is_active ? "success" : "neutral"}>{account.is_active ? "Activa" : "Inactiva"}</Badge></td></InteractiveTableRow>)}</tbody></Table></DataState><Modal open={Boolean(accountDraft)} onOpenChange={open => !open && !busy && setAccountDraft(null)} eyebrow="Catálogo pagador" title={accountDraft?.id ? "Editar cuenta pagadora" : "Nueva cuenta pagadora"} description="Captura únicamente datos descriptivos y los últimos cuatro caracteres." footer={<><Button disabled={busy} onClick={() => setAccountDraft(null)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!accountDraft?.bankName.trim() || !accountDraft?.alias.trim() || accountDraft.currencyCode.length !== 3 || accountDraft.last4.length !== 4} onClick={() => void saveAccount()}>Guardar</Button></>}>{accountDraft && <div className="paying-account-form"><Field label="Banco"><Input value={accountDraft.bankName} onChange={event => setAccountDraft({ ...accountDraft, bankName: event.target.value })} /></Field><Field label="Alias"><Input value={accountDraft.alias} onChange={event => setAccountDraft({ ...accountDraft, alias: event.target.value })} /></Field><Field label="Moneda"><Input maxLength={3} value={accountDraft.currencyCode} onChange={event => setAccountDraft({ ...accountDraft, currencyCode: event.target.value.replace(/[^a-zA-Z]/g, "").toUpperCase() })} /></Field><Field label="Últimos 4"><Input maxLength={4} value={accountDraft.last4} onChange={event => setAccountDraft({ ...accountDraft, last4: event.target.value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase() })} /></Field><label className="checkbox-label"><input type="checkbox" checked={accountDraft.isActive} onChange={event => setAccountDraft({ ...accountDraft, isActive: event.target.checked })} /> Cuenta activa</label></div>}</Modal></section>;

  return <section className="supplier-payments-workspace"><header className="supplier-payments-heading"><div><h2>Pagos a proveedores</h2><p>Solo nacen desde propuestas aprobadas y permanecen sin conciliación bancaria.</p></div></header>{canConfirm && <section className="approved-payment-proposals"><header><h3>Propuestas aprobadas pendientes de pago</h3><p>Instrucciones autorizadas que todavía deben convertirse en un pago real.</p></header><DataState loading={loading} error={null} hasData={approved.length} empty="No hay propuestas aprobadas disponibles."><Table><thead><tr><th>Propuesta</th><th>Proveedor</th><th>CxP</th><th className="number-cell">Importe</th><th></th></tr></thead><tbody>{approved.map(proposal => <tr key={proposal.id}><td><strong>{proposal.id.slice(0, 8).toUpperCase()}</strong><small>{proposal.currency_code}</small></td><td>{proposal.supplier_name}<small>{proposal.supplier_code}</small></td><td>{proposal.line_count}</td><td className="number-cell"><strong>{money(proposal.total_proposed, proposal.currency_code)}</strong></td><td><Button size="sm" loading={busy} onClick={() => void openApprovedProposal(proposal)}>Registrar/ver pago</Button></td></tr>)}</tbody></Table><Pagination page={approvedPage} total={approvedTotal} setPage={setApprovedPage} /></DataState></section>}<div className="supplier-payments-list-heading"><h3>Pagos registrados y expediente REP</h3><p>Pagos reales ya confirmados; aquí se consultan sus aplicaciones, comprobantes y REP.</p></div><DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Proveedor o referencia" results={total} activeFilters={status === "all" ? 0 : 1} onClear={() => setStatus("all")} filters={<Select ariaLabel="Estado del pago" value={status} onValueChange={value => { setStatus(value); setPage(1); }} options={[{ value: "all", label: "Todos" }, { value: "confirmed", label: "Confirmados" }, { value: "reversed", label: "Revertidos" }]} />} /><DataState loading={loading} error={error} hasData={payments.length} empty="No hay pagos con estos filtros."><Table><thead><tr><th>Referencia</th><th>Proveedor</th><th>Fecha efectiva</th><th>Cuenta</th><th>Estado</th><th>REP</th><th>Aplicaciones</th><th className="number-cell">Importe</th></tr></thead><tbody>{payments.map(payment => <InteractiveTableRow key={payment.id} className="purchase-order-row" label={`Abrir pago ${payment.reference}`} onActivate={() => void openPayment(payment.id)}><td><strong>{payment.reference}</strong><small>{payment.payment_method}</small></td><td><strong>{payment.supplier_name}</strong><small>{payment.supplier_code}</small></td><td>{date(payment.effective_date)}</td><td>{payment.account_alias}<small>{payment.bank_name} · {payment.masked_ending}</small></td><td><PaymentBadge status={payment.status} /><small>Sin conciliación</small></td><td><RepBadge status={payment.rep_status} /></td><td>{payment.application_count}</td><td className="number-cell"><strong>{money(payment.total_amount, payment.currency_code)}</strong></td></InteractiveTableRow>)}</tbody></Table><Pagination page={page} total={total} setPage={setPage} /></DataState>
    <Modal open={Boolean(confirmDraft)} onOpenChange={open => !open && !busy && setConfirmDraft(null)} eyebrow="Desde propuesta aprobada" title="Confirmar pago" description="Al confirmar se crearán aplicaciones inmutables y se reducirán exclusivamente los saldos de CxP." footer={<><Button disabled={busy} onClick={() => setConfirmDraft(null)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!confirmDraft?.accountId || !confirmDraft?.paymentMethod.trim() || !confirmDraft?.reference.trim()} onClick={() => void confirmPayment()}>Confirmar pago</Button></>}>{confirmDraft && <div className="supplier-payment-form"><div className="proposal-scope"><div><span>Proveedor</span><strong>{confirmDraft.proposal.supplier_name}</strong></div><div><span>Moneda</span><strong>{confirmDraft.proposal.currency_code}</strong></div><div><span>Importe</span><strong>{money(confirmDraft.proposal.total_proposed, confirmDraft.proposal.currency_code)}</strong></div></div><Field label="Fecha efectiva"><Input type="date" value={confirmDraft.effectiveDate} onChange={event => setConfirmDraft({ ...confirmDraft, effectiveDate: event.target.value })} /></Field><Field label="Cuenta pagadora"><Select ariaLabel="Cuenta pagadora" value={confirmDraft.accountId} onValueChange={value => setConfirmDraft({ ...confirmDraft, accountId: value })} options={[{ value: "", label: "Selecciona cuenta" }, ...accounts.filter(account => account.currency_code === confirmDraft.proposal.currency_code).map(account => ({ value: account.id, label: `${account.alias} · ${account.bank_name} · ${account.masked_ending}` }))]} /></Field><Field label="Forma de pago SAT"><Select ariaLabel="Forma de pago SAT" value={confirmDraft.paymentMethod} onValueChange={value => setConfirmDraft({ ...confirmDraft, paymentMethod: value })} options={[{ value: "", label: "Selecciona forma" }, ...PAYMENT_FORMS]} /></Field><Field label="Referencia"><Input value={confirmDraft.reference} onChange={event => setConfirmDraft({ ...confirmDraft, reference: event.target.value })} /></Field>{!accounts.some(account => account.currency_code === confirmDraft.proposal.currency_code) && <p className="proposal-no-impact">No existe una cuenta activa en {confirmDraft.proposal.currency_code}. Regístrala antes de confirmar.</p>}</div>}</Modal>
    <Drawer open={Boolean(paymentDetail)} onOpenChange={open => !open && !busy && setPaymentDetail(null)} title={paymentDetail ? `Pago ${paymentDetail.reference}` : "Pago"} className="purchase-order-detail-drawer payment-proposal-drawer">
      {paymentDetail && <div className="purchase-order-detail">
        <header><div><PaymentBadge status={paymentDetail.status} /> <Badge tone="warning">No conciliado</Badge> <RepBadge status={paymentDetail.rep_status} /></div><strong>{money(paymentDetail.total_amount, paymentDetail.currency_code)}</strong></header>
        <dl><div><dt>Proveedor</dt><dd>{paymentDetail.supplier.display_name} · {paymentDetail.supplier.code}</dd></div><div><dt>Fecha efectiva</dt><dd>{date(paymentDetail.effective_date)}</dd></div><div><dt>Cuenta pagadora</dt><dd>{paymentDetail.paying_account.alias} · {paymentDetail.paying_account.bank_name} · {paymentDetail.paying_account.masked_ending}</dd></div><div><dt>Forma / referencia</dt><dd>{paymentDetail.payment_method} · {paymentDetail.reference}</dd></div></dl>
        <PagedCollection items={paymentDetail.applications} resetKey={paymentDetail.id} label="aplicaciones">{visibleApplications=><Table><thead><tr><th>Factura</th><th>Método</th><th>UUID</th><th className="number-cell">Saldo anterior</th><th className="number-cell">Aplicado</th><th className="number-cell">Saldo insoluto</th></tr></thead><tbody>{visibleApplications.map(application => <tr key={application.id}><td><strong>{application.invoice_number}</strong><small>{date(application.due_date)}</small></td><td>{application.payment_method_code ?? "Sin clave"}</td><td><small>{application.invoice_uuid ?? "Sin UUID"}</small></td><td className="number-cell">{money(application.balance_before, paymentDetail.currency_code)}</td><td className="number-cell"><strong>{money(application.amount, paymentDetail.currency_code)}</strong></td><td className="number-cell">{money(application.balance_after, paymentDetail.currency_code)}</td></tr>)}</tbody></Table>}</PagedCollection>
        <section className="invoice-document-dossier payment-evidence-dossier"><header><div><h3>Comprobantes y REP</h3><p>Archivos privados e inmutables. La validación local del XML no sustituye la consulta oficial SAT.</p></div>{canManageDocuments && paymentDetail.status === "confirmed" && <div className="payment-evidence-actions"><input ref={bankReceiptInput} hidden type="file" accept="application/pdf,image/jpeg,image/png" onChange={event => event.target.files?.[0] && void attachPaymentDocument(event.target.files[0], "bank_receipt")} /><input ref={repInput} hidden type="file" accept=".xml,application/xml,text/xml" onChange={event => event.target.files?.[0] && void attachPaymentDocument(event.target.files[0], "rep_xml")} /><Button size="sm" loading={busy} onClick={() => bankReceiptInput.current?.click()}><Upload size={14} /> Comprobante</Button><Button size="sm" loading={busy} onClick={() => repInput.current?.click()}><FilePlus2 size={14} /> Recibir REP</Button></div>}</header>
          {paymentDetail.documents.length === 0 ? <p className="invoice-document-empty">Aún no hay evidencia adjunta. Un REP pendiente no revierte ni modifica el pago.</p> : <div className="invoice-document-list">{paymentDetail.documents.map(document => <article key={document.id}><FileText size={17} /><span><strong>{document.original_file_name}</strong><small>{document.document_role === "rep_xml" ? `REP · ${document.fiscal_uuid ?? "UUID no legible"}` : "Comprobante bancario"} · {(document.size_bytes / 1024).toFixed(1)} KB</small></span><Badge tone={document.local_validation_status === "verified_local" ? "success" : document.local_validation_status === "mismatch" ? "danger" : "neutral"}>{document.local_validation_status === "verified_local" ? "Validación local OK" : document.local_validation_status === "mismatch" ? `${document.local_validation_issues.length} diferencias` : "No aplica"}</Badge>{document.document_role === "rep_xml" && <Badge tone={document.sat_verification?.sat_status === "valid" ? "success" : document.sat_verification ? "danger" : "warning"}>{document.sat_verification?.sat_status === "valid" ? "SAT vigente" : document.sat_verification?.sat_status === "cancelled" ? "SAT cancelado" : document.sat_verification?.sat_status === "not_found" ? "SAT no encontrado" : "SAT no consultado"}</Badge>}<Button size="sm" onClick={() => void openPaymentDocument(document)}><ExternalLink size={13} /> Abrir</Button>{canVerifyRepSat && document.document_role === "rep_xml" && <Button size="sm" onClick={() => setRepSatDraft({ documentId: document.id, status: "valid", evidence: "" })}>Verificar SAT</Button>}{document.local_validation_issues.length > 0 && <p className="payment-document-issues">{document.local_validation_issues.map((issue, index) => <span key={`${document.id}-${index}`}>{issue.field}{issue.invoice_uuid ? ` · ${issue.invoice_uuid}` : ""}: esperado {String(issue.expected ?? "—")}, recibido {String(issue.actual ?? "—")}</span>)}</p>}</article>)}</div>}
        </section>
        {paymentDetail.reversal_reason && <section className="proposal-decision-reason"><strong>Motivo de reversa</strong><p>{paymentDetail.reversal_reason}</p></section>}
        <section className="purchase-order-history"><h3>Historial auditado</h3>{paymentDetail.audit.map(item => <article key={item.id}><span><strong>{paymentAuditLabel(item.action)}</strong><small>{new Date(item.created_at).toLocaleString("es-MX")}</small></span></article>)}</section>
        <div className="purchase-order-actions">{canReverse && paymentDetail.status === "confirmed" && <Button variant="danger" onClick={() => setReversalReason("")}><RotateCcw size={15} /> Revertir pago</Button>}</div>
      </div>}
    </Drawer>
    <Modal open={reversalReason !== null} onOpenChange={open => !open && !busy && setReversalReason(null)} eyebrow="Reversa auditada" title="Revertir pago" description="Las aplicaciones permanecerán inmutables y sus importes restaurarán las CxP exactamente una vez." footer={<><Button disabled={busy} onClick={() => setReversalReason(null)}>Cancelar</Button><Button variant="danger" loading={busy} disabled={!reversalReason?.trim()} onClick={() => void reversePayment()}>Confirmar reversa</Button></>}>{reversalReason !== null && <label className="operation-reason">Motivo obligatorio<textarea rows={4} value={reversalReason} onChange={event => setReversalReason(event.target.value)} /></label>}</Modal>
    <Modal open={Boolean(repSatDraft)} onOpenChange={open => !open && !busy && setRepSatDraft(null)} eyebrow="Evidencia oficial separada" title="Registrar consulta SAT del REP" description="Esta captura no recalcula la validación local ni modifica pagos o CxP." footer={<><Button disabled={busy} onClick={() => setRepSatDraft(null)}>Cancelar</Button><Button variant="primary" loading={busy} disabled={!repSatDraft?.evidence.trim()} onClick={() => void recordRepSatVerification()}>Registrar</Button></>}>{repSatDraft && <div className="supplier-payment-form"><Field label="Resultado SAT"><Select ariaLabel="Resultado SAT del REP" value={repSatDraft.status} onValueChange={value => setRepSatDraft({ ...repSatDraft, status: value as typeof repSatDraft.status })} options={[{ value: "valid", label: "Vigente" }, { value: "cancelled", label: "Cancelado" }, { value: "not_found", label: "No encontrado" }]} /></Field><label className="operation-reason">Evidencia o referencia de consulta<textarea rows={4} value={repSatDraft.evidence} onChange={event => setRepSatDraft({ ...repSatDraft, evidence: event.target.value })} /></label></div>}</Modal>
  </section>;
}

function ThreeWay({ candidate, draft, setDraft, canCost }: { candidate: Candidate; draft: Draft; setDraft: (draft: Draft) => void; canCost: boolean }) {
  const [page, setPage] = useState(1);
  const [query, setQuery] = useState("");
  const [onlyExceptions, setOnlyExceptions] = useState(false);
  const isException = (line: InvoiceableLine) => {
    const id = line.purchase_receipt_line_id;
    const quantity = draft.quantities[id];
    return quantity === undefined || quantity === "" || Math.abs(Number(quantity) - Number(line.available_quantity)) > 0.000001
      || Math.abs(Number(draft.prices[id] ?? line.received_unit_cost) - Number(line.received_unit_cost)) > 0.000001
      || Number(draft.discounts[id] ?? 0) !== 0 || Number(draft.taxes[id] ?? 0) !== 0;
  };
  const normalizedQuery = query.trim().toLowerCase();
  const filtered = candidate.lines.filter(line => (!normalizedQuery || `${line.purchase_receipt_folio} ${line.line_number} ${line.description}`.toLowerCase().includes(normalizedQuery)) && (!onlyExceptions || isException(line)));
  const visible = filtered.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);
  const exceptionCount = candidate.lines.filter(isException).length;
  function useReceiptAsBase() {
    setDraft({
      ...draft,
      quantities: { ...draft.quantities, ...Object.fromEntries(candidate.lines.map(line => [line.purchase_receipt_line_id, String(line.available_quantity)])) },
      prices: { ...draft.prices, ...Object.fromEntries(candidate.lines.map(line => [line.purchase_receipt_line_id, String(line.received_unit_cost)])) },
      discounts: { ...draft.discounts, ...Object.fromEntries(candidate.lines.map(line => [line.purchase_receipt_line_id, "0"])) },
      taxes: { ...draft.taxes, ...Object.fromEntries(candidate.lines.map(line => [line.purchase_receipt_line_id, "0"])) },
    });
    setOnlyExceptions(true); setPage(1);
  }
  return <section className="three-way-reconciliation">
    <header><div><strong>Conciliación de tres vías · {candidate.folio}</strong><small>Usa la recepción como base y captura solo diferencias reales. Los totales y límites se validan nuevamente en servidor.</small></div><Badge tone="info">{draft.currencyCode}</Badge></header>
    <DataToolbar search={query} onSearchChange={value => { setQuery(value); setPage(1); }} placeholder="Buscar recepción, partida o descripción" filters={<Button type="button" size="sm" variant={onlyExceptions ? "primary" : "secondary"} onClick={() => { setOnlyExceptions(value => !value); setPage(1); }}>{onlyExceptions ? `Por revisar (${exceptionCount})` : "Mostrar solo por revisar"}</Button>} activeFilters={(query ? 1 : 0) + (onlyExceptions ? 1 : 0)} onClear={() => { setQuery(""); setOnlyExceptions(false); setPage(1); }} results={filtered.length} />
    <div className="supplier-invoice-actions"><Button type="button" variant="secondary" onClick={useReceiptAsBase}>Usar recepción como base</Button><small>Completa cantidad disponible, costo recibido y ceros administrativos en todas las partidas.</small></div>
    <div className="table-wrap"><Table><thead><tr><th>Recepción / partida</th><th className="number-cell">Ordenada</th><th className="number-cell">Recibida</th><th className="number-cell">Facturada</th><th className="number-cell">Disponible</th><th className="number-cell">Actual</th>{canCost && <><th className="number-cell">Costo OC</th><th className="number-cell">Costo recibido</th></>}<th className="number-cell">Precio factura</th><th className="number-cell">Desc.</th><th className="number-cell">Impuesto</th></tr></thead><tbody>{visible.map(line => <tr key={line.purchase_receipt_line_id}><td><strong>{line.purchase_receipt_folio} · #{line.line_number}</strong><small>{line.description}</small></td><td className="number-cell">{line.ordered_quantity}</td><td className="number-cell">{line.received_quantity}</td><td className="number-cell">{line.previously_invoiced}</td><td className="number-cell">{line.available_quantity}</td><td><Input aria-label={`Cantidad ${line.description}`} type="number" min="0" max={line.available_quantity} step="0.000001" value={draft.quantities[line.purchase_receipt_line_id] ?? ""} onChange={event => setDraft({ ...draft, quantities: { ...draft.quantities, [line.purchase_receipt_line_id]: event.target.value } })} /></td>{canCost && <><td className="number-cell">{money(line.order_unit_cost, candidate.currency_code)}</td><td className="number-cell">{money(line.received_unit_cost, candidate.currency_code)}</td></>}<td><Input aria-label={`Precio ${line.description}`} type="number" min="0" step="0.000001" value={draft.prices[line.purchase_receipt_line_id] ?? line.received_unit_cost} onChange={event => setDraft({ ...draft, prices: { ...draft.prices, [line.purchase_receipt_line_id]: event.target.value } })} /></td><td><Input aria-label={`Descuento ${line.description}`} type="number" min="0" step="0.000001" value={draft.discounts[line.purchase_receipt_line_id] ?? "0"} onChange={event => setDraft({ ...draft, discounts: { ...draft.discounts, [line.purchase_receipt_line_id]: event.target.value } })} /></td><td><Input aria-label={`Impuesto ${line.description}`} type="number" min="0" step="0.000001" value={draft.taxes[line.purchase_receipt_line_id] ?? "0"} onChange={event => setDraft({ ...draft, taxes: { ...draft.taxes, [line.purchase_receipt_line_id]: event.target.value } })} /></td></tr>)}</tbody></Table>{!visible.length && <p className="empty-state">No hay partidas por revisar con estos filtros.</p>}</div>
    <Pagination page={page} total={filtered.length} setPage={setPage} />
  </section>;
}

function parseCfdi(xmlText: string): CfdiData {
  const document = new DOMParser().parseFromString(xmlText, "application/xml");
  if (document.querySelector("parsererror")) throw new Error("El XML no es legible.");
  const root = document.documentElement;
  const emitter = [...document.getElementsByTagNameNS("*", "Emisor")][0];
  const receiver = [...document.getElementsByTagNameNS("*", "Receptor")][0];
  const stamp = [...document.getElementsByTagNameNS("*", "TimbreFiscalDigital")][0];
  if (!root || !emitter || !receiver || !stamp) throw new Error("El XML no contiene la estructura CFDI timbrada.");
  const attr = (element: Element, ...names: string[]) => names.map(name => element.getAttribute(name)).find(Boolean) ?? null;
  const concepts = [...document.getElementsByTagNameNS("*", "Concepto")].map((concept): CfdiConcept => {
    const transferred = [...concept.getElementsByTagNameNS("*", "Traslado")].map(tax => ({ kind: "transferred" as const, tax_code: attr(tax, "Impuesto", "impuesto") ?? "", factor_type: attr(tax, "TipoFactor", "tipoFactor") ?? "", rate: attr(tax, "TasaOCuota", "tasaOCuota") ?? "0", base: attr(tax, "Base", "base") ?? "0", amount: attr(tax, "Importe", "importe") ?? "0" }));
    const withheld = [...concept.getElementsByTagNameNS("*", "Retencion")].map(tax => ({ kind: "withheld" as const, tax_code: attr(tax, "Impuesto", "impuesto") ?? "", factor_type: attr(tax, "TipoFactor", "tipoFactor") ?? "Tasa", rate: attr(tax, "TasaOCuota", "tasaOCuota") ?? "0", base: attr(tax, "Base", "base") ?? "0", amount: attr(tax, "Importe", "importe") ?? "0" }));
    return {
      product_service_code: attr(concept, "ClaveProdServ", "claveProdServ") ?? "", identification_number: attr(concept, "NoIdentificacion", "noIdentificacion"),
      quantity: attr(concept, "Cantidad", "cantidad") ?? "0", unit_code: attr(concept, "ClaveUnidad", "claveUnidad") ?? "", unit_name: attr(concept, "Unidad", "unidad"),
      description: attr(concept, "Descripcion", "descripcion") ?? "", unit_value: attr(concept, "ValorUnitario", "valorUnitario") ?? "0", subtotal: attr(concept, "Importe", "importe") ?? "0",
      discount_amount: attr(concept, "Descuento", "descuento") ?? "0", tax_object_code: attr(concept, "ObjetoImp", "objetoImp") ?? "01",
      transferred_tax_amount: String(Number(transferred.reduce((sum, tax) => sum + Number(tax.amount || 0), 0).toFixed(6))),
      withheld_tax_amount: String(Number(withheld.reduce((sum, tax) => sum + Number(tax.amount || 0), 0).toFixed(6))), tax_details: [...transferred, ...withheld],
    };
  });
  return {
    version: attr(root, "Version", "version"), series: attr(root, "Serie", "serie"), folio: attr(root, "Folio", "folio"), issued_at: attr(root, "Fecha", "fecha"), currency: attr(root, "Moneda", "moneda"),
    subtotal: attr(root, "SubTotal", "subTotal"), discount_total: attr(root, "Descuento", "descuento") ?? "0",
    transferred_tax_total: String(Number(concepts.reduce((sum, concept) => sum + Number(concept.transferred_tax_amount), 0).toFixed(6))),
    withheld_tax_total: String(Number(concepts.reduce((sum, concept) => sum + Number(concept.withheld_tax_amount), 0).toFixed(6))), total: attr(root, "Total", "total"),
    document_type: attr(root, "TipoDeComprobante", "tipoDeComprobante"), payment_method_code: attr(root, "MetodoPago", "metodoDePago"), payment_form_code: attr(root, "FormaPago", "formaDePago"),
    issuer_rfc: attr(emitter, "Rfc", "rfc"), issuer_name: attr(emitter, "Nombre", "nombre"), issuer_regime_code: attr(emitter, "RegimenFiscal", "regimenFiscal"),
    receiver_rfc: attr(receiver, "Rfc", "rfc"), receiver_name: attr(receiver, "Nombre", "nombre"), receiver_regime_code: attr(receiver, "RegimenFiscalReceptor", "regimenFiscalReceptor"),
    receiver_postal_code: attr(receiver, "DomicilioFiscalReceptor", "domicilioFiscalReceptor"), cfdi_use_code: attr(receiver, "UsoCFDI", "usoCFDI"), export_code: attr(root, "Exportacion", "exportacion"),
    uuid: attr(stamp, "UUID", "Uuid", "uuid"), concepts,
  };
}

function parseRep(xmlText: string): RepData {
  const document = new DOMParser().parseFromString(xmlText, "application/xml");
  if (document.querySelector("parsererror")) throw new Error("El XML del REP no es legible.");
  const root = document.documentElement;
  const emitter = [...document.getElementsByTagNameNS("*", "Emisor")][0];
  const receiver = [...document.getElementsByTagNameNS("*", "Receptor")][0];
  const stamp = [...document.getElementsByTagNameNS("*", "TimbreFiscalDigital")][0];
  const complement = [...document.getElementsByTagNameNS("*", "Pagos")][0];
  const payments = [...document.getElementsByTagNameNS("*", "Pago")];
  if (!root || !emitter || !receiver || !stamp || !complement) throw new Error("El XML no contiene un CFDI timbrado con complemento de Pagos.");
  if (payments.length !== 1) throw new Error("Satrapy requiere un REP con exactamente un evento Pago para relacionarlo sin ambigüedad.");
  const payment = payments[0];
  const attr = (element: Element | undefined, ...names: string[]) => element ? names.map(name => element.getAttribute(name)).find(value => value !== null) ?? null : null;
  return {
    cfdi_version: attr(root, "Version", "version"), complement_version: attr(complement, "Version", "version"), document_type: attr(root, "TipoDeComprobante", "tipoDeComprobante"),
    currency: attr(root, "Moneda", "moneda"), total: attr(root, "Total", "total"), issued_at: attr(root, "Fecha", "fecha"), uuid: attr(stamp, "UUID", "Uuid", "uuid"),
    issuer_rfc: attr(emitter, "Rfc", "rfc"), receiver_rfc: attr(receiver, "Rfc", "rfc"),
    payment: { date: attr(payment, "FechaPago", "fechaPago"), payment_form: attr(payment, "FormaDePagoP", "formaDePagoP"), currency: attr(payment, "MonedaP", "monedaP"), exchange_rate: attr(payment, "TipoCambioP", "tipoCambioP"), amount: attr(payment, "Monto", "monto") },
    related_documents: [...payment.getElementsByTagNameNS("*", "DoctoRelacionado")].map(related => ({ document_uuid: attr(related, "IdDocumento", "idDocumento"), currency: attr(related, "MonedaDR", "monedaDR"), equivalence: attr(related, "EquivalenciaDR", "equivalenciaDR"), partiality: attr(related, "NumParcialidad", "numParcialidad"), previous_balance: attr(related, "ImpSaldoAnt", "impSaldoAnt"), paid_amount: attr(related, "ImpPagado", "impPagado"), remaining_balance: attr(related, "ImpSaldoInsoluto", "impSaldoInsoluto") })),
  };
}

function arrayBufferToBase64(buffer: ArrayBuffer) {
  const bytes = new Uint8Array(buffer); let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 32768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
  return btoa(binary);
}

function Pagination({ page, total, setPage }: { page: number; total: number; setPage: React.Dispatch<React.SetStateAction<number>> }) { return <DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} showTotal={false} />; }
function InvoiceBadge({ status }: { status: InvoiceStatus }) { return <Badge tone={status === "confirmed" ? "success" : status === "reversed" ? "danger" : "neutral"}>{status === "confirmed" ? "Confirmada" : status === "reversed" ? "Revertida" : "Borrador"}</Badge>; }
function DueBucketBadge({ bucket }: { bucket: DueBucket }) { return <Badge tone={bucket === "overdue" ? "danger" : bucket === "upcoming" ? "warning" : "info"}>{bucket === "overdue" ? "Vencida" : bucket === "upcoming" ? "Próxima" : "Futura"}</Badge>; }
function ProposalBadge({ status }: { status: ProposalStatus }) { return <Badge tone={status === "approved" ? "success" : status === "rejected" ? "danger" : status === "submitted" ? "warning" : status === "cancelled" ? "neutral" : "info"}>{status === "draft" ? "Borrador" : status === "submitted" ? "En aprobación" : status === "approved" ? "Aprobada" : status === "rejected" ? "Rechazada" : "Cancelada"}</Badge>; }
function PaymentCalendarBadge({ item }: { item: PaymentCalendarRow }) {
  const label = item.payment_id ? "Pago confirmado" : item.proposal_status === "approved" ? "Aprobada" : item.proposal_id ? "Programada" : item.state === "overdue" ? "Vencida" : item.state === "due_today" ? "Vence hoy" : item.state === "upcoming" ? "Próxima" : "Futura";
  const tone = item.payment_id || item.proposal_status === "approved" ? "success" : item.proposal_id ? "info" : item.state === "overdue" ? "danger" : item.state === "due_today" || item.state === "upcoming" ? "warning" : "neutral";
  return <Badge tone={tone}>{label}</Badge>;
}
function PaymentBadge({ status }: { status: SupplierPaymentRow["status"] }) { return <Badge tone={status === "confirmed" ? "success" : "danger"}>{status === "confirmed" ? "Confirmado" : "Revertido"}</Badge>; }
function RepBadge({ status }: { status: RepStatus }) { return <Badge tone={status === "received" ? "success" : status === "differences" ? "danger" : status === "pending" ? "warning" : "neutral"}>{status === "received" ? "Recibido" : status === "differences" ? "Con diferencias" : status === "pending" ? "Pendiente" : "No requerido"}</Badge>; }
function conditionLabel(value: string) { return value === "overdue" ? "Vencida" : value === "not_due" ? "No vencida" : value === "settled" ? "Saldada" : "Revertida"; }
function exceptionLabel(value: string) { return value === "duplicate_uuid" ? "UUID duplicado" : value === "duplicate_identity" ? "Identidad documental duplicada" : "Diferencia de conciliación"; }
function actionTitle(value: Action["kind"] | undefined) { return value === "authorize" ? "Autorizar diferencias" : value === "approve_expense" ? "Aprobar factura de gasto" : value === "reverse" ? "Revertir factura" : value === "sat" ? "Registrar verificación SAT" : "Confirmar nota de crédito"; }
function auditLabel(value: string) { return value === "supplier_invoice.draft_created" ? "Borrador creado" : value === "supplier_invoice.draft_updated" ? "Borrador actualizado" : value === "supplier_expense_invoice.draft_created" ? "Borrador de gasto creado" : value === "supplier_expense_invoice.approved" ? "Gasto aprobado" : value === "supplier_invoice.document_attached" ? "Documento adjuntado" : value === "supplier_invoice.sat_verification_recorded" ? "Verificación SAT registrada" : value === "supplier_invoice.differences_authorized" ? "Diferencias autorizadas" : value === "supplier_invoice.confirmed" ? "Factura y CxP confirmadas" : value === "supplier_invoice.reversed" ? "Factura revertida" : value === "supplier_credit_note.confirmed" ? "Nota de crédito confirmada" : value; }
function proposalAuditLabel(value: string) { return value === "supplier_payment_proposal.created" ? "Borrador creado" : value === "supplier_payment_proposal.updated" ? "Borrador actualizado" : value === "supplier_payment_proposal.submitted" ? "Enviada a aprobación" : value === "supplier_payment_proposal.approved" ? "Aprobada" : value === "supplier_payment_proposal.rejected" ? "Rechazada" : value === "supplier_payment_proposal.cancelled" ? "Cancelada" : value; }
function paymentAuditLabel(value: string) { return value === "supplier_payment.confirmed" ? "Pago confirmado" : value === "supplier_payment.reversed" ? "Pago revertido" : value === "supplier_payment.bank_receipt_attached" ? "Comprobante bancario adjuntado" : value === "supplier_payment.rep_received" ? "REP recibido y validado localmente" : value === "supplier_payment.rep_sat_verification_recorded" ? "Verificación SAT del REP registrada" : value; }
