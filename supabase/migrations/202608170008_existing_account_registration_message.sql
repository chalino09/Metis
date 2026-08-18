-- Satrapy · Distingue una cuenta existente de un correo sin autorización pendiente.

create or replace function public.prepare_pending_user_registration(p_email text)
returns jsonb language plpgsql stable security definer set search_path=public,auth as $$
declare v_email text:=lower(trim(p_email));v_user auth.users%rowtype;v_count integer;
begin
  if auth.role()<>'service_role' then raise exception 'Operación reservada al servidor.';end if;
  select * into v_user from auth.users where lower(email)=v_email limit 1;
  if found and coalesce((v_user.raw_user_meta_data->>'registration_pending')::boolean,false)=false then
    return jsonb_build_object('allowed',false,'already_registered',true);
  end if;
  select count(*) into v_count from public.company_user_invitations where lower(email)=v_email and status='pending';
  if v_count=0 then return jsonb_build_object('allowed',false);end if;
  return jsonb_build_object('allowed',true,'user_id',v_user.id,'company_count',v_count);
end $$;

revoke all on function public.prepare_pending_user_registration(text) from public;
grant execute on function public.prepare_pending_user_registration(text) to service_role;
