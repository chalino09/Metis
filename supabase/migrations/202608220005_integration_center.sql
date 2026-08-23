-- Satrapy - Centro de integraciones por empresa.
-- Los secretos llegan cifrados desde el servidor y nunca se exponen por RPC al navegador.
begin;

insert into public.permissions(code,description) values
('view_integrations','Consultar conexiones, salud y eventos de integraciones.'),
('manage_integrations','Configurar conexiones y solicitar reintentos.')
on conflict(code) do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r join public.permissions p on p.code in('view_integrations','manage_integrations') where r.code in('super_admin','direccion_admin') on conflict do nothing;

create table if not exists public.integration_connections(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  provider_code text not null check(provider_code in('meta_whatsapp','xai')), display_name text not null,
  auth_mode text not null check(auth_mode in('api_key','oauth2','managed')),
  status text not null default 'configured' check(status in('configured','connected','degraded','disabled')),
  configuration jsonb not null default '{}'::jsonb, secret_ciphertext text not null, secret_version integer not null default 1,
  external_account_id text, nango_connection_id text, last_checked_at timestamptz, last_success_at timestamptz,
  last_error_code text, last_error_message text, retry_count integer not null default 0 check(retry_count>=0), next_retry_at timestamptz,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id), updated_at timestamptz not null default now(), updated_by uuid references auth.users(id),
  unique(company_id,provider_code), check(jsonb_typeof(configuration)='object'), check(nullif(trim(secret_ciphertext),'') is not null)
);
create index if not exists integration_connections_health_idx on public.integration_connections(company_id,status,next_retry_at);
drop trigger if exists integration_connections_updated_at on public.integration_connections;
create trigger integration_connections_updated_at before update on public.integration_connections for each row execute function public.set_updated_at();

create table if not exists public.integration_events(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid references public.integration_connections(id) on delete cascade, provider_code text not null,
  event_type text not null check(event_type in('configured','connected','health_ok','health_failed','retry_requested','webhook_received','webhook_completed','webhook_failed')),
  severity text not null default 'info' check(severity in('info','warning','error')), summary text not null, metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(), actor_id uuid references auth.users(id)
);
create index if not exists integration_events_company_idx on public.integration_events(company_id,occurred_at desc,id);

create table if not exists public.integration_webhook_receipts(
  id uuid primary key default gen_random_uuid(), company_id uuid not null references public.companies(id) on delete cascade,
  connection_id uuid not null references public.integration_connections(id) on delete cascade, provider_code text not null,
  provider_event_id text not null, event_type text not null, payload_sha256 text not null,
  status text not null default 'received' check(status in('received','processing','completed','retry_pending','failed','ignored')),
  attempts integer not null default 0 check(attempts>=0), next_retry_at timestamptz, last_error_code text, last_error_message text,
  received_at timestamptz not null default now(), processed_at timestamptz, unique(connection_id,provider_event_id)
);
create index if not exists integration_webhook_retry_idx on public.integration_webhook_receipts(status,next_retry_at) where status='retry_pending';

alter table public.integration_connections enable row level security;
alter table public.integration_events enable row level security;
alter table public.integration_webhook_receipts enable row level security;
revoke all on public.integration_connections,public.integration_events,public.integration_webhook_receipts from anon,authenticated;

