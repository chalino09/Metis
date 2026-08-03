-- Metas unificadas: una meta anual con captura anual, trimestral o mensual.
-- Las asignaciones por categoría o producto se guardan y aprueban con el plan.

alter table public.bi_budget_versions
  add column if not exists product_id uuid references public.products(id) on delete restrict;

do $constraints$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid='public.bi_budget_versions'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%scope_type%'
  loop
    execute format('alter table public.bi_budget_versions drop constraint %I',r.conname);
  end loop;
end;$constraints$;

alter table public.bi_budget_versions
  add constraint bi_budget_versions_scope_type_check check(scope_type in(
    'company','location','responsible','category','location_category','responsible_category',
    'product','location_product','responsible_product'
  )),
  add constraint bi_budget_versions_scope_identity_check check(
    (scope_type='company' and location_id is null and collaborator_id is null and category_id is null and product_id is null)
    or(scope_type='location' and location_id is not null and collaborator_id is null and category_id is null and product_id is null)
    or(scope_type='responsible' and location_id is null and collaborator_id is not null and category_id is null and product_id is null)
    or(scope_type='category' and location_id is null and collaborator_id is null and category_id is not null and product_id is null)
    or(scope_type='location_category' and location_id is not null and collaborator_id is null and category_id is not null and product_id is null)
    or(scope_type='responsible_category' and location_id is null and collaborator_id is not null and category_id is not null and product_id is null)
    or(scope_type='product' and location_id is null and collaborator_id is null and category_id is not null and product_id is not null)
    or(scope_type='location_product' and location_id is not null and collaborator_id is null and category_id is not null and product_id is not null)
    or(scope_type='responsible_product' and location_id is null and collaborator_id is not null and category_id is not null and product_id is not null)
  );

drop index if exists public.bi_budget_versions_scope_idx;
create index bi_budget_versions_scope_idx
  on public.bi_budget_versions(company_id,metric_code,scope_type,location_id,collaborator_id,category_id,product_id,period_start,period_end);

create or replace function public.bi_validate_budget_product()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.product_id is not null and not exists(
    select 1 from public.products p
    where p.id=new.product_id and p.company_id=new.company_id and p.category_id=new.category_id
  )then raise exception'El producto canónico no pertenece a la empresa y categoría seleccionadas.';end if;
  return new;
end$$;

drop trigger if exists bi_validate_budget_product_trigger on public.bi_budget_versions;
create trigger bi_validate_budget_product_trigger before insert or update on public.bi_budget_versions
for each row execute function public.bi_validate_budget_product();

create or replace function public.bi_save_budget_plan_draft(
  p_company_id uuid,p_version_id uuid,p_name text,p_description text,p_metric_code text,
  p_period_start date,p_scope_type text,p_location_id uuid,p_collaborator_id uuid,
  p_value numeric,p_unit_code text,p_reason text,p_monthly_allocations jsonb,
  p_commercial_allocations jsonb default'[]'::jsonb,p_replace_version_id uuid default null
)returns jsonb language plpgsql security definer set search_path=public as $$
declare
  root_json jsonb;root_id uuid;child_id uuid;child_budget uuid;child_scope text;
  item jsonb;child_months jsonb;child_value numeric;child_category uuid;child_product uuid;
  child_label text;old_child_budgets uuid[];total_assigned numeric:=0;
