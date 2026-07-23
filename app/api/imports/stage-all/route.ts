import { NextRequest, NextResponse } from "next/server";
import { alphaUploadLabel, classifyAlphaUpload, isCustomerAlphaUpload, isPurchasingAlphaUpload } from "@/app/lib/alpha-upload-routing";
import { stageCustomerAlphaUploads, stagePurchasingAlphaUploads, stageStandardAlphaUpload } from "@/app/lib/import-upload-staging";
import { purchasingUploadPackageState } from "@/app/lib/purchasing-upload-package";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import { detectAndStageAccountingUpload } from "@/app/lib/accounting-import";
import { detectAndStageBankStatement } from "@/app/lib/bank-statement-import";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

type UploadResult = {
  files: string[];
  kind: string;
  label: string;
  status: "staged" | "awaiting_configuration" | "validation_failed" | "duplicate" | "failed" | "unrecognized";
  batch_id?: string;
  message?: string;
};

export async function POST(request: NextRequest) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response({ message: "Sesión no válida." }, 401);

    const form = await request.formData();
    const companyId = form.get("companyId");
    const files = form.getAll("files").filter((entry): entry is File => entry instanceof File);
    if (typeof companyId !== "string" || !files.length) return response({ message: "Selecciona al menos un archivo para preparar la migración." }, 400);

    const customerFiles: File[] = [];
    const purchasingFiles: File[] = [];
    const standardFiles: Array<{ file: File; kind: ReturnType<typeof classifyAlphaUpload> }> = [];
    const results: UploadResult[] = [];
    for (const file of files) {
      if (!/\.(xlsx?|csv)$/i.test(file.name)) {
        results.push({ files: [file.name], kind: "unrecognized", label: "Archivo no reconocido", status: "unrecognized", message: "Solo se aceptan archivos CSV, XLS o XLSX." });
        continue;
      }
      const kind = classifyAlphaUpload(file.name);
      if (isCustomerAlphaUpload(kind)) {
        customerFiles.push(file);
        continue;
      }
      if (isPurchasingAlphaUpload(kind)) {
        purchasingFiles.push(file);
        continue;
      }
      standardFiles.push({ file, kind });
    }

    if (purchasingFiles.length) {
      const packageState = purchasingUploadPackageState(purchasingFiles.map((file) => file.name));
      if (!packageState.complete) {
        return response({ message: `Compras/CxP requiere exactamente cata_prv, rpcon2, lfchvenc y pag_det en el mismo paquete. Detectados: ${packageState.detected}/4.` }, 422);
      }
    }

    for (const { file, kind } of standardFiles) {
      try {
        if (kind === "unrecognized") {
          const banking = await detectAndStageBankStatement(supabase, companyId, file);
          if (banking) {
            results.push({ files: [file.name], kind: banking.kind, label: banking.label, status: normalizeStatus(banking.status), batch_id: banking.batch_id, message: banking.message });
            continue;
          }
          const accounting = await detectAndStageAccountingUpload(supabase, companyId, file);
          results.push(accounting ? {
            files: [file.name], kind: accounting.kind, label: accounting.label,
            status: normalizeStatus(accounting.status), batch_id: accounting.batch_id, message: accounting.message,
          } : { files: [file.name], kind, label: alphaUploadLabel(kind), status: "unrecognized", message: "La estructura del archivo no corresponde a ningún origen admitido." });
          continue;
        }
        const staged = await stageStandardAlphaUpload(supabase, companyId, file);
        results.push({
          files: [file.name], kind, label: alphaUploadLabel(kind),
          status: normalizeStatus(staged.status),
          batch_id: staged.batch_id, message: staged.message,
        });
      } catch (error) {
        results.push({ files: [file.name], kind, label: alphaUploadLabel(kind), status: "failed", message: error instanceof Error ? error.message : "No se pudo guardar el staging." });
      }
    }

    if (customerFiles.length) {
      try {
        const staged = await stageCustomerAlphaUploads(supabase, companyId, customerFiles);
        results.push({ files: customerFiles.map((file) => file.name), kind: "customers", label: "Clientes y CxC", status: normalizeStatus(staged.status), batch_id: staged.batch_id, message: staged.message });
      } catch (error) {
        const detail = error instanceof Error ? error.message : "No se pudo preparar el paquete de Clientes/CxC.";
        results.push({ files: customerFiles.map((file) => file.name), kind: "customers", label: "Clientes y CxC", status: "validation_failed", message: `Estructura incompatible: ${detail}` });
      }
    }

    if (purchasingFiles.length) {
      try {
        const staged = await stagePurchasingAlphaUploads(supabase, companyId, purchasingFiles);
        results.push({ files: purchasingFiles.map((file) => file.name), kind: "purchasing", label: "Proveedores, Compras y CxP", status: normalizeStatus(staged.status), batch_id: staged.batch_id, message: staged.message });
      } catch (error) {
        const detail = error instanceof Error ? error.message : "No se pudo preparar el paquete de Compras/CxP.";
        results.push({ files: purchasingFiles.map((file) => file.name), kind: "purchasing", label: "Proveedores, Compras y CxP", status: "validation_failed", message: `Estructura incompatible: ${detail}` });
      }
    }

    return NextResponse.json({ results }, { headers: noStore });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response({ message: "Sesión no válida." }, 401);
    return response({ message: "No se pudo preparar la carga de migración." }, 422);
  }
}

function normalizeStatus(status: string): UploadResult["status"] {
  return status === "duplicate" ? "duplicate" : status === "validation_failed" ? "validation_failed" : status === "awaiting_metadata" || status === "awaiting_configuration" ? "awaiting_configuration" : status === "staged" || status === "ready_to_promote" ? "staged" : "failed";
}

const noStore = { "cache-control": "no-store" };
function response(payload: { message: string }, status: number) {
  return NextResponse.json(payload, { status, headers: noStore });
}