create or replace function public.get_integration_center(p_company_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_items jsonb; v_events jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_integrations') then raise exception 'No autorizado para consultar integraciones.'; end if;
  select jsonb_agg(item order by item->>'sort') into v_items from(
    select jsonb_build_object('sort','1','provider_code','meta_whatsapp','name','WhatsApp','category','Canales','description','Recibe solicitudes y entrega cotizaciones por sucursal.','status',coalesce(c.status,'not_connected'),'display_name',c.display_name,'configuration',coalesce(c.configuration,'{}'::jsonb),'last_checked_at',c.last_checked_at,'last_success_at',c.last_success_at,'last_error_code',c.last_error_code,'last_error_message',c.last_error_message,'retry_count',coalesce(c.retry_count,0),'next_retry_at',c.next_retry_at,'managed_by',case when c.nango_connection_id is null then 'direct' else 'nango' end) item from (select 1) seed left join public.integration_connections c on c.company_id=p_company_id and c.provider_code='meta_whatsapp'
    union all
    select jsonb_build_object('sort','2','provider_code','shopify','name','Shopify','category','Comercio','description','Sincroniza clientes, pedidos, envios y productos.','status',case when s.installed_at is null then 'not_connected' when s.last_error_code is not null then 'degraded' else 'connected' end,'display_name',s.shop_domain,'configuration',jsonb_build_object('shop_domain',s.shop_domain),'last_checked_at',s.last_sync_at,'last_success_at',s.last_sync_at,'last_error_code',s.last_error_code,'last_error_message',null,'retry_count',0,'next_retry_at',null,'managed_by','direct') from (select 1) seed left join public.shopify_stores s on s.company_id=p_company_id
    union all
    select jsonb_build_object('sort','3','provider_code','xai','name','Grok / xAI','category','Inteligencia artificial','description','Proveedor alterno para clasificacion y extraccion estructurada.','status',coalesce(c.status,'not_connected'),'display_name',c.display_name,'configuration',coalesce(c.configuration,'{}'::jsonb),'last_checked_at',c.last_checked_at,'last_success_at',c.last_success_at,'last_error_code',c.last_error_code,'last_error_message',c.last_error_message,'retry_count',coalesce(c.retry_count,0),'next_retry_at',c.next_retry_at,'managed_by',case when c.nango_connection_id is null then 'direct' else 'nango' end) from (select 1) seed left join public.integration_connections c on c.company_id=p_company_id and c.provider_code='xai'
  ) catalog;
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'provider_code',e.provider_code,'event_type',e.event_type,'severity',e.severity,'summary',e.summary,'occurred_at',e.occurred_at,'actor_name',p.full_name) order by e.occurred_at desc,e.id desc),'[]'::jsonb) into v_events from (select * from public.integration_events where company_id=p_company_id order by occurred_at desc,id desc limit 30) e left join public.profiles p on p.id=e.actor_id;
  return jsonb_build_object('items',coalesce(v_items,'[]'::jsonb),'events',v_events,'capabilities',jsonb_build_object('secure_credentials',true,'webhook_idempotency',true,'automatic_retries',true,'optional_nango_adapter',true));
end $$;

create or replace function public.authorize_integration_management(p_company_id uuid) returns boolean language plpgsql stable security definer set search_path=public as $$
begin if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_integrations') then raise exception 'No autorizado para administrar integraciones.'; end if; return true; end $$;

create or replace function public.complete_integration_connection(p_company_id uuid,p_actor_id uuid,p_provider_code text,p_display_name text,p_auth_mode text,p_configuration jsonb,p_secret_ciphertext text,p_nango_connection_id text default null) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_provider text:=trim(p_provider_code); v_name text:=trim(p_display_name);
begin
  if auth.role()<>'service_role' or p_actor_id is null then raise exception 'Operacion reservada al servidor.'; end if;
  if v_provider not in('meta_whatsapp','xai') or v_name='' or p_auth_mode not in('api_key','oauth2','managed') or nullif(trim(p_secret_ciphertext),'') is null then raise exception 'Conexion incompleta.'; end if;
  insert into public.integration_connections(company_id,provider_code,display_name,auth_mode,status,configuration,secret_ciphertext,nango_connection_id,created_by,updated_by)
  values(p_company_id,v_provider,v_name,p_auth_mode,'configured',coalesce(p_configuration,'{}'::jsonb),trim(p_secret_ciphertext),nullif(trim(p_nango_connection_id),''),p_actor_id,p_actor_id)
  on conflict(company_id,provider_code) do update set display_name=excluded.display_name,auth_mode=excluded.auth_mode,status='configured',configuration=excluded.configuration,secret_ciphertext=excluded.secret_ciphertext,secret_version=integration_connections.secret_version+1,nango_connection_id=excluded.nango_connection_id,last_error_code=null,last_error_message=null,next_retry_at=null,updated_by=p_actor_id returning id into v_id;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,actor_id) values(p_company_id,v_id,v_provider,'configured','Credenciales actualizadas de forma segura.',p_actor_id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,p_actor_id,'integration.configured','integration_connection',v_id,jsonb_build_object('provider_code',v_provider,'auth_mode',p_auth_mode,'managed_by',case when p_nango_connection_id is null then 'direct' else 'nango' end));
  return v_id;
end $$;

create or replace function public.request_integration_retry(p_company_id uuid,p_provider_code text) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_integrations') then raise exception 'No autorizado para reintentar integraciones.'; end if;
  select * into v_connection from public.integration_connections where company_id=p_company_id and provider_code=p_provider_code for update;
  if not found then raise exception 'La conexion todavia no esta configurada.'; end if;
  update public.integration_connections set status='configured',next_retry_at=now(),retry_count=retry_count+1,updated_by=auth.uid() where id=v_connection.id;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,actor_id) values(p_company_id,v_connection.id,p_provider_code,'retry_requested','Reintento solicitado por un administrador.',auth.uid());
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'integration.retry_requested','integration_connection',v_connection.id,jsonb_build_object('provider_code',p_provider_code));
  return public.get_integration_center(p_company_id);
