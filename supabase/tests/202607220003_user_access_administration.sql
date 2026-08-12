begin;
do $users$
declare
 c uuid:='cf030000-0000-4000-8000-000000000001';admin_user uuid:='cf030000-0000-4000-8000-000000000002';target_user uuid:='cf030000-0000-4000-8000-000000000003';outsider uuid:='cf030000-0000-4000-8000-000000000004';
 l1 uuid:='cf030000-0000-4000-8000-000000000011';l2 uuid:='cf030000-0000-4000-8000-000000000012';r jsonb;r2 jsonb;stamp timestamptz;blocked boolean:=false;
begin
 insert into public.companies(id,legal_name,display_name) values(c,'Usuarios controlados','Usuarios controlados');
 insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,last_sign_in_at) values
  (admin_user,'authenticated','authenticated','admin-users@example.invalid','',now(),now()),
  (target_user,'authenticated','authenticated','operator-users@example.invalid','',now(),null),
  (outsider,'authenticated','authenticated','outsider-users@example.invalid','',now(),now());
 insert into public.locations(id,company_id,external_code,name,location_type,classification_source) values
  (l1,c,'USR-01','Sucursal Uno','sucursal','manual_review'),(l2,c,'USR-02','Sucursal Dos','sucursal','manual_review');
 insert into public.user_roles(user_id,role_id,company_id) select admin_user,id,c from public.roles where code='direccion_admin';
 perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',admin_user::text,true);
 r:=public.get_company_user_access_options(c);
 if not (r->'roles') @> '[{"code":"direccion_admin"},{"code":"sucursal"},{"code":"almacen"},{"code":"ingeniero_campo"}]'::jsonb or (r->'roles') @> '[{"code":"punto_venta"}]'::jsonb or (r->'roles') @> '[{"code":"supervisor_sucursal"}]'::jsonb then raise exception 'Los roles asignables no corresponden al modelo aprobado: %',r;end if;
 r:=public.save_company_user_access(c,target_user,'sucursal',array[l1],'active','Alta de operador',null,'cf030000-0000-4000-8000-000000000021');
 if r->>'role_code'<>'sucursal' or r->>'status'<>'active' then raise exception 'No se creó el acceso de operador: %',r;end if;stamp:=(r->>'updated_at')::timestamptz;
 r2:=public.save_company_user_access(c,target_user,'sucursal',array[l1],'active','Alta de operador',null,'cf030000-0000-4000-8000-000000000021');
 if not coalesce((r2->>'idempotent')::boolean,false) then raise exception 'El reintento no fue idempotente.';end if;
 perform set_config('request.jwt.claim.sub',target_user::text,true);
 if not public.can_access_location(l1) or public.can_access_location(l2) then raise exception 'El alcance por sucursal no quedó aislado.';end if;
 perform set_config('request.jwt.claim.sub',admin_user::text,true);
 r2:=public.save_company_user_access(c,target_user,'ingeniero_campo',array[l2],'active','Cambio de función',stamp,'cf030000-0000-4000-8000-000000000022');
 begin perform public.save_company_user_access(c,target_user,'sucursal',array[l1],'active','Edición atrasada',stamp,'cf030000-0000-4000-8000-000000000023');exception when others then blocked:=position('cambió mientras' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'Una edición concurrente sobrescribió el acceso.';end if;blocked:=false;
 r:=public.list_company_users(c,'operator','ingeniero_campo','invited',1,25);
 if (r->>'total')::int<>1 or r#>>'{items,0,locations,0,id}'<>l2::text then raise exception 'El listado paginado no explicó rol, invitación y alcance: %',r;end if;
 stamp:=(r2->>'updated_at')::timestamptz;
 r:=public.save_company_user_access(c,target_user,'ingeniero_campo',array[l2],'suspended','Baja temporal',stamp,'cf030000-0000-4000-8000-000000000024');
 perform set_config('request.jwt.claim.sub',target_user::text,true);
 if public.has_company_access(c) or public.can_access_location(l2) then raise exception 'El usuario suspendido conserva acceso operativo.';end if;
 perform set_config('request.jwt.claim.sub',admin_user::text,true);
 begin perform public.save_company_user_access(c,admin_user,'direccion_admin','{}'::uuid[],'active','Autocambio',null,'cf030000-0000-4000-8000-000000000025');exception when others then blocked:=position('propio acceso' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'El administrador elevó o modificó su propio acceso.';end if;blocked:=false;
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin perform public.list_company_users(c,null,null,null,1,25);exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'Un usuario ajeno consultó la administración de accesos.';end if;
 if (select count(*) from public.audit_log where company_id=c and action='company.user_access_saved')<>3 then raise exception 'La auditoría no conserva exactamente los cambios aplicados.';end if;
 raise notice 'Usuarios: roles canónicos, alcance, idempotencia, concurrencia, suspensión, auditoría y aislamiento aprobados.';
end;$users$;
rollback;
