type AlphaFileInput = Pick<File, "name" | "arrayBuffer">;
type Cell = string | number | Date | null | undefined;

export type AlphaSupplierEvidence = {
  external_code: string;
  display_name: string;
  counterparty_kind: string | null;
  supplier_type: string | null;
  tax_id: string | null;
  address_line: string | null;
  neighborhood: string | null;
  municipality: string | null;
  state_name: string | null;
  phone: string | null;
  source_row_number: number;
  source_row_hash: string;
};

export type AlphaPurchaseOrderEvidence = {
  source_order_key: string;
  order_number: string;
  branch_code: string;
  supplier_external_code: string;
  supplier_name: string;
  warehouse_name: string | null;
  ordered_date: string;
  currency_code: string | null;
  source_currency: string | null;
  source_status: string;
  source_approval_status: string;
  exchange_rate: number | null;
  discount_percent: number | null;
  source_row_number: number;
  source_row_hash: string;
};

export type AlphaPurchaseOrderLineEvidence = {
  source_order_key: string;
  line_number: number;
  alpha_class: string | null;
  alpha_sku: string;
  description: string;
  unit: string | null;
  attribute: string | null;
  quantity: number;
  unit_cost_mxn: number;
  discount_1: number | null;
  discount_2: number | null;
  expected_date: string | null;
  requisition_reference: string | null;
  source_row_number: number;
  source_row_hash: string;
};

export type AlphaPayableDocumentEvidence = {
  source_document_key: string;
  folio: string;
  supplier_external_code: string;
  supplier_name: string;
  issued_date: string;
  due_date: string;
  source_concept: string | null;
  outstanding_amount: number;
  currency_code: string | null;
  source_currency: string | null;
  source_row_number: number;
  source_row_hash: string;
};

export type AlphaSupplierPaymentEvidence = {
  source_payment_key: string;
  application_folio: string | null;
  branch_code: string | null;
  payment_date: string | null;
  document_type: string | null;
  document_folio: string;
  supplier_name: string;
  matched_supplier_external_code: string | null;
  amount_mxn: number;
  payment_method: string | null;
  source_currency: string | null;
  exchange_rate: number | null;
  bank_reference: string | null;
  source_row_number: number;
  source_row_hash: string;
};

export type AlphaPurchasingDifference = {
  severity: "error" | "warning";
  difference_code: string;
  message: string;
  source_file: string | null;
  source_row_number: number | null;
  evidence: Record<string, unknown>;
};

type FileMetadata = {
  report_type: "suppliers" | "purchase_orders" | "payable_documents" | "supplier_payments";
  original_name: string;
  file_sha256: string;
  snapshot_date: string;
  row_count: number;
};

export type AlphaPurchasingMigrationPayload = {
  cutoffDate: string;
  contentHash: string;
  files: FileMetadata[];
  suppliers: AlphaSupplierEvidence[];
  purchaseOrders: AlphaPurchaseOrderEvidence[];
  purchaseOrderLines: AlphaPurchaseOrderLineEvidence[];
  payableDocuments: AlphaPayableDocumentEvidence[];
  supplierPayments: AlphaSupplierPaymentEvidence[];
  differences: AlphaPurchasingDifference[];
  summary: {
    suppliers: number;
    purchase_orders: number;
    purchase_order_lines: number;
    payable_documents: number;
    payable_outstanding_total: number;
    supplier_payments: number;
    supplier_payment_total: number;
    receipt_source_available: false;
  };
};

type ParsedWorkbook = { name: string; rows: Cell[][]; bytes: ArrayBuffer; fileHash: string; snapshotDate: string };

const patterns = {
  suppliers: /^cata_prv_.+\.xlsx?$/i,
  purchaseOrders: /^rpcon2_.+\.xlsx?$/i,
  payableDocuments: /^lfchvenc_.+\.xlsx?$/i,
  supplierPayments: /^pag_det_.+\.xlsx?$/i,
};

