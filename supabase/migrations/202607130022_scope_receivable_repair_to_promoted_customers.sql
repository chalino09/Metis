-- A completed batch may contain blocked customers. Only documents belonging to
-- customers actually promoted by that batch are eligible for the repair.

create or replace function public.preview_promoted_alpha_receivable_ledger_repair(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_filtered jsonb; v_excluded integer; v_result jsonb;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para revisar esta migración.'; end if;
  select coalesce(jsonb_agg(d.value),'[]'::jsonb),count(*) filter(where c.id is null)
    into v_filtered,v_excluded
  from jsonb_array_elements(coalesce(p_documents,'[]'::jsonb)) d(value)
  left join public.alpha_customer_migration_customers c on c.batch_id=p_batch_id and c.external_code=trim(d.value->>'customer_external_code') and c.status='promoted';
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_filtered
  from jsonb_array_elements(coalesce(p_documents,'[]'::jsonb)) d(value)
  where exists(select 1 from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and c.external_code=trim(d.value->>'customer_external_code') and c.status='promoted');
  v_result:=public.preview_alpha_receivable_ledger_repair(p_batch_id,p_ledger_file_sha256,v_filtered);
  return v_result||jsonb_build_object('excluded_blocked_customer_documents',coalesce(v_excluded,0));
end $$;

create or replace function public.apply_promoted_alpha_receivable_ledger_repair(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_batch public.alpha_customer_migration_batches%rowtype; v_filtered jsonb;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para reparar esta migración.'; end if;
  select coalesce(jsonb_agg(value),'[]'::jsonb) into v_filtered
  from jsonb_array_elements(coalesce(p_documents,'[]'::jsonb)) d(value)
  where exists(select 1 from public.alpha_customer_migration_customers c where c.batch_id=p_batch_id and c.external_code=trim(d.value->>'customer_external_code') and c.status='promoted');
  return public.apply_alpha_receivable_ledger_repair(p_batch_id,p_ledger_file_sha256,v_filtered);
end $$;

revoke all on function public.preview_promoted_alpha_receivable_ledger_repair(uuid,text,jsonb),public.apply_promoted_alpha_receivable_ledger_repair(uuid,text,jsonb) from public;
grant execute on function public.preview_promoted_alpha_receivable_ledger_repair(uuid,text,jsonb),public.apply_promoted_alpha_receivable_ledger_repair(uuid,text,jsonb) to authenticated;