begin
  if p_scope_type not in('company','location','responsible')then
    raise exception'La meta general debe asignarse a empresa, sucursal o responsable.';
  end if;
  if jsonb_typeof(coalesce(p_commercial_allocations,'[]'::jsonb))<>'array'then
    raise exception'Las asignaciones comerciales son inválidas.';
  end if;
  if exists(
    select 1 from(
      select coalesce('product:'||nullif(x->>'product_id',''),'category:'||nullif(x->>'category_id',''))identity_key,count(*)
      from jsonb_array_elements(coalesce(p_commercial_allocations,'[]'::jsonb))x
      group by 1 having count(*)>1
    )duplicates where identity_key is not null
  )then raise exception'Cada categoría o producto sólo puede asignarse una vez dentro de la meta.';end if;
  if p_version_id is null and p_replace_version_id is null and exists(
    select 1 from public.bi_budget_versions v
    where v.company_id=p_company_id and v.status='approved' and v.budget_kind='independent'
      and v.metric_code=p_metric_code and v.scope_type=p_scope_type
      and v.location_id is not distinct from p_location_id
      and v.collaborator_id is not distinct from p_collaborator_id
      and daterange(v.period_start,v.period_end,'[]')&&daterange(date_trunc('year',p_period_start)::date,(date_trunc('year',p_period_start)+interval'1 year'-interval'1 day')::date,'[]')
  )then raise exception'Ya existe esta meta para el año seleccionado. Abre la meta existente para ajustar su distribución.';end if;
  if p_replace_version_id is null and exists(
    select 1
    from jsonb_array_elements(coalesce(p_commercial_allocations,'[]'::jsonb))x
    left join public.products proposed_product on proposed_product.id=nullif(x->>'product_id','')::uuid and proposed_product.company_id=p_company_id
    join public.bi_budget_versions v on v.company_id=p_company_id and v.status='approved'and v.budget_kind='independent'and v.metric_code=p_metric_code
      and daterange(v.period_start,v.period_end,'[]')&&daterange(date_trunc('year',p_period_start)::date,(date_trunc('year',p_period_start)+interval'1 year'-interval'1 day')::date,'[]')
      and((p_scope_type='company'and v.scope_type in('category','product'))
        or(p_scope_type='location'and v.scope_type in('location_category','location_product')and v.location_id=p_location_id)
        or(p_scope_type='responsible'and v.scope_type in('responsible_category','responsible_product')and v.collaborator_id=p_collaborator_id))
      and v.category_id=coalesce(proposed_product.category_id,nullif(x->>'category_id','')::uuid)
      and(v.product_id is null or proposed_product.id is null or v.product_id=proposed_product.id)
  )then raise exception'Ya existe una meta histórica para esa categoría o producto en el año seleccionado. Sustitúyela antes de crear el plan unificado.';end if;

  root_json:=public.bi_save_budget_draft(
    p_company_id,p_version_id,p_name,p_description,p_metric_code,'annual',p_period_start,p_scope_type,
    p_location_id,p_collaborator_id,null,p_value,p_unit_code,null,null,p_replace_version_id,p_reason,p_monthly_allocations
  );
  root_id:=(root_json->>'id')::uuid;

  select array_agg(budget_id)into old_child_budgets from public.bi_budget_versions
  where parent_version_id=root_id and status='draft';
  delete from public.bi_budget_versions where parent_version_id=root_id and status='draft';
  if old_child_budgets is not null then
    delete from public.bi_budgets b where b.id=any(old_child_budgets)
      and not exists(select 1 from public.bi_budget_versions v where v.budget_id=b.id);
  end if;

  for item in select value from jsonb_array_elements(coalesce(p_commercial_allocations,'[]'::jsonb))loop
    child_value:=(item->>'value')::numeric;
    child_category:=nullif(item->>'category_id','')::uuid;
    child_product:=nullif(item->>'product_id','')::uuid;
    child_months:=coalesce(item->'monthly_allocations','[]'::jsonb);
    if child_value<0 then raise exception'Cada asignación debe ser mayor o igual a cero.';end if;
    if child_product is not null then
      select p.category_id,p.name into child_category,child_label from public.products p
      where p.id=child_product and p.company_id=p_company_id;
      if child_label is null then raise exception'Producto canónico inválido.';end if;
      child_scope:=case p_scope_type when'company'then'product'when'location'then'location_product'else'responsible_product'end;
    else
      select c.name into child_label from public.product_categories c where c.id=child_category and c.company_id=p_company_id;
      if child_label is null then raise exception'Categoría canónica inválida.';end if;
      child_scope:=case p_scope_type when'company'then'category'when'location'then'location_category'else'responsible_category'end;
    end if;
    if jsonb_array_length(child_months)<>12
      or(select count(distinct(x->>'month_start')::date)from jsonb_array_elements(child_months)x)<>12
      or(select min((x->>'month_start')::date)from jsonb_array_elements(child_months)x)<>date_trunc('year',p_period_start)::date
      or(select max((x->>'month_start')::date)from jsonb_array_elements(child_months)x)<>(date_trunc('year',p_period_start)+interval'11 months')::date
      or exists(select 1 from jsonb_array_elements(child_months)x where (x->>'month_start')::date<>date_trunc('month',(x->>'month_start')::date)::date or (x->>'value')::numeric<0)
      or abs((select coalesce(sum((x->>'value')::numeric),0)from jsonb_array_elements(child_months)x)-child_value)>0.005 then
      raise exception'Cada asignación debe incluir 12 meses que sumen exactamente su meta.';
    end if;
    total_assigned:=total_assigned+child_value;
    insert into public.bi_budgets(company_id)values(p_company_id)returning id into child_budget;
    insert into public.bi_budget_versions(
      budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,
      scope_type,location_id,collaborator_id,category_id,product_id,value,unit_code,owner_user_id,
      budget_kind,parent_version_id
    )values(
      child_budget,p_company_id,1,left(trim(p_name)||' · '||child_label,140),null,p_metric_code,'annual',
      date_trunc('year',p_period_start)::date,(date_trunc('year',p_period_start)+interval'1 year'-interval'1 day')::date,
      child_scope,p_location_id,p_collaborator_id,child_category,child_product,child_value,
      case when p_metric_code='units_sold'then'unit'else upper(p_unit_code)end,auth.uid(),'distribution',root_id
    )returning id into child_id;
    insert into public.bi_budget_monthly_allocations(company_id,version_id,month_start,value)
    select p_company_id,child_id,(x->>'month_start')::date,(x->>'value')::numeric from jsonb_array_elements(child_months)x;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)
    select p_company_id,child_id,'created',trim(p_reason),jsonb_build_object('version',to_jsonb(v),'monthly_allocations',child_months)
    from public.bi_budget_versions v where v.id=child_id;
  end loop;
  if total_assigned>p_value+0.005 then raise exception'Las asignaciones comerciales exceden la meta total.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_plan_saved','bi_budget_version',root_id,
    jsonb_build_object('reason',trim(p_reason),'commercial_allocations',jsonb_array_length(coalesce(p_commercial_allocations,'[]'::jsonb)),'assigned_value',total_assigned));
  return jsonb_build_object('version',root_json,'assigned_value',total_assigned,'pending_value',p_value-total_assigned);
