-- Restaurante fase 1 · costeo recursivo, consumo atómico y reversa exacta.

create table public.culinary_sale_item_snapshots(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 sale_item_id uuid not null unique references public.sale_items(id) on delete restrict,
 root_recipe_version_id uuid not null references public.culinary_recipe_versions(id) on delete restrict,
 recognized_unit_cost numeric(18,6) not null check(recognized_unit_cost>=0),
 recognized_cost_amount numeric(18,6) not null check(recognized_cost_amount>=0),
 currency_code text not null check(currency_code~'^[A-Z]{3}$'),
 captured_at timestamptz not null default now()
);

create table public.culinary_sale_item_recipe_versions(
 snapshot_id uuid not null references public.culinary_sale_item_snapshots(id) on delete restrict,
 recipe_version_id uuid not null references public.culinary_recipe_versions(id) on delete restrict,
 depth integer not null check(depth>=0 and depth<=32),
 primary key(snapshot_id,recipe_version_id)
);

create table public.culinary_sale_consumptions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 snapshot_id uuid not null references public.culinary_sale_item_snapshots(id) on delete restrict,
 ingredient_product_id uuid not null references public.products(id) on delete restrict,
 base_unit_code text not null references public.culinary_units(code) on delete restrict,
 quantity numeric(24,9) not null check(quantity>0),
 product_cost_id uuid not null references public.product_costs(id) on delete restrict,
 recognized_unit_cost numeric(18,6) not null check(recognized_unit_cost>=0),
 recognized_cost_amount numeric(18,6) not null check(recognized_cost_amount>=0),
 created_at timestamptz not null default now(),
 unique(snapshot_id,ingredient_product_id)
);

create table public.culinary_sale_consumption_reversals(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 sale_cancellation_id uuid not null references public.sale_cancellations(id) on delete restrict,
 consumption_id uuid not null unique references public.culinary_sale_consumptions(id) on delete restrict,
 quantity numeric(24,9) not null check(quantity>0),
 reversed_at timestamptz not null default now(),
 unique(sale_cancellation_id,consumption_id)
);

alter table public.sale_items add column if not exists recognized_culinary_snapshot_id uuid references public.culinary_sale_item_snapshots(id) on delete restrict;
alter table public.sale_items alter constraint sale_items_recognized_culinary_snapshot_id_fkey deferrable initially deferred;
alter table public.sale_items drop constraint if exists sale_items_recognized_cost_complete;
alter table public.sale_items add constraint sale_items_recognized_cost_complete check(
 (recognized_unit_cost is null and recognized_cost_method is null and recognized_cost_currency_code is null and recognized_product_cost_id is null and recognized_cost_correction_id is null and recognized_culinary_snapshot_id is null)
 or(recognized_unit_cost is not null and recognized_unit_cost>=0 and recognized_cost_method in('replacement_cost','standard_cost','average_cost') and recognized_cost_currency_code~'^[A-Z]{3}$' and num_nonnulls(recognized_product_cost_id,recognized_cost_correction_id,recognized_culinary_snapshot_id)=1)
);

alter table public.inventory_ledger
 add column culinary_consumption_id uuid references public.culinary_sale_consumptions(id) on delete restrict,
 add column culinary_consumption_reversal_id uuid references public.culinary_sale_consumption_reversals(id) on delete restrict;
