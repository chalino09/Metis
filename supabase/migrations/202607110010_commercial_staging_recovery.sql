-- A preview with warnings is still usable staging.  Older commercial batches
-- were labelled validation_failed before their zero blocking-error count was
-- refreshed, which obscured otherwise recoverable previews in the UI.

update public.import_batches
set status = 'staged'
where status = 'validation_failed'
  and coalesce(blocking_error_count, 0) = 0
  and closed_at is null
  and staging_purged_at is null;

-- Import screens may be opened by an administrator with the scoped commercial
-- permission rather than the legacy import_data permission.  This function
-- exposes only unfinished batch metadata, and it still receives the caller's
-- JWT and performs an explicit permission check.
create or replace function public.list_import_staging_batches(p_company_id uuid)
returns table (
  id uuid,
  import_type text,
  status text,
  source text,
  file_sha256 text,
  snapshot_date date,
  records_received integer,
  valid_rows integer,
  warning_rows integer,
  error_rows integer,
  blocking_error_count integer,
  pending_warning_count integer,
  staging_purged_at timestamptz,
  original_name text,
  file_type text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id, 'import_data')
    or public.has_company_permission(p_company_id, 'import_prices')
    or public.has_company_permission(p_company_id, 'import_costs')
  ) then
    raise exception 'No autorizado para consultar staging.';
  end if;

  return query
  select
    batch.id,
    batch.import_type,
    batch.status,
    batch.source,
    batch.file_sha256,
    batch.snapshot_date,
    batch.records_received,
    batch.valid_rows,
    batch.warning_rows,
    batch.error_rows,
    batch.blocking_error_count,
    batch.pending_warning_count,
    batch.staging_purged_at,
    file_data.original_name,
    file_data.file_type
  from public.import_batches batch
  left join lateral (
    select file_row.original_name, file_row.file_type
    from public.import_files file_row
    where file_row.import_batch_id = batch.id
    order by file_row.created_at asc
    limit 1
  ) file_data on true
  where batch.company_id = p_company_id
    and batch.status in ('staged', 'validation_failed', 'failed')
  order by batch.started_at desc
  limit 20;
end;
$$;

revoke all on function public.list_import_staging_batches(uuid) from public;
grant execute on function public.list_import_staging_batches(uuid) to authenticated;

-- A rejected "no price in any list" row preserves its raw Alpha data for
-- audit, but is not a commercial price/cost row.  It must not create a fake
-- currency or price-list requirement, nor block confirmation once its warning
-- was explicitly acknowledged.
create or replace function public.get_commercial_import_requirements(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype;
begin
 select * into v_batch from public.import_batches where id=p_import_batch_id;
 if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,v_batch.import_type) then raise exception 'No autorizado.'; end if;
 return jsonb_build_object(
  'currencies',coalesce((select jsonb_agg(x) from (
    select normalized_data->>'currencyLabel' source_label,normalized_data->>'currencyCode' currency_code,count(*) rows
    from public.import_staging_rows
    where import_batch_id=p_import_batch_id and detected_type in ('prices','costs')
      and coalesce((normalized_data->>'rejected')::boolean,false)=false
      and nullif(normalized_data->>'currencyLabel','') is not null
    group by 1,2 order by 1)x),'[]'),
  'price_lists',coalesce((select jsonb_agg(x) from (
    select normalized_data->>'listExternalCode' external_code,normalized_data->>'semanticCode' semantic_code,
      coalesce((normalized_data->>'isDefault')::boolean,false) is_default,count(*) rows
    from public.import_staging_rows
    where import_batch_id=p_import_batch_id and detected_type='prices'
      and coalesce((normalized_data->>'rejected')::boolean,false)=false
      and nullif(normalized_data->>'listExternalCode','') is not null
    group by 1,2,3 order by 1)x),'[]')
 );
end $$;

