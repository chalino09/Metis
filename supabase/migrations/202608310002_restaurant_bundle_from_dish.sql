-- Restaurante · el paquete se elige desde el guisado.
-- No crea un producto "Comida completa"; conserva el producto real del menú.

begin;

alter table public.restaurant_menu_bundles
  add column if not exists combo_price_amount numeric(18,2),
  add constraint restaurant_menu_bundles_combo_price_check check (combo_price_amount is null or combo_price_amount > 0);

alter table public.sale_cart_items
  add column if not exists restaurant_bundle_mode text check (restaurant_bundle_mode is null or restaurant_bundle_mode in ('solo','complete')),
  add column if not exists restaurant_bundle_price_amount numeric(18,6) check (restaurant_bundle_price_amount is null or restaurant_bundle_price_amount > 0);

-- Reutiliza la resolución oficial de precios y solo sustituye el precio neto
-- del guisado cuando esa línea fue convertida a comida completa.
alter function public.resolve_pos_sale_price(uuid,uuid,uuid,uuid,timestamptz)
  rename to resolve_pos_sale_price_base;

create or replace function public.resolve_pos_sale_price(
  p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_product_id uuid default null,p_at timestamptz default now()
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_base jsonb;v_cart_id uuid:=nullif(current_setting('satrapy.pos_cart_id',true),'')::uuid;v_bundle_price numeric;
begin
  v_base:=public.resolve_pos_sale_price_base(p_company_id,p_location_id,p_customer_id,p_product_id,p_at);
  if v_base is null or v_cart_id is null or p_product_id is null then return v_base;end if;
  select restaurant_bundle_price_amount into v_bundle_price from public.sale_cart_items where cart_id=v_cart_id and product_id=p_product_id;
  if v_bundle_price is null then return v_base;end if;
  return v_base||jsonb_build_object('amount',round(v_bundle_price,6),'restaurant_bundle_mode','complete');
end$$;

-- Esta función se usa internamente por las operaciones POS; conserva el
-- límite de acceso de la función original y no abre una vía directa al precio.
revoke all on function public.resolve_pos_sale_price(uuid,uuid,uuid,uuid,timestamptz) from public,anon,authenticated;

create or replace function public.get_pos_restaurant_bundle_choice(
  p_cart_id uuid,p_product_id uuid,p_at timestamptz default now()
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_base jsonb;v_bundle public.restaurant_menu_bundles%rowtype;v_solo numeric;v_combo numeric;v_tax_rate numeric;v_cart public.sale_carts%rowtype;
begin
  select * into v_cart from public.sale_carts where id=p_cart_id;
  if not found or v_cart.cashier_id<>auth.uid() then raise exception 'Carrito no disponible.';end if;
  v_base:=public.get_pos_restaurant_bundle(p_cart_id,p_product_id,p_at);
  if not coalesce((v_base->>'configured')::boolean,false) then return v_base;end if;
  select * into v_bundle from public.restaurant_menu_bundles where id=(v_base->>'bundle_id')::uuid;
  select (public.resolve_pos_sale_price_base(v_cart.company_id,v_cart.location_id,v_cart.customer_id,p_product_id,p_at)->>'amount')::numeric into v_solo;
  select rate into v_tax_rate from public.tax_rates where tax_category_id=(select tax_category_id from public.products where id=p_product_id) and valid_from<=p_at and(valid_to is null or valid_to>p_at) order by valid_from desc limit 1;
  v_solo:=round(coalesce(v_solo,0)*(1+coalesce(v_tax_rate,0)),2);
  v_combo:=coalesce(v_bundle.combo_price_amount,80);
  return v_base||jsonb_build_object('solo_price',coalesce(v_solo,0),'combo_price',v_combo);
end$$;

create or replace function public.add_restaurant_bundle_choice(
  p_cart_id uuid,p_product_id uuid,p_mode text,p_selections jsonb default '{}'::jsonb,p_extra_product_ids uuid[] default '{}',p_expected_revision integer default null,p_client_request_id uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_item public.sale_cart_items%rowtype;v_bundle public.restaurant_menu_bundles%rowtype;v_change jsonb;v_revision integer;v_extra uuid;v_tax_rate numeric;v_net_combo numeric;v_base jsonb;
begin
  if p_mode not in ('solo','complete') then raise exception 'Modo de venta inválido.';end if;
  select * into v_cart from public.sale_carts where id=p_cart_id for update;
  if not found or v_cart.cashier_id<>auth.uid() or v_cart.status<>'active' then raise exception 'Carrito no disponible.';end if;
  if p_expected_revision is not null and v_cart.revision<>p_expected_revision then raise exception 'El carrito cambió en otra operación; actualiza la vista.';end if;
  select * into v_bundle from public.restaurant_menu_bundles where company_id=v_cart.company_id and product_id=p_product_id and is_active;
  if not found then raise exception 'Este guisado no tiene configuración de comida completa.';end if;
  select * into v_item from public.sale_cart_items where cart_id=p_cart_id and product_id=p_product_id;
  if found and v_item.restaurant_bundle_mode is not null and v_item.restaurant_bundle_mode<>p_mode then raise exception 'Ese guisado ya está agregado como %; usa la misma modalidad o inicia otra venta.',case when v_item.restaurant_bundle_mode='complete' then 'comida completa' else 'solo' end;end if;
  if p_mode='complete' then
    v_base:=public.get_pos_restaurant_bundle(p_cart_id,p_product_id);
    if jsonb_array_length(coalesce(v_base->'groups','[]'::jsonb))=0 then raise exception 'Configura las opciones de sopa y agua para este guisado.';end if;
    v_change:=public.add_restaurant_bundle_to_cart(p_cart_id,p_product_id,p_selections,p_extra_product_ids,p_expected_revision,p_client_request_id);
    v_revision:=(v_change->>'revision')::integer;
    select rate into v_tax_rate from public.tax_rates where tax_category_id=(select tax_category_id from public.products where id=p_product_id) and valid_from<=now()and(valid_to is null or valid_to>now())order by valid_from desc limit 1;
    select coalesce(v_bundle.combo_price_amount,80)/(1+coalesce(v_tax_rate,0.16)) into v_net_combo;
    update public.sale_cart_items set restaurant_bundle_mode='complete',restaurant_bundle_price_amount=round(v_net_combo,6),updated_at=now()where cart_id=p_cart_id and product_id=p_product_id;
  else
    v_change:=public.change_sale_cart_item(p_cart_id,p_product_id,1,v_cart.revision);v_revision:=(v_change->>'revision')::integer;
    update public.sale_cart_items set restaurant_bundle_mode='solo',restaurant_bundle_price_amount=null,updated_at=now()where cart_id=p_cart_id and product_id=p_product_id;
    foreach v_extra in array coalesce(p_extra_product_ids,'{}') loop
      if not exists(select 1 from public.restaurant_menu_bundle_extras where bundle_id=v_bundle.id and product_id=v_extra and is_active)then raise exception 'El extra no corresponde a este guisado.';end if;
      v_change:=public.change_sale_cart_item(p_cart_id,v_extra,1,v_revision);v_revision:=(v_change->>'revision')::integer;
    end loop;
  end if;
  return public.quote_sale_cart(p_cart_id);
end$$;

-- La misma finalización acepta ahora ambas modalidades: solo no requiere
-- selecciones; completa sí exige una instancia por unidad del guisado.
create or replace function public.complete_pos_sale(
  p_cart_id uuid,p_expected_revision integer,p_sale_type text,p_payment_method_id uuid default null,p_received_amount numeric default null,p_client_request_id uuid default null,p_payment_reference text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_cart public.sale_carts%rowtype;v_method public.payment_methods%rowtype;v_reference text:=nullif(trim(coalesce(p_payment_reference,'')),'');v_result jsonb;v_ticket_payload jsonb;v_parent record;v_instance record;v_selection record;v_component_sale_item_id uuid;v_sale_id uuid;v_parent_sale_item_id uuid;v_expected integer;v_actual integer;v_balance numeric;
begin
 select * into v_cart from public.sale_carts where id=p_cart_id and cashier_id=auth.uid();if not found then raise exception 'Carrito no disponible.';end if;
 for v_parent in select i.id cart_item_id,i.product_id,i.quantity,coalesce(i.restaurant_bundle_mode,'complete') bundle_mode,b.id bundle_id from public.sale_cart_items i join public.restaurant_menu_bundles b on b.product_id=i.product_id and b.company_id=v_cart.company_id and b.is_active where i.cart_id=p_cart_id loop
   select count(*) into v_actual from public.sale_cart_bundle_instances where cart_item_id=v_parent.cart_item_id;
   v_expected:=case when v_parent.bundle_mode='complete' then v_parent.quantity::integer else 0 end;
   if v_actual<>v_expected then raise exception 'Completa las elecciones de cada comida antes de cobrar.';end if;
 end loop;
 if p_sale_type='cash'then select*into v_method from public.payment_methods where id=p_payment_method_id and company_id=v_cart.company_id and is_active;if not found then raise exception 'Forma de pago no disponible.';end if;if v_method.settlement_kind='external'and v_reference is null then raise exception 'Captura la autorización o referencia del cobro externo.';end if;else v_reference:=null;end if;
 perform set_config('satrapy.pos_payment_reference',coalesce(v_reference,''),true);perform set_config('satrapy.pos_price_list_id',coalesce(v_cart.price_list_id::text,''),true);perform set_config('satrapy.pos_cart_id',v_cart.id::text,true);
 v_result:=public.complete_sale(p_cart_id,p_expected_revision,p_sale_type,p_payment_method_id,p_received_amount,p_client_request_id);v_sale_id:=(v_result->>'sale_id')::uuid;
 if not coalesce((v_result->>'idempotent')::boolean,false)then
  for v_instance in select i.* from public.sale_cart_bundle_instances i join public.sale_cart_items ci on ci.id=i.cart_item_id where ci.cart_id=p_cart_id order by i.created_at,i.id loop
   select si.id into v_parent_sale_item_id from public.sale_items si join public.sale_cart_items ci on ci.product_id=si.product_id where si.sale_id=v_sale_id and ci.id=v_instance.cart_item_id;
   insert into public.sale_item_bundle_instances(id,company_id,sale_item_id,bundle_id)values(v_instance.id,v_instance.company_id,v_parent_sale_item_id,v_instance.bundle_id);
    for v_selection in select s.*,g.name group_name,p.name product_name,p.internal_sku,p.alpha_sku,p.unit,p.tax_category_id,p.is_inventory_tracked from public.sale_cart_bundle_selections s join public.restaurant_menu_bundle_groups g on g.id=s.group_id join public.products p on p.id=s.product_id where s.instance_id=v_instance.id order by g.sort_order,p.name loop
    if not coalesce((public.validate_pos_product_for_location(v_cart.company_id,v_cart.location_id,v_selection.product_id)->>'allowed')::boolean,false)then raise exception 'La opción % ya no está disponible.',v_selection.product_name;end if;
    insert into public.sale_items(sale_id,product_id,product_code,product_name,unit_name,quantity,unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount)values(v_sale_id,v_selection.product_id,coalesce(v_selection.internal_sku,v_selection.alpha_sku),v_selection.product_name,v_selection.unit,v_selection.quantity,0,0,0,0,0,0,0)returning id into v_component_sale_item_id;
    insert into public.sale_item_taxes(sale_item_id,tax_category_id,tax_category_code,rate,tax_amount)select v_component_sale_item_id,t.id,t.code,0,0 from public.tax_categories t where t.id=v_selection.tax_category_id;
    if v_selection.is_inventory_tracked then
      select quantity_on_hand into v_balance from public.inventory_balances where company_id=v_cart.company_id and location_id=v_cart.location_id and product_id=v_selection.product_id for update;
      if coalesce(v_balance,0)<v_selection.quantity then raise exception 'Existencia insuficiente para %.',v_selection.product_name;end if;
      update public.inventory_balances set quantity_on_hand=quantity_on_hand-v_selection.quantity,updated_at=now() where company_id=v_cart.company_id and location_id=v_cart.location_id and product_id=v_selection.product_id returning quantity_on_hand into v_balance;
      insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,sale_item_id,actor_id)values(v_cart.company_id,v_cart.location_id,v_selection.product_id,-v_selection.quantity,v_balance,'sale',v_component_sale_item_id,auth.uid());
    end if;
    insert into public.sale_item_bundle_selections(company_id,instance_id,group_name,product_id,product_name,quantity,component_sale_item_id)values(v_cart.company_id,v_instance.id,v_selection.group_name,v_selection.product_id,v_selection.product_name,v_selection.quantity,v_component_sale_item_id);
   end loop;
  end loop;
 end if;
 select ticket.payload into v_ticket_payload from public.canonical_tickets ticket where ticket.id=(v_result->>'ticket_id')::uuid;
 if v_ticket_payload is not null then
  select jsonb_set(v_ticket_payload,'{items}',coalesce(jsonb_agg(item_payload order by ordinal),'[]'::jsonb),true) into v_ticket_payload from(select ordinal,item_payload||case when x.selections is null then '{}'::jsonb else jsonb_build_object('selections',x.selections)end item_payload from jsonb_array_elements(v_ticket_payload->'items')with ordinality t(item_payload,ordinal)left join lateral(select jsonb_agg(jsonb_build_object('group',s.group_name,'name',s.product_name,'quantity',s.quantity)order by s.group_name,s.product_name)selections from public.sale_item_bundle_instances i join public.sale_item_bundle_selections s on s.instance_id=i.id join public.sale_items si on si.id=i.sale_item_id where si.sale_id=v_sale_id and si.product_code=t.item_payload->>'product_code')x on true)q;
  update public.canonical_tickets set payload=v_ticket_payload,content_sha256=encode(digest(v_ticket_payload::text,'sha256'),'hex')where id=(v_result->>'ticket_id')::uuid;v_result:=jsonb_set(v_result,'{ticket}',v_ticket_payload,true);
 end if;
 return v_result;
end$$;

revoke all on function public.get_pos_restaurant_bundle_choice(uuid,uuid,timestamptz),public.add_restaurant_bundle_choice(uuid,uuid,text,jsonb,uuid[],integer,uuid) from public,anon;
grant execute on function public.get_pos_restaurant_bundle_choice(uuid,uuid,timestamptz),public.add_restaurant_bundle_choice(uuid,uuid,text,jsonb,uuid[],integer,uuid) to authenticated;

commit;
