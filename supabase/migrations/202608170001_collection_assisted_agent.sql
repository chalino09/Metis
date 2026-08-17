-- Automatización de cobranza · Fase 3: agente asistido y aprobaciones.
-- El agente sólo prepara propuestas. Ninguna RPC registra pagos, modifica CxC
-- ni envía comunicaciones.

alter table public.collection_executions
  add column if not exists model text,
  add column if not exists prompt_version text,
  add column if not exists input_tokens integer check(input_tokens is null or input_tokens>=0),
  add column if not exists output_tokens integer check(output_tokens is null or output_tokens>=0),
  add column if not exists estimated_cost_usd numeric(14,6) check(estimated_cost_usd is null or estimated_cost_usd>=0),
  add column if not exists provider_trace_id text;

alter table public.collection_proposals
  add column if not exists balance_snapshot numeric(14,2) check(balance_snapshot is null or balance_snapshot>=0),
  add column if not exists model text,
  add column if not exists prompt_version text,
  add column if not exists updated_at timestamptz not null default now();

create index if not exists collection_proposals_review_idx
  on public.collection_proposals(company_id,status,expires_at,created_at desc);
create unique index if not exists collection_proposals_one_per_task_idx
  on public.collection_proposals(task_id) where task_id is not null;

create or replace function public.collection_get_agent_context(p_task_id uuid,p_worker_id text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_task public.collection_tasks%rowtype;v_case public.collection_cases%rowtype;v_balance numeric;begin
  if auth.role()<>'service_role' then raise exception 'Solo el worker puede consultar contexto asistido.';end if;
  select * into v_task from public.collection_tasks where id=p_task_id and status='leased' and lease_owner=p_worker_id and lease_expires_at>clock_timestamp();
  if not found or v_task.task_type<>'assisted_review' then raise exception 'Tarea asistida o lease no disponible.';end if;
  select * into v_case from public.collection_cases where id=v_task.case_id and company_id=v_task.company_id and status<>'closed';
  if not found then raise exception 'Caso de cobranza no disponible.';end if;
  if exists(select 1 from public.collection_blocks where case_id=v_case.id and status='active') then raise exception 'El caso tiene un bloqueo activo.';end if;
  select coalesce(sum(outstanding_amount),0) into v_balance from public.customer_receivables where company_id=v_case.company_id and customer_id=v_case.customer_id and outstanding_amount>0;
  if v_balance<=0 then raise exception 'El caso ya no tiene saldo abierto.';end if;
  return jsonb_build_object(
    'task',jsonb_build_object('id',v_task.id,'reason',v_task.reason,'purpose',v_task.purpose),
    'case',jsonb_build_object('id',v_case.id,'priority_score',v_case.priority_score,'balance_snapshot',v_balance),
    'customer',(select jsonb_build_object('code',c.code,'display_name',c.display_name) from public.customers c where c.id=v_case.customer_id),
    'contact',coalesce((select jsonb_build_object('display_name',c.display_name,'role_name',c.role_name,'has_phone',nullif(trim(c.phone),'') is not null,'has_email',nullif(trim(c.email),'') is not null) from public.customer_contacts c where c.company_id=v_case.company_id and c.customer_id=v_case.customer_id order by c.is_primary desc,c.created_at limit 1),'null'::jsonb),
    'documents',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'due_date',r.due_date,'outstanding_amount',r.outstanding_amount) order by r.due_date) from public.customer_receivables r where r.company_id=v_case.company_id and r.customer_id=v_case.customer_id and r.outstanding_amount>0),'[]'::jsonb),
    'recent_payments',coalesce((select jsonb_agg(jsonb_build_object('received_at',p.received_at,'amount',p.amount) order by p.received_at desc) from(select * from public.receivable_payments where company_id=v_case.company_id and customer_id=v_case.customer_id order by received_at desc limit 10)p),'[]'::jsonb)
  );
end$$;

