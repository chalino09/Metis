-- Importación de colaboradores desde Alpha dentro del Centro de Migración.
-- Alpha conserva únicamente su identificador de origen; Satrapy genera el código COL.

alter table public.import_batches drop constraint if exists import_batches_import_type_check;
alter table public.import_batches add constraint import_batches_import_type_check
  check (import_type in ('products','inventory','prices','costs','collaborators','unsupported'));

alter table public.import_staging_rows drop constraint if exists import_staging_rows_detected_type_check;
alter table public.import_staging_rows add constraint import_staging_rows_detected_type_check
  check (detected_type in ('products','inventory','prices','costs','collaborators'));

create or replace function public.stage_alpha_import(
  p_company_id uuid, p_import_type text, p_source text, p_file_name text, p_file_type text,
  p_file_sha256 text, p_snapshot_date date, p_rows jsonb, p_errors jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch_id uuid; v_completed uuid; v_retry uuid; v_received integer; v_batch public.import_batches%rowtype;
begin
  if auth.uid() is null or not public.can_import_commercial(p_company_id,p_import_type) then raise exception 'No autorizado para preparar esta importación.'; end if;
  if p_import_type not in ('products','inventory','prices','costs','collaborators','unsupported') then raise exception 'Tipo no permitido.'; end if;
  if p_source not in ('manual_upload','local_development') then raise exception 'Origen no permitido.'; end if;
  select id into v_completed from public.import_batches where company_id=p_company_id and import_type=p_import_type and file_sha256=p_file_sha256 and status='completed' limit 1;
  if v_completed is not null then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(p_company_id,auth.uid(),'import.duplicate_detected','import_batch',v_completed,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256,'import_type',p_import_type));
    return jsonb_build_object('status','duplicate','batch_id',v_completed,'message','Este archivo ya fue importado correctamente.');
  end if;
  select id into v_retry from public.import_batches where company_id=p_company_id and import_type=p_import_type and file_sha256=p_file_sha256 and status in ('failed','validation_failed','discarded','expired') order by started_at desc limit 1;
  select count(*) into v_received from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb));
  insert into public.import_batches(company_id,import_type,source,file_sha256,status,records_received,imported_by,snapshot_date,retry_of_batch_id,last_activity_at)
  values(p_company_id,p_import_type,p_source,p_file_sha256,'staged',v_received,auth.uid(),p_snapshot_date,v_retry,now()) returning id into v_batch_id;
  insert into public.import_files(import_batch_id,original_name,file_type,file_sha256,row_count) values(v_batch_id,p_file_name,p_file_type,p_file_sha256,v_received);
  insert into public.import_staging_rows(import_batch_id,row_number,source_file,detected_type,raw_data,normalized_data,validation_status)
  select v_batch_id,(item->>'row_number')::int,item->>'source_file',item->>'detected_type',coalesce(item->'raw_data','{}'),coalesce(item->'normalized_data','{}'),item->>'validation_status'
  from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) item;
  insert into public.import_staging_errors(import_batch_id,severity,error_code,message,row_number,alpha_sku,location_code,context_key)
  select v_batch_id,item->>'severity',item->>'error_code',item->>'message',nullif(item->>'row_number','')::int,nullif(item->>'alpha_sku',''),nullif(item->>'location_code',''),nullif(item->>'context_key','')
  from jsonb_array_elements(coalesce(p_errors,'[]'::jsonb)) item;
  update public.import_staging_errors e set staging_row_id=r.id from public.import_staging_rows r
  where e.import_batch_id=v_batch_id and r.import_batch_id=v_batch_id and e.row_number=r.row_number;
  perform public.refresh_import_staging_batch(v_batch_id,false); select * into v_batch from public.import_batches where id=v_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values
    (p_company_id,auth.uid(),'import.file_uploaded','import_batch',v_batch_id,jsonb_build_object('original_name',p_file_name,'file_sha256',p_file_sha256,'import_type',p_import_type)),
    (p_company_id,auth.uid(),'import.preview_generated','import_batch',v_batch_id,jsonb_build_object('records_received',v_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows));
  return jsonb_build_object('status',v_batch.status,'batch_id',v_batch_id,'records_received',v_received,'valid_rows',v_batch.valid_rows,'warning_rows',v_batch.warning_rows,'error_rows',v_batch.error_rows,'blocking_errors',v_batch.blocking_error_count,'pending_warnings',v_batch.pending_warning_count);
end $$;

