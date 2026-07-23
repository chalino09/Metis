-- M4A · staging primero. Los archivos se conservan antes de pedir decisiones;
-- detectar no equivale a aprobar ni a promover datos canónicos.

alter table public.accounting_import_batches alter column cutoff_date drop not null;
alter table public.accounting_import_batches alter column currency_code drop not null;
alter table public.accounting_import_batches drop constraint accounting_import_batches_currency_code_check;
alter table public.accounting_import_batches add constraint accounting_import_batches_currency_code_check check(currency_code is null or currency_code~'^[A-Z]{3}$');
alter table public.accounting_import_batches drop constraint accounting_import_batches_status_check;
alter table public.accounting_import_batches add constraint accounting_import_batches_status_check check(status in ('loading','awaiting_metadata','awaiting_configuration','staged','validation_failed','promoted','failed'));
alter table public.accounting_import_batches
  add column catalog_structure jsonb not null default '{}'::jsonb check(jsonb_typeof(catalog_structure)='object'),
  add column detection_evidence jsonb not null default '{}'::jsonb check(jsonb_typeof(detection_evidence)='object'),
  add column metadata_issues jsonb not null default '[]'::jsonb check(jsonb_typeof(metadata_issues)='array');

create or replace function public.create_accounting_import_staging(
  p_company_id uuid,p_import_type text,p_cutoff_date date,p_currency_code text,p_catalog_structure jsonb,
  p_detection_evidence jsonb,p_metadata_issues jsonb,p_original_name text,p_content_sha256 text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_accounting_opening') then raise exception 'No autorizado para importar apertura.';end if;
  if p_import_type not in ('chart_of_accounts','trial_balance') or lower(p_content_sha256)!~'^[0-9a-f]{64}$' then raise exception 'Archivo contable inválido.';end if;
  select * into v_batch from public.accounting_import_batches where company_id=p_company_id and import_type=p_import_type and content_sha256=lower(p_content_sha256);
  if found then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true);end if;
  insert into public.accounting_import_batches(company_id,import_type,cutoff_date,currency_code,catalog_structure,detection_evidence,metadata_issues,original_name,content_sha256)
  values(p_company_id,p_import_type,p_cutoff_date,case when p_currency_code is null then null else upper(trim(p_currency_code)) end,coalesce(p_catalog_structure,'{}'),coalesce(p_detection_evidence,'{}'),coalesce(p_metadata_issues,'[]'),p_original_name,lower(p_content_sha256)) returning * into v_batch;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.file_detected','accounting_import_batch',v_batch.id,jsonb_build_object('type',p_import_type,'evidence',p_detection_evidence,'issues',p_metadata_issues));
  return to_jsonb(v_batch)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.finalize_accounting_staging(p_batch_id uuid,p_source_system text default 'external')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;v_config public.accounting_config_versions%rowtype;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  if v_batch.status='promoted' then return to_jsonb(v_batch)||jsonb_build_object('idempotent',true);end if;
  if jsonb_array_length(v_batch.metadata_issues)>0 or v_batch.cutoff_date is null or v_batch.currency_code is null then
    update public.accounting_import_batches set status='awaiting_metadata' where id=v_batch.id returning * into v_batch;return to_jsonb(v_batch);
  end if;
  if v_batch.import_type='trial_balance' then
    select * into v_config from public.accounting_config_versions where company_id=v_batch.company_id and status='approved' and cutoff_date=v_batch.cutoff_date and base_currency=v_batch.currency_code;
    if not found then update public.accounting_import_batches set status='awaiting_configuration' where id=v_batch.id returning * into v_batch;return to_jsonb(v_batch);end if;
  end if;
  return public.validate_accounting_import(v_batch.id,p_source_system);
end $$;