create or replace function public.collection_record_agent_proposal(
  p_task_id uuid,p_worker_id text,p_content jsonb,p_evidence jsonb,p_reason text,p_risk text,
  p_model text,p_prompt_version text,p_expires_at timestamptz,p_usage jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_task public.collection_tasks%rowtype;v_case public.collection_cases%rowtype;v_proposal public.collection_proposals%rowtype;v_balance numeric;begin
  if auth.role()<>'service_role' then raise exception 'Solo el worker puede registrar propuestas.';end if;
  select * into v_task from public.collection_tasks where id=p_task_id and status='leased' and lease_owner=p_worker_id and lease_expires_at>clock_timestamp() for update;
  if not found or v_task.task_type<>'assisted_review' then raise exception 'Tarea asistida o lease no disponible.';end if;
  select * into v_case from public.collection_cases where id=v_task.case_id and company_id=v_task.company_id and status<>'closed' for update;
  if not found or exists(select 1 from public.collection_blocks where case_id=v_task.case_id and status='active') then raise exception 'El caso ya no admite propuestas.';end if;
  select coalesce(sum(outstanding_amount),0) into v_balance from public.customer_receivables where company_id=v_task.company_id and customer_id=v_case.customer_id and outstanding_amount>0;
  if v_balance<=0 or p_expires_at<=clock_timestamp() then raise exception 'Saldo o vigencia inválidos.';end if;
  if p_risk not in('low','medium','high') or nullif(trim(p_reason),'') is null or jsonb_typeof(p_content)<>'object' or jsonb_typeof(p_evidence)<>'array' then raise exception 'Propuesta inválida.';end if;
  insert into public.collection_proposals(company_id,case_id,task_id,proposal_type,content,evidence,reason,risk,expires_at,balance_snapshot,model,prompt_version)
  values(v_task.company_id,v_task.case_id,v_task.id,'contact_draft',p_content,p_evidence,trim(p_reason),p_risk,p_expires_at,v_balance,nullif(trim(p_model),''),nullif(trim(p_prompt_version),''))
  on conflict(task_id) where task_id is not null do update set content=excluded.content,evidence=excluded.evidence,reason=excluded.reason,risk=excluded.risk,expires_at=excluded.expires_at,balance_snapshot=excluded.balance_snapshot,model=excluded.model,prompt_version=excluded.prompt_version,updated_at=clock_timestamp()
  returning * into v_proposal;
  insert into public.collection_actions(company_id,case_id,task_id,action_type,reason,safe_arguments,result,idempotency_key)
  values(v_task.company_id,v_task.case_id,v_task.id,'proposal_created',trim(p_reason),jsonb_build_object('proposal_id',v_proposal.id,'model',p_model,'prompt_version',p_prompt_version),jsonb_build_object('risk',p_risk,'balance_snapshot',v_balance),v_task.idempotency_key||':proposal') on conflict do nothing;
  return to_jsonb(v_proposal);
end$$;

create or replace function public.collection_finish_assisted_task(
  p_task_id uuid,p_worker_id text,p_model text,p_prompt_version text,p_input_tokens integer,p_output_tokens integer,
  p_estimated_cost_usd numeric,p_trace_id text,p_result jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_task public.collection_tasks%rowtype;v_execution public.collection_executions%rowtype;v_proposal_id uuid;begin
  if auth.role()<>'service_role' then raise exception 'Solo el worker puede finalizar tareas asistidas.';end if;
  select * into v_task from public.collection_tasks where id=p_task_id and status='leased' and lease_owner=p_worker_id and lease_expires_at>clock_timestamp() for update;
  if not found or v_task.task_type<>'assisted_review' then raise exception 'Tarea asistida o lease no disponible.';end if;
  select id into v_proposal_id from public.collection_proposals where task_id=v_task.id and status='pending';
  if v_proposal_id is null then raise exception 'La tarea no produjo una propuesta pendiente.';end if;
  if coalesce(p_input_tokens,-1)<0 or coalesce(p_output_tokens,-1)<0 or coalesce(p_estimated_cost_usd,-1)<0 or nullif(trim(p_trace_id),'') is null then raise exception 'Telemetría asistida incompleta.';end if;
  insert into public.collection_executions(company_id,task_id,attempt,worker_id,status,finished_at,result,model,prompt_version,input_tokens,output_tokens,estimated_cost_usd,provider_trace_id)
  values(v_task.company_id,v_task.id,v_task.attempt_count,p_worker_id,'completed',clock_timestamp(),coalesce(p_result,'{}'),nullif(trim(p_model),''),nullif(trim(p_prompt_version),''),p_input_tokens,p_output_tokens,p_estimated_cost_usd,trim(p_trace_id))
  on conflict(task_id,attempt) do update set status='completed',finished_at=excluded.finished_at,result=excluded.result,model=excluded.model,prompt_version=excluded.prompt_version,input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,estimated_cost_usd=excluded.estimated_cost_usd,provider_trace_id=excluded.provider_trace_id returning * into v_execution;
  update public.collection_tasks set status='completed',completed_at=clock_timestamp(),lease_owner=null,lease_expires_at=null where id=v_task.id returning * into v_task;
  insert into public.collection_actions(company_id,case_id,task_id,execution_id,action_type,reason,result,idempotency_key)
  values(v_task.company_id,v_task.case_id,v_task.id,v_execution.id,'task_completed',v_task.reason,jsonb_build_object('mode','assisted','proposal_id',v_proposal_id),v_task.idempotency_key||':completed') on conflict(company_id,idempotency_key) do nothing;
  perform public.write_sales_audit(v_task.company_id,'collection.assisted_task_completed','collection_tasks',v_task.id,jsonb_build_object('attempt',v_task.attempt_count,'proposal_id',v_proposal_id,'input_tokens',p_input_tokens,'output_tokens',p_output_tokens,'estimated_cost_usd',p_estimated_cost_usd));
  return jsonb_build_object('task_id',v_task.id,'status',v_task.status,'proposal_id',v_proposal_id,'execution_id',v_execution.id);
end$$;

create or replace function public.collection_generate_assisted_reviews(p_company_id uuid,p_batch_size integer default 100,p_after_case_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$declare v_policy public.collection_policy_versions%rowtype;v_created integer;v_next uuid;v_has_more boolean;begin
  perform public.collection_assert_manage_access(p_company_id);perform public.collection_assert_operational_policy(p_company_id);
  if p_batch_size not between 1 and 500 then raise exception 'Tamaño de lote inválido.';end if;
  select * into v_policy from public.collection_policy_versions where company_id=p_company_id and status='approved' and effective_from<=clock_timestamp() and(effective_to is null or effective_to>clock_timestamp());
  with page as materialized(
    select cc.id from public.collection_cases cc where cc.company_id=p_company_id and cc.status in('pending','managing') and(p_after_case_id is null or cc.id>p_after_case_id)
      and not exists(select 1 from public.collection_blocks b where b.case_id=cc.id and b.status='active')
      and not exists(select 1 from public.collection_proposals p where p.case_id=cc.id and p.status='pending' and p.expires_at>clock_timestamp())
    order by cc.id limit p_batch_size
  ),created as(
    insert into public.collection_tasks(company_id,case_id,policy_version_id,task_type,purpose,reason,run_at,priority,channel,maximum_attempts,idempotency_key,created_by)
    select p_company_id,p.id,v_policy.id,'assisted_review','prepare_contact_proposal','Preparar propuesta para revisión humana',clock_timestamp(),0,'internal',v_policy.maximum_attempts,'assisted-review:'||p.id||':'||current_date,auth.uid() from page p
    on conflict do nothing returning 1
  )select count(*) into v_created from created;
  select x.id into v_next from(select cc.id from public.collection_cases cc where cc.company_id=p_company_id and cc.status in('pending','managing') and(p_after_case_id is null or cc.id>p_after_case_id) order by cc.id limit p_batch_size)x order by x.id desc limit 1;
  select exists(select 1 from public.collection_cases cc where cc.company_id=p_company_id and cc.status in('pending','managing') and(v_next is null or cc.id>v_next)) into v_has_more;
  perform public.write_sales_audit(p_company_id,'collection.assisted_reviews_generated','collection_tasks',null,jsonb_build_object('created',v_created,'next_cursor',v_next,'has_more',v_has_more));
  return jsonb_build_object('created',v_created,'next_cursor',v_next,'has_more',v_has_more);
end$$;

create or replace function public.collection_list_proposals(p_company_id uuid,p_status text default 'pending',p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql volatile security definer set search_path=public as $$declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar propuestas.';end if;
  if p_status not in('all','pending','approved','rejected','expired','applied') then raise exception 'Estado de propuesta no válido.';end if;
  update public.collection_proposals set status='expired',updated_at=clock_timestamp() where company_id=p_company_id and status='pending' and expires_at<=clock_timestamp();
  select count(*) into v_total from public.collection_proposals where company_id=p_company_id and(p_status='all' or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_items from(
    select p.id,p.content,p.risk,p.status,p.expires_at,p.balance_snapshot,p.created_at,p.decided_at,p.decision_reason,c.display_name customer_name,c.code customer_code
    from public.collection_proposals p join public.collection_cases cc on cc.id=p.case_id join public.customers c on c.id=cc.customer_id
    where p.company_id=p_company_id and(p_status='all' or p.status=p_status) order by p.created_at desc limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end$$;

create or replace function public.collection_apply_proposal(p_company_id uuid,p_proposal_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_proposals%rowtype;v_case public.collection_cases%rowtype;v_balance numeric;begin
  perform public.collection_assert_manage_access(p_company_id);
  if nullif(trim(p_reason),'') is null then raise exception 'Motivo de aplicación obligatorio.';end if;
  select * into v from public.collection_proposals where id=p_proposal_id and company_id=p_company_id and status='approved' for update;
  if not found then raise exception 'Propuesta aprobada no disponible.';end if;
  select * into v_case from public.collection_cases where id=v.case_id and company_id=p_company_id and status<>'closed' for update;if not found then raise exception 'El caso ya no está disponible.';end if;
  select coalesce(sum(outstanding_amount),0) into v_balance from public.customer_receivables where company_id=p_company_id and customer_id=v_case.customer_id and outstanding_amount>0;
  if v.expires_at<=clock_timestamp() or v_balance<>v.balance_snapshot or exists(select 1 from public.collection_blocks where case_id=v.case_id and status='active') then raise exception 'La propuesta venció o el contexto financiero cambió; genera una nueva.';end if;
  update public.collection_proposals set status='applied',decision_reason=concat_ws(E'\n',nullif(decision_reason,''),'Aplicación: '||trim(p_reason)),updated_at=clock_timestamp() where id=v.id returning * into v;
  insert into public.collection_actions(company_id,case_id,task_id,action_type,reason,safe_arguments,result,idempotency_key)
  values(p_company_id,v.case_id,v.task_id,'proposal_applied',trim(p_reason),jsonb_build_object('proposal_id',v.id),jsonb_build_object('ready_for_channel',true,'outbound_sent',false),v.id::text||':applied') on conflict(company_id,idempotency_key) do nothing;
  perform public.write_sales_audit(p_company_id,'collection.proposal_applied','collection_proposals',v.id,jsonb_build_object('reason',p_reason,'outbound_sent',false));
  return jsonb_build_object('id',v.id,'status',v.status,'outbound_sent',false);
end$$;

create or replace function public.collection_decide_proposal(p_company_id uuid,p_proposal_id uuid,p_decision text,p_reason text,p_content jsonb default null,p_expires_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_proposals%rowtype;v_case public.collection_cases%rowtype;v_balance numeric;begin
  perform public.collection_assert_manage_access(p_company_id);
  if p_decision not in('approve','reject','reschedule') or nullif(trim(p_reason),'') is null then raise exception 'Decisión y motivo obligatorios.';end if;
  select * into v from public.collection_proposals where id=p_proposal_id and company_id=p_company_id and status='pending' for update;
  if not found then raise exception 'Propuesta no disponible.';end if;
  select * into v_case from public.collection_cases where id=v.case_id and status<>'closed';if not found then raise exception 'El caso ya no está disponible.';end if;
  select coalesce(sum(outstanding_amount),0) into v_balance from public.customer_receivables where company_id=p_company_id and customer_id=v_case.customer_id and outstanding_amount>0;
  if p_decision='approve' and(v.expires_at<=clock_timestamp() or v_balance<>v.balance_snapshot or exists(select 1 from public.collection_blocks where case_id=v.case_id and status='active')) then raise exception 'La propuesta venció o el contexto financiero cambió; genera una nueva.';end if;
  if p_content is not null and jsonb_typeof(p_content)<>'object' then raise exception 'Contenido editado inválido.';end if;
  if p_decision='reschedule' and(p_expires_at is null or p_expires_at<=clock_timestamp()) then raise exception 'Nueva vigencia obligatoria.';end if;
  update public.collection_proposals set content=coalesce(p_content,content),status=case p_decision when'approve'then'approved' when'reject'then'rejected'else'pending'end,expires_at=case when p_decision='reschedule'then p_expires_at else expires_at end,decided_by=case when p_decision='reschedule'then null else auth.uid() end,decided_at=case when p_decision='reschedule'then null else clock_timestamp() end,decision_reason=trim(p_reason),updated_at=clock_timestamp() where id=v.id returning * into v;
  insert into public.collection_actions(company_id,case_id,task_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,v.case_id,v.task_id,'proposal_'||p_decision,trim(p_reason),jsonb_build_object('proposal_id',v.id,'edited',p_content is not null),jsonb_build_object('status',v.status),v.id::text||':'||p_decision||':'||extract(epoch from clock_timestamp())::bigint);
  perform public.write_sales_audit(p_company_id,'collection.proposal_'||p_decision,'collection_proposals',v.id,jsonb_build_object('reason',p_reason,'status',v.status));return jsonb_build_object('id',v.id,'status',v.status,'expires_at',v.expires_at);
end$$;

create or replace function public.collection_get_case(p_company_id uuid,p_case_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$declare v_case public.collection_cases%rowtype;v_customer public.customers%rowtype;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  select * into v_case from public.collection_cases where id=p_case_id and company_id=p_company_id;if not found then raise exception 'Caso no encontrado.';end if;select * into v_customer from public.customers where id=v_case.customer_id;
  return jsonb_build_object('case',to_jsonb(v_case),'customer',jsonb_build_object('id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name),'contact',coalesce((select to_jsonb(c)-'company_id'-'customer_id'-'created_by' from public.customer_contacts c where c.company_id=p_company_id and c.customer_id=v_case.customer_id order by c.is_primary desc,c.created_at limit 1),'null'),'documents',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',coalesce(r.source_reference,t.folio),'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at,r.id) from public.customer_receivables r left join public.canonical_tickets t on t.sale_id=r.sale_id where r.company_id=p_company_id and r.customer_id=v_case.customer_id and r.outstanding_amount>0),'[]'),'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'received_at',p.received_at,'payment_method_code',p.payment_method_code) order by p.received_at desc) from public.receivable_payments p where p.company_id=p_company_id and p.customer_id=v_case.customer_id),'[]'),'promises',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.collection_promises p where p.case_id=v_case.id),'[]'),'blocks',coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from public.collection_blocks b where b.case_id=v_case.id),'[]'),'assistant_history',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'summary',p.content->>'summary','draft',p.content->>'draft','channel',p.content->>'channel','recommendation',p.content->>'recommendation','risk',p.risk,'status',p.status,'balance_snapshot',p.balance_snapshot,'created_at',p.created_at,'decided_at',p.decided_at,'decision_reason',p.decision_reason) order by p.created_at desc) from public.collection_proposals p where p.case_id=v_case.id),'[]'),'timeline',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'type',a.action_type,'reason',a.reason,'created_at',a.created_at,'result',a.result) order by a.created_at desc) from public.collection_actions a where a.case_id=v_case.id),'[]'));
