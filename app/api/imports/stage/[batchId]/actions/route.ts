import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type ActionBody = {
  action?: "resolve_product" | "resolve_sales_missing_sku" | "resolve_sales_missing_sku_continuations" | "promote_sales_history" | "acknowledge_warnings" | "discard" | "retry" | "confirm" | "map_currency" | "map_price_list";
  stagingRowId?: string;
  productId?: string;
  errorCode?: string;
  reason?: string;
  sourceLabel?: string;
  currencyCode?: string;
  externalCode?: string;
  semanticCode?: string;
  isDefault?: boolean;
  assortmentIds?: string[];
  sourceDescription?: string;
  sourceUnit?: string | null;
};

export async function POST(request: NextRequest, context: { params: Promise<{ batchId: string }> }) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response("Sesión no válida.", 401);
    const { batchId } = await context.params;
    const body = await request.json() as ActionBody;
    let importType: string | undefined;
    if (body.action === "confirm") {
      const { data: batch, error: batchError } = await supabase.from("import_batches").select("import_type").eq("id", batchId).single();
      if (batchError) return response("No se pudo validar el lote.", 422);
      importType = batch.import_type;
    }
    const rpc = rpcForAction(batchId, body, importType);
    if (!rpc) return response("La operación solicitada no es válida.", 400);

    const { data, error } = await supabase.rpc(rpc.name, rpc.parameters);
    if (error) return response(error.message || "No se pudo completar la operación.", 422);
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response("Sesión no válida.", 401);
    return response("No se pudo completar la operación de staging.", 422);
  }
}

function rpcForAction(batchId: string, body: ActionBody, importType?: string) {
  if (body.action === "confirm") {
    if (importType === "sales") return null;
    if (importType === "products") {
      return {
        name: "confirm_product_import_with_assortments",
        parameters: {
          p_import_batch_id: batchId,
          p_assortment_ids: Array.isArray(body.assortmentIds) ? body.assortmentIds : [],
        },
      };
    }
    if (importType === "collaborators") {
      return { name: "confirm_collaborator_import", parameters: { p_import_batch_id: batchId } };
    }
    return { name: ["prices", "costs"].includes(importType ?? "") ? "confirm_commercial_import" : "confirm_staged_import", parameters: { p_import_batch_id: batchId } };
  }
  if (body.action === "map_currency" && body.sourceLabel && body.currencyCode) return { name: "review_staged_currency", parameters: { p_import_batch_id: batchId, p_source_label: body.sourceLabel, p_currency_code: body.currencyCode } };
  if (body.action === "map_price_list" && body.externalCode && body.semanticCode) return { name: "review_staged_price_list", parameters: { p_import_batch_id: batchId, p_external_code: body.externalCode, p_semantic_code: body.semanticCode, p_is_default: Boolean(body.isDefault) } };
  if (body.action === "resolve_product" && body.stagingRowId && body.productId && body.reason?.trim()) {
    return {
      name: "resolve_staged_product",
      parameters: {
        p_import_batch_id: batchId,
        p_staging_row_id: body.stagingRowId,
        p_product_id: body.productId,
        p_reason: body.reason.trim(),
      },
    };
  }
  if (body.action === "resolve_sales_missing_sku" && body.sourceDescription?.trim() && body.productId && body.reason?.trim()) {
    return {
      name: "resolve_alpha_sales_missing_sku",
      parameters: {
        p_import_batch_id: batchId,
        p_source_description: body.sourceDescription.trim(),
        p_source_unit: body.sourceUnit?.trim() || null,
        p_product_id: body.productId,
        p_reason: body.reason.trim(),
      },
    };
  }
  if (body.action === "resolve_sales_missing_sku_continuations" && body.reason?.trim()) {
    return {
      name: "resolve_alpha_sales_missing_sku_continuations",
      parameters: { p_import_batch_id: batchId, p_reason: body.reason.trim() },
    };
  }
  if (body.action === "promote_sales_history" && body.reason?.trim()) {
    return {
      name: "promote_alpha_historical_sales",
      parameters: { p_import_batch_id: batchId, p_reason: body.reason.trim() },
    };
  }
  if (body.action === "acknowledge_warnings" && body.errorCode && body.reason?.trim()) {
    return {
      name: "acknowledge_staged_warnings",
      parameters: {
        p_import_batch_id: batchId,
        p_error_code: body.errorCode,
        p_note: body.reason.trim(),
      },
    };
  }
  if (body.action === "discard" && body.reason?.trim()) {
    return {
      name: "discard_staged_import",
      parameters: { p_import_batch_id: batchId, p_reason: body.reason.trim() },
    };
  }
  if (body.action === "retry" && body.reason?.trim()) {
    return {
      name: "retry_staged_import",
      parameters: { p_import_batch_id: batchId, p_reason: body.reason.trim() },
    };
  }
  return null;
}

function response(message: string, status: number) {
  return NextResponse.json({ message }, { status, headers: { "cache-control": "no-store" } });
}
