-- Almacén administra ubicaciones, pero no puede importar ni consultar auditoría.
-- This is idempotent and applies to projects where the original migration ran.
delete from public.role_permissions rp
using public.roles r, public.permissions p
where rp.role_id = r.id
  and rp.permission_id = p.id
  and r.code = 'almacen'
  and p.code in ('import_data', 'view_import_audit');
