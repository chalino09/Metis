import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type WarningAcknowledgementRow = {
  error_code: string;
  acknowledged_at: string;
  acknowledgement_note: string | null;
  acknowledged_by: string | null;
};

type StagingPreviewPayload = {
  batch?: { import_type?: string };
  error_groups?: Array<{
    error_code: string;
    severity: "error" | "warning";
    total: number;
    pending: number;
    acknowledgement?: {
      acknowledged_at: string;
      acknowledgement_note: string | null;
      acknowledged_by: string | null;
      actor_name: string | null;
    };
  }>;
  [key: string]: unknown;
};

type SalesMissingSkuReview = {
  total_rows: number;
  groups: Array<{
    description: string;
    unit: string | null;
    row_count: number;
    amount: number;
    row_numbers: number[];
    source_invoices: string[];
    can_map: boolean;
  }>;
};
type SalesMissingSkuContinuationReview = {
  total_rows: number;
  eligible_rows: number;
  items: Array<{
    row_number: number;
    previous_row_number: number;
    fragment: string;
    previous_description: string;
    full_description: string;
    product_id: string;
    product_alpha_sku: string;
    product_name: string;
    product_unit: string | null;
    catalog_match: boolean;
    source_invoice: string | null;
    source_folio: string | null;
  }>;
};

export async function GET(request: NextRequest, context: { params: Promise<{ batchId: string }> }) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response("Sesión no válida.", 401);

    const { batchId } = await context.params;
    const page = positiveInteger(request.nextUrl.searchParams.get("page"), 1);
    const pageSize = Math.min(positiveInteger(request.nextUrl.searchParams.get("pageSize"), 50), 200);
    const status = request.nextUrl.searchParams.get("status") || null;
    const errorCode = request.nextUrl.searchParams.get("errorCode") || null;
    const { data, error } = await supabase.rpc("get_import_staging_preview", {
      p_import_batch_id: batchId,
      p_page: page,
      p_page_size: pageSize,
      p_status: status,
      p_error_code: errorCode,
    });
    if (error) return response(error.message || "No se pudo recuperar el preview.", 422);
    const preview = data as StagingPreviewPayload;
    const acknowledgedCodes = (preview.error_groups ?? [])
      .filter((group) => group.severity === "warning" && group.pending === 0)
      .map((group) => group.error_code);
    if (acknowledgedCodes.length) {
      const { data: acknowledgementRows } = await supabase
        .from("import_staging_errors")
        .select("error_code,acknowledged_at,acknowledgement_note,acknowledged_by")
        .eq("import_batch_id", batchId)
        .eq("severity", "warning")
        .in("error_code", acknowledgedCodes)
        .not("acknowledged_at", "is", null)
        .order("acknowledged_at", { ascending: false });
      const latestByCode = new Map<string, WarningAcknowledgementRow>();
      for (const row of (acknowledgementRows ?? []) as WarningAcknowledgementRow[]) {
        if (!latestByCode.has(row.error_code)) latestByCode.set(row.error_code, row);
      }
      const actorIds = [...new Set([...latestByCode.values()].map((row) => row.acknowledged_by).filter((id): id is string => Boolean(id)))];
      const actorNames = new Map<string, string>();
      if (actorIds.length) {
        const { data: profiles } = await supabase.from("profiles").select("id,full_name").in("id", actorIds);
        for (const profile of profiles ?? []) actorNames.set(profile.id, profile.full_name || "Usuario registrado");
      }
      preview.error_groups = (preview.error_groups ?? []).map((group) => {
        const acknowledgement = latestByCode.get(group.error_code);
        return acknowledgement ? {
          ...group,
          acknowledgement: {
            acknowledged_at: acknowledgement.acknowledged_at,
            acknowledgement_note: acknowledgement.acknowledgement_note,
            acknowledged_by: acknowledgement.acknowledged_by,
            actor_name: acknowledgement.acknowledged_by ? actorNames.get(acknowledgement.acknowledged_by) ?? "Usuario registrado" : null,
          },
        } : group;
      });
    }
    if (["prices", "costs"].includes(preview.batch?.import_type ?? "")) {
      const { data: requirements, error: requirementsError } = await supabase.rpc("get_commercial_import_requirements", { p_import_batch_id: batchId });
      if (requirementsError) return response(requirementsError.message || "No se pudo recuperar la revisión comercial.", 422);
      return NextResponse.json({ ...preview, commercial_requirements: requirements }, { headers: { "cache-control": "no-store" } });
    }
    if (preview.batch?.import_type === "products") {
      const { data: taxSummary, error: taxSummaryError } = await supabase.rpc("get_staged_product_tax_summary", { p_import_batch_id: batchId });
      if (taxSummaryError) return response(taxSummaryError.message || "No se pudo recuperar el resumen fiscal.", 422);
      return NextResponse.json({ ...preview, tax_summary: taxSummary }, { headers: { "cache-control": "no-store" } });
    }
    if (preview.batch?.import_type === "sales") {
      const [salesEvidenceResult, missingSkuResult, continuationResult, promotionResult] = await Promise.all([
        supabase.rpc("get_alpha_sales_evidence_status", { p_import_batch_id: batchId }),
        supabase.rpc("get_alpha_sales_missing_sku_review", { p_import_batch_id: batchId }),
        supabase.rpc("get_alpha_sales_missing_sku_continuation_review", { p_import_batch_id: batchId }),
        supabase.rpc("preview_alpha_historical_sales_promotion", { p_import_batch_id: batchId }),
      ]);
      if (salesEvidenceResult.error) return response(salesEvidenceResult.error.message || "No se pudo recuperar la conciliación histórica.", 422);
      if (missingSkuResult.error) return response(missingSkuResult.error.message || "No se pudo recuperar la revisión de partidas sin SKU.", 422);
      if (continuationResult.error && !/does not exist|could not find the function/i.test(continuationResult.error.message)) return response(continuationResult.error.message || "No se pudo recuperar la revisión de continuaciones.", 422);
      if (promotionResult.error && !/does not exist|could not find the function/i.test(promotionResult.error.message)) return response(promotionResult.error.message || "No se pudo validar la importación histórica.", 422);
      const continuationReview = continuationResult.error ? { total_rows: 0, eligible_rows: 0, items: [] } : continuationResult.data as SalesMissingSkuContinuationReview;
      return NextResponse.json({ ...preview, sales_evidence: salesEvidenceResult.data, sales_missing_sku_review: missingSkuResult.data as SalesMissingSkuReview, sales_missing_sku_continuation_review: continuationReview, sales_promotion: promotionResult.error ? null : promotionResult.data }, { headers: { "cache-control": "no-store" } });
    }
    return NextResponse.json(preview, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response("Sesión no válida.", 401);
    return response("No se pudo recuperar el preview persistente.", 422);
  }
}

function positiveInteger(value: string | null, fallback: number) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function response(message: string, status: number) {
  return NextResponse.json({ message }, { status, headers: { "cache-control": "no-store" } });
}
