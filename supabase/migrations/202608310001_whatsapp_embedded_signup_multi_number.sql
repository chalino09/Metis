-- Satrapy · Embedded Signup y múltiples números de WhatsApp por sucursal.
-- Una conexión representa un número; la cuenta WABA puede repetirse entre números.

begin;

alter table public.integration_connections
  drop constraint if exists integration_connections_company_id_provider_code_key;

create unique index if not exists integration_connections_single_xai_idx
  on public.integration_connections(company_id,provider_code)
  where provider_code='xai';

create unique index if not exists integration_connections_whatsapp_phone_idx
  on public.integration_connections(company_id,(configuration->>'phone_number_id'))
  where provider_code='meta_whatsapp' and nullif(configuration->>'phone_number_id','') is not null;

create index if not exists integration_connections_whatsapp_waba_idx
  on public.integration_connections(company_id,(configuration->>'waba_id'))
  where provider_code='meta_whatsapp';

create or replace function public.complete_whatsapp_connection(
  p_company_id uuid,
  p_actor_id uuid,
  p_display_name text,
  p_location_id uuid,
  p_waba_id text,
  p_phone_number_id text,
  p_phone_number text,
  p_onboarding_mode text,
  p_secret_ciphertext text
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid;
  v_name text:=trim(p_display_name);
  v_waba text:=trim(p_waba_id);
  v_phone_id text:=trim(p_phone_number_id);
  v_phone text:=nullif(trim(coalesce(p_phone_number,'')),'');
  v_mode text:=trim(p_onboarding_mode);
begin
  if auth.role()<>'service_role' or p_actor_id is null then raise exception 'Operacion reservada al servidor.'; end if;
  if v_name='' or v_waba!~'^[0-9]+$' or v_phone_id!~'^[0-9]+$'
    or v_mode not in('cloud','coexistence') or nullif(trim(p_secret_ciphertext),'') is null then
    raise exception 'Conexion de WhatsApp incompleta.';
  end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id) then
    raise exception 'La sucursal no pertenece a la empresa.';
  end if;

  insert into public.integration_connections(
    company_id,provider_code,display_name,auth_mode,status,configuration,secret_ciphertext,
    external_account_id,created_by,updated_by
  ) values(
    p_company_id,'meta_whatsapp',v_name,'oauth2','configured',
    jsonb_build_object(
      'waba_id',v_waba,'phone_number_id',v_phone_id,'phone_number',v_phone,
      'location_id',p_location_id,'onboarding_mode',v_mode,'embedded_signup',true
    ),trim(p_secret_ciphertext),v_phone_id,p_actor_id,p_actor_id
  )
  on conflict(company_id,(configuration->>'phone_number_id'))
    where provider_code='meta_whatsapp' and nullif(configuration->>'phone_number_id','') is not null
  do update set
    display_name=excluded.display_name,auth_mode='oauth2',status='configured',
    configuration=excluded.configuration,secret_ciphertext=excluded.secret_ciphertext,
    secret_version=integration_connections.secret_version+1,external_account_id=excluded.external_account_id,
    last_error_code=null,last_error_message=null,next_retry_at=null,updated_by=p_actor_id
  returning id into v_id;

  insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,actor_id,metadata)
  values(p_company_id,v_id,'meta_whatsapp','configured','Número de WhatsApp conectado mediante Embedded Signup.',p_actor_id,
    jsonb_build_object('location_id',p_location_id,'waba_id',v_waba,'phone_number_id',v_phone_id,'onboarding_mode',v_mode));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,p_actor_id,'whatsapp.embedded_signup_completed','integration_connection',v_id,
    jsonb_build_object('location_id',p_location_id,'waba_id',v_waba,'phone_number_id',v_phone_id,'onboarding_mode',v_mode));
  return v_id;
end;
$$;

