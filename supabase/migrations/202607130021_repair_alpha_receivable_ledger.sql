-- Repair the proven lis_sal interpretation defect. The source workbook is
-- re-parsed outside PostgreSQL, but every row is matched back to the staged,
-- hashed ledger before any balance is changed.

create or replace function public.get_alpha_receivable_repair_source(p_batch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_file public.alpha_customer_migration_files%rowtype;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para revisar esta migración.';
  end if;
  if v_batch.status not in ('completed','completed_with_discrepancies') then raise exception 'La reparación solo aplica a una migración terminada.'; end if;
  select * into v_file from public.alpha_customer_migration_files where batch_id=p_batch_id and report_type='ledger' limit 1;
  if not found then raise exception 'La migración no conserva un archivo lis_sal.'; end if;
  return jsonb_build_object('batch_id',v_batch.id,'company_id',v_batch.company_id,'cutoff_date',v_batch.cutoff_date,'original_name',v_file.original_name,'file_sha256',v_file.file_sha256,'repair',v_batch.summary->'receivable_repair');
end $$;

create or replace function public.preview_alpha_receivable_ledger_repair(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_file_hash text; v_result jsonb;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para revisar esta migración.'; end if;
  select file_sha256 into v_file_hash from public.alpha_customer_migration_files where batch_id=p_batch_id and report_type='ledger' limit 1;
  if v_file_hash is null or v_file_hash is distinct from p_ledger_file_sha256 then raise exception 'El archivo lis_sal no coincide con el que originó la migración.'; end if;

  with payload as materialized (
    select trim(d.customer_external_code) customer_code,trim(d.folio) folio,coalesce(nullif(trim(d.source_code),''),'F') source_code,d.document_date,round(d.original_amount,2) original_amount,round(d.outstanding_amount,2) outstanding_amount,trim(d.source_row_hash) source_row_hash,upper(trim(d.currency_code)) currency_code,
      encode(digest(concat_ws('|',trim(d.customer_external_code),coalesce(nullif(trim(d.source_code),''),'F'),trim(d.folio),d.document_date::text,upper(trim(d.currency_code)),(round(d.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) d(customer_external_code text,folio text,source_code text,document_date date,original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text)
  ), duplicate_payload as (
    select source_document_key from payload group by source_document_key having count(*)>1
  ), staged_keys as materialized (
    select d.source_document_key from public.alpha_customer_migration_documents d where d.batch_id=p_batch_id
  ), existing as materialized (
    select r.*,coalesce((select sum(a.amount) from public.receivable_payment_applications a where a.receivable_id=r.id),0) applied_amount
    from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_kind='alpha_document' and exists(select 1 from staged_keys s where s.source_document_key=r.source_document_key)
  ), target as materialized (
    select p.*,c.id customer_id,coalesce(e.applied_amount,0) applied_amount,e.id receivable_id,e.outstanding_amount current_outstanding
    from payload p left join public.customers c on c.company_id=v_batch.company_id and c.alpha_external_code=p.customer_code
    left join existing e on e.source_document_key=p.source_document_key
  ), risky_payments as (
    select e.id,e.applied_amount from existing e left join target t on t.receivable_id=e.id
    where e.applied_amount>0 and (t.receivable_id is null or t.outstanding_amount<e.applied_amount)
  )
  select jsonb_build_object(
    'can_apply',not exists(select 1 from duplicate_payload) and not exists(select 1 from target where customer_id is null or not exists(select 1 from staged_keys s where s.source_document_key=target.source_document_key)) and not exists(select 1 from risky_payments),
    'current_total',coalesce((select sum(outstanding_amount) from existing),0),
    'source_total',coalesce((select sum(outstanding_amount) from target),0),
    'expected_total_after_recorded_payments',coalesce((select sum(greatest(outstanding_amount-applied_amount,0)) from target),0),
    'current_documents',coalesce((select count(*) from existing where outstanding_amount>0),0),
    'source_documents',coalesce((select count(*) from target where outstanding_amount>0),0),
    'documents_to_close',coalesce((select count(*) from existing e where e.outstanding_amount>0 and not exists(select 1 from target t where t.receivable_id=e.id)),0),
    'documents_to_insert',coalesce((select count(*) from target where receivable_id is null),0),
    'documents_to_update',coalesce((select count(*) from target where receivable_id is not null and current_outstanding is distinct from greatest(outstanding_amount-applied_amount,0)),0),
    'duplicate_payload_keys',coalesce((select count(*) from duplicate_payload),0),
    'unmatched_source_documents',coalesce((select count(*) from target where customer_id is null or not exists(select 1 from staged_keys s where s.source_document_key=target.source_document_key)),0),
    'payments_at_risk',coalesce((select count(*) from risky_payments),0),
    'payments_at_risk_amount',coalesce((select sum(applied_amount) from risky_payments),0)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.apply_alpha_receivable_ledger_repair(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_preview jsonb; v_before numeric; v_after numeric; v_closed integer; v_updated integer; v_inserted integer;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para reparar esta migración.'; end if;
  if v_batch.summary#>>'{receivable_repair,file_sha256}'=p_ledger_file_sha256 then
    return jsonb_build_object('status','already_applied','batch_id',p_batch_id,'summary',v_batch.summary->'receivable_repair');
  end if;
  v_preview:=public.preview_alpha_receivable_ledger_repair(p_batch_id,p_ledger_file_sha256,p_documents);
  if not coalesce((v_preview->>'can_apply')::boolean,false) then raise exception 'La reparación fue bloqueada por documentos no conciliados o pagos que requieren revisión.'; end if;
  v_before:=(v_preview->>'current_total')::numeric;

  with payload as materialized (
    select trim(d.customer_external_code) customer_code,trim(d.folio) folio,coalesce(nullif(trim(d.source_code),''),'F') source_code,d.document_date,round(d.original_amount,2) original_amount,round(d.outstanding_amount,2) outstanding_amount,trim(d.source_row_hash) source_row_hash,upper(trim(d.currency_code)) currency_code,
      encode(digest(concat_ws('|',trim(d.customer_external_code),coalesce(nullif(trim(d.source_code),''),'F'),trim(d.folio),d.document_date::text,upper(trim(d.currency_code)),(round(d.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) d(customer_external_code text,folio text,source_code text,document_date date,original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text)
  ), staged_keys as materialized (select source_document_key from public.alpha_customer_migration_documents where batch_id=p_batch_id), changed as (
    update public.customer_receivables r set outstanding_amount=0
    where r.company_id=v_batch.company_id and r.source_kind='alpha_document' and r.outstanding_amount>0 and exists(select 1 from staged_keys s where s.source_document_key=r.source_document_key) and not exists(select 1 from payload p where p.source_document_key=r.source_document_key)
    returning 1
  ) select count(*) into v_closed from changed;

  with payload as materialized (
    select round(d.outstanding_amount,2) outstanding_amount,
      encode(digest(concat_ws('|',trim(d.customer_external_code),coalesce(nullif(trim(d.source_code),''),'F'),trim(d.folio),d.document_date::text,upper(trim(d.currency_code)),(round(d.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) d(customer_external_code text,folio text,source_code text,document_date date,original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text)
  ), changed as (
    update public.customer_receivables r set outstanding_amount=greatest(p.outstanding_amount-coalesce((select sum(a.amount) from public.receivable_payment_applications a where a.receivable_id=r.id),0),0)
    from payload p where r.company_id=v_batch.company_id and r.source_kind='alpha_document' and r.source_document_key=p.source_document_key and r.outstanding_amount is distinct from greatest(p.outstanding_amount-coalesce((select sum(a.amount) from public.receivable_payment_applications a where a.receivable_id=r.id),0),0)
    returning 1
  ) select count(*) into v_updated from changed;

  with payload as materialized (
    select trim(d.customer_external_code) customer_code,trim(d.folio) folio,coalesce(nullif(trim(d.source_code),''),'F') source_code,d.document_date,round(d.original_amount,2) original_amount,round(d.outstanding_amount,2) outstanding_amount,trim(d.source_row_hash) source_row_hash,upper(trim(d.currency_code)) currency_code,
      encode(digest(concat_ws('|',trim(d.customer_external_code),coalesce(nullif(trim(d.source_code),''),'F'),trim(d.folio),d.document_date::text,upper(trim(d.currency_code)),(round(d.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) d(customer_external_code text,folio text,source_code text,document_date date,original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text)
  ), inserted as (
    insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
    select v_batch.company_id,c.id,null,p.document_date,p.document_date,p.original_amount,p.outstanding_amount,'alpha_document',p.source_document_key,p.source_row_hash,p.folio,v_batch.cutoff_date
    from payload p join public.customers c on c.company_id=v_batch.company_id and c.alpha_external_code=p.customer_code
    where not exists(select 1 from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_kind in ('alpha_document','alpha_opening_balance') and r.source_document_key=p.source_document_key)
    returning 1
  ) select count(*) into v_inserted from inserted;

  select coalesce(sum(r.outstanding_amount),0) into v_after from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_kind='alpha_document' and r.outstanding_amount>0;
  update public.alpha_customer_migration_batches set summary=summary||jsonb_build_object('receivable_repair',jsonb_build_object('status','completed','file_sha256',p_ledger_file_sha256,'parser','lis_sal_final_balance_v1','previous_total',v_before,'corrected_total',v_after,'documents_closed',v_closed,'documents_updated',v_updated,'documents_inserted',v_inserted,'completed_at',now(),'completed_by',auth.uid())) where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.receivables_repaired','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('file_sha256',p_ledger_file_sha256,'previous_total',v_before,'corrected_total',v_after,'documents_closed',v_closed,'documents_updated',v_updated,'documents_inserted',v_inserted,'parser','lis_sal_final_balance_v1'));
  return jsonb_build_object('status','completed','batch_id',p_batch_id,'previous_total',v_before,'corrected_total',v_after,'documents_closed',v_closed,'documents_updated',v_updated,'documents_inserted',v_inserted);
end $$;

revoke all on function public.get_alpha_receivable_repair_source(uuid),public.preview_alpha_receivable_ledger_repair(uuid,text,jsonb),public.apply_alpha_receivable_ledger_repair(uuid,text,jsonb) from public;
grant execute on function public.get_alpha_receivable_repair_source(uuid),public.preview_alpha_receivable_ledger_repair(uuid,text,jsonb),public.apply_alpha_receivable_ledger_repair(uuid,text,jsonb) to authenticated;
