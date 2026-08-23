-- Satrapy - Fase 3A: documento final y aprobacion de cotizaciones.
-- La aprobacion congela la presentacion comercial; no envia mensajes ni reserva inventario.

begin;

alter table public.sales_quotes
  drop constraint if exists sales_quotes_status_check;
alter table public.sales_quotes
  add constraint sales_quotes_status_check
  check (status in ('draft', 'approved', 'sent', 'accepted', 'not_converted'));

alter table public.sales_quotes
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references auth.users(id) on delete set null;

alter table public.sales_quote_follow_ups
  drop constraint if exists sales_quote_follow_ups_event_type_check;
alter table public.sales_quote_follow_ups
  add constraint sales_quote_follow_ups_event_type_check
  check (event_type in ('created', 'approved', 'sent', 'accepted', 'not_converted', 'note'));

create or replace function public.get_sales_quote_detail(p_company_id uuid, p_quote_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype;
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id;
  if not found or not public.has_company_permission(p_company_id, 'view_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotizacion no disponible.'; end if;
  return jsonb_build_object(
    'id', v_quote.id, 'folio', v_quote.folio, 'status', v_quote.status, 'currency_code', v_quote.currency_code,
    'valid_until', v_quote.valid_until, 'subtotal_amount', v_quote.subtotal_amount, 'tax_amount', v_quote.tax_amount,
    'total_amount', v_quote.total_amount, 'approved_at', v_quote.approved_at,
    'approved_by', (select jsonb_build_object('id', profile_data.id, 'name', profile_data.full_name) from public.profiles profile_data where profile_data.id = v_quote.approved_by),
    'updated_at', v_quote.updated_at,
    'customer', (select jsonb_build_object('id', customer_data.id, 'code', customer_data.code, 'display_name', customer_data.display_name) from public.customers customer_data where customer_data.id = v_quote.customer_id),
    'location', (select jsonb_build_object('id', location_data.id, 'name', location_data.name, 'code', location_data.external_code) from public.locations location_data where location_data.id = v_quote.location_id),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', line_data.id, 'product_id', line_data.product_id, 'product_code', line_data.product_code, 'product_name', line_data.product_name, 'unit_name', line_data.unit_name, 'quantity', line_data.quantity, 'unit_total_amount', line_data.unit_total_amount, 'line_total_amount', line_data.line_total_amount) order by line_data.created_at, line_data.id) from public.sales_quote_lines line_data where line_data.quote_id = v_quote.id), '[]'::jsonb),
    'follow_ups', coalesce((select jsonb_agg(jsonb_build_object('id', follow_up.id, 'event_type', follow_up.event_type, 'reason_code', follow_up.reason_code, 'note', follow_up.note, 'created_at', follow_up.created_at, 'actor_name', profile_data.full_name) order by follow_up.created_at desc, follow_up.id desc) from public.sales_quote_follow_ups follow_up left join public.profiles profile_data on profile_data.id = follow_up.created_by where follow_up.quote_id = v_quote.id), '[]'::jsonb),
    'order', (select jsonb_build_object('id', order_data.id, 'folio', order_data.folio, 'status', order_data.status) from public.sales_deposit_orders order_data where order_data.company_id = p_company_id and order_data.source_quote_id = v_quote.id)
  );
end $$;

create or replace function public.approve_sales_quote(p_company_id uuid, p_quote_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_quote public.sales_quotes%rowtype;
  v_branding jsonb;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotizacion no disponible.'; end if;
  if v_quote.status = 'approved' then return public.get_sales_quote_detail(p_company_id, p_quote_id); end if;
  if v_quote.status <> 'draft' then raise exception 'Solo un borrador puede aprobarse.'; end if;
  if v_quote.valid_until is not null and v_quote.valid_until < current_date then raise exception 'Actualiza la vigencia antes de aprobar.'; end if;
  if not exists(select 1 from public.sales_quote_lines where quote_id = p_quote_id) then raise exception 'La cotizacion no tiene partidas.'; end if;

  v_branding := public.get_quote_branding(p_company_id);
  insert into public.sales_quote_document_snapshots(quote_id, company_id, branding, generated_at, generated_by)
  values(p_quote_id, p_company_id, v_branding, clock_timestamp(), auth.uid())
  on conflict(quote_id) do update set branding = excluded.branding, generated_at = excluded.generated_at, generated_by = excluded.generated_by;

  update public.sales_quotes set status = 'approved', approved_at = clock_timestamp(), approved_by = auth.uid(), updated_by = auth.uid() where id = p_quote_id;
  insert into public.sales_quote_follow_ups(company_id, quote_id, event_type, note) values(p_company_id, p_quote_id, 'approved', coalesce(v_note, 'Documento revisado y aprobado.'));
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
  values(p_company_id, auth.uid(), 'sales_quote.approved', 'sales_quote', p_quote_id, jsonb_build_object('document_format', 'react_pdf_a4', 'note', v_note));
  return public.get_sales_quote_detail(p_company_id, p_quote_id);
end $$;

create or replace function public.record_sales_quote_follow_up(p_company_id uuid, p_quote_id uuid, p_event_type text, p_reason_code text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_quote public.sales_quotes%rowtype; v_event text := trim(coalesce(p_event_type, '')); v_reason text := nullif(trim(coalesce(p_reason_code, '')), ''); v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into v_quote from public.sales_quotes where id = p_quote_id and company_id = p_company_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(p_company_id, 'manage_sales_quotes') or not public.can_access_location(v_quote.location_id) then raise exception 'Cotizacion no disponible.'; end if;
  if v_event not in ('sent', 'accepted', 'not_converted', 'note') then raise exception 'Seguimiento no valido.'; end if;
  if v_event = 'sent' and v_quote.status <> 'approved' then raise exception 'Aprueba el documento antes de registrar el envio.'; end if;
  if v_event = 'accepted' and v_quote.status <> 'sent' then raise exception 'La cotizacion debe estar enviada antes de aceptar.'; end if;
  if v_event = 'not_converted' and v_quote.status not in ('draft', 'approved', 'sent') then raise exception 'La cotizacion ya tiene un cierre registrado.'; end if;
  if v_event = 'note' and v_quote.status in ('accepted', 'not_converted') then raise exception 'La cotizacion ya tiene un cierre registrado.'; end if;
  if v_event = 'not_converted' and v_reason not in ('rejected_by_customer', 'cancelled_by_customer', 'lost_to_competition', 'no_follow_up_response', 'other') then raise exception 'Selecciona el motivo por el que no se concreto.'; end if;
  if v_event = 'not_converted' and v_reason = 'other' and v_note is null then raise exception 'Describe el motivo de cierre.'; end if;
  update public.sales_quotes set status = case v_event when 'sent' then 'sent' when 'accepted' then 'accepted' when 'not_converted' then 'not_converted' else status end, updated_by = auth.uid() where id = p_quote_id;
  insert into public.sales_quote_follow_ups(company_id, quote_id, event_type, reason_code, note) values(p_company_id, p_quote_id, v_event, case when v_event = 'not_converted' then v_reason else null end, v_note);
  insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata) values(p_company_id, auth.uid(), 'sales_quote.follow_up_recorded', 'sales_quote', p_quote_id, jsonb_build_object('event_type', v_event, 'reason_code', v_reason, 'note', v_note));
  return public.get_sales_quote_detail(p_company_id, p_quote_id);
end $$;

revoke all on function public.approve_sales_quote(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.approve_sales_quote(uuid, uuid, text) to authenticated;

commit;