create or replace function public.get_integration_center(p_company_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_items jsonb; v_events jsonb; v_whatsapp jsonb; v_whatsapp_status text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_integrations') then raise exception 'No autorizado para consultar integraciones.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'display_name',c.display_name,'status',c.status,'configuration',c.configuration,
    'last_checked_at',c.last_checked_at,'last_success_at',c.last_success_at,
    'last_error_code',c.last_error_code,'last_error_message',c.last_error_message
  ) order by c.created_at,c.id),'[]'::jsonb),
  case
    when count(*)=0 then 'not_connected'
    when bool_or(c.status='degraded') then 'degraded'
    when bool_or(c.status='connected') then 'connected'
    else 'configured'
  end
  into v_whatsapp,v_whatsapp_status
  from public.integration_connections c where c.company_id=p_company_id and c.provider_code='meta_whatsapp';

  select jsonb_agg(item order by item->>'sort') into v_items from(
    select jsonb_build_object('sort','1','provider_code','meta_whatsapp','name','WhatsApp','category','Canales',
      'description','Conecta números de WhatsApp y asígnalos a sus sucursales.','status',v_whatsapp_status,
      'connections',v_whatsapp,'configuration','{}'::jsonb,'retry_count',0,'managed_by','embedded_signup') item
    union all
    select jsonb_build_object('sort','2','provider_code','shopify','name','Shopify','category','Comercio','description','Sincroniza clientes, pedidos, envios y productos.','status',case when s.installed_at is null then 'not_connected' when s.last_error_code is not null then 'degraded' else 'connected' end,'display_name',s.shop_domain,'configuration',jsonb_build_object('shop_domain',s.shop_domain),'last_checked_at',s.last_sync_at,'last_success_at',s.last_sync_at,'last_error_code',s.last_error_code,'last_error_message',null,'retry_count',0,'next_retry_at',null,'managed_by','direct','connections','[]'::jsonb) from (select 1) seed left join public.shopify_stores s on s.company_id=p_company_id
    union all
    select jsonb_build_object('sort','3','provider_code','xai','name','Grok / xAI','category','Inteligencia artificial','description','Proveedor alterno para clasificacion y extraccion estructurada.','status',coalesce(c.status,'not_connected'),'display_name',c.display_name,'configuration',coalesce(c.configuration,'{}'::jsonb),'last_checked_at',c.last_checked_at,'last_success_at',c.last_success_at,'last_error_code',c.last_error_code,'last_error_message',c.last_error_message,'retry_count',coalesce(c.retry_count,0),'next_retry_at',c.next_retry_at,'managed_by',case when c.nango_connection_id is null then 'direct' else 'nango' end,'connections','[]'::jsonb) from (select 1) seed left join public.integration_connections c on c.company_id=p_company_id and c.provider_code='xai'
  ) catalog;
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'provider_code',e.provider_code,'event_type',e.event_type,'severity',e.severity,'summary',e.summary,'occurred_at',e.occurred_at,'actor_name',p.full_name) order by e.occurred_at desc,e.id desc),'[]'::jsonb) into v_events from (select * from public.integration_events where company_id=p_company_id order by occurred_at desc,id desc limit 30) e left join public.profiles p on p.id=e.actor_id;
  return jsonb_build_object('items',coalesce(v_items,'[]'::jsonb),'events',v_events,'capabilities',jsonb_build_object('secure_credentials',true,'webhook_idempotency',true,'automatic_retries',true,'embedded_signup',true,'multiple_numbers',true));
end;
$$;

