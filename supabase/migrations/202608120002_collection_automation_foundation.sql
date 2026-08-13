-- Automatización de cobranza · Fase 1.
-- Fundación durable y neutral: no genera casos desde CxC ni integra proveedores.

insert into public.permissions(code,description) values
  ('view_collection_automation','Consultar estado técnico de automatización de cobranza.'),
  ('manage_collection_automation','Configurar y operar la fundación de automatización de cobranza.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in('super_admin','direccion_admin')
  and p.code in('view_collection_automation','manage_collection_automation')
on conflict do nothing;

create table public.collection_policy_versions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  version integer not null,
  status text not null default 'draft' check(status in('draft','approved','superseded')),
  timezone text,
  allowed_weekdays smallint[],
  contact_window_start time,
  contact_window_end time,
  minimum_contact_interval interval,
  maximum_attempts integer check(maximum_attempts between 1 and 20),
  operational_owner_id uuid references auth.users(id) on delete restrict,
  escalation_owner_id uuid references auth.users(id) on delete restrict,
  reason text not null check(length(trim(reason))>0),
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  effective_from timestamptz,
  effective_to timestamptz,
  created_by uuid references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,version),
  check(contact_window_start is null or contact_window_end is null or contact_window_start<contact_window_end),
  check(effective_to is null or effective_from is null or effective_to>effective_from),
  check((status<>'approved') or(approved_by is not null and approved_at is not null and effective_from is not null))
);
create unique index collection_policy_one_approved_idx on public.collection_policy_versions(company_id) where status='approved';

create table public.collection_cases(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  status text not null default 'pending' check(status in('pending','managing','requires_human','closed')),
  technical_reason text not null check(length(trim(technical_reason))>0),
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,customer_id)
);

create table public.collection_tasks(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.collection_cases(id) on delete cascade,
  policy_version_id uuid not null references public.collection_policy_versions(id) on delete restrict,
  task_type text not null check(length(trim(task_type))>0),
  purpose text not null check(length(trim(purpose))>0),
  reason text not null check(length(trim(reason))>0),
  status text not null default 'pending' check(status in('pending','leased','completed','failed','cancelled')),
  run_at timestamptz not null,
  priority smallint not null default 0 check(priority between -100 and 100),
  channel text check(channel in('internal','email','whatsapp','voice')),
  attempt_count integer not null default 0 check(attempt_count>=0),
  maximum_attempts integer not null check(maximum_attempts between 1 and 20),
  lease_owner text,
  lease_expires_at timestamptz,
  idempotency_key text not null check(length(trim(idempotency_key))>0),
  last_error text,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_reason text,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id,idempotency_key),
  check((status='leased')=(lease_owner is not null and lease_expires_at is not null)),
  check(status<>'cancelled' or(cancelled_at is not null and length(trim(cancelled_reason))>0))
);
create index collection_tasks_claim_idx on public.collection_tasks(run_at,priority desc,created_at) where status in('pending','leased');
create unique index collection_tasks_equivalent_pending_idx on public.collection_tasks(case_id,task_type,purpose) where status in('pending','leased');

create table public.collection_executions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  task_id uuid not null references public.collection_tasks(id) on delete cascade,
  attempt integer not null,
  worker_id text not null,
  status text not null check(status in('running','completed','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  error_code text,
  error_detail text,
  result jsonb not null default '{}'::jsonb,
  unique(task_id,attempt)
);

create table public.collection_actions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.collection_cases(id) on delete cascade,
  task_id uuid references public.collection_tasks(id) on delete restrict,
  execution_id uuid references public.collection_executions(id) on delete restrict,
  action_type text not null,
  reason text not null check(length(trim(reason))>0),
  safe_arguments jsonb not null default '{}'::jsonb,
  result jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  unique(company_id,idempotency_key)
);

