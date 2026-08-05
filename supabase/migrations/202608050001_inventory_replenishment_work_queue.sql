-- Satrapy · Reabastecimiento como bandeja de seguimiento operativo.
-- Los estados se derivan de transferencias, solicitudes y órdenes existentes;
-- no introduce una entidad ni flags paralelos para el seguimiento.

create or replace function public.list_inventory_replenishment_work_queue(
  p_company_id uuid,
  p_location_id uuid default null,
  p_query text default null,
  p_below_minimum_only boolean default true,
  p_work_status text default 'all',
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_size integer := least(greatest(coalesce(p_page_size, 50), 1), 100);
  v_query text := lower(trim(coalesce(p_query, '')));
  v_work_status text := lower(trim(coalesce(p_work_status, 'all')));
  v_can_view_procurement boolean;
begin
  if auth.uid() is null
    or not (
      public.has_company_permission(p_company_id, 'view_inventory')
      or public.has_company_permission(p_company_id, 'manage_inventory_replenishment')
    ) then
    raise exception 'No autorizado para consultar reabastecimiento.';
  end if;

  if v_work_status not in ('all', 'unattended', 'in_progress', 'in_transit') then
    raise exception 'Estado de seguimiento no válido.';
  end if;

  if p_location_id is not null and not exists (
    select 1
    from public.locations location_data
    where location_data.id = p_location_id
      and location_data.company_id = p_company_id
      and public.can_access_location(location_data.id)
  ) then
    raise exception 'Ubicación no disponible.';
  end if;

  v_can_view_procurement := public.has_company_permission(p_company_id, 'view_procurement');

  return (
    with base as materialized (
      select
        policy.id as policy_id,
        policy.location_id,
        location_data.external_code as location_code,
        location_data.name as location_name,
        policy.product_id,
        coalesce(product.internal_sku, product.alpha_sku) as product_code,
        product.name as product_name,
        product.unit,
        coalesce(balance.quantity_on_hand, 0) as quantity_on_hand,
        policy.minimum_quantity,
        policy.maximum_quantity,
        coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity as is_below_minimum,
        greatest(policy.minimum_quantity - coalesce(balance.quantity_on_hand, 0), 0) as shortage_quantity,
        case when coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity
          then policy.maximum_quantity - coalesce(balance.quantity_on_hand, 0)
          else 0
        end as suggested_quantity,
        policy.updated_at
      from public.inventory_replenishment_policies policy
      join public.products product
        on product.id = policy.product_id
        and product.company_id = p_company_id
      join public.locations location_data
        on location_data.id = policy.location_id
        and location_data.company_id = p_company_id
      left join public.inventory_balances balance
        on balance.location_id = policy.location_id
        and balance.product_id = policy.product_id
      where policy.company_id = p_company_id
        and product.is_active
        and product.is_inventory_tracked
        and public.can_access_location(policy.location_id)
        and (p_location_id is null or policy.location_id = p_location_id)
        and (not p_below_minimum_only or coalesce(balance.quantity_on_hand, 0) < policy.minimum_quantity)
        and (
          v_query = ''
          or lower(product.name) like '%' || v_query || '%'
          or lower(product.alpha_sku) like '%' || v_query || '%'
          or lower(coalesce(product.internal_sku, '')) like '%' || v_query || '%'
        )
    ), tracked as materialized (
      select
        base.*,
        transfer_data.id as transfer_id,
        transfer_data.status as transfer_status,
        requisition_data.id as requisition_id,
        requisition_data.folio as requisition_folio,
        requisition_data.status as requisition_status,
        purchase_data.purchase_order_id,
        purchase_data.purchase_order_folio,
        purchase_data.requisition_id as purchase_requisition_id,
        purchase_data.requisition_folio as purchase_requisition_folio
      from base
      left join lateral (
        select transfer_header.id, transfer_header.status
        from public.inventory_transfer_lines transfer_line
        join public.inventory_transfers transfer_header
          on transfer_header.id = transfer_line.inventory_transfer_id
        where transfer_header.company_id = p_company_id
          and transfer_header.destination_location_id = base.location_id
          and transfer_line.product_id = base.product_id
          and transfer_header.status in ('sent', 'in_transit')
        order by case transfer_header.status when 'in_transit' then 0 else 1 end,
          transfer_header.created_at desc, transfer_header.id desc
        limit 1
      ) transfer_data on base.is_below_minimum
      left join lateral (
        select requisition.id, requisition.folio, requisition.status
        from public.procurement_requisition_lines requisition_line
        join public.procurement_requisitions requisition
          on requisition.id = requisition_line.requisition_id
        where requisition.company_id = p_company_id
          and requisition.location_id = base.location_id
          and requisition.source = 'replenishment'
          and requisition.status in ('draft', 'quoting', 'recommended')
          and requisition_line.product_id = base.product_id
        order by requisition.created_at desc, requisition.id desc
        limit 1
      ) requisition_data on base.is_below_minimum and transfer_data.id is null
      left join lateral (
        select
          purchase_order.id as purchase_order_id,
          purchase_order.folio as purchase_order_folio,
          requisition.id as requisition_id,
          requisition.folio as requisition_folio
        from public.procurement_requisition_lines requisition_line
        join public.procurement_requisitions requisition
          on requisition.id = requisition_line.requisition_id
        join public.procurement_awards award
          on award.requisition_id = requisition.id
        join public.procurement_purchase_orders procurement_order
          on procurement_order.procurement_award_id = award.id
        join public.purchase_orders purchase_order
          on purchase_order.id = procurement_order.purchase_order_id
        join public.purchase_order_lines purchase_line
          on purchase_line.purchase_order_id = purchase_order.id
          and purchase_line.product_id = base.product_id
        where requisition.company_id = p_company_id
          and requisition.location_id = base.location_id
          and requisition.source = 'replenishment'
          and requisition.status = 'approved'
          and requisition_line.product_id = base.product_id
          and purchase_order.status = 'approved'
          and purchase_order.fulfillment_status <> 'fully_received'
        order by purchase_order.ordered_date desc, purchase_order.id desc
        limit 1
      ) purchase_data on base.is_below_minimum and transfer_data.id is null and requisition_data.id is null
    ), classified as materialized (
      select
        tracked.*,
        case
          when not is_below_minimum then 'in_range'
          when transfer_status = 'in_transit' then 'in_transit'
          when purchase_order_id is not null then 'in_transit'
          when transfer_status = 'sent' then 'in_progress'
          when requisition_id is not null then 'in_progress'
          else 'unattended'
        end as work_status,
        case
          when not is_below_minimum then 'En rango'
          when transfer_status = 'in_transit' then 'Transferencia en tránsito'
          when purchase_order_id is not null then 'Compra pendiente de recibir'
          when transfer_status = 'sent' then 'Transferencia por enviar'
          when requisition_status = 'draft' then 'Solicitud creada'
          when requisition_status = 'quoting' then 'En cotización'
          when requisition_status = 'recommended' then 'Por aprobar'
          else 'Sin atender'
        end as work_status_label
      from tracked
    ), filtered as materialized (
      select *
      from classified
      where v_work_status = 'all' or work_status = v_work_status
    ), paged as (
      select
        policy_id, location_id, location_code, location_name, product_id, product_code, product_name, unit,
        quantity_on_hand, minimum_quantity, maximum_quantity, is_below_minimum, shortage_quantity,
        suggested_quantity, updated_at, work_status, work_status_label,
        case when v_can_view_procurement then coalesce(requisition_id, purchase_requisition_id) end as requisition_id,
        case when v_can_view_procurement then coalesce(requisition_folio, purchase_requisition_folio) end as requisition_folio
      from filtered
      order by
        case work_status when 'unattended' then 0 when 'in_progress' then 1 when 'in_transit' then 2 else 3 end,
        shortage_quantity desc,
        location_name,
        product_name,
        product_id
      offset (v_page - 1) * v_size limit v_size
    )
    select jsonb_build_object(
      'total', (select count(*) from filtered),
      'status_counts', jsonb_build_object(
        'unattended', (select count(*) from classified where work_status = 'unattended'),
        'in_progress', (select count(*) from classified where work_status = 'in_progress'),
        'in_transit', (select count(*) from classified where work_status = 'in_transit'),
        'all', (select count(*) from classified where is_below_minimum)
      ),
      'items', coalesce((select jsonb_agg(to_jsonb(paged)) from paged), '[]'::jsonb)
    )
  );
end;
$$;

create or replace function public.generate_procurement_requisition_from_replenishment(
  p_company_id uuid,p_location_id uuid,p_target_date date default null,p_product_ids uuid[] default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_lines jsonb;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'create_procurement_requisitions') then raise exception 'No autorizado para generar necesidades.'; end if;
  if not (public.has_company_permission(p_company_id,'view_inventory') or public.has_company_permission(p_company_id,'manage_inventory_replenishment')) then raise exception 'No autorizado para consultar faltantes.'; end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and public.can_access_location(id)) then raise exception 'Ubicación no disponible.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text || ':' || p_location_id::text, 0));
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
          r.status in ('draft','quoting','recommended') or (r.status='approved' and exists(
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

revoke all on function public.list_inventory_replenishment_work_queue(uuid,uuid,text,boolean,text,integer,integer) from public, anon;
grant execute on function public.list_inventory_replenishment_work_queue(uuid,uuid,text,boolean,text,integer,integer) to authenticated;
