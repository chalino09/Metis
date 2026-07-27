-- Satrapy BI · Fase 4: vistas versionadas, tableros configurables y exportaciones.
-- Persiste configuración; los resultados siempre se recalculan con bi_explorer_query.

insert into public.permissions(code,description) values
  ('view_bi_dashboards','Consultar tableros y vistas compartidas de BI.'),
  ('manage_own_bi_views','Crear y administrar vistas propias de BI.'),
  ('share_bi_views','Compartir vistas de BI con la empresa.'),
  ('manage_bi_dashboards','Crear y administrar tableros de BI.'),
  ('export_bi_reports','Exportar vistas, widgets y tableros de BI.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in('super_admin','direccion_admin') and p.code in(
  'view_bi_dashboards','manage_own_bi_views','share_bi_views','manage_bi_dashboards','export_bi_reports'
) on conflict do nothing;

create table public.bi_saved_views(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete restrict default auth.uid(),
  name text not null check(nullif(trim(name),'') is not null and length(trim(name))<=120),
  description text,
  visibility text not null default'private' check(visibility in('private','company')),
  current_version integer not null default 1 check(current_version>0),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(company_id,owner_id,name)
);
create index bi_saved_views_catalog_idx on public.bi_saved_views(company_id,visibility,updated_at desc,id);