export async function parseAlphaPurchasingMigration(files: AlphaFileInput[]): Promise<AlphaPurchasingMigrationPayload> {
  if (!files.length) throw new Error("Selecciona al menos un archivo de Compras/CxP.");
  const XLSX = await import("xlsx");
  const parsed = await Promise.all(files.map(async (file): Promise<ParsedWorkbook> => {
    const bytes = await file.arrayBuffer();
    const workbook = XLSX.read(bytes, { type: "array", raw: true, cellDates: true });
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    if (!sheet) throw new Error(`El archivo ${file.name} no contiene una hoja legible.`);
    const rows = XLSX.utils.sheet_to_json<Cell[]>(sheet, { header: 1, raw: true, defval: "" });
    const snapshotDate = extractSnapshotDate(rows);
    if (!snapshotDate) throw new Error(`No se encontró fecha de corte en ${file.name}.`);
    return { name: file.name, bytes, rows, fileHash: await hash(bytes), snapshotDate };
  }));

  const grouped = {
    suppliers: parsed.filter((file) => patterns.suppliers.test(file.name)),
    purchaseOrders: parsed.filter((file) => patterns.purchaseOrders.test(file.name)),
    payableDocuments: parsed.filter((file) => patterns.payableDocuments.test(file.name)),
    supplierPayments: parsed.filter((file) => patterns.supplierPayments.test(file.name)),
  };
  if (Object.values(grouped).flat().length !== parsed.length) throw new Error("Uno o más archivos no corresponden al paquete de Compras/CxP.");
  for (const [kind, matches] of Object.entries(grouped)) {
    if (matches.length > 1) throw new Error(`Selecciona como máximo un archivo ${kind} por carga.`);
  }
  const cutoffs = new Set(parsed.map((file) => file.snapshotDate));
  if (cutoffs.size !== 1) throw new Error("Los archivos de Compras/CxP no comparten la misma fecha de corte.");

  const supplierFile = grouped.suppliers[0];
  const orderFile = grouped.purchaseOrders[0];
  const payableFile = grouped.payableDocuments[0];
  const paymentFile = grouped.supplierPayments[0];
  const suppliers = supplierFile ? await parseSuppliers(supplierFile.rows) : [];
  const { orders: purchaseOrders, lines: purchaseOrderLines } = orderFile ? await parsePurchaseOrders(orderFile.rows) : { orders: [], lines: [] };
  const payableDocuments = payableFile ? await parsePayableDocuments(payableFile.rows) : [];
  const supplierNames = supplierNameIndex(suppliers);
  const supplierPayments = paymentFile ? await parseSupplierPayments(paymentFile.rows, supplierNames) : [];
  const differences = validatePackage({ suppliers, purchaseOrders, purchaseOrderLines, payableDocuments, supplierPayments }, {
    supplierFile: supplierFile?.name ?? null,
    orderFile: orderFile?.name ?? null,
    payableFile: payableFile?.name ?? null,
    paymentFile: paymentFile?.name ?? null,
  });
  const filesMetadata: FileMetadata[] = [
    ...(supplierFile ? [{ report_type: "suppliers" as const, original_name: supplierFile.name, file_sha256: supplierFile.fileHash, snapshot_date: supplierFile.snapshotDate, row_count: suppliers.length }] : []),
    ...(orderFile ? [{ report_type: "purchase_orders" as const, original_name: orderFile.name, file_sha256: orderFile.fileHash, snapshot_date: orderFile.snapshotDate, row_count: purchaseOrders.length + purchaseOrderLines.length }] : []),
    ...(payableFile ? [{ report_type: "payable_documents" as const, original_name: payableFile.name, file_sha256: payableFile.fileHash, snapshot_date: payableFile.snapshotDate, row_count: payableDocuments.length }] : []),
    ...(paymentFile ? [{ report_type: "supplier_payments" as const, original_name: paymentFile.name, file_sha256: paymentFile.fileHash, snapshot_date: paymentFile.snapshotDate, row_count: supplierPayments.length }] : []),
  ];
  const cutoffDate = parsed[0]!.snapshotDate;
  const contentHash = await hashText(JSON.stringify({ cutoffDate, files: filesMetadata.map((file) => [file.report_type, file.file_sha256]).sort() }));
  return {
    cutoffDate,
    contentHash,
    files: filesMetadata,
    suppliers,
    purchaseOrders,
    purchaseOrderLines,
    payableDocuments,
    supplierPayments,
    differences,
    summary: {
      suppliers: suppliers.length,
      purchase_orders: purchaseOrders.length,
      purchase_order_lines: purchaseOrderLines.length,
      payable_documents: payableDocuments.length,
      payable_outstanding_total: money(payableDocuments.reduce((total, row) => total + row.outstanding_amount, 0)),
      supplier_payments: supplierPayments.length,
      supplier_payment_total: money(supplierPayments.reduce((total, row) => total + row.amount_mxn, 0)),
      receipt_source_available: false,
    },
  };
}

