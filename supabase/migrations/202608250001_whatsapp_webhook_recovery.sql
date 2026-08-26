-- Satrapy · Recuperación segura e idempotente de webhooks de WhatsApp.
-- El evento se persiste antes de invocar IA y sólo un worker puede reclamarlo.

begin;

alter table public.integration_webhook_receipts
  add column if not exists payload jsonb not null default '{}'::jsonb,
  add column if not exists processing_started_at timestamptz;

create or replace function public.register_integration_webhook(
  p_company_id uuid,
  p_provider_code text,
  p_provider_event_id text,
  p_event_type text,
  p_payload_sha256 text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_connection public.integration_connections%rowtype;
  v_receipt public.integration_webhook_receipts%rowtype;
begin
  if auth.role()<>'service_role' then
    raise exception 'Operacion reservada al servidor.';
  end if;
  if nullif(trim(p_provider_event_id),'') is null
    or nullif(trim(p_event_type),'') is null
    or p_payload_sha256 !~ '^[0-9a-fA-F]{64}$'
    or jsonb_typeof(coalesce(p_payload,'null'::jsonb))<>'object' then
    raise exception 'Webhook incompleto.';
  end if;

  select * into v_connection
  from public.integration_connections
  where company_id=p_company_id and provider_code=p_provider_code;
  if not found then raise exception 'La conexion todavia no esta configurada.'; end if;

  insert into public.integration_webhook_receipts(
    company_id,connection_id,provider_code,provider_event_id,event_type,payload_sha256,payload,status,processing_started_at
  ) values(
    p_company_id,v_connection.id,p_provider_code,trim(p_provider_event_id),trim(p_event_type),lower(p_payload_sha256),p_payload,'processing',clock_timestamp()
  )
  on conflict(connection_id,provider_event_id) do nothing
  returning * into v_receipt;

  if found then
    insert into public.integration_events(company_id,connection_id,provider_code,event_type,summary,metadata)
    values(p_company_id,v_connection.id,p_provider_code,'webhook_received','Webhook recibido, persistido y reclamado.',jsonb_build_object('receipt_id',v_receipt.id,'external_event_type',trim(p_event_type)));
    return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',false,'should_process',true,'retry',false);
  end if;

  select * into v_receipt
  from public.integration_webhook_receipts
  where connection_id=v_connection.id and provider_event_id=trim(p_provider_event_id)
  for update;

  if v_receipt.payload_sha256<>lower(p_payload_sha256) then
    raise exception 'El identificador del webhook fue reutilizado con otro contenido.';
  end if;

  if v_receipt.status='retry_pending'
    or (v_receipt.status='processing' and v_receipt.processing_started_at<clock_timestamp()-interval '5 minutes') then
    update public.integration_webhook_receipts
    set status='processing',processing_started_at=clock_timestamp(),next_retry_at=null,payload=p_payload
    where id=v_receipt.id;
    return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',true,'should_process',true,'retry',true);
  end if;

  return jsonb_build_object('receipt_id',v_receipt.id,'duplicate',true,'should_process',false,'retry',false,'status',v_receipt.status);
end;
$$;

create or replace function public.complete_integration_webhook(
  p_receipt_id uuid,p_succeeded boolean,p_error_code text default null,p_error_message text default null
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_receipt public.integration_webhook_receipts%rowtype;
  v_attempts integer;
  v_retry boolean;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_receipt from public.integration_webhook_receipts where id=p_receipt_id for update;
  if not found then raise exception 'Webhook no encontrado.'; end if;
  if v_receipt.status in('completed','ignored') then
    return jsonb_build_object('status',v_receipt.status,'duplicate_completion',true);
  end if;
  v_attempts:=v_receipt.attempts+1;
  v_retry:=not p_succeeded and v_attempts<8;
  update public.integration_webhook_receipts set
    attempts=v_attempts,
    status=case when p_succeeded then 'completed' when v_retry then 'retry_pending' else 'failed' end,
    next_retry_at=case when v_retry then clock_timestamp()+make_interval(secs=>least(3600,30*power(2,v_attempts-1)::integer)) else null end,
    last_error_code=case when p_succeeded then null else left(coalesce(p_error_code,'WEBHOOK_PROCESSING_FAILED'),120) end,
    last_error_message=case when p_succeeded then null else left(coalesce(p_error_message,'No fue posible procesar el webhook.'),600) end,
    processed_at=case when p_succeeded or not v_retry then clock_timestamp() else null end,
    processing_started_at=null
  where id=p_receipt_id;
  insert into public.integration_events(company_id,connection_id,provider_code,event_type,severity,summary,metadata)
  values(v_receipt.company_id,v_receipt.connection_id,v_receipt.provider_code,
    case when p_succeeded then 'webhook_completed' else 'webhook_failed' end,
    case when p_succeeded then 'info' when v_retry then 'warning' else 'error' end,
    case when p_succeeded then 'Webhook procesado correctamente.' when v_retry then 'Webhook pendiente de reintento.' else 'Webhook agotó sus reintentos.' end,
    jsonb_build_object('receipt_id',p_receipt_id,'attempt',v_attempts,'will_retry',v_retry));
  return jsonb_build_object('status',case when p_succeeded then 'completed' when v_retry then 'retry_pending' else 'failed' end,'attempts',v_attempts,'will_retry',v_retry);
end;
$$;

create or replace function public.start_external_sales_quote_intake(
  p_connection_id uuid,p_location_id uuid,p_customer_id uuid,p_message text,p_source_message_id text,p_source_sender text,p_receipt_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_connection public.integration_connections%rowtype;
  v_actor uuid;
  v_customer uuid:=p_customer_id;
  v_started jsonb;
  v_request public.sales_quote_intake_requests%rowtype;
  v_sender_digits text;
begin
  if auth.role()<>'service_role' then raise exception 'Operacion reservada al servidor.'; end if;
  select * into v_connection from public.integration_connections where id=p_connection_id and provider_code='meta_whatsapp';
  if not found then raise exception 'Conexion de WhatsApp no disponible.'; end if;
  v_actor:=v_connection.created_by;
  if v_actor is null then raise exception 'La conexion no tiene un responsable operativo.'; end if;
  if p_source_message_id is null or trim(p_source_message_id)='' then raise exception 'Mensaje externo sin identificador.'; end if;

  select * into v_request from public.sales_quote_intake_requests
  where company_id=v_connection.company_id and source='whatsapp' and source_message_id=trim(p_source_message_id)
  for update;
  if found then
    if v_request.status='failed' then
      update public.sales_quote_intake_requests set status='processing',error_message=null,processed_at=null,updated_at=clock_timestamp()
      where id=v_request.id;
      return jsonb_build_object('id',v_request.id,'customer_id',v_request.customer_id,'duplicate',false,'retry',true);
    end if;
    return jsonb_build_object('id',v_request.id,'duplicate',true,'retry',false);
  end if;

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
  v_request.id:=(v_started->>'id')::uuid;
  update public.sales_quote_intake_requests set source='whatsapp',source_message_id=trim(p_source_message_id),source_sender=nullif(trim(p_source_sender),''),integration_receipt_id=p_receipt_id where id=v_request.id;
  return jsonb_build_object('id',v_request.id,'customer_id',v_customer,'duplicate',false,'retry',false);
end;
$$;

revoke all on function public.register_integration_webhook(uuid,text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.register_integration_webhook(uuid,text,text,text,text,jsonb) to service_role;
drop function if exists public.register_integration_webhook(uuid,text,text,text,text);

commit;
