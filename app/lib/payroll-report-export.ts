import ExcelJS from "exceljs";

export type PayrollReportPeriod = { starts_on:string; ends_on:string; payment_state?:string; has_adjustments?:boolean };
export type PayrollReportLine = { collaborator_name_snapshot:string; base_pay_snapshot:number; additions_total:number; reductions_total:number; total_pay:number; payment_method:string; concepts:Array<{ label:string; concept_code:string; direction:string; amount:number; source_date:string|null; calculation_metadata?:Record<string,unknown> }> };
export type PayrollReportBatch = { payment_method:string; payment_date:string; payment_reference:string; total_amount:number };

const label:Record<string,string>={preparing:"En preparación",reviewing:"En revisión",due:"Nómina por pagar",partial:"Pago parcial",paid:"Nómina pagada"};
const moneyFormat='$#,##0.00;[Red]($#,##0.00);-';
const paymentMethodLabel:Record<string,string>={unspecified:"Sin definir",transfer:"Transferencia",cash:"Efectivo",other:"Otro"};
const isoDates=(startsOn:string,endsOn:string)=>{const values:string[]=[];const cursor=new Date(`${startsOn}T12:00:00Z`);const end=new Date(`${endsOn}T12:00:00Z`);while(cursor<=end){values.push(cursor.toISOString().slice(0,10));cursor.setUTCDate(cursor.getUTCDate()+1);}return values;};
const signed=(concept:{direction:string;amount:number})=>concept.direction==="reduction"?-Number(concept.amount):concept.direction==="addition"?Number(concept.amount):0;