alter table public.inventory_ledger drop constraint if exists inventory_ledger_movement_type_check,drop constraint if exists inventory_ledger_source_check;
alter table public.inventory_ledger add constraint inventory_ledger_movement_type_check check(movement_type in(
 'opening_snapshot','opening_manual','sale','sale_reversal','sale_return','culinary_sale','culinary_sale_reversal','controlled_adjustment',
 'physical_count_adjustment','transfer_out','transfer_in','purchase_receipt','purchase_receipt_reversal')),
 add constraint inventory_ledger_source_check check(
  (movement_type='opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='opening_manual' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='sale_reversal' and sale_cancellation_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='sale_return' and sale_return_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='culinary_sale' and culinary_consumption_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='culinary_sale_reversal' and culinary_consumption_reversal_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null)
  or(movement_type='controlled_adjustment' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type='physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type in('transfer_out','transfer_in') and inventory_transfer_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
  or(movement_type in('purchase_receipt','purchase_receipt_reversal') and purchase_receipt_line_id is not null and purchase_receipt_id is not null and purchase_order_id is not null and supplier_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null and culinary_consumption_id is null and culinary_consumption_reversal_id is null)
 );
create unique index inventory_ledger_culinary_consumption_once_idx on public.inventory_ledger(culinary_consumption_id) where culinary_consumption_id is not null;
create unique index inventory_ledger_culinary_reversal_once_idx on public.inventory_ledger(culinary_consumption_reversal_id) where culinary_consumption_reversal_id is not null;

create or replace function public.expand_culinary_recipe(p_version_id uuid,p_portions numeric)
returns table(ingredient_product_id uuid,base_unit_code text,quantity numeric)
language sql stable set search_path=public as $$
with recursive tree(product_id,unit_code,required_quantity,child_version_id,path,depth) as(
 select c.component_product_id,c.base_unit_code,
  c.normalized_quantity*p_portions/root.portion_count/(1-root.waste_percent/100),
  child.id,array[p_version_id]::uuid[],0
 from public.culinary_recipe_versions root
 join public.culinary_recipe_components c on c.recipe_version_id=root.id
 left join public.culinary_recipes cr on cr.product_id=c.component_product_id and cr.company_id=(select company_id from public.culinary_recipes where id=root.recipe_id)
 left join public.culinary_recipe_versions child on child.recipe_id=cr.id and child.status='active'
 where root.id=p_version_id
 union all
 select c.component_product_id,c.base_unit_code,
  c.normalized_quantity*(tree.required_quantity/public.normalize_culinary_quantity(child.yield_quantity,child.yield_unit_code,tree.unit_code))/(1-child.waste_percent/100),
  nested.id,tree.path||child.id,tree.depth+1
 from tree join public.culinary_recipe_versions child on child.id=tree.child_version_id
 join public.culinary_recipe_components c on c.recipe_version_id=child.id
 left join public.culinary_recipes cr on cr.product_id=c.component_product_id and cr.company_id=(select company_id from public.culinary_recipes r where r.id=child.recipe_id)
 left join public.culinary_recipe_versions nested on nested.recipe_id=cr.id and nested.status='active'
 where tree.depth<32 and not child.id=any(tree.path)
)
select product_id,unit_code,sum(required_quantity) from tree where child_version_id is null group by product_id,unit_code
$$;

create or replace function public.get_culinary_recipe_cost(p_company_id uuid,p_product_id uuid,p_portions numeric default 1,p_at timestamptz default now(),p_currency_code text default 'MXN')
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_version uuid;v_method text;v_components jsonb;v_total numeric;v_missing jsonb;
begin
 if auth.uid() is not null and not public.has_company_permission(p_company_id,'view_costs') then raise exception 'No autorizado para consultar costos culinarios.';end if;
 if p_portions is null or p_portions<=0 then raise exception 'Las porciones deben ser mayores que cero.';end if;
 select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
 where r.company_id=p_company_id and r.product_id=p_product_id and rv.status='active' and rv.valid_from<=p_at and(rv.valid_to is null or rv.valid_to>p_at);
 if v_version is null then return jsonb_build_object('allowed',false,'blockers',jsonb_build_array(jsonb_build_object('code','missing_active_recipe','message','Agrega y activa una receta.')));end if;
 select coalesce(cost_method,'replacement_cost') into v_method from public.accounting_event_rule_sets where company_id=p_company_id and status='approved';v_method:=coalesce(v_method,'replacement_cost');
 with expanded as(select * from public.expand_culinary_recipe(v_version,p_portions)),priced as(
  select e.*,pc.id product_cost_id,pc.amount unit_cost,round(e.quantity*pc.amount,6) amount
  from expanded e left join lateral(select * from public.product_costs x where x.company_id=p_company_id and x.product_id=e.ingredient_product_id and x.cost_type=v_method and x.currency_code=p_currency_code and x.valid_from<=p_at and(x.valid_to is null or x.valid_to>p_at) order by x.valid_from desc,x.id desc limit 1)pc on true)
 select coalesce(jsonb_agg(jsonb_build_object('product_id',ingredient_product_id,'base_unit_code',base_unit_code,'quantity',quantity,'product_cost_id',product_cost_id,'unit_cost',unit_cost,'cost_amount',amount)order by ingredient_product_id),'[]'),round(sum(amount),6),jsonb_agg(ingredient_product_id)filter(where product_cost_id is null)
 into v_components,v_total,v_missing from priced;
 if v_missing is not null then return jsonb_build_object('allowed',false,'recipe_version_id',v_version,'blockers',jsonb_build_array(jsonb_build_object('code','missing_component_cost','message','Completa el costo de todos los ingredientes.','product_ids',v_missing)),'components',v_components);end if;
 return jsonb_build_object('allowed',true,'recipe_version_id',v_version,'portions',p_portions,'currency_code',p_currency_code,'total_cost',coalesce(v_total,0),'cost_per_portion',round(coalesce(v_total,0)/p_portions,6),'components',v_components);
end$$;

create or replace function public.prepare_culinary_sale_item_cost()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype;v_version uuid;v_cost jsonb;v_method text;v_total numeric;
begin
 select * into v_sale from public.sales where id=new.sale_id;
 select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
 where r.company_id=v_sale.company_id and r.product_id=new.product_id and rv.status='active' and rv.valid_from<=v_sale.completed_at and(rv.valid_to is null or rv.valid_to>v_sale.completed_at);
 if v_version is null then return new;end if;
 if exists(select 1 from public.products where id=new.product_id and is_inventory_tracked) then raise exception 'El platillo % no puede descontarse como producto y receta al mismo tiempo.',new.product_name;end if;
 v_cost:=public.get_culinary_recipe_cost(v_sale.company_id,new.product_id,new.quantity,v_sale.completed_at,v_sale.currency_code);
 if not coalesce((v_cost->>'allowed')::boolean,false) then raise exception 'El platillo % no está listo: %',new.product_name,v_cost->'blockers';end if;
 v_total:=(v_cost->>'total_cost')::numeric;
 select coalesce(cost_method,'replacement_cost') into v_method from public.accounting_event_rule_sets where company_id=v_sale.company_id and status='approved';v_method:=coalesce(v_method,'replacement_cost');
 new.recognized_unit_cost:=round(v_total/new.quantity,6);new.recognized_cost_method:=v_method;new.recognized_cost_currency_code:=v_sale.currency_code;
 new.recognized_product_cost_id:=null;new.recognized_cost_correction_id:=null;new.recognized_culinary_snapshot_id:=gen_random_uuid();
 return new;
end$$;
create trigger sale_items_prepare_culinary_cost before insert on public.sale_items for each row execute function public.prepare_culinary_sale_item_cost();

create or replace function public.consume_culinary_sale_item()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_sale public.sales%rowtype;v_version uuid;v_cost jsonb;v_component record;v_snapshot uuid;v_consumption uuid;v_balance numeric;v_total numeric;
begin
 select * into v_sale from public.sales where id=new.sale_id;
 select rv.id into v_version from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
 where r.company_id=v_sale.company_id and r.product_id=new.product_id and rv.status='active' and rv.valid_from<=v_sale.completed_at and(rv.valid_to is null or rv.valid_to>v_sale.completed_at);
 if v_version is null then return new;end if;
 v_cost:=public.get_culinary_recipe_cost(v_sale.company_id,new.product_id,new.quantity,v_sale.completed_at,v_sale.currency_code);
 if not coalesce((v_cost->>'allowed')::boolean,false) then raise exception 'El platillo % no está listo: %',new.product_name,v_cost->'blockers';end if;
 v_total:=(v_cost->>'total_cost')::numeric;
 v_snapshot:=new.recognized_culinary_snapshot_id;
 insert into public.culinary_sale_item_snapshots(id,company_id,sale_item_id,root_recipe_version_id,recognized_unit_cost,recognized_cost_amount,currency_code)
 values(v_snapshot,v_sale.company_id,new.id,v_version,new.recognized_unit_cost,v_total,v_sale.currency_code);
 with recursive versions(id,depth,path)as(
  select v_version,0,array[v_version]::uuid[] union all
  select child.id,v.depth+1,v.path||child.id from versions v join public.culinary_recipe_components c on c.recipe_version_id=v.id
  join public.culinary_recipes r on r.product_id=c.component_product_id and r.company_id=v_sale.company_id join public.culinary_recipe_versions child on child.recipe_id=r.id and child.status='active'
  where v.depth<32 and not child.id=any(v.path))
 insert into public.culinary_sale_item_recipe_versions(snapshot_id,recipe_version_id,depth) select v_snapshot,id,min(depth) from versions group by id;
 for v_component in select * from jsonb_to_recordset(v_cost->'components')as x(product_id uuid,base_unit_code text,quantity numeric,product_cost_id uuid,unit_cost numeric,cost_amount numeric) order by product_id loop
  select quantity_on_hand into v_balance from public.inventory_balances where company_id=v_sale.company_id and location_id=v_sale.location_id and product_id=v_component.product_id for update;
  if coalesce(v_balance,0)<v_component.quantity then raise exception 'Existencia insuficiente para el ingrediente %.',(select name from public.products where id=v_component.product_id);end if;
  update public.inventory_balances set quantity_on_hand=quantity_on_hand-v_component.quantity,updated_at=now() where company_id=v_sale.company_id and location_id=v_sale.location_id and product_id=v_component.product_id returning quantity_on_hand into v_balance;
  insert into public.culinary_sale_consumptions(company_id,snapshot_id,ingredient_product_id,base_unit_code,quantity,product_cost_id,recognized_unit_cost,recognized_cost_amount)
  values(v_sale.company_id,v_snapshot,v_component.product_id,v_component.base_unit_code,v_component.quantity,v_component.product_cost_id,v_component.unit_cost,v_component.cost_amount) returning id into v_consumption;
  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,culinary_consumption_id,actor_id)
  values(v_sale.company_id,v_sale.location_id,v_component.product_id,-v_component.quantity,v_balance,'culinary_sale',v_consumption,auth.uid());
 end loop;
 return new;
end$$;
create trigger sale_items_consume_culinary_recipe after insert on public.sale_items for each row execute function public.consume_culinary_sale_item();

create or replace function public.reverse_cancelled_culinary_consumptions()
returns trigger language plpgsql security definer set search_path=public as $$
declare v record;v_reversal uuid;v_balance numeric;v_location uuid;
begin
 select location_id into v_location from public.sales where id=new.sale_id;
 for v in select c.* from public.culinary_sale_consumptions c join public.culinary_sale_item_snapshots s on s.id=c.snapshot_id join public.sale_items i on i.id=s.sale_item_id where i.sale_id=new.sale_id order by c.ingredient_product_id for update of c loop
  insert into public.culinary_sale_consumption_reversals(company_id,sale_cancellation_id,consumption_id,quantity) values(new.company_id,new.id,v.id,v.quantity) returning id into v_reversal;
  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(new.company_id,v_location,v.ingredient_product_id,v.quantity)
  on conflict(location_id,product_id)do update set quantity_on_hand=public.inventory_balances.quantity_on_hand+excluded.quantity_on_hand,updated_at=now() returning quantity_on_hand into v_balance;
  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,culinary_consumption_reversal_id,actor_id)
  values(new.company_id,v_location,v.ingredient_product_id,v.quantity,v_balance,'culinary_sale_reversal',v_reversal,auth.uid());
 end loop;
 return new;
