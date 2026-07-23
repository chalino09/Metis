-- Configuración modular, administración de sucursales y lectura de migración inicial.
-- Reutiliza ubicaciones, importaciones y dominios existentes; no crea otro cargador.

create index if not exists locations_company_active_name_idx
  on public.locations(company_id,is_active,name,id);

-- La marca de edición de sucursales también funciona como token de concurrencia.
-- Debe avanzar incluso cuando un proceso administrativo hace más de un cambio
-- dentro de la misma transacción.
create or replace function public.set_location_updated_at()
returns trigger language plpgsql set search_path=public as $$
begin
  new.updated_at:=greatest(clock_timestamp(),old.updated_at+interval '1 microsecond');
  return new;
end $$;

drop trigger if exists locations_set_updated_at on public.locations;
create trigger locations_set_updated_at before update on public.locations
for each row execute function public.set_location_updated_at();

create unique index if not exists audit_location_admin_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='company.location_saved' and metadata ? 'request_id';

create or replace function public.list_company_locations(
  p_company_id uuid,
  p_query text default null,
  p_location_type text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_page integer;v_size integer;v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_locations') then
    raise exception 'No autorizado para administrar sucursales.';
  end if;
  if p_location_type is not null and p_location_type not in ('sucursal','almacen_central','almacen_operativo','campo','pendiente_revision') then raise exception 'Tipo de ubicación inválido.';end if;
  if p_status is not null and p_status not in ('active','inactive') then raise exception 'Estado de ubicación inválido.';end if;
  v_page:=greatest(coalesce(p_page,1),1);v_size:=least(greatest(coalesce(p_page_size,25),1),100);
  with filtered as(
    select l.* from public.locations l where l.company_id=p_company_id
      and (nullif(trim(p_query),'') is null or l.external_code ilike '%'||trim(p_query)||'%' or l.name ilike '%'||trim(p_query)||'%')
      and (p_location_type is null or l.location_type=p_location_type)
      and (p_status is null or l.is_active=(p_status='active'))
  ) select count(*) into v_total from filtered;
  with filtered as(
    select l.* from public.locations l where l.company_id=p_company_id
      and (nullif(trim(p_query),'') is null or l.external_code ilike '%'||trim(p_query)||'%' or l.name ilike '%'||trim(p_query)||'%')
      and (p_location_type is null or l.location_type=p_location_type)
      and (p_status is null or l.is_active=(p_status='active'))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',l.id,'external_code',l.external_code,'name',l.name,'location_type',l.location_type,'is_active',l.is_active,'updated_at',l.updated_at,
    'inventory_quantity',coalesce(b.quantity,0),'open_cash_sessions',coalesce(c.sessions,0),'active_counts',coalesce(ic.counts,0),'active_transfers',coalesce(t.transfers,0),
    'can_deactivate',coalesce(b.quantity,0)=0 and coalesce(c.sessions,0)=0 and coalesce(ic.counts,0)=0 and coalesce(t.transfers,0)=0
  ) order by l.is_active desc,l.name,l.id),'[]'::jsonb) into v_items
  from (select * from filtered order by is_active desc,name,id limit v_size offset (v_page-1)*v_size) l
  left join lateral(select coalesce(sum(quantity_on_hand),0) quantity from public.inventory_balances where location_id=l.id)b on true
  left join lateral(select count(*) sessions from public.cash_sessions where location_id=l.id and status in('open','pending_variance_approval'))c on true
  left join lateral(select count(*) counts from public.inventory_counts where location_id=l.id and status in('open','review','pending_approval'))ic on true
  left join lateral(select count(*) transfers from public.inventory_transfers where (source_location_id=l.id or destination_location_id=l.id) and status in('sent','in_transit'))t on true;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

