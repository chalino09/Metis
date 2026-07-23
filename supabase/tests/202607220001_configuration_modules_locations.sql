begin;
do $configuration$
declare
 c uuid:='cf000000-0000-4000-8000-000000000001';admin_user uuid:='cf000000-0000-4000-8000-000000000002';branch_user uuid:='cf000000-0000-4000-8000-000000000003';outsider uuid:='cf000000-0000-4000-8000-000000000004';
 location_id uuid;empty_location uuid;product_id uuid;r jsonb;r2 jsonb;stamp timestamptz;blocked boolean:=false;
begin
 insert into public.companies(id,legal_name,display_name) values(c,'Configuración controlada','Configuración controlada');
 insert into auth.users(id,aud,role,email,encrypted_password) values(admin_user,'authenticated','authenticated','admin-config@example.com',''),(branch_user,'authenticated','authenticated','branch-config@example.com',''),(outsider,'authenticated','authenticated','outside-config@example.com','');
 insert into public.user_roles(user_id,role_id,company_id) select admin_user,id,c from public.roles where code='direccion_admin' union all select branch_user,id,c from public.roles where code='sucursal';
 perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',admin_user::text,true);

 r:=public.save_company_location(c,null,' suc-01 ','Sucursal Centro','sucursal',true,'Apertura aprobada',null,'cf000000-0000-4000-8000-000000000010');location_id:=(r->>'id')::uuid;
 if r->>'external_code'<>'SUC-01' or coalesce((r->>'idempotent')::boolean,true) then raise exception 'La creación canónica de sucursal falló: %',r;end if;
 r2:=public.save_company_location(c,null,' suc-01 ','Sucursal Centro','sucursal',true,'Apertura aprobada',null,'cf000000-0000-4000-8000-000000000010');
 if not coalesce((r2->>'idempotent')::boolean,false) or (r2->>'id')::uuid<>location_id then raise exception 'La creación de sucursal no fue idempotente.';end if;
 r:=public.list_company_locations(c,'centro','sucursal','active',1,25);
 if (r->>'total')::int<>1 or r#>>'{items,0,name}'<>'Sucursal Centro' then raise exception 'El listado paginado o la búsqueda fallaron: %',r;end if;

 insert into public.products(company_id,alpha_sku,name) values(c,'P-CFG','Producto controlado') returning id into product_id;
 insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(c,location_id,product_id,10);
 select updated_at into stamp from public.locations where id=location_id;
 begin perform public.save_company_location(c,location_id,'SUC-01','Sucursal Centro','sucursal',false,'Cierre de sucursal',stamp,'cf000000-0000-4000-8000-000000000011');exception when others then blocked:=position('inventario' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'Se desactivó una sucursal con inventario.';end if;blocked:=false;

 r:=public.save_company_location(c,null,'SUC-02','Sucursal Temporal','sucursal',true,'Alta temporal',null,'cf000000-0000-4000-8000-000000000012');empty_location:=(r->>'id')::uuid;
 select updated_at into stamp from public.locations where id=empty_location;
 r:=public.save_company_location(c,empty_location,'SUC-02','Sucursal Temporal','sucursal',false,'Cierre sin operación',stamp,'cf000000-0000-4000-8000-000000000013');
 if (r->>'is_active')::boolean then raise exception 'No se desactivó una sucursal sin operación.';end if;
 begin perform public.save_company_location(c,empty_location,'SUC-02','Nombre atrasado','sucursal',false,'Edición atrasada',stamp,'cf000000-0000-4000-8000-000000000014');exception when others then blocked:=position('cambió mientras' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'La concurrencia sobrescribió una edición posterior.';end if;blocked:=false;

 r:=public.get_initial_migration_readiness(c);
 if jsonb_array_length(r->'steps')<6 or not coalesce((r#>>'{steps,0,ready}')::boolean,false) then raise exception 'La ruta inicial no explica el avance existente: %',r;end if;
 perform set_config('request.jwt.claim.sub',branch_user::text,true);
 begin perform public.list_company_locations(c,null,null,null,1,25);exception when others then blocked:=position('no autorizado' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'Un rol de sucursal administró la estructura empresarial.';end if;blocked:=false;
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 begin perform public.get_initial_migration_readiness(c);exception when others then blocked:=position('no disponible' in lower(sqlerrm))>0;end;
 if not blocked then raise exception 'Un usuario ajeno consultó la migración inicial.';end if;
 if (select count(*) from public.audit_log where company_id=c and action='company.location_saved')<>3 then raise exception 'La auditoría de sucursales no conserva exactamente los cambios aplicados.';end if;
 raise notice 'Configuración: paginación, búsqueda, idempotencia, concurrencia, bloqueo operativo, auditoría y aislamiento aprobados.';
end;$configuration$;
rollback;