async function parseSuppliers(rows: Cell[][]) {
  const suppliers: AlphaSupplierEvidence[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const externalCode = alphaCode(row[0]);
    const displayName = text(row[4]);
    if (!externalCode || !displayName) continue;
    if (seen.has(externalCode)) throw new Error(`El proveedor con código de origen ${externalCode} aparece más de una vez.`);
    seen.add(externalCode);
    const detail = rows.slice(index + 1, index + 4).find((candidate) => {
      const label = text(candidate?.[0]).toLocaleLowerCase("es-MX");
      return label === "proveedor" || label === "acreedor";
    }) ?? [];
    const raw = {
      external_code: externalCode,
      display_name: displayName,
      counterparty_kind: nullable(text(detail[0])),
      supplier_type: nullable(text(detail[8])),
      tax_id: nullable(text(detail[11])),
      address_line: nullable(text(row[11])),
      neighborhood: nullable(text(row[18])),
      municipality: nullable(text(row[22])),
      state_name: nullable(text(row[24])),
      phone: nullable(text(detail[17])),
      source_row_number: index + 1,
    };
    suppliers.push({ ...raw, source_row_hash: await hashText(JSON.stringify(raw)) });
  }
  if (!suppliers.length) throw new Error("cata_prv no contiene proveedores legibles.");
  return suppliers;
}

async function parsePurchaseOrders(rows: Cell[][]) {
  const orders: AlphaPurchaseOrderEvidence[] = [];
  const lines: AlphaPurchaseOrderLineEvidence[] = [];
  const seenOrders = new Set<string>();
  let current: AlphaPurchaseOrderEvidence | null = null;
  let lineNumber = 0;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const orderedDate = parseDate(row[0]);
    const orderNumber = identifier(row[4]);
    const supplierCode = alphaCode(row[7]);
    if (orderedDate && orderNumber && supplierCode && text(row[10])) {
      const branchCode = text(row[5]);
      const sourceOrderKey = `${branchCode}|${orderNumber}`;
      if (seenOrders.has(sourceOrderKey)) throw new Error(`La orden de origen ${sourceOrderKey} aparece más de una vez.`);
      seenOrders.add(sourceOrderKey);
      const raw = {
        source_order_key: sourceOrderKey,
        order_number: orderNumber,
        branch_code: branchCode,
        supplier_external_code: supplierCode,
        supplier_name: text(row[10]),
        warehouse_name: nullable(text(row[19])),
        ordered_date: orderedDate,
        currency_code: currency(text(row[26])),
        source_currency: nullable(text(row[26])),
        source_status: text(row[38]),
        source_approval_status: text(row[42]),
        exchange_rate: numberOrNull(row[33]),
        discount_percent: numberOrNull(row[31]),
        source_row_number: index + 1,
      };
      current = { ...raw, source_row_hash: await hashText(JSON.stringify(raw)) };
      orders.push(current);
      lineNumber = 0;
      continue;
    }
    const sku = text(row[4]);
    const description = text(row[7]);
    const quantity = numberOrNull(row[25]);
    const unitCost = numberOrNull(row[29]);
    if (!current || !sku || !description || quantity === null || unitCost === null) continue;
    lineNumber += 1;
    const raw = {
      source_order_key: current.source_order_key,
      line_number: lineNumber,
      alpha_class: nullable(text(row[0])),
      alpha_sku: sku,
      description,
      unit: nullable(text(row[17])),
      attribute: nullable(text(row[22])),
      quantity,
      unit_cost_mxn: unitCost,
      discount_1: numberOrNull(row[34]),
      discount_2: numberOrNull(row[37]),
      expected_date: parseDate(row[40]),
      requisition_reference: nullable(identifier(row[43])),
      source_row_number: index + 1,
    };
    lines.push({ ...raw, source_row_hash: await hashText(JSON.stringify(raw)) });
  }
  if (!orders.length || !lines.length) throw new Error("rpcon2 no contiene órdenes y partidas legibles.");
  return { orders, lines };
}

async function parsePayableDocuments(rows: Cell[][]) {
  const documents: AlphaPayableDocumentEvidence[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const folio = text(row[0]);
    const supplierCode = alphaCode(row[9]);
    const supplierName = text(row[10]);
    const issuedDate = parseDate(row[15]);
    const dueDate = parseDate(row[17]);
    const amount = numberOrNull(row[25]);
    if (!folio || !supplierCode || !supplierName || !issuedDate || !dueDate || amount === null) continue;
    const sourceDocumentKey = `${supplierCode}|${folio}|${issuedDate}`;
    if (seen.has(sourceDocumentKey)) throw new Error(`El documento CxP ${sourceDocumentKey} aparece más de una vez.`);
    seen.add(sourceDocumentKey);
    const raw = {
      source_document_key: sourceDocumentKey,
      folio,
      supplier_external_code: supplierCode,
      supplier_name: supplierName,
      issued_date: issuedDate,
      due_date: dueDate,
      source_concept: nullable(text(row[21])),
      outstanding_amount: amount,
      currency_code: currency(text(row[30])),
      source_currency: nullable(text(row[30])),
      source_row_number: index + 1,
    };
    documents.push({ ...raw, source_row_hash: await hashText(JSON.stringify(raw)) });
  }
  if (!documents.length) throw new Error("lfchvenc no contiene documentos abiertos legibles.");
  return documents;
}

