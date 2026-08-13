import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { parseAlphaCustomerMigration } from "@/app/lib/alpha-customer-migration";
import { parseAlphaCollaboratorMigration } from "@/app/lib/alpha-collaborator-migration";
import { parseAlphaPurchasingMigration } from "@/app/lib/alpha-purchasing-migration";
import { parseAlphaWorkbook } from "@/app/lib/alpha";
import { buildStagingPayload } from "@/app/lib/import-staging";
import { validateReferencedProducts, validateReferencedSales } from "@/app/lib/import-validation";
import type { AlphaStandardImportKind } from "@/app/lib/alpha-upload-routing";

type FileInput = Pick<File, "name" | "arrayBuffer">;
type Client = SupabaseClient;
export type StandardStagingResult = { status: string; batch_id?: string; message?: string; records_received?: number; valid_rows?: number; warning_rows?: number; error_rows?: number };
export type CustomerStagingResult = { status: string; batch_id?: string; message?: string; files_staged?: number; records_received?: number; reconciled_customers?: number; customers_with_differences?: number };
export type PurchasingStagingResult = { status: string; batch_id?: string; message?: string; errors?: number; warnings?: number };
export type CollaboratorStagingResult = StandardStagingResult;

const CHUNK_SIZE = 400;

export async function stageStandardAlphaUpload(
  supabase: Client,
  companyId: string,
  file: FileInput,
  source: "manual_upload" | "local_development" = "manual_upload",
): Promise<StandardStagingResult> {
  const parsed = await parseAlphaWorkbook(await file.arrayBuffer(), file.name, source === "manual_upload" ? "manual" : "local_development");
  const additionalIssues = [...await validateReferencedProducts(parsed, companyId, supabase), ...await validateReferencedSales(parsed, companyId, supabase)];
  const payload = buildStagingPayload(parsed, additionalIssues);
  if (parsed.importKind === "sales") return stageAlphaSalesEvidence(supabase, companyId, parsed, payload, source);
  const { data, error } = await supabase.rpc("stage_alpha_import", {
    p_company_id: companyId,
    p_import_type: parsed.importKind,
    p_source: source,
    p_file_name: parsed.fileName,
    p_file_type: extension(parsed.fileName),
    p_file_sha256: parsed.fileHash,
    p_snapshot_date: parsed.snapshotDate,
    p_rows: payload.rows,
    p_errors: payload.errors,
  });
  if (error) throw new Error(error.message);
  return data as StandardStagingResult;
}

async function stageAlphaSalesEvidence(
  supabase: Client,
  companyId: string,
  parsed: Awaited<ReturnType<typeof parseAlphaWorkbook>>,
  payload: ReturnType<typeof buildStagingPayload>,
  source: "manual_upload" | "local_development",
): Promise<StandardStagingResult> {
  let batchId: string | undefined;
  try {
    const { data: begun, error: beginError } = await supabase.rpc("begin_alpha_sales_evidence_file", {
      p_company_id: companyId,
      p_source: source,
      p_source_kind: "sales",
      p_file_name: parsed.fileName,
      p_file_type: extension(parsed.fileName),
      p_file_sha256: parsed.fileHash,
      p_cutoff_date: parsed.snapshotDate,
    });
    if (beginError) throw new Error(beginError.message);
    const begin = begun as { status: string; batch_id?: string; message?: string };
    if (begin.status !== "processing" || !begin.batch_id) return begin;
    batchId = begin.batch_id;
    for (let index = 0; index < payload.rows.length; index += CHUNK_SIZE) {
      const rows = payload.rows.slice(index, index + CHUNK_SIZE);
      const rowNumbers = new Set(rows.map((row) => row.row_number));
      const errors = payload.errors.filter((error) => error.row_number !== null && rowNumbers.has(error.row_number));
      const { error } = await supabase.rpc("stage_alpha_sales_staging_rows", { p_batch_id: batchId, p_rows: rows, p_errors: errors });
      if (error) throw new Error(`No se pudo guardar un bloque de ventas: ${error.message}`);
    }
    const fileErrors = payload.errors.filter((error) => error.row_number === null);
    const { data, error } = await supabase.rpc("finish_alpha_sales_evidence_file", { p_batch_id: batchId, p_file_errors: fileErrors });
    if (error) throw new Error(error.message);
    return data as StandardStagingResult;
  } catch (error) {
    const message = error instanceof Error ? error.message : "No se pudo preparar la evidencia de ventas.";
    if (batchId) await supabase.rpc("fail_alpha_sales_staging", { p_batch_id: batchId, p_reason: message });
    throw new Error(message);
  }
}

