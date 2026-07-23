import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function PATCH(request: NextRequest, context: { params: Promise<{ batchId: string }> }) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response("Sesión no válida.", 401);
    const { batchId } = await context.params;
    const body = await request.json() as { externalCode?: string; locationType?: string };
    if (!body.externalCode || !["sucursal", "almacen_central", "almacen_operativo", "campo"].includes(body.locationType ?? "")) {
      return response("La clasificación de ubicación no es válida.", 400);
    }
    const { data, error } = await supabase.rpc("review_staged_location", {
      p_import_batch_id: batchId,
      p_external_code: body.externalCode,
      p_location_type: body.locationType,
    });
    if (error) return response("No se pudo guardar la clasificación de ubicación.", 422);
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response("Sesión no válida.", 401);
    return response("No se pudo guardar la clasificación de ubicación.", 422);
  }
}

function response(message: string, status: number) {
  return NextResponse.json({ message }, { status, headers: { "cache-control": "no-store" } });
}
