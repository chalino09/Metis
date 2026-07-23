import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime="nodejs";export const dynamic="force-dynamic";

export async function GET(request:NextRequest){
  try{
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));const {data:authData}=await supabase.auth.getUser();if(!authData.user)return response("Sesión no válida.",401);
    const companyId=request.nextUrl.searchParams.get("companyId");if(!companyId)return response("Falta la empresa.",400);
    const reportType=request.nextUrl.searchParams.get("reportType");
    if(reportType){
      const locationId=request.nextUrl.searchParams.get("locationId")||null;const unassigned=request.nextUrl.searchParams.get("unassigned")==="true";
      const useFinancialReport=reportType==="enterprise_consolidated"||Boolean(locationId)||unassigned;
      const {data,error}=useFinancialReport
        ?await supabase.rpc("list_financial_report",{p_company_id:companyId,p_report_type:reportType,p_starts_on:request.nextUrl.searchParams.get("startsOn"),p_ends_on:request.nextUrl.searchParams.get("endsOn"),p_location_id:locationId,p_unassigned:unassigned,p_page:Number(request.nextUrl.searchParams.get("page")||1),p_page_size:Number(request.nextUrl.searchParams.get("pageSize")||50)})
        :await supabase.rpc("list_accounting_report",{p_company_id:companyId,p_report_type:reportType,p_starts_on:request.nextUrl.searchParams.get("startsOn"),p_ends_on:request.nextUrl.searchParams.get("endsOn"),p_account_id:request.nextUrl.searchParams.get("accountId")||null,p_page:Number(request.nextUrl.searchParams.get("page")||1),p_page_size:Number(request.nextUrl.searchParams.get("pageSize")||50)});
      if(error)throw new Error(error.message);return NextResponse.json(useFinancialReport?{...(data as Record<string,unknown>),report_type:reportType}:data,{headers:noStore});
    }
    const [{data:batches,error},{data:accounts},{data:configs},{data:controls},{data:periods},{data:journals},{data:responsibles},{data:eventRuleSets},{data:eventRoleAccounts},{data:events},{data:manualAdjustments},{data:expenseCategories},{data:classificationWork}]=await Promise.all([
      supabase.from("accounting_import_batches").select("id,import_type,cutoff_date,currency_code,catalog_structure,detection_evidence,metadata_issues,original_name,status,row_count,error_count,warning_count,summary,promoted_entry_id,created_at,promoted_at").eq("company_id",companyId).order("created_at",{ascending:false}).limit(50),
      supabase.from("accounting_accounts").select("id,code,name,account_type,normal_balance,parent_id,level,accepts_posting,is_active,updated_at").eq("company_id",companyId).order("code").limit(1000),
      supabase.from("accounting_config_versions").select("id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_at,updated_at").eq("company_id",companyId).order("version",{ascending:false}).limit(20),
      supabase.from("accounting_control_accounts").select("config_version_id,control_key,account_id").eq("company_id",companyId),
      supabase.from("accounting_periods").select("id,period_code,starts_on,ends_on,status,closed_by,closed_at,reopened_by,reopened_at,reopen_reason").eq("company_id",companyId).order("starts_on",{ascending:false}).limit(60),
      supabase.from("accounting_journal_entries").select("id,period_id,entry_number,entry_date,description,source_type,status,immutable,content_sha256,posted_at,accounting_journal_lines(id,line_number,account_id,description,debit,credit,external_account_code)").eq("company_id",companyId).order("entry_date",{ascending:false}).order("entry_number",{ascending:false}).limit(100),
      supabase.rpc("list_accounting_responsibles",{p_company_id:companyId}),
      supabase.from("accounting_event_rule_sets").select("id,version,status,cost_method,reason,approved_at").eq("company_id",companyId).order("version",{ascending:false}).limit(20),
      supabase.from("accounting_event_role_accounts").select("rule_set_id,account_role,account_id").eq("company_id",companyId),
      supabase.from("accounting_events").select("id,event_type,source_entity_type,source_entity_id,accounting_date,status,journal_entry_id,original_event_id,accounting_journal_entries!accounting_events_journal_fkey(entry_number)").eq("company_id",companyId).order("accounting_date",{ascending:false}).order("created_at",{ascending:false}).limit(100),
      supabase.from("accounting_manual_adjustments").select("id,adjustment_type,entry_date,description,reason,status,requested_by,decided_by,journal_entry_id,reversal_entry_id").eq("company_id",companyId).order("requested_at",{ascending:false}).limit(100),
      supabase.from("accounting_expense_category_versions").select("id,category_id,version,code,display_name,account_id,status,valid_from,valid_to,change_reason,created_at").eq("company_id",companyId).is("valid_to",null).order("code").limit(1000),
      supabase.rpc("list_expense_classification_work",{p_company_id:companyId,p_page:1,p_page_size:100}),
    ]);if(error)throw error;
    const ids=(batches??[]).map((batch)=>batch.id);const queryIds=ids.length?ids:["00000000-0000-0000-0000-000000000000"];
    const [{data:exceptions},{data:comparisons}]=await Promise.all([
      supabase.from("accounting_import_exceptions").select("id,batch_id,exception_code,severity,message,status,accounting_import_rows(external_account_code)").in("batch_id",queryIds).eq("status","pending").order("created_at"),
      supabase.from("accounting_auxiliary_comparisons").select("batch_id,control_key,ledger_amount,auxiliary_amount,difference,detail").in("batch_id",queryIds).order("control_key"),
    ]);
    const [{data:locations},{data:closeRuns}]=await Promise.all([
      supabase.from("locations").select("id,name,external_code").eq("company_id",companyId).eq("is_active",true).order("name").limit(500),
      supabase.from("accounting_close_runs").select("id,period_id,status,snapshot,snapshot_sha256,prepared_by,prepared_at,approval_reason,approved_by,approved_at,closed_by,closed_at,reopen_reason,reopened_by,reopened_at").eq("company_id",companyId).order("prepared_at",{ascending:false}).limit(60),
    ]);
    return NextResponse.json({batches,exceptions,comparisons,accounts,configs,controls,periods,journals,responsibles:responsibles??[],eventRuleSets:eventRuleSets??[],eventRoleAccounts:eventRoleAccounts??[],events:events??[],manualAdjustments:manualAdjustments??[],expenseCategories:expenseCategories??[],classificationWork:classificationWork??{items:[],pagination:{page:1,page_size:100,total:0}},locations:locations??[],closeRuns:closeRuns??[]},{headers:noStore});
  }catch(error){return response(error instanceof Error?error.message:"No se pudo consultar Contabilidad.",422);}
}

