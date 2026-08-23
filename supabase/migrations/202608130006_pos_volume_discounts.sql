-- Descuentos automáticos por cantidad. La política es por empresa, se evalúa
-- en servidor y nunca se acumula con un descuento especial de venta.

create table if not exists public.pos_volume_discount_tiers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  tier_number smallint not null check (tier_number between 1 and 3),
  min_quantity numeric(14,4) not null check (min_quantity > 0),
  max_quantity numeric(14,4),
  discount_percent numeric(7,4) not null check (discount_percent > 0 and discount_percent < 100),
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  unique (company_id, tier_number),
  check (max_quantity is null or max_quantity >= min_quantity)
);

alter table public.pos_volume_discount_tiers enable row level security;

drop policy if exists pos_volume_discount_tiers_select on public.pos_volume_discount_tiers;
create policy pos_volume_discount_tiers_select on public.pos_volume_discount_tiers
for select to authenticated using (public.has_company_permission(company_id, 'use_pos') or public.has_company_permission(company_id, 'manage_discount_policies'));

drop trigger if exists companies_seed_pos_volume_discounts on public.companies;
drop function if exists public.seed_pos_volume_discount_tiers_for_company();

create or replace function public.pos_volume_discount_for_quantity(p_company_id uuid,p_quantity numeric)
returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce((select jsonb_build_object('tier_number',tier_number,'min_quantity',min_quantity,'max_quantity',max_quantity,'discount_percent',discount_percent)
    from public.pos_volume_discount_tiers
    where company_id=p_company_id and is_active and p_quantity>=min_quantity and (max_quantity is null or p_quantity<=max_quantity)
    order by discount_percent desc,tier_number desc limit 1),jsonb_build_object('discount_percent',0));
$$;

create or replace function public.apply_pos_volume_discount_to_cart_item()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company_id uuid; v_tier jsonb;
begin
  if new.discount_status <> 'none' then return new; end if;
  select company_id into v_company_id from public.sale_carts where id=new.cart_id;
  v_tier:=public.pos_volume_discount_for_quantity(v_company_id,new.quantity);
  new.discount_percent:=coalesce((v_tier->>'discount_percent')::numeric,0);
  new.discount_reason:=case when new.discount_percent>0 then 'volume:'||(v_tier->>'tier_number') else null end;
  return new;
end $$;

drop trigger if exists sale_cart_items_apply_volume_discount on public.sale_cart_items;
create trigger sale_cart_items_apply_volume_discount before insert or update of quantity,discount_status
on public.sale_cart_items for each row execute function public.apply_pos_volume_discount_to_cart_item();

create or replace function public.sync_pos_volume_discount_after_special()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.sale_discount_status in ('pending','approved') and new.sale_discount_percent>0 then
    update public.sale_cart_items set discount_percent=0,discount_reason=null where cart_id=new.id and discount_status='none';
  elsif old.sale_discount_status in ('pending','approved') and new.sale_discount_status='none' then
    update public.sale_cart_items set quantity=quantity where cart_id=new.id and discount_status='none';
  end if;
  return new;
end $$;

drop trigger if exists sale_carts_sync_volume_after_special on public.sale_carts;
create trigger sale_carts_sync_volume_after_special after update of sale_discount_status,sale_discount_percent
on public.sale_carts for each row execute function public.sync_pos_volume_discount_after_special();

update public.sale_cart_items item
set quantity=item.quantity
from public.sale_carts cart
where item.cart_id=cart.id and cart.status in ('active','held') and item.discount_status='none' and cart.sale_discount_status='none';

create or replace function public.list_pos_volume_discount_tiers(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not (public.has_company_permission(p_company_id,'use_pos') or public.has_company_permission(p_company_id,'manage_discount_policies')) then raise exception 'No autorizado.'; end if;
  return coalesce((select jsonb_agg(to_jsonb(tier) order by tier_number) from public.pos_volume_discount_tiers tier where company_id=p_company_id),'[]'::jsonb);
end $$;

create or replace function public.save_pos_volume_discount_tiers(p_company_id uuid,p_tiers jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_tier record; v_previous_max numeric:=null; v_previous_discount numeric:=0;
begin
  if not public.has_company_permission(p_company_id,'manage_discount_policies') then raise exception 'No autorizado para configurar descuentos.'; end if;
  if jsonb_array_length(coalesce(p_tiers,'[]'::jsonb))<>3 then raise exception 'Configura exactamente tres niveles.'; end if;
  for v_tier in select * from jsonb_to_recordset(p_tiers) as x(tier_number smallint,min_quantity numeric,max_quantity numeric,discount_percent numeric,is_active boolean) order by tier_number loop
    if v_tier.tier_number not between 1 and 3 or v_tier.min_quantity<=0 or v_tier.discount_percent<=0 or v_tier.discount_percent>=100 or (v_tier.max_quantity is not null and v_tier.max_quantity<v_tier.min_quantity) then raise exception 'Revisa cantidades y porcentajes.'; end if;
    if v_previous_max is not null and v_tier.min_quantity<>v_previous_max+1 then raise exception 'Los rangos activos deben ser consecutivos y no traslaparse.'; end if;
    if v_tier.discount_percent<=v_previous_discount then raise exception 'Cada nivel debe ofrecer un descuento mayor al anterior.'; end if;
    v_previous_max:=v_tier.max_quantity; v_previous_discount:=v_tier.discount_percent;
    insert into public.pos_volume_discount_tiers(company_id,tier_number,min_quantity,max_quantity,discount_percent,is_active,updated_at,updated_by)
    values(p_company_id,v_tier.tier_number,v_tier.min_quantity,v_tier.max_quantity,v_tier.discount_percent,coalesce(v_tier.is_active,true),now(),auth.uid())
    on conflict(company_id,tier_number) do update set min_quantity=excluded.min_quantity,max_quantity=excluded.max_quantity,discount_percent=excluded.discount_percent,is_active=excluded.is_active,updated_at=now(),updated_by=auth.uid();
  end loop;
  update public.sale_cart_items item set quantity=item.quantity from public.sale_carts cart where item.cart_id=cart.id and cart.company_id=p_company_id and cart.status in ('active','held') and item.discount_status='none' and cart.sale_discount_status='none';
  perform public.write_sales_audit(p_company_id,'volume_discount.policy_updated','pos_volume_discount_tiers',p_company_id,p_tiers);
  return public.list_pos_volume_discount_tiers(p_company_id);
end $$;

grant execute on function public.list_pos_volume_discount_tiers(uuid) to authenticated;
grant execute on function public.save_pos_volume_discount_tiers(uuid,jsonb) to authenticated;
grant execute on function public.pos_volume_discount_for_quantity(uuid,numeric) to authenticated;
