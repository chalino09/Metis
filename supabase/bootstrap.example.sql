-- Run after you create a real user in Supabase Auth and know its UUID.
-- Replace the three values below. This file performs no action by itself.

-- insert into public.companies (legal_name, display_name)
-- values ('Teza Agricultura Sustentable', 'Teza Agricultura Sustentable')
-- returning id;

-- insert into public.user_roles (user_id, role_id, company_id)
-- select '<AUTH_USER_UUID>', r.id, '<COMPANY_UUID>'
-- from public.roles r where r.code = 'super_admin';

-- update public.profiles
-- set default_company_id = '<COMPANY_UUID>'
-- where id = '<AUTH_USER_UUID>';
