-- Restaurante · el estado del catálogo también exige disponibilidad comercial
-- en al menos una sucursal. El POS conserva la validación final por ubicación.

begin;

alter function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean)
  rename to search_restaurant_catalog_before_location_readiness;

revoke all on function public.search_restaurant_catalog_before_location_readiness(uuid,text,text,integer,integer,boolean)
  from public,anon,authenticated;

create function public.search_restaurant_catalog(
  p_company_id uuid,
  p_role text default 'dish',
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50,
  p_is_sellable boolean default null
) returns jsonb
language plpgsql
stable
security definer
set search_path=public,extensions
as $$
declare
  v_result jsonb;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_blockers jsonb;
  v_offered_location_count integer;
begin
  v_result:=public.search_restaurant_catalog_before_location_readiness(
    p_company_id,p_role,p_query,p_page,p_page_size,p_is_sellable
  );

  if p_role<>'dish' then return v_result;end if;

  for v_item in select value from jsonb_array_elements(coalesce(v_result->'items','[]'::jsonb)) loop
    select count(distinct assignment.location_id)::integer
    into v_offered_location_count
    from public.sales_assortment_items item
    join public.sales_assortments assortment
      on assortment.id=item.assortment_id
     and assortment.company_id=p_company_id
     and assortment.status='active'
     and (assortment.valid_from is null or assortment.valid_from<=now())
     and (assortment.valid_to is null or assortment.valid_to>now())
    join public.location_sales_assortments assignment
      on assignment.assortment_id=assortment.id
     and assignment.valid_from<=now()
     and (assignment.valid_to is null or assignment.valid_to>now())
    join public.locations location
      on location.id=assignment.location_id
     and location.company_id=p_company_id
     and location.is_active
    where item.product_id=(v_item->>'id')::uuid;

    v_blockers:=coalesce(v_item->'blockers','[]'::jsonb);
    if coalesce(v_offered_location_count,0)=0 and not (v_blockers ? 'outside_assortment') then
      v_blockers:=v_blockers||jsonb_build_array('outside_assortment');
    end if;

    v_item:=v_item||jsonb_build_object(
      'offered_location_count',coalesce(v_offered_location_count,0),
      'blockers',v_blockers,
      'pos_ready',jsonb_array_length(v_blockers)=0
    );
    v_items:=v_items||jsonb_build_array(v_item);
  end loop;

  return jsonb_set(v_result,'{items}',v_items,true);
end$$;

revoke all on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean)
  from public,anon;
grant execute on function public.search_restaurant_catalog(uuid,text,text,integer,integer,boolean)
  to authenticated;

notify pgrst,'reload schema';

commit;
