type AlphaFileInput = Pick<File, "name" | "arrayBuffer">;

type CustomerProfile = {
  external_code: string;
  display_name: string;
  tax_id: string | null;
  address_line: string | null;
  neighborhood: string | null;
  municipality: string | null;
  state_name: string | null;
  postal_code: string | null;
  phone: string | null;
  contact_name: string | null;
  bank_reference: string | null;
  commercial_name: string | null;
  commercial_type: string | null;
  credit_limit: number | null;
  credit_term_days: number | null;
  payment_manager: string | null;
  sales_agent: string | null;
  catalog_present: boolean;
  terms_present: boolean;
  source_row_hash: string;
};

type OpenDocument = {
  customer_external_code: string;
  source_code: string;
  folio: string;
  document_date: string;
  currency_code: string;
  original_amount: number;
  outstanding_amount: number;
  source_row_hash: string;
  raw_data: Record<string, unknown>;
};

type CollectionEvidence = {
  customer_external_code: string;
  payment_subtype: string | null;
  folio: string | null;
  branch_code: string | null;
  issued_date: string | null;
  applied_date: string | null;
  due_date: string | null;
  document_type: string | null;
  reference: string | null;
  amount: number | null;
  currency_code: string | null;
  account_number: string | null;
  source_row_hash: string;
  raw_data: Record<string, unknown>;
};

type FileMetadata = {
  report_type: "customers" | "credit_terms" | "ledger" | "collections";
  original_name: string;
  file_sha256: string;
  logical_sha256: string | null;
  snapshot_date: string;
  duplicate_group: string | null;
  row_count: number;
};

export type AlphaCustomerMigrationPayload = {
  cutoffDate: string;
  contentHash: string;
  isComplete: boolean;
  files: FileMetadata[];
  customers: CustomerProfile[];
  documents: OpenDocument[];
  collections: CollectionEvidence[];
};

type WorkbookFile = { name: string; bytes: ArrayBuffer; rows: Cell[][]; fileHash: string; snapshotDate: string };
type Cell = string | number | Date | null | undefined;

const names = {
  customers: /^cata_cte_.+\.xlsx?$/i,
  creditTerms: /^cat_ctee_.+\.xlsx?$/i,
  ledger: /^lis_sal_.+\.xlsx?$/i,
  collections: /^cob_cte_.+\.xlsx?$/i,
};