export async function stageAlphaSalesCollectionUpload(
  supabase: Client,
  companyId: string,
  file: FileInput,
  source: "manual_upload" | "local_development" = "manual_upload",
): Promise<StandardStagingResult> {
  let batchId: string | undefined;
  try {
    const parsed = await parseAlphaCustomerMigration([file]);
    const metadata = parsed.files.find((item) => item.report_type === "collections");
    if (!metadata) throw new Error("El archivo no contiene cobranza detallada compatible.");
    const rows = parsed.collections.map((row, index) => ({
      row_number: 1_000_000 + index + 1,
      source_file: file.name,
      detected_type: "sales" as const,
      raw_data: { cells: [row.customer_external_code, row.payment_subtype ?? "", row.folio ?? "", row.branch_code ?? "", row.issued_date ?? "", row.applied_date ?? "", row.reference ?? "", row.amount ?? "", row.currency_code ?? "", row.account_number ?? ""] },
      normalized_data: {
        evidenceKind: "collection",
        customerExternalCode: row.customer_external_code,
        paymentSubtype: row.payment_subtype,
        sourceFolio: row.folio,
        branchCode: row.branch_code,
        issuedDate: row.issued_date,
        appliedDate: row.applied_date,
        dueDate: row.due_date,
        documentType: row.document_type,
        reference: row.reference,
        amount: row.amount,
        currencyCode: row.currency_code,
        accountNumber: row.account_number,
        sourceRowHash: row.source_row_hash,
        evidenceOnly: true,
      },
      validation_status: "valid" as const,
    }));
    const { data: begun, error: beginError } = await supabase.rpc("begin_alpha_sales_evidence_file", {
      p_company_id: companyId,
      p_source: source,
      p_source_kind: "collections",
      p_file_name: file.name,
      p_file_type: extension(file.name),
      p_file_sha256: metadata.file_sha256,
      p_cutoff_date: parsed.cutoffDate,
    });
    if (beginError) throw new Error(beginError.message);
    const begin = begun as { status: string; batch_id?: string; message?: string };
    if (begin.status !== "processing" || !begin.batch_id) return begin;
    batchId = begin.batch_id;
    for (let index = 0; index < rows.length; index += CHUNK_SIZE) {
      const { error } = await supabase.rpc("stage_alpha_sales_staging_rows", { p_batch_id: batchId, p_rows: rows.slice(index, index + CHUNK_SIZE), p_errors: [] });
      if (error) throw new Error(`No se pudo guardar un bloque de cobranza: ${error.message}`);
    }
    const { data, error } = await supabase.rpc("finish_alpha_sales_evidence_file", { p_batch_id: batchId, p_file_errors: [] });
    if (error) throw new Error(error.message);
    return data as StandardStagingResult;
  } catch (error) {
    const message = error instanceof Error ? error.message : "No se pudo preparar la evidencia de cobranza.";
    if (batchId) await supabase.rpc("fail_alpha_sales_staging", { p_batch_id: batchId, p_reason: message });
    throw new Error(message);
  }
}

export async function stageCollaboratorAlphaUpload(
  supabase: Client,
  companyId: string,
  file: FileInput,
  source: "manual_upload" | "local_development" = "manual_upload",
): Promise<CollaboratorStagingResult | null> {
  const parsed = await parseAlphaCollaboratorMigration(file);
  if (!parsed.recognized) return null;
  const { data, error } = await supabase.rpc("stage_alpha_import", {
    p_company_id: companyId,
    p_import_type: "collaborators",
    p_source: source,
    p_file_name: parsed.fileName,
    p_file_type: extension(parsed.fileName),
    p_file_sha256: parsed.fileHash,
    p_snapshot_date: parsed.snapshotDate,
    p_rows: parsed.rows,
    p_errors: parsed.errors,
  });
  if (error) throw new Error(error.message);
  return data as CollaboratorStagingResult;
}

