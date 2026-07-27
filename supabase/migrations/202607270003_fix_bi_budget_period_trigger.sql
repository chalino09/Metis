-- Corrige el validador que se ejecuta antes de insertar o modificar una
-- versión. Instalaciones que aplicaron Fase 5 originalmente conservaron aquí
-- el intervalo inválido aunque el RPC de guardado ya estuviera corregido.

create or replace function public.bi_validate_budget_version()
returns trigger language plpgsql set search_path=public as $$
declare v_company uuid;v_start date;v_end date;
begin
  select company_id into v_company from public.bi_budgets where id=new.budget_id;
  if v_company is null or v_company<>new.company_id then
    raise exception'El presupuesto no pertenece a la empresa.';
  end if;
  if new.location_id is not null and not exists(
    select 1 from public.locations where id=new.location_id and company_id=new.company_id
  )then raise exception'Ubicación canónica inválida.';end if;
  if new.collaborator_id is not null and not exists(
    select 1 from public.collaborators where id=new.collaborator_id and company_id=new.company_id
  )then raise exception'Responsable canónico inválido.';end if;
  if new.category_id is not null and not exists(
    select 1 from public.product_categories where id=new.category_id and company_id=new.company_id
  )then raise exception'Categoría canónica inválida.';end if;

  if new.period_type='monthly'then
    v_start:=date_trunc('month',new.period_start)::date;
    v_end:=(v_start+interval'1 month'-interval'1 day')::date;
  elsif new.period_type='quarterly'then
    v_start:=date_trunc('quarter',new.period_start)::date;
    v_end:=(v_start+interval'3 months'-interval'1 day')::date;
  elsif new.period_type='annual'then
    v_start:=date_trunc('year',new.period_start)::date;
    v_end:=(v_start+interval'1 year'-interval'1 day')::date;
  else
    raise exception'Tipo de periodo inválido.';
  end if;
  if new.period_start<>v_start or new.period_end<>v_end then
    raise exception'El periodo no coincide con el tipo seleccionado.';
  end if;
  if tg_op='UPDATE'and old.status in('approved','superseded')
    and not(old.status='approved'and new.status='superseded'
      and(to_jsonb(new)-'status'-'updated_at')=(to_jsonb(old)-'status'-'updated_at'))
    and to_jsonb(new)is distinct from to_jsonb(old)then
    raise exception'Una versión aprobada no puede modificarse destructivamente.';
  end if;
  return new;
end$$;

create or replace function public.bi_promote_budget_import(p_company_id uuid,p_batch_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.bi_budget_import_batches%rowtype;r public.bi_budget_import_rows%rowtype;budget uuid;v public.bi_budget_versions%rowtype;v_end date;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'import_bi_budgets')
    or not public.has_company_permission(p_company_id,'create_bi_budget_drafts')then
    raise exception'No autorizado para promover presupuestos.';
  end if;
  if nullif(trim(coalesce(p_reason,'')),'')is null then
    raise exception'El motivo de promoción es obligatorio.';
  end if;
  select*into b from public.bi_budget_import_batches
  where id=p_batch_id and company_id=p_company_id for update;
  if not found then raise exception'Lote no disponible.';end if;
  if b.status='promoted'then
    return jsonb_build_object('batch_id',b.id,'status',b.status,'promoted_count',b.promoted_count,'idempotent',true);
  end if;
  if b.error_count>0 then raise exception'Corrige todas las filas inválidas antes de promover.';end if;
  for r in select*from public.bi_budget_import_rows where batch_id=b.id order by row_number for update loop
    if r.promoted_version_id is not null then continue;end if;
    if r.normalized_data->>'period_type'='monthly'then
      v_end:=(date_trunc('month',(r.normalized_data->>'period_start')::date)+interval'1 month'-interval'1 day')::date;
    elsif r.normalized_data->>'period_type'='quarterly'then
      v_end:=(date_trunc('quarter',(r.normalized_data->>'period_start')::date)+interval'3 months'-interval'1 day')::date;
    else
      v_end:=(date_trunc('year',(r.normalized_data->>'period_start')::date)+interval'1 year'-interval'1 day')::date;
    end if;
    insert into public.bi_budgets(company_id)values(p_company_id)returning id into budget;
    insert into public.bi_budget_versions(
      budget_id,company_id,version,name,description,metric_code,period_type,period_start,period_end,
      scope_type,location_id,collaborator_id,category_id,value,unit_code,owner_user_id
    )values(
      budget,p_company_id,1,r.normalized_data->>'name',r.normalized_data->>'description',
      r.normalized_data->>'metric_code',r.normalized_data->>'period_type',
      (r.normalized_data->>'period_start')::date,v_end,r.normalized_data->>'scope_type',
      r.location_id,r.collaborator_id,r.category_id,(r.normalized_data->>'value')::numeric,
      r.normalized_data->>'unit_code',auth.uid()
    )returning*into v;
    update public.bi_budget_import_rows set promoted_version_id=v.id where id=r.id;
    insert into public.bi_budget_version_events(company_id,version_id,action,reason,snapshot)
    values(p_company_id,v.id,'imported',trim(p_reason),to_jsonb(v));
  end loop;
  update public.bi_budget_import_batches set
    status='promoted',promoted_count=row_count,promoted_at=now()
  where id=b.id returning*into b;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'bi.budget_import_promoted','bi_budget_import_batch',b.id,
    jsonb_build_object('rows',b.promoted_count,'reason',trim(p_reason)));
  return jsonb_build_object('batch_id',b.id,'status',b.status,'promoted_count',b.promoted_count,'idempotent',false);
end$$;

do $verify$
declare trigger_definition text;save_definition text;
begin
  if(date'2026-01-01'+interval'1 year'-interval'1 day')::date<>date'2026-12-31'then
    raise exception'Falló la verificación del cierre anual.';
  end if;
  trigger_definition:=pg_get_functiondef('public.bi_validate_budget_version()'::regprocedure);
  if position('1 year-1 day'in trigger_definition)>0
    or position('3 months-1 day'in trigger_definition)>0
    or position('1 month-1 day'in trigger_definition)>0 then
    raise exception'El trigger de presupuestos conserva el cálculo de periodo anterior.';
  end if;
  if not exists(
    select 1 from pg_trigger t
    join pg_proc p on p.oid=t.tgfoid
    where t.tgrelid='public.bi_budget_versions'::regclass
      and t.tgname='bi_budget_versions_validate'
      and p.oid='public.bi_validate_budget_version()'::regprocedure
      and not t.tgisinternal
  )then raise exception'El trigger de presupuestos no apunta al validador corregido.';end if;
  save_definition:=pg_get_functiondef(
    'public.bi_save_budget_draft(uuid,uuid,text,text,text,text,date,text,uuid,uuid,uuid,numeric,text,uuid,uuid,uuid,text,jsonb)'::regprocedure
  );
  if position('bi_save_budget_draft_phase5'in save_definition)>0 then
    raise exception'El RPC público todavía depende de la función de guardado anterior; aplica primero 202607270002.';
  end if;
end$verify$;

notify pgrst,'reload schema';
