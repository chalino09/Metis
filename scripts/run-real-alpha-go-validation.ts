import { spawnSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { parseAlphaWorkbook } from "../app/lib/alpha.ts";
import type { ImportIssue, ParsedAlphaFile } from "../app/lib/types.ts";

const root = process.cwd();
const folder = process.env.ALPHA_ERP_IMPORT_DIR;
if (!folder) throw new Error("ALPHA_ERP_IMPORT_DIR no está configurado.");
const mapping = JSON.parse(await readFile(resolve(root,"config/alpha-commercial-mappings-20260708.json"),"utf8"));
const names = await readdir(folder);
const sourceName = (prefix: string) => {
  const found = names.find((name) => name.toLowerCase().startsWith(prefix.toLowerCase()));
  if (!found) throw new Error(`Falta la fuente ${prefix}.`);
  return found;
};
async function parse(path: string, name = basename(path)): Promise<ParsedAlphaFile> {
  const bytes = await readFile(path);
  return parseAlphaWorkbook(bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength),name,"local_development");
}

const [fiscal,catalog,prices,costs,inventory] = await Promise.all([
  parse("/Users/chalino09/Downloads/3.1 PRODUCTOS.xls"),
  parse(resolve(folder,sourceName("cata_prd_20260708_005NMD"))),
  parse(resolve(folder,sourceName("rprecprd"))),
  parse(resolve(folder,sourceName("rcostprd"))),
  parse(resolve(folder,sourceName("reexic2"))),
]);
if (fiscal.products.length!==1502 || fiscal.issues.some((issue)=>issue.severity==="error")) throw new Error("La fuente fiscal no coincide con el corte aprobado de 1,502 productos.");

