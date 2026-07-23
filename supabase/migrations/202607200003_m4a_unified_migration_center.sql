-- M4A remediation: one global migration intake. Accounting configuration is
-- completed in its own module after the chart is promoted; no second uploader.

create or replace function public.complete_accounting_config(p_config_id uuid,p_control_accounts jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;v_key text;v_account uuid;
begin
  select * into v_config from public.accounting_config_versions where id=p_config_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_config.company_id,'configure_accounting') then raise exception 'Configuración no disponible.';end if;
  if v_config.status<>'draft' then return to_jsonb(v_config)||jsonb_build_object('idempotent',true);end if;
  delete from public.accounting_control_accounts where config_version_id=v_config.id;
  for v_key,v_account in select key,value::text::uuid from jsonb_each_text(coalesce(p_control_accounts,'{}')) loop
    insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) values(v_config.id,v_config.company_id,v_key,v_account);
  end loop;
  if not public.accounting_config_is_complete(v_config.id) then raise exception 'Asigna las nueve cuentas de control antes de aprobar.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_config.company_id,auth.uid(),'accounting.control_accounts_completed','accounting_config_version',v_config.id,jsonb_build_object('control_accounts',p_control_accounts));
  return public.approve_accounting_config(v_config.id);
end $$;

revoke all on function public.complete_accounting_config(uuid,jsonb) from public,anon;
grant execute on function public.complete_accounting_config(uuid,jsonb) to authenticated;
