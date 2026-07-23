-- Module 3A remediation: cata_prv separates the supplier header and its
-- fiscal/contact detail with a blank row. Repair already promoted suppliers
-- from the existing source evidence without recreating the import batch.

create or replace function public.repair_alpha_supplier_details(
  p_company_id uuid,
  p_cutoff_date date,
  p_suppliers jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch_id uuid;
  v_source_count integer;
  v_matched integer;
  v_tax_updated integer;
  v_raw_rfc integer;
  v_generic_or_invalid integer;
  v_duplicate_rfc integer;
  v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'promote_suppliers') then
    raise exception 'No autorizado para reparar datos de proveedores.';
  end if;
  if jsonb_typeof(coalesce(p_suppliers,'null'::jsonb))<>'array' or jsonb_array_length(p_suppliers)=0 then
    raise exception 'La evidencia de proveedores está vacía.';
  end if;

  select id into v_batch_id
  from public.alpha_purchasing_import_batches
  where company_id=p_company_id and cutoff_date=p_cutoff_date and supplier_promotion_completed_at is not null
  order by completed_at desc nulls last,created_at desc limit 1 for update;
  if not found then raise exception 'No existe una promoción de proveedores para este corte.'; end if;

  create temporary table if not exists pg_temp.supplier_detail_repair(
    external_code text primary key,display_name text not null,counterparty_kind text,supplier_type text,tax_id text,
    address_line text,neighborhood text,municipality text,state_name text,phone text,source_row_hash text not null,
    canonical_tax_id text,tax_occurrences integer
  ) on commit drop;
  truncate pg_temp.supplier_detail_repair;
  insert into pg_temp.supplier_detail_repair(external_code,display_name,counterparty_kind,supplier_type,tax_id,address_line,neighborhood,municipality,state_name,phone,source_row_hash,canonical_tax_id,tax_occurrences)
  select trim(r.external_code),trim(r.display_name),nullif(trim(r.counterparty_kind),''),nullif(trim(r.supplier_type),''),nullif(trim(r.tax_id),''),nullif(trim(r.address_line),''),nullif(trim(r.neighborhood),''),nullif(trim(r.municipality),''),nullif(trim(r.state_name),''),nullif(trim(r.phone),''),trim(r.source_row_hash),
    public.canonical_supplier_tax_id(r.tax_id),
    count(*) over(partition by public.canonical_supplier_tax_id(r.tax_id))
  from jsonb_to_recordset(p_suppliers) r(external_code text,display_name text,counterparty_kind text,supplier_type text,tax_id text,address_line text,neighborhood text,municipality text,state_name text,phone text,source_row_hash text);

  select count(*) into v_source_count from pg_temp.supplier_detail_repair;
  if v_source_count<>jsonb_array_length(p_suppliers) then raise exception 'La evidencia contiene claves de proveedor duplicadas.'; end if;
  select count(*) into v_matched from pg_temp.supplier_detail_repair r join public.alpha_purchasing_import_suppliers s on s.batch_id=v_batch_id and s.external_code=r.external_code;
  if v_matched<>(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_batch_id) or v_matched<>v_source_count then
    raise exception 'La evidencia no coincide exactamente con los proveedores del lote promovido.';
  end if;

  update public.alpha_purchasing_import_suppliers s set
    display_name=r.display_name,counterparty_kind=r.counterparty_kind,supplier_type=r.supplier_type,tax_id=r.tax_id,
    address_line=r.address_line,neighborhood=r.neighborhood,municipality=r.municipality,state_name=r.state_name,phone=r.phone,source_row_hash=r.source_row_hash
  from pg_temp.supplier_detail_repair r where s.batch_id=v_batch_id and s.external_code=r.external_code;

  update public.supplier_external_references er set source_row_hash=r.source_row_hash,
    metadata=er.metadata||jsonb_build_object('source_tax_id',r.tax_id,'counterparty_kind',r.counterparty_kind,'supplier_type',r.supplier_type,'details_repaired_at',now())
  from pg_temp.supplier_detail_repair r
  where er.company_id=p_company_id and er.source_system='alpha' and er.external_code=r.external_code;

  update public.suppliers s set
    tax_id=r.canonical_tax_id,
    supplier_category=coalesce(s.supplier_category,r.supplier_type),
    address_line=coalesce(s.address_line,r.address_line),neighborhood=coalesce(s.neighborhood,r.neighborhood),
    municipality=coalesce(s.municipality,r.municipality),state_name=coalesce(s.state_name,r.state_name),phone=coalesce(s.phone,r.phone),
    updated_by=auth.uid()
  from pg_temp.supplier_detail_repair r
  join public.supplier_external_references er on er.company_id=p_company_id and er.source_system='alpha' and er.external_code=r.external_code
  where s.id=er.supplier_id and s.company_id=p_company_id and r.canonical_tax_id is not null and r.tax_occurrences=1
    and not exists(select 1 from public.suppliers other where other.company_id=p_company_id and other.id<>s.id and other.tax_id=r.canonical_tax_id);
  get diagnostics v_tax_updated=row_count;

  -- Non-fiscal details are safe to repair even when Alpha has no usable RFC.
  update public.suppliers s set
    supplier_category=coalesce(s.supplier_category,r.supplier_type),
    address_line=coalesce(s.address_line,r.address_line),neighborhood=coalesce(s.neighborhood,r.neighborhood),
    municipality=coalesce(s.municipality,r.municipality),state_name=coalesce(s.state_name,r.state_name),phone=coalesce(s.phone,r.phone),updated_by=auth.uid()
  from pg_temp.supplier_detail_repair r
  join public.supplier_external_references er on er.company_id=p_company_id and er.source_system='alpha' and er.external_code=r.external_code
  where s.id=er.supplier_id and s.company_id=p_company_id;

  select count(*) filter(where tax_id is not null),count(*) filter(where tax_id is not null and canonical_tax_id is null),count(*) filter(where canonical_tax_id is not null and tax_occurrences>1)
  into v_raw_rfc,v_generic_or_invalid,v_duplicate_rfc from pg_temp.supplier_detail_repair;
  v_summary:=jsonb_build_object('source_suppliers',v_source_count,'matched_suppliers',v_matched,'canonical_rfc_updated',v_tax_updated,'source_rfc_present',v_raw_rfc,'generic_or_invalid_rfc',v_generic_or_invalid,'duplicate_rfc_rows',v_duplicate_rfc,'repaired_at',now());
  update public.alpha_purchasing_import_batches set supplier_promotion_summary=supplier_promotion_summary||jsonb_build_object('supplier_detail_repair',v_summary) where id=v_batch_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'alpha_suppliers.details_repaired','alpha_purchasing_import_batch',v_batch_id,v_summary);
  return jsonb_build_object('status','completed','batch_id',v_batch_id,'summary',v_summary);
end $$;

revoke all on function public.repair_alpha_supplier_details(uuid,date,jsonb) from public;
grant execute on function public.repair_alpha_supplier_details(uuid,date,jsonb) to authenticated;
