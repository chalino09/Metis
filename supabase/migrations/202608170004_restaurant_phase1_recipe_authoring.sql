-- Restaurante fase 1 · autoría transaccional de recetas.
-- Volumen: decenas/cientos de recetas y pocos miles de componentes. Una receta
-- completa se guarda en una llamada; cargas iniciales extensas deben importarse.

alter table public.culinary_units enable row level security;
drop policy if exists culinary_units_read on public.culinary_units;
create policy culinary_units_read on public.culinary_units for select to authenticated using(true);

alter table public.culinary_recipe_versions add column updated_at timestamptz not null default now();

create table public.culinary_recipe_requests(
 company_id uuid not null references public.companies(id) on delete cascade,
 client_request_id uuid not null,
 operation text not null check(operation in('save_draft','duplicate')),
 result jsonb not null,
 created_at timestamptz not null default now(),
 primary key(company_id,client_request_id)
);

create or replace function public.culinary_version_cost(p_version_id uuid,p_portions numeric,p_at timestamptz,p_currency_code text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_company uuid;v_method text;v_components jsonb;v_total numeric;v_missing jsonb;
begin
 select r.company_id into v_company from public.culinary_recipe_versions v join public.culinary_recipes r on r.id=v.recipe_id where v.id=p_version_id;
 if v_company is null then raise exception 'Versión de receta no encontrada.';end if;
 select coalesce(cost_method,'replacement_cost') into v_method from public.accounting_event_rule_sets where company_id=v_company and status='approved';v_method:=coalesce(v_method,'replacement_cost');
 with expanded as(select * from public.expand_culinary_recipe(p_version_id,p_portions)),priced as(
  select e.*,p.name,pc.id product_cost_id,pc.amount unit_cost,round(e.quantity*pc.amount,6) amount
  from expanded e join public.products p on p.id=e.ingredient_product_id left join lateral(select * from public.product_costs x where x.company_id=v_company and x.product_id=e.ingredient_product_id and x.cost_type=v_method and x.currency_code=p_currency_code and x.valid_from<=p_at and(x.valid_to is null or x.valid_to>p_at)order by x.valid_from desc,x.id desc limit 1)pc on true)
 select coalesce(jsonb_agg(jsonb_build_object('product_id',ingredient_product_id,'product_name',name,'base_unit_code',base_unit_code,'quantity',quantity,'product_cost_id',product_cost_id,'unit_cost',unit_cost,'cost_amount',amount)order by name,ingredient_product_id),'[]'),round(sum(amount),6),jsonb_agg(ingredient_product_id)filter(where product_cost_id is null)
 into v_components,v_total,v_missing from priced;
 return jsonb_build_object('allowed',v_missing is null,'currency_code',p_currency_code,'total_cost',case when v_missing is null then coalesce(v_total,0)end,'cost_per_portion',case when v_missing is null then round(coalesce(v_total,0)/p_portions,6)end,'components',v_components,'blockers',case when v_missing is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('code','missing_component_cost','message','Completa el costo de todos los ingredientes.','product_ids',v_missing))end);
end$$;