export async function stageCustomerAlphaUploads(
  supabase: Client,
  companyId: string,
  files: FileInput[],
): Promise<CustomerStagingResult> {
  let startedBatchId: string | null = null;
  try {
    const payload = await parseAlphaCustomerMigration(files);
    const { data: begun, error: beginError } = await supabase.rpc("begin_alpha_customer_migration", {
      p_company_id: companyId,
      p_cutoff_date: payload.cutoffDate,
      p_content_sha256: payload.contentHash,
      p_files: payload.files,
    });
    if (beginError) throw new Error(beginError.message);
    const begin = begun as { status: string; batch_id: string };
    if (begin.status === "duplicate") return begin;
    startedBatchId = begin.batch_id;
    for (const [kind, rows] of [["customers", payload.customers], ["documents", payload.documents], ["collections", payload.collections]] as const) {
      for (let index = 0; index < rows.length; index += CHUNK_SIZE) {
        const { error } = await supabase.rpc("stage_alpha_customer_migration_rows", { p_batch_id: begin.batch_id, p_kind: kind, p_rows: rows.slice(index, index + CHUNK_SIZE) });
        if (error) throw new Error(`No se pudo guardar el bloque ${kind}: ${error.message}`);
      }
    }
    const operation = payload.isComplete ? "reconcile_alpha_customer_migration" : "finish_alpha_customer_migration_staging";
    const { data, error } = await supabase.rpc(operation, { p_batch_id: begin.batch_id });
    if (error) throw new Error(error.message);
    return data as CustomerStagingResult;
  } catch (error) {
    const message = error instanceof Error ? error.message : "No se pudo preparar la migración de Clientes/CxC.";
    if (startedBatchId) await supabase.rpc("fail_alpha_customer_migration", { p_batch_id: startedBatchId, p_reason: message });
    throw new Error(message);
  }
}

export async function stagePurchasingAlphaUploads(
  supabase: Client,
  companyId: string,
  files: FileInput[],
): Promise<PurchasingStagingResult> {
  let startedBatchId: string | null = null;
  try {
    const payload = await parseAlphaPurchasingMigration(files);
    const { data: begun, error: beginError } = await supabase.rpc("begin_alpha_purchasing_import", {
      p_company_id: companyId,
      p_cutoff_date: payload.cutoffDate,
      p_content_sha256: payload.contentHash,
      p_files: payload.files,
    });
    if (beginError) throw new Error(beginError.message);
    const begin = begun as { status: string; batch_id: string };
    if (begin.status === "duplicate") return begin;
    startedBatchId = begin.batch_id;
    for (const [kind, rows] of [
      ["suppliers", payload.suppliers],
      ["purchase_orders", payload.purchaseOrders],
      ["purchase_order_lines", payload.purchaseOrderLines],
      ["payable_documents", payload.payableDocuments],
      ["supplier_payments", payload.supplierPayments],
    ] as const) {
      for (let index = 0; index < rows.length; index += CHUNK_SIZE) {
        const { error } = await supabase.rpc("stage_alpha_purchasing_import_rows", { p_batch_id: begin.batch_id, p_kind: kind, p_rows: rows.slice(index, index + CHUNK_SIZE) });
        if (error) throw new Error(`No se pudo guardar el bloque ${kind}: ${error.message}`);
      }
    }
    const { data, error } = await supabase.rpc("finish_alpha_purchasing_import", { p_batch_id: begin.batch_id, p_summary: payload.summary, p_differences: payload.differences });
    if (error) throw new Error(error.message);
    return data as PurchasingStagingResult;
  } catch (error) {
    const message = error instanceof Error ? error.message : "No se pudo preparar Compras/CxP.";
    if (startedBatchId) await supabase.rpc("fail_alpha_purchasing_import", { p_batch_id: startedBatchId, p_reason: message });
    throw new Error(message);
  }
}

export function isStandardKind(kind: string): kind is AlphaStandardImportKind {
  return ["products", "inventory", "prices", "costs", "sales"].includes(kind);
}

function extension(fileName: string) {
  return fileName.split(".").pop()?.toLowerCase() ?? "xls";
}
