-- R-OP · Catálogo contable manual para empresas que inician sin historia.
-- Se usa para pocas cuentas iniciales; catálogos extensos siguen entrando por importación.
begin;

create unique index if not exists audit_accounting_account_request_uidx on public.audit_log(company_id,action,(metadata->>'request_id')) where action='accounting.account_saved' and metadata?'request_id';

create or replace function public.save_accounting_account(
  p_company_id uuid,p_account_id uuid,p_code text,p_name text,p_account_type text,p_normal_balance text,
  p_parent_id uuid,p_level integer,p_accepts_posting boolean,p_is_active boolean,p_reason text,
  p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_account public.accounting_accounts%rowtype;v_previous jsonb;v_replay jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para administrar el catálogo contable.';end if;
  if nullif(trim(p_code),'') is null or length(trim(p_code))>80 or nullif(trim(p_name),'') is null or length(trim(p_name))>240 then raise exception 'Código y nombre de cuenta son obligatorios.';end if;
  if p_account_type not in ('asset','liability','equity','revenue','expense','memorandum') or p_normal_balance not in ('debit','credit') or coalesce(p_level,0) not between 1 and 20 then raise exception 'La clasificación de la cuenta es inválida.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'Motivo y referencia idempotente son obligatorios.';end if;
  if p_parent_id is not null and not exists(select 1 from public.accounting_accounts where id=p_parent_id and company_id=p_company_id) then raise exception 'La cuenta padre no pertenece a esta empresa.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,92));
  select to_jsonb(a) into v_replay from public.audit_log l join public.accounting_accounts a on a.id=l.entity_id where l.company_id=p_company_id and l.action='accounting.account_saved' and l.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  if p_account_id is null then
    insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,parent_id,level,accepts_posting,is_active) values(p_company_id,trim(p_code),trim(p_name),p_account_type,p_normal_balance,p_parent_id,p_level,coalesce(p_accepts_posting,true),coalesce(p_is_active,true)) returning * into v_account;
  else
    select * into v_account from public.accounting_accounts where id=p_account_id and company_id=p_company_id for update;if not found then raise exception 'Cuenta no disponible.';end if;
    if p_expected_updated_at is null or v_account.updated_at<>p_expected_updated_at then raise exception 'La cuenta cambió mientras la editabas.';end if;v_previous:=to_jsonb(v_account);
    update public.accounting_accounts set code=trim(p_code),name=trim(p_name),account_type=p_account_type,normal_balance=p_normal_balance,parent_id=p_parent_id,level=p_level,accepts_posting=coalesce(p_accepts_posting,true),is_active=coalesce(p_is_active,true) where id=p_account_id returning * into v_account;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.account_saved','accounting_account',v_account.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'previous',v_previous,'current',to_jsonb(v_account),'origin','manual'));
  return to_jsonb(v_account)||jsonb_build_object('idempotent',false);
end $$;

create unique index if not exists audit_accounting_manual_bootstrap_request_uidx on public.audit_log(company_id,action,(metadata->>'request_id')) where action='accounting.manual_bootstrap' and metadata?'request_id';

create or replace function public.bootstrap_manual_accounting_config(
  p_company_id uuid,p_base_currency text,p_cutoff_date date,p_catalog_structure jsonb,
  p_tax_treatment jsonb,p_responsibilities jsonb,p_control_accounts jsonb,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config jsonb;v_replay jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para configurar contabilidad.';end if;
  if p_client_request_id is null or nullif(trim(p_reason),'') is null then raise exception 'Motivo y referencia idempotente son obligatorios.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,93));
  select to_jsonb(c) into v_replay from public.audit_log l join public.accounting_config_versions c on c.id=l.entity_id where l.company_id=p_company_id and l.action='accounting.manual_bootstrap' and l.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  if exists(select 1 from public.accounting_config_versions where company_id=p_company_id) then raise exception 'La empresa ya tiene configuración contable; crea una nueva versión.';end if;
  if (select count(*) from jsonb_object_keys(coalesce(p_control_accounts,'{}')))<>9 then raise exception 'Asigna las nueve cuentas de control.';end if;
  v_config:=public.save_accounting_config(p_company_id,p_base_currency,p_cutoff_date,p_catalog_structure,p_tax_treatment,p_responsibilities,p_reason,p_control_accounts);
  v_config:=public.complete_accounting_config((v_config->>'id')::uuid,p_control_accounts,p_reason);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.manual_bootstrap','accounting_config_version',(v_config->>'id')::uuid,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'opening_balance','zero','origin','manual'));
  return v_config||jsonb_build_object('idempotent',false,'opening_balance','zero');
end $$;

grant execute on function public.save_accounting_account(uuid,uuid,text,text,text,text,uuid,integer,boolean,boolean,text,timestamptz,uuid) to authenticated;
grant execute on function public.bootstrap_manual_accounting_config(uuid,text,date,jsonb,jsonb,jsonb,jsonb,text,uuid) to authenticated;
commit;