create or replace function public.search_culinary_components(p_company_id uuid,p_query text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,30),1),50);v_query text:=lower(trim(coalesce(p_query,'')));v_items jsonb;v_total bigint;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then raise exception 'No autorizado para consultar ingredientes.';end if;
 with scope as materialized(
  select p.id,p.internal_sku,p.name,p.unit,p.is_inventory_tracked,r.recipe_kind,
   (select count(*) from public.culinary_recipe_components c where c.component_product_id=p.id) usage_count
  from public.products p left join public.culinary_recipes r on r.company_id=p.company_id and r.product_id=p.id
  where p.company_id=p_company_id and p.is_active and(v_query='' or lower(p.name)like'%'||v_query||'%' or lower(p.internal_sku)like'%'||v_query||'%')
 ),paged as(select * from scope order by usage_count desc,name,id limit v_size offset(v_page-1)*v_size)
 select(select count(*)from scope),coalesce(jsonb_agg(to_jsonb(paged)order by usage_count desc,name,id),'[]')into v_total,v_items from paged;
 return jsonb_build_object('items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end$$;

create or replace function public.get_culinary_recipe_context(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;v_recipe public.culinary_recipes%rowtype;v_draft public.culinary_recipe_versions%rowtype;v_active public.culinary_recipe_versions%rowtype;v_currency text;v_price numeric;v_version jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then raise exception 'No autorizado para consultar recetas.';end if;
 select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
 if not found then raise exception 'Platillo no encontrado.';end if;
 select * into v_recipe from public.culinary_recipes where company_id=p_company_id and product_id=p_product_id;
 if found then
  select * into v_draft from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='draft' order by version_number desc limit 1;
  select * into v_active from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='active';
 end if;
 select pp.amount,pp.currency_code into v_price,v_currency from public.product_prices pp join public.price_lists pl on pl.id=pp.price_list_id where pp.product_id=p_product_id and pp.valid_from<=now()and(pp.valid_to is null or pp.valid_to>now())and pl.is_active order by pp.valid_from desc limit 1;
 v_currency:=coalesce(v_currency,(select base_currency_code from public.companies where id=p_company_id),'MXN');
 if v_draft.id is not null then v_version:=to_jsonb(v_draft)||jsonb_build_object('components',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'product_id',p.id,'product_name',p.name,'product_code',p.internal_sku,'entered_quantity',c.entered_quantity,'entered_unit_code',c.entered_unit_code,'base_unit_code',c.base_unit_code,'recipe_kind',r.recipe_kind)order by c.sort_order,p.name),'[]')from public.culinary_recipe_components c join public.products p on p.id=c.component_product_id left join public.culinary_recipes r on r.company_id=p_company_id and r.product_id=p.id where c.recipe_version_id=v_draft.id),'cost',public.culinary_version_cost(v_draft.id,v_draft.portion_count,now(),v_currency));end if;
 return jsonb_build_object('product',jsonb_build_object('id',v_product.id,'name',v_product.name,'code',v_product.internal_sku),'recipe_id',v_recipe.id,'draft',v_version,'active',case when v_active.id is null then null else to_jsonb(v_active)||jsonb_build_object('cost',public.culinary_version_cost(v_active.id,v_active.portion_count,now(),v_currency))end,'sale_price',v_price,'currency_code',v_currency);
end$$;

create or replace function public.save_culinary_recipe_draft(p_company_id uuid,p_product_id uuid,p_recipe_kind text,p_yield_quantity numeric,p_yield_unit_code text,p_portion_count numeric,p_waste_percent numeric,p_components jsonb,p_client_request_id uuid,p_duplicate_from_version_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing jsonb;v_recipe public.culinary_recipes%rowtype;v_version public.culinary_recipe_versions%rowtype;v_component record;v_count integer;v_result jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_recipes') then raise exception 'No autorizado para guardar recetas.';end if;
 if p_client_request_id is null then raise exception 'La llave de la operación es obligatoria.';end if;
 select result into v_existing from public.culinary_recipe_requests where company_id=p_company_id and client_request_id=p_client_request_id;if found then return v_existing||jsonb_build_object('idempotent',true);end if;
 if p_recipe_kind not in('dish','preparation')or p_yield_quantity<=0 or p_portion_count<=0 or p_waste_percent<0 or p_waste_percent>=100 then raise exception 'Completa rendimiento, porciones y merma con valores válidos.';end if;
 if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id and is_active)then raise exception 'Producto no disponible.';end if;
 if jsonb_typeof(coalesce(p_components,'[]'))<>'array' or jsonb_array_length(coalesce(p_components,'[]'))=0 then raise exception 'Agrega al menos un ingrediente.';end if;
 insert into public.culinary_recipes(company_id,product_id,recipe_kind)values(p_company_id,p_product_id,p_recipe_kind)on conflict(company_id,product_id)do update set recipe_kind=excluded.recipe_kind returning*into v_recipe;
 select * into v_version from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='draft' order by version_number desc limit 1 for update;
 if not found then insert into public.culinary_recipe_versions(recipe_id,version_number,yield_quantity,yield_unit_code,portion_count,waste_percent,duplicated_from_id)values(v_recipe.id,coalesce((select max(version_number)+1 from public.culinary_recipe_versions where recipe_id=v_recipe.id),1),p_yield_quantity,lower(p_yield_unit_code),p_portion_count,p_waste_percent,p_duplicate_from_version_id)returning*into v_version;
 else update public.culinary_recipe_versions set yield_quantity=p_yield_quantity,yield_unit_code=lower(p_yield_unit_code),portion_count=p_portion_count,waste_percent=p_waste_percent,updated_at=now()where id=v_version.id returning*into v_version;delete from public.culinary_recipe_components where recipe_version_id=v_version.id;end if;
 for v_component in select * from jsonb_to_recordset(p_components)as x(product_id uuid,quantity numeric,unit_code text,base_unit_code text,notes text,sort_order integer) loop
  if not exists(select 1 from public.products where id=v_component.product_id and company_id=p_company_id and is_active)then raise exception 'Uno de los ingredientes ya no está disponible.';end if;
  insert into public.culinary_recipe_components(recipe_version_id,component_product_id,entered_quantity,entered_unit_code,normalized_quantity,base_unit_code,notes,sort_order)values(v_version.id,v_component.product_id,v_component.quantity,lower(v_component.unit_code),1,lower(v_component.base_unit_code),nullif(trim(v_component.notes),''),coalesce(v_component.sort_order,0));v_count:=coalesce(v_count,0)+1;
 end loop;
 perform public.assert_culinary_recipe_acyclic(v_version.id);
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'culinary_recipe.draft_saved','culinary_recipe_version',v_version.id,jsonb_build_object('product_id',p_product_id,'component_count',v_count,'client_request_id',p_client_request_id));
 v_result:=jsonb_build_object('recipe_id',v_recipe.id,'version_id',v_version.id,'version_number',v_version.version_number,'status','draft','component_count',v_count,'idempotent',false);
 insert into public.culinary_recipe_requests(company_id,client_request_id,operation,result)values(p_company_id,p_client_request_id,case when p_duplicate_from_version_id is null then'save_draft'else'duplicate'end,v_result);
 return v_result;