const issueStatus = (issues: ImportIssue[],rowNumber: number) => {
  const rows=issues.filter((issue)=>issue.rowNumber===rowNumber);
  return rows.some((issue)=>issue.severity==="error")?"error":rows.some((issue)=>issue.severity==="warning")?"warning":"valid";
};
const productRows = (parsed: ParsedAlphaFile) => parsed.products.map((row)=>({row_number:row.rowNumber,source_file:parsed.fileName,detected_type:"products",raw_data:{cells:row.rawData},normalized_data:row,validation_status:issueStatus(parsed.issues,row.rowNumber)}));
const priceRows = prices.prices.map((row)=>({row_number:row.rowNumber,source_file:prices.fileName,detected_type:"prices",raw_data:{cells:row.rawData},normalized_data:{sourceRowNumber:row.sourceRowNumber,alphaSku:row.alphaSku,alphaClass:row.alphaClass,description:row.description,unit:row.unit,listNumber:row.listNumber,listExternalCode:`ALPHA_LIST_${row.listNumber}`,semanticCode:null,amount:row.amount,currencyLabel:row.currencyLabel,currencyCode:null,effectiveDate:prices.snapshotDate},validation_status:issueStatus(prices.issues,row.rowNumber)}));
const costRows = costs.costs.map((row)=>({row_number:row.rowNumber,source_file:costs.fileName,detected_type:"costs",raw_data:{cells:row.rawData},normalized_data:{alphaSku:row.alphaSku,alphaClass:row.alphaClass,description:row.description,unit:row.unit,replacementCost:row.replacementCost,currencyLabel:row.currencyLabel,currencyCode:null,adValorem:row.adValorem,effectiveDate:costs.snapshotDate},validation_status:issueStatus(costs.issues,row.rowNumber)}));
const inventoryRows = inventory.inventory.map((row)=>{const location=inventory.locations.find((item)=>item.externalCode===row.locationCode);const quarantined=row.alphaSku==="HO38808";return {row_number:row.rowNumber,source_file:inventory.fileName,detected_type:"inventory",raw_data:{cells:row.rawData},normalized_data:{alphaSku:row.alphaSku,alphaClass:row.alphaClass,description:row.description,locationCode:row.locationCode,locationName:row.locationName,locationType:location?.locationType??null,classificationSource:location?.classificationSource??null,quantity:row.quantity,unit:row.unit,replacementCost:row.replacementCost,reportedValue:row.reportedValue,snapshotDate:inventory.snapshotDate,rejected:quarantined},validation_status:quarantined?"warning":issueStatus(inventory.issues,row.rowNumber)}});
const rejectedRows = (parsed: ParsedAlphaFile) => parsed.rejectedRows.map((row)=>({row_number:row.rowNumber,source_file:parsed.fileName,detected_type:row.detectedType,raw_data:{cells:row.rawData},normalized_data:{...row.normalizedData,rejected:true},validation_status:issueStatus(parsed.issues,row.rowNumber)}));
const errorRows = (parsed: ParsedAlphaFile) => parsed.issues.map((issue)=>({severity:issue.severity,error_code:issue.code,message:issue.message,row_number:issue.rowNumber??null,alpha_sku:issue.alphaSku??null,location_code:issue.locationCode??null,context_key:issue.contextKey??null}));
const inventoryErrors=[...errorRows(inventory),{severity:"warning",error_code:"PRODUCTO_INEXISTENTE",message:"HO38808 está marcado Eliminados; sus 2 unidades en CUAPA se conservan como diferencia legacy fuera del inventario operativo.",row_number:inventory.inventory.find((row)=>row.alphaSku==="HO38808")?.rowNumber??null,alpha_sku:"HO38808",location_code:"CUAPA",context_key:"legacy_inactive_stock"}];
const literal=(value:string)=>`'${value.replaceAll("'","''")}'`;
const json=(tag:string,value:unknown)=>`$${tag}$${JSON.stringify(value)}$${tag}$::jsonb`;
const stage=(parsed:ParsedAlphaFile,type:string,rows:unknown[],errors:unknown[])=>`public.stage_alpha_import(v_company,'${type}','local_development',${literal(parsed.fileName)},'xls',${literal(parsed.fileHash)},${parsed.snapshotDate?literal(parsed.snapshotDate):"null"},${json(`${type}_rows`,rows)},${json(`${type}_errors`,errors)})`;
const priceMaps=Object.entries(mapping.price_list_mappings) as Array<[string,{semantic_code:string,is_default:boolean}]>;

