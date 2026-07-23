import { spawnSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { parseAlphaPurchasingMigration } from "../app/lib/alpha-purchasing-migration.ts";
import { parseAlphaWorkbook } from "../app/lib/alpha.ts";

const directory=process.env.ALPHA_ERP_IMPORT_DIR;
if(!directory)throw new Error("ALPHA_ERP_IMPORT_DIR no está configurado.");
const allowed=/^(?:cata_prv|rpcon2|lfchvenc|pag_det)_.+\.xlsx?$/i;
const names=(await readdir(directory)).filter(name=>allowed.test(name)).sort();
const files=await Promise.all(names.map(async name=>new File([await readFile(resolve(directory,name))],name)));
const payload=await parseAlphaPurchasingMigration(files);
if(payload.purchaseOrders.length!==84||payload.purchaseOrderLines.length!==731)throw new Error(`Volumen real inesperado: ${payload.purchaseOrders.length} OC / ${payload.purchaseOrderLines.length} partidas.`);
if(payload.purchaseOrders.some(order=>order.source_approval_status!=="Aceptada"))throw new Error("Existe una OC real que no está Aceptada.");
const catalogName=(await readdir(directory)).filter(name=>/^cata_prd_.+\.xlsx?$/i.test(name)).sort()[0];
if(!catalogName)throw new Error("No hay un cata_prd real para verificar las partidas de OC.");
const catalogBytes=await readFile(resolve(directory,catalogName));
const catalogBuffer=catalogBytes.buffer.slice(catalogBytes.byteOffset,catalogBytes.byteOffset+catalogBytes.byteLength);
const catalog=await parseAlphaWorkbook(catalogBuffer,basename(catalogName),"local_development");
const requiredSkus=new Set(payload.purchaseOrderLines.map(line=>line.alpha_sku));
const products=catalog.products.filter(product=>requiredSkus.has(product.alphaSku)).map(product=>({alpha_sku:product.alphaSku,name:product.name,unit:product.unit}));
const resolvedSkus=new Set(products.map(product=>product.alpha_sku));
const missingSkus=[...requiredSkus].filter(sku=>!resolvedSkus.has(sku));
if(missingSkus.length)throw new Error(`${missingSkus.length} SKU de OC no existen en cata_prd real: ${missingSkus.slice(0,10).join(", ")}`);
const quote=(value:unknown)=>JSON.stringify(value).replaceAll("'","''");
const sql=String.raw`\set ON_ERROR_STOP on
begin;
do $validation$
declare
 v_company uuid:='37000000-0000-4000-8000-000000000001';v_batch uuid;v_result jsonb;v_status text:='in_progress';
 v_orders int;v_lines int;v_exceptions int;v_inventory bigint;v_costs bigint;v_receivables bigint;v_receipts bigint;v_supplier_pending int;v_supplier_detail text;v_exception uuid;v_canonical_supplier uuid;
begin
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);perform set_config('request.jwt.claim.role','authenticated',true);
 insert into public.companies(id,legal_name,display_name) values(v_company,'Validación OC Alpha','Validación OC Alpha');
 insert into public.user_roles(user_id,role_id,company_id) select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',id,v_company from public.roles where code='super_admin' on conflict do nothing;
 select count(*) into v_inventory from public.inventory_balances;select count(*) into v_costs from public.product_costs;select count(*) into v_receivables from public.customer_receivables;select count(*) into v_receipts from public.purchase_receipts;
 insert into public.products(company_id,alpha_sku,name,unit,is_active) select v_company,r.alpha_sku,r.name,r.unit,true from jsonb_to_recordset('${quote(products)}'::jsonb)r(alpha_sku text,name text,unit text);
 insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,status,records_received,imported_by,summary,completed_at)
 values(v_company,'${payload.cutoffDate}','real-alpha-purchase-orders-validation','staged',${payload.purchaseOrders.length+payload.purchaseOrderLines.length},'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','${quote({...payload.summary,error_count:0,warning_count:payload.differences.length})}'::jsonb,now()) returning id into v_batch;
 insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,counterparty_kind,supplier_type,tax_id,address_line,neighborhood,municipality,state_name,phone,source_row_number,source_row_hash)
 select v_batch,r.external_code,r.display_name,r.counterparty_kind,r.supplier_type,r.tax_id,r.address_line,r.neighborhood,r.municipality,r.state_name,r.phone,r.source_row_number,r.source_row_hash from jsonb_to_recordset('${quote(payload.suppliers)}'::jsonb)r(external_code text,display_name text,counterparty_kind text,supplier_type text,tax_id text,address_line text,neighborhood text,municipality text,state_name text,phone text,source_row_number int,source_row_hash text);
 insert into public.alpha_purchasing_import_orders(batch_id,source_order_key,order_number,branch_code,supplier_external_code,supplier_name,warehouse_name,ordered_date,currency_code,source_currency,source_status,source_approval_status,exchange_rate,discount_percent,source_row_number,source_row_hash)
 select v_batch,r.source_order_key,r.order_number,r.branch_code,r.supplier_external_code,r.supplier_name,r.warehouse_name,r.ordered_date,r.currency_code,r.source_currency,r.source_status,r.source_approval_status,r.exchange_rate,r.discount_percent,r.source_row_number,r.source_row_hash from jsonb_to_recordset('${quote(payload.purchaseOrders)}'::jsonb)r(source_order_key text,order_number text,branch_code text,supplier_external_code text,supplier_name text,warehouse_name text,ordered_date date,currency_code text,source_currency text,source_status text,source_approval_status text,exchange_rate numeric,discount_percent numeric,source_row_number int,source_row_hash text);
 insert into public.alpha_purchasing_import_order_lines(batch_id,source_order_key,line_number,alpha_class,alpha_sku,description,unit,attribute,quantity,unit_cost_mxn,discount_1,discount_2,expected_date,requisition_reference,source_row_number,source_row_hash)
 select v_batch,r.source_order_key,r.line_number,r.alpha_class,r.alpha_sku,r.description,r.unit,r.attribute,r.quantity,r.unit_cost_mxn,r.discount_1,r.discount_2,r.expected_date,r.requisition_reference,r.source_row_number,r.source_row_hash from jsonb_to_recordset('${quote(payload.purchaseOrderLines)}'::jsonb)r(source_order_key text,line_number int,alpha_class text,alpha_sku text,description text,unit text,attribute text,quantity numeric,unit_cost_mxn numeric,discount_1 numeric,discount_2 numeric,expected_date date,requisition_reference text,source_row_number int,source_row_hash text);
 v_result:=public.promote_alpha_suppliers(v_batch);
 select e.id into v_exception from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id where e.batch_id=v_batch and s.external_code='36';
 if v_exception is not null then
   v_result:=public.resolve_supplier_import_exception(v_exception,'create_separate',null,'RFC y razón social verificados; se crea una sola identidad canónica para las cuentas Alpha 36 y 37.');
   v_canonical_supplier:=(v_result->>'supplier_id')::uuid;
   select e.id into v_exception from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id where e.batch_id=v_batch and s.external_code='37';
   perform public.resolve_supplier_import_exception(v_exception,'link_existing',v_canonical_supplier,'Mismo RFC y proveedor legal; DÓLAR distingue la cuenta fuente, no una identidad comercial distinta.');
 end if;
 select count(*) into v_supplier_pending from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id where e.batch_id=v_batch and e.status='pending' and exists(select 1 from public.alpha_purchasing_import_orders o where o.batch_id=v_batch and o.supplier_external_code=s.external_code);
 if v_supplier_pending>0 then
   select string_agg(format('%s:%s [%s] OC=%s',s.external_code,s.display_name,array_to_string(e.conflict_kinds,','),(select count(*) from public.alpha_purchasing_import_orders o where o.batch_id=v_batch and o.supplier_external_code=s.external_code)), '; ' order by s.external_code) into v_supplier_detail
   from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id where e.batch_id=v_batch and e.status='pending' and exists(select 1 from public.alpha_purchasing_import_orders o where o.batch_id=v_batch and o.supplier_external_code=s.external_code);
   raise exception '% proveedores excepcionales de M3A son utilizados por OC reales: %',v_supplier_pending,v_supplier_detail;
 end if;
 while v_status='in_progress' loop v_result:=public.promote_alpha_purchase_orders(v_batch,25);v_status:=v_result->>'status';end loop;
 select count(*) into v_orders from public.purchase_orders where company_id=v_company and origin='imported_historical';
 select count(*) into v_lines from public.purchase_order_lines l join public.purchase_orders o on o.id=l.purchase_order_id where o.company_id=v_company and o.origin='imported_historical';
 select count(*) into v_exceptions from public.purchase_order_import_exceptions where batch_id=v_batch and status='pending';
 if v_orders<>84 or v_lines<>731 or v_exceptions<>0 then raise exception 'Conciliación real incorrecta: % OC / % partidas / % excepciones.',v_orders,v_lines,v_exceptions;end if;
 if exists(select 1 from public.purchase_orders where company_id=v_company and (status<>'approved' or origin<>'imported_historical')) then raise exception 'Una OC real no quedó aprobada e identificada como histórica.';end if;
 if (select count(*) from public.purchase_order_external_references where company_id=v_company and source_system='alpha')<>84 then raise exception 'Las referencias externas no concilian.';end if;
 v_result:=public.promote_alpha_purchase_orders(v_batch,25);if v_result->>'status'<>'already_promoted' or (select count(*) from public.purchase_orders where company_id=v_company)<>84 then raise exception 'El reintento real no fue idempotente.';end if;
 if (select count(*) from public.inventory_balances)<>v_inventory or (select count(*) from public.product_costs)<>v_costs or (select count(*) from public.customer_receivables)<>v_receivables or (select count(*) from public.purchase_receipts)<>v_receipts then raise exception 'La promoción real alteró inventario, costos, recepciones o cuentas.';end if;
 raise notice 'REAL_ALPHA_PURCHASE_ORDERS source_orders=84 source_lines=731 promoted_orders=% promoted_lines=% exceptions=% status=approved inventory_changes=0 cost_changes=0 receipts=0 payables=0 idempotent=true',v_orders,v_lines,v_exceptions;
end $validation$;
rollback;`;
const result=spawnSync("docker",["exec","-i","supabase_db_satrapy-validation","psql","-U","postgres","-d","postgres"],{input:sql,encoding:"utf8",maxBuffer:64*1024*1024});
process.stdout.write(result.stdout);process.stderr.write(result.stderr);if(result.status!==0)process.exit(result.status??1);
