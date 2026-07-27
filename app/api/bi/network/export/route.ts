import {NextRequest,NextResponse} from "next/server";
import ExcelJS from "exceljs";
import {PDFDocument,StandardFonts,rgb} from "pdf-lib";
import sharp from "sharp";
import {getRequestSupabaseClient} from "@/app/lib/supabase-server";

export const runtime="nodejs";export const dynamic="force-dynamic";
type Filters={dateFrom:string;dateTo:string;locationId:string;categoryId:string;supplierId:string;productId:string;relationType:string;
  operationalState:string;concentration:string;sizeMetric:string;colorMetric:string;edgeMetric:string;perspective:string};
type NodeRow={id:string;type:string;entity_id:string;label:string;secondary?:string;size_value:number;concentration:number;availability?:string;metrics:Record<string,number>};
type EdgeRow={id:string;source:string;target:string;type:string;amount:number;quantity:number;frequency:number;weight:number;metric_source:string;
  operational_state?:string;concentration_share:number;period:{from:string|null;to:string|null}};
type Result={nodes:NodeRow[];edges:EdgeRow[];currency_code:string|null;updated_at:string;truncated:boolean;methodology:Record<string,string>;period:{from:string;to:string}};

export async function POST(request:NextRequest){
  const supabase=getRequestSupabaseClient(request.headers.get("authorization"));let jobId:string|null=null;
  try{
    const{data:auth}=await supabase.auth.getUser();if(!auth.user)return message("Sesión no válida.",401);
    const body=await request.json()as{companyId?:string;format?:string;filters?:Filters};
    if(!body.companyId||!body.filters||!["csv","xlsx","pdf","png"].includes(body.format??""))return message("Solicitud de exportación inválida.",400);
    const format=body.format as"csv"|"xlsx"|"pdf"|"png",definition=toDefinition(body.filters);
    const started=await supabase.rpc("bi_start_network_export",{p_company_id:body.companyId,p_format:format,p_definition:definition});
    if(started.error)throw new Error(started.error.message);jobId=started.data as string;
    const response=await supabase.rpc("bi_dependency_network_query",{...rpcArgs(body.companyId,body.filters),p_node_limit:200,p_edge_limit:400});
    if(response.error)throw new Error(response.error.message);const result=response.data as Result;
    if(result.truncated)throw new Error("La exportación alcanzó 200 nodos o 400 relaciones. Reduce el periodo o aplica más filtros.");
    const{data:company}=await supabase.from("companies").select("display_name").eq("id",body.companyId).maybeSingle();
    const title=`Red de dependencias · ${company?.display_name??"Empresa"}`,generated=new Date().toISOString();
    const bytes=format==="csv"?csv(result,title,generated):format==="xlsx"?await xlsx(result,title,generated):format==="pdf"?await pdf(result,title,generated):await png(result,title,generated);
    await supabase.rpc("bi_finish_export",{p_job_id:jobId,p_status:"completed",p_row_count:result.nodes.length+result.edges.length,p_byte_count:bytes.byteLength,
      p_metadata:{nodes:result.nodes.length,edges:result.edges.length,methodology:true}});
    return new NextResponse(bytes as BodyInit,{headers:{"content-type":contentType(format),"content-disposition":`attachment; filename="satrapy_red_dependencias.${format}"`,"cache-control":"no-store, max-age=0"}});
  }catch(error){
    if(jobId)await supabase.rpc("bi_finish_export",{p_job_id:jobId,p_status:"failed",p_row_count:0,p_byte_count:0,p_metadata:{message:error instanceof Error?error.message:"Error"}});
    return message(error instanceof Error?error.message:"No se pudo exportar la red.",400);
  }
}
function toDefinition(f:Filters){return{kind:"network",date_from:f.dateFrom,date_to:f.dateTo,location_id:f.locationId||null,category_id:f.categoryId||null,
  supplier_id:f.supplierId||null,product_id:f.productId||null,relation_types:f.relationType?[f.relationType]:[],operational_state:f.operationalState||null,
  concentration_level:f.concentration||null,size_metric:f.sizeMetric,color_metric:f.colorMetric,edge_metric:f.edgeMetric,perspective:f.perspective};}
