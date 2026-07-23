-- The historical batch was staged with an obsolete lis_sal parser (15,667 rows).
-- The preserved workbook is immutable and the corrected final-balance parser
-- yields 823 source documents.  For the backfill, the final workbook is the
-- source of truth: a staged row is used only to map its Alpha external code to
-- the promoted canonical customer.  Old row hashes and staged surplus rows are
-- deliberately not treated as receivable source records.

create or replace function public.preview_alpha_repaired_customer_receivable_backfill(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_file_hash text;
  v_result jsonb;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para revisar la incorporación de CxC.';
  end if;
  if v_batch.summary#>>'{customer_identity_repair,status}' <> 'completed' then
    raise exception 'Primero debe concluir la reparación de identidad de clientes.';
  end if;
  if v_batch.summary#>>'{receivable_repair,status}' <> 'completed' then
    raise exception 'Primero debe concluir la conciliación de saldos de lis_sal.';
  end if;
  select file_sha256 into v_file_hash
  from public.alpha_customer_migration_files
  where batch_id=p_batch_id and report_type='ledger'
  limit 1;
  if v_file_hash is null or v_file_hash is distinct from p_ledger_file_sha256 then
    raise exception 'El lis_sal no coincide con el archivo conservado por el lote.';
  end if;

  with payload as materialized (
    select trim(p.customer_external_code) customer_external_code,
      trim(p.source_row_hash) source_row_hash,
      trim(p.folio) folio,
      p.document_date,
      round(p.original_amount,2) original_amount,
      round(p.outstanding_amount,2) outstanding_amount,
      upper(trim(p.currency_code)) currency_code,
      encode(digest(concat_ws('|',trim(p.customer_external_code),coalesce(nullif(trim(p.source_code),''),'F'),trim(p.folio),p.document_date::text,upper(trim(p.currency_code)),(round(p.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) p(
      customer_external_code text,folio text,source_code text,document_date date,
      original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text
    )
  ), duplicate_payload as materialized (
    select source_document_key from payload group by source_document_key having count(*) > 1
  ), staged_match as materialized (
    select p.*,c.status,c.promoted_customer_id,
      exists(
        select 1 from public.alpha_customer_migration_documents d
        where d.batch_id=p_batch_id
          and d.customer_external_code=p.customer_external_code
          and d.source_document_key=p.source_document_key
      ) as has_staging_match
    from payload p
    left join public.alpha_customer_migration_customers c
      on c.batch_id=p_batch_id and c.external_code=p.customer_external_code
  ), eligible as materialized (
    select * from staged_match
    where has_staging_match and status='promoted' and promoted_customer_id is not null
  ), existing as materialized (
    select r.id,r.customer_id,r.source_document_key,r.original_amount
    from public.customer_receivables r
    where r.company_id=v_batch.company_id
      and r.source_kind in ('alpha_document','alpha_opening_balance')
  ), conflicts as materialized (
    select e.id
    from eligible s
    join existing e on e.source_document_key=s.source_document_key
    where e.customer_id is distinct from s.promoted_customer_id
       or e.original_amount is distinct from s.original_amount
  )
  select jsonb_build_object(
    'batch_id',p_batch_id,
    'status','preview',
    'can_apply',not exists(select 1 from duplicate_payload)
      and not exists(select 1 from staged_match where not has_staging_match)
      and not exists(select 1 from conflicts),
    'eligible_documents',coalesce((select count(*) from eligible),0),
    'eligible_total',coalesce((select sum(outstanding_amount) from eligible),0),
    'documents_to_insert',coalesce((select count(*) from eligible s where not exists(select 1 from existing e where e.source_document_key=s.source_document_key)),0),
    'amount_to_insert',coalesce((select sum(s.outstanding_amount) from eligible s where not exists(select 1 from existing e where e.source_document_key=s.source_document_key)),0),
    'already_recorded_documents',coalesce((select count(*) from eligible s where exists(select 1 from existing e where e.source_document_key=s.source_document_key)),0),
    'excluded_unresolved_customer_documents',coalesce((select count(*) from staged_match where has_staging_match and (status <> 'promoted' or promoted_customer_id is null)),0),
    'excluded_unresolved_customer_amount',coalesce((select sum(outstanding_amount) from staged_match where has_staging_match and (status <> 'promoted' or promoted_customer_id is null)),0),
    'duplicate_payload_hashes',coalesce((select count(*) from duplicate_payload),0),
    'staged_documents_missing_from_source',0,
    'source_documents_not_in_staging',coalesce((select count(*) from staged_match where not has_staging_match),0),
    'existing_document_conflicts',coalesce((select count(*) from conflicts),0)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.apply_alpha_repaired_customer_receivable_backfill(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_preview jsonb;
  v_inserted integer;
  v_inserted_total numeric;
  v_total_after numeric;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para incorporar CxC.';
  end if;
  if v_batch.summary#>>'{receivable_backfill,status}'='completed' then
    return jsonb_build_object('status','already_applied','batch_id',p_batch_id,'summary',v_batch.summary->'receivable_backfill');
  end if;
  v_preview:=public.preview_alpha_repaired_customer_receivable_backfill(p_batch_id,p_ledger_file_sha256,p_documents);
  if not coalesce((v_preview->>'can_apply')::boolean,false) then
    raise exception 'La incorporación fue bloqueada: hay una clave, staging o documento existente incompatible.';
  end if;

  with payload as materialized (
    select trim(p.customer_external_code) customer_external_code,
      trim(p.source_row_hash) source_row_hash,
      trim(p.folio) folio,
      p.document_date,
      round(p.original_amount,2) original_amount,
      round(p.outstanding_amount,2) outstanding_amount,
      encode(digest(concat_ws('|',trim(p.customer_external_code),coalesce(nullif(trim(p.source_code),''),'F'),trim(p.folio),p.document_date::text,upper(trim(p.currency_code)),(round(p.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) p(
      customer_external_code text,folio text,source_code text,document_date date,
      original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text
    )
  ), eligible as materialized (
    select p.*,c.promoted_customer_id
    from payload p
    join public.alpha_customer_migration_customers c
      on c.batch_id=p_batch_id and c.external_code=p.customer_external_code
    where c.status='promoted' and c.promoted_customer_id is not null
      and exists(
        select 1 from public.alpha_customer_migration_documents d
        where d.batch_id=p_batch_id
          and d.customer_external_code=p.customer_external_code
          and d.source_document_key=p.source_document_key
      )
  ), inserted as (
    insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
    select v_batch.company_id,e.promoted_customer_id,null,e.document_date,e.document_date,e.original_amount,e.outstanding_amount,
      'alpha_document',e.source_document_key,e.source_row_hash,e.folio,v_batch.cutoff_date
    from eligible e
    where not exists (
      select 1 from public.customer_receivables r
      where r.company_id=v_batch.company_id
        and r.source_kind in ('alpha_document','alpha_opening_balance')
        and r.source_document_key=e.source_document_key
    )
    on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing
    returning outstanding_amount
  ) select count(*),coalesce(sum(outstanding_amount),0) into v_inserted,v_inserted_total from inserted;

  select coalesce(sum(outstanding_amount),0) into v_total_after
  from public.customer_receivables
  where company_id=v_batch.company_id and source_kind='alpha_document';

  update public.alpha_customer_migration_batches
  set summary=summary || jsonb_build_object('receivable_backfill',jsonb_build_object(
    'status','completed','file_sha256',p_ledger_file_sha256,
    'documents_inserted',v_inserted,'amount_inserted',v_inserted_total,
    'total_after',v_total_after,'validation','final_ledger_key_v2',
    'completed_at',now(),'completed_by',auth.uid()
  )) where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.receivables_backfilled','alpha_customer_migration_batches',p_batch_id,jsonb_build_object(
    'file_sha256',p_ledger_file_sha256,'documents_inserted',v_inserted,
    'amount_inserted',v_inserted_total,'total_after',v_total_after,'validation','final_ledger_key_v2'
  ));
  return jsonb_build_object('status','completed','batch_id',p_batch_id,'documents_inserted',v_inserted,'amount_inserted',v_inserted_total,'total_after',v_total_after);
end $$;