end$$;

create or replace function public.bi_approve_budget_plan(p_company_id uuid,p_version_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare root_json jsonb;child record;root_value numeric;assigned numeric;old_root uuid;
begin
  select value,replaces_version_id into root_value,old_root from public.bi_budget_versions where id=p_version_id and company_id=p_company_id and status='draft' and budget_kind='independent'for update;
  if root_value is null then raise exception'El borrador del plan no está disponible.';end if;
  select coalesce(sum(value),0)into assigned from public.bi_budget_versions where parent_version_id=p_version_id and status='draft';
  if assigned>root_value+0.005 then raise exception'Las asignaciones comerciales exceden la meta total.';end if;
  root_json:=public.bi_approve_budget_version(p_company_id,p_version_id,p_reason);
  for child in select id from public.bi_budget_versions where parent_version_id=p_version_id and status='draft'order by id loop
    perform public.bi_approve_budget_version(p_company_id,child.id,p_reason);
  end loop;
  if old_root is not null then
    update public.bi_budget_versions set status='superseded',updated_at=now()where parent_version_id=old_root and status='approved';
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)
    select p_company_id,id,'superseded',trim(p_reason),to_jsonb(v)from public.bi_budget_versions v where parent_version_id=old_root and status='superseded';
  end if;
  return jsonb_build_object('version',root_json,'assigned_value',assigned,'pending_value',root_value-assigned);
end$$;