async function parseSupplierPayments(rows: Cell[][], supplierNames: Map<string, string[]>) {
  const payments: AlphaSupplierPaymentEvidence[] = [];
  let currentApplication: string | null = null;
  let currentDate: string | null = null;
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const nextApplication = identifier(row[0]);
    const nextDate = parseDate(row[6]);
    if (nextApplication) currentApplication = nextApplication;
    if (nextDate) currentDate = nextDate;
    const documentFolio = text(row[10]);
    const supplierName = text(row[15]);
    const amount = numberOrNull(row[21]);
    if (!documentFolio || !supplierName || amount === null || amount <= 0) continue;
    const candidates = supplierNames.get(nameKey(supplierName)) ?? [];
    const raw = {
      application_folio: currentApplication,
      branch_code: nullable(text(row[4])),
      payment_date: currentDate,
      document_type: nullable(text(row[9])),
      document_folio: documentFolio,
      supplier_name: supplierName,
      matched_supplier_external_code: candidates.length === 1 ? candidates[0]! : null,
      amount_mxn: amount,
      payment_method: nullable(text(row[22])),
      source_currency: nullable(text(row[30])),
      exchange_rate: numberOrNull(row[32]),
      bank_reference: nullable(text(row[34])),
      source_row_number: index + 1,
    };
    const sourcePaymentKey = await hashText(JSON.stringify(raw));
    payments.push({ source_payment_key: sourcePaymentKey, ...raw, source_row_hash: sourcePaymentKey });
  }
  if (!payments.length) throw new Error("pag_det no contiene aplicaciones de pago legibles.");
  return payments;
}

