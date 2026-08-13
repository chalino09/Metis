import ExcelJS from "exceljs";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";

export type BiExportMetric = {
  code:string;name:string;formula:string;unit:string;source:string;grain:string;kind:string;limitations:string;
};
export type BiExportSection = {
  title:string;widgetType:"kpi"|"chart"|"table";definition:Record<string,unknown>;
  metrics:BiExportMetric[];currencyCode:string|null;rows:Array<Record<string,unknown>>;
  chart:Array<Record<string,unknown>>;total:number;
};
export type BiExportReport = { companyName:string;targetLabel:string;generatedAt:string;sections:BiExportSection[] };

const green="1C6656",ink="17211E",muted="64716C";

export function createBiCsv(report:BiExportReport){
  const lines:string[]=[`Satrapy BI,${csv(report.companyName)}`,`Reporte,${csv(report.targetLabel)}`,`Generado,${csv(report.generatedAt)}`,""];
  for(const section of report.sections){
    lines.push(csv(section.title),`Periodo,${csv(String(section.definition.date_from??""))},${csv(String(section.definition.date_to??""))}`);
    if(isOperational(section)){
      lines.push(`Dimensión,${csv(section.definition.dimension)}`,`Búsqueda,${csv(section.definition.search??"")}`,`Orden,${csv(section.definition.sort_by??"")},${csv(section.definition.sort_direction??"")}`);
      lines.push("Entidad,Valor actual,Valor anterior,Variación absoluta,Variación porcentual,Participación en el total,Contribución al cambio,Ranking,Estado,Disponible,Motivo");
      for(const row of section.rows)lines.push([row.group_label,row.current_value,row.previous_value,row.change_value,row.change_percent,row.share_percent,row.contribution_percent,row.ranking,row.status,row.available,row.reason].map(csv).join(","));
    }else{
      lines.push("Grupo,Métrica,Periodo actual,Periodo anterior,Disponible,Motivo");
      for(const row of section.rows)lines.push([row.group_label,row.metric_code,row.current_value,row.previous_value,row.available,row.reason].map(csv).join(","));
    }
    lines.push("");
  }
  return new TextEncoder().encode(`\uFEFF${lines.join("\r\n")}`);
}

export async function createBiXlsx(report:BiExportReport){
  const workbook=new ExcelJS.Workbook();workbook.creator="Satrapy";workbook.created=new Date(report.generatedAt);
  report.sections.forEach((section,index)=>{
    const sheet=workbook.addWorksheet(uniqueSheet(section.title,index),{views:[{state:"frozen",ySplit:7,showGridLines:false}]});
    const operational=isOperational(section),lastColumn=operational?"K":"F";
    sheet.mergeCells(`A1:${lastColumn}1`);sheet.getCell("A1").value=report.companyName;
    sheet.mergeCells(`A2:${lastColumn}2`);sheet.getCell("A2").value=section.title;
    sheet.mergeCells(`A3:${lastColumn}3`);sheet.getCell("A3").value=`${section.definition.date_from??"—"} a ${section.definition.date_to??"—"} · ${section.currencyCode??"Sin moneda"}`;
    if(operational){sheet.mergeCells("A4:K4");sheet.getCell("A4").value=`Búsqueda: ${section.definition.search??"Sin búsqueda"} · Orden: ${section.definition.sort_by??"—"} ${section.definition.sort_direction??""}`;sheet.getCell("A4").font={color:{argb:muted},size:9};}
    sheet.getCell("A1").font={bold:true,color:{argb:green}};sheet.getCell("A2").font={bold:true,size:20,color:{argb:ink}};sheet.getCell("A3").font={color:{argb:muted},size:10};
    sheet.getRow(6).values=operational?["Entidad","Valor actual","Valor anterior","Variación absoluta","Variación porcentual","Participación en el total","Contribución al cambio","Ranking","Estado","Disponible","Motivo"]:["Grupo","Métrica","Periodo actual","Periodo anterior","Disponible","Motivo"];
    sheet.getRow(6).eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:green}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
    if(operational){
      for(const row of section.rows)sheet.addRow([row.group_label,num(row.current_value),num(row.previous_value),num(row.change_value),percent(row.change_percent),percent(row.share_percent),percent(row.contribution_percent),num(row.ranking),row.status,row.available?"Sí":"No",row.reason??""]);
      sheet.columns.forEach((column,i)=>{column.width=[30,18,18,18,17,20,20,11,16,12,48][i]??18;});
      const valueFormat=section.metrics[0]?.unit==="currency"?'$#,##0.00;[Red]($#,##0.00);-':'#,##0.###';
      [2,3,4].forEach(column=>sheet.getColumn(column).numFmt=valueFormat);[5,6,7].forEach(column=>sheet.getColumn(column).numFmt='0.0%;[Red](0.0%);-');
      sheet.autoFilter={from:"A6",to:`K${Math.max(6,sheet.rowCount)}`};
    }else{
      for(const row of section.rows)sheet.addRow([row.group_label,row.metric_code,num(row.current_value),num(row.previous_value),row.available?"Sí":"No",row.reason??""]);
      sheet.columns.forEach((column,i)=>{column.width=[28,24,18,18,12,42][i]??18;});
      sheet.getColumn(3).numFmt=section.metrics[0]?.unit==="currency"?'$#,##0.00;[Red]($#,##0.00);-':'#,##0.###';sheet.getColumn(4).numFmt=sheet.getColumn(3).numFmt;
      sheet.autoFilter={from:"A6",to:`F${Math.max(6,sheet.rowCount)}`};
    }
  });
  const method=workbook.addWorksheet("Metodología",{views:[{showGridLines:false}]});
  method.columns=[{header:"Sección",key:"section",width:28},{header:"Métrica",key:"metric",width:28},{header:"Fórmula",key:"formula",width:52},{header:"Fuente",key:"source",width:46},{header:"Granularidad",key:"grain",width:20},{header:"Criterio",key:"kind",width:16},{header:"Limitaciones",key:"limitations",width:60}];
  for(const section of report.sections)for(const metric of section.metrics)method.addRow({section:section.title,metric:metric.name,formula:metric.formula,source:metric.source,grain:metric.grain,kind:metric.kind,limitations:metric.limitations});
  method.getRow(1).eachCell(cell=>{cell.fill={type:"pattern",pattern:"solid",fgColor:{argb:green}};cell.font={bold:true,color:{argb:"FFFFFF"}};});
  method.eachRow((row,index)=>{if(index>1)row.alignment={vertical:"top",wrapText:true};});
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}