create or replace function public.bi_get_budget_plan_editor(p_company_id uuid,p_version_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
  if not exists(select 1 from public.bi_budget_versions v where v.id=p_version_id and v.company_id=p_company_id and public.bi_can_view_budget_version(v.id))then
    raise exception'Presupuesto no disponible.';
  end if;
  select jsonb_build_object(
    'monthly_allocations',coalesce((select jsonb_agg(jsonb_build_object('month_start',a.month_start,'value',a.value)order by a.month_start)from public.bi_budget_monthly_allocations a where a.version_id=p_version_id),'[]'::jsonb),
    'commercial_allocations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',c.id,'scope_type',c.scope_type,'category_id',c.category_id,'product_id',c.product_id,
      'label',coalesce(p.name,pc.name),'value',c.value,
      'monthly_allocations',coalesce((select jsonb_agg(jsonb_build_object('month_start',ma.month_start,'value',ma.value)order by ma.month_start)from public.bi_budget_monthly_allocations ma where ma.version_id=c.id),'[]'::jsonb)
    )order by coalesce(p.name,pc.name),c.id)from public.bi_budget_versions c left join public.products p on p.id=c.product_id left join public.product_categories pc on pc.id=c.category_id where c.parent_version_id=p_version_id),'[]'::jsonb)
  )into result;
  return result;
end$$;

create or replace function public.bi_project_budget_plan(
  p_company_id uuid,p_version_id uuid,p_increase_percent numeric,p_reason text
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;next_start date;factor numeric;root_months jsonb;children jsonb;new_name text;
begin
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id and status='approved'and budget_kind='independent';
  if not found then raise exception'La meta aprobada no está disponible.';end if;
  if v.period_type<>'annual'then raise exception'Sólo las metas anuales pueden proyectarse al siguiente año.';end if;
  if p_increase_percent is null or p_increase_percent<=-100 or p_increase_percent>1000 then raise exception'Usa un porcentaje mayor a -100 y menor o igual a 1000.';end if;
  factor:=1+p_increase_percent/100;next_start:=(v.period_start+interval'1 year')::date;
  new_name:=replace(v.name,extract(year from v.period_start)::text,extract(year from next_start)::text);
  select jsonb_agg(jsonb_build_object('month_start',(a.month_start+interval'1 year')::date,'value',round(a.value*factor,6))order by a.month_start)
  into root_months from public.bi_budget_monthly_allocations a where a.version_id=v.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'category_id',c.category_id,'product_id',c.product_id,'value',round(c.value*factor,6),
    'monthly_allocations',(select jsonb_agg(jsonb_build_object('month_start',(ma.month_start+interval'1 year')::date,'value',round(ma.value*factor,6))order by ma.month_start)from public.bi_budget_monthly_allocations ma where ma.version_id=c.id)
  )order by c.id),'[]'::jsonb)into children from public.bi_budget_versions c where c.parent_version_id=v.id and c.status='approved';
  return public.bi_save_budget_plan_draft(p_company_id,null,new_name,v.description,v.metric_code,next_start,v.scope_type,v.location_id,v.collaborator_id,
    round(v.value*factor,6),v.unit_code,p_reason,root_months,children,null);
end$$;

create or replace function public.bi_budget_actual(p_version_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;parent_location uuid;amount numeric:=0;rows_count bigint:=0;attributed bigint:=0;
begin
  select*into v from public.bi_budget_versions where id=p_version_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  if v.metric_code='gross_margin'then return jsonb_build_object('available',false,'value',null,'reason','El catálogo BI no dispone aún de costo reconocido por partida vendida y fecha; no se usa costo vigente.');end if;
  if v.parent_version_id is not null then select location_id into parent_location from public.bi_budget_versions where id=v.parent_version_id and scope_type='location';end if;
  select coalesce(sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end),0),count(distinct s.id),count(distinct s.id)filter(where sr.id is not null)
  into amount,rows_count,attributed
  from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id
  left join public.sale_responsibilities sr on sr.sale_id=s.id
  where s.company_id=v.company_id and s.completed_at::date between p_from and p_to
    and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
    and public.can_access_location(s.location_id)
    and(v.location_id is null or s.location_id=v.location_id)and(parent_location is null or s.location_id=parent_location)
    and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)
    and(v.category_id is null or p.category_id=v.category_id)and(v.product_id is null or p.id=v.product_id);
  return jsonb_build_object('available',true,'value',amount,'operation_count',rows_count,'attributed_operation_count',attributed,'attribution_limited',v.collaborator_id is not null);