create table public.collection_proposals(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.collection_cases(id) on delete cascade,
  task_id uuid references public.collection_tasks(id) on delete restrict,
  proposal_type text not null,
  content jsonb not null,
  evidence jsonb not null default '[]'::jsonb,
  reason text not null check(length(trim(reason))>0),
  risk text not null check(risk in('low','medium','high')),
  status text not null default 'pending' check(status in('pending','approved','rejected','expired','applied')),
  decided_by uuid references auth.users(id) on delete restrict,
  decided_at timestamptz,
  decision_reason text,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create trigger collection_cases_updated_at before update on public.collection_cases for each row execute function public.set_updated_at();
create trigger collection_tasks_updated_at before update on public.collection_tasks for each row execute function public.set_updated_at();

create or replace function public.collection_policy_is_complete(p public.collection_policy_versions)
returns boolean language sql immutable as $$select p.timezone is not null and cardinality(p.allowed_weekdays)>0
  and p.contact_window_start is not null and p.contact_window_end is not null
  and p.minimum_contact_interval is not null and p.maximum_attempts is not null
  and p.operational_owner_id is not null and p.escalation_owner_id is not null$$;

create or replace function public.collection_assert_worker_access(p_company_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$begin
  if auth.role()<>'service_role' and(auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collection_automation')) then
    raise exception 'No autorizado para operar automatización de cobranza.';
  end if;
end$$;

create or replace function public.collection_save_policy_draft(
  p_company_id uuid,p_reason text,p_timezone text default null,p_allowed_weekdays smallint[] default null,
  p_contact_window_start time default null,p_contact_window_end time default null,p_minimum_contact_interval interval default null,
  p_maximum_attempts integer default null,p_operational_owner_id uuid default null,p_escalation_owner_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.collection_policy_versions%rowtype;v_version integer;
begin
  perform public.collection_assert_worker_access(p_company_id);if auth.uid() is null then raise exception 'Un usuario debe crear la política.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Motivo obligatorio.';end if;
  perform pg_advisory_xact_lock(hashtextextended('collection-policy:'||p_company_id::text,0));
  select coalesce(max(version),0)+1 into v_version from public.collection_policy_versions where company_id=p_company_id;
  insert into public.collection_policy_versions(company_id,version,timezone,allowed_weekdays,contact_window_start,contact_window_end,minimum_contact_interval,maximum_attempts,operational_owner_id,escalation_owner_id,reason,created_by)
  values(p_company_id,v_version,nullif(trim(p_timezone),''),p_allowed_weekdays,p_contact_window_start,p_contact_window_end,p_minimum_contact_interval,p_maximum_attempts,p_operational_owner_id,p_escalation_owner_id,trim(p_reason),auth.uid()) returning * into v;
  perform public.write_sales_audit(p_company_id,'collection.policy_draft_created','collection_policy_versions',v.id,jsonb_build_object('version',v.version,'complete',public.collection_policy_is_complete(v),'reason',v.reason));return to_jsonb(v)||jsonb_build_object('complete',public.collection_policy_is_complete(v));
end$$;

create or replace function public.collection_approve_policy(p_company_id uuid,p_policy_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_policy_versions%rowtype;begin
  perform public.collection_assert_worker_access(p_company_id);if auth.uid() is null then raise exception 'Un usuario debe aprobar la política.';end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Motivo de aprobación obligatorio.';end if;
  select * into v from public.collection_policy_versions where id=p_policy_id and company_id=p_company_id and status='draft' for update;
  if not found then raise exception 'Borrador de política no disponible.';end if;
  if not public.collection_policy_is_complete(v) then raise exception 'La política está incompleta.';end if;
  update public.collection_policy_versions set status='superseded',effective_to=clock_timestamp() where company_id=p_company_id and status='approved';
  update public.collection_policy_versions set status='approved',approved_by=auth.uid(),approved_at=clock_timestamp(),effective_from=clock_timestamp(),reason=v.reason||E'\nAprobación: '||trim(p_reason) where id=v.id returning * into v;
  perform public.write_sales_audit(p_company_id,'collection.policy_approved','collection_policy_versions',v.id,jsonb_build_object('version',v.version,'reason',p_reason));return to_jsonb(v);
end$$;

create or replace function public.collection_enqueue_task(
  p_company_id uuid,p_case_id uuid,p_task_type text,p_purpose text,p_reason text,p_run_at timestamptz,
  p_priority smallint,p_channel text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_policy public.collection_policy_versions%rowtype;v_task public.collection_tasks%rowtype;
begin
  perform public.collection_assert_worker_access(p_company_id);
  select * into v_policy from public.collection_policy_versions where company_id=p_company_id and status='approved'
    and effective_from<=clock_timestamp() and(effective_to is null or effective_to>clock_timestamp()) for share;
  if not found or not public.collection_policy_is_complete(v_policy) then raise exception 'Automatización de cobranza no configurada.';end if;
  if not exists(select 1 from public.collection_cases where id=p_case_id and company_id=p_company_id and status<>'closed') then raise exception 'Caso de cobranza no disponible.';end if;
  insert into public.collection_tasks(company_id,case_id,policy_version_id,task_type,purpose,reason,run_at,priority,channel,maximum_attempts,idempotency_key,created_by)
  values(p_company_id,p_case_id,v_policy.id,trim(p_task_type),trim(p_purpose),trim(p_reason),p_run_at,coalesce(p_priority,0),p_channel,v_policy.maximum_attempts,trim(p_idempotency_key),auth.uid())
  on conflict(company_id,idempotency_key) do update set idempotency_key=excluded.idempotency_key
  returning * into v_task;
  perform public.write_sales_audit(p_company_id,'collection.task_enqueued','collection_tasks',v_task.id,jsonb_build_object('case_id',p_case_id,'task_type',p_task_type,'purpose',p_purpose,'run_at',p_run_at));
  return to_jsonb(v_task);
end$$;

create or replace function public.collection_claim_tasks(p_worker_id text,p_batch_size integer default 25,p_lease_seconds integer default 60)
returns setof public.collection_tasks language plpgsql security definer set search_path=public as $$begin
  if auth.role()<>'service_role' then raise exception 'Solo el worker puede reclamar tareas.';end if;
  if nullif(trim(p_worker_id),'') is null then raise exception 'Worker requerido.';end if;
  if p_batch_size not between 1 and 100 or p_lease_seconds not between 15 and 900 then raise exception 'Parámetros de lease inválidos.';end if;
  return query
  with candidates as(
    select t.id from public.collection_tasks t join public.collection_policy_versions p on p.id=t.policy_version_id
    where(t.status='pending' or(t.status='leased' and t.lease_expires_at<=clock_timestamp())) and t.run_at<=clock_timestamp()
      and t.attempt_count<t.maximum_attempts and p.status='approved' and public.collection_policy_is_complete(p)
      and p.effective_from<=clock_timestamp() and(p.effective_to is null or p.effective_to>clock_timestamp())
    order by t.priority desc,t.run_at,t.created_at for update of t skip locked limit p_batch_size
  )
  update public.collection_tasks t set status='leased',lease_owner=trim(p_worker_id),lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds),attempt_count=t.attempt_count+1,last_error=null
  from candidates c where t.id=c.id returning t.*;
end$$;

create or replace function public.collection_finish_task(p_task_id uuid,p_worker_id text,p_success boolean,p_result jsonb default '{}'::jsonb,p_error text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_task public.collection_tasks%rowtype;v_execution public.collection_executions%rowtype;v_terminal boolean;v_delay interval;
begin
  if auth.role()<>'service_role' then raise exception 'Solo el worker puede finalizar tareas.';end if;
  select * into v_task from public.collection_tasks where id=p_task_id for update;
  if not found or v_task.status<>'leased' or v_task.lease_owner<>p_worker_id then raise exception 'Lease de tarea inválido.';end if;
  insert into public.collection_executions(company_id,task_id,attempt,worker_id,status,finished_at,error_detail,result)
  values(v_task.company_id,v_task.id,v_task.attempt_count,p_worker_id,case when p_success then 'completed' else 'failed' end,clock_timestamp(),case when p_success then null else left(coalesce(p_error,'Error sin detalle'),2000) end,coalesce(p_result,'{}'))
  on conflict(task_id,attempt) do update set status=excluded.status,finished_at=excluded.finished_at,error_detail=excluded.error_detail,result=excluded.result returning * into v_execution;
  if p_success then
    update public.collection_tasks set status='completed',completed_at=clock_timestamp(),lease_owner=null,lease_expires_at=null where id=v_task.id returning * into v_task;
    insert into public.collection_actions(company_id,case_id,task_id,execution_id,action_type,reason,result,idempotency_key)
    values(v_task.company_id,v_task.case_id,v_task.id,v_execution.id,'task_completed',v_task.reason,coalesce(p_result,'{}'),v_task.idempotency_key||':completed') on conflict(company_id,idempotency_key) do nothing;
  else
    v_terminal:=v_task.attempt_count>=v_task.maximum_attempts;v_delay:=make_interval(secs=>least(3600,30*power(2,v_task.attempt_count-1)::integer));
    update public.collection_tasks set status=case when v_terminal then 'failed' else 'pending' end,run_at=case when v_terminal then run_at else clock_timestamp()+v_delay end,last_error=left(coalesce(p_error,'Error sin detalle'),2000),lease_owner=null,lease_expires_at=null where id=v_task.id returning * into v_task;
  end if;
  perform public.write_sales_audit(v_task.company_id,case when p_success then 'collection.task_completed' else 'collection.task_failed' end,'collection_tasks',v_task.id,jsonb_build_object('attempt',v_task.attempt_count,'terminal',coalesce(v_terminal,false)));
  return to_jsonb(v_task);
end$$;

create or replace function public.collection_cancel_task(p_company_id uuid,p_task_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_tasks%rowtype;begin
  perform public.collection_assert_worker_access(p_company_id);if nullif(trim(p_reason),'') is null then raise exception 'Motivo obligatorio.';end if;
  update public.collection_tasks set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason=trim(p_reason),lease_owner=null,lease_expires_at=null
  where id=p_task_id and company_id=p_company_id and status in('pending','leased') returning * into v;
  if not found then raise exception 'Tarea no cancelable.';end if;
  perform public.write_sales_audit(p_company_id,'collection.task_cancelled','collection_tasks',v.id,jsonb_build_object('reason',p_reason));return to_jsonb(v);
end$$;

create or replace function public.collection_list_tasks(p_company_id uuid,p_status text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;v_configuration text;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar automatización.';end if;
  select case when exists(select 1 from public.collection_policy_versions p where p.company_id=p_company_id and p.status='approved' and public.collection_policy_is_complete(p) and p.effective_from<=clock_timestamp() and(p.effective_to is null or p.effective_to>clock_timestamp())) then 'configured' else 'not_configured' end into v_configuration;
  select count(*) into v_total from public.collection_tasks t where t.company_id=p_company_id and(p_status is null or t.status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.priority desc,x.run_at,x.id),'[]') into v_items from(
    select t.id,t.case_id,t.task_type,t.purpose,t.reason,t.status,t.run_at,t.priority,t.channel,t.attempt_count,t.maximum_attempts,t.lease_expires_at,t.last_error,t.created_at
    from public.collection_tasks t where t.company_id=p_company_id and(p_status is null or t.status=p_status)
    order by t.priority desc,t.run_at,t.id limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('configuration_status',v_configuration,'items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

alter table public.collection_policy_versions enable row level security;alter table public.collection_cases enable row level security;alter table public.collection_tasks enable row level security;alter table public.collection_executions enable row level security;alter table public.collection_actions enable row level security;alter table public.collection_proposals enable row level security;
create policy collection_policy_read on public.collection_policy_versions for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
create policy collection_cases_read on public.collection_cases for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
create policy collection_tasks_read on public.collection_tasks for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
create policy collection_executions_read on public.collection_executions for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
create policy collection_actions_read on public.collection_actions for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
create policy collection_proposals_read on public.collection_proposals for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
revoke all on public.collection_policy_versions,public.collection_cases,public.collection_tasks,public.collection_executions,public.collection_actions,public.collection_proposals from authenticated;
grant select on public.collection_policy_versions,public.collection_cases,public.collection_tasks,public.collection_executions,public.collection_actions,public.collection_proposals to authenticated;
revoke all on function public.collection_save_policy_draft(uuid,text,text,smallint[],time,time,interval,integer,uuid,uuid),public.collection_approve_policy(uuid,uuid,text),public.collection_enqueue_task(uuid,uuid,text,text,text,timestamptz,smallint,text,text),public.collection_claim_tasks(text,integer,integer),public.collection_finish_task(uuid,text,boolean,jsonb,text),public.collection_cancel_task(uuid,uuid,text),public.collection_list_tasks(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.collection_save_policy_draft(uuid,text,text,smallint[],time,time,interval,integer,uuid,uuid),public.collection_approve_policy(uuid,uuid,text),public.collection_enqueue_task(uuid,uuid,text,text,text,timestamptz,smallint,text,text),public.collection_cancel_task(uuid,uuid,text),public.collection_list_tasks(uuid,text,integer,integer) to authenticated;
grant execute on function public.collection_claim_tasks(text,integer,integer),public.collection_finish_task(uuid,text,boolean,jsonb,text) to service_role;
