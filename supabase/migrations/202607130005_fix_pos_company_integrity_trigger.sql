-- Fixes a shared trigger function so it can safely handle rows from each table.
-- Required after applying 202607130002 in an existing database.

create or replace function public.assert_pos_company_integrity()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_company_id uuid;
begin
  if tg_table_name = 'customers' and (to_jsonb(new) ->> 'price_list_id') is not null then
    select company_id into v_company_id
    from public.price_lists
    where id = (to_jsonb(new) ->> 'price_list_id')::uuid;
    if v_company_id is distinct from new.company_id then
      raise exception 'La lista de precio del cliente debe pertenecer a su empresa.';
    end if;
  elsif tg_table_name = 'locations' and (to_jsonb(new) ->> 'default_price_list_id') is not null then
    select company_id into v_company_id
    from public.price_lists
    where id = (to_jsonb(new) ->> 'default_price_list_id')::uuid;
    if v_company_id is distinct from new.company_id then
      raise exception 'La lista de precio de la ubicación debe pertenecer a su empresa.';
    end if;
  elsif tg_table_name = 'cash_registers' then
    select company_id into v_company_id from public.locations where id = new.location_id;
    if v_company_id is distinct from new.company_id then
      raise exception 'La caja debe pertenecer a la misma empresa que su ubicación.';
    end if;
  end if;
  return new;
end $$;
