-- Metas unificadas: captura temporal, asignación por producto y proyección anual.
begin;

do $installation$
begin
  if to_regprocedure('public.bi_save_budget_plan_draft(uuid,uuid,text,text,text,date,text,uuid,uuid,numeric,text,text,jsonb,jsonb,uuid)')is null then raise exception'Falta guardado transaccional de planes.';end if;
  if to_regprocedure('public.bi_approve_budget_plan(uuid,uuid,text)')is null then raise exception'Falta aprobación transaccional de planes.';end if;
  if to_regprocedure('public.bi_project_budget_plan(uuid,uuid,numeric,text)')is null then raise exception'Falta proyección anual.';end if;
  if has_function_privilege('anon','public.bi_project_budget_plan(uuid,uuid,numeric,text)','execute')then raise exception'anon no debe proyectar metas.';end if;
end;$installation$;

do $fixtures$
declare c uuid:='b3100000-0000-4000-8000-000000000001';u uuid:='b3100000-0000-4000-8000-000000000002';l uuid:='b3100000-0000-4000-8000-000000000003';cat uuid:='b3100000-0000-4000-8000-000000000004';p uuid:='b3100000-0000-4000-8000-000000000005';
begin
  insert into public.companies(id,legal_name,display_name)values(c,'Metas unificadas','Metas unificadas');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','bi-unified@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c from public.roles where code='direccion_admin';
  insert into public.locations(id,company_id,external_code,name,location_type)values(l,c,'SUI','SUISSAL','sucursal');
  insert into public.product_categories(id,company_id,external_code,name)values(cat,c,'ACEROS','Aceros');
  insert into public.products(id,company_id,alpha_sku,name,category_id)values(p,c,'ACE-1','Acero inoxidable',cat);
end;$fixtures$;

set local role authenticated;

do $assertions$
declare c uuid:='b3100000-0000-4000-8000-000000000001';u uuid:='b3100000-0000-4000-8000-000000000002';l uuid:='b3100000-0000-4000-8000-000000000003';cat uuid:='b3100000-0000-4000-8000-000000000004';p uuid:='b3100000-0000-4000-8000-000000000005';
months jsonb;child_months jsonb;plan jsonb;replacement jsonb;root_id uuid;old_root uuid;projected jsonb;projected_id uuid;blocked boolean;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
  select jsonb_agg(jsonb_build_object('month_start',d::date,'value',100)order by d)into months from generate_series(date'2027-01-01',date'2027-12-01',interval'1 month')d;
  select jsonb_agg(jsonb_build_object('month_start',d::date,'value',25)order by d)into child_months from generate_series(date'2027-01-01',date'2027-12-01',interval'1 month')d;
  plan:=public.bi_save_budget_plan_draft(c,null,'Venta SUISSAL 2027',null,'net_sales',date'2027-01-01','location',l,null,1200,'MXN','Planeación anual',months,
    jsonb_build_array(jsonb_build_object('category_id',cat,'product_id',p,'value',300,'monthly_allocations',child_months)),null);
  root_id:=(plan->'version'->>'id')::uuid;
  if(plan->>'assigned_value')::numeric<>300 or(plan->>'pending_value')::numeric<>900 then raise exception'Resumen de asignación incorrecto: %',plan;end if;
  if not exists(select 1 from public.bi_budget_versions where parent_version_id=root_id and scope_type='location_product'and product_id=p and category_id=cat and value=300 and status='draft')then raise exception'No se creó la meta de producto dentro del plan.';end if;
  if jsonb_array_length(public.bi_get_budget_monthly_allocations(c,root_id))<>12 then raise exception'La meta anual no conservó sus 12 meses.';end if;
  perform public.bi_approve_budget_plan(c,root_id,'Plan aprobado por dirección');
  if(select count(*)from public.bi_budget_versions where(id=root_id or parent_version_id=root_id)and status='approved')<>2 then raise exception'La aprobación no incluyó todo el plan.';end if;

  old_root:=root_id;
  replacement:=public.bi_save_budget_plan_draft(c,null,'Venta SUISSAL 2027 ajustada',null,'net_sales',date'2027-01-01','location',l,null,1200,'MXN','Ajuste del plan',months,
    jsonb_build_array(jsonb_build_object('category_id',cat,'product_id',p,'value',300,'monthly_allocations',child_months)),old_root);
  root_id:=(replacement->'version'->>'id')::uuid;perform public.bi_approve_budget_plan(c,root_id,'Sustitución aprobada');
  if exists(select 1 from public.bi_budget_versions where parent_version_id=old_root and status='approved')then raise exception'Las asignaciones anteriores no fueron sustituidas con el plan.';end if;

  blocked:=false;begin perform public.bi_save_budget_plan_draft(c,null,'Duplicada',null,'net_sales',date'2027-01-01','location',l,null,1200,'MXN','Intento duplicado',months,'[]',null);exception when others then blocked:=position('Ya existe esta meta' in sqlerrm)>0;end;
  if not blocked then raise exception'Se permitió una meta anual duplicada para el mismo alcance.';end if;

  projected:=public.bi_project_budget_plan(c,root_id,10,'Crecimiento aprobado 2028');projected_id:=(projected->'version'->>'id')::uuid;
  if(select value from public.bi_budget_versions where id=projected_id)<>1320 then raise exception'La proyección general no aplicó 10%%.';end if;
  if not exists(select 1 from public.bi_budget_versions where parent_version_id=projected_id and product_id=p and value=330 and status='draft')then raise exception'La proyección no conservó la asignación de producto.';end if;
  if(select sum((x->>'value')::numeric)from jsonb_array_elements(public.bi_get_budget_monthly_allocations(c,projected_id))x)<>1320 then raise exception'Los meses proyectados no cuadran con el total.';end if;
end;$assertions$;

reset role;
rollback;
