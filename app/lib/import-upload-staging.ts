import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { parseAlphaCustomerMigration } from "@/app/lib/alpha-customer-migration";
import { parseAlphaPurchasingMigration } from "@/app/lib/alpha-purchasing-migration";
import { parseAlphaWorkbook } from "@/app/lib/alpha";
import { buildStagingPayload } from "@/app/lib/import-staging";
import { validateReferencedProducts } from "@/app/lib/import-validation";
import type { AlphaStandardImportKind } from "@/app/lib/alpha-upload-routing";

type FileInput = Pick<File, "name" | "arrayBuffer">;
type Client = SupabaseClient;
export type StandardStagingResult = { status: string; batch_id?: string; message?: string; records_received?: number; valid_rows?: number; warning_rows?: number; error_rows?: number };
export type CustomerStagingResult = { status: string; batch_id?: string; message?: string; files_staged?: number; records_received?: number; reconciled_customers?: number; customers_with_differences?: number };
export type PurchasingStagingResult = { status: string; batch_id?: string; message?: string; errors?: number; warnings?: number };

const CHUNK_SIZE = 400;

export async function stageStandardAlphaUpload(
  supabase: Client,
  companyId: string,
  file: FileInput,
  source: "manual_upload" | "local_development" = "manual_upload",
): Promise<StandardStagingResult> {
  const parsed = await parseAlphaWorkbook(await file.arrayBuffer(), file.name, source === "manual_upload" ? "manual" : "local_development");
  const additionalIssues = await validateReferencedProducts(parsed, companyId, supabase);
  const payload = buildStagingPayload(parsed, additionalIssues);
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
  return ["products", "inventory", "prices", "costs"].includes(kind);
}

function extension(fileName: string) {
  return fileName.split(".").pop()?.toLowerCase() ?? "xls";
}
