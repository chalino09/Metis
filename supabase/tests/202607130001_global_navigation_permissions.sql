begin;

do $$
begin
  if not exists (select 1 from public.permissions where code = 'view_products') then
    raise exception 'Falta el permiso view_products.';
  end if;

  if exists (
    select 1
    from public.roles role_data
    where role_data.code in ('super_admin', 'direccion_admin', 'sucursal', 'ingeniero_campo', 'almacen', 'punto_venta')
      and not exists (
        select 1
        from public.role_permissions assignment
        join public.permissions permission_data on permission_data.id = assignment.permission_id
        where assignment.role_id = role_data.id and permission_data.code = 'view_products'
      )
  ) then
    raise exception 'Un rol de consulta vigente no recibió view_products.';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'products' and policyname = 'products_read'
      and qual like '%view_products%'
  ) then
    raise exception 'La lectura directa de productos no exige view_products.';
  end if;
end;
$$;

rollback;
