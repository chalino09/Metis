import { lstat, readFile, readdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { NextRequest, NextResponse } from "next/server";
import { parseAlphaPurchasingMigration } from "@/app/lib/alpha-purchasing-migration";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime="nodejs";
export const dynamic="force-dynamic";

export async function POST(request:NextRequest) {
  if(process.env.NODE_ENV!=="development"||!process.env.ALPHA_ERP_IMPORT_DIR) return NextResponse.json({message:"La evidencia de origen vinculada no está disponible en este entorno."},{status:404});
  const supabase=getRequestSupabaseClient(request.headers.get("authorization"));
  const {data:authData,error:authError}=await supabase.auth.getUser();
  if(authError||!authData.user) return NextResponse.json({message:"Sesión no válida."},{status:401});
  try {
    const body=await request.json() as {companyId?:string};
    if(!body.companyId) return NextResponse.json({message:"Empresa requerida."},{status:400});
    const directory=process.env.ALPHA_ERP_IMPORT_DIR;
    const names=(await readdir(directory)).filter(name=>/^cata_prv_.+\.xlsx?$/i.test(name)).sort();
    if(names.length!==1) return NextResponse.json({message:"Se requiere exactamente un cata_prv en la carpeta vinculada."},{status:422});
    const path=resolve(directory,names[0]); const info=await lstat(path);
    if(!info.isFile()||info.isSymbolicLink()||basename(path)!==names[0]) return NextResponse.json({message:"El archivo cata_prv no es válido."},{status:422});
    const payload=await parseAlphaPurchasingMigration([new File([await readFile(path)],names[0])]);
    const {data,error}=await supabase.rpc("repair_alpha_supplier_details",{p_company_id:body.companyId,p_cutoff_date:payload.cutoffDate,p_suppliers:payload.suppliers});
    if(error) return NextResponse.json({message:error.message},{status:422});
    return NextResponse.json(data,{headers:{"cache-control":"no-store"}});
  } catch(error) {
    return NextResponse.json({message:error instanceof Error?error.message:"No se pudieron reparar los datos de proveedores."},{status:422});
  }
}
