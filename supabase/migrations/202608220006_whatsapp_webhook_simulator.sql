-- Satrapy · Webhook y simulador de WhatsApp conectados con cotizaciones AI.
begin;

alter table public.integration_connections drop constraint if exists integration_connections_auth_mode_check;
alter table public.integration_connections add constraint integration_connections_auth_mode_check check(auth_mode in('api_key','oauth2','managed','simulated'));
alter table public.integration_connections alter column secret_ciphertext drop not null;
alter table public.integration_connections drop constraint if exists integration_connections_secret_ciphertext_check;
alter table public.integration_connections add constraint integration_connections_secret_ciphertext_check check(
  (auth_mode='simulated' and secret_ciphertext is null) or
  (auth_mode<>'simulated' and nullif(trim(secret_ciphertext),'') is not null)
);

alter table public.sales_quote_intake_requests
  add column if not exists source_message_id text,
  add column if not exists source_sender text,
  add column if not exists integration_receipt_id uuid references public.integration_webhook_receipts(id) on delete set null;
create unique index if not exists sales_quote_intake_external_message_uidx
  on public.sales_quote_intake_requests(company_id,source,source_message_id)
  where source_message_id is not null;

create or replace function public.enable_whatsapp_simulator(p_company_id uuid,p_location_id uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_integrations') or not public.has_company_permission(p_company_id,'manage_sales_quotes') then raise exception 'No autorizado para simular WhatsApp.'; end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then raise exception 'Sucursal no disponible.'; end if;
  insert into public.integration_connections(company_id,provider_code,display_name,auth_mode,status,configuration,created_by,updated_by)
  values(p_company_id,'meta_whatsapp','WhatsApp · Simulador','simulated','configured',jsonb_build_object('simulation_enabled',true,'location_id',p_location_id),auth.uid(),auth.uid())
  on conflict(company_id,provider_code) do update set
    configuration=integration_connections.configuration||jsonb_build_object('simulation_enabled',true,'location_id',p_location_id),
    updated_by=auth.uid()
  returning id into v_id;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,actor_id,metadata)
  values(p_company_id,v_id,'meta_whatsapp','configured','Simulador de WhatsApp habilitado.',auth.uid(),jsonb_build_object('location_id',p_location_id));
  return v_id;
end $$;

create or replace function public.start_external_sales_quote_intake(
  p_connection_id uuid,p_location_id uuid,p_customer_id uuid,p_message text,p_source_message_id text,p_source_sender text,p_receipt_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype;v_actor uuid;v_customer uuid:=p_customer_id;v_started jsonb;v_request_id uuid;v_sender_digits text;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_connection from public.integration_connections where id=p_connection_id and provider_code='meta_whatsapp';
  if not found then raise exception 'Conexion de WhatsApp no disponible.'; end if;
  v_actor:=v_connection.created_by;
  if v_actor is null then raise exception 'La conexion no tiene un responsable operativo.'; end if;
  if p_source_message_id is null or trim(p_source_message_id)='' then raise exception 'Mensaje externo sin identificador.'; end if;
  select id into v_request_id from public.sales_quote_intake_requests where company_id=v_connection.company_id and source='whatsapp' and source_message_id=trim(p_source_message_id);
  if v_request_id is not null then return jsonb_build_object('id',v_request_id,'duplicate',true); end if;
  if v_customer is null and nullif(trim(p_source_sender),'') is not null then
    v_sender_digits:=right(regexp_replace(p_source_sender,'[^0-9]','','g'),10);
    select candidate.customer_id into v_customer from(
      select c.id customer_id,0 priority from public.customers c where c.company_id=v_connection.company_id and c.is_active and right(regexp_replace(coalesce(c.phone,''),'[^0-9]','','g'),10)=v_sender_digits
      union all
      select cc.customer_id,1 from public.customer_contacts cc join public.customers c on c.id=cc.customer_id where cc.company_id=v_connection.company_id and c.is_active and right(regexp_replace(coalesce(cc.phone,''),'[^0-9]','','g'),10)=v_sender_digits
    )candidate order by priority limit 1;
  end if;
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  perform set_config('request.jwt.claim.role','authenticated',true);
  v_started:=public.start_sales_quote_intake(v_connection.company_id,p_location_id,v_customer,p_message);
  v_request_id:=(v_started->>'id')::uuid;
  update public.sales_quote_intake_requests set source='whatsapp',source_message_id=trim(p_source_message_id),source_sender=nullif(trim(p_source_sender),''),integration_receipt_id=p_receipt_id where id=v_request_id;
  return jsonb_build_object('id',v_request_id,'customer_id',v_customer,'duplicate',false);
end $$;

create or replace function public.complete_external_sales_quote_intake(
  p_connection_id uuid,p_request_id uuid,p_intent text,p_intent_confidence numeric,p_customer_hint text,p_items jsonb,
  p_model text,p_prompt_version text,p_raw_output jsonb,p_input_tokens integer,p_output_tokens integer,
  p_estimated_cost_usd numeric,p_trace_id text,p_latency_ms integer
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype;v_actor uuid;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_connection from public.integration_connections where id=p_connection_id and provider_code='meta_whatsapp';
  if not found then raise exception 'Conexion de WhatsApp no disponible.'; end if;
  v_actor:=v_connection.created_by;if v_actor is null then raise exception 'La conexion no tiene un responsable operativo.';end if;
  perform set_config('request.jwt.claim.sub',v_actor::text,true);perform set_config('request.jwt.claim.role','authenticated',true);
  return public.complete_sales_quote_intake(v_connection.company_id,p_request_id,p_intent,p_intent_confidence,p_customer_hint,p_items,p_model,p_prompt_version,p_raw_output,p_input_tokens,p_output_tokens,p_estimated_cost_usd,p_trace_id,p_latency_ms);
end $$;

create or replace function public.fail_external_sales_quote_intake(p_connection_id uuid,p_request_id uuid,p_error text,p_latency_ms integer default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_connection public.integration_connections%rowtype;v_actor uuid;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_connection from public.integration_connections where id=p_connection_id and provider_code='meta_whatsapp';
  if not found then return;end if;v_actor:=v_connection.created_by;if v_actor is null then return;end if;
  perform set_config('request.jwt.claim.sub',v_actor::text,true);perform set_config('request.jwt.claim.role','authenticated',true);
  perform public.fail_sales_quote_intake(p_request_id,p_error,p_latency_ms);
end $$;

revoke all on function public.enable_whatsapp_simulator(uuid,uuid) from public,anon,authenticated;
grant execute on function public.enable_whatsapp_simulator(uuid,uuid) to authenticated;
revoke all on function public.start_external_sales_quote_intake(uuid,uuid,uuid,text,text,text,uuid),public.complete_external_sales_quote_intake(uuid,uuid,text,numeric,text,jsonb,text,text,jsonb,integer,integer,numeric,text,integer),public.fail_external_sales_quote_intake(uuid,uuid,text,integer) from public,anon,authenticated;
grant execute on function public.start_external_sales_quote_intake(uuid,uuid,uuid,text,text,text,uuid),public.complete_external_sales_quote_intake(uuid,uuid,text,numeric,text,jsonb,text,text,jsonb,integer,integer,numeric,text,integer),public.fail_external_sales_quote_intake(uuid,uuid,text,integer) to service_role;

commit;