end$$;

create or replace function public.bi_list_budget_performance(
  p_company_id uuid,p_status text default'approved',p_from date default null,p_to date default null,p_page integer default 1,p_page_size integer default 25
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;today date:=current_date;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_budgets')then raise exception'No autorizado para consultar presupuestos.';end if;
  select count(*)into v_total from public.bi_budget_versions v where v.company_id=p_company_id and(p_status is null or v.status=p_status)and(p_from is null or v.period_end>=p_from)and(p_to is null or v.period_start<=p_to)and public.bi_can_view_budget_version(v.id);
  select coalesce(jsonb_agg(to_jsonb(x)order by x.period_start desc,x.name,x.id),'[]')into v_items from(
    select v.*,coalesce(pr.name,l.name,c.display_name,pc.name,'Empresa')scope_label,
      a.available actual_available,a.value actual_value,a.reason actual_reason,
      case when a.available and v.value<>0 then round(a.value/v.value*100,2)end attainment_percent,
      case when a.available then v.value-a.value end remaining_value,
      case when a.available then case when today<v.period_start then 0 when today>=v.period_end then a.value else round(a.value/greatest(today-v.period_start+1,1)*(v.period_end-v.period_start+1),6)end end projected_value,
      case when v.budget_kind='independent'then coalesce(d.assigned,0)else null end assigned_value,
      case when v.budget_kind='independent'then greatest(v.value-coalesce(d.assigned,0),0)else null end pending_distribution,
      case when v.budget_kind='independent'then greatest(coalesce(d.assigned,0)-v.value,0)else null end distribution_excess
    from public.bi_budget_versions v
    left join public.locations l on l.id=v.location_id left join public.collaborators c on c.id=v.collaborator_id
    left join public.product_categories pc on pc.id=v.category_id left join public.products pr on pr.id=v.product_id
    left join lateral(select sum(ch.value)assigned from public.bi_budget_versions ch where ch.parent_version_id=v.id and ch.status=v.status)d on true
    left join lateral(select(z->>'available')::boolean available,(z->>'value')::numeric value,z->>'reason'reason from(select public.bi_budget_actual(v.id,v.period_start,least(today,v.period_end))z)q)a on true
    where v.company_id=p_company_id and(p_status is null or v.status=p_status)and(p_from is null or v.period_end>=p_from)and(p_to is null or v.period_start<=p_to)and public.bi_can_view_budget_version(v.id)
    order by v.period_start desc,v.name,v.id limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'updated_at',now());
end$$;

create or replace function public.bi_budget_drilldown(p_company_id uuid,p_version_id uuid,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;parent_location uuid;v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),100);v_total bigint;v_items jsonb;
begin
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  if v.metric_code='gross_margin'then raise exception'El margen no dispone de resultado real canónico para drill-down.';end if;
  if v.parent_version_id is not null then select location_id into parent_location from public.bi_budget_versions where id=v.parent_version_id and scope_type='location';end if;
  with matching as(
    select s.id,s.completed_at,l.name location_name,coalesce(c.display_name,'Sin atribución')responsible_name,sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end)value
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id join public.locations l on l.id=s.location_id
    left join public.sale_responsibilities sr on sr.sale_id=s.id left join public.collaborators c on c.id=sr.collaborator_id
    where s.company_id=p_company_id and s.completed_at::date between v.period_start and least(v.period_end,current_date)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)and public.can_access_location(s.location_id)
      and(v.location_id is null or s.location_id=v.location_id)and(parent_location is null or s.location_id=parent_location)
      and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)and(v.category_id is null or p.category_id=v.category_id)and(v.product_id is null or p.id=v.product_id)
    group by s.id,s.completed_at,l.name,c.display_name
  )select count(*)into v_total from matching;
  with matching as(
    select s.id,s.completed_at,l.name location_name,coalesce(c.display_name,'Sin atribución')responsible_name,sum(case when v.metric_code='units_sold'then si.quantity else si.taxable_amount end)value
    from public.sales s join public.sale_items si on si.sale_id=s.id join public.products p on p.id=si.product_id join public.locations l on l.id=s.location_id
    left join public.sale_responsibilities sr on sr.sale_id=s.id left join public.collaborators c on c.id=sr.collaborator_id
    where s.company_id=p_company_id and s.completed_at::date between v.period_start and least(v.period_end,current_date)
      and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)and public.can_access_location(s.location_id)
      and(v.location_id is null or s.location_id=v.location_id)and(parent_location is null or s.location_id=parent_location)
      and(v.collaborator_id is null or sr.collaborator_id=v.collaborator_id)and(v.category_id is null or p.category_id=v.category_id)and(v.product_id is null or p.id=v.product_id)
    group by s.id,s.completed_at,l.name,c.display_name
  )select coalesce(jsonb_agg(to_jsonb(x)order by completed_at desc,id),'[]')into v_items from(select*from matching order by completed_at desc,id limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

create or replace function public.bi_budget_pace_on(p_version_id uuid,p_on date)
returns numeric language sql stable security definer set search_path=public as $$
  select case when exists(select 1 from public.bi_budget_monthly_allocations where version_id=p_version_id)then
    coalesce((select sum(a.value)from public.bi_budget_monthly_allocations a where a.version_id=p_version_id and a.month_start<date_trunc('month',p_on)::date),0)
    +coalesce((select a.value*least(greatest(p_on-a.month_start+1,0),extract(day from(date_trunc('month',a.month_start)+interval'1 month'-interval'1 day'))::integer)
      /extract(day from(date_trunc('month',a.month_start)+interval'1 month'-interval'1 day'))
      from public.bi_budget_monthly_allocations a where a.version_id=p_version_id and a.month_start=date_trunc('month',p_on)::date),0)
  else(select v.value*least(greatest(p_on-v.period_start+1,0),v.period_end-v.period_start+1)/(v.period_end-v.period_start+1)from public.bi_budget_versions v where v.id=p_version_id)end
$$;

create or replace function public.bi_get_budget_detail(p_company_id uuid,p_version_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_budget_versions%rowtype;actual jsonb;previous jsonb;series jsonb;events jsonb;children jsonb;today date:=current_date;
begin
  select*into v from public.bi_budget_versions where id=p_version_id and company_id=p_company_id;
  if not found or not public.bi_can_view_budget_version(v.id)then raise exception'Presupuesto no disponible.';end if;
  actual:=public.bi_budget_actual(v.id,v.period_start,least(today,v.period_end));
  previous:=public.bi_budget_actual(v.id,v.period_start-(v.period_end-v.period_start+1),v.period_start-1);
  select coalesce(jsonb_agg(jsonb_build_object('date',d,'actual',case when(a->>'available')::boolean then(a->>'value')::numeric end,'budget_pace',public.bi_budget_pace_on(v.id,d::date))order by d),'[]')into series
  from generate_series(v.period_start,least(v.period_end,today),'1 day')g(d)cross join lateral(select public.bi_budget_actual(v.id,v.period_start,d::date)a)q;
  select coalesce(jsonb_agg(to_jsonb(e)order by occurred_at desc,id),'[]')into events from public.bi_budget_version_events e where e.version_id=v.id;
  select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object(
    'scope_label',coalesce(pr.name,pc.name,'Asignación'),
    'actual_available',(ca->>'available')::boolean,
    'actual_value',case when(ca->>'available')::boolean then(ca->>'value')::numeric end,
    'attainment_percent',case when(ca->>'available')::boolean and c.value<>0 then round((ca->>'value')::numeric/c.value*100,2)end
  )order by c.name,c.id),'[]')into children
  from public.bi_budget_versions c
  left join public.products pr on pr.id=c.product_id
  left join public.product_categories pc on pc.id=c.category_id
  cross join lateral(select public.bi_budget_actual(c.id,c.period_start,least(today,c.period_end))ca)actual_result
  where c.parent_version_id=v.id and public.bi_can_view_budget_version(c.id);
  return jsonb_build_object('version',to_jsonb(v),'actual',actual,'previous_period',previous,'series',series,'history',events,'distributions',children);
