do $$begin
 if(select quantity_on_hand from public.inventory_balances where location_id='81700006-0000-4000-8000-000000000003'and product_id='81700006-0000-4000-8000-000000000011')<>40 then raise exception'El saldo culinario concurrente no quedó en 40.';end if;
 if(select count(*)from public.culinary_sale_consumptions where company_id='81700006-0000-4000-8000-000000000001')<>1 then raise exception'La concurrencia confirmó más de un consumo.';end if;
 if exists(select 1 from public.inventory_balances where company_id='81700006-0000-4000-8000-000000000001'and quantity_on_hand<0)then raise exception'La concurrencia produjo inventario negativo.';end if;
end$$;
