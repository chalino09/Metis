import { Agent, Runner } from "@openai/agents";
import { randomUUID } from "node:crypto";
import { z } from "zod";

export const QUOTE_INTAKE_PROMPT_VERSION = "quote-intake-v1";

export const quoteIntakeExtractionSchema = z.object({
  intent: z.enum(["quotation_request", "order", "product_question", "general_question", "support", "other"]),
  confidence: z.number().min(0).max(1),
  customer_hint: z.string().max(160).nullable(),
  items: z.array(z.object({
    raw_text: z.string().min(1).max(240),
    quantity: z.number().positive(),
    unit: z.string().max(80).nullable(),
    brand: z.string().max(120).nullable(),
    presentation: z.string().max(120).nullable(),
  })).max(50),
});

export type QuoteIntakeExtraction = z.infer<typeof quoteIntakeExtractionSchema>;

export async function extractQuoteRequest(message: string) {
  const model = process.env.QUOTE_INTAKE_MODEL ?? process.env.COLLECTION_AGENT_MODEL ?? "gpt-5.4-mini";
  const defaultRates = model === "gpt-5.4-mini" ? { input: 0.75, output: 4.5 } : null;
  const inputRate = Number(process.env.QUOTE_INTAKE_INPUT_USD_PER_MILLION ?? process.env.COLLECTION_AGENT_INPUT_USD_PER_MILLION ?? defaultRates?.input);
  const outputRate = Number(process.env.QUOTE_INTAKE_OUTPUT_USD_PER_MILLION ?? process.env.COLLECTION_AGENT_OUTPUT_USD_PER_MILLION ?? defaultRates?.output);
  if (!Number.isFinite(inputRate) || !Number.isFinite(outputRate)) throw new Error("Configura las tarifas del modelo para procesar cotizaciones.");

  const traceId = `trace_${randomUUID().replaceAll("-", "")}`;
  const agent = new Agent({
    name: "Intérprete de solicitudes de cotización Satrapy",
    model,
    instructions: [
      "Clasifica el mensaje y extrae únicamente lo que el cliente escribió.",
      "Nunca inventes productos, SKU, precios, existencias, clientes, marcas, presentaciones ni unidades.",
      "Si una cantidad no está expresada, usa 1 y reduce la confianza.",
      "raw_text debe conservar la frase útil para buscar cada producto.",
      "Un pedido explícito no es una solicitud de cotización salvo que también pida precio o cotización.",
      "Si no hay productos identificables, devuelve items vacío.",
    ].join(" "),
    outputType: quoteIntakeExtractionSchema,
  });
  const runner = new Runner({ workflowName: "Satrapy quote intake", traceId, traceIncludeSensitiveData: false, traceMetadata: { prompt_version: QUOTE_INTAKE_PROMPT_VERSION } });
  const result = await runner.run(agent, message, { maxTurns: 2 });
  if (!result.finalOutput) throw new Error("No se pudo interpretar el mensaje.");
  const extraction = quoteIntakeExtractionSchema.parse(result.finalOutput);
  const usage = result.state.usage;
  return {
    extraction,
    model,
    promptVersion: QUOTE_INTAKE_PROMPT_VERSION,
    usage: {
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      estimatedCostUsd: (usage.inputTokens * inputRate + usage.outputTokens * outputRate) / 1_000_000,
      traceId,
    },
  };
}