export async function createPayrollPeriodExcel(period:PayrollReportPeriod, lines:PayrollReportLine[], batches:PayrollReportBatch[]) {
  const workbook=new ExcelJS.Workbook();workbook.creator="Satrapy";workbook.created=new Date();
  const status=`${label[period.payment_state??"preparing"]??period.payment_state??"En preparación"}${period.has_adjustments?" · Con ajustes":""}`;
  const payments=new Map(batches.map(batch=>[batch.payment_method,batch]));
  const summary=workbook.addWorksheet("Nómina",{views:[{state:"frozen",ySplit:5,showGridLines:false}]});
  summary.mergeCells("A1:J1");summary.getCell("A1").value="Satrapy · Reporte de nómina";summary.getCell("A1").font={bold:true,size:18,color:{argb:"17211E"}};
  summary.mergeCells("A2:J2");summary.getCell("A2").value=`Periodo: ${period.starts_on} a ${period.ends_on} · ${status}`;summary.getCell("A2").font={size:10,color:{argb:"64716C"}};
  const headers=["Colaborador","Sueldo del periodo","Adiciones","Deducciones","Importe neto","Estado de pago","Fecha real de pago","Método","Referencia","Incidencias aplicadas"];
  summary.addRow([]);const header=summary.addRow(headers);header.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  for(const line of lines){const batch=payments.get(line.payment_method);const incidences=line.concepts.filter(item=>item.concept_code!=="base_pay");summary.addRow([line.collaborator_name_snapshot,line.base_pay_snapshot,line.additions_total,line.reductions_total,line.total_pay,status,batch?.payment_date??"",line.payment_method,batch?.payment_reference??"",incidences.map(item=>`${item.label} ${item.direction==="reduction"?"−":"+"}${Number(item.amount).toFixed(2)}`).join(" · ")||"Sin incidencias"]);}
  summary.columns=[{width:28},{width:16},{width:16},{width:16},{width:16},{width:23},{width:18},{width:16},{width:26},{width:54}];
  [2,3,4,5].forEach(column=>summary.getColumn(column).numFmt=moneyFormat);summary.autoFilter={from:{row:4,column:1},to:{row:Math.max(4,summary.rowCount),column:headers.length}};
  const incidents=workbook.addWorksheet("Incidencias",{views:[{state:"frozen",ySplit:1,showGridLines:false}]});
  const incidentHeaders=["Colaborador","Fecha efectiva","Concepto","Dirección","Importe","Fecha de origen","Retroactiva"];
  const incidentHeader=incidents.addRow(incidentHeaders);incidentHeader.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  for(const line of lines) for(const item of line.concepts.filter(concept=>concept.concept_code!=="base_pay")){const metadata=item.calculation_metadata??{};const occurredOn=String(metadata.occurred_on??item.source_date??"");incidents.addRow([line.collaborator_name_snapshot,item.source_date??"",item.label,item.direction==="reduction"?"Deducción":"Adición",item.amount,occurredOn,metadata.retroactive?"Sí":"No"]);}
  incidents.columns=[{width:28},{width:18},{width:24},{width:16},{width:16},{width:18},{width:14}];incidents.getColumn(5).numFmt=moneyFormat;incidents.autoFilter={from:{row:1,column:1},to:{row:Math.max(1,incidents.rowCount),column:incidentHeaders.length}};
  const daily=workbook.addWorksheet("Detalle por fecha",{views:[{state:"frozen",ySplit:4,showGridLines:false}]});
  daily.mergeCells("A1:I1");daily.getCell("A1").value="Satrapy · Detalle de nómina por fecha";daily.getCell("A1").font={bold:true,size:18,color:{argb:"17211E"}};
  daily.mergeCells("A2:I2");daily.getCell("A2").value=`Periodo: ${period.starts_on} a ${period.ends_on} · El sueldo del periodo se conserva separado de los movimientos diarios.`;daily.getCell("A2").font={size:10,color:{argb:"64716C"}};
  const dailyHeaders=["Colaborador","Fecha","Sueldo del periodo","Horas extra","Inasistencias","Comisiones","Bonificaciones","Movimiento neto","Observaciones"];
  daily.addRow([]);const dailyHeader=daily.addRow(dailyHeaders);dailyHeader.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  for(const line of lines) for(const sourceDate of isoDates(period.starts_on,period.ends_on)){const concepts=line.concepts.filter(item=>item.concept_code!=="base_pay"&&item.source_date===sourceDate);const amount=(code:string)=>concepts.filter(item=>item.concept_code===code).reduce((total,item)=>total+Number(item.amount),0);daily.addRow([line.collaborator_name_snapshot,sourceDate,line.base_pay_snapshot,amount("overtime"),amount("absence"),amount("commission"),amount("bonus"),concepts.reduce((total,item)=>total+signed(item),0),concepts.map(item=>item.label).join(" · ")||"Sin movimientos"]);}
  daily.columns=[{width:28},{width:16},{width:18},{width:16},{width:16},{width:16},{width:16},{width:18},{width:38}];[3,4,5,6,7,8].forEach(column=>daily.getColumn(column).numFmt=moneyFormat);daily.autoFilter={from:{row:4,column:1},to:{row:Math.max(4,daily.rowCount),column:dailyHeaders.length}};

  const receipts=workbook.addWorksheet("Recibos",{views:[{showGridLines:false}]});
  receipts.columns=[{width:28},{width:42},{width:18}];let receiptRow=1;
  for(const line of lines){const batch=payments.get(line.payment_method);receipts.mergeCells(receiptRow,1,receiptRow,3);const title=receipts.getCell(receiptRow,1);title.value="Satrapy · Recibo de nómina";title.font={bold:true,size:16,color:{argb:"17211E"}};receiptRow+=2;
    receipts.getCell(receiptRow,1).value="Colaborador";receipts.getCell(receiptRow,2).value=line.collaborator_name_snapshot;receiptRow++;
    receipts.getCell(receiptRow,1).value="Periodo";receipts.getCell(receiptRow,2).value=`${period.starts_on} a ${period.ends_on}`;receiptRow++;
    receipts.getCell(receiptRow,1).value="Forma de pago";receipts.getCell(receiptRow,2).value=paymentMethodLabel[line.payment_method]??line.payment_method;receipts.getCell(receiptRow,3).value=batch?`${batch.payment_date} · ${batch.payment_reference}`:"";receiptRow+=2;
    const receiptHeader=receipts.getRow(receiptRow);receiptHeader.values=["Concepto","Fecha / cálculo","Importe"];receiptHeader.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});receiptRow++;
    receipts.getRow(receiptRow).values=["Sueldo del periodo",period.ends_on,line.base_pay_snapshot];receiptRow++;
    for(const concept of line.concepts.filter(item=>item.concept_code!=="base_pay")){const metadata=concept.calculation_metadata??{};const detail=concept.concept_code==="overtime"?`${metadata.payable_hours??metadata.hours??""} h`:concept.concept_code==="absence"?`${metadata.days??0} días · ${metadata.hours??0} horas`:"";receipts.getRow(receiptRow).values=[concept.label,[concept.source_date,detail].filter(Boolean).join(" · "),signed(concept)];receiptRow++;}
    receipts.getRow(receiptRow).values=["Pago neto","",line.total_pay];receipts.getRow(receiptRow).font={bold:true,size:12,color:{argb:"1C6656"}};receiptRow+=3;
    receipts.mergeCells(receiptRow,1,receiptRow,2);receipts.getCell(receiptRow,1).value="Firma de conformidad: __________________________________________";receiptRow+=3;
  }
  receipts.getColumn(3).numFmt=moneyFormat;
  for(const sheet of [summary,incidents,daily,receipts]){sheet.eachRow(row=>{row.eachCell(cell=>{cell.alignment={vertical:"top",wrapText:true};});});}
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}

