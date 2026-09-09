begin;
do $test$
declare
  v_actor uuid; v_company uuid:=gen_random_uuid(); v_supplier jsonb; v_id uuid;
  v_rejected boolean:=false;
begin
  select ur.user_id into v_actor from public.user_roles ur join public.roles r on r.id=ur.role_id where r.code='super_admin' limit 1;
  if v_actor is null then raise exception 'La prueba requiere Super Admin.';end if;
  insert into public.companies(id,legal_name,display_name) values(v_company,'Prueba RFC opcional','Prueba RFC opcional');
  insert into public.user_roles(user_id,role_id,company_id) select v_actor,id,v_company from public.roles where code='super_admin';
  perform set_config('request.jwt.claim.role','authenticated',true);
  perform set_config('request.jwt.claim.sub',v_actor::text,true);
  v_supplier:=public.save_supplier_v3(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Proveedor fisico sin RFC',p_legal_entity_type=>'physical',p_fiscal_postal_code=>'50000',p_email=>'prueba@example.com',p_is_active=>true,p_prompt_payment_terms=>'[{"tier_number":1,"term_days":10,"discount_components":[5]}]'::jsonb);
  v_id:=(v_supplier->>'id')::uuid;
  if not (v_supplier->>'is_active')::boolean or v_supplier->>'tax_id' is not null or v_supplier->>'tax_regime' is not null then raise exception 'No se guardó activo sin RFC y régimen.';end if;
  v_supplier:=public.save_supplier_v2(p_company_id=>v_company,p_supplier_id=>v_id,p_display_name=>'Proveedor fisico sin RFC',p_legal_entity_type=>'physical',p_fiscal_postal_code=>'50000',p_email=>'prueba@example.com',p_is_active=>true);
  if not exists(select 1 from public.supplier_prompt_payment_terms where supplier_id=v_id and term_days=10) then raise exception 'Se perdieron condiciones ocultas al editar.';end if;
  v_supplier:=public.save_supplier_v3(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'Proveedor moral sin RFC',p_legal_name=>'Proveedor moral SA',p_legal_entity_type=>'moral',p_fiscal_postal_code=>'50000',p_email=>'prueba@example.com',p_is_active=>true);
  if not (v_supplier->>'is_active')::boolean or v_supplier->>'tax_id' is not null then raise exception 'No se guardó persona moral sin RFC.';end if;
  begin
    perform public.save_supplier_v3(p_company_id=>v_company,p_supplier_id=>null,p_display_name=>'RFC incorrecto',p_legal_entity_type=>'physical',p_tax_id=>'INVALIDO',p_fiscal_postal_code=>'50000',p_email=>'prueba@example.com');
  exception when others then v_rejected:=position('RFC' in sqlerrm)>0;end;
  if not v_rejected then raise exception 'Se permitió un RFC incorrecto.';end if;
  raise notice 'PASS: física y moral sin RFC ni régimen; RFC inválido rechazado; condiciones ocultas conservadas.';
end $test$;
rollback;
