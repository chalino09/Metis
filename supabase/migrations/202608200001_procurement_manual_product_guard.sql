-- Satrapy · Protecciones para solicitudes excepcionales de compra.
-- El selector usa búsqueda server-side y la creación conserva idempotencia.

alter table public.procurement_requisitions
  add column if not exists client_request_id uuid;

create unique index if not exists procurement_requisitions_company_request_uidx
  on public.procurement_requisitions(company_id, client_request_id)
  where client_request_id is not null;

create or replace function public.validate_procurement_requisition_product()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.products product
    where product.id = new.product_id
      and product.company_id = new.company_id
      and product.is_active
      and product.is_inventory_tracked
  ) then
    raise exception 'El producto debe estar activo y controlado por inventario.';
  end if;
  return new;
end;
$$;

drop trigger if exists procurement_requisition_product_guard on public.procurement_requisition_lines;
create trigger procurement_requisition_product_guard
before insert or update of product_id on public.procurement_requisition_lines
for each row execute function public.validate_procurement_requisition_product();

create or replace function public.save_procurement_requisition(
  p_company_id uuid,
  p_location_id uuid,
  p_source text,
  p_target_date date,
  p_exception_reason text,
  p_lines jsonb,
  p_client_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id, 'create_procurement_requisitions') then
    raise exception 'No autorizado para crear necesidades.';
  end if;

  if p_client_request_id is null then
    return public.save_procurement_requisition(p_company_id, p_location_id, p_source, p_target_date, p_exception_reason, p_lines);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_client_request_id::text, 0));
  select id into v_id
  from public.procurement_requisitions
  where company_id = p_company_id and client_request_id = p_client_request_id
  for update;

  if v_id is not null then
    return public.get_procurement_requisition(p_company_id, v_id);
  end if;

  v_result := public.save_procurement_requisition(p_company_id, p_location_id, p_source, p_target_date, p_exception_reason, p_lines);
  v_id := (v_result->>'id')::uuid;
  update public.procurement_requisitions
  set client_request_id = p_client_request_id
  where id = v_id and company_id = p_company_id;
  return v_result;
end;
$$;

grant execute on function public.save_procurement_requisition(uuid, uuid, text, date, text, jsonb, uuid) to authenticated;
