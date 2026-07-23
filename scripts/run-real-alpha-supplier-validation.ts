import { spawnSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { parseAlphaPurchasingMigration } from "../app/lib/alpha-purchasing-migration.ts";

const directory=process.env.ALPHA_ERP_IMPORT_DIR;
if(!directory) throw new Error("ALPHA_ERP_IMPORT_DIR no está configurado.");
const allowed=/^(?:cata_prv|rpcon2|lfchvenc|pag_det)_.+\.xlsx?$/i;
const names=(await readdir(directory)).filter(name=>allowed.test(name)).sort();
const files=await Promise.all(names.map(async name=>new File([await readFile(resolve(directory,name))],name)));
const payload=await parseAlphaPurchasingMigration(files);
if(payload.suppliers.length!==119) throw new Error(`Se esperaban 119 proveedores reales y se obtuvieron ${payload.suppliers.length}.`);

const supplierRows=JSON.stringify(payload.suppliers);
const sql=String.raw`\set ON_ERROR_STOP on
begin;
do $validation$
declare
 v_company uuid:='33000000-0000-4000-8000-000000000001';v_batch uuid;v_result jsonb;v_promoted int;v_pending int;v_total int;
begin
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);perform set_config('request.jwt.claim.role','authenticated',true);
 insert into public.companies(id,legal_name,display_name) values(v_company,'Validación Proveedores Alpha','Validación Proveedores Alpha');
 insert into public.user_roles(user_id,role_id,company_id) select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',id,v_company from public.roles where code='super_admin' on conflict do nothing;
 insert into public.alpha_purchasing_import_batches(company_id,cutoff_date,content_sha256,status,records_received,imported_by,summary,completed_at)
 values(v_company,'${payload.cutoffDate}','real-alpha-suppliers-validation','staged',${payload.suppliers.length},'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','${JSON.stringify({...payload.summary,error_count:0,warning_count:payload.differences.length}).replaceAll("'","''")}'::jsonb,now()) returning id into v_batch;
 insert into public.alpha_purchasing_import_suppliers(batch_id,external_code,display_name,counterparty_kind,supplier_type,tax_id,address_line,neighborhood,municipality,state_name,phone,source_row_number,source_row_hash)
 select v_batch,r.external_code,r.display_name,r.counterparty_kind,r.supplier_type,r.tax_id,r.address_line,r.neighborhood,r.municipality,r.state_name,r.phone,r.source_row_number,r.source_row_hash
 from jsonb_to_recordset($rows$${supplierRows}$rows$::jsonb) r(external_code text,display_name text,counterparty_kind text,supplier_type text,tax_id text,address_line text,neighborhood text,municipality text,state_name text,phone text,source_row_number int,source_row_hash text);
 v_result:=public.promote_alpha_suppliers(v_batch);
 select count(*) into v_promoted from public.alpha_purchasing_import_suppliers where batch_id=v_batch and promoted_supplier_id is not null;
 select count(*) into v_pending from public.supplier_import_exceptions where batch_id=v_batch and status='pending';
 select count(*) into v_total from public.suppliers where company_id=v_company;
 if v_promoted+v_pending<>119 or v_total<>v_promoted then raise exception 'Conciliación real incorrecta: promovidos %, pendientes %, canónicos %',v_promoted,v_pending,v_total;end if;
 if (select count(*) from public.supplier_external_references where company_id=v_company and source_system='alpha')<>v_promoted then raise exception 'Las referencias Alpha no concilian.';end if;
 if (select count(*) from public.alpha_purchasing_import_orders where batch_id=v_batch)<>0 or (select count(*) from public.alpha_purchasing_import_payable_documents where batch_id=v_batch)<>0 or (select count(*) from public.alpha_purchasing_import_payment_evidence where batch_id=v_batch)<>0 then raise exception 'La promoción 3A creó operaciones posteriores.';end if;
 v_result:=public.promote_alpha_suppliers(v_batch);if v_result->>'status'<>'already_promoted' or (select count(*) from public.suppliers where company_id=v_company)<>v_total then raise exception 'El reintento real no fue idempotente.';end if;
 raise notice 'REAL_ALPHA_SUPPLIERS source=119 promoted=% pending_exceptions=% canonical=% purchase_orders_created=0 payables_created=0 payments_created=0',v_promoted,v_pending,v_total;
end $validation$;
rollback;`;
const result=spawnSync("docker",["exec","-i","supabase_db_satrapy-validation","psql","-U","postgres","-d","postgres"],{input:sql,encoding:"utf8",maxBuffer:64*1024*1024});
process.stdout.write(result.stdout);process.stderr.write(result.stderr);if(result.status!==0)process.exit(result.status??1);