function validatePackage(
  data: Pick<AlphaPurchasingMigrationPayload, "suppliers" | "purchaseOrders" | "purchaseOrderLines" | "payableDocuments" | "supplierPayments">,
  files: { supplierFile: string | null; orderFile: string | null; payableFile: string | null; paymentFile: string | null },
) {
  const differences: AlphaPurchasingDifference[] = [{
    severity: "warning",
    difference_code: "RECEIPT_SOURCE_NOT_AVAILABLE",
    message: "Los Excel entregados no contienen una recepción vinculable de forma inequívoca a la orden de compra; rep_mov no incluye una llave OC–proveedor–recepción.",
    source_file: null,
    source_row_number: null,
    evidence: { inspected_report: "rep_mov", operational_effect: "No se crearán recepciones ni movimientos históricos desde esta fuente." },
  }];
  const supplierCodes = new Set(data.suppliers.map((supplier) => supplier.external_code));
  for (const order of data.purchaseOrders) {
    if (supplierCodes.size && !supplierCodes.has(order.supplier_external_code)) differences.push({ severity: "error", difference_code: "ORDER_SUPPLIER_NOT_IN_CATALOG", message: `La OC ${order.order_number} referencia al proveedor ${order.supplier_external_code}, ausente de cata_prv.`, source_file: files.orderFile, source_row_number: order.source_row_number, evidence: { source_order_key: order.source_order_key, supplier_external_code: order.supplier_external_code } });
    if (!order.currency_code) differences.push({ severity: "error", difference_code: "PURCHASE_CURRENCY_UNMAPPED", message: `La OC ${order.order_number} usa una moneda no reconocida: ${order.source_currency ?? "vacía"}.`, source_file: files.orderFile, source_row_number: order.source_row_number, evidence: { source_currency: order.source_currency } });
  }
  const orderKeys = new Set(data.purchaseOrders.map((order) => order.source_order_key));
  for (const line of data.purchaseOrderLines) {
    if (!orderKeys.has(line.source_order_key) || line.quantity <= 0 || line.unit_cost_mxn < 0) differences.push({ severity: "error", difference_code: "PURCHASE_ORDER_LINE_INVALID", message: `La partida ${line.line_number} de ${line.source_order_key} no tiene una orden, cantidad o costo válido.`, source_file: files.orderFile, source_row_number: line.source_row_number, evidence: { source_order_key: line.source_order_key, quantity: line.quantity, unit_cost_mxn: line.unit_cost_mxn } });
  }
  for (const document of data.payableDocuments) {
    if (supplierCodes.size && !supplierCodes.has(document.supplier_external_code)) differences.push({ severity: "error", difference_code: "PAYABLE_SUPPLIER_NOT_IN_CATALOG", message: `El documento ${document.folio} referencia al proveedor ${document.supplier_external_code}, ausente de cata_prv.`, source_file: files.payableFile, source_row_number: document.source_row_number, evidence: { source_document_key: document.source_document_key } });
    if (!document.currency_code) differences.push({ severity: "error", difference_code: "PAYABLE_CURRENCY_UNMAPPED", message: `El documento ${document.folio} no tiene una moneda reconocida.`, source_file: files.payableFile, source_row_number: document.source_row_number, evidence: { source_currency: document.source_currency } });
    if (document.outstanding_amount < 0) differences.push({ severity: "warning", difference_code: "SUPPLIER_CREDIT_BALANCE_REQUIRES_CLASSIFICATION", message: `El documento ${document.folio} tiene saldo acreedor ${document.outstanding_amount}; se conserva como evidencia hasta clasificarlo como crédito o anticipo.`, source_file: files.payableFile, source_row_number: document.source_row_number, evidence: { source_document_key: document.source_document_key, outstanding_amount: document.outstanding_amount } });
  }
  for (const payment of data.supplierPayments) if (!payment.matched_supplier_external_code) differences.push({ severity: "warning", difference_code: "PAYMENT_SUPPLIER_UNRESOLVED", message: `El pago aplicado a ${payment.document_folio} solo identifica al proveedor por nombre (${payment.supplier_name}); queda como evidencia y no generará un pago operativo.`, source_file: files.paymentFile, source_row_number: payment.source_row_number, evidence: { supplier_name: payment.supplier_name, document_folio: payment.document_folio } });
  if (!files.supplierFile) differences.push({ severity: "error", difference_code: "SUPPLIER_CATALOG_MISSING", message: "Falta cata_prv; no se pueden validar las identidades de proveedor.", source_file: null, source_row_number: null, evidence: {} });
  return differences;
}

function supplierNameIndex(suppliers: AlphaSupplierEvidence[]) {
  const index = new Map<string, string[]>();
  for (const supplier of suppliers) index.set(nameKey(supplier.display_name), [...(index.get(nameKey(supplier.display_name)) ?? []), supplier.external_code]);
  return index;
}

function text(value: Cell) { return String(value ?? "").replace(/\s+/g, " ").trim(); }
function nullable(value: string) { return value || null; }
function nameKey(value: string) { return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^A-Z0-9]/gi, "").toUpperCase(); }
function identifier(value: Cell) { const valueText = text(value); return valueText && !/^(fecha|hora|pagina|total)/i.test(valueText) ? valueText : ""; }
function alphaCode(value: Cell) { const valueText = text(value); return /^\d+$/.test(valueText) ? String(Number(valueText)) : ""; }
function numberOrNull(value: Cell) { const raw = String(value ?? "").replace(/[$,\s%]/g, ""); if (!raw) return null; const parsed = Number(raw); return Number.isFinite(parsed) ? money(parsed) : null; }
function money(value: number) { return Math.round(value * 100) / 100; }
function currency(value: string) { const key = nameKey(value); return key === "PESOS" || key === "MXN" || key === "P" ? "MXN" : null; }
function parseDate(value: Cell) {
  if (value instanceof Date && Number.isFinite(value.getTime())) return value.toISOString().slice(0, 10);
  const raw = text(value);
  const dmy = raw.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{2}|\d{4})$/);
  if (dmy) { const year = dmy[3]!.length === 2 ? 2000 + Number(dmy[3]) : Number(dmy[3]); return `${year}-${dmy[2]!.padStart(2, "0")}-${dmy[1]!.padStart(2, "0")}`; }
  const iso = raw.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return iso ? `${iso[1]}-${iso[2]}-${iso[3]}` : null;
}
function extractSnapshotDate(rows: Cell[][]) { for (const row of rows.slice(0, 6)) for (const value of row) { const parsed = parseDate(value); if (parsed) return parsed; } return null; }
async function hash(input: ArrayBuffer) { const digest = await crypto.subtle.digest("SHA-256", input); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
async function hashText(input: string) { const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
