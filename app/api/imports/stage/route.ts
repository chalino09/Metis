import { NextRequest, NextResponse } from "next/server";
import { stageStandardAlphaUpload } from "@/app/lib/import-upload-staging";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function POST(request: NextRequest) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return message("Sesión no válida.", 401);

    const form = await request.formData();
    const companyId = form.get("companyId");
    const upload = form.get("file");
    if (typeof companyId !== "string" || !(upload instanceof File)) {
      return message("Falta el archivo o la empresa para generar el staging.", 400);
    }
    if (!/\.xlsx?$/i.test(upload.name)) {
      return message("Selecciona un archivo XLS o XLSX.", 400);
    }

    const result = await stageStandardAlphaUpload(supabase, companyId, upload);
    if (result.status === "duplicate") {
      return NextResponse.json(result, { status: 409, headers: { "cache-control": "no-store" } });
    }
    return NextResponse.json(result, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return message("Sesión no válida.", 401);
    return message("No se pudo analizar el archivo de origen.", 422);
  }
}

function message(messageText: string, status: number) {
  return NextResponse.json({ message: messageText }, { status, headers: { "cache-control": "no-store" } });
}
