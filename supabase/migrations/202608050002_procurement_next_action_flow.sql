-- Satrapy · Compras sin fricción: ajustar la necesidad antes de cotizar y emitir la OC en una decisión auditada.

create or replace function public.search_procurement_requisitions(
  p_company_id uuid,p_query text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_q text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_procurement') then raise exception 'No autorizado.'; end if;
  with filtered as materialized (
    select r.*,l.name location_name,count(q.id) filter(where q.status='received')::integer as quote_count
    from public.procurement_requisitions r
    join public.locations l on l.id=r.location_id
    left join public.procurement_quotes q on q.requisition_id=r.id
    where r.company_id=p_company_id
      and (p_status is null or r.status=p_status)
      and (v_q='' or lower(r.folio) like '%'||v_q||'%' or lower(l.name) like '%'||v_q||'%')
    group by r.id,l.name
  ), paged as (
    select * from filtered order by created_at desc,id desc limit v_size offset(v_page-1)*v_size
  )
  select (select count(*) from filtered),coalesce(jsonb_agg(to_jsonb(paged) order by created_at desc,id desc),'[]'::jsonb) into v_total,v_items from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0)));
end $$;

create or replace function public.adjust_procurement_requisition_quantities(
  p_company_id uuid,p_requisition_id uuid,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_expected integer;v_received integer;v_changes jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'create_procurement_requisitions') then raise exception 'No autorizado para ajustar la necesidad.'; end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Indica las cantidades a ajustar.'; end if;
  perform 1 from public.procurement_requisitions r where r.id=p_requisition_id and r.company_id=p_company_id and r.status in ('draft','quoting') for update;
  if not found then raise exception 'La necesidad ya no se puede ajustar.'; end if;
  if exists(select 1 from public.procurement_quotes q where q.requisition_id=p_requisition_id) then raise exception 'La necesidad ya tiene cotizaciones; crea una revisión para cambiarla.'; end if;
  select count(*) into v_expected from public.procurement_requisition_lines where requisition_id=p_requisition_id;
  select count(*) into v_received from jsonb_to_recordset(p_lines) input(requisition_line_id uuid,required_quantity numeric);
  if v_received<>v_expected then raise exception 'Incluye una cantidad para cada partida.'; end if;
  if exists(
    select 1 from jsonb_to_recordset(p_lines) input(requisition_line_id uuid,required_quantity numeric)
    left join public.procurement_requisition_lines line on line.id=input.requisition_line_id and line.requisition_id=p_requisition_id
    where line.id is null or input.required_quantity is null or input.required_quantity<=0
  ) then raise exception 'Usa cantidades mayores a cero para las partidas de esta necesidad.'; end if;
  if (select count(distinct input.requisition_line_id) from jsonb_to_recordset(p_lines) input(requisition_line_id uuid,required_quantity numeric))<>v_received then raise exception 'No repitas partidas al ajustar la necesidad.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('requisition_line_id',line.id,'from_quantity',line.required_quantity,'to_quantity',input.required_quantity) order by line.line_number),'[]'::jsonb)
    into v_changes
    from public.procurement_requisition_lines line
    join jsonb_to_recordset(p_lines) input(requisition_line_id uuid,required_quantity numeric) on input.requisition_line_id=line.id
    where line.requisition_id=p_requisition_id;
  update public.procurement_requisition_lines line set required_quantity=input.required_quantity
  from jsonb_to_recordset(p_lines) input(requisition_line_id uuid,required_quantity numeric)
  where line.id=input.requisition_line_id and line.requisition_id=p_requisition_id;
  update public.procurement_requisitions set updated_at=now() where id=p_requisition_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'procurement.requisition_quantities_adjusted','procurement_requisition',p_requisition_id,jsonb_build_object('changes',v_changes));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

create or replace function public.create_procurement_order_from_selection(
  p_company_id uuid,p_requisition_id uuid,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_required integer;v_awarded integer;v_result jsonb;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id,'recommend_procurement_awards')
    or not public.has_company_permission(p_company_id,'approve_procurement_awards') then
    raise exception 'No autorizado para crear la orden de compra desde esta selección.';
  end if;
  perform 1 from public.procurement_requisitions r where r.id=p_requisition_id and r.company_id=p_company_id and r.status='quoting' for update;
  if not found then raise exception 'La necesidad ya no está disponible para crear una orden.'; end if;
  perform public.recommend_procurement_award(p_company_id,p_requisition_id,'Selección preparada desde cotizaciones registradas.',p_lines);
  select count(*) into v_required from public.procurement_requisition_lines where requisition_id=p_requisition_id;
  select count(*) into v_awarded from public.procurement_award_lines award_line join public.procurement_awards award on award.id=award_line.award_id where award.requisition_id=p_requisition_id;
  if v_awarded<>v_required then raise exception 'Selecciona una cotización que cubra cada partida antes de crear la orden.'; end if;
  v_result:=public.approve_procurement_award(p_company_id,p_requisition_id,'Orden creada desde la selección de Compras.');
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'procurement.order_created_from_selection','procurement_requisition',p_requisition_id,jsonb_build_object('line_count',v_awarded));
  return v_result;
end $$;

revoke all on function public.adjust_procurement_requisition_quantities(uuid,uuid,jsonb),public.create_procurement_order_from_selection(uuid,uuid,jsonb) from public,anon;
grant execute on function public.adjust_procurement_requisition_quantities(uuid,uuid,jsonb),public.create_procurement_order_from_selection(uuid,uuid,jsonb) to authenticated;