export async function parseAlphaCustomerMigration(files: AlphaFileInput[]): Promise<AlphaCustomerMigrationPayload> {
  const XLSX = await import("xlsx");
  const parsed = await Promise.all(files.map(async (file): Promise<WorkbookFile> => {
    const bytes = await file.arrayBuffer();
    const workbook = XLSX.read(bytes, { type: "array", raw: false, cellDates: true });
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    if (!sheet) throw new Error(`El archivo ${file.name} no contiene una hoja legible.`);
    const rows = XLSX.utils.sheet_to_json<Cell[]>(sheet, { header: 1, raw: false, defval: "" });
    const snapshotDate = extractSnapshotDate(rows);
    if (!snapshotDate) throw new Error(`No se encontró fecha de corte en ${file.name}.`);
    return { name: file.name, bytes, rows, fileHash: await hash(bytes), snapshotDate };
  }));

  const customerFiles = parsed.filter((file) => names.customers.test(file.name));
  const ledgerFiles = parsed.filter((file) => names.ledger.test(file.name));
  const collectionFiles = parsed.filter((file) => names.collections.test(file.name));
  const creditFiles = parsed.filter((file) => names.creditTerms.test(file.name));
  const recognizedCount = customerFiles.length + ledgerFiles.length + collectionFiles.length + creditFiles.length;
  if (recognizedCount !== parsed.length) throw new Error("Uno o más archivos no corresponden al paquete de Clientes/CxC.");
  if (customerFiles.length > 1) throw new Error("Selecciona como máximo un archivo cata_cte por carga.");
  if (ledgerFiles.length > 1) throw new Error("Selecciona como máximo un archivo lis_sal por carga.");
  if (collectionFiles.length > 1) throw new Error("Selecciona como máximo un archivo cob_cte por carga.");

  const cutoffs = new Set(parsed.map((file) => file.snapshotDate));
  if (cutoffs.size !== 1) throw new Error("Los archivos no comparten la misma fecha de corte; no se pueden combinar.");
  const termsByFile = await Promise.all(creditFiles.map(async (file) => ({ file, terms: parseCreditTerms(file.rows) })));
  const logicalCreditHashes = await Promise.all(termsByFile.map(async ({ terms }) => hashText(JSON.stringify([...terms.values()].sort((a, b) => a.code.localeCompare(b.code))))));
  if (logicalCreditHashes.length && new Set(logicalCreditHashes).size !== 1) throw new Error("Las copias de cat_ctee tienen diferencias de contenido; deben revisarse antes de migrar.");
  const creditTerms = termsByFile[0]?.terms ?? new Map<string, CreditTerm>();
  const customerFile = customerFiles[0];
  const ledgerFile = ledgerFiles[0];
  const collectionFile = collectionFiles[0];
  const catalog = customerFile ? parseCustomerCatalog(customerFile.rows) : new Map<string, CatalogCustomer>();
  const customers = await mergeCustomers(catalog, creditTerms);
  const documents = ledgerFile ? await parseOpenDocuments(ledgerFile.rows) : [];
  const collections = collectionFile ? await parseCollectionEvidence(collectionFile.rows) : [];
  const duplicateGroup = logicalCreditHashes[0] ? `credit_terms:${logicalCreditHashes[0]}` : null;
  const filesMetadata: FileMetadata[] = [
    ...(customerFile ? [{ report_type: "customers" as const, original_name: customerFile.name, file_sha256: customerFile.fileHash, logical_sha256: null, snapshot_date: customerFile.snapshotDate, duplicate_group: null, row_count: catalog.size }] : []),
    ...creditFiles.map((file) => ({ report_type: "credit_terms" as const, original_name: file.name, file_sha256: file.fileHash, logical_sha256: logicalCreditHashes[0] ?? null, snapshot_date: file.snapshotDate, duplicate_group: duplicateGroup, row_count: creditTerms.size })),
    ...(ledgerFile ? [{ report_type: "ledger" as const, original_name: ledgerFile.name, file_sha256: ledgerFile.fileHash, logical_sha256: null, snapshot_date: ledgerFile.snapshotDate, duplicate_group: null, row_count: documents.length }] : []),
    ...(collectionFile ? [{ report_type: "collections" as const, original_name: collectionFile.name, file_sha256: collectionFile.fileHash, logical_sha256: null, snapshot_date: collectionFile.snapshotDate, duplicate_group: null, row_count: collections.length }] : []),
  ];
  const cutoffDate = parsed[0]!.snapshotDate;
  const contentHash = await hashText(JSON.stringify({ cutoffDate, files: filesMetadata.map((file) => [file.report_type, file.original_name, file.file_sha256]).sort() }));
  const isComplete = Boolean(customerFile && creditFiles.length && ledgerFile && collectionFile);
  return { cutoffDate, contentHash, isComplete, files: filesMetadata, customers, documents, collections };
}

type CatalogCustomer = Omit<CustomerProfile, "commercial_name" | "commercial_type" | "credit_limit" | "credit_term_days" | "payment_manager" | "sales_agent" | "terms_present" | "source_row_hash">;
type CreditTerm = { code: string; displayName: string; type: string | null; creditLimit: number | null; creditTermDays: number | null; paymentManager: string | null; salesAgent: string | null; bankReference: string | null };

function parseCustomerCatalog(rows: Cell[][]) {
  const result = new Map<string, CatalogCustomer>();
  for (let index = 6; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const code = alphaCode(row[0]);
    const displayName = text(row[3]);
    if (!code || !displayName) continue;
    const detail = rows[index + 1] ?? [];
    result.set(code, {
      external_code: code,
      display_name: displayName,
      tax_id: labelValue(detail, "RFC.", 3),
      address_line: nullable(text(row[7])),
      neighborhood: nullable(text(row[10])),
      municipality: nullable(text(row[14])),
      state_name: nullable(text(row[16])),
      postal_code: labelValue(detail, "C.P.", 11),
      phone: labelValue(detail, "Teléfonos:", 7),
      contact_name: labelValue(detail, "Contacto:", 13),
      bank_reference: labelValue(detail, "Ref. Bancaria:", 16),
      catalog_present: true,
    });
  }
  return result;
}

