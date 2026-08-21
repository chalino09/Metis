-- El destino puede corregirse antes de cotizar; las cotizaciones posteriores no pueden reinterpretar la necesidad.
create or replace function public.change_procurement_requisition_destination(
  p_company_id uuid,
  p_requisition_id uuid,
  p_location_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_previous_location_id uuid;
  v_line_count integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'create_procurement_requisitions') then raise exception 'No autorizado para cambiar el destino.'; end if;

  select requisition.location_id
  into v_previous_location_id
  from public.procurement_requisitions requisition
  where requisition.id=p_requisition_id
    and requisition.company_id=p_company_id
    and requisition.status in ('draft','quoting')
  for update;
  if not found then raise exception 'La solicitud ya no permite cambiar destino.'; end if;

  if exists(select 1 from public.procurement_quotes quote where quote.requisition_id=p_requisition_id) then
    raise exception 'La solicitud ya tiene cotizaciones; no puede cambiar destino.';
  end if;
  if not exists(select 1 from public.locations location where location.id=p_location_id and location.company_id=p_company_id and location.is_active and public.can_access_location(location.id)) then
    raise exception 'Ubicación destino no disponible.';
  end if;

  update public.procurement_requisitions
  set location_id=p_location_id,updated_at=now()
  where id=p_requisition_id;

  update public.procurement_requisition_lines requisition_line
  set available_quantity_snapshot=coalesce((
    select balance.quantity_on_hand
    from public.inventory_balances balance
    where balance.company_id=p_company_id
      and balance.location_id=p_location_id
      and balance.product_id=requisition_line.product_id
  ),0)
  where requisition_line.requisition_id=p_requisition_id;
  get diagnostics v_line_count = row_count;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),'procurement.requisition_destination_changed','procurement_requisition',p_requisition_id,
    jsonb_build_object('from_location_id',v_previous_location_id,'to_location_id',p_location_id,'line_count',v_line_count)
  );
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

revoke all on function public.change_procurement_requisition_destination(uuid,uuid,uuid) from public,anon;
grant execute on function public.change_procurement_requisition_destination(uuid,uuid,uuid) to authenticated;
