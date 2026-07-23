import { spawnSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { parseAlphaWorkbook } from "../app/lib/alpha.ts";

const folder = process.env.ALPHA_ERP_IMPORT_DIR;
if (!folder) throw new Error("ALPHA_ERP_IMPORT_DIR no está configurado.");

const catalogName = (await readdir(folder)).filter((name) => /^cata_prd_.+\.xlsx?$/i.test(name)).sort()[0];
if (!catalogName) throw new Error("No hay un cata_prd real en la carpeta configurada.");

const bytes = await readFile(resolve(folder, catalogName));
const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
const parsed = await parseAlphaWorkbook(buffer, basename(catalogName), "local_development");
const errors = parsed.issues.filter((issue) => issue.severity === "error");
if (!parsed.products.length || errors.length) {
  throw new Error(`El catálogo real no es importable: productos=${parsed.products.length}, errores=${errors.length}.`);
}

const rows = parsed.products.map((product) => ({
  row_number: product.rowNumber,
  source_file: parsed.fileName,
  detected_type: "products",
  raw_data: { cells: product.rawData },
  normalized_data: product,
  validation_status: "valid",
}));
const sqlLiteral = (value: string) => `'${value.replaceAll("'", "''")}'`;

const sql = String.raw`\set ON_ERROR_STOP on
begin;
do $validation$
declare
  v_company uuid := '26000000-0000-4000-8000-000000000001';
  v_batch uuid;
  v_result jsonb;
  v_total integer;
  v_pending integer;
  v_sample uuid;
  v_rows jsonb := $rows$${JSON.stringify(rows)}$rows$::jsonb;
begin
  perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  insert into public.companies(id,legal_name,display_name) values(v_company,'Validación Alpha real','Validación Alpha real');
  insert into public.user_roles(user_id,role_id,company_id)
    select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',id,v_company from public.roles where code='super_admin'
    on conflict do nothing;
  v_result:=public.stage_alpha_import(v_company,'products','local_development',${sqlLiteral(parsed.fileName)},'xls',${sqlLiteral(parsed.fileHash)},null,v_rows,'[]'::jsonb);
  v_batch:=(v_result->>'batch_id')::uuid;
  v_result:=public.confirm_staged_import(v_batch);
  if v_result->>'status'<>'completed' then raise exception 'La promoción real no terminó: %',v_result; end if;
  select count(*),count(*) filter(where tax_category_id is null),min(id::text)::uuid
    into v_total,v_pending,v_sample from public.products where company_id=v_company;
  if v_total<>${parsed.products.length} or v_pending<>v_total then
    raise exception 'Contrato real incorrecto: productos %, pendientes fiscales %',v_total,v_pending;
  end if;
  if not (public.product_pos_readiness_detail(v_company,v_sample)->'blockers' @> '["missing_tax_category"]'::jsonb) then
    raise exception 'El catálogo real sin fuente fiscal no quedó bloqueado por readiness.';
  end if;
  v_result:=public.confirm_staged_import(v_batch);
  if v_result->>'status'<>'completed' then raise exception 'El reintento real no fue idempotente.'; end if;
  raise notice 'REAL_ALPHA file=% rows=% tax_configured=0 readiness_pending=% batch=%',${sqlLiteral(parsed.fileName)},v_total,v_pending,v_batch;
end $validation$;
rollback;
`;

const result = spawnSync("docker", ["exec", "-i", "supabase_db_satrapy-validation", "psql", "-U", "postgres", "-d", "postgres"], {
  input: sql,
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
});
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
if (result.status !== 0) process.exit(result.status ?? 1);