export async function createPayrollReceiptExcel(period:PayrollReportPeriod,line:PayrollReportLine,batches:PayrollReportBatch[]){
  const workbook=new ExcelJS.Workbook();workbook.creator="Satrapy";workbook.created=new Date();
  const receipt=workbook.addWorksheet("Recibo",{views:[{showGridLines:false}]});receipt.columns=[{width:28},{width:42},{width:18}];
  const batch=batches.find(item=>item.payment_method===line.payment_method);let row=1;
  receipt.mergeCells(row,1,row,3);const title=receipt.getCell(row,1);title.value="Satrapy · Recibo de nómina";title.font={bold:true,size:16,color:{argb:"17211E"}};row+=2;
  receipt.getCell(row,1).value="Colaborador";receipt.getCell(row,2).value=line.collaborator_name_snapshot;row++;
  receipt.getCell(row,1).value="Periodo";receipt.getCell(row,2).value=`${period.starts_on} a ${period.ends_on}`;row++;
  receipt.getCell(row,1).value="Forma de pago";receipt.getCell(row,2).value=paymentMethodLabel[line.payment_method]??line.payment_method;receipt.getCell(row,3).value=batch?`${batch.payment_date} · ${batch.payment_reference}`:"";row+=2;
  const header=receipt.getRow(row);header.values=["Concepto","Fecha / cálculo","Importe"];header.eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:"1C6656"}};cell.font={bold:true,color:{argb:"FFFFFF"}};});row++;
  receipt.getRow(row).values=["Sueldo del periodo",period.ends_on,line.base_pay_snapshot];row++;
  for(const concept of line.concepts.filter(item=>item.concept_code!=="base_pay")){const metadata=concept.calculation_metadata??{};const detail=concept.concept_code==="overtime"?`${metadata.payable_hours??metadata.hours??""} h`:concept.concept_code==="absence"?`${metadata.days??0} días · ${metadata.hours??0} horas`:"";receipt.getRow(row).values=[concept.label,[concept.source_date,detail].filter(Boolean).join(" · "),signed(concept)];row++;}
  receipt.getRow(row).values=["Pago neto","",line.total_pay];receipt.getRow(row).font={bold:true,size:12,color:{argb:"1C6656"}};row+=3;
  receipt.mergeCells(row,1,row,2);receipt.getCell(row,1).value="Firma de conformidad: __________________________________________";
  receipt.getColumn(3).numFmt=moneyFormat;receipt.eachRow(receiptRow=>receiptRow.eachCell(cell=>{cell.alignment={vertical:"top",wrapText:true};}));
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}
