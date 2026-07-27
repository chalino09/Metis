import ExcelJS from "exceljs";
import { NextRequest,NextResponse } from "next/server";
import { BUDGET_IMPORT_COLUMNS } from "@/app/lib/bi-budget-import";

export const runtime="nodejs";
export const dynamic="force-dynamic";
export const maxDuration=300;

const EXAMPLES=[
  {name:"Venta neta empresa 2027",description:"Objetivo anual aprobado por dirección",metric_code:"net_sales",period_type:"annual",period_start:"2027-01-01",scope_type:"company",location_code:"",responsible_code:"",category_code:"",value:12000000,unit_code:"MXN"},
  {name:"Unidades tienda enero",description:"Distribución operativa",metric_code:"units_sold",period_type:"monthly",period_start:"2027-01-01",scope_type:"location",location_code:"CODIGO_CANONICO",responsible_code:"",category_code:"",value:2500,unit_code:"unit"},
];

export async function GET(request:NextRequest){
  const format=request.nextUrl.searchParams.get("format")??"csv";
  if(format==="xlsx"){
    const workbook=new ExcelJS.Workbook();workbook.creator="Satrapy";
    const sheet=workbook.addWorksheet("Presupuestos",{views:[{state:"frozen",ySplit:1}]});
    sheet.columns=BUDGET_IMPORT_COLUMNS.map(key=>({header:key,key,width:key==="description"?38:22}));
    EXAMPLES.forEach(row=>sheet.addRow(row));
    sheet.getRow(1).font={bold:true,color:{argb:"FFFFFFFF"}};
    sheet.getRow(1).fill={type:"pattern",pattern:"solid",fgColor:{argb:"FF1C6656"}};
    const guide=workbook.addWorksheet("Catálogos");
    guide.addRows([
      ["metric_code","net_sales | gross_margin | units_sold"],
      ["period_type","monthly | quarterly | annual"],
      ["scope_type","company | location | responsible | category | location_category | responsible_category"],
      ["unit_code","ISO 4217 (ej. MXN) o unit para units_sold"],
      ["Identidades","Usa códigos canónicos exactos. No se aceptan nombres ni datos Alpha."],
    ]);
    guide.getColumn(1).width=24;guide.getColumn(2).width=90;guide.getRow(1).font={bold:true};
    const bytes=new Uint8Array(await workbook.xlsx.writeBuffer());
    return new NextResponse(bytes as BodyInit,{headers:{
      "content-type":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition":'attachment; filename="plantilla_presupuestos_satrapy.xlsx"',
      "cache-control":"no-store",
    }});
  }
  const csv=[BUDGET_IMPORT_COLUMNS.join(","),...EXAMPLES.map(row=>BUDGET_IMPORT_COLUMNS.map(key=>csvCell(row[key])).join(","))].join("\r\n");
  return new NextResponse(`\uFEFF${csv}`,{headers:{
    "content-type":"text/csv; charset=utf-8",
    "content-disposition":'attachment; filename="plantilla_presupuestos_satrapy.csv"',
    "cache-control":"no-store",
  }});
}

function csvCell(value:unknown){const text=String(value??"");return`"${text.replaceAll('"','""')}"`;}
