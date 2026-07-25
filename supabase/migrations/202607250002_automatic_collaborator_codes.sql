-- Colaboradores: el código pertenece a Satrapy y se genera en servidor.
-- Las altas nacen activas y sin fecha de baja.

create or replace function public.save_collaborator(
  p_company_id uuid,p_collaborator_id uuid,p_code text,p_display_name text,p_job_title text,p_employment_status text,p_hired_at date,p_terminated_at date,p_payment_frequency text,p_base_pay_amount numeric,p_effective_from date,p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_collaborator public.collaborators%rowtype;
  v_frequency text:=lower(trim(coalesce(p_payment_frequency,'')));
  v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collaborators') then
    raise exception 'No autorizado para administrar colaboradores.';
  end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or p_hired_at is null then
    raise exception 'Nombre y fecha de ingreso son obligatorios.';
  end if;
  if v_frequency not in ('weekly','biweekly','monthly') then
    raise exception 'Periodicidad de pago inválida.';
  end if;
  if lower(trim(coalesce(p_employment_status,''))) not in ('active','inactive') then
    raise exception 'Estado de colaborador inválido.';
  end if;
  if p_base_pay_amount is null or p_base_pay_amount<0 or p_effective_from is null then
    raise exception 'Captura el pago base y su vigencia.';
  end if;

  if p_collaborator_id is null then
    perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,97));
    select 'COL-'||lpad((coalesce(max(nullif(regexp_replace(code,'[^0-9]','','g'),'')::bigint),0)+1)::text,6,'0')
      into v_code
    from public.collaborators
    where company_id=p_company_id;

    insert into public.collaborators(
      company_id,code,display_name,job_title,employment_status,hired_at,terminated_at,payment_frequency
    ) values(
      p_company_id,v_code,trim(p_display_name),nullif(trim(p_job_title),''),'active',p_hired_at,null,v_frequency
    ) returning * into v_collaborator;
  else
    if lower(trim(p_employment_status))='inactive' and p_terminated_at is null then
      raise exception 'La fecha de baja es obligatoria al desactivar un colaborador.';
    end if;

    update public.collaborators set
      display_name=trim(p_display_name),
      job_title=nullif(trim(p_job_title),''),
      employment_status=lower(trim(p_employment_status)),
      hired_at=p_hired_at,
      terminated_at=case when lower(trim(p_employment_status))='inactive' then p_terminated_at end,
      payment_frequency=v_frequency
    where id=p_collaborator_id and company_id=p_company_id
    returning * into v_collaborator;

    if not found then
      raise exception 'Colaborador no disponible.';
    end if;
  end if;

  insert into public.collaborator_compensation_history(
    company_id,collaborator_id,effective_from,base_pay_amount,reason
  ) values(
    p_company_id,v_collaborator.id,p_effective_from,p_base_pay_amount,nullif(trim(p_reason),'')
  )
  on conflict(collaborator_id,effective_from) do update set
    base_pay_amount=excluded.base_pay_amount,
    reason=excluded.reason;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(
    p_company_id,auth.uid(),
    case when p_collaborator_id is null then 'collaborator.created' else 'collaborator.updated' end,
    'collaborator',v_collaborator.id,
    jsonb_build_object('code',v_collaborator.code,'payment_frequency',v_frequency,'effective_from',p_effective_from)
  );

  return public.get_collaborator_profile(p_company_id,v_collaborator.id);
end $$;

revoke all on function public.save_collaborator(uuid,uuid,text,text,text,text,date,date,text,numeric,date,text) from public,anon;
grant execute on function public.save_collaborator(uuid,uuid,text,text,text,text,date,date,text,numeric,date,text) to authenticated;
