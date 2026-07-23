create or replace function public.assert_purchase_order_line_product()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_origin text;
begin
  select origin into v_origin
  from public.purchase_orders
  where id=new.purchase_order_id and company_id=new.company_id;

  if not found then
    raise exception 'La partida no pertenece a una OC de la empresa.';
  end if;

  if new.product_id is not null and not exists(
    select 1 from public.products p
    where p.id=new.product_id and p.company_id=new.company_id
  ) then
    raise exception 'El producto de la partida no pertenece a la empresa.';
  end if;

  if v_origin='operational' then
    if new.product_id is null then
      raise exception 'Selecciona un producto canónico en cada partida de la OC operativa.';
    end if;
    if not exists(
      select 1 from public.products p
      where p.id=new.product_id
        and p.company_id=new.company_id
        and p.is_active
        and p.is_inventory_tracked
    ) then
      raise exception 'El producto debe estar activo y controlar inventario.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists purchase_order_line_product_guard on public.purchase_order_lines;
create trigger purchase_order_line_product_guard
before insert or update of company_id,purchase_order_id,product_id
on public.purchase_order_lines
for each row execute function public.assert_purchase_order_line_product();

create or replace function public.assert_operational_purchase_order_submission()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.origin='operational'
    and new.status='pending_approval'
    and old.status is distinct from new.status
    and exists(
      select 1
      from public.purchase_order_lines line
      left join public.products product
        on product.id=line.product_id
       and product.company_id=line.company_id
      where line.purchase_order_id=new.id
        and (
          line.product_id is null
          or product.id is null
          or not product.is_active
          or not product.is_inventory_tracked
        )
    )
  then
    raise exception 'La OC operativa contiene partidas sin un producto canónico activo que controle inventario.';
  end if;

  return new;
end;
$$;

drop trigger if exists purchase_order_submission_product_guard on public.purchase_orders;
create trigger purchase_order_submission_product_guard
before update of status on public.purchase_orders
for each row execute function public.assert_operational_purchase_order_submission();

revoke all on function public.assert_purchase_order_line_product() from public,authenticated;
revoke all on function public.assert_operational_purchase_order_submission() from public,authenticated;