function parseCreditTerms(rows: Cell[][]) {
  const result = new Map<string, CreditTerm>();
  for (let index = 7; index < rows.length; index += 1) {
    const row = rows[index] ?? [];
    const code = alphaCode(row[0]);
    if (!code) continue;
    result.set(code, {
      code,
      displayName: text(row[3]),
      creditLimit: numberOrNull(row[9]),
      creditTermDays: integerOrNull(row[12]),
      type: nullable(text(row[14])),
      paymentManager: nullable(text(row[17])),
      salesAgent: nullable(text(row[20])),
      bankReference: nullable(text(row[25])),
    });
  }
  return result;
}

async function mergeCustomers(catalog: Map<string, CatalogCustomer>, terms: Map<string, CreditTerm>) {
  const merged: CustomerProfile[] = [];
  for (const [code, customer] of catalog) {
    const term = terms.get(code);
    const evidence = { customer, term };
    merged.push({
      ...customer,
      commercial_name: term?.displayName ?? null,
      commercial_type: term?.type ?? null,
      credit_limit: term?.creditLimit ?? null,
      credit_term_days: term?.creditTermDays ?? null,
      payment_manager: term?.paymentManager ?? null,
      sales_agent: term?.salesAgent ?? null,
      bank_reference: customer.bank_reference ?? term?.bankReference ?? null,
      terms_present: Boolean(term),
      source_row_hash: await hashText(JSON.stringify(evidence)),
    });
  }
  for (const [code, term] of terms) {
    if (catalog.has(code)) continue;
    merged.push({
      external_code: code, display_name: term.displayName || `Cliente importado ${code}`, tax_id: null, address_line: null, neighborhood: null, municipality: null, state_name: null, postal_code: null, phone: null, contact_name: null, bank_reference: term.bankReference, commercial_name: term.displayName || null, commercial_type: term.type, credit_limit: term.creditLimit, credit_term_days: term.creditTermDays, payment_manager: term.paymentManager, sales_agent: term.salesAgent, catalog_present: false, terms_present: true, source_row_hash: await hashText(JSON.stringify(term)),
    });
  }
  return merged.sort((left, right) => left.external_code.localeCompare(right.external_code, "es", { numeric: true }));
}