create or replace function public.save_company_location(
  p_company_id uuid,
  p_location_id uuid,
  p_external_code text,
  p_name text,
  p_location_type text,
  p_is_active boolean,
  p_reason text,
  p_expected_updated_at timestamptz,
  p_client_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_location public.locations%rowtype;v_previous jsonb;v_result jsonb;v_blocker text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_locations') then raise exception 'No autorizado para administrar sucursales.';end if;
  if nullif(trim(p_external_code),'') is null or length(trim(p_external_code))>40 or nullif(trim(p_name),'') is null or length(trim(p_name))>160 then raise exception 'Código y nombre son obligatorios.';end if;
  if p_location_type not in ('sucursal','almacen_central','almacen_operativo','campo') then raise exception 'Selecciona un tipo de ubicación válido.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'El motivo es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));
  select to_jsonb(l) into v_result from public.audit_log a join public.locations l on l.id=a.entity_id
    where a.company_id=p_company_id and a.action='company.location_saved' and a.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  if p_location_id is not null then
    select * into v_location from public.locations where id=p_location_id and company_id=p_company_id for update;
    if not found then raise exception 'La sucursal ya no está disponible.';end if;
    if p_expected_updated_at is null or v_location.updated_at<>p_expected_updated_at then raise exception 'La sucursal cambió mientras la editabas. Actualiza y vuelve a intentarlo.';end if;
    v_previous:=to_jsonb(v_location);
    if (not p_is_active or v_location.location_type<>p_location_type) then
      if exists(select 1 from public.inventory_balances where location_id=v_location.id and quantity_on_hand<>0) then v_blocker:='Tiene inventario disponible.';
      elsif exists(select 1 from public.cash_sessions where location_id=v_location.id and status in('open','pending_variance_approval')) then v_blocker:='Tiene una sesión de caja pendiente.';
      elsif exists(select 1 from public.inventory_counts where location_id=v_location.id and status in('open','review','pending_approval')) then v_blocker:='Tiene un conteo físico pendiente.';
      elsif exists(select 1 from public.inventory_transfers where (source_location_id=v_location.id or destination_location_id=v_location.id) and status in('sent','in_transit')) then v_blocker:='Tiene transferencias pendientes.';end if;
      if v_blocker is not null then raise exception 'No se puede cambiar el tipo ni desactivar. %',v_blocker;end if;
    end if;
    update public.locations set external_code=upper(trim(p_external_code)),name=trim(p_name),location_type=p_location_type,is_active=p_is_active,classification_source='manual_review' where id=v_location.id returning * into v_location;
  else
    v_previous:=null;
    insert into public.locations(company_id,external_code,name,location_type,is_active,classification_source)
    values(p_company_id,upper(trim(p_external_code)),trim(p_name),p_location_type,coalesce(p_is_active,true),'manual_review') returning * into v_location;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'company.location_saved','location',v_location.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'previous',v_previous,'current',to_jsonb(v_location)));
  return to_jsonb(v_location)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  if exists(select 1 from public.locations where company_id=p_company_id and upper(external_code)=upper(trim(p_external_code)) and id is distinct from p_location_id) then raise exception 'Ya existe una ubicación con ese código.';end if;
  raise;
end $$;

create or replace function public.get_initial_migration_readiness(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_locations bigint;v_users bigint;v_products bigint;v_snapshots bigint;v_customers bigint;v_suppliers bigint;v_accounting bigint;v_banks bigint;v_files bigint;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'Empresa no disponible.';end if;
  select count(*) into v_locations from public.locations where company_id=p_company_id and is_active;
  select count(distinct user_id) into v_users from public.user_roles where company_id=p_company_id;
  select count(*) into v_products from public.products where company_id=p_company_id;
  select count(*) into v_snapshots from public.inventory_snapshots where company_id=p_company_id and status='completed';
  select count(*) into v_customers from public.customers where company_id=p_company_id;
  select count(*) into v_suppliers from public.suppliers where company_id=p_company_id;
  select count(*) into v_accounting from public.accounting_config_versions where company_id=p_company_id and status='approved';
  select count(*) into v_banks from public.financial_accounts where company_id=p_company_id and is_active;
  select count(*) into v_files from public.import_batches where company_id=p_company_id;
  return jsonb_build_object('observed_at',now(),'files',v_files,'steps',jsonb_build_array(
    jsonb_build_object('code','company','label','Empresa y sucursales','description','Estructura operativa donde ocurren ventas, inventario y caja.','count',v_locations,'ready',v_locations>0,'href','/satrapy/configuracion/empresa/sucursales'),
    jsonb_build_object('code','responsibles','label','Responsables','description','Personas con acceso vigente a la empresa.','count',v_users,'ready',v_users>0,'href','/satrapy/configuracion'),
    jsonb_build_object('code','catalog','label','Catálogo de productos','description','Productos canónicos disponibles para operar.','count',v_products,'ready',v_products>0,'href','/satrapy/configuracion/importaciones'),
    jsonb_build_object('code','inventory','label','Inventario inicial','description','Existencias promovidas y conciliadas por ubicación.','count',v_snapshots,'ready',v_snapshots>0,'href','/satrapy/configuracion/importaciones'),
    jsonb_build_object('code','customers','label','Clientes y cuentas por cobrar','description','Maestros y saldos disponibles cuando aplican.','count',v_customers,'ready',v_customers>0,'href','/satrapy/configuracion/importaciones'),
    jsonb_build_object('code','purchasing','label','Proveedores y cuentas por pagar','description','Proveedores, documentos y pagos preservados.','count',v_suppliers,'ready',v_suppliers>0,'href','/satrapy/configuracion/importaciones'),
    jsonb_build_object('code','accounting','label','Contabilidad','description','Configuración aprobada, catálogo y apertura trazable.','count',v_accounting,'ready',v_accounting>0,'href','/satrapy/contabilidad/configuracion'),
    jsonb_build_object('code','banking','label','Bancos','description','Cuentas financieras listas para estados y conciliación.','count',v_banks,'ready',v_banks>0,'href','/satrapy/configuracion/cuentas-bancarias')
  ));
end $$;

revoke all on function public.list_company_locations(uuid,text,text,text,integer,integer) from public;
revoke all on function public.save_company_location(uuid,uuid,text,text,text,boolean,text,timestamptz,uuid) from public;
revoke all on function public.get_initial_migration_readiness(uuid) from public;
grant execute on function public.list_company_locations(uuid,text,text,text,integer,integer) to authenticated;
grant execute on function public.save_company_location(uuid,uuid,text,text,text,boolean,text,timestamptz,uuid) to authenticated;
grant execute on function public.get_initial_migration_readiness(uuid) to authenticated;
