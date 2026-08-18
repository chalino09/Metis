-- Restaurante fase 1 · fundamento culinario canónico.
-- Las cantidades se normalizan a mg, ml o pieza; las unidades de compra sólo
-- describen una conversión auditable hacia una de esas dimensiones.

insert into public.permissions(code,description) values
 ('view_recipes','Consultar recetas, rendimientos, costos y readiness.'),
 ('manage_recipes','Crear borradores y activar versiones de recetas.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin','sucursal')
  and p.code in ('view_recipes','manage_recipes')
on conflict do nothing;

create table public.culinary_units(
 code text primary key,
 display_name text not null,
 dimension text not null check(dimension in('mass','volume','count')),
 factor_to_base numeric(24,9) not null check(factor_to_base>0),
 is_system boolean not null default true,
 check(nullif(trim(code),'') is not null)
);
insert into public.culinary_units(code,display_name,dimension,factor_to_base) values
 ('mg','miligramo','mass',1),('g','gramo','mass',1000),('kg','kilogramo','mass',1000000),
 ('ml','mililitro','volume',1),('l','litro','volume',1000),('piece','pieza','count',1);

create table public.product_purchase_conversions(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict,
 purchase_unit_name text not null check(nullif(trim(purchase_unit_name),'') is not null),
 base_unit_code text not null references public.culinary_units(code) on delete restrict,
 base_quantity numeric(24,9) not null check(base_quantity>0),
 valid_from timestamptz not null default now(),
 valid_to timestamptz,
 created_by uuid references auth.users(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now(),
 check(valid_to is null or valid_to>valid_from),
 exclude using gist(product_id with =,lower(purchase_unit_name) with =,
   tstzrange(valid_from,coalesce(valid_to,'infinity'::timestamptz),'[)') with &&)
);
create index product_purchase_conversions_lookup_idx on public.product_purchase_conversions(company_id,product_id,valid_from desc);

create table public.culinary_recipes(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict,
 recipe_kind text not null check(recipe_kind in('dish','preparation')),
 created_by uuid references auth.users(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now(),
 unique(company_id,product_id)
);

create table public.culinary_recipe_versions(
 id uuid primary key default gen_random_uuid(),
 recipe_id uuid not null references public.culinary_recipes(id) on delete restrict,
 version_number integer not null check(version_number>0),
 status text not null default 'draft' check(status in('draft','active','retired')),
 yield_quantity numeric(24,9) not null check(yield_quantity>0),
 yield_unit_code text not null references public.culinary_units(code) on delete restrict,
 portion_count numeric(18,6) not null check(portion_count>0),
 waste_percent numeric(7,4) not null default 0 check(waste_percent>=0 and waste_percent<100),
 valid_from timestamptz,
 valid_to timestamptz,
 duplicated_from_id uuid references public.culinary_recipe_versions(id) on delete restrict,
 created_by uuid references auth.users(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now(),
 activated_by uuid references auth.users(id) on delete set null,
 activated_at timestamptz,
 unique(recipe_id,version_number),
 check((status='draft' and valid_from is null and activated_at is null) or
       (status in('active','retired') and valid_from is not null and activated_at is not null)),
 check(valid_to is null or valid_to>valid_from)
);
create unique index culinary_recipe_one_active_idx on public.culinary_recipe_versions(recipe_id) where status='active';

create table public.culinary_recipe_components(
 id uuid primary key default gen_random_uuid(),
 recipe_version_id uuid not null references public.culinary_recipe_versions(id) on delete cascade,
 component_product_id uuid not null references public.products(id) on delete restrict,
 entered_quantity numeric(24,9) not null check(entered_quantity>0),
 entered_unit_code text not null references public.culinary_units(code) on delete restrict,
 normalized_quantity numeric(24,9) not null check(normalized_quantity>0),
 base_unit_code text not null references public.culinary_units(code) on delete restrict,
 sort_order integer not null default 0,
 notes text,
 unique(recipe_version_id,component_product_id)
);
create index culinary_recipe_components_product_idx on public.culinary_recipe_components(component_product_id);

create or replace function public.normalize_culinary_quantity(p_quantity numeric,p_unit_code text,p_base_unit_code text)
returns numeric language plpgsql stable set search_path=public as $$
declare u public.culinary_units%rowtype;b public.culinary_units%rowtype;
begin
 if p_quantity is null or p_quantity<=0 then raise exception 'La cantidad debe ser mayor que cero.';end if;
 select * into u from public.culinary_units where code=lower(trim(p_unit_code));
 select * into b from public.culinary_units where code=lower(trim(p_base_unit_code));
 if u.code is null or b.code is null then raise exception 'Unidad culinaria no reconocida.';end if;
 if u.dimension<>b.dimension then raise exception 'Las unidades % y % son dimensionalmente incompatibles.',u.display_name,b.display_name;end if;
 return p_quantity*u.factor_to_base/b.factor_to_base;
end$$;

create or replace function public.guard_culinary_component()
returns trigger language plpgsql set search_path=public as $$
declare v_recipe_product uuid;v_entered_dimension text;v_base_dimension text;
begin
 select r.product_id into v_recipe_product from public.culinary_recipe_versions rv join public.culinary_recipes r on r.id=rv.recipe_id where rv.id=new.recipe_version_id;
 if v_recipe_product=new.component_product_id then raise exception 'Una receta no puede consumirse a sí misma.';end if;
 select dimension into v_entered_dimension from public.culinary_units where code=new.entered_unit_code;
 select dimension into v_base_dimension from public.culinary_units where code=new.base_unit_code;
 if v_entered_dimension is distinct from v_base_dimension then raise exception 'La unidad cotidiana y la unidad base son incompatibles.';end if;
 new.normalized_quantity:=public.normalize_culinary_quantity(new.entered_quantity,new.entered_unit_code,new.base_unit_code);
 return new;
end$$;
create trigger culinary_component_normalize before insert or update on public.culinary_recipe_components for each row execute function public.guard_culinary_component();

create or replace function public.assert_culinary_recipe_acyclic(p_version_id uuid)
returns void language plpgsql stable set search_path=public as $$
declare v_root uuid;v_cycle boolean;
begin
 select recipe_id into v_root from public.culinary_recipe_versions where id=p_version_id;
 if v_root is null then raise exception 'Versión de receta no encontrada.';end if;
 with recursive walk(recipe_id,path,cycle) as(
  select child.id,array[v_root,child.id],child.id=v_root
  from public.culinary_recipe_components c
  join public.culinary_recipe_versions rv on rv.id=c.recipe_version_id
  join public.culinary_recipes child on child.product_id=c.component_product_id and child.company_id=(select company_id from public.culinary_recipes where id=v_root)
  where rv.id=p_version_id
  union all
  select child.id,w.path||child.id,child.id=any(w.path)
  from walk w join public.culinary_recipe_versions active on active.recipe_id=w.recipe_id and active.status='active'
  join public.culinary_recipe_components c on c.recipe_version_id=active.id
  join public.culinary_recipes child on child.product_id=c.component_product_id and child.company_id=(select company_id from public.culinary_recipes where id=v_root)
  where not w.cycle
 ) select coalesce(bool_or(cycle),false) into v_cycle from walk;
 if v_cycle then raise exception 'La receta contiene un ciclo entre preparaciones.';end if;
end$$;

create or replace function public.activate_culinary_recipe_version(p_version_id uuid,p_expected_status text default 'draft')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.culinary_recipe_versions%rowtype;r public.culinary_recipes%rowtype;
begin
 select * into v from public.culinary_recipe_versions where id=p_version_id for update;
 if not found then raise exception 'Versión de receta no encontrada.';end if;
 select * into r from public.culinary_recipes where id=v.recipe_id;
 if not public.has_company_permission(r.company_id,'manage_recipes') then raise exception 'No autorizado para activar recetas.';end if;
 if v.status='active' then return jsonb_build_object('version_id',v.id,'status','active','idempotent',true);end if;
 if v.status<>p_expected_status then raise exception 'La receta cambió; actualiza la vista.';end if;
 if not exists(select 1 from public.culinary_recipe_components where recipe_version_id=v.id) then raise exception 'Agrega al menos un componente antes de activar.';end if;
 perform public.assert_culinary_recipe_acyclic(v.id);
 update public.culinary_recipe_versions set status='retired',valid_to=now() where recipe_id=v.recipe_id and status='active';
 update public.culinary_recipe_versions set status='active',valid_from=now(),activated_at=now(),activated_by=auth.uid() where id=v.id;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
 values(r.company_id,auth.uid(),'culinary_recipe.activated','culinary_recipe_version',v.id,jsonb_build_object('recipe_id',r.id,'version_number',v.version_number));
 return jsonb_build_object('version_id',v.id,'status','active','idempotent',false);
end$$;

create or replace function public.culinary_recipe_readiness(p_company_id uuid,p_product_id uuid,p_at timestamptz default now())
returns jsonb language sql stable set search_path=public as $$
with active as(
 select rv.id,rv.yield_quantity,rv.portion_count from public.culinary_recipes r join public.culinary_recipe_versions rv on rv.recipe_id=r.id
 where r.company_id=p_company_id and r.product_id=p_product_id and rv.status='active' and rv.valid_from<=p_at and (rv.valid_to is null or rv.valid_to>p_at)
), missing_cost as(
 select c.component_product_id from active a join public.culinary_recipe_components c on c.recipe_version_id=a.id
 where not exists(select 1 from public.product_costs pc where pc.company_id=p_company_id and pc.product_id=c.component_product_id and pc.valid_from<=p_at and (pc.valid_to is null or pc.valid_to>p_at))
)
select jsonb_build_object('allowed',exists(select 1 from active) and not exists(select 1 from missing_cost),
 'recipe_version_id',(select id from active),'blockers',
 case when not exists(select 1 from active) then jsonb_build_array(jsonb_build_object('code','missing_active_recipe','message','Agrega y activa una receta.'))
      when exists(select 1 from missing_cost) then jsonb_build_array(jsonb_build_object('code','missing_component_cost','message','Completa el costo de todos los ingredientes.','product_ids',(select jsonb_agg(component_product_id) from missing_cost)))
      else '[]'::jsonb end)
$$;

alter table public.culinary_units enable row level security;
alter table public.product_purchase_conversions enable row level security;
alter table public.culinary_recipes enable row level security;
alter table public.culinary_recipe_versions enable row level security;
alter table public.culinary_recipe_components enable row level security;
create policy product_purchase_conversions_read on public.product_purchase_conversions for select to authenticated using(public.has_company_permission(company_id,'view_recipes'));
create policy culinary_units_read on public.culinary_units for select to authenticated using(true);
create policy culinary_recipes_read on public.culinary_recipes for select to authenticated using(public.has_company_permission(company_id,'view_recipes'));
create policy culinary_recipe_versions_read on public.culinary_recipe_versions for select to authenticated using(exists(select 1 from public.culinary_recipes r where r.id=recipe_id and public.has_company_permission(r.company_id,'view_recipes')));
create policy culinary_recipe_components_read on public.culinary_recipe_components for select to authenticated using(exists(select 1 from public.culinary_recipe_versions rv join public.culinary_recipes r on r.id=rv.recipe_id where rv.id=recipe_version_id and public.has_company_permission(r.company_id,'view_recipes')));
grant select on public.culinary_units,public.product_purchase_conversions,public.culinary_recipes,public.culinary_recipe_versions,public.culinary_recipe_components to authenticated;
revoke all on function public.activate_culinary_recipe_version(uuid,text) from public,anon;
grant execute on function public.activate_culinary_recipe_version(uuid,text),public.culinary_recipe_readiness(uuid,uuid,timestamptz) to authenticated;
