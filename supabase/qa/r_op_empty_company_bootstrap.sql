-- R-OP · Empresa QA vacía, sin archivos importados.
-- Ejecutar en Supabase SQL Editor. Es idempotente y no modifica Teza.

do $$
declare
  v_company_id constant uuid := '70f00000-0000-4000-8000-000000000001';
  v_user_id uuid;
  v_role_id uuid;
begin
  select id
  into v_user_id
  from auth.users
  where lower(email) = 'josemilio780@gmail.com'
  limit 1;

  if v_user_id is null then
    raise exception 'No existe el usuario josemilio780@gmail.com en Supabase Auth.';
  end if;

  select id into v_role_id
  from public.roles
  where code = 'direccion_admin';

  if v_role_id is null then
    raise exception 'No existe el rol direccion_admin. Aplica primero las migraciones de Satrapy.';
  end if;

  insert into public.companies(id, legal_name, display_name)
  values(v_company_id, 'Empresa QA R-OP', 'QA R-OP · Sin importaciones')
  on conflict(id) do nothing;

  insert into public.profiles(id, full_name)
  values(
    v_user_id,
    coalesce(
      nullif(trim((select raw_user_meta_data->>'full_name' from auth.users where id = v_user_id)), ''),
      'José Emilio'
    )
  )
  on conflict(id) do nothing;

  insert into public.user_roles(user_id, role_id, company_id, is_active)
  values(v_user_id, v_role_id, v_company_id, true)
  on conflict(user_id, role_id, company_id) do update
  set is_active = true,
      updated_at = clock_timestamp();

  if not exists (
    select 1 from public.audit_log
    where company_id = v_company_id
      and action = 'qa.empty_company_bootstrapped'
      and entity_type = 'company'
      and entity_id = v_company_id
  ) then
    insert into public.audit_log(company_id, actor_id, action, entity_type, entity_id, metadata)
    values(
      v_company_id,
      v_user_id,
      'qa.empty_company_bootstrapped',
      'company',
      v_company_id,
      jsonb_build_object('email', 'josemilio780@gmail.com', 'imports_used', false)
    );
  end if;

  raise notice 'Empresa QA creada: %', v_company_id;
end $$;

