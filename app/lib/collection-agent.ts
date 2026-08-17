import { Agent, Runner, tool } from "@openai/agents";
import { randomUUID } from "node:crypto";
import { z } from "zod";

export const COLLECTION_AGENT_PROMPT_VERSION="collection-assistant-v1";
export const collectionProposalSchema=z.object({
  summary:z.string().min(1).max(1200),
  recommendation:z.enum(["prepare_contact","wait","escalate_human"]),
  channel:z.enum(["phone","email","whatsapp","none"]),
  draft:z.string().max(2500),
  reason:z.string().min(1).max(1200),
  risk:z.enum(["low","medium","high"]),
  evidence:z.array(z.object({source:z.enum(["receivable","payment","contact","case"]),reference:z.string().min(1).max(160)})).max(20),
});
export type CollectionProposal=z.infer<typeof collectionProposalSchema>;
type AgentContext={caseId:string;context:Record<string,unknown>};

const contextParameters=z.object({case_id:z.string().uuid()});
const contextTool=tool<typeof contextParameters,AgentContext>({
  name:"consultar_contexto_cobranza",
  description:"Consulta el contexto canónico, de solo lectura, del caso de cobranza asignado.",
  parameters:contextParameters,
  inputGuardrails:[{name:"limitar_al_caso_asignado",run:async({context,toolCall})=>{
    const args=JSON.parse(toolCall.arguments) as {case_id?:string};
    return args.case_id===context.context.caseId?{behavior:{type:"allow"}}:{behavior:{type:"throwException"}};
  }}],
  execute:async({case_id},runContext)=>{
    if(!runContext||case_id!==runContext.context.caseId)throw new Error("Caso fuera del alcance asignado.");
    return runContext.context.context;
  },
});

export async function prepareCollectionProposal(caseId:string,context:Record<string,unknown>){
  const model=process.env.COLLECTION_AGENT_MODEL??"gpt-5.4-mini";
  const defaultRates=model==="gpt-5.4-mini"?{input:0.75,output:4.5}:null;
  const inputRate=Number(process.env.COLLECTION_AGENT_INPUT_USD_PER_MILLION??defaultRates?.input);
  const outputRate=Number(process.env.COLLECTION_AGENT_OUTPUT_USD_PER_MILLION??defaultRates?.output);
  if(!Number.isFinite(inputRate)||!Number.isFinite(outputRate))throw new Error("Configura las tarifas por millón de tokens para el modelo de cobranza.");
  const traceId=`trace_${randomUUID().replaceAll("-","")}`;
  const agent=new Agent<AgentContext,typeof collectionProposalSchema>({
    name:"Asistente de cobranza Satrapy",
    model,
    instructions:[
      "Preparas propuestas de cobranza para revisión humana; nunca ejecutas acciones.",
      "Debes consultar la herramienta de contexto antes de concluir.",
      "No inventes saldos, pagos, contactos, acuerdos, descuentos ni fechas.",
      "Si falta canal, existe ambigüedad o se requiere negociar, recomienda escalar a una persona.",
      "El borrador debe ser sobrio, respetuoso y no afirmar consecuencias no autorizadas.",
    ].join(" "),
    tools:[contextTool],
    outputType:collectionProposalSchema,
  });
  const runner=new Runner({workflowName:"Satrapy collection proposal",traceId,groupId:caseId,traceIncludeSensitiveData:false,traceMetadata:{prompt_version:COLLECTION_AGENT_PROMPT_VERSION}});
  const result=await runner.run(agent,`Analiza el caso ${caseId} y prepara una propuesta estructurada.`,{context:{caseId,context},maxTurns:4});
  if(!result.finalOutput)throw new Error("El agente no produjo una propuesta estructurada.");
  const usage=result.state.usage;
  const estimatedCostUsd=(usage.inputTokens*inputRate+usage.outputTokens*outputRate)/1_000_000;
  return {proposal:collectionProposalSchema.parse(result.finalOutput),model,promptVersion:COLLECTION_AGENT_PROMPT_VERSION,usage:{requests:usage.requests,inputTokens:usage.inputTokens,outputTokens:usage.outputTokens,totalTokens:usage.totalTokens,inputUsdPerMillion:inputRate,outputUsdPerMillion:outputRate,estimatedCostUsd,traceId}};
}
