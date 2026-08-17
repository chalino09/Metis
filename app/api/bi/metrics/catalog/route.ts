import { NextRequest,NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic="force-dynamic";

export async function GET(request:NextRequest){
  try{
    const companyId=request.nextUrl.searchParams.get("company_id");
    if(!companyId)return response({error:"company_id es obligatorio."},400);
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));
    const{data:auth}=await supabase.auth.getUser();if(!auth.user)return response({error:"Sesión no válida."},401);
    const{data,error}=await supabase.rpc("bi_get_metric_catalog",{p_company_id:companyId});
    if(error)return response({error:"Catálogo no disponible para este acceso."},403);
    return response(data,200);
  }catch{return response({error:"Sesión no válida."},401);}
}
function response(body:unknown,status:number){return NextResponse.json(body,{status,headers:{"cache-control":"private, no-store","vary":"authorization","x-content-type-options":"nosniff"}});}