end$$;

create or replace function public.bi_search_budget_scope_options(
  p_company_id uuid,p_scope text,p_query text default null,p_page integer default 1,p_page_size integer default 20
)returns jsonb language plpgsql stable security definer set search_path=public as $$
declare q text:=lower(trim(coalesce(p_query,'')));v_page integer:=greatest(p_page,1);v_size integer:=least(greatest(p_page_size,1),50);v_total bigint;items jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then raise exception'No autorizado para consultar alcances.';end if;
  if p_scope='location'then
    select count(*)into v_total from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]')into items from(select l.id,l.name,l.external_code from public.locations l where l.company_id=p_company_id and l.is_active and public.can_access_location(l.id)and(q=''or lower(l.name)like'%'||q||'%'or lower(l.external_code)like'%'||q||'%')order by l.name,l.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='responsible'then
    select count(*)into v_total from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.display_name,'secondary',x.code)order by x.display_name,x.id),'[]')into items from(select c.id,c.display_name,c.code from public.collaborators c where c.company_id=p_company_id and c.employment_status='active'and(q=''or lower(c.display_name)like'%'||q||'%'or lower(c.code)like'%'||q||'%')order by c.display_name,c.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='category'then
    select count(*)into v_total from public.product_categories c where c.company_id=p_company_id and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',x.external_code)order by x.name,x.id),'[]')into items from(select c.id,c.name,c.external_code from public.product_categories c where c.company_id=p_company_id and(q=''or lower(c.name)like'%'||q||'%'or lower(c.external_code)like'%'||q||'%')order by c.name,c.id limit v_size offset(v_page-1)*v_size)x;
  elsif p_scope='product'then
    select count(*)into v_total from public.products p where p.company_id=p_company_id and(q=''or lower(p.name)like'%'||q||'%'or lower(p.alpha_sku)like'%'||q||'%');
    select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'label',x.name,'secondary',concat_ws(' · ',x.alpha_sku,x.category_name),'category_id',x.category_id)order by x.name,x.id),'[]')into items from(select p.id,p.name,p.alpha_sku,p.category_id,c.name category_name from public.products p left join public.product_categories c on c.id=p.category_id where p.company_id=p_company_id and(q=''or lower(p.name)like'%'||q||'%'or lower(p.alpha_sku)like'%'||q||'%')order by p.name,p.id limit v_size offset(v_page-1)*v_size)x;
  else raise exception'Tipo de alcance inválido.';end if;
  return jsonb_build_object('items',items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

revoke all on function public.bi_save_budget_plan_draft(uuid,uuid,text,text,text,date,text,uuid,uuid,numeric,text,text,jsonb,jsonb,uuid)from public,anon;
revoke all on function public.bi_approve_budget_plan(uuid,uuid,text)from public,anon;
revoke all on function public.bi_get_budget_plan_editor(uuid,uuid)from public,anon;
revoke all on function public.bi_project_budget_plan(uuid,uuid,numeric,text)from public,anon;
revoke all on function public.bi_budget_pace_on(uuid,date)from public,anon;
grant execute on function public.bi_save_budget_plan_draft(uuid,uuid,text,text,text,date,text,uuid,uuid,numeric,text,text,jsonb,jsonb,uuid)to authenticated;
grant execute on function public.bi_approve_budget_plan(uuid,uuid,text)to authenticated;
grant execute on function public.bi_get_budget_plan_editor(uuid,uuid)to authenticated;
grant execute on function public.bi_project_budget_plan(uuid,uuid,numeric,text)to authenticated;
notify pgrst,'reload schema';
