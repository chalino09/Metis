-- Etiquetas de rol comprensibles; los códigos y permisos permanecen sin cambio.
update public.roles
set display_name = 'Administrador'
where code = 'direccion_admin';

update public.roles
set display_name = 'Superadmin'
where code = 'super_admin';