-- Preserve the existing atomic importer, but exclude rejected audit-only rows
-- consistently from required metadata checks and price-list creation.
create or replace function public.confirm_commercial_import(p_import_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.import_batches%rowtype; v_file text; v_effective timestamptz; v_records integer:=0; v_error text; v_dup uuid;
begin
 select * into v_batch from public.import_batches where id=p_import_batch_id for update;
 if not found or auth.uid() is null or not public.can_import_commercial(v_batch.company_id,v_batch.import_type) then raise exception 'No autorizado.'; end if;
 if v_batch.import_type not in ('prices','costs') then raise exception 'Tipo comercial inválido.'; end if;
 perform public.refresh_import_staging_batch(p_import_batch_id,false); select * into v_batch from public.import_batches where id=p_import_batch_id;
 if v_batch.blocking_error_count>0 or v_batch.pending_warning_count>0 then return jsonb_build_object('status','validation_failed','message','Resuelve errores y reconoce warnings antes de confirmar.'); end if;
 if v_batch.status<>'staged' or v_batch.snapshot_date is null then return jsonb_build_object('status','validation_failed','message','Falta vigencia efectiva.'); end if;
 select id into v_dup from public.import_batches where company_id=v_batch.company_id and import_type=v_batch.import_type and file_sha256=v_batch.file_sha256 and status='completed' and id<>v_batch.id limit 1;
 if v_dup is not null then return jsonb_build_object('status','duplicate','batch_id',v_dup); end if;
 select original_name into v_file from public.import_files where import_batch_id=p_import_batch_id order by created_at limit 1;
 v_effective := v_batch.snapshot_date::timestamptz;
 begin
  if exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and not exists(select 1 from public.products p where p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku')) then raise exception 'Existen SKU sin producto.'; end if;
  if exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and nullif(r.normalized_data->>'currencyCode','') is null) then raise exception 'Existen monedas sin mapear.'; end if;
  if v_batch.import_type='prices' then
    if exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.detected_type='prices' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and nullif(r.normalized_data->>'semanticCode','') is null) then raise exception 'Existen listas sin asignación.'; end if;
    if not exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.detected_type='prices' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and coalesce((r.normalized_data->>'isDefault')::boolean,false)) then raise exception 'Selecciona una lista predeterminada.'; end if;
    update public.price_lists set is_default=false where company_id=v_batch.company_id;
    insert into public.price_lists(company_id,external_code,name,currency_code,is_active,semantic_code,status,source,is_default,reviewed_at,reviewed_by)
    select distinct v_batch.company_id,r.normalized_data->>'listExternalCode',initcap(r.normalized_data->>'semanticCode'),r.normalized_data->>'currencyCode',true,r.normalized_data->>'semanticCode','active','alpha',coalesce((r.normalized_data->>'isDefault')::boolean,false),now(),auth.uid()
    from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and r.detected_type='prices' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false
    on conflict(company_id,external_code) do update set name=excluded.name,currency_code=excluded.currency_code,semantic_code=excluded.semantic_code,status='active',is_active=true,is_default=excluded.is_default,reviewed_at=now(),reviewed_by=auth.uid();
    update public.product_prices pp set valid_to=v_effective where valid_to is null and valid_from<v_effective and exists(select 1 from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' join public.price_lists pl on pl.company_id=v_batch.company_id and pl.external_code=r.normalized_data->>'listExternalCode' where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and pp.product_id=p.id and pp.price_list_id=pl.id);
    if exists(select 1 from public.product_prices pp join public.products p on p.id=pp.product_id join public.price_lists pl on pl.id=pp.price_list_id where p.company_id=v_batch.company_id and pp.valid_to is null and pp.valid_from>=v_effective and exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and r.normalized_data->>'alphaSku'=p.alpha_sku and r.normalized_data->>'listExternalCode'=pl.external_code)) then raise exception 'La vigencia debe ser posterior al precio vigente.'; end if;
    insert into public.product_prices(product_id,price_list_id,amount,currency_code,valid_from,source_file_name,import_batch_id,created_by)
    select p.id,pl.id,(r.normalized_data->>'amount')::numeric,r.normalized_data->>'currencyCode',v_effective,v_file,p_import_batch_id,auth.uid() from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' join public.price_lists pl on pl.company_id=v_batch.company_id and pl.external_code=r.normalized_data->>'listExternalCode' where r.import_batch_id=p_import_batch_id and r.detected_type='prices' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and (r.normalized_data->>'amount')::numeric>=0;
    get diagnostics v_records=row_count;
  else
    update public.product_costs pc set valid_to=v_effective where company_id=v_batch.company_id and cost_type='replacement_cost' and valid_to is null and valid_from<v_effective and exists(select 1 from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and pc.product_id=p.id);
    if exists(select 1 from public.product_costs pc join public.products p on p.id=pc.product_id where pc.company_id=v_batch.company_id and pc.cost_type='replacement_cost' and pc.valid_to is null and pc.valid_from>=v_effective and exists(select 1 from public.import_staging_rows r where r.import_batch_id=p_import_batch_id and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and r.normalized_data->>'alphaSku'=p.alpha_sku)) then raise exception 'La vigencia debe ser posterior al costo vigente.'; end if;
    insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,import_batch_id,created_by)
    select v_batch.company_id,p.id,'replacement_cost',(r.normalized_data->>'replacementCost')::numeric,r.normalized_data->>'currencyCode',v_effective,v_file,p_import_batch_id,auth.uid() from public.import_staging_rows r join public.products p on p.company_id=v_batch.company_id and p.alpha_sku=r.normalized_data->>'alphaSku' where r.import_batch_id=p_import_batch_id and r.detected_type='costs' and coalesce((r.normalized_data->>'rejected')::boolean,false)=false and nullif(r.normalized_data->>'replacementCost','') is not null and (r.normalized_data->>'replacementCost')::numeric>=0;
    get diagnostics v_records=row_count;
  end if;
  update public.import_batches set status='completed',records_imported=v_records,completed_at=now(),closed_at=now(),last_activity_at=now(),notes=null where id=p_import_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),case when v_batch.import_type='prices' then 'price.imported' else 'cost.imported' end,'import_batch',p_import_batch_id,jsonb_build_object('records_imported',v_records,'source_file',v_file,'valid_from',v_effective));
 exception when others then v_error:=sqlerrm; end;
 if v_error is not null then update public.import_batches set status='failed',completed_at=now(),closed_at=now(),notes=v_error where id=p_import_batch_id; insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_batch.company_id,auth.uid(),'import.failed','import_batch',p_import_batch_id,jsonb_build_object('error',v_error)); return jsonb_build_object('status','failed','message',v_error,'batch_id',p_import_batch_id); end if;
 return jsonb_build_object('status','completed','records_imported',v_records,'batch_id',p_import_batch_id);
end $$;
