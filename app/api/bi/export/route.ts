import { NextRequest,NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import { createBiCsv,createBiPdf,createBiXlsx,type BiExportMetric,type BiExportReport,type BiExportSection } from "@/app/lib/bi-report-export";

export const runtime="nodejs";export const dynamic="force-dynamic";
const PAGE_SIZE=100,MAX_ROWS=50_000;
type Definition={metric_codes:string[];dimension:string;visualization:string;date_from:string;date_to:string;location_id?:string;product_id?:string;customer_id?:string;supplier_id?:string;compare_previous?:boolean};
type Prepared={job_id:string;configs:Array<{title:string;target_id:string;widget_type:"kpi"|"chart"|"table";definition:Definition}>};

export async function POST(request:NextRequest){
  let supabase:ReturnType<typeof getRequestSupabaseClient>|null=null,jobId:string|null=null;
  try{
    supabase=getRequestSupabaseClient(request.headers.get("authorization"));const{data:authData}=await supabase.auth.getUser();
    if(!authData.user)return message("Sesión no válida.",401);
    const body=await request.json()as{companyId?:string;targetType?:string;targetId?:string;format?:string;filters?:Record<string,unknown>};
    if(!body.companyId||!body.targetId||!["view","widget","dashboard"].includes(body.targetType??"")||!["csv","xlsx","pdf"].includes(body.format??""))return message("Solicitud de exportación inválida.",400);
    const format=body.format as"csv"|"xlsx"|"pdf";
    const[{data:preparedData,error:prepareError},{data:catalogData,error:catalogError},{data:company}]=await Promise.all([
      supabase.rpc("bi_prepare_export",{p_company_id:body.companyId,p_target_type:body.targetType,p_target_id:body.targetId,p_format:format,p_filters:body.filters??{}}),
      supabase.rpc("bi_get_metric_catalog",{p_company_id:body.companyId}),
      supabase.from("companies").select("display_name").eq("id",body.companyId).maybeSingle(),
    ]);
    if(prepareError)throw new Error(prepareError.message);if(catalogError)throw new Error(catalogError.message);
    const prepared=preparedData as Prepared;jobId=prepared.job_id;
    const catalog=catalogData as{currency_code:string|null;metrics:BiExportMetric[]};const sections:BiExportSection[]=[];let totalRows=0;
    for(const config of prepared.configs){
      const args=rpcArgs(body.companyId,config.definition,1);const first=await supabase.rpc("bi_explorer_query",args);if(first.error)throw new Error(first.error.message);
      const initial=first.data as{items:Array<Record<string,unknown>>;chart:Array<Record<string,unknown>>;pagination:{total:number;page_size:number};currency_code:string|null};
      if(totalRows+initial.pagination.total>MAX_ROWS)throw new Error(`La exportación excede ${MAX_ROWS.toLocaleString("es-MX")} agregados. Reduce el periodo o exporta un widget.`);
      const rows=[...initial.items];for(let page=2;page<=Math.ceil(initial.pagination.total/PAGE_SIZE);page++){const next=await supabase.rpc("bi_explorer_query",rpcArgs(body.companyId,config.definition,page));if(next.error)throw new Error(next.error.message);rows.push(...((next.data as{items:Array<Record<string,unknown>>}).items??[]));}
      totalRows+=rows.length;sections.push({title:config.title,widgetType:config.widget_type,definition:config.definition,metrics:catalog.metrics.filter(metric=>config.definition.metric_codes.includes(metric.code)),currencyCode:initial.currency_code,rows,chart:initial.chart,total:initial.pagination.total});
    }
    const report:BiExportReport={companyName:company?.display_name??"Empresa",targetLabel:prepared.configs.length===1?prepared.configs[0].title:"Tablero BI",generatedAt:new Date().toISOString(),sections};
    const bytes=format==="csv"?createBiCsv(report):format==="xlsx"?await createBiXlsx(report):await createBiPdf(report);
    await supabase.rpc("bi_finish_export",{p_job_id:jobId,p_status:"completed",p_row_count:totalRows,p_byte_count:bytes.byteLength,p_metadata:{sections:sections.length}});
    const filename=`satrapy_bi_${new Date().toISOString().slice(0,10)}.${format}`;return new NextResponse(bytes as BodyInit,{headers:{"content-type":contentType(format),"content-disposition":`attachment; filename="${filename}"`,"cache-control":"no-store, max-age=0","x-content-type-options":"nosniff"}});
  }catch(error){
    if(supabase&&jobId)try{await supabase.rpc("bi_finish_export",{p_job_id:jobId,p_status:"failed",p_row_count:0,p_byte_count:0,p_metadata:{message:error instanceof Error?error.message:"Error"}});}catch{}
    return message(error instanceof Error?error.message:"No se pudo generar la exportación.",400);
  }
}
function rpcArgs(companyId:string,d:Definition,page:number){return{p_company_id:companyId,p_metric_codes:d.metric_codes,p_dimension:d.dimension,p_visualization:d.visualization,p_date_from:d.date_from,p_date_to:d.date_to,p_location_id:d.location_id||null,p_product_id:d.product_id||null,p_customer_id:d.customer_id||null,p_supplier_id:d.supplier_id||null,p_compare_previous:d.compare_previous??true,p_page:page,p_page_size:PAGE_SIZE};}
function contentType(format:string){return format==="csv"?"text/csv; charset=utf-8":format==="xlsx"?"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":"application/pdf";}
function message(value:string,status:number){return NextResponse.json({message:value},{status,headers:{"cache-control":"no-store, max-age=0"}});}
