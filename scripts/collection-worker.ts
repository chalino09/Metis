import { createClient } from "@supabase/supabase-js";
import { getGlobalTraceProvider } from "@openai/agents";
import { prepareCollectionProposal } from "../app/lib/collection-agent.ts";

const workerId = process.env.COLLECTION_WORKER_ID ?? `collection-worker-${process.pid}`;
const batchSize = Math.min(Math.max(Number(process.env.COLLECTION_WORKER_BATCH_SIZE ?? 25), 1), 100);
if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) throw new Error("Faltan credenciales server-side.");
const supabase = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const { data: tasks, error } = await supabase.rpc("collection_claim_tasks", { p_worker_id: workerId, p_batch_size: batchSize, p_lease_seconds: 60 });
if (error) throw error;
for (const task of tasks ?? []) {
  try {
    const result:Record<string,unknown>={ mode: "deterministic", provider: null };
    if(task.task_type==="assisted_review"){
      if(!process.env.OPENAI_API_KEY)throw new Error("Falta OPENAI_API_KEY para la tarea asistida.");
      const contextResponse=await supabase.rpc("collection_get_agent_context",{p_task_id:task.id,p_worker_id:workerId});
      if(contextResponse.error)throw contextResponse.error;
      const context=contextResponse.data as Record<string,unknown>;
      const caseId=String((context.case as {id?:string}|undefined)?.id??task.case_id);
      const prepared=await prepareCollectionProposal(caseId,context);
      const proposalResponse=await supabase.rpc("collection_record_agent_proposal",{
        p_task_id:task.id,p_worker_id:workerId,
        p_content:{summary:prepared.proposal.summary,recommendation:prepared.proposal.recommendation,channel:prepared.proposal.channel,draft:prepared.proposal.draft},
        p_evidence:prepared.proposal.evidence,p_reason:prepared.proposal.reason,p_risk:prepared.proposal.risk,
        p_model:prepared.model,p_prompt_version:prepared.promptVersion,p_expires_at:new Date(Date.now()+24*60*60*1000).toISOString(),p_usage:{input_tokens:prepared.usage.inputTokens,output_tokens:prepared.usage.outputTokens,trace_id:prepared.usage.traceId},
      });
      if(proposalResponse.error)throw proposalResponse.error;
      const finishResponse=await supabase.rpc("collection_finish_assisted_task",{p_task_id:task.id,p_worker_id:workerId,p_model:prepared.model,p_prompt_version:prepared.promptVersion,p_input_tokens:prepared.usage.inputTokens,p_output_tokens:prepared.usage.outputTokens,p_estimated_cost_usd:prepared.usage.estimatedCostUsd,p_trace_id:prepared.usage.traceId,p_result:{mode:"assisted",provider:"openai",proposal_id:(proposalResponse.data as {id?:string}|null)?.id,requests:prepared.usage.requests,total_tokens:prepared.usage.totalTokens,input_usd_per_million:prepared.usage.inputUsdPerMillion,output_usd_per_million:prepared.usage.outputUsdPerMillion}});
      if(finishResponse.error)throw finishResponse.error;
      continue;
    }else if(!["internal_healthcheck","internal_follow_up"].includes(task.task_type))throw new Error(`Tipo de tarea de cobranza no soportado: ${task.task_type}`);
    const { error: finishError } = await supabase.rpc("collection_finish_task", { p_task_id: task.id, p_worker_id: workerId, p_success: true, p_result: result });
    if (finishError) throw finishError;
  } catch (taskError) {
    const message = taskError instanceof Error ? taskError.message : "Error no identificado";
    const { error: finishError } = await supabase.rpc("collection_finish_task", { p_task_id: task.id, p_worker_id: workerId, p_success: false, p_error: message, p_result: {} });
    if (finishError) throw finishError;
  }
}
await getGlobalTraceProvider().forceFlush();
console.log(JSON.stringify({ worker_id: workerId, claimed: tasks?.length ?? 0 }));
