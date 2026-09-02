import { createClient } from "@supabase/supabase-js";
import { NextRequest,NextResponse } from "next/server";
import { encryptIntegrationSecret,integrationEncryptionKey } from "@/app/lib/integration-secrets";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime="nodejs";
export const dynamic="force-dynamic";

type Body={company_id?:string;location_id?:string;display_name?:string;code?:string;waba_id?:string;phone_number_id?:string;phone_number?:string};
type TokenResponse={access_token?:string;error?:{message?:string}};
type PhoneResponse={data?:Array<{id?:string;display_phone_number?:string;verified_name?:string}>;error?:{message?:string}};

export async function POST(request:NextRequest){
  try{
    const raw=await request.text();if(new TextEncoder().encode(raw).byteLength>20_000)return json({message:"La solicitud es demasiado grande."},413);
    const body=JSON.parse(raw) as Body;
    const companyId=String(body.company_id??"");const locationId=String(body.location_id??"");const code=String(body.code??"").trim();const wabaId=String(body.waba_id??"").trim();
    if(!companyId||!locationId||!code||!/^\d+$/.test(wabaId))return json({message:"Meta no devolvió una autorización completa."},400);
    const supabase=getRequestSupabaseClient(request.headers.get("authorization"));const {data:auth}=await supabase.auth.getUser();if(!auth.user)return json({message:"Tu sesión terminó. Inicia sesión nuevamente."},401);
    const permission=await supabase.rpc("authorize_integration_management",{p_company_id:companyId});if(permission.error)return json({message:permission.error.message},403);

    const appId=process.env.META_APP_ID?.trim()||process.env.NEXT_PUBLIC_META_APP_ID?.trim();
    const appSecret=process.env.META_APP_SECRET?.trim();
    const verifyToken=process.env.META_WEBHOOK_VERIFY_TOKEN?.trim();
    const graphVersion=process.env.META_GRAPH_API_VERSION?.trim()||"v23.0";
    if(!appId||!appSecret||!verifyToken)return json({message:"Completa la configuración de Meta en el servidor."},503);

    const tokenUrl=new URL(`https://graph.facebook.com/${graphVersion}/oauth/access_token`);
    tokenUrl.searchParams.set("client_id",appId);tokenUrl.searchParams.set("client_secret",appSecret);tokenUrl.searchParams.set("code",code);
    const tokenResponse=await fetch(tokenUrl,{method:"GET",cache:"no-store"});const tokenBody=await tokenResponse.json() as TokenResponse;
    if(!tokenResponse.ok||!tokenBody.access_token)return json({message:"Meta no permitió intercambiar la autorización. Intenta conectar nuevamente."},422);

    let phoneNumberId=String(body.phone_number_id??"").trim();let phoneNumber=String(body.phone_number??"").trim();let verifiedName="";
    if(!phoneNumberId){
      const phoneResponse=await fetch(`https://graph.facebook.com/${graphVersion}/${encodeURIComponent(wabaId)}/phone_numbers?fields=id,display_phone_number,verified_name`,{headers:{authorization:`Bearer ${tokenBody.access_token}`},cache:"no-store"});
      const phoneBody=await phoneResponse.json() as PhoneResponse;
      if(!phoneResponse.ok)return json({message:"Meta autorizó la cuenta, pero no permitió consultar sus números."},422);
      if((phoneBody.data?.length??0)!==1)return json({message:"Selecciona un único número durante el onboarding de Meta y vuelve a intentarlo."},409);
      phoneNumberId=String(phoneBody.data?.[0]?.id??"");phoneNumber=String(phoneBody.data?.[0]?.display_phone_number??"");verifiedName=String(phoneBody.data?.[0]?.verified_name??"");
    }
    if(!/^\d+$/.test(phoneNumberId))return json({message:"Meta no devolvió el identificador del número."},422);

    const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!serviceKey)return json({message:"El almacenamiento de integraciones no está configurado."},503);
    const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
    const secretCiphertext=encryptIntegrationSecret({access_token:tokenBody.access_token,app_secret:appSecret,verify_token:verifyToken},integrationEncryptionKey());
    const saved=await admin.rpc("complete_whatsapp_connection",{
      p_company_id:companyId,p_actor_id:auth.user.id,p_display_name:String(body.display_name??"").trim()||verifiedName||phoneNumber||"WhatsApp",
      p_location_id:locationId,p_waba_id:wabaId,p_phone_number_id:phoneNumberId,p_phone_number:phoneNumber,
      p_onboarding_mode:"coexistence",p_secret_ciphertext:secretCiphertext
    });
    if(saved.error)return json({message:"No fue posible asignar el número a la sucursal."},422);
    return json({message:"Número conectado y asignado a la sucursal.",connection_id:saved.data,phone_number_id:phoneNumberId,phone_number:phoneNumber},200);
  }catch(error){return json({message:error instanceof SyntaxError?"El contenido enviado no es válido.":"No fue posible completar Embedded Signup."},422);}
}

function json(body:unknown,status:number){return NextResponse.json(body,{status,headers:{"cache-control":"private, no-store","x-content-type-options":"nosniff"}});}
