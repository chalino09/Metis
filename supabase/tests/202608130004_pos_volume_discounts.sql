begin;

do $$
declare v_company uuid; v_tier jsonb;
begin
  insert into public.companies(legal_name,display_name) values('Prueba descuentos por volumen','Prueba descuentos por volumen') returning id into v_company;
  v_tier:=public.pos_volume_discount_for_quantity(v_company,10);
  if (v_tier->>'discount_percent')::numeric<>0 then raise exception 'Una empresa nueva no debe recibir descuentos por defecto.'; end if;
  insert into public.pos_volume_discount_tiers(company_id,tier_number,min_quantity,max_quantity,discount_percent) values
    (v_company,1,2,4,3),(v_company,2,5,9,6),(v_company,3,10,null,12);
  v_tier:=public.pos_volume_discount_for_quantity(v_company,1);
  if (v_tier->>'discount_percent')::numeric<>0 then raise exception 'Una pieza no debe tener descuento.'; end if;
  v_tier:=public.pos_volume_discount_for_quantity(v_company,2);
  if (v_tier->>'discount_percent')::numeric<>3 then raise exception '2 piezas deben recibir 3%%.'; end if;
  v_tier:=public.pos_volume_discount_for_quantity(v_company,5);
  if (v_tier->>'discount_percent')::numeric<>6 then raise exception '5 piezas deben recibir 6%%.'; end if;
  v_tier:=public.pos_volume_discount_for_quantity(v_company,10);
  if (v_tier->>'discount_percent')::numeric<>12 then raise exception '10 piezas deben recibir 12%%.'; end if;
  v_tier:=public.pos_volume_discount_for_quantity(v_company,250);
  if (v_tier->>'discount_percent')::numeric<>12 then raise exception 'El nivel 3 debe continuar sin límite superior.'; end if;
end $$;

rollback;
