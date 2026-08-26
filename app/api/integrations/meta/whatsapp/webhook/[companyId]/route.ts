import { createHmac,timingSafeEqual } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { NextRequest,NextResponse } from "next/server";
import { decryptIntegrationSecret,integrationEncryptionKey } from "@/app/lib/integration-secrets";
import { processWhatsappText } from "@/app/lib/whatsapp-intake";

export const runtime="nodejs";export const dynamic="force-dynamic";
type Context={params:Promise<{companyId:string}>};
type Connection={id:string;company_id:string;configuration:Record<string,unknown>;secret_ciphertext:string|null;status:string};
type MetaPayload={entry?:Array<{changes?:Array<{field?:string;value?:{metadata?:{phone_number_id?:string};messages?:Array<{id?:string;from?:string;type?:string;text?:{body?:string}}>}}>}>};

function adminClient(){const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!key)throw new Error("WEBHOOK_STORAGE_NOT_CONFIGURED");return createClient(url,key,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});}
async function connectionFor(companyId:string){const admin=adminClient();const result=await admin.from("integration_connections").select("id,company_id,configuration,secret_ciphertext,status").eq("company_id",companyId).eq("provider_code","meta_whatsapp").maybeSingle();if(result.error||!result.data)throw new Error("WHATSAPP_CONNECTION_NOT_FOUND");return{admin,connection:result.data as Connection};}
function secretsFor(connection:Connection){if(!connection.secret_ciphertext)throw new Error("WHATSAPP_CREDENTIALS_NOT_CONFIGURED");return decryptIntegrationSecret(connection.secret_ciphertext,integrationEncryptionKey());}

export async function GET(request:NextRequest,context:Context){
  try{const {companyId}=await context.params;const {connection}=await connectionFor(companyId);const secrets=secretsFor(connection);const mode=request.nextUrl.searchParams.get("hub.mode");const token=request.nextUrl.searchParams.get("hub.verify_token");const challenge=request.nextUrl.searchParams.get("hub.challenge");if(mode!=="subscribe"||!challenge||!token||token!==secrets.verify_token)return new NextResponse("Forbidden",{status:403});return new NextResponse(challenge,{status:200,headers:{"content-type":"text/plain; charset=utf-8","cache-control":"no-store"}});}catch{return new NextResponse("Not found",{status:404});}
}

export async function POST(request:NextRequest,context:Context){
  try{
    const {companyId}=await context.params;const raw=await request.text();if(new TextEncoder().encode(raw).byteLength>1_000_000)return new NextResponse("Payload too large",{status:413});
    const {admin,connection}=await connectionFor(companyId);const secrets=secretsFor(connection);const signature=request.headers.get("x-hub-signature-256")??"";const expected=`sha256=${createHmac("sha256",secrets.app_secret).update(raw).digest("hex")}`;
    const receivedBuffer=Buffer.from(signature);const expectedBuffer=Buffer.from(expected);if(receivedBuffer.length!==expectedBuffer.length||!timingSafeEqual(receivedBuffer,expectedBuffer))return new NextResponse("Invalid signature",{status:401});
    const payload=JSON.parse(raw) as MetaPayload;const locationId=String(connection.configuration.location_id??"");if(!locationId)throw new Error("WHATSAPP_LOCATION_NOT_CONFIGURED");
    const jobs:Array<Promise<unknown>>=[];
    for(const entry of payload.entry??[])for(const change of entry.changes??[]){if(change.field!=="messages")continue;const configuredPhone=String(connection.configuration.phone_number_id??"");const incomingPhone=String(change.value?.metadata?.phone_number_id??"");if(configuredPhone&&incomingPhone&&configuredPhone!==incomingPhone)continue;for(const message of change.value?.messages??[]){if(message.type!=="text"||!message.id||!message.from||!message.text?.body)continue;jobs.push(processWhatsappText(admin,{companyId,connectionId:connection.id,locationId,messageId:message.id,sender:message.from,message:message.text.body,rawPayload:raw}));}}
    const results=await Promise.allSettled(jobs);const failed=results.filter(result=>result.status==="rejected").length;
    if(failed>0)return NextResponse.json({received:true,processed:jobs.length-failed,retry:true},{status:503,headers:{"cache-control":"no-store","retry-after":"30","x-content-type-options":"nosniff"}});
    return NextResponse.json({received:true,processed:jobs.length},{status:200,headers:{"cache-control":"no-store","x-content-type-options":"nosniff"}});
  }catch(error){const code=error instanceof Error?error.message:"";if(code==="WHATSAPP_CONNECTION_NOT_FOUND"||code==="WHATSAPP_CREDENTIALS_NOT_CONFIGURED")return new NextResponse("Not configured",{status:404});return NextResponse.json({received:false},{status:500,headers:{"cache-control":"no-store"}});}
}
