import { NextRequest,NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic="force-dynamic";
const MAX_BYTES=16_384;

export async function POST(request:NextRequest){
  try{
    const raw=await request.text();if(new TextEncoder().encode(raw).byteLength>MAX_BYTES)return response({error:"Solicitud demasiado grande."},413);
    const body=JSON.parse(raw)as{company_id?:string;query?:unknown};if(!body.company_id||!body.query)return response({error:"company_id y query son obligatorios."},400);
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));
    const{data:auth}=await supabase.auth.getUser();if(!auth.user)return response({error:"Sesión no válida."},401);
    const{data,error}=await supabase.rpc("bi_query_metric",{p_company_id:body.company_id,p_request:body.query});
    if(error)return response({error:normalize(error.message)},400);return response(data,200);
  }catch(error){return response({error:error instanceof SyntaxError?"JSON inválido.":"Sesión no válida."},error instanceof SyntaxError?400:401);}
}
function normalize(message:string){if(/no autorizado|access|permission/i.test(message))return"Consulta no disponible para este acceso.";if(/invalid input syntax for type (uuid|date|integer)/i.test(message))return"La consulta contiene un identificador, fecha o número inválido.";return message;}
function response(body:unknown,status:number){return NextResponse.json(body,{status,headers:{"cache-control":"private, no-store","vary":"authorization","x-content-type-options":"nosniff"}});}
