-- Restaurante · corrige clasificaciones heredadas usando únicamente la
-- taxonomía culinaria estándar de Satrapy y expone el rol real en la receta.

begin;

create temp table restaurant_standard_role_repairs on commit drop as
select product.company_id,product.id product_id,role_data.role previous_role,
  case
    when lower(trim(product.product_group)) in ('desayunos','entradas','sopas y ensaladas','platos fuertes','guarniciones','postres','bebidas','otros platillos') then 'dish'
    when lower(trim(product.product_group)) in ('salsas','aderezos','caldos y fondos','marinados','masas','cremas y bases','guarniciones base','otras bases') then 'preparation'
    when lower(trim(product.product_group)) in ('proteínas','frutas y verduras','lácteos y huevos','granos, cereales y harinas','abarrotes y secos','condimentos y especias','congelados','bebidas e insumos líquidos','pan y tortillas','otros insumos') then 'ingredient'
  end expected_role
from public.products product
join public.companies company on company.id=product.company_id and company.product_experience_code='restaurant'
left join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id
where nullif(trim(coalesce(product.product_group,'')),'') is not null;

delete from public.product_culinary_roles role_data
using restaurant_standard_role_repairs repair
where repair.expected_role is not null and role_data.company_id=repair.company_id and role_data.product_id=repair.product_id and role_data.role<>repair.expected_role;

insert into public.product_culinary_roles(company_id,product_id,role,assigned_by,reason)
select distinct company_id,product_id,expected_role,null::uuid,'Reparación por categoría culinaria estándar de Satrapy'
from restaurant_standard_role_repairs where expected_role is not null
on conflict do nothing;

update public.products product
set inventory_policy=case when repair.expected_role='ingredient' then 'tracked' else 'not_required' end,
  is_inventory_tracked=repair.expected_role='ingredient',
  is_sellable=case when repair.expected_role='dish' then product.is_sellable else false end,
  tax_category_id=case when repair.expected_role='dish' then product.tax_category_id else null end,
  unit=case
    when repair.expected_role='dish' then 'piece'
    when repair.expected_role='preparation' then coalesce((
      select version.yield_unit_code from public.culinary_recipes recipe
      join public.culinary_recipe_versions version on version.recipe_id=recipe.id and version.status='active'
      where recipe.company_id=product.company_id and recipe.product_id=product.id and recipe.recipe_kind='preparation'
      order by version.version_number desc limit 1
    ),product.unit)
    else product.unit
  end,
  updated_at=now()
from (select distinct company_id,product_id,expected_role from restaurant_standard_role_repairs where expected_role is not null) repair
where product.company_id=repair.company_id and product.id=repair.product_id;

insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select distinct company_id,null::uuid,'restaurant.culinary_role_repaired_from_standard_category','product',product_id,
  jsonb_build_object('previous_role',previous_role,'role',expected_role,'source','standard_culinary_category')
from restaurant_standard_role_repairs
where expected_role is not null and previous_role is distinct from expected_role;

create or replace function public.restaurant_recipe_version_context(
  p_company_id uuid,p_version_id uuid,p_currency text
)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_version public.culinary_recipe_versions%rowtype;v_cost jsonb;
begin
  if p_version_id is null then return null; end if;
  select version.* into v_version
  from public.culinary_recipe_versions version join public.culinary_recipes recipe on recipe.id=version.recipe_id
  where version.id=p_version_id and recipe.company_id=p_company_id;
  if not found then return null; end if;
  begin
    v_cost:=public.culinary_version_cost(v_version.id,v_version.portion_count,now(),p_currency);
  exception when others then
    v_cost:=jsonb_build_object('allowed',false,'total_cost',null,'cost_per_portion',null,'currency_code',p_currency,'blockers',jsonb_build_array(jsonb_build_object('code','cost_context_unavailable','message','No se pudo calcular el costo; revisa la configuración de costos.')));
  end;
  return to_jsonb(v_version)||jsonb_build_object(
    'components',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',component.id,'product_id',product.id,'product_name',product.name,'product_code',product.internal_sku,
      'entered_quantity',component.entered_quantity,'entered_unit_code',component.entered_unit_code,'base_unit_code',component.base_unit_code,
      'recipe_kind',component_recipe.recipe_kind,'catalog_role',component_role.role
    ) order by component.sort_order,product.name),'[]'::jsonb)
    from public.culinary_recipe_components component
    join public.products product on product.id=component.component_product_id
    left join public.culinary_recipes component_recipe on component_recipe.company_id=p_company_id and component_recipe.product_id=product.id
    left join lateral(select role from public.product_culinary_roles role_data where role_data.company_id=p_company_id and role_data.product_id=product.id order by case role_data.role when 'dish' then 1 when 'preparation' then 2 else 3 end limit 1) component_role on true
    where component.recipe_version_id=v_version.id),
    'cost',v_cost
  );
end $$;

create or replace function public.get_culinary_recipe_context(p_company_id uuid,p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;v_recipe public.culinary_recipes%rowtype;v_draft_id uuid;v_active_id uuid;v_currency text;v_price numeric;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_recipes') then raise exception 'No autorizado para consultar recetas.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
  if not found then raise exception 'Registro culinario no encontrado.'; end if;
  select * into v_recipe from public.culinary_recipes where company_id=p_company_id and product_id=p_product_id;
  if found then
    select id into v_draft_id from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='draft' order by version_number desc limit 1;
    select id into v_active_id from public.culinary_recipe_versions where recipe_id=v_recipe.id and status='active' order by version_number desc limit 1;
  end if;
  select price.amount,price.currency_code into v_price,v_currency
  from public.product_prices price join public.price_lists list on list.id=price.price_list_id
  where price.product_id=p_product_id and price.valid_from<=now() and (price.valid_to is null or price.valid_to>now()) and list.is_active
  order by price.valid_from desc limit 1;
  v_currency:=coalesce(v_currency,(select base_currency_code from public.companies where id=p_company_id),'MXN');
  return jsonb_build_object(
    'product',jsonb_build_object('id',v_product.id,'name',v_product.name,'code',v_product.internal_sku),
    'recipe_id',v_recipe.id,
    'draft',public.restaurant_recipe_version_context(p_company_id,v_draft_id,v_currency),
    'active',public.restaurant_recipe_version_context(p_company_id,v_active_id,v_currency),
    'sale_price',v_price,'currency_code',v_currency
  );
end $$;

revoke all on function public.restaurant_recipe_version_context(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.get_culinary_recipe_context(uuid,uuid) to authenticated;

notify pgrst,'reload schema';
commit;
