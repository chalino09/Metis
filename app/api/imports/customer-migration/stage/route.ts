import { NextRequest, NextResponse } from "next/server";
import { stageCustomerAlphaUploads } from "@/app/lib/import-upload-staging";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(request: NextRequest) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return message("Sesión no válida.", 401);
    const form = await request.formData();
    const companyId = form.get("companyId");
    const files = form.getAll("files").filter((entry): entry is File => entry instanceof File);
    if (typeof companyId !== "string" || files.length < 1) return message("Selecciona al menos un Excel de Clientes/CxC.", 400);
    const result = await stageCustomerAlphaUploads(supabase, companyId, files);
    return NextResponse.json(result, { headers: noStore });
  } catch (error) {
    const text = error instanceof Error ? error.message : "No se pudo preparar la migración de Clientes/CxC.";
    return message(text, 422);
  }
}

const noStore = { "cache-control": "no-store" };
function message(text: string, status: number) { return NextResponse.json({ message: text }, { status, headers: noStore }); }