export async function createBiPdf(report:BiExportReport){
  const doc=await PDFDocument.create(),regular=await doc.embedFont(StandardFonts.Helvetica),bold=await doc.embedFont(StandardFonts.HelveticaBold);
  const size:[number,number]=[841.89,595.28],margin=36,usable=size[0]-margin*2;let page=doc.addPage(size),y=size[1]-margin;
  const pageHeader=(title:string)=>{page.drawText(report.companyName,{x:margin,y,size:9,font:bold,color:rgb(.11,.40,.34)});y-=22;page.drawText(fit(title,80),{x:margin,y,size:20,font:bold,color:rgb(.09,.13,.12)});y-=18;page.drawText(`Generado ${new Date(report.generatedAt).toLocaleString("es-MX")}`,{x:margin,y,size:8,font:regular,color:rgb(.39,.44,.42)});y-=24;};
  const newPage=(title:string)=>{page=doc.addPage(size);y=size[1]-margin;pageHeader(title);};pageHeader(report.targetLabel);
  for(const section of report.sections){
    if(y<180)newPage(report.targetLabel);
    page.drawText(fit(section.title,72),{x:margin,y,size:14,font:bold,color:rgb(.11,.40,.34)});y-=16;
    page.drawText(`${section.definition.date_from??"—"} a ${section.definition.date_to??"—"} · ${section.total.toLocaleString("es-MX")} agregados`,{x:margin,y,size:8,font:regular,color:rgb(.39,.44,.42)});y-=18;
    if(section.chart.length){
      const visible=section.chart.slice(0,12),max=Math.max(...visible.map(row=>Math.abs(Number(row.current_value??0))),1);
      visible.forEach((row,index)=>{const yy=y-index*17;page.drawText(fit(String(row.group_label??""),24),{x:margin,y:yy,size:7,font:regular,color:rgb(.09,.13,.12)});page.drawRectangle({x:margin+125,y:yy-1,width:Math.abs(Number(row.current_value??0))/max*(usable-260),height:8,color:rgb(.11,.40,.34)});page.drawText(formatNumber(row.current_value,section.currencyCode),{x:size[0]-margin-95,y:yy,size:7,font:regular,color:rgb(.09,.13,.12)});});y-=visible.length*17+12;
    }
    for(const metric of section.metrics){if(y<70)newPage(report.targetLabel);page.drawText(fit(`${metric.name}: ${metric.formula}`,120),{x:margin,y,size:7.2,font:regular,color:rgb(.39,.44,.42)});y-=12;}
    y-=10;
  }
  doc.getPages().forEach((item,index)=>item.drawText(`Satrapy BI · Página ${index+1} de ${doc.getPageCount()}`,{x:margin,y:18,size:7,font:regular,color:rgb(.39,.44,.42)}));
  doc.setTitle(`${report.targetLabel} - ${report.companyName}`);doc.setAuthor("Satrapy");doc.setSubject("Reporte BI con fuentes y criterios metodológicos");
  return doc.save();
}

function csv(value:unknown){const text=value==null?"":String(value);return`"${text.replaceAll('"','""')}"`;}
function num(value:unknown){return value==null?null:Number(value);}
function percent(value:unknown){return value==null?null:Number(value)/100;}
function isOperational(section:BiExportSection){return section.definition.kind==="operational_table";}
function uniqueSheet(value:string,index:number){return`${index+1} ${value}`.replace(/[\\/?*[\]:]/g," ").slice(0,31);}
function pdfSafe(value:string){
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/Σ/g,"Suma ").replace(/[^\x20-\x7e\xa0-\xff]/g,"");
}
function fit(value:string,length:number){const safe=pdfSafe(value);return safe.length<=length?safe:`${safe.slice(0,length-3)}...`;}
function formatNumber(value:unknown,currency:string|null){const number=Number(value??0);return currency?number.toLocaleString("es-MX",{style:"currency",currency}):number.toLocaleString("es-MX",{maximumFractionDigits:2});}
