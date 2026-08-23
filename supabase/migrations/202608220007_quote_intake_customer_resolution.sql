-- Satrapy · Resolución clara de cliente en solicitudes de cotización.
-- Expone el remitente sólo a usuarios autorizados para reutilizarlo en el alta rápida.

begin;

create or replace function public.get_sales_quote_intake(p_company_id uuid,p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v public.sales_quote_intake_requests%rowtype;
begin
  select * into v
  from public.sales_quote_intake_requests
  where id=p_request_id and company_id=p_company_id;

  if not found
    or auth.uid() is null
    or not public.has_company_permission(p_company_id,'view_sales_quotes')
    or not public.can_access_location(v.location_id) then
    raise exception 'Solicitud no disponible.';
  end if;

  return jsonb_build_object(
    'id',v.id,
    'status',v.status,
    'source',v.source,
    'source_sender',v.source_sender,
    'original_message',v.original_message,
    'intent',v.intent,
    'intent_confidence',v.intent_confidence,
    'customer_hint',v.customer_hint,
    'prepared_lines',v.prepared_lines,
    'latency_ms',v.latency_ms,
    'error_message',v.error_message,
    'created_at',v.created_at,
    'processed_at',v.processed_at,
    'location',(select jsonb_build_object('id',l.id,'name',l.name,'code',l.external_code) from public.locations l where l.id=v.location_id),
    'customer',(select jsonb_build_object('id',c.id,'display_name',c.display_name,'code',c.code) from public.customers c where c.id=v.customer_id)
  );
end;
$$;

revoke all on function public.get_sales_quote_intake(uuid,uuid) from public,anon;
grant execute on function public.get_sales_quote_intake(uuid,uuid) to authenticated;

commit;
