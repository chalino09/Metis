import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime="nodejs";
export const dynamic="force-dynamic";
const noStore={"cache-control":"no-store"};

type InviteBody={companyId?:string;email?:string;roleCode?:string;locationIds?:string[];reason?:string;clientRequestId?:string};

export async function POST(request:NextRequest){
  try{
    const requester=getRequestSupabaseClient(request.headers.get("authorization"));
    const {data:authData}=await requester.auth.getUser();
    if(!authData.user)return response("Sesión no válida.",401);
    const body=await request.json() as InviteBody;
    const companyId=String(body.companyId??"");const email=String(body.email??"").trim().toLowerCase();
    const roleCode=String(body.roleCode??"");const locationIds=Array.isArray(body.locationIds)?body.locationIds:[];const reason=String(body.reason??"").trim();const clientRequestId=String(body.clientRequestId??"");
    if(!companyId||!email||!roleCode||!reason||!clientRequestId)return response("Completa correo, rol, alcance y motivo.",400);
    const {data:existing,error:resolveError}=await requester.rpc("resolve_company_user_email",{p_company_id:companyId,p_email:email});
    if(resolveError)throw new Error(resolveError.message);
    if(existing){
      const {data,error}=await requester.rpc("save_company_user_access",{p_company_id:companyId,p_user_id:existing,p_role_code:roleCode,p_location_ids:locationIds,p_status:"active",p_reason:reason,p_expected_updated_at:null,p_client_request_id:clientRequestId});
      if(error)throw new Error(error.message);
      return NextResponse.json({...(data as Record<string,unknown>),pendingRegistration:false},{headers:noStore});
    }
    const {data,error}=await requester.rpc("save_company_user_invitation",{p_company_id:companyId,p_invitation_id:null,p_email:email,p_role_code:roleCode,p_location_ids:locationIds,p_status:"active",p_reason:reason,p_expected_updated_at:null,p_client_request_id:clientRequestId});
    if(error)throw new Error(error.message);
    return NextResponse.json({...(data as Record<string,unknown>),pendingRegistration:true},{headers:noStore});
  }catch(error){return response(error instanceof Error?error.message:"No se pudo invitar al usuario.",422);}
}

function response(message:string,status:number){return NextResponse.json({message},{status,headers:noStore});}
