-- Los códigos de ubicación se asignan en el servidor para evitar colisiones y
-- mantener una sola regla para todas las experiencias de producto.
create or replace function public.save_company_location(
  p_company_id uuid,
  p_location_id uuid,
  p_external_code text,
  p_name text,
  p_location_type text,
  p_is_active boolean,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_client_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_location public.locations%rowtype;
  v_previous jsonb;
  v_result jsonb;
  v_blocker text;
  v_external_code text;
  v_code_prefix text;
  v_next_code integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_locations') then
    raise exception 'No autorizado para administrar sucursales.';
  end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>160 then
    raise exception 'El nombre es obligatorio.';
  end if;
  if nullif(trim(p_external_code),'') is not null and length(trim(p_external_code))>40 then
    raise exception 'El código no puede exceder 40 caracteres.';
  end if;
  if p_location_type not in ('sucursal','almacen_central','almacen_operativo','campo') then
    raise exception 'Selecciona un tipo de ubicación válido.';
  end if;
  if nullif(trim(p_reason),'') is null then
    raise exception 'El motivo es obligatorio.';
  end if;
  if p_client_request_id is null then
    raise exception 'Falta la referencia idempotente.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));

  select to_jsonb(l) into v_result
  from public.audit_log a
  join public.locations l on l.id=a.entity_id
  where a.company_id=p_company_id
    and a.action='company.location_saved'
    and a.metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_result is not null then
    return v_result||jsonb_build_object('idempotent',true);
  end if;

  if p_location_id is not null then
    select * into v_location
    from public.locations
    where id=p_location_id and company_id=p_company_id
    for update;
    if not found then
      raise exception 'La sucursal ya no está disponible.';
    end if;
    if p_expected_updated_at is null or v_location.updated_at<>p_expected_updated_at then
      raise exception 'La sucursal cambió mientras la editabas. Actualiza y vuelve a intentarlo.';
    end if;

    v_previous:=to_jsonb(v_location);
    v_external_code:=v_location.external_code;

    if not p_is_active or v_location.location_type<>p_location_type then
      if exists(select 1 from public.inventory_balances where location_id=v_location.id and quantity_on_hand<>0) then
        v_blocker:='Tiene inventario disponible.';
      elsif exists(select 1 from public.cash_sessions where location_id=v_location.id and status in('open','pending_variance_approval')) then
        v_blocker:='Tiene una sesión de caja pendiente.';
      elsif exists(select 1 from public.inventory_counts where location_id=v_location.id and status in('open','review','pending_approval')) then
        v_blocker:='Tiene un conteo físico pendiente.';
      elsif exists(select 1 from public.inventory_transfers where (source_location_id=v_location.id or destination_location_id=v_location.id) and status in('sent','in_transit')) then
        v_blocker:='Tiene transferencias pendientes.';
      end if;
      if v_blocker is not null then
        raise exception 'No se puede cambiar el tipo ni desactivar. %',v_blocker;
      end if;
    end if;

    update public.locations
    set name=trim(p_name),
        location_type=p_location_type,
        is_active=p_is_active,
        classification_source='manual_review'
    where id=v_location.id
    returning * into v_location;
  else
    v_previous:=null;
    v_external_code:=nullif(upper(trim(p_external_code)),'');

    if v_external_code is null then
      v_code_prefix:=case p_location_type
        when 'sucursal' then 'SUC'
        when 'almacen_central' then 'ALM'
        when 'almacen_operativo' then 'ALM'
        when 'campo' then 'CAM'
      end;

      select coalesce(max(substring(upper(external_code) from ('^'||v_code_prefix||'-([0-9]+)$'))::integer),0)+1
      into v_next_code
      from public.locations
      where company_id=p_company_id
        and upper(external_code)~('^'||v_code_prefix||'-[0-9]+$');

      v_external_code:=v_code_prefix||'-'||lpad(v_next_code::text,3,'0');
    end if;

    insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source)
    values(p_company_id,v_external_code,trim(p_name),p_location_type,coalesce(p_is_active,true),'manual_review')
    returning * into v_location;
  end if;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,
    auth.uid(),
    'company.location_saved',
    'location',
    v_location.id,
    jsonb_build_object(
      'request_id',p_client_request_id,
      'reason',trim(p_reason),
      'previous',v_previous,
      'current',to_jsonb(v_location)
    )
  );

  return to_jsonb(v_location)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  if exists(
    select 1 from public.locations
    where company_id=p_company_id
      and upper(external_code)=upper(v_external_code)
      and id is distinct from p_location_id
  ) then
    raise exception 'Ya existe una ubicación con ese código.';
  end if;
  raise;
end $$;

revoke all on function public.save_company_location(uuid,uuid,text,text,text,boolean,text,timestamptz,uuid) from public;
grant execute on function public.save_company_location(uuid,uuid,text,text,text,boolean,text,timestamptz,uuid) to authenticated;
