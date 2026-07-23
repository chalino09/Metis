-- Validation-only identity. This database is local and disposable.
insert into auth.users(
  id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'validation-super-admin@example.invalid', '', now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()
) on conflict(id) do nothing;

insert into public.profiles(id, full_name)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Validation Super Admin')
on conflict(id) do update set full_name = excluded.full_name;

insert into public.user_roles(user_id, role_id, company_id)
select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', id, null
from public.roles where code = 'super_admin'
on conflict do nothing;
