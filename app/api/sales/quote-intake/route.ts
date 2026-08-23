import { NextRequest, NextResponse } from "next/server";
import { extractQuoteRequest } from "@/app/lib/quote-intake-agent";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const MAX_BYTES = 12_000;

type Body = { company_id?: string; location_id?: string; customer_id?: string | null; message?: string };

export async function POST(request: NextRequest) {
  const startedAt = Date.now();
  let requestId: string | null = null;
  try {
    const raw = await request.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BYTES) return json({ error: "El mensaje es demasiado largo." }, 413);
    const body = JSON.parse(raw) as Body;
    const message = String(body.message ?? "").trim();
    if (!body.company_id || !body.location_id || message.length < 3) return json({ error: "Selecciona una sucursal y captura el mensaje del cliente." }, 400);
    if (message.length > 4_000) return json({ error: "El mensaje debe tener 4,000 caracteres o menos." }, 400);

    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: auth } = await supabase.auth.getUser();
    if (!auth.user) return json({ error: "Tu sesión venció. Inicia sesión nuevamente." }, 401);
    const started = await supabase.rpc("start_sales_quote_intake", { p_company_id: body.company_id, p_location_id: body.location_id, p_customer_id: body.customer_id ?? null, p_message: message });
    if (started.error || !started.data) return json({ error: started.error?.message ?? "No se pudo registrar el mensaje." }, 400);
    requestId = String((started.data as { id?: string }).id ?? started.data);

    const prepared = await extractQuoteRequest(message);
    const completed = await supabase.rpc("complete_sales_quote_intake", {
      p_company_id: body.company_id,
      p_request_id: requestId,
      p_intent: prepared.extraction.intent,
      p_intent_confidence: prepared.extraction.confidence,
      p_customer_hint: prepared.extraction.customer_hint,
      p_items: prepared.extraction.items,
      p_model: prepared.model,
      p_prompt_version: prepared.promptVersion,
      p_raw_output: prepared.extraction,
      p_input_tokens: prepared.usage.inputTokens,
      p_output_tokens: prepared.usage.outputTokens,
      p_estimated_cost_usd: prepared.usage.estimatedCostUsd,
      p_trace_id: prepared.usage.traceId,
      p_latency_ms: Date.now() - startedAt,
    });
    if (completed.error) throw new Error(completed.error.message);
    return json(completed.data, 200);
  } catch (error) {
    const message = error instanceof SyntaxError ? "El contenido enviado no es válido." : error instanceof Error ? error.message : "No se pudo analizar el mensaje.";
    if (requestId) {
      try {
        const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
        await supabase.rpc("fail_sales_quote_intake", { p_request_id: requestId, p_error: message, p_latency_ms: Date.now() - startedAt });
      } catch { /* La respuesta principal conserva el error original. */ }
    }
    return json({ error: message }, error instanceof SyntaxError ? 400 : 422);
  }
}

function json(body: unknown, status: number) {
  return NextResponse.json(body, { status, headers: { "cache-control": "private, no-store", vary: "authorization", "x-content-type-options": "nosniff" } });
}