create or replace function public.save_detected_accounting_config(
  p_company_id uuid,p_batch_id uuid,p_base_currency text,p_cutoff_date date,p_catalog_structure jsonb,
  p_tax_treatment jsonb,p_responsibilities jsonb,p_correction_reason text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;v_value text;v_reason text;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id and company_id=p_company_id;
  if not found then raise exception 'Selecciona un archivo contable detectado.';end if;
  if (v_batch.cutoff_date is distinct from p_cutoff_date or v_batch.currency_code is distinct from upper(trim(p_base_currency)) or (v_batch.import_type='chart_of_accounts' and v_batch.catalog_structure is distinct from p_catalog_structure)) and nullif(trim(coalesce(p_correction_reason,'')),'') is null then raise exception 'Explica la corrección de los datos detectados.';end if;
  for v_value in select value from jsonb_each_text(p_responsibilities) loop
    if not exists(select 1 from public.user_roles ur where ur.user_id=v_value::uuid and (ur.company_id=p_company_id or ur.company_id is null)) then raise exception 'Selecciona responsables con acceso vigente a la empresa.';end if;
  end loop;
  v_reason:=coalesce(nullif(trim(p_correction_reason),''),'Base detectada automáticamente desde '||v_batch.original_name);
  update public.accounting_import_batches set cutoff_date=p_cutoff_date,currency_code=upper(trim(p_base_currency)),catalog_structure=coalesce(p_catalog_structure,catalog_structure),metadata_issues='[]',detection_evidence=detection_evidence||jsonb_build_object('confirmed_by',auth.uid(),'confirmed_at',now(),'correction_reason',p_correction_reason) where id=v_batch.id;
  return public.save_accounting_config(p_company_id,p_base_currency,p_cutoff_date,p_catalog_structure,p_tax_treatment,p_responsibilities,v_reason,'{}');
end $$;

create or replace function public.list_accounting_responsibles(p_company_id uuid)
returns jsonb language sql security definer set search_path=public stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',x.user_id,'name',coalesce(nullif(trim(p.full_name),''),'Usuario '||left(x.user_id::text,8))) order by coalesce(p.full_name,x.user_id::text)),'[]'::jsonb)
  from (select distinct ur.user_id from public.user_roles ur where ur.company_id=p_company_id or ur.company_id is null) x left join public.profiles p on p.id=x.user_id
  where auth.uid() is not null and public.has_company_permission(p_company_id,'configure_accounting')
$$;

drop function public.complete_accounting_config(uuid,jsonb);
create function public.complete_accounting_config(p_config_id uuid,p_control_accounts jsonb,p_approval_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;v_key text;v_account uuid;
begin
  select * into v_config from public.accounting_config_versions where id=p_config_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_config.company_id,'configure_accounting') then raise exception 'Configuración no disponible.';end if;
  if v_config.status<>'draft' then return to_jsonb(v_config)||jsonb_build_object('idempotent',true);end if;
  if nullif(trim(coalesce(p_approval_reason,'')),'') is null then raise exception 'El motivo de aprobación es obligatorio.';end if;
  delete from public.accounting_control_accounts where config_version_id=v_config.id;
  for v_key,v_account in select key,value::text::uuid from jsonb_each_text(coalesce(p_control_accounts,'{}')) loop insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) values(v_config.id,v_config.company_id,v_key,v_account);end loop;
  if not public.accounting_config_is_complete(v_config.id) then raise exception 'Asigna las nueve cuentas de control antes de aprobar.';end if;
  update public.accounting_config_versions set change_reason=trim(p_approval_reason) where id=v_config.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_config.company_id,auth.uid(),'accounting.control_accounts_completed','accounting_config_version',v_config.id,jsonb_build_object('control_accounts',p_control_accounts,'approval_reason',trim(p_approval_reason)));
  return public.approve_accounting_config(v_config.id);
end $$;

create or replace function public.create_accounting_period(p_company_id uuid,p_code text,p_starts_on date,p_ends_on date)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_period public.accounting_periods%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado.';end if;
  if not exists(select 1 from public.accounting_config_versions where company_id=p_company_id and status='approved') or not exists(select 1 from public.accounting_accounts where company_id=p_company_id) then raise exception 'Aprueba la configuración y el catálogo antes de crear periodos.';end if;
  insert into public.accounting_periods(company_id,period_code,starts_on,ends_on) values(p_company_id,trim(p_code),p_starts_on,p_ends_on) returning * into v_period;return to_jsonb(v_period);
end $$;

alter function public.promote_accounting_import(uuid,uuid) rename to promote_accounting_import_unchecked;
revoke all on function public.promote_accounting_import_unchecked(uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_accounting_import_batch(uuid,text,date,text,text,text) from public,anon,authenticated;
create function public.promote_accounting_import(p_batch_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.accounting_import_batches%rowtype;
begin
  select * into v_batch from public.accounting_import_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_accounting_opening') then raise exception 'Lote no disponible.';end if;
  if v_batch.import_type='chart_of_accounts' and not exists(select 1 from public.accounting_config_versions where company_id=v_batch.company_id and status in ('draft','approved') and cutoff_date=v_batch.cutoff_date and base_currency=v_batch.currency_code) then raise exception 'Confirma primero la detección automática de fecha y moneda.';end if;
  return public.promote_accounting_import_unchecked(p_batch_id,p_client_request_id);
end $$;

revoke all on function public.create_accounting_import_staging(uuid,text,date,text,jsonb,jsonb,jsonb,text,text),public.finalize_accounting_staging(uuid,text),public.save_detected_accounting_config(uuid,uuid,text,date,jsonb,jsonb,jsonb,text),public.list_accounting_responsibles(uuid),public.complete_accounting_config(uuid,jsonb,text),public.promote_accounting_import(uuid,uuid) from public,anon;
grant execute on function public.create_accounting_import_staging(uuid,text,date,text,jsonb,jsonb,jsonb,text,text),public.finalize_accounting_staging(uuid,text),public.save_detected_accounting_config(uuid,uuid,text,date,jsonb,jsonb,jsonb,text),public.list_accounting_responsibles(uuid),public.complete_accounting_config(uuid,jsonb,text),public.promote_accounting_import(uuid,uuid) to authenticated;
