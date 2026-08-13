import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type StagedBatchRow = {
  id: string;
  import_type: string;
  status: string;
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
  original_name: string | null;
  file_type: string | null;
};

type ImportFileRow = {
  import_batch_id: string;
  original_name: string;
  file_type: string;
};

export async function GET(request: NextRequest) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response("Sesión no válida.", 401);

    const companyId = request.nextUrl.searchParams.get("companyId");
    if (!companyId) return response("Empresa inválida.", 400);

    const page = positiveInteger(request.nextUrl.searchParams.get("page"), 1);
    const pageSize = Math.min(positiveInteger(request.nextUrl.searchParams.get("pageSize"), 20), 100);

    const { data, error } = await supabase.rpc("list_import_staging_batches_page", {
      p_company_id: companyId,
      p_page: page,
      p_page_size: pageSize,
    });
    if (error) return response(error.message || "No se pudieron recuperar las importaciones en staging.", 422);

    const result = data as { items?: StagedBatchRow[]; pagination?: { page: number; page_size: number; total: number } } | null;
    const items = result?.items ?? [];
    const batchIds = items.map((batch) => batch.id);
    const filesByBatch = new Map<string, Array<{ original_name: string; file_type: string }>>();
    if (batchIds.length) {
      const { data: fileRows, error: filesError } = await supabase
        .from("import_files")
        .select("import_batch_id,original_name,file_type")
        .in("import_batch_id", batchIds)
        .order("created_at", { ascending: true });
      if (filesError) return response(filesError.message || "No se pudieron recuperar los archivos de staging.", 422);
      for (const file of (fileRows ?? []) as ImportFileRow[]) {
        const files = filesByBatch.get(file.import_batch_id) ?? [];
        files.push({ original_name: file.original_name, file_type: file.file_type });
        filesByBatch.set(file.import_batch_id, files);
      }
    }

    return NextResponse.json({ batches: items.map((batch) => ({
      ...batch,
      import_files: filesByBatch.get(batch.id) ?? (batch.original_name ? [{ original_name: batch.original_name, file_type: batch.file_type }] : []),
    })), pagination: result?.pagination ?? { page, page_size: pageSize, total: 0 } }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response("Sesión no válida.", 401);
    return response("No se pudieron recuperar las importaciones en staging.", 422);
  }
}

function positiveInteger(value: string | null, fallback: number) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function response(message: string, status: number) {
  return NextResponse.json({ message }, { status, headers: { "cache-control": "no-store" } });
}
