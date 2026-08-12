-- Compatibilidad de contratos canónicos después de perfiles componibles,
-- retroactividad de nómina y cotizaciones comerciales completas.

create or replace function public.sync_company_user_invitation_role()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  delete from public.company_user_invitation_roles where invitation_id=new.id;
  if new.role_id is not null then
    insert into public.company_user_invitation_roles(invitation_id,role_id)
    values(new.id,new.role_id) on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists company_user_invitations_sync_role on public.company_user_invitations;
create trigger company_user_invitations_sync_role
after insert or update of role_id on public.company_user_invitations
for each row execute function public.sync_company_user_invitation_role();

insert into public.company_user_invitation_roles(invitation_id,role_id)
select id,role_id from public.company_user_invitations where role_id is not null
on conflict do nothing;

create or replace function public.guard_product_canonical_code()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.alpha_sku is null and new.internal_sku is not null and exists(
    select 1 from public.products p where p.company_id=new.company_id and p.internal_sku=new.internal_sku and p.id<>new.id
  ) then
    raise exception 'El código canónico ya existe en esta empresa.';
  end if;
  return new;
end $$;

drop trigger if exists products_guard_canonical_code on public.products;
create trigger products_guard_canonical_code
before insert or update of company_id,internal_sku on public.products
for each row execute function public.guard_product_canonical_code();

create or replace function public.save_payroll_movements_batch(p_company_id uuid,p_movements jsonb,p_approve boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb;v_count integer:=0;v_id uuid;v_type text;v_direction text;v_date date;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payroll_movements') then raise exception 'No autorizado para registrar movimientos.'; end if;
  if jsonb_typeof(coalesce(p_movements,'null'::jsonb))<>'array' or jsonb_array_length(p_movements)=0 then raise exception 'Agrega al menos un movimiento.'; end if;
  for v_item in select value from jsonb_array_elements(p_movements) loop
    v_type:=lower(trim(coalesce(v_item->>'movement_type','')));v_direction:=lower(trim(coalesce(v_item->>'direction','')));v_date:=nullif(v_item->>'effective_on','')::date;
    if v_type not in ('overtime','bonus','aguinaldo','vacation_premium','adjustment','absence') or v_direction not in ('addition','reduction','informational') or nullif(v_item->>'collaborator_id','') is null or v_date is null or coalesce((v_item->>'amount')::numeric,-1)<0 then raise exception 'Un movimiento contiene datos inválidos.'; end if;
    if not exists(select 1 from public.collaborators where id=(v_item->>'collaborator_id')::uuid and company_id=p_company_id) then raise exception 'Un colaborador del lote no está disponible.'; end if;
    v_id:=nullif(v_item->>'id','')::uuid;
    if v_id is null then
      insert into public.payroll_movements(company_id,collaborator_id,movement_type,direction,effective_on,occurred_on,units,amount,description,status,approved_by,approved_at)
      values(p_company_id,(v_item->>'collaborator_id')::uuid,v_type,v_direction,v_date,v_date,nullif(v_item->>'units','')::numeric,coalesce((v_item->>'amount')::numeric,0),nullif(trim(v_item->>'description'),''),case when p_approve then 'approved' else 'pending' end,case when p_approve then auth.uid() end,case when p_approve then now() end);
    else
      update public.payroll_movements set movement_type=v_type,direction=v_direction,effective_on=v_date,occurred_on=v_date,units=nullif(v_item->>'units','')::numeric,amount=coalesce((v_item->>'amount')::numeric,0),description=nullif(trim(v_item->>'description'),''),status=case when p_approve then 'approved' else 'pending' end,approved_by=case when p_approve then auth.uid() else null end,approved_at=case when p_approve then now() else null end where id=v_id and company_id=p_company_id;
      if not found then raise exception 'Un movimiento del lote no está disponible.'; end if;
    end if;
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata) values(p_company_id,auth.uid(),'payroll.movements_saved','payroll_movement_batch',jsonb_build_object('count',v_count,'approved',p_approve));
  return jsonb_build_object('saved',v_count);
end $$;

grant execute on function public.save_payroll_movements_batch(uuid,jsonb,boolean) to authenticated;
