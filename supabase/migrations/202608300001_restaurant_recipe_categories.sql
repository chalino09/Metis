-- Restaurante · reemplaza la categoría técnica de la importación por categorías culinarias.
-- Sólo toca registros que todavía conservan el marcador de importación.

begin;

create temp table restaurant_recipe_category_repairs on commit drop as
select product.company_id,product.id product_id,role_data.role,
  product.product_group previous_category,
  case role_data.role
    when 'dish' then 'Platos fuertes'
    when 'preparation' then 'Salsas'
    when 'ingredient' then case lower(trim(product.name))
      when 'aceite de oliva' then 'Abarrotes y secos'
      when 'ajo' then 'Frutas y verduras'
      when 'bistec de puerco' then 'Proteínas'
      when 'canela' then 'Condimentos y especias'
      when 'carne molida puerco' then 'Proteínas'
      when 'chile de arbol' then 'Condimentos y especias'
      when 'chile morita' then 'Condimentos y especias'
      when 'chipotle' then 'Condimentos y especias'
      when 'cilanto' then 'Frutas y verduras'
      when 'clavo' then 'Condimentos y especias'
      when 'comino' then 'Condimentos y especias'
      when 'costilla de puerco' then 'Proteínas'
      when 'harina' then 'Granos, cereales y harinas'
      when 'lentejas' then 'Granos, cereales y harinas'
      when 'mole' then 'Abarrotes y secos'
      when 'nopales' then 'Frutas y verduras'
      when 'oregano rama fresca' then 'Condimentos y especias'
      when 'pan molido' then 'Granos, cereales y harinas'
      when 'pechuga pollo' then 'Proteínas'
      when 'pimienta' then 'Condimentos y especias'
      when 'pollo pierna y muslo' then 'Proteínas'
      when 'queso panela' then 'Lácteos y huevos'
      when 'sal' then 'Condimentos y especias'
      when 'salsa inglesa' then 'Abarrotes y secos'
      when 'salsa maggi' then 'Abarrotes y secos'
      when 'tocino' then 'Proteínas'
      when 'tomate' then 'Frutas y verduras'
      else 'Otros insumos'
    end
  end category
from public.products product
join public.companies company on company.id=product.company_id and company.product_experience_code='restaurant'
join public.product_culinary_roles role_data on role_data.company_id=product.company_id and role_data.product_id=product.id
where lower(trim(coalesce(product.product_group,'')))='importado de recetas'
  and role_data.role in ('dish','preparation','ingredient');

update public.products product
set product_group=repair.category,updated_at=now()
from restaurant_recipe_category_repairs repair
where product.company_id=repair.company_id and product.id=repair.product_id;

insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
select company_id,null::uuid,'restaurant.recipe_import_category_repaired','product',product_id,
  jsonb_build_object('role',role,'previous_category',previous_category,'category',category,'source','restaurant_recipe_import')
from restaurant_recipe_category_repairs;

notify pgrst,'reload schema';
commit;