async function parseOpenDocuments(rows: Cell[][]) {
  type Invoice = { documentDate: string; originalAmount: number; currencyCode: string };
  type Segment = { customerCode: string; folio: string; invoice: Invoice | null; movementDate: string | null; endingBalance: number };
  type PendingSegment = Omit<Segment, "endingBalance"> & { lastBalance: number | null };

  const segmentsByDocument = new Map<string, Segment[]>();
  const reportedTotals = new Map<string, number>();
  let customerCode: string | null = null;
  let pending: PendingSegment | null = null;

  const closeSegment = (row: Cell[]) => {
    if (!pending) return;
    const endingBalance = numberOrNull(row[19]) ?? pending.lastBalance;
    if (endingBalance === null) throw new Error(`No se pudo determinar el saldo final del folio ${pending.folio} del cliente ${pending.customerCode}.`);
    const key = `${pending.customerCode}\u0000${pending.folio}`;
    const group = segmentsByDocument.get(key) ?? [];
    group.push({ customerCode: pending.customerCode, folio: pending.folio, invoice: pending.invoice, movementDate: pending.movementDate, endingBalance });
    segmentsByDocument.set(key, group);
    pending = null;
  };

  for (const row of rows) {
    if (normalized(row[0]) === "cliente") {
      const nextCustomer = alphaCode(row[2]);
      if (pending && nextCustomer && nextCustomer !== pending.customerCode) throw new Error(`El folio ${pending.folio} del cliente ${pending.customerCode} quedó incompleto antes del siguiente cliente.`);
      customerCode = nextCustomer;
      continue;
    }

    const summaryLabel = text(row[0]);
    if (summaryLabel.startsWith("Total de Facturas, Notas de cgo, Cheques Dev. Elaboradas en M. N.")) {
      if (!customerCode) throw new Error("Se encontró un total de CxC sin cliente asociado.");
      const reported = numberOrNull(row[19]) ?? ((numberOrNull(row[14]) ?? 0) - (numberOrNull(row[17]) ?? 0));
      reportedTotals.set(customerCode, reported);
      continue;
    }

    const folio = text(row[2]);
    const sourceCode = text(row[8]);
    if (customerCode && folio && (sourceCode === "F" || sourceCode === "P")) {
      if (pending && pending.folio !== folio) throw new Error(`El folio ${pending.folio} del cliente ${pending.customerCode} no tiene una fila de total antes del folio ${folio}.`);
      if (!pending) pending = { customerCode, folio, invoice: null, movementDate: null, lastBalance: null };
      const movementDate = parseDate(row[5]);
      pending.movementDate = movementDate ?? pending.movementDate;
      pending.lastBalance = numberOrNull(row[20]) ?? pending.lastBalance;
      if (sourceCode === "F") {
        const originalAmount = numberOrNull(row[14]);
        const currencyCode = currency(text(row[24]));
        if (!movementDate || originalAmount === null || originalAmount <= 0 || !currencyCode) throw new Error(`La factura ${folio} del cliente ${customerCode} no tiene fecha, importe o moneda válidos.`);
        if (pending.invoice) throw new Error(`El folio ${folio} del cliente ${customerCode} contiene más de una factura dentro del mismo bloque.`);
        pending.invoice = { documentDate: movementDate, originalAmount, currencyCode };
      }
      continue;
    }

    if (pending && folio.startsWith("Total de ")) closeSegment(row);
  }

  if (pending) throw new Error(`El folio ${pending.folio} del cliente ${pending.customerCode} terminó sin una fila de total.`);

  const documents: OpenDocument[] = [];
  const calculatedTotals = new Map<string, number>();
  for (const segments of segmentsByDocument.values()) {
    const invoices = segments.filter((segment): segment is Segment & { invoice: Invoice } => Boolean(segment.invoice));
    const adjustments = segments.filter((segment) => !segment.invoice && segment.endingBalance !== 0);
    if (!invoices.length) {
      if (adjustments.length) throw new Error(`El folio ${segments[0]!.folio} del cliente ${segments[0]!.customerCode} tiene movimientos sin una factura de origen.`);
      continue;
    }

    const candidates = invoices.map((segment) => ({ ...segment, outstandingCents: cents(segment.endingBalance) }));
    if (candidates.length === 1) {
      candidates[0]!.outstandingCents += adjustments.reduce((total, segment) => total + cents(segment.endingBalance), 0);
    } else {
      for (const adjustment of adjustments) {
        if (adjustment.endingBalance >= 0) throw new Error(`El folio repetido ${adjustment.folio} del cliente ${adjustment.customerCode} tiene un movimiento positivo sin factura identificable.`);
        const amount = Math.abs(cents(adjustment.endingBalance));
        let matches = candidates.filter((candidate) => candidate.invoice.documentDate === adjustment.movementDate && candidate.outstandingCents >= amount);
        if (matches.length !== 1) matches = candidates.filter((candidate) => candidate.outstandingCents === amount);
        if (matches.length !== 1) throw new Error(`El folio repetido ${adjustment.folio} del cliente ${adjustment.customerCode} no permite asociar un pago a una sola factura.`);
        matches[0]!.outstandingCents -= amount;
      }
    }

    for (const candidate of candidates) {
      if (candidate.outstandingCents < 0) throw new Error(`El folio ${candidate.folio} del cliente ${candidate.customerCode} termina con saldo negativo.`);
      if (candidate.outstandingCents === 0) continue;
      const outstandingAmount = candidate.outstandingCents / 100;
      const raw = { customer_external_code: candidate.customerCode, folio: candidate.folio, source_code: "F", document_date: candidate.invoice.documentDate, original_amount: candidate.invoice.originalAmount, outstanding_amount: outstandingAmount, currency_code: candidate.invoice.currencyCode };
      documents.push({ ...raw, source_row_hash: await hashText(JSON.stringify(raw)), raw_data: raw });
      calculatedTotals.set(candidate.customerCode, (calculatedTotals.get(candidate.customerCode) ?? 0) + outstandingAmount);
    }
  }

  for (const [code, reported] of reportedTotals) {
    const calculated = calculatedTotals.get(code) ?? 0;
    if (cents(calculated) !== cents(reported)) throw new Error(`La conciliación documental del cliente ${code} no cuadra: el reporte indica ${reported.toFixed(2)} y los documentos ${calculated.toFixed(2)}.`);
  }

  return documents;
}