create or replace function public.register_integration_webhook(
  p_connection_id uuid,p_provider_event_id text,p_event_type text,p_payload_sha256 text,p_payload jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype; v_receipt public.integration_webhook_receipts%rowtype;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  if nullif(trim(p_provider_event_id),'') is null or nullif(trim(p_event_type),'') is null
    or p_payload_sha256!~'^[0-9a-fA-F]{64}$' or jsonb_typeof(coalesce(p_payload,'null'::jsonb))<>'object' then raise exception 'Webhook incompleto.'; end if;
  select * into v_connection from public.integration_connections where id=p_connection_id and provider_code='meta_whatsapp';
  if not found then raise exception 'Conexion de WhatsApp no disponible.'; end if;
  insert into public.integration_webhook_receipts(company_id,connection_id,provider_code,provider_event_id,event_type,payload_sha256,payload,status,processing_started_at)
  values(v_connection.company_id,v_connection.id,'meta_whatsapp',trim(p_provider_event_id),trim(p_event_type),lower(p_payload_sha256),p_payload,'processing',clock_timestamp())
  on conflict(connection_id,provider_event_id) do nothing returning * into v_receipt;
  if found then
    insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,metadata)
    values(v_connection.company_id,v_connection.id,'meta_whatsapp','webhook_received','Webhook recibido, persistido y reclamado.',jsonb_build_object('receipt_id',v_receipt.id,'external_event_type',trim(p_event_type)));
    return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',false,'should_process',true,'retry',false);
  end if;
  select * into v_receipt from public.integration_webhook_receipts where connection_id=v_connection.id and provider_event_id=trim(p_provider_event_id) for update;
  if v_receipt.payload_sha256<>lower(p_payload_sha256) then raise exception 'El identificador del webhook fue reutilizado con otro contenido.'; end if;
  if v_receipt.status='retry_pending' or (v_receipt.status='processing' and v_receipt.processing_started_at<clock_timestamp()-interval '5 minutes') then
    update public.integration_webhook_receipts set status='processing',processing_started_at=clock_timestamp(),next_retry_at=null,payload=p_payload where id=v_receipt.id;
    return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',true,'should_process',true,'retry',true);
  end if;
  return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',true,'should_process',false,'retry',false,'status',v_receipt.status);
end;
$$;

create or replace function public.enable_whatsapp_simulator(p_company_id uuid,p_location_id uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_integrations') or not public.has_company_permission(p_company_id,'manage_sales_quotes') then raise exception 'No autorizado para simular WhatsApp.'; end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then raise exception 'Sucursal no disponible.'; end if;
  select id into v_id from public.integration_connections where company_id=p_company_id and provider_code='meta_whatsapp' and auth_mode='simulated' order by created_at limit 1 for update;
  if v_id is null then
    insert into public.integration_connections(company_id,provider_code,display_name,auth_mode,status,configuration,created_by,updated_by)
    values(p_company_id,'meta_whatsapp','WhatsApp · Simulador','simulated','configured',jsonb_build_object('simulation_enabled',true,'location_id',p_location_id),auth.uid(),auth.uid()) returning id into v_id;
  else
    update public.integration_connections set configuration=configuration||jsonb_build_object('simulation_enabled',true,'location_id',p_location_id),updated_by=auth.uid() where id=v_id;
  end if;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,actor_id,metadata)
  values(p_company_id,v_id,'meta_whatsapp','configured','Simulador de WhatsApp habilitado.',auth.uid(),jsonb_build_object('location_id',p_location_id));
  return v_id;
end;
$$;

create or replace function public.request_integration_retry(p_company_id uuid,p_provider_code text) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_integrations') then raise exception 'No autorizado para reintentar integraciones.'; end if;
  update public.integration_connections set status='configured',next_retry_at=now(),retry_count=retry_count+1,updated_by=auth.uid()
  where company_id=p_company_id and provider_code=p_provider_code;
  get diagnostics v_count=row_count;
  if v_count=0 then raise exception 'La conexion todavia no esta configurada.'; end if;
  insert into public.integration_events(company_id,provider_code,event_type,summary,actor_id,metadata)
  values(p_company_id,p_provider_code,'retry_requested','Reintento solicitado por un administrador.',auth.uid(),jsonb_build_object('connections',v_count));
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'integration.retry_requested','integration_connection',jsonb_build_object('provider_code',p_provider_code,'connections',v_count));
  return public.get_integration_center(p_company_id);
end;
$$;

revoke all on function public.complete_whatsapp_connection(uuid,uuid,text,uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.complete_whatsapp_connection(uuid,uuid,text,uuid,text,text,text,text,text) to service_role;
revoke all on function public.register_integration_webhook(uuid,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.register_integration_webhook(uuid,text,text,text,jsonb) to service_role;

commit;