create or replace function public.confirm_collaborator_import(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch public.import_batches%rowtype;
  v_file_name text;
  v_records integer:=0;
  v_created integer:=0;
  v_error text;
  v_duplicate uuid;
  v_next_code bigint:=0;
  v_default_payment_frequency text;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id for update;
  if not found then raise exception 'Lote de importación no encontrado.'; end if;
  if auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado.'; end if;
  if v_batch.import_type<>'collaborators' then raise exception 'Tipo de importación inválido.'; end if;
  if v_batch.status='completed' then return jsonb_build_object('status','completed','records_imported',v_batch.records_imported,'batch_id',v_batch.id); end if;

  perform public.refresh_import_staging_batch(p_import_batch_id,false);
  select * into v_batch from public.import_batches where id=p_import_batch_id;
  if v_batch.blocking_error_count>0 or v_batch.pending_warning_count>0 then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(v_batch.company_id,auth.uid(),'import.confirmation_blocked','import_batch',p_import_batch_id,jsonb_build_object('blocking_errors',v_batch.blocking_error_count,'pending_warnings',v_batch.pending_warning_count));
    return jsonb_build_object('status','validation_failed','message','Resuelve errores y reconoce alertas antes de confirmar.');
  end if;
  if v_batch.status<>'staged' then return jsonb_build_object('status',v_batch.status,'message','El lote no está listo.'); end if;
  select id into v_duplicate from public.import_batches where company_id=v_batch.company_id and import_type='collaborators' and file_sha256=v_batch.file_sha256 and status='completed' and id<>v_batch.id limit 1;
  if v_duplicate is not null then return jsonb_build_object('status','duplicate','batch_id',v_duplicate); end if;
  select original_name into v_file_name from public.import_files where import_batch_id=p_import_batch_id order by created_at limit 1;

  begin
    select payment_frequency into v_default_payment_frequency from public.payroll_schedules where company_id=v_batch.company_id;
    if coalesce(v_default_payment_frequency,'') not in ('weekly','biweekly','monthly') then raise exception 'Configura la periodicidad de nómina antes de confirmar colaboradores importados.'; end if;
    if exists(
      select 1 from public.import_staging_rows r
      where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
        and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
        and (nullif(trim(r.normalized_data->>'alphaExternalId'),'') is null
          or nullif(trim(r.normalized_data->>'displayName'),'') is null
          or nullif(r.normalized_data->>'hiredAt','') is null
          or nullif(r.normalized_data->>'basePayAmount','') is null)
    ) then raise exception 'El staging de colaboradores contiene datos obligatorios incompletos.'; end if;
    if exists(
      select 1 from public.import_staging_rows r
      where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
        and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
      group by r.normalized_data->>'alphaExternalId' having count(*)>1
    ) then raise exception 'El archivo tiene códigos de origen duplicados.'; end if;

    perform pg_advisory_xact_lock(hashtextextended(v_batch.company_id::text,97));
    select coalesce(max(nullif(regexp_replace(code,'[^0-9]','','g'),'')::bigint),0) into v_next_code
    from public.collaborators where company_id=v_batch.company_id;

    with source as (
      select distinct on (r.normalized_data->>'alphaExternalId')
        r.row_number,
        trim(r.normalized_data->>'alphaExternalId') as alpha_external_id,
        trim(r.normalized_data->>'displayName') as display_name,
        nullif(trim(r.normalized_data->>'jobTitle'),'') as job_title,
        coalesce(nullif(trim(r.normalized_data->>'employmentStatus'),''),'active') as employment_status,
        (r.normalized_data->>'hiredAt')::date as hired_at,
        nullif(r.normalized_data->>'terminatedAt','')::date as terminated_at,
        coalesce(nullif(trim(r.normalized_data->>'paymentFrequency'),''),v_default_payment_frequency) as payment_frequency,
        nullif(trim(r.normalized_data->>'paymentMethod'),'') as payment_method
      from public.import_staging_rows r
      where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
        and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
      order by r.normalized_data->>'alphaExternalId',r.row_number
    ), missing as (
      select source.* from source left join public.collaborators c
        on c.company_id=v_batch.company_id and c.alpha_external_id=source.alpha_external_id
      where c.id is null
    )
    insert into public.collaborators(company_id,code,display_name,job_title,employment_status,hired_at,terminated_at,payment_frequency,alpha_external_id,source,payment_method)
    select v_batch.company_id,
      'COL-'||lpad((v_next_code+row_number() over(order by alpha_external_id))::text,6,'0'),
      display_name,job_title,employment_status,hired_at,
      case when employment_status='inactive' then terminated_at else null end,
      payment_frequency,alpha_external_id,'alpha_import',coalesce(payment_method,'unspecified')
    from missing;
    get diagnostics v_created=row_count;

    with source as (
      select distinct on (r.normalized_data->>'alphaExternalId')
        r.row_number,
        trim(r.normalized_data->>'alphaExternalId') as alpha_external_id,
        trim(r.normalized_data->>'displayName') as display_name,
        nullif(trim(r.normalized_data->>'jobTitle'),'') as job_title,
        coalesce(nullif(trim(r.normalized_data->>'employmentStatus'),''),'active') as employment_status,
        (r.normalized_data->>'hiredAt')::date as hired_at,
        nullif(r.normalized_data->>'terminatedAt','')::date as terminated_at,
        coalesce(nullif(trim(r.normalized_data->>'paymentFrequency'),''),v_default_payment_frequency) as payment_frequency,
        nullif(trim(r.normalized_data->>'paymentMethod'),'') as payment_method
      from public.import_staging_rows r
      where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
        and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
      order by r.normalized_data->>'alphaExternalId',r.row_number
    )
    update public.collaborators c set
      display_name=source.display_name,
      job_title=source.job_title,
      employment_status=source.employment_status,
      hired_at=source.hired_at,
      terminated_at=case when source.employment_status='inactive' then source.terminated_at else null end,
      payment_frequency=source.payment_frequency,
      payment_method=coalesce(source.payment_method,c.payment_method),
      source='alpha_import'
    from source where c.company_id=v_batch.company_id and c.alpha_external_id=source.alpha_external_id;

    with source as (
      select distinct on (r.normalized_data->>'alphaExternalId')
        trim(r.normalized_data->>'alphaExternalId') as alpha_external_id,
        coalesce(nullif(r.normalized_data->>'effectiveFrom','')::date,coalesce(v_batch.snapshot_date,current_date)) as effective_from,
        (r.normalized_data->>'basePayAmount')::numeric as base_pay_amount
      from public.import_staging_rows r
      where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
        and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
      order by r.normalized_data->>'alphaExternalId',r.row_number
    )
    insert into public.collaborator_compensation_history(company_id,collaborator_id,effective_from,base_pay_amount,reason)
    select v_batch.company_id,c.id,source.effective_from,source.base_pay_amount,'Importado desde Alpha'
    from source join public.collaborators c on c.company_id=v_batch.company_id and c.alpha_external_id=source.alpha_external_id
    on conflict(collaborator_id,effective_from) do update set base_pay_amount=excluded.base_pay_amount,reason=excluded.reason;

    select count(*) into v_records from public.import_staging_rows r
    where r.import_batch_id=p_import_batch_id and r.detected_type='collaborators'
      and coalesce((r.normalized_data->>'rejected')::boolean,false)=false;
    if v_records=0 then raise exception 'El staging no contiene colaboradores válidos.'; end if;

    update public.import_batches set status='completed',records_imported=v_records,completed_at=now(),closed_at=now(),last_activity_at=now(),notes=null where id=p_import_batch_id;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(v_batch.company_id,auth.uid(),'import.completed','import_batch',p_import_batch_id,jsonb_build_object('import_type','collaborators','records_imported',v_records,'created',v_created,'updated',v_records-v_created,'original_name',v_file_name,'snapshot_date',v_batch.snapshot_date));
  exception when others then
    v_error:=sqlerrm;
  end;

  if v_error is not null then
    update public.import_batches set status='failed',completed_at=now(),closed_at=now(),last_activity_at=now(),notes=v_error where id=p_import_batch_id;
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(v_batch.company_id,auth.uid(),'import.failed','import_batch',p_import_batch_id,jsonb_build_object('import_type','collaborators','original_name',v_file_name,'error',v_error));
    return jsonb_build_object('status','failed','message',v_error,'batch_id',p_import_batch_id);
  end if;
  return jsonb_build_object('status','completed','records_imported',v_records,'batch_id',p_import_batch_id);
end $$;

revoke all on function public.stage_alpha_import(uuid,text,text,text,text,text,date,jsonb,jsonb) from public;
revoke all on function public.confirm_collaborator_import(uuid) from public;
grant execute on function public.stage_alpha_import(uuid,text,text,text,text,text,date,jsonb,jsonb),public.confirm_collaborator_import(uuid) to authenticated;