function rpcArgs(companyId:string,f:Filters){return{p_company_id:companyId,p_date_from:f.dateFrom,p_date_to:f.dateTo,p_location_id:f.locationId||null,
  p_category_id:f.categoryId||null,p_supplier_id:f.supplierId||null,p_product_id:f.productId||null,p_relation_types:f.relationType?[f.relationType]:null,
  p_operational_state:f.operationalState||null,p_concentration_level:f.concentration||null,p_size_metric:f.sizeMetric,p_color_metric:f.colorMetric,
  p_edge_metric:f.edgeMetric,p_perspective:f.perspective,p_anchor_type:null,p_anchor_id:null,p_expansion_levels:0};}
function csv(r:Result,title:string,generated:string){
  const lines:unknown[][]=[["Satrapy BI",title],["Periodo",r.period.from,r.period.to],["Generado",generated],[],["NODOS"],["ID","Tipo","Identidad","Código","Tamaño","Compras","Ventas","Inventario","Conexiones","Concentración","Disponibilidad"]];
  for(const n of r.nodes)lines.push([n.entity_id,n.type,n.label,n.secondary??"",n.size_value,n.metrics.purchases,n.metrics.sales,n.metrics.inventory,n.metrics.connections,n.concentration,n.availability??""]);
  lines.push([],["RELACIONES"],["ID","Origen","Destino","Tipo","Importe","Cantidad","Frecuencia","Métrica","Fuente","Periodo desde","Periodo hasta","Concentración","Estado operativo"]);
  for(const e of r.edges)lines.push([e.id,e.source,e.target,e.type,e.amount,e.quantity,e.frequency,e.weight,e.metric_source,e.period.from??"",e.period.to??"",e.concentration_share,e.operational_state??""]);
  lines.push([],["METODOLOGÍA"]);for(const[k,v]of Object.entries(r.methodology))lines.push([k,v]);
  return new TextEncoder().encode(`\uFEFF${lines.map(row=>row.map(cell=>`"${String(cell??"").replaceAll('"','""')}"`).join(",")).join("\r\n")}`);
}
async function xlsx(r:Result,title:string,generated:string){
  const wb=new ExcelJS.Workbook();wb.creator="Satrapy";wb.created=new Date(generated);
  const nodes=wb.addWorksheet("Nodos",{views:[{state:"frozen",ySplit:5,showGridLines:false}]});nodes.addRows([[title],["Periodo",r.period.from,r.period.to],["Generado",generated],[],["ID","Tipo","Identidad","Código","Tamaño","Compras","Ventas","Inventario","Conexiones","Concentración","Disponibilidad"]]);
  r.nodes.forEach(n=>nodes.addRow([n.entity_id,n.type,n.label,n.secondary,n.size_value,n.metrics.purchases,n.metrics.sales,n.metrics.inventory,n.metrics.connections,n.concentration,n.availability]));
  const edges=wb.addWorksheet("Relaciones",{views:[{state:"frozen",ySplit:5,showGridLines:false}]});edges.addRows([[title],["Periodo",r.period.from,r.period.to],["Generado",generated],[],["ID","Origen","Destino","Tipo","Importe","Cantidad","Frecuencia","Métrica","Fuente","Desde","Hasta","Concentración","Estado"]]);
  r.edges.forEach(e=>edges.addRow([e.id,e.source,e.target,e.type,e.amount,e.quantity,e.frequency,e.weight,e.metric_source,e.period.from,e.period.to,e.concentration_share,e.operational_state]));
  const method=wb.addWorksheet("Metodología");method.addRow(["Concepto","Definición"]);Object.entries(r.methodology).forEach(row=>method.addRow(row));
  for(const sheet of wb.worksheets){sheet.getRow(sheet===method?1:5).font={bold:true,color:{argb:"FFFFFF"}};sheet.getRow(sheet===method?1:5).fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};sheet.columns.forEach(c=>c.width=22);}
  return new Uint8Array(await wb.xlsx.writeBuffer());
}
function graphSvg(r:Result,title:string,generated:string){
  const width=1400,height=820,cx=700,cy=405,byType=new Map<string,NodeRow[]>();for(const n of r.nodes){const a=byType.get(n.type)??[];a.push(n);byType.set(n.type,a);}
  const order=["supplier","product","category","location"],xAt:Record<string,number>={supplier:150,product:545,category:900,location:1250},pos=new Map<string,{x:number;y:number}>();
  for(const type of order){const rows=byType.get(type)??[];rows.forEach((n,i)=>pos.set(n.id,{x:xAt[type],y:110+(i+1)*(height-190)/(rows.length+1)}));}
  const esc=(s:unknown)=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]!));
  const colors:Record<string,string>={supplier:"#27645a",product:"#327a9b",category:"#a66b29",location:"#76548d"};
  const edgeSvg=r.edges.map(e=>{const a=pos.get(e.source),b=pos.get(e.target);return a&&b?`<line x1="${a.x}" y1="${a.y}" x2="${b.x}" y2="${b.y}" stroke="#8ba79f" stroke-width="${1+Math.min(6,Math.sqrt(Math.max(e.weight,0))/30)}" opacity=".55"/>`:"";}).join("");
  const nodeSvg=r.nodes.map(n=>{const p=pos.get(n.id)??{x:cx,y:cy};return`<g><circle cx="${p.x}" cy="${p.y}" r="${10+Math.min(16,Math.sqrt(Math.max(n.size_value,0))/40)}" fill="${colors[n.type]??"#555"}" stroke="white" stroke-width="2"/><text x="${p.x}" y="${p.y+32}" text-anchor="middle">${esc(n.label.slice(0,28))}</text></g>`;}).join("");
  return`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="100%" height="100%" fill="#f7f9f8"/><style>text{font-family:Arial,sans-serif;fill:#17211e;font-size:11px;font-weight:600}</style><text x="45" y="42" font-size="24">${esc(title)}</text><text x="45" y="66" font-size="11">${esc(`${r.period.from} a ${r.period.to} · generado ${generated} · ${r.nodes.length} nodos · ${r.edges.length} relaciones`)}</text>${edgeSvg}${nodeSvg}<text x="45" y="795" font-size="10">${esc("Surtido y disponibilidad son relaciones distintas. La cercanía visual no implica causalidad.")}</text></svg>`;
}
async function png(r:Result,title:string,generated:string){return new Uint8Array(await sharp(Buffer.from(graphSvg(r,title,generated))).png().toBuffer());}
async function pdf(r:Result,title:string,generated:string){
  const doc=await PDFDocument.create(),page=doc.addPage([841.89,595.28]),regular=await doc.embedFont(StandardFonts.Helvetica),bold=await doc.embedFont(StandardFonts.HelveticaBold);
  const image=await doc.embedPng(await png(r,title,generated));page.drawImage(image,{x:25,y:92,width:791,height:463});page.drawText(title,{x:28,y:568,size:15,font:bold,color:rgb(.1,.35,.3)});
  page.drawText(`${r.period.from} a ${r.period.to} · ${r.nodes.length} nodos · ${r.edges.length} relaciones · ${generated}`,{x:28,y:550,size:7,font:regular,color:rgb(.35,.4,.38)});
  page.drawText("Metodologia: etapas de compra no acumulables; surtido y readiness separados; cercania visual no implica causalidad.",{x:28,y:64,size:7,font:regular,color:rgb(.35,.4,.38)});
  page.drawText(String(r.methodology.concentration??"").slice(0,150),{x:28,y:50,size:7,font:regular,color:rgb(.35,.4,.38)});return doc.save();
}
function contentType(format:string){return format==="csv"?"text/csv; charset=utf-8":format==="xlsx"?"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":format==="png"?"image/png":"application/pdf";}
function message(value:string,status:number){return NextResponse.json({message:value},{status,headers:{"cache-control":"no-store"}});}
