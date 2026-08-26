import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";
import { encryptIntegrationSecret, integrationEncryptionKey } from "@/app/lib/integration-secrets";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
type Body={company_id?:string;provider_code?:"meta_whatsapp"|"xai";display_name?:string;configuration?:Record<string,string>;secrets?:Record<string,string>;managed_by?:"direct"|"nango";nango_connection_id?:string|null;preserve_existing_secret?:boolean};

export async function POST(request:NextRequest){
  try{
    const raw=await request.text(); if(new TextEncoder().encode(raw).byteLength>20_000)return response("La configuración es demasiado grande.",413);
    const body=JSON.parse(raw) as Body; const companyId=String(body.company_id??""); const provider=body.provider_code; const displayName=String(body.display_name??"").trim();
    if(!companyId||!provider||!displayName)return response("Completa la identificación de la conexión.",400);
    if(provider!=="meta_whatsapp"&&provider!=="xai")return response("Este conector usa un flujo de autorización diferente.",400);
    const managedBy=body.managed_by==="nango"?"nango":"direct";
    const nangoConnectionId=String(body.nango_connection_id??"").trim();
    const secrets=Object.fromEntries(Object.entries(body.secrets??{}).map(([key,value])=>[key,String(value).trim()]).filter(([,value])=>Boolean(value)));
    const preserveExisting=body.preserve_existing_secret===true;
    const supabase=getRequestSupabaseClient(request.headers.get("authorization")); const {data:auth}=await supabase.auth.getUser(); if(!auth.user)return response("Tu sesión terminó. Inicia sesión nuevamente.",401);
    const permission=await supabase.rpc("authorize_integration_management",{p_company_id:companyId}); if(permission.error)return response(permission.error.message,403);
    const url=process.env.NEXT_PUBLIC_SUPABASE_URL; const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY; if(!url||!serviceKey)throw new Error("INTEGRATION_STORAGE_NOT_CONFIGURED");
    const configuration=Object.fromEntries(Object.entries(body.configuration??{}).map(([key,value])=>[key,String(value).trim()]).filter(([,value])=>Boolean(value)));
    if(provider==="meta_whatsapp"&&!configuration.location_id)return response("Selecciona la sucursal que atenderá este número.",400);
    const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
    const suppliedSecretCount=Object.keys(secrets).length;
    const completeDirectSecret=provider==="meta_whatsapp"?Boolean(secrets.access_token&&secrets.app_secret&&secrets.verify_token):Boolean(secrets.api_key);
    if(managedBy==="direct"&&suppliedSecretCount>0&&!completeDirectSecret)return response("Para reemplazar las credenciales, captura todos los campos secretos.",400);
    if(managedBy==="nango"&&!nangoConnectionId&&!preserveExisting)return response("Captura el Connection ID de Nango.",400);
    let secretCiphertext="";let savedNangoConnectionId=managedBy==="nango"?nangoConnectionId:null;
    if(preserveExisting&&((managedBy==="direct"&&suppliedSecretCount===0)||(managedBy==="nango"&&!nangoConnectionId))){
      const existing=await admin.from("integration_connections").select("secret_ciphertext,nango_connection_id").eq("company_id",companyId).eq("provider_code",provider).maybeSingle();
      if(existing.error||!existing.data)return response("La conexión anterior no está disponible; captura nuevamente las credenciales.",409);
      secretCiphertext=String(existing.data.secret_ciphertext);savedNangoConnectionId=managedBy==="nango"?existing.data.nango_connection_id:null;
    }else{
      if(managedBy==="direct"&&!completeDirectSecret)return response(provider==="meta_whatsapp"?"Captura el token de acceso, App secret y token de verificación.":"Captura la clave de API de xAI.",400);
      const protectedReference=managedBy==="nango"?{managed_reference:nangoConnectionId}:secrets;
      secretCiphertext=encryptIntegrationSecret(protectedReference,integrationEncryptionKey());
    }
    const saved=await admin.rpc("complete_integration_connection",{p_company_id:companyId,p_actor_id:auth.user.id,p_provider_code:provider,p_display_name:displayName,p_auth_mode:managedBy==="nango"?"managed":"api_key",p_configuration:configuration,p_secret_ciphertext:secretCiphertext,p_nango_connection_id:savedNangoConnectionId});
    if(saved.error)throw new Error("INTEGRATION_STORAGE_FAILED");
    return NextResponse.json({message:"Conexión configurada. Falta validar el acceso con el proveedor."},{headers:{"cache-control":"private, no-store","x-content-type-options":"nosniff"}});
  }catch(error){const code=error instanceof Error?error.message:"";if(code==="INTEGRATION_ENCRYPTION_NOT_CONFIGURED"||code==="INTEGRATION_ENCRYPTION_KEY_INVALID")return response("Configura una clave de cifrado válida en el servidor.",503);if(code==="INTEGRATION_STORAGE_NOT_CONFIGURED"||code==="INTEGRATION_STORAGE_FAILED")return response("No fue posible guardar la conexión.",503);return response(error instanceof SyntaxError?"El contenido enviado no es válido.":"No fue posible configurar la conexión.",422);}
}
function response(message:string,status:number){return NextResponse.json({message},{status,headers:{"cache-control":"private, no-store","x-content-type-options":"nosniff"}});}
