-- Enforce the import-boundary rule for every company and every Alpha batch:
-- placeholder RFCs are never fiscal identities in the canonical master.

create or replace function public.alpha_customer_noncanonical_tax_id(p_tax_id text)
returns boolean language sql immutable parallel safe as $$
  select upper(trim(coalesce(p_tax_id,''))) ~ '^X[A-Z]*010101[0-9]*$'
      or upper(trim(coalesce(p_tax_id,''))) ~ '^XAXX[0-9]+$'
$$;

create or replace function public.canonicalize_alpha_imported_customer_identity()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- Alpha remains source evidence only. A placeholder RFC cannot enter the
  -- canonical master, and imported customers begin as cash customers.
  if new.alpha_external_code is not null then
    if public.alpha_customer_noncanonical_tax_id(new.tax_id) then
      new.tax_id:=null;
    end if;
    new.credit_enabled:=false;
    new.credit_limit:=0;
    new.credit_term_days:=0;
  end if;
  return new;
end $$;

drop trigger if exists customers_canonicalize_alpha_imported_identity on public.customers;
create trigger customers_canonicalize_alpha_imported_identity
before insert or update of tax_id,alpha_external_code,credit_enabled,credit_limit,credit_term_days
on public.customers
for each row execute function public.canonicalize_alpha_imported_customer_identity();

revoke all on function public.alpha_customer_noncanonical_tax_id(text),public.canonicalize_alpha_imported_customer_identity() from public;
