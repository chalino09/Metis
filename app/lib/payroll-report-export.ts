import ExcelJS from "exceljs";

export type PayrollReportPeriod = { starts_on:string; ends_on:string; payment_state?:string; has_adjustments?:boolean };
export type PayrollReportLine = { collaborator_name_snapshot:string; base_pay_snapshot:number; additions_total:number; reductions_total:number; total_pay:number; payment_method:string; concepts:Array<{ label:string; concept_code:string; direction:string; amount:number; source_date:string|null; calculation_metadata?:Record<string,unknown> }> };
export type PayrollReportBatch = { payment_method:string; payment_date:string; payment_reference:string; total_amount:number };

const label:Record<string,string>={preparing:"En preparación",reviewing:"En revisión",due:"Nómina por pagar",partial:"Pago parcial",paid:"Nómina pagada"};
const moneyFormat='$#,##0.00;[Red]($#,##0.00);-';

export async function createPayrollPeriodExcel(period:PayrollReportPeriod, lines:PayrollReportLine[], batches:PayrollReportBatch[]) {
  const workbook=new ExcelJS.Workbook();workbook.creator="Satrapy";workbook.created=new Date();
  const status=`${label[period.payment_state??"preparing"]??period.payment_state??"En preparación"}${period.has_adjustments?" · Con ajustes":""}`;
  const payments=new Map(batches.map(batch=>[batch.payment_method,batch]));
  const summary=workbook.addWorksheet("Nómina",{views:[{state:"frozen",ySplit:5,showGridLines:false}]});
  summary.mergeCells("A1:J1");summary.getCell("A1").value="Satrapy · Reporte de nómina";summary.getCell("A1").font={bold:true,size:18,color:{argb:"17211E"}};
  summary.mergeCells("A2:J2");summary.getCell("A2").value=`Periodo: ${period.starts_on} a ${period.ends_on} · ${status}`;summary.getCell("A2").font={size:10,color:{argb:"64716C"}};
  const headers=["Colaborador","Sueldo base","Adiciones","Deducciones","Importe neto","Estado de pago","Fecha real de pago","Método","Referencia","Incidencias aplicadas"];
  summary.addRow([]);const header=summary.addRow(headers);header.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  for(const line of lines){const batch=payments.get(line.payment_method);const incidences=line.concepts.filter(item=>item.concept_code!=="base_pay");summary.addRow([line.collaborator_name_snapshot,line.base_pay_snapshot,line.additions_total,line.reductions_total,line.total_pay,status,batch?.payment_date??"",line.payment_method,batch?.payment_reference??"",incidences.map(item=>`${item.label} ${item.direction==="reduction"?"−":"+"}${Number(item.amount).toFixed(2)}`).join(" · ")||"Sin incidencias"]);}
  summary.columns=[{width:28},{width:16},{width:16},{width:16},{width:16},{width:23},{width:18},{width:16},{width:26},{width:54}];
  [2,3,4,5].forEach(column=>summary.getColumn(column).numFmt=moneyFormat);summary.autoFilter={from:{row:4,column:1},to:{row:Math.max(4,summary.rowCount),column:headers.length}};
  const incidents=workbook.addWorksheet("Incidencias",{views:[{state:"frozen",ySplit:1,showGridLines:false}]});
  const incidentHeaders=["Colaborador","Fecha efectiva","Concepto","Dirección","Importe","Fecha de origen","Retroactiva"];
  const incidentHeader=incidents.addRow(incidentHeaders);incidentHeader.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  for(const line of lines) for(const item of line.concepts.filter(concept=>concept.concept_code!=="base_pay")){const metadata=item.calculation_metadata??{};const occurredOn=String(metadata.occurred_on??item.source_date??"");incidents.addRow([line.collaborator_name_snapshot,item.source_date??"",item.label,item.direction==="reduction"?"Deducción":"Adición",item.amount,occurredOn,metadata.retroactive?"Sí":"No"]);}
  incidents.columns=[{width:28},{width:18},{width:24},{width:16},{width:16},{width:18},{width:14}];incidents.getColumn(5).numFmt=moneyFormat;incidents.autoFilter={from:{row:1,column:1},to:{row:Math.max(1,incidents.rowCount),column:incidentHeaders.length}};
  for(const sheet of [summary,incidents]){sheet.eachRow(row=>{row.eachCell(cell=>{cell.alignment={vertical:"top",wrapText:true};});});}
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}
