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
    const view=request.nextUrl.searchParams.get("view")??"summary";
    const pageSize=100;
    const pageFor=(name:string)=>Math.max(1,Number(request.nextUrl.searchParams.get(name)??"1")||1);
    const paged=(page:number)=>({from:(page-1)*pageSize,to:page*pageSize-1});
    const stats=async()=>{
      const [{count:accountCount,error:accountError},{count:periodCount,error:periodError},{count:openPeriodCount,error:openPeriodError},{count:postedJournalCount,error:journalError}]=await Promise.all([
        supabase.from("accounting_accounts").select("id",{count:"exact",head:true}).eq("company_id",companyId),
        supabase.from("accounting_periods").select("id",{count:"exact",head:true}).eq("company_id",companyId),
        supabase.from("accounting_periods").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","open"),
        supabase.from("accounting_journal_entries").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","posted"),
      ]);const error=accountError??periodError??openPeriodError??journalError;if(error)throw error;
      return {accountCount:accountCount??0,periodCount:periodCount??0,openPeriodCount:openPeriodCount??0,postedJournalCount:postedJournalCount??0};
    };
    const pendingWork=async()=>{
      const [{count:pendingEvents,error:eventError},{count:submittedAdjustments,error:adjustmentError},{count:preparedClosures,error:preparedError},{count:approvedClosures,error:approvedError},{count:bankExceptions,error:bankError}]=await Promise.all([
        supabase.from("accounting_events").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","pending"),
        supabase.from("accounting_manual_adjustments").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","submitted"),
        supabase.from("accounting_close_runs").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","prepared"),
        supabase.from("accounting_close_runs").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","approved"),
        supabase.from("bank_reconciliation_exceptions").select("id",{count:"exact",head:true}).eq("company_id",companyId).eq("status","pending"),
      ]);const error=eventError??adjustmentError??preparedError??approvedError??bankError;if(error)throw error;
      return [
        {key:"events",count:pendingEvents??0,label:"Eventos por reprocesar",detail:"Operaciones sin póliza contable",href:"/satrapy/contabilidad/eventos"},
        {key:"adjustments",count:submittedAdjustments??0,label:"Ajustes por decidir",detail:"Solicitudes que requieren una aprobación independiente",href:"/satrapy/contabilidad/polizas"},
        {key:"close_approval",count:preparedClosures??0,label:"Cierres por aprobar",detail:"Cierres preparados que esperan revisión",href:"/satrapy/contabilidad/periodos"},
        {key:"close_confirmation",count:approvedClosures??0,label:"Cierres por confirmar",detail:"Cierres aprobados listos para confirmar si no tienen diferencias",href:"/satrapy/contabilidad/periodos"},
        {key:"banking",count:bankExceptions??0,label:"Excepciones bancarias",detail:"Movimientos o estados bancarios sin resolver",href:"/satrapy/contabilidad/bancos"},
      ];
    };
    const configQuery=()=>supabase.from("accounting_config_versions").select("id,version,status,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason,approved_at,updated_at").eq("company_id",companyId).order("version",{ascending:false}).limit(20);
    const accountsQuery=()=>supabase.from("accounting_accounts").select("id,code,name,account_type,normal_balance,parent_id,level,accepts_posting,is_active,updated_at").eq("company_id",companyId).order("code").limit(1000);
    const batchesQuery=()=>supabase.from("accounting_import_batches").select("id,import_type,cutoff_date,currency_code,catalog_structure,detection_evidence,metadata_issues,original_name,status,row_count,error_count,warning_count,summary,promoted_entry_id,created_at,promoted_at").eq("company_id",companyId).order("created_at",{ascending:false}).limit(50);
    const result=(data:Record<string,unknown>)=>NextResponse.json(data,{headers:noStore});

    if(view==="summary"){
      const [{data:configs,error:configError},{data:batches,error:batchError},summary,work]=await Promise.all([configQuery(),batchesQuery(),stats(),pendingWork()]);if(configError??batchError)throw configError??batchError;
      return result({configs,batches,stats:summary,pendingWork:work});
    }
    if(view==="accounts"){
      const [{data:accounts,error:accountError},{data:batches,error:batchError},{data:expenseCategories,error:categoryError},{data:classificationWork,error:classificationError},summary]=await Promise.all([
        accountsQuery(),batchesQuery(),supabase.from("accounting_expense_category_versions").select("id,category_id,version,code,display_name,account_id,status,valid_from,valid_to,change_reason,created_at").eq("company_id",companyId).is("valid_to",null).order("code").limit(1000),supabase.rpc("list_expense_classification_work",{p_company_id:companyId,p_page:1,p_page_size:100}),stats(),
      ]);const error=accountError??batchError??categoryError??classificationError;if(error)throw error;
      return result({accounts,batches,expenseCategories,classificationWork:classificationWork??{items:[],pagination:{page:1,page_size:100,total:0}},stats:summary});
    }
    if(view==="periods"){
      const [{data:configs,error:configError},{data:periods,error:periodError},{data:responsibles,error:responsibleError},{data:closeRuns,error:closeError},summary]=await Promise.all([
        configQuery(),supabase.from("accounting_periods").select("id,period_code,starts_on,ends_on,status").eq("company_id",companyId).order("starts_on",{ascending:false}).limit(60),supabase.rpc("list_accounting_responsibles",{p_company_id:companyId}),supabase.from("accounting_close_runs").select("id,period_id,status,snapshot,snapshot_sha256,prepared_by,prepared_at,approval_reason,approved_by,approved_at,closed_by,closed_at,reopen_reason,reopened_by,reopened_at").eq("company_id",companyId).neq("status","cancelled").order("prepared_at",{ascending:false}).limit(60),stats(),
      ]);const error=configError??periodError??responsibleError??closeError;if(error)throw error;
      return result({configs,periods,responsibles:responsibles??[],closeRuns:closeRuns??[],stats:summary});
    }
    if(view==="reports"){
      const [{data:configs,error:configError},{data:accounts,error:accountError},{data:periods,error:periodError},{data:locations,error:locationError},summary]=await Promise.all([
        configQuery(),accountsQuery(),supabase.from("accounting_periods").select("id,period_code,starts_on,ends_on,status").eq("company_id",companyId).order("starts_on",{ascending:false}).limit(60),supabase.from("locations").select("id,name,external_code").eq("company_id",companyId).eq("is_active",true).order("name").limit(500),stats(),
      ]);const error=configError??accountError??periodError??locationError;if(error)throw error;
      return result({configs,accounts,periods,locations,stats:summary});
    }
    if(view==="journals"){
      const journalsPage=pageFor("journalsPage"),adjustmentsPage=pageFor("adjustmentsPage"),journalsRange=paged(journalsPage),adjustmentsRange=paged(adjustmentsPage);
      const [{data:configs,error:configError},{data:accounts,error:accountError},{data:journals,count:journalsTotal,error:journalsError},{data:manualAdjustments,count:adjustmentsTotal,error:adjustmentsError},summary]=await Promise.all([
        configQuery(),accountsQuery(),supabase.from("accounting_journal_entries").select("id,period_id,entry_number,entry_date,description,source_type,status,immutable,content_sha256,posted_at,accounting_journal_lines(id,line_number,account_id,description,debit,credit,external_account_code)",{count:"exact"}).eq("company_id",companyId).order("entry_date",{ascending:false}).order("entry_number",{ascending:false}).range(journalsRange.from,journalsRange.to),supabase.from("accounting_manual_adjustments").select("id,adjustment_type,entry_date,description,reason,status,requested_by,decided_by,journal_entry_id,reversal_entry_id",{count:"exact"}).eq("company_id",companyId).order("requested_at",{ascending:false}).range(adjustmentsRange.from,adjustmentsRange.to),stats(),
      ]);const error=configError??accountError??journalsError??adjustmentsError;if(error)throw error;
      return result({configs,accounts,journals:journals??[],manualAdjustments:manualAdjustments??[],pagination:{journals:{page:journalsPage,pageSize,total:journalsTotal??0},adjustments:{page:adjustmentsPage,pageSize,total:adjustmentsTotal??0}},stats:summary});
    }
    if(view==="events"){
      const eventsPage=pageFor("eventsPage"),eventsRange=paged(eventsPage);
      const [{data:configs,error:configError},{data:accounts,error:accountError},{data:eventRuleSets,error:ruleSetError},{data:eventRoleAccounts,error:roleAccountError},{data:events,count:eventsTotal,error:eventsError},summary]=await Promise.all([
        configQuery(),accountsQuery(),supabase.from("accounting_event_rule_sets").select("id,version,status,cost_method,reason,approved_at").eq("company_id",companyId).order("version",{ascending:false}).limit(20),supabase.from("accounting_event_role_accounts").select("rule_set_id,account_role,account_id").eq("company_id",companyId),supabase.from("accounting_events").select("id,event_type,source_entity_type,source_entity_id,accounting_date,status,journal_entry_id,original_event_id,accounting_journal_entries!accounting_events_journal_fkey(entry_number)",{count:"exact"}).eq("company_id",companyId).order("accounting_date",{ascending:false}).order("created_at",{ascending:false}).range(eventsRange.from,eventsRange.to),stats(),
      ]);const error=configError??accountError??ruleSetError??roleAccountError??eventsError;if(error)throw error;
      return result({configs,accounts,eventRuleSets:eventRuleSets??[],eventRoleAccounts:eventRoleAccounts??[],events:events??[],pagination:{events:{page:eventsPage,pageSize,total:eventsTotal??0}},stats:summary});
    }
    if(view==="opening"){
      const [{data:configs,error:configError},{data:accounts,error:accountError},{data:batches,error:batchError},{data:periods,error:periodError},summary]=await Promise.all([
        configQuery(),accountsQuery(),batchesQuery(),supabase.from("accounting_periods").select("id,period_code,starts_on,ends_on,status").eq("company_id",companyId).order("starts_on",{ascending:false}).limit(60),stats(),
      ]);const error=configError??accountError??batchError??periodError;if(error)throw error;
      const ids=(batches??[]).map((batch)=>batch.id);const queryIds=ids.length?ids:["00000000-0000-0000-0000-000000000000"];
      const [{data:exceptions,error:exceptionsError},{data:comparisons,error:comparisonsError}]=await Promise.all([
        supabase.from("accounting_import_exceptions").select("id,batch_id,exception_code,severity,message,status,accounting_import_rows(external_account_code)").in("batch_id",queryIds).eq("status","pending").order("created_at"),supabase.from("accounting_auxiliary_comparisons").select("batch_id,control_key,ledger_amount,auxiliary_amount,difference,detail").in("batch_id",queryIds).order("control_key"),
      ]);if(exceptionsError??comparisonsError)throw exceptionsError??comparisonsError;
      return result({configs,accounts,batches,periods,exceptions,comparisons,stats:summary});
    }
    if(view==="settings"){
      const [{data:configs,error:configError},{data:accounts,error:accountError},{data:batches,error:batchError},{data:controls,error:controlsError},{data:responsibles,error:responsibleError},summary]=await Promise.all([
        configQuery(),accountsQuery(),batchesQuery(),supabase.from("accounting_control_accounts").select("config_version_id,control_key,account_id").eq("company_id",companyId),supabase.rpc("list_accounting_responsibles",{p_company_id:companyId}),stats(),
      ]);const error=configError??accountError??batchError??controlsError??responsibleError;if(error)throw error;
      return result({configs,accounts,batches,controls,responsibles:responsibles??[],stats:summary});
    }
    return response("Vista contable inválida.",400);
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
    else if(action==="cancel_close_preparation")({data,error}=await supabase.rpc("cancel_accounting_close_preparation",{p_close_run_id:body.closeRunId,p_reason:body.reason,p_client_request_id:body.clientRequestId}));
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