export async function POST(request:NextRequest){
  try{
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));const {data:authData}=await supabase.auth.getUser();if(!authData.user)return response("Sesión no válida.",401);
    const body=await request.json() as Record<string,unknown>;const action=String(body.action??"");let data:unknown;let error:{message:string}|null=null;
    if(action==="save_account")({data,error}=await supabase.rpc("save_accounting_account",{p_company_id:body.companyId,p_account_id:body.accountId||null,p_code:body.code,p_name:body.name,p_account_type:body.accountType,p_normal_balance:body.normalBalance,p_parent_id:body.parentId||null,p_level:body.level,p_accepts_posting:body.acceptsPosting,p_is_active:body.isActive,p_reason:body.reason,p_expected_updated_at:body.expectedUpdatedAt||null,p_client_request_id:body.clientRequestId}));
    else if(action==="save_expense_category")({data,error}=await supabase.rpc("save_accounting_expense_category",{p_company_id:body.companyId,p_category_id:body.categoryId||null,p_code:body.code,p_display_name:body.displayName,p_account_id:body.accountId,p_status:body.status,p_valid_from:body.validFrom,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="bulk_assign_expense_category")({data,error}=await supabase.rpc("bulk_assign_expense_category",{p_company_id:body.companyId,p_category_id:body.categoryId,p_invoice_id:body.invoiceId||null,p_expense_category_text:body.expenseCategoryText??null,p_line_ids:body.lineIds??null,p_limit:body.limit??1000,p_client_request_id:body.clientRequestId}));
    else if(action==="bootstrap_manual_config")({data,error}=await supabase.rpc("bootstrap_manual_accounting_config",{p_company_id:body.companyId,p_base_currency:body.baseCurrency,p_cutoff_date:body.cutoffDate,p_catalog_structure:body.catalogStructure,p_tax_treatment:body.taxTreatment,p_responsibilities:body.responsibilities,p_control_accounts:body.controlAccounts,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="save_config_draft")({data,error}=await supabase.rpc("save_detected_accounting_config",{p_company_id:body.companyId,p_batch_id:body.batchId,p_base_currency:body.baseCurrency,p_cutoff_date:body.cutoffDate,p_catalog_structure:body.catalogStructure,p_tax_treatment:body.taxTreatment,p_responsibilities:body.responsibilities,p_correction_reason:body.correctionReason||null}));
    else if(action==="start_config_revision")({data,error}=await supabase.rpc("start_accounting_config_revision",{p_company_id:body.companyId,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="save_config_revision")({data,error}=await supabase.rpc("save_accounting_config_revision",{p_config_id:body.configId,p_base_currency:body.baseCurrency,p_cutoff_date:body.cutoffDate,p_catalog_structure:body.catalogStructure,p_tax_treatment:body.taxTreatment,p_responsibilities:body.responsibilities,p_control_accounts:body.controlAccounts,p_change_reason:body.reason,p_expected_updated_at:body.expectedUpdatedAt,p_client_request_id:body.clientRequestId,p_approve:Boolean(body.approve)}));
    else if(action==="complete_config"){
      ({data,error}=await supabase.rpc("complete_accounting_config",{p_config_id:body.configId,p_control_accounts:body.controlAccounts,p_approval_reason:body.approvalReason}));
      if(!error){const companyId=String((data as {company_id?:string})?.company_id??"");const {data:waiting}=await supabase.from("accounting_import_batches").select("id").eq("company_id",companyId).in("status",["awaiting_configuration","validation_failed"]);for(const batch of waiting??[]){await supabase.rpc("finalize_accounting_staging",{p_batch_id:batch.id,p_source_system:"external"});}}
    }
    else if(action==="create_period")({data,error}=await supabase.rpc("create_accounting_period",{p_company_id:body.companyId,p_code:body.periodCode,p_starts_on:body.startsOn,p_ends_on:body.endsOn}));
    else if(action==="prepare_close")({data,error}=await supabase.rpc("prepare_accounting_close",{p_company_id:body.companyId,p_period_id:body.periodId,p_client_request_id:body.clientRequestId}));
    else if(action==="approve_close")({data,error}=await supabase.rpc("approve_accounting_close",{p_close_run_id:body.closeRunId,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="confirm_close")({data,error}=await supabase.rpc("confirm_accounting_close",{p_close_run_id:body.closeRunId,p_client_request_id:body.clientRequestId}));
    else if(action==="reopen_close")({data,error}=await supabase.rpc("reopen_accounting_close",{p_close_run_id:body.closeRunId,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="map")({data,error}=await supabase.rpc("map_accounting_external_account",{p_batch_id:body.batchId,p_external_code:body.externalCode,p_account_id:body.accountId,p_source_system:"external",p_reason:body.reason}));
    else if(action==="promote")({data,error}=await supabase.rpc("promote_accounting_import",{p_batch_id:body.batchId,p_client_request_id:body.clientRequestId}));
    else if(action==="create_event_matrix")({data,error}=await supabase.rpc("create_accounting_event_rule_set",{p_company_id:body.companyId,p_cost_method:body.costMethod,p_recognition_policy:{sales:"confirmation",collections:"effective",inventory:"confirmation",purchases:"confirmation"},p_reason:body.reason}));
    else if(action==="complete_event_matrix")({data,error}=await supabase.rpc("complete_accounting_event_rule_set",{p_rule_set_id:body.ruleSetId,p_role_accounts:body.roleAccounts,p_reason:body.reason}));
    else if(action==="reprocess_events")({data,error}=await supabase.rpc("reprocess_accounting_events",{p_company_id:body.companyId,p_limit:100}));
    else if(action==="submit_adjustment")({data,error}=await supabase.rpc("submit_accounting_adjustment",{p_company_id:body.companyId,p_adjustment_type:body.adjustmentType,p_entry_date:body.entryDate,p_description:body.description,p_reason:body.reason,p_lines:body.lines,p_client_request_id:body.clientRequestId}));
    else if(action==="decide_adjustment")({data,error}=await supabase.rpc("decide_accounting_adjustment",{p_adjustment_id:body.adjustmentId,p_decision:body.decision,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else if(action==="reverse_adjustment")({data,error}=await supabase.rpc("reverse_accounting_adjustment",{p_adjustment_id:body.adjustmentId,p_entry_date:body.entryDate,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
    else return response("Operación contable inválida.",400);
    if(error)throw new Error(error.message);return NextResponse.json(data,{headers:noStore});
  }catch(error){return response(error instanceof Error?error.message:"No se pudo completar la operación contable.",422);}
}

const noStore={"cache-control":"no-store"};
function response(message:string,status:number){return NextResponse.json({message},{status,headers:noStore});}