end$$;
create trigger sale_cancellations_reverse_culinary after insert on public.sale_cancellations for each row execute function public.reverse_cancelled_culinary_consumptions();

alter table public.culinary_sale_item_snapshots enable row level security;alter table public.culinary_sale_item_recipe_versions enable row level security;alter table public.culinary_sale_consumptions enable row level security;alter table public.culinary_sale_consumption_reversals enable row level security;
create policy culinary_sale_snapshots_read on public.culinary_sale_item_snapshots for select to authenticated using(public.has_company_permission(company_id,'view_costs'));
create policy culinary_sale_versions_read on public.culinary_sale_item_recipe_versions for select to authenticated using(exists(select 1 from public.culinary_sale_item_snapshots s where s.id=snapshot_id and public.has_company_permission(s.company_id,'view_costs')));
create policy culinary_sale_consumptions_read on public.culinary_sale_consumptions for select to authenticated using(public.has_company_permission(company_id,'view_costs'));
create policy culinary_sale_reversals_read on public.culinary_sale_consumption_reversals for select to authenticated using(public.has_company_permission(company_id,'view_costs'));
revoke all on public.culinary_sale_item_snapshots,public.culinary_sale_item_recipe_versions,public.culinary_sale_consumptions,public.culinary_sale_consumption_reversals from public,anon,authenticated;
grant select on public.culinary_sale_item_snapshots,public.culinary_sale_item_recipe_versions,public.culinary_sale_consumptions,public.culinary_sale_consumption_reversals to authenticated;
revoke all on function public.get_culinary_recipe_cost(uuid,uuid,numeric,timestamptz,text) from public,anon;
grant execute on function public.get_culinary_recipe_cost(uuid,uuid,numeric,timestamptz,text) to authenticated;
