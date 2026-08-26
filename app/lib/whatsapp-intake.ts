import "server-only";
import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { extractQuoteRequest } from "@/app/lib/quote-intake-agent";

// The service-role client is intentionally schema-agnostic because these RPCs
// are introduced by migrations and are not part of generated database types.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AdminClient=SupabaseClient<any>;

export async function processWhatsappText(admin:AdminClient,input:{companyId:string;connectionId:string;locationId:string;customerId?:string|null;messageId:string;sender:string;message:string;rawPayload:string}){
  const startedAt=Date.now();
  const digest=createHash("sha256").update(input.rawPayload).digest("hex");
  const registered=await admin.rpc("register_integration_webhook",{p_company_id:input.companyId,p_provider_code:"meta_whatsapp",p_provider_event_id:input.messageId,p_event_type:"messages",p_payload_sha256:digest,p_payload:{message_id:input.messageId,sender:input.sender,message:input.message,location_id:input.locationId}});
  if(registered.error)throw new Error(registered.error.message);
  const receipt=registered.data as {receipt_id?:string;duplicate?:boolean;should_process?:boolean;retry?:boolean;status?:string};
  if(!receipt.receipt_id)throw new Error("No se registró el webhook.");
  if(!receipt.should_process)return{duplicate:true,receiptId:receipt.receipt_id,requestId:null,status:receipt.status??"duplicate"};
  let requestId:string|null=null;
  try{
    const started=await admin.rpc("start_external_sales_quote_intake",{p_connection_id:input.connectionId,p_location_id:input.locationId,p_customer_id:input.customerId??null,p_message:input.message,p_source_message_id:input.messageId,p_source_sender:input.sender,p_receipt_id:receipt.receipt_id});
    if(started.error||!started.data)throw new Error(started.error?.message??"No se creó la solicitud de cotización.");
    const startResult=started.data as {id?:string;duplicate?:boolean};requestId=String(startResult.id??"");
    if(startResult.duplicate){await admin.rpc("complete_integration_webhook",{p_receipt_id:receipt.receipt_id,p_succeeded:true,p_error_code:null,p_error_message:null});return{duplicate:true,receiptId:receipt.receipt_id,requestId,status:"duplicate"};}
    const prepared=await extractQuoteRequest(input.message);
    const completed=await admin.rpc("complete_external_sales_quote_intake",{p_connection_id:input.connectionId,p_request_id:requestId,p_intent:prepared.extraction.intent,p_intent_confidence:prepared.extraction.confidence,p_customer_hint:prepared.extraction.customer_hint,p_items:prepared.extraction.items,p_model:prepared.model,p_prompt_version:prepared.promptVersion,p_raw_output:prepared.extraction,p_input_tokens:prepared.usage.inputTokens,p_output_tokens:prepared.usage.outputTokens,p_estimated_cost_usd:prepared.usage.estimatedCostUsd,p_trace_id:prepared.usage.traceId,p_latency_ms:Date.now()-startedAt});
    if(completed.error)throw new Error(completed.error.message);
    await admin.rpc("complete_integration_webhook",{p_receipt_id:receipt.receipt_id,p_succeeded:true,p_error_code:null,p_error_message:null});
    const result=completed.data as {status?:string};
    return{duplicate:false,receiptId:receipt.receipt_id,requestId,status:result.status??"processed",detail:completed.data};
  }catch(error){
    const message=error instanceof Error?error.message:"No se pudo procesar el mensaje de WhatsApp.";
    if(requestId)await admin.rpc("fail_external_sales_quote_intake",{p_connection_id:input.connectionId,p_request_id:requestId,p_error:message,p_latency_ms:Date.now()-startedAt});
    await admin.rpc("complete_integration_webhook",{p_receipt_id:receipt.receipt_id,p_succeeded:false,p_error_code:"WHATSAPP_INTAKE_FAILED",p_error_message:message});
    throw error;
  }
}