end $$;

create or replace function public.register_integration_webhook(p_company_id uuid,p_provider_code text,p_provider_event_id text,p_event_type text,p_payload_sha256 text) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype; v_receipt_id uuid; v_inserted boolean:=false;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  if nullif(trim(p_provider_event_id),'') is null or nullif(trim(p_event_type),'') is null or p_payload_sha256 !~ '^[0-9a-fA-F]{64}$' then raise exception 'Webhook incompleto.'; end if;
  select * into v_connection from public.integration_connections where company_id=p_company_id and provider_code=p_provider_code;
  if not found then raise exception 'La conexion todavia no esta configurada.'; end if;
  insert into public.integration_webhook_receipts(company_id,connection_id,provider_code,provider_event_id,event_type,payload_sha256)
  values(p_company_id,v_connection.id,p_provider_code,trim(p_provider_event_id),trim(p_event_type),lower(p_payload_sha256))
  on conflict(connection_id,provider_event_id) do nothing returning id into v_receipt_id;
  if v_receipt_id is not null then
    v_inserted:=true;
    insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,metadata) values(p_company_id,v_connection.id,p_provider_code,'webhook_received','Webhook recibido y registrado.',jsonb_build_object('receipt_id',v_receipt_id,'external_event_type',trim(p_event_type)));
  else
    select id into v_receipt_id from public.integration_webhook_receipts where connection_id=v_connection.id and provider_event_id=trim(p_provider_event_id);
  end if;
  return jsonb_build_object('receipt_id',v_receipt_id,'duplicate',not v_inserted);
end $$;

create or replace function public.complete_integration_webhook(p_receipt_id uuid,p_succeeded boolean,p_error_code text default null,p_error_message text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.integration_webhook_receipts%rowtype; v_attempts integer; v_retry boolean;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_receipt from public.integration_webhook_receipts where id=p_receipt_id for update;
  if not found then raise exception 'Webhook no encontrado.'; end if;
  if v_receipt.status in('completed','ignored') then return jsonb_build_object('status',v_receipt.status,'duplicate_completion',true); end if;
  v_attempts:=v_receipt.attempts+1; v_retry:=not p_succeeded and v_attempts<8;
  update public.integration_webhook_receipts set attempts=v_attempts,status=case when p_succeeded then 'completed' when v_retry then 'retry_pending' else 'failed' end,next_retry_at=case when v_retry then now()+make_interval(secs=>least(3600,30*power(2,v_attempts-1)::integer)) else null end,last_error_code=case when p_succeeded then null else left(coalesce(p_error_code,'WEBHOOK_PROCESSING_FAILED'),120) end,last_error_message=case when p_succeeded then null else left(coalesce(p_error_message,'No fue posible procesar el webhook.'),600) end,processed_at=case when p_succeeded or not v_retry then now() else null end where id=p_receipt_id;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,severity,summary,metadata) values(v_receipt.company_id,v_receipt.connection_id,v_receipt.provider_code,case when p_succeeded then 'webhook_completed' else 'webhook_failed' end,case when p_succeeded then 'info' when v_retry then 'warning' else 'error' end,case when p_succeeded then 'Webhook procesado correctamente.' when v_retry then 'Webhook pendiente de reintento.' else 'Webhook agotó sus reintentos.' end,jsonb_build_object('receipt_id',p_receipt_id,'attempt',v_attempts,'will_retry',v_retry));
  return jsonb_build_object('status',case when p_succeeded then 'completed' when v_retry then 'retry_pending' else 'failed' end,'attempts',v_attempts,'will_retry',v_retry);
end $$;

revoke all on function public.get_integration_center(uuid),public.authorize_integration_management(uuid),public.request_integration_retry(uuid,text) from public,anon,authenticated;
grant execute on function public.get_integration_center(uuid),public.authorize_integration_management(uuid),public.request_integration_retry(uuid,text) to authenticated;
revoke all on function public.complete_integration_connection(uuid,uuid,text,text,text,jsonb,text,text) from public,anon,authenticated;
grant execute on function public.complete_integration_connection(uuid,uuid,text,text,text,jsonb,text,text) to service_role;
revoke all on function public.register_integration_webhook(uuid,text,text,text,text),public.complete_integration_webhook(uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.register_integration_webhook(uuid,text,text,text,text),public.complete_integration_webhook(uuid,boolean,text,text) to service_role;
commit;