end$$;

revoke all on function public.collection_get_agent_context(uuid,text),public.collection_record_agent_proposal(uuid,text,jsonb,jsonb,text,text,text,text,timestamptz,jsonb),public.collection_finish_assisted_task(uuid,text,text,text,integer,integer,numeric,text,jsonb),public.collection_generate_assisted_reviews(uuid,integer,uuid),public.collection_list_proposals(uuid,text,integer,integer),public.collection_decide_proposal(uuid,uuid,text,text,jsonb,timestamptz),public.collection_apply_proposal(uuid,uuid,text),public.collection_get_case(uuid,uuid) from public,anon,authenticated;
grant execute on function public.collection_get_agent_context(uuid,text),public.collection_record_agent_proposal(uuid,text,jsonb,jsonb,text,text,text,text,timestamptz,jsonb),public.collection_finish_assisted_task(uuid,text,text,text,integer,integer,numeric,text,jsonb) to service_role;
grant execute on function public.collection_generate_assisted_reviews(uuid,integer,uuid),public.collection_list_proposals(uuid,text,integer,integer),public.collection_decide_proposal(uuid,uuid,text,text,jsonb,timestamptz),public.collection_apply_proposal(uuid,uuid,text),public.collection_get_case(uuid,uuid) to authenticated;

-- Los detalles técnicos sólo son accesibles mediante RPC con respuesta mínima.
-- RLS a nivel empresa no sustituye la minimización de datos entregados al navegador.
revoke select on public.collection_proposals,public.collection_executions,public.collection_actions from authenticated;
