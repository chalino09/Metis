import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { NextRequest,NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import { processWhatsappText } from "@/app/lib/whatsapp-intake";

export const runtime="nodejs";export const dynamic="force-dynamic";
type Body={company_id?:string;location_id?:string;customer_id?:string|null;sender?:string;message?:string;message_id?:string};

export async function POST(request:NextRequest){
  try{
    const raw=await request.text();if(new TextEncoder().encode(raw).byteLength>16_000)return json({error:"La simulación es demasiado grande."},413);
    const body=JSON.parse(raw) as Body;const companyId=String(body.company_id??"");const locationId=String(body.location_id??"");const sender=String(body.sender??"").trim();const message=String(body.message??"").trim();
    if(!companyId||!locationId||message.length<3||message.length>4000)return json({error:"Selecciona una sucursal y captura un mensaje válido."},400);
    if(!/^\+?[0-9]{10,15}$/.test(sender.replace(/[\s()-]/g,"")))return json({error:"Captura el teléfono remitente con lada."},400);
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));const {data:auth}=await supabase.auth.getUser();if(!auth.user)return json({error:"Tu sesión terminó."},401);
    const enabled=await supabase.rpc("enable_whatsapp_simulator",{p_company_id:companyId,p_location_id:locationId});if(enabled.error||!enabled.data)return json({error:enabled.error?.message??"No se habilitó el simulador."},403);
    const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!key)return json({error:"El almacenamiento de integraciones no está configurado."},503);
    const admin=createClient(url,key,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
    const messageId=String(body.message_id??"").trim()||`sim_${randomUUID().replaceAll("-","")}`;
    const payload=JSON.stringify({object:"whatsapp_business_account",simulation:true,entry:[{changes:[{field:"messages",value:{messages:[{id:messageId,from:sender,type:"text",text:{body:message}}]}}]}]});
    const result=await processWhatsappText(admin,{companyId,connectionId:String(enabled.data),locationId,customerId:body.customer_id??null,messageId,sender,message,rawPayload:payload});
    return json(result,200);
  }catch(error){return json({error:error instanceof SyntaxError?"El contenido enviado no es válido.":error instanceof Error?error.message:"No se pudo ejecutar la simulación."},422);}
}
function json(body:unknown,status:number){return NextResponse.json(body,{status,headers:{"cache-control":"private, no-store","x-content-type-options":"nosniff"}});}
