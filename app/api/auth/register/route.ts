import { createClient } from "@supabase/supabase-js";
import { NextRequest, NextResponse } from "next/server";

export const runtime="nodejs";
export const dynamic="force-dynamic";
const noStore={"cache-control":"no-store"};

type RegisterBody={email?:string;fullName?:string;password?:string};

export async function POST(request:NextRequest){
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const anonKey=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!url||!anonKey||!serviceKey)return response("La activación de cuentas aún no está habilitada en el servidor.",503);
  let createdUserId:string|null=null;
  try{
    const body=await request.json() as RegisterBody;const email=String(body.email??"").trim().toLowerCase();const fullName=String(body.fullName??"").trim();const password=String(body.password??"");
    if(!email||!fullName||password.length<8)return response("Captura nombre, correo autorizado y una contraseña de al menos 8 caracteres.",400);
    const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});
    const {data:prepared,error:prepareError}=await admin.rpc("prepare_pending_user_registration",{p_email:email});
    if(prepareError)throw new Error(prepareError.message);
    const pending=prepared as {allowed?:boolean;already_registered?:boolean;user_id?:string|null};
    if(!pending.allowed)return response(pending.already_registered?"Este correo ya tiene una cuenta. Inicia sesión.":"Este correo no tiene un acceso autorizado por un administrador.",403);
    let userId=pending.user_id??null;
    if(!userId){
      const {data,error}=await admin.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{full_name:fullName,registration_pending:true}});
      if(error||!data.user)throw new Error(error?.message??"No se pudo crear la cuenta.");
      userId=data.user.id;createdUserId=userId;
    }else{
      const {error}=await admin.auth.admin.updateUserById(userId,{password,user_metadata:{full_name:fullName,registration_pending:true}});
      if(error)throw new Error(error.message);
    }
    const {error:completeError}=await admin.rpc("complete_pending_user_registration",{p_user_id:userId,p_email:email,p_full_name:fullName});
    if(completeError)throw new Error(completeError.message);
    const {error:finalizeError}=await admin.auth.admin.updateUserById(userId,{user_metadata:{full_name:fullName,registration_pending:false}});
    if(finalizeError)throw new Error(finalizeError.message);
    return NextResponse.json({activated:true},{headers:noStore});
  }catch(error){
    if(createdUserId){
      const url=process.env.NEXT_PUBLIC_SUPABASE_URL;const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
      if(url&&serviceKey){const admin=createClient(url,serviceKey,{auth:{autoRefreshToken:false,persistSession:false,detectSessionInUrl:false}});await admin.auth.admin.deleteUser(createdUserId).catch(()=>undefined);}
    }
    return response(error instanceof Error?error.message:"No se pudo activar la cuenta.",422);
  }
}

function response(message:string,status:number){return NextResponse.json({message},{status,headers:noStore});}
