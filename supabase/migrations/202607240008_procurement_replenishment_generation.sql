-- Satrapy · Generación paginada y auditada de necesidades desde reabastecimiento.
-- No altera surtidos comerciales; sólo convierte faltantes actuales en una necesidad de compra.

create or replace function public.generate_procurement_requisition_from_replenishment(
  p_company_id uuid,p_location_id uuid,p_target_date date default null,p_product_ids uuid[] default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_lines jsonb;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'create_procurement_requisitions') then raise exception 'No autorizado para generar necesidades.'; end if;
  if not (public.has_company_permission(p_company_id,'view_inventory') or public.has_company_permission(p_company_id,'manage_inventory_replenishment')) then raise exception 'No autorizado para consultar faltantes.'; end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and public.can_access_location(id)) then raise exception 'Ubicación no disponible.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('product_id',x.product_id,'quantity',x.suggested_quantity,'suggested_quantity',x.suggested_quantity) order by x.product_id),'[]'::jsonb) into v_lines
  from (
    select policy.product_id,greatest(policy.maximum_quantity-coalesce(balance.quantity_on_hand,0),0) suggested_quantity
    from public.inventory_replenishment_policies policy
    join public.products product on product.id=policy.product_id and product.company_id=p_company_id and product.is_active and product.is_inventory_tracked
    left join public.inventory_balances balance on balance.location_id=policy.location_id and balance.product_id=policy.product_id
    where policy.company_id=p_company_id and policy.location_id=p_location_id and coalesce(balance.quantity_on_hand,0)<policy.minimum_quantity
      and (p_product_ids is null or policy.product_id=any(p_product_ids))
      and not exists(
        select 1 from public.procurement_requisition_lines rl join public.procurement_requisitions r on r.id=rl.requisition_id
        where r.company_id=p_company_id and r.location_id=p_location_id and rl.product_id=policy.product_id and (
          r.status in ('quoting','recommended') or (r.status='approved' and exists(
            select 1 from public.procurement_purchase_orders ppo join public.purchase_orders po on po.id=ppo.purchase_order_id
            join public.purchase_order_lines pol on pol.purchase_order_id=po.id and pol.product_id=rl.product_id
            where ppo.procurement_award_id=(select id from public.procurement_awards where requisition_id=r.id) and po.status='approved' and po.fulfillment_status<>'fully_received'
          ))
        )
      )
  ) x;
  if jsonb_array_length(v_lines)=0 then raise exception 'No hay faltantes nuevos para convertir en necesidad.'; end if;
  v_result:=public.save_procurement_requisition(p_company_id,p_location_id,'replenishment',p_target_date,null,v_lines);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.replenishment_generated','procurement_requisition',(v_result->>'id')::uuid,jsonb_build_object('location_id',p_location_id,'line_count',jsonb_array_length(v_lines)));
  return v_result;
end $$;

revoke all on function public.generate_procurement_requisition_from_replenishment(uuid,uuid,date,uuid[]) from public;
grant execute on function public.generate_procurement_requisition_from_replenishment(uuid,uuid,date,uuid[]) to authenticated;