create table public.bi_saved_view_versions(
  id uuid primary key default gen_random_uuid(),
  saved_view_id uuid not null references public.bi_saved_views(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  version integer not null check(version>0),
  definition jsonb not null check(jsonb_typeof(definition)='object'),
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  unique(saved_view_id,version)
);
create index bi_saved_view_versions_current_idx on public.bi_saved_view_versions(saved_view_id,version desc);

create table public.bi_dashboards(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete restrict default auth.uid(),
  name text not null check(nullif(trim(name),'') is not null and length(trim(name))<=120),
  description text,
  revision integer not null default 1 check(revision>0),
  default_filters jsonb not null default'{}'::jsonb check(jsonb_typeof(default_filters)='object'),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(company_id,name)
);
create index bi_dashboards_catalog_idx on public.bi_dashboards(company_id,updated_at desc,id);

create table public.bi_dashboard_widgets(
  id uuid primary key default gen_random_uuid(),
  dashboard_id uuid not null references public.bi_dashboards(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  saved_view_id uuid not null references public.bi_saved_views(id) on delete restrict,
  widget_type text not null check(widget_type in('kpi','chart','table')),
  title text,
  filter_mode text not null default'inherit' check(filter_mode in('inherit','own')),
  own_filters jsonb not null default'{}'::jsonb check(jsonb_typeof(own_filters)='object'),
  display_config jsonb not null default'{}'::jsonb check(jsonb_typeof(display_config)='object'),
  position integer not null check(position>=0),
  width integer not null default 2 check(width between 1 and 4),
  height integer not null default 1 check(height between 1 and 3),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(dashboard_id,position)
);
create index bi_dashboard_widgets_order_idx on public.bi_dashboard_widgets(dashboard_id,position);

create table public.bi_export_jobs(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  target_type text not null check(target_type in('view','widget','dashboard')),
  target_id uuid not null,
  format text not null check(format in('csv','xlsx','pdf')),
  status text not null default'processing' check(status in('processing','completed','failed')),
  query_snapshot jsonb not null check(jsonb_typeof(query_snapshot)='object'),
  row_count bigint,
  byte_count bigint,
  result_metadata jsonb not null default'{}'::jsonb,
  requested_at timestamptz not null default now(),completed_at timestamptz
);
create index bi_export_jobs_audit_idx on public.bi_export_jobs(company_id,requested_at desc,id);

alter table public.bi_saved_views enable row level security;
alter table public.bi_saved_view_versions enable row level security;
alter table public.bi_dashboards enable row level security;
alter table public.bi_dashboard_widgets enable row level security;
alter table public.bi_export_jobs enable row level security;

create policy bi_saved_views_read on public.bi_saved_views for select to authenticated using(
  public.has_company_permission(company_id,'view_bi')
  and(owner_id=auth.uid()or(visibility='company'and public.has_company_permission(company_id,'view_bi_dashboards')))
);
create policy bi_saved_view_versions_read on public.bi_saved_view_versions for select to authenticated using(
  exists(select 1 from public.bi_saved_views v where v.id=saved_view_id)
);
create policy bi_dashboards_read on public.bi_dashboards for select to authenticated using(
  public.has_company_permission(company_id,'view_bi')and public.has_company_permission(company_id,'view_bi_dashboards')
);
create policy bi_dashboard_widgets_read on public.bi_dashboard_widgets for select to authenticated using(
  exists(select 1 from public.bi_dashboards d where d.id=dashboard_id)
);
create policy bi_export_jobs_read on public.bi_export_jobs for select to authenticated using(
  requested_by=auth.uid()and public.has_company_permission(company_id,'export_bi_reports')
);

revoke all on public.bi_saved_views,public.bi_saved_view_versions,public.bi_dashboards,public.bi_dashboard_widgets,public.bi_export_jobs from public,anon,authenticated;
grant select on public.bi_saved_views,public.bi_saved_view_versions,public.bi_dashboards,public.bi_dashboard_widgets,public.bi_export_jobs to authenticated;

create or replace function public.bi_assert_explorer_definition(p_company_id uuid,p_definition jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb;codes text[];d1 date;d2 date;
begin
  if jsonb_typeof(p_definition)<>'object'then raise exception 'Definición de BI inválida.';end if;
  select array_agg(value)into codes from jsonb_array_elements_text(p_definition->'metric_codes');
  d1:=(p_definition->>'date_from')::date;d2:=(p_definition->>'date_to')::date;
  r:=public.bi_explorer_query(
    p_company_id,codes,p_definition->>'dimension',p_definition->>'visualization',d1,d2,
    nullif(p_definition->>'location_id','')::uuid,nullif(p_definition->>'product_id','')::uuid,
    nullif(p_definition->>'customer_id','')::uuid,nullif(p_definition->>'supplier_id','')::uuid,
    coalesce((p_definition->>'compare_previous')::boolean,true),1,1
  );
  return jsonb_build_object('valid',true,'catalog_updated_at',(public.bi_get_metric_catalog(p_company_id)->>'updated_at'),'query',r->'query');
exception when invalid_text_representation or datetime_field_overflow then raise exception 'Filtros o periodo de BI inválidos.';
end $$;

create or replace function public.bi_view_availability(p_company_id uuid,p_definition jsonb)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare c jsonb:=public.bi_get_metric_catalog(p_company_id);code text;metric jsonb;warnings jsonb:='[]'::jsonb;
begin
  for code in select value from jsonb_array_elements_text(p_definition->'metric_codes')loop
    select value into metric from jsonb_array_elements(c->'metrics')where value->>'code'=code;
    if metric is null then warnings:=warnings||jsonb_build_array('La métrica '||code||' ya no existe en el catálogo.');
    elsif not coalesce((metric->>'available')::boolean,false)then warnings:=warnings||jsonb_build_array(coalesce(metric->>'unavailable_reason','Métrica no disponible.'));
    end if;
  end loop;
  return jsonb_build_object('available',jsonb_array_length(warnings)=0,'warnings',warnings);
end $$;

create or replace function public.bi_list_saved_views(p_company_id uuid,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare pg integer:=greatest(coalesce(p_page,1),1);sz integer:=least(greatest(coalesce(p_page_size,25),1),100);total bigint;items jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi')then raise exception'No autorizado para consultar BI.';end if;
  with visible as materialized(
    select v.*,vv.definition,public.bi_view_availability(p_company_id,vv.definition)availability
    from public.bi_saved_views v join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    where v.company_id=p_company_id and(v.owner_id=auth.uid()or(v.visibility='company'and public.has_company_permission(p_company_id,'view_bi_dashboards')))
  ),paged as(select * from visible order by updated_at desc,id limit sz offset(pg-1)*sz)
  select(select count(*)from visible),coalesce(jsonb_agg(to_jsonb(paged)order by updated_at desc,id),'[]')into total,items from paged;
  return jsonb_build_object('items',items,'pagination',jsonb_build_object('page',pg,'page_size',sz,'total',total));
end $$;

create or replace function public.bi_save_view(
  p_company_id uuid,p_view_id uuid,p_name text,p_description text,p_visibility text,p_definition jsonb,
  p_expected_version integer default null,p_client_request_id uuid default gen_random_uuid()
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.bi_saved_views%rowtype;next_version integer;action text;previous_visibility text;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'manage_own_bi_views')then raise exception'No autorizado para administrar vistas de BI.';end if;
  if p_visibility not in('private','company')then raise exception'Visibilidad inválida.';end if;
  if p_visibility='company'and not public.has_company_permission(p_company_id,'share_bi_views')then raise exception'No autorizado para compartir vistas.';end if;
  perform public.bi_assert_explorer_definition(p_company_id,p_definition);
  if p_view_id is null then
    insert into public.bi_saved_views(company_id,owner_id,name,description,visibility)
    values(p_company_id,auth.uid(),trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_visibility)returning*into v;
    next_version:=1;action:='bi.view_created';
  else
    select*into v from public.bi_saved_views where id=p_view_id and company_id=p_company_id for update;
    if not found or v.owner_id<>auth.uid()then raise exception'Vista no disponible.';end if;
    if p_expected_version is null or v.current_version<>p_expected_version then raise exception'La vista cambió; recarga antes de guardar.';end if;
    previous_visibility:=v.visibility;
    next_version:=v.current_version+1;
    update public.bi_saved_views set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),visibility=p_visibility,
      current_version=next_version,updated_at=now()where id=v.id returning*into v;
    action:='bi.view_updated';
  end if;
  insert into public.bi_saved_view_versions(saved_view_id,company_id,version,definition)values(v.id,p_company_id,next_version,p_definition);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),action,'bi_saved_view',v.id,jsonb_build_object('request_id',p_client_request_id,'version',next_version,'visibility',p_visibility));
  if previous_visibility='private'and p_visibility='company'then
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(p_company_id,auth.uid(),'bi.view_shared','bi_saved_view',v.id,jsonb_build_object('version',next_version));
  end if;
  return to_jsonb(v)||jsonb_build_object('definition',p_definition);
end $$;

create or replace function public.bi_duplicate_view(p_company_id uuid,p_view_id uuid,p_name text,p_client_request_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path=public as $$
declare source public.bi_saved_views%rowtype;definition jsonb;result jsonb;
begin
  if not public.has_company_permission(p_company_id,'manage_own_bi_views')then raise exception'No autorizado.';end if;
  select v.* into source from public.bi_saved_views v
  where v.id=p_view_id and v.company_id=p_company_id and(v.owner_id=auth.uid()or v.visibility='company');
  if not found then raise exception'Vista no disponible.';end if;
  select vv.definition into definition from public.bi_saved_view_versions vv where vv.saved_view_id=source.id and vv.version=source.current_version;
  result:=public.bi_save_view(p_company_id,null,p_name,source.description,'private',definition,null,p_client_request_id);
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.view_duplicated','bi_saved_view',(result->>'id')::uuid,jsonb_build_object('source_view_id',p_view_id));
  return result;
end $$;

create or replace function public.bi_delete_view(p_company_id uuid,p_view_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v public.bi_saved_views%rowtype;
begin
  select*into v from public.bi_saved_views where id=p_view_id and company_id=p_company_id for update;
  if not found or v.owner_id<>auth.uid()or not public.has_company_permission(p_company_id,'manage_own_bi_views')then raise exception'Vista no disponible.';end if;
  if exists(select 1 from public.bi_dashboard_widgets where saved_view_id=v.id)then raise exception'La vista está usada por un tablero; retira primero sus widgets.';end if;
  delete from public.bi_saved_views where id=v.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.view_deleted','bi_saved_view',v.id,jsonb_build_object('name',v.name,'version',v.current_version));
end $$;

create or replace function public.bi_list_dashboards(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_dashboards')then raise exception'No autorizado para consultar tableros.';end if;
  return coalesce((select jsonb_agg(to_jsonb(x)order by x.updated_at desc)from(
    select d.*,count(w.id)widget_count from public.bi_dashboards d left join public.bi_dashboard_widgets w on w.dashboard_id=d.id
    where d.company_id=p_company_id group by d.id)x),'[]'::jsonb);
end $$;

create or replace function public.bi_save_dashboard(p_company_id uuid,p_dashboard_id uuid,p_name text,p_description text,p_expected_revision integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;action text;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'No autorizado para administrar tableros.';end if;
  if p_dashboard_id is null then insert into public.bi_dashboards(company_id,name,description)values(p_company_id,trim(p_name),nullif(trim(coalesce(p_description,'')),''))returning*into d;action:='bi.dashboard_created';
  else
    select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id for update;
    if not found or d.revision<>p_expected_revision then raise exception'El tablero cambió; recarga antes de guardar.';end if;
    update public.bi_dashboards set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),revision=revision+1,updated_at=now()where id=d.id returning*into d;action:='bi.dashboard_updated';
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),action,'bi_dashboard',d.id,jsonb_build_object('revision',d.revision));
  return to_jsonb(d);
end $$;

create or replace function public.bi_delete_dashboard(p_company_id uuid,p_dashboard_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;
begin
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id for update;
  if not found or not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'Tablero no disponible.';end if;
  delete from public.bi_dashboards where id=d.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.dashboard_deleted','bi_dashboard',d.id,jsonb_build_object('name',d.name));
end $$;

create or replace function public.bi_add_dashboard_widget(
  p_company_id uuid,p_dashboard_id uuid,p_saved_view_id uuid,p_widget_type text,p_title text,p_filter_mode text default'inherit'
)returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;w public.bi_dashboard_widgets%rowtype;pos integer;
begin
  if not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'No autorizado.';end if;
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id for update;
  if not found then raise exception'Tablero no disponible.';end if;
  if not exists(select 1 from public.bi_saved_views v where v.id=p_saved_view_id and v.company_id=p_company_id and v.visibility='company')then raise exception'Comparte la vista con la empresa antes de agregarla a un tablero.';end if;
  if(select count(*)from public.bi_dashboard_widgets where dashboard_id=d.id)>=12 then raise exception'Un tablero admite hasta 12 widgets.';end if;
  select coalesce(max(position),-1)+1 into pos from public.bi_dashboard_widgets where dashboard_id=d.id;
  insert into public.bi_dashboard_widgets(dashboard_id,company_id,saved_view_id,widget_type,title,filter_mode,position)
  values(d.id,p_company_id,p_saved_view_id,p_widget_type,nullif(trim(coalesce(p_title,'')),''),p_filter_mode,pos)returning*into w;
  update public.bi_dashboards set revision=revision+1,updated_at=now()where id=d.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.widget_added','bi_dashboard_widget',w.id,jsonb_build_object('dashboard_id',d.id,'saved_view_id',p_saved_view_id));
  return to_jsonb(w);
end $$;

create or replace function public.bi_remove_dashboard_widget(p_company_id uuid,p_widget_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare w public.bi_dashboard_widgets%rowtype;
begin
  select*into w from public.bi_dashboard_widgets where id=p_widget_id and company_id=p_company_id for update;
  if not found or not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'Widget no disponible.';end if;
  delete from public.bi_dashboard_widgets where id=w.id;
  with ordered as(select id,row_number()over(order by position,id)-1 pos from public.bi_dashboard_widgets where dashboard_id=w.dashboard_id)
  update public.bi_dashboard_widgets x set position=o.pos from ordered o where x.id=o.id;
  update public.bi_dashboards set revision=revision+1,updated_at=now()where id=w.dashboard_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.widget_removed','bi_dashboard_widget',w.id,jsonb_build_object('dashboard_id',w.dashboard_id));
end $$;

create or replace function public.bi_save_dashboard_layout(p_company_id uuid,p_dashboard_id uuid,p_expected_revision integer,p_widgets jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;item jsonb;seen uuid[]:='{}';count_items integer;
begin
  if not public.has_company_permission(p_company_id,'manage_bi_dashboards')then raise exception'No autorizado.';end if;
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id for update;
  if not found or d.revision<>p_expected_revision then raise exception'El tablero cambió; recarga antes de ordenar.';end if;
  if jsonb_typeof(p_widgets)<>'array'then raise exception'Layout inválido.';end if;
  count_items:=jsonb_array_length(p_widgets);
  if count_items>12 or count_items<>(select count(*)from public.bi_dashboard_widgets where dashboard_id=d.id)then raise exception'El layout debe incluir todos los widgets una sola vez.';end if;
  update public.bi_dashboard_widgets set position=position+1000 where dashboard_id=d.id;
  for item in select value from jsonb_array_elements(p_widgets)loop
    if(item->>'id')::uuid=any(seen)then raise exception'Widget repetido.';end if;seen:=seen||(item->>'id')::uuid;
    update public.bi_dashboard_widgets set position=(item->>'position')::integer,width=(item->>'width')::integer,height=(item->>'height')::integer,
      filter_mode=coalesce(item->>'filter_mode',filter_mode),updated_at=now()
    where id=(item->>'id')::uuid and dashboard_id=d.id;
    if not found then raise exception'Widget ajeno al tablero.';end if;
  end loop;
  update public.bi_dashboards set revision=revision+1,updated_at=now()where id=d.id returning*into d;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.dashboard_layout_saved','bi_dashboard',d.id,jsonb_build_object('revision',d.revision,'widget_count',count_items));
  return to_jsonb(d);
end $$;

create or replace function public.bi_get_dashboard_snapshot(p_company_id uuid,p_dashboard_id uuid,p_global_filters jsonb default'{}')
returns jsonb language plpgsql security definer set search_path=public as $$
declare d public.bi_dashboards%rowtype;w record;definition jsonb;effective jsonb;result jsonb;widgets jsonb:='[]';from_date date;to_date date;codes text[];
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_bi_dashboards')then raise exception'No autorizado para consultar tableros.';end if;
  select*into d from public.bi_dashboards where id=p_dashboard_id and company_id=p_company_id;
  if not found then raise exception'Tablero no disponible.';end if;
  for w in select x.*,v.name view_name,v.current_version,v.visibility,v.owner_id,vv.definition
    from public.bi_dashboard_widgets x join public.bi_saved_views v on v.id=x.saved_view_id
    join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    where x.dashboard_id=d.id order by x.position
  loop
    begin
      definition:=w.definition;effective:=definition;
      if w.filter_mode='inherit'then
        effective:=effective||jsonb_strip_nulls(jsonb_build_object(
          'date_from',p_global_filters->>'date_from','date_to',p_global_filters->>'date_to','location_id',p_global_filters->>'location_id'
        ));
      else effective:=effective||w.own_filters;end if;
      from_date:=(effective->>'date_from')::date;to_date:=(effective->>'date_to')::date;
      select array_agg(value)into codes from jsonb_array_elements_text(effective->'metric_codes');
      result:=public.bi_explorer_query(p_company_id,codes,effective->>'dimension',effective->>'visualization',from_date,to_date,
        nullif(effective->>'location_id','')::uuid,nullif(effective->>'product_id','')::uuid,nullif(effective->>'customer_id','')::uuid,
        nullif(effective->>'supplier_id','')::uuid,coalesce((effective->>'compare_previous')::boolean,true),1,case when w.widget_type='table'then 25 else 12 end);
      widgets:=widgets||jsonb_build_array(to_jsonb(w)-'definition'||jsonb_build_object('status','ready','definition',effective,'result',result));
    exception when others then
      widgets:=widgets||jsonb_build_array(to_jsonb(w)-'definition'||jsonb_build_object('status','error','error',sqlerrm,'availability',public.bi_view_availability(p_company_id,w.definition)));
    end;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.dashboard_queried','bi_dashboard',d.id,jsonb_build_object('widget_count',jsonb_array_length(widgets)));
  return jsonb_build_object('dashboard',to_jsonb(d),'widgets',widgets,'updated_at',now());
end $$;

create or replace function public.bi_prepare_export(p_company_id uuid,p_target_type text,p_target_id uuid,p_format text,p_filters jsonb default'{}')
returns jsonb language plpgsql security definer set search_path=public as $$
declare configs jsonb:='[]';job public.bi_export_jobs%rowtype;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'export_bi_reports')or not public.has_company_permission(p_company_id,'view_bi')then raise exception'No autorizado para exportar BI.';end if;
  if p_target_type='view'then
    select jsonb_build_array(jsonb_build_object('title',v.name,'target_id',v.id,'widget_type','table','definition',vv.definition))into configs
    from public.bi_saved_views v join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    where v.id=p_target_id and v.company_id=p_company_id and(v.owner_id=auth.uid()or v.visibility='company');
  elsif p_target_type='widget'then
    select jsonb_build_array(jsonb_build_object('title',coalesce(w.title,v.name),'target_id',w.id,'widget_type',w.widget_type,
      'definition',vv.definition||case when w.filter_mode='inherit'then d.default_filters||coalesce(p_filters,'{}')else w.own_filters end))into configs
    from public.bi_dashboard_widgets w join public.bi_saved_views v on v.id=w.saved_view_id join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    join public.bi_dashboards d on d.id=w.dashboard_id
    where w.id=p_target_id and w.company_id=p_company_id and public.has_company_permission(p_company_id,'view_bi_dashboards');
  elsif p_target_type='dashboard'then
    if not public.has_company_permission(p_company_id,'view_bi_dashboards')then raise exception'No autorizado para consultar tableros.';end if;
    select coalesce(jsonb_agg(jsonb_build_object('title',coalesce(w.title,v.name),'target_id',w.id,'widget_type',w.widget_type,
      'definition',vv.definition||case when w.filter_mode='inherit'then d.default_filters||coalesce(p_filters,'{}')else w.own_filters end)order by w.position),'[]')into configs
    from public.bi_dashboard_widgets w join public.bi_dashboards d on d.id=w.dashboard_id
    join public.bi_saved_views v on v.id=w.saved_view_id join public.bi_saved_view_versions vv on vv.saved_view_id=v.id and vv.version=v.current_version
    where w.dashboard_id=p_target_id and w.company_id=p_company_id;
  else raise exception'Tipo de exportación inválido.';end if;
  if configs is null or jsonb_array_length(configs)=0 then raise exception'Contenido no disponible para exportar.';end if;
  insert into public.bi_export_jobs(company_id,target_type,target_id,format,query_snapshot)
  values(p_company_id,p_target_type,p_target_id,p_format,jsonb_build_object('configs',configs,'filters',coalesce(p_filters,'{}')))returning*into job;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(p_company_id,auth.uid(),'bi.export_requested','bi_export_job',job.id,jsonb_build_object('target_type',p_target_type,'target_id',p_target_id,'format',p_format));
  return jsonb_build_object('job_id',job.id,'configs',configs);
end $$;

create or replace function public.bi_finish_export(p_job_id uuid,p_status text,p_row_count bigint,p_byte_count bigint,p_metadata jsonb default'{}')
returns void language plpgsql security definer set search_path=public as $$
declare j public.bi_export_jobs%rowtype;
begin
  select*into j from public.bi_export_jobs where id=p_job_id and requested_by=auth.uid()for update;
  if not found then raise exception'Exportación no disponible.';end if;
  update public.bi_export_jobs set status=p_status,row_count=p_row_count,byte_count=p_byte_count,result_metadata=coalesce(p_metadata,'{}'),completed_at=now()where id=j.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)values(j.company_id,auth.uid(),case when p_status='completed'then'bi.export_completed'else'bi.export_failed'end,'bi_export_job',j.id,jsonb_build_object('format',j.format,'rows',p_row_count,'bytes',p_byte_count,'result',p_metadata));
end $$;

do $$declare r record;begin
  for r in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'and p.proname in(
      'bi_assert_explorer_definition','bi_view_availability','bi_list_saved_views','bi_save_view','bi_duplicate_view','bi_delete_view',
      'bi_list_dashboards','bi_save_dashboard','bi_delete_dashboard','bi_add_dashboard_widget','bi_remove_dashboard_widget',
      'bi_save_dashboard_layout','bi_get_dashboard_snapshot','bi_prepare_export','bi_finish_export'
    )
  loop execute format('revoke all on function %s from public,anon',r.signature);execute format('grant execute on function %s to authenticated',r.signature);end loop;
end $$;

notify pgrst,'reload schema';