end$$;

create or replace function public.import_culinary_recipe_batch(p_company_id uuid,p_rows jsonb,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row record;v_count integer:=0;v_results jsonb:='[]'::jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_recipes')then raise exception'No autorizado para importar recetas.';end if;
 if nullif(trim(coalesce(p_reason,'')),'')is null then raise exception'Indica el motivo de la importación.';end if;
 if jsonb_typeof(coalesce(p_rows,'[]'))<>'array'or jsonb_array_length(coalesce(p_rows,'[]'))=0 or jsonb_array_length(p_rows)>500 then raise exception'El lote debe contener entre 1 y 500 recetas.';end if;
 for v_row in select*from jsonb_to_recordset(p_rows)as x(product_id uuid,recipe_kind text,yield_quantity numeric,yield_unit_code text,portion_count numeric,waste_percent numeric,components jsonb,client_request_id uuid)loop
  v_results:=v_results||jsonb_build_array(public.save_culinary_recipe_draft(p_company_id,v_row.product_id,v_row.recipe_kind,v_row.yield_quantity,v_row.yield_unit_code,v_row.portion_count,v_row.waste_percent,v_row.components,v_row.client_request_id,null));v_count:=v_count+1;
 end loop;
 insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)values(p_company_id,auth.uid(),'culinary_recipe.batch_imported','culinary_recipe_batch',jsonb_build_object('recipe_count',v_count,'reason',trim(p_reason)));
 return jsonb_build_object('processed',v_count,'results',v_results);
end$$;

alter table public.culinary_recipe_requests enable row level security;
revoke all on public.culinary_recipe_requests from public,anon,authenticated;
revoke all on function public.search_culinary_components(uuid,text,integer,integer),public.get_culinary_recipe_context(uuid,uuid),public.save_culinary_recipe_draft(uuid,uuid,text,numeric,text,numeric,numeric,jsonb,uuid,uuid),public.import_culinary_recipe_batch(uuid,jsonb,text) from public,anon;
grant execute on function public.search_culinary_components(uuid,text,integer,integer),public.get_culinary_recipe_context(uuid,uuid),public.save_culinary_recipe_draft(uuid,uuid,text,numeric,text,numeric,numeric,jsonb,uuid,uuid),public.import_culinary_recipe_batch(uuid,jsonb,text) to authenticated;