const sql=String.raw`\set ON_ERROR_STOP on
begin;
do $go$
declare
 v_company uuid:='27000000-0000-4000-8000-000000000001';v_actor uuid:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 v_result jsonb;v_batch uuid;v_cursor uuid;v_product uuid;v_location uuid;v_list uuid;v_balance numeric;v_session jsonb;v_cart jsonb;v_quote jsonb;v_sale jsonb;v_close jsonb;
 v_total integer;v_ready integer;v_pending integer;v_missing_tax integer;v_missing_price integer;v_missing_cost integer;v_ticket_count integer;
begin
 perform set_config('request.jwt.claim.sub',v_actor::text,true);perform set_config('request.jwt.claim.role','authenticated',true);
 insert into public.companies(id,legal_name,display_name) values(v_company,'Validación GO Alpha real','Validación GO Alpha real');
 insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin' on conflict do nothing;

 v_result:=${stage(fiscal,"products",productRows(fiscal),errorRows(fiscal))};v_batch:=(v_result->>'batch_id')::uuid;v_result:=public.confirm_staged_import(v_batch);if v_result->>'status'<>'completed' then raise exception 'Fiscal: %',v_result;end if;
 v_result:=${stage(catalog,"products",productRows(catalog),errorRows(catalog))};v_batch:=(v_result->>'batch_id')::uuid;v_result:=public.confirm_staged_import(v_batch);if v_result->>'status'<>'completed' then raise exception 'Catálogo: %',v_result;end if;

 v_result:=${stage(prices,"prices",[...priceRows,...rejectedRows(prices)],errorRows(prices))};v_batch:=(v_result->>'batch_id')::uuid;
 perform public.review_staged_currency(v_batch,'PESOS','${mapping.currency_mappings.PESOS}');
 ${priceMaps.map(([external,value])=>`perform public.review_staged_price_list(v_batch,'${external}','${value.semantic_code}',${value.is_default});`).join("\n ")}
 perform public.acknowledge_staged_warnings(v_batch,'PRECIO_FALTANTE',${literal(mapping.warning_reconciliation.PRECIO_FALTANTE)});
 v_result:=public.confirm_commercial_import(v_batch);if v_result->>'status'<>'completed' or (v_result->>'records_imported')::integer<>2251 then raise exception 'Precios: %',v_result;end if;

 v_result:=${stage(costs,"costs",[...costRows,...rejectedRows(costs)],errorRows(costs))};v_batch:=(v_result->>'batch_id')::uuid;
 perform public.review_staged_currency(v_batch,'PESOS','${mapping.currency_mappings.PESOS}');
 perform public.acknowledge_staged_warnings(v_batch,'COSTO_FALTANTE',${literal(mapping.warning_reconciliation.COSTO_FALTANTE)});
 v_result:=public.confirm_commercial_import(v_batch);if v_result->>'status'<>'completed' or (v_result->>'records_imported')::integer<>1665 then raise exception 'Costos: %',v_result;end if;

 v_result:=${stage(inventory,"inventory",inventoryRows,inventoryErrors)};v_batch:=(v_result->>'batch_id')::uuid;perform public.acknowledge_staged_warnings(v_batch,'PRODUCTO_INEXISTENTE','HO38808 está inactivo en catálogo; 2 unidades CUAPA quedan en cuarentena legacy, no vendibles.');v_result:=public.confirm_staged_import(v_batch);if v_result->>'status'<>'completed' then raise exception 'Inventario: %',v_result;end if;
 loop v_result:=public.backfill_inventory_opening_balances(v_company,v_cursor,1000);v_cursor:=nullif(v_result->>'next_snapshot_item_id','')::uuid;exit when (v_result->>'complete')::boolean;end loop;

 select id into v_list from public.price_lists where company_id=v_company and external_code='ALPHA_LIST_1';
 update public.companies set default_price_policy='specific_list',default_price_list_id=v_list where id=v_company;
 select p.id,b.location_id,b.quantity_on_hand into v_product,v_location,v_balance from public.products p join public.inventory_balances b on b.product_id=p.id where p.company_id=v_company and p.alpha_sku='MS63533' and b.quantity_on_hand>=1 order by b.quantity_on_hand desc limit 1;
 update public.locations set default_price_list_id=v_list where id=v_location;
 insert into public.sales_assortments(id,company_id,code,name,status) values('27000000-0000-4000-8000-000000000002',v_company,'REAL-GO','Surtido validación real','draft');
 insert into public.sales_assortment_items(assortment_id,product_id) values('27000000-0000-4000-8000-000000000002',v_product);
 insert into public.location_sales_assortments(location_id,assortment_id,valid_from) values(v_location,'27000000-0000-4000-8000-000000000002',now()-interval '1 day');
 update public.sales_assortments set status='active' where id='27000000-0000-4000-8000-000000000002';

 select count(*),count(*) filter(where coalesce((r->>'pos_ready')::boolean,false)),count(*) filter(where not coalesce((r->>'pos_ready')::boolean,false)) into v_total,v_ready,v_pending from public.products p cross join lateral public.product_pos_readiness_detail(v_company,p.id,null,now()) r where p.company_id=v_company;
 select count(*) into v_missing_tax from public.products where company_id=v_company and tax_category_id is null;
 select count(*) into v_missing_price from public.products p where p.company_id=v_company and p.product_type='P. TERMINADO' and not exists(select 1 from public.product_prices pp where pp.product_id=p.id and pp.amount>0 and pp.valid_to is null);
 select count(*) into v_missing_cost from public.products p where p.company_id=v_company and not exists(select 1 from public.product_costs pc where pc.product_id=p.id and pc.valid_to is null);
 if v_total<>1670 or v_ready<>1501 then raise exception 'Readiness inesperado: total %, ready %, pending %',v_total,v_ready,v_pending;end if;
 if not coalesce((public.product_pos_readiness_detail(v_company,v_product,v_list,now())->>'pos_ready')::boolean,false) then raise exception 'MS63533 no quedó listo con la lista aprobada: %',public.product_pos_readiness_detail(v_company,v_product,v_list,now());end if;

 insert into public.cash_registers(id,company_id,location_id,code,display_name,currency_code) values('27000000-0000-4000-8000-000000000003',v_company,v_location,'REAL-01','Caja jornada real','MXN');
 insert into public.payment_methods(id,company_id,code,display_name,settlement_kind) values('27000000-0000-4000-8000-000000000004',v_company,'EFECTIVO','Efectivo','cash_drawer');
 insert into public.cash_denominations(id,company_id,currency_code,value,display_name) values('27000000-0000-4000-8000-000000000005',v_company,'MXN',100,'$100'),('27000000-0000-4000-8000-000000000006',v_company,'MXN',20,'$20');
 v_session:=public.open_cash_session(v_company,'27000000-0000-4000-8000-000000000003',jsonb_build_array(jsonb_build_object('denomination_id','27000000-0000-4000-8000-000000000005','quantity',1),jsonb_build_object('denomination_id','27000000-0000-4000-8000-000000000006','quantity',0)),'27000000-0000-4000-8000-000000000007');
 v_cart:=public.get_or_create_sale_cart(v_company,(v_session->>'cash_session_id')::uuid);perform public.change_sale_cart_item((v_cart->>'cart_id')::uuid,v_product,1,(v_cart->>'revision')::integer);v_quote:=public.quote_sale_cart((v_cart->>'cart_id')::uuid);
 if (v_quote->>'total_amount')::numeric<>360 then raise exception 'Cotización real inesperada: %',v_quote;end if;
 v_sale:=public.complete_sale((v_cart->>'cart_id')::uuid,(v_quote->>'revision')::integer,'cash','27000000-0000-4000-8000-000000000004',400,'27000000-0000-4000-8000-000000000008');
 if (select quantity_on_hand from public.inventory_balances where product_id=v_product and location_id=v_location)<>v_balance-1 then raise exception 'La venta real no descontó inventario.';end if;
 select count(*) into v_ticket_count from public.canonical_tickets where sale_id=(v_sale->>'sale_id')::uuid;if v_ticket_count<>1 then raise exception 'No se emitió ticket canónico.';end if;
 v_close:=public.close_cash_session((v_session->>'cash_session_id')::uuid,jsonb_build_array(jsonb_build_object('denomination_id','27000000-0000-4000-8000-000000000005','quantity',4),jsonb_build_object('denomination_id','27000000-0000-4000-8000-000000000006','quantity',3)),null,'27000000-0000-4000-8000-000000000009');
 if v_close->>'status'<>'closed' or (v_close->>'variance_amount')::numeric<>0 then raise exception 'Cierre real no cuadrado: %',v_close;end if;
 raise notice 'GO_DATA total=% ready=% pending=% missing_tax=% missing_sellable_price=% missing_cost=% fiscal=1502 prices=2251 costs=1665 inventory=2238 quarantined_inventory=HO38808:2 sku=MS63533 opening=100 sale=360 closing=460 variance=0 ticket=%',v_total,v_ready,v_pending,v_missing_tax,v_missing_price,v_missing_cost,v_sale->>'folio';
end $go$;
rollback;
`;
const result=spawnSync("docker",["exec","-i","supabase_db_satrapy-validation","psql","-U","postgres","-d","postgres"],{input:sql,encoding:"utf8",maxBuffer:128*1024*1024});
process.stdout.write(result.stdout);process.stderr.write(result.stderr);if(result.status!==0)process.exit(result.status??1);
