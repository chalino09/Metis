begin;

do $$
begin
  if public.restaurant_unit_conversion_factor('mg','mg') <> 1
    or public.restaurant_unit_conversion_factor('g','mg') <> 1000
    or public.restaurant_unit_conversion_factor('kg','mg') <> 1000000
    or public.restaurant_unit_conversion_factor('mg','g') <> 0.001
    or public.restaurant_unit_conversion_factor('kg','g') <> 1000
    or public.restaurant_unit_conversion_factor('mg','kg') <> 0.000001
    or public.restaurant_unit_conversion_factor('g','kg') <> 0.001 then
    raise exception 'La matriz de peso no es exacta.';
  end if;

  if public.restaurant_unit_conversion_factor('ml','ml') <> 1
    or public.restaurant_unit_conversion_factor('l','ml') <> 1000
    or public.restaurant_unit_conversion_factor('ml','l') <> 0.001
    or public.restaurant_unit_conversion_factor('l','l') <> 1 then
    raise exception 'La matriz de volumen no es exacta.';
  end if;

  if public.restaurant_unit_conversion_factor('PZA','piezas') <> 1
    or public.restaurant_unit_conversion_factor('kg','ml') is not null then
    raise exception 'La matriz mezcla dimensiones incompatibles.';
  end if;

  if public.restaurant_purchase_configuration_error('BOTELLA','g',750) is null
    or public.restaurant_purchase_configuration_error('BOTELLA','ml',750) is not null
    or public.restaurant_purchase_configuration_error('SACO','ml',20) is null
    or public.restaurant_purchase_configuration_error('BOLSA','kg',10) is not null
    or public.restaurant_purchase_configuration_error('KG','g',1) is null
    or public.restaurant_purchase_configuration_error('KG','g',1000) is not null
    or public.restaurant_purchase_configuration_error('15','g',15) is null then
    raise exception 'La validación de presentaciones no respeta sus dimensiones.';
  end if;
end $$;

rollback;