async function parseCollectionEvidence(rows: Cell[][]) {
  const collections: CollectionEvidence[] = [];
  let customerCode: string | null = null;
  let subtype: string | null = null;
  for (const row of rows) {
    const possibleCustomer = text(row[0]);
    if (/^\d{1,10}$/.test(possibleCustomer)) { customerCode = alphaCode(possibleCustomer); subtype = null; continue; }
    if (customerCode && possibleCustomer && !text(row[3])) { subtype = possibleCustomer; continue; }
    const folio = text(row[3]);
    if (!customerCode || !folio) continue;
    const raw = { customer_external_code: customerCode, payment_subtype: subtype, folio, branch_code: nullable(text(row[5])), issued_date: parseDate(row[7]), applied_date: parseDate(row[9]), due_date: parseDate(row[12]), document_type: nullable(text(row[14])), reference: nullable(text(row[15])), amount: numberOrNull(row[17]), currency_code: currency(text(row[20])), account_number: nullable(text(row[26])) };
    collections.push({ ...raw, source_row_hash: await hashText(JSON.stringify(raw)), raw_data: raw });
  }
  return collections;
}

function text(value: Cell) { return String(value ?? "").replace(/\s+/g, " ").trim(); }
function nullable(value: string) { return value || null; }
function normalized(value: Cell) { return text(value).toLocaleLowerCase("es-MX"); }
function alphaCode(value: Cell) { const raw = text(value); return /^\d+$/.test(raw) ? String(Number(raw)) : ""; }
function numberOrNull(value: Cell) { const raw = String(value ?? "").replace(/[$,\s]/g, ""); if (!raw) return null; const parsed = Number(raw); return Number.isFinite(parsed) ? Math.round(parsed * 100) / 100 : null; }
function cents(value: number) { return Math.round(value * 100); }
function integerOrNull(value: Cell) { const parsed = numberOrNull(value); return parsed !== null && Number.isInteger(parsed) ? parsed : null; }
function currency(value: string) { const key = normalized(value); return key === "pesos" || key === "mxn" ? "MXN" : null; }
function parseDate(value: Cell) { const raw = text(value); const match = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); return match ? `${match[3]}-${match[2]!.padStart(2, "0")}-${match[1]!.padStart(2, "0")}` : null; }
function extractSnapshotDate(rows: Cell[][]) { for (const row of rows.slice(0, 5)) for (const value of row) { const date = parseDate(value); if (date) return date; } return null; }
function labelValue(row: Cell[], label: string, fallbackIndex: number) { const index = row.findIndex((value) => text(value).startsWith(label)); if (index < 0) return null; const inline = text(row[index]).slice(label.length).trim(); if (inline) return inline; for (let cursor = index + 1; cursor < Math.min(row.length, index + 5); cursor += 1) { const value = text(row[cursor]); if (value && !value.endsWith(":")) return value; } return nullable(text(row[fallbackIndex])); }
async function hash(input: ArrayBuffer) { const digest = await crypto.subtle.digest("SHA-256", input); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
async function hashText(input: string) { const bytes = new TextEncoder().encode(input); const digest = await crypto.subtle.digest("SHA-256", bytes); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
