-- Fase 2: cobranza operativa determinista, agrupada por cliente y sin IA.

alter table public.collection_cases
  add column assigned_to uuid references auth.users(id) on delete restrict,
  add column next_action_at timestamptz,
  add column next_action_reason text,
  add column priority_score smallint not null default 0 check(priority_score between 0 and 100),
  add column closed_at timestamptz,
  add column closed_reason text;

alter table public.collection_cases
  add constraint collection_case_next_action_complete check(
    (next_action_at is null and next_action_reason is null) or
    (next_action_at is not null and assigned_to is not null and length(trim(next_action_reason))>0)
  ),
  add constraint collection_case_close_complete check(
    status<>'closed' or(closed_at is not null and length(trim(closed_reason))>0)
  );

create index collection_cases_queue_idx on public.collection_cases(company_id,status,priority_score desc,next_action_at,updated_at);

create table public.collection_promises(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.collection_cases(id) on delete cascade,
  amount numeric(18,2) not null check(amount>0),
  promised_for date not null,
  status text not null default 'active' check(status in('active','fulfilled','broken','cancelled')),
  evidence text not null check(length(trim(evidence))>0),
  resolution_reason text,
  resolved_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  check(status='active' or(resolved_at is not null and length(trim(resolution_reason))>0))
);
create unique index collection_one_active_promise_idx on public.collection_promises(case_id) where status='active';
create index collection_promises_case_idx on public.collection_promises(case_id,created_at desc);

alter table public.collection_promises enable row level security;
create policy collection_promises_read on public.collection_promises for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
revoke all on public.collection_promises from authenticated;
grant select on public.collection_promises to authenticated;

create or replace function public.collection_assert_manage_access(p_company_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_collection_automation') then
    raise exception 'No autorizado para gestionar cobranza.';
  end if;
end $$;

create or replace function public.collection_assert_operational_policy(p_company_id uuid)
returns void language plpgsql stable security definer set search_path=public as $$begin
  if not exists(select 1 from public.collection_policy_versions p where p.company_id=p_company_id and p.status='approved' and public.collection_policy_is_complete(p) and p.effective_from<=clock_timestamp() and(p.effective_to is null or p.effective_to>clock_timestamp())) then
    raise exception 'Cobranza operativa no configurada.';
  end if;
end $$;

create or replace function public.collection_priority_score(p_overdue numeric,p_outstanding numeric,p_oldest_due date)
returns smallint language sql stable as $$
  select least(100,greatest(0,
    (case when coalesce(p_overdue,0)>0 then 30 else 0 end)+
    (case when p_oldest_due is null then 0 when current_date-p_oldest_due>90 then 40 when current_date-p_oldest_due>60 then 30 when current_date-p_oldest_due>30 then 20 else 10 end)+
    (case when coalesce(p_outstanding,0)>=100000 then 30 when coalesce(p_outstanding,0)>=25000 then 20 when coalesce(p_outstanding,0)>0 then 10 else 0 end)
  ))::smallint
$$;

create or replace function public.collection_sync_cases(p_company_id uuid,p_batch_size integer default 100)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_size integer:=least(greatest(coalesce(p_batch_size,100),1),500);v_created integer:=0;v_updated integer:=0;v_closed integer:=0;
begin
  perform public.collection_assert_manage_access(p_company_id);
  perform public.collection_assert_operational_policy(p_company_id);
  with balances as materialized(
    select r.customer_id,sum(r.outstanding_amount) outstanding,
      coalesce(sum(r.outstanding_amount) filter(where r.due_date<current_date),0) overdue,
      min(r.due_date) filter(where r.outstanding_amount>0) oldest_due
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 group by r.customer_id
  ), candidates as(
    select b.* from balances b join public.customers c on c.id=b.customer_id and c.company_id=p_company_id and c.is_active
    order by b.overdue desc,b.outstanding desc,b.customer_id limit v_size
  ), inserted as(
    insert into public.collection_cases(company_id,customer_id,status,technical_reason,priority_score,created_by)
    select p_company_id,c.customer_id,'pending','Saldo abierto detectado en CxC',public.collection_priority_score(c.overdue,c.outstanding,c.oldest_due),auth.uid() from candidates c
    on conflict(company_id,customer_id) do nothing returning 1
  ) select count(*) into v_created from inserted;

  with balances as(
    select r.customer_id,sum(r.outstanding_amount) outstanding,coalesce(sum(r.outstanding_amount) filter(where r.due_date<current_date),0) overdue,min(r.due_date) oldest_due
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 group by r.customer_id
  ), changed as(
    update public.collection_cases cc set priority_score=public.collection_priority_score(b.overdue,b.outstanding,b.oldest_due),updated_at=clock_timestamp()
    from balances b where cc.company_id=p_company_id and cc.customer_id=b.customer_id and cc.status<>'closed' returning 1
  ) select count(*) into v_updated from changed;

  with closed as(
    update public.collection_cases cc set status='closed',closed_at=clock_timestamp(),closed_reason='Sin saldo abierto en CxC',next_action_at=null,next_action_reason=null,updated_at=clock_timestamp()
    where cc.company_id=p_company_id and cc.status<>'closed' and not exists(select 1 from public.customer_receivables r where r.company_id=p_company_id and r.customer_id=cc.customer_id and r.outstanding_amount>0)
    returning id
  ), cancelled as(
    update public.collection_tasks t set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason='Caso cerrado por saldo liquidado',lease_owner=null,lease_expires_at=null
    where t.company_id=p_company_id and t.status in('pending','leased') and t.case_id in(select id from closed) returning 1
  ) select count(*) into v_closed from closed;
  perform public.write_sales_audit(p_company_id,'collection.cases_synchronized','collection_cases',null,jsonb_build_object('created',v_created,'updated',v_updated,'closed',v_closed,'batch_size',v_size));
  return jsonb_build_object('created',v_created,'updated',v_updated,'closed',v_closed);
end $$;

create or replace function public.collection_list_cases(p_company_id uuid,p_status text default 'open',p_query text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total integer;v_items jsonb;v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  if coalesce(p_status,'open') not in('open','pending','managing','requires_human','closed') then raise exception 'Estado no válido.';end if;
  with balances as materialized(select customer_id,sum(outstanding_amount) outstanding,coalesce(sum(outstanding_amount) filter(where due_date<current_date),0) overdue from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id),
  base as materialized(select cc.*,c.code,c.display_name,coalesce(b.outstanding,0) outstanding,coalesce(b.overdue,0) overdue,cp.amount promise_amount,cp.promised_for
    from public.collection_cases cc join public.customers c on c.id=cc.customer_id left join balances b on b.customer_id=cc.customer_id left join public.collection_promises cp on cp.case_id=cc.id and cp.status='active'
    where cc.company_id=p_company_id and(case when coalesce(p_status,'open')='open' then cc.status<>'closed' else cc.status=p_status end)
      and(coalesce(trim(p_query),'')='' or lower(c.display_name||' '||c.code) like '%'||lower(trim(p_query))||'%'))
  select count(*) into v_total from base;
  with balances as materialized(select customer_id,sum(outstanding_amount) outstanding,coalesce(sum(outstanding_amount) filter(where due_date<current_date),0) overdue from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id),
  base as materialized(select cc.*,c.code,c.display_name,coalesce(b.outstanding,0) outstanding,coalesce(b.overdue,0) overdue,cp.amount promise_amount,cp.promised_for
    from public.collection_cases cc join public.customers c on c.id=cc.customer_id left join balances b on b.customer_id=cc.customer_id left join public.collection_promises cp on cp.case_id=cc.id and cp.status='active'
    where cc.company_id=p_company_id and(case when coalesce(p_status,'open')='open' then cc.status<>'closed' else cc.status=p_status end) and(coalesce(trim(p_query),'')='' or lower(c.display_name||' '||c.code) like '%'||lower(trim(p_query))||'%')),
  paged as(select * from base order by priority_score desc,overdue desc,outstanding desc,display_name,id limit v_size offset(v_page-1)*v_size)
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'customer_id',customer_id,'customer_code',code,'customer_name',display_name,'status',status,'priority_score',priority_score,'assigned_to',assigned_to,'next_action_at',next_action_at,'next_action_reason',next_action_reason,'outstanding_amount',outstanding,'overdue_amount',overdue,'promise_amount',promise_amount,'promised_for',promised_for) order by priority_score desc,overdue desc,outstanding desc,display_name),'[]') into v_items from paged;
  select jsonb_build_object('open_cases',count(*) filter(where status<>'closed'),'requires_human',count(*) filter(where status='requires_human'),'active_promises',(select count(*) from public.collection_promises where company_id=p_company_id and status='active'),'recovered_amount',coalesce((select sum(amount) from public.receivable_payments where company_id=p_company_id),0)) into v_summary from public.collection_cases where company_id=p_company_id;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'summary',v_summary);
end $$;

create or replace function public.collection_get_case(p_company_id uuid,p_case_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_case public.collection_cases%rowtype;v_customer public.customers%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  select * into v_case from public.collection_cases where id=p_case_id and company_id=p_company_id;if not found then raise exception 'Caso no encontrado.';end if;
  select * into v_customer from public.customers where id=v_case.customer_id;
  return jsonb_build_object('case',to_jsonb(v_case),'customer',jsonb_build_object('id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name),
    'contact',coalesce((select to_jsonb(c)-'company_id'-'customer_id'-'created_by' from public.customer_contacts c where c.company_id=p_company_id and c.customer_id=v_case.customer_id order by c.is_primary desc,c.created_at limit 1),'null'),
    'documents',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',s.folio,'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at) from public.customer_receivables r left join public.sales s on s.id=r.sale_id where r.company_id=p_company_id and r.customer_id=v_case.customer_id and r.outstanding_amount>0),'[]'),
    'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'received_at',p.received_at,'payment_method_code',p.payment_method_code) order by p.received_at desc) from public.receivable_payments p where p.company_id=p_company_id and p.customer_id=v_case.customer_id),'[]'),
    'promises',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.collection_promises p where p.case_id=v_case.id),'[]'),
    'timeline',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'type',a.action_type,'reason',a.reason,'created_at',a.created_at,'result',a.result) order by a.created_at desc) from public.collection_actions a where a.case_id=v_case.id),'[]'));
end $$;

create or replace function public.collection_generate_followups(p_company_id uuid,p_batch_size integer default 100)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_size integer:=least(greatest(coalesce(p_batch_size,100),1),500);v_policy public.collection_policy_versions%rowtype;v_created integer;
begin
  perform public.collection_assert_manage_access(p_company_id);perform public.collection_assert_operational_policy(p_company_id);
  select * into v_policy from public.collection_policy_versions where company_id=p_company_id and status='approved' and effective_from<=clock_timestamp() and(effective_to is null or effective_to>clock_timestamp()) order by version desc limit 1;
  with due as(select id,next_action_at,next_action_reason,priority_score from public.collection_cases where company_id=p_company_id and status='managing' and next_action_at<=clock_timestamp() order by priority_score desc,next_action_at,id limit v_size),
  inserted as(insert into public.collection_tasks(company_id,case_id,policy_version_id,task_type,purpose,reason,run_at,priority,channel,maximum_attempts,idempotency_key,created_by)
    select p_company_id,d.id,v_policy.id,'internal_follow_up','operational_follow_up',d.next_action_reason,d.next_action_at,d.priority_score,'internal',v_policy.maximum_attempts,'follow-up:'||d.id||':'||extract(epoch from d.next_action_at)::bigint,auth.uid() from due d
    on conflict do nothing returning 1)
  select count(*) into v_created from inserted;
  perform public.write_sales_audit(p_company_id,'collection.followups_generated','collection_tasks',null,jsonb_build_object('created',v_created,'batch_size',v_size));return jsonb_build_object('created',v_created);
end $$;

create or replace function public.collection_stop_settled_case()
returns trigger language plpgsql security definer set search_path=public as $$declare v_case_id uuid;begin
  if old.outstanding_amount>0 and new.outstanding_amount=0 and not exists(select 1 from public.customer_receivables r where r.company_id=new.company_id and r.customer_id=new.customer_id and r.id<>new.id and r.outstanding_amount>0) then
    update public.collection_cases set status='closed',closed_at=clock_timestamp(),closed_reason='Saldo liquidado en CxC',next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where company_id=new.company_id and customer_id=new.customer_id and status<>'closed' returning id into v_case_id;
    if v_case_id is not null then
      update public.collection_tasks set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason='Saldo liquidado en CxC',lease_owner=null,lease_expires_at=null where case_id=v_case_id and status in('pending','leased');
      update public.collection_promises set status='fulfilled',resolved_at=clock_timestamp(),resolution_reason='Saldo liquidado en CxC' where case_id=v_case_id and status='active';
      insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(new.company_id,v_case_id,'case_settled','Saldo liquidado en CxC','{}','{}','settled:'||new.id);
    end if;
  end if;return new;
end $$;
create trigger customer_receivables_stop_collection after update of outstanding_amount on public.customer_receivables for each row execute function public.collection_stop_settled_case();

create or replace function public.collection_schedule_action(p_company_id uuid,p_case_id uuid,p_run_at timestamptz,p_reason text,p_assigned_to uuid)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_cases%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);if p_run_at is null or p_run_at<=clock_timestamp() then raise exception 'La próxima acción debe estar en el futuro.';end if;if nullif(trim(p_reason),'') is null or p_assigned_to is null then raise exception 'Fecha, motivo y responsable son obligatorios.';end if;
  perform public.collection_assert_operational_policy(p_company_id);
  if not exists(select 1 from public.user_roles ur where ur.user_id=p_assigned_to and ur.is_active and(ur.company_id=p_company_id or ur.company_id is null)) then raise exception 'El responsable no pertenece a la empresa.';end if;
  update public.collection_cases set status='managing',assigned_to=p_assigned_to,next_action_at=p_run_at,next_action_reason=trim(p_reason),updated_at=clock_timestamp() where id=p_case_id and company_id=p_company_id and status<>'closed' returning * into v;if not found then raise exception 'Caso no disponible.';end if;
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,p_case_id,'follow_up_scheduled',trim(p_reason),jsonb_build_object('run_at',p_run_at,'assigned_to',p_assigned_to),'{}',gen_random_uuid()::text);
  perform public.write_sales_audit(p_company_id,'collection.follow_up_scheduled','collection_cases',p_case_id,jsonb_build_object('run_at',p_run_at,'assigned_to',p_assigned_to,'reason',p_reason));return to_jsonb(v);
end $$;

create or replace function public.collection_register_promise(p_company_id uuid,p_case_id uuid,p_amount numeric,p_promised_for date,p_evidence text,p_assigned_to uuid)
returns jsonb language plpgsql security definer set search_path=public as $$declare v_case public.collection_cases%rowtype;v_balance numeric;v public.collection_promises%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);if p_amount is null or p_amount<=0 or p_promised_for<current_date or nullif(trim(p_evidence),'') is null or p_assigned_to is null then raise exception 'Monto, fecha, evidencia y responsable son obligatorios.';end if;
  perform public.collection_assert_operational_policy(p_company_id);
  select * into v_case from public.collection_cases where id=p_case_id and company_id=p_company_id and status<>'closed' for update;if not found then raise exception 'Caso no disponible.';end if;
  select coalesce(sum(outstanding_amount),0) into v_balance from public.customer_receivables where company_id=p_company_id and customer_id=v_case.customer_id and outstanding_amount>0;if p_amount>v_balance then raise exception 'La promesa excede el saldo abierto.';end if;
  update public.collection_promises set status='cancelled',resolved_at=clock_timestamp(),resolution_reason='Sustituida por una nueva promesa' where case_id=p_case_id and status='active';
  insert into public.collection_promises(company_id,case_id,amount,promised_for,evidence) values(p_company_id,p_case_id,p_amount,p_promised_for,trim(p_evidence)) returning * into v;
  update public.collection_cases set status='managing',assigned_to=p_assigned_to,next_action_at=(p_promised_for+time '09:00') at time zone 'America/Mexico_City',next_action_reason='Verificar cumplimiento de promesa',updated_at=clock_timestamp() where id=p_case_id;
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,p_case_id,'promise_registered',trim(p_evidence),jsonb_build_object('amount',p_amount,'promised_for',p_promised_for,'assigned_to',p_assigned_to),jsonb_build_object('promise_id',v.id),gen_random_uuid()::text);return to_jsonb(v);
end $$;

create or replace function public.collection_escalate_case(p_company_id uuid,p_case_id uuid,p_reason text,p_assigned_to uuid)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_cases%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);if nullif(trim(p_reason),'') is null or p_assigned_to is null then raise exception 'Motivo y responsable son obligatorios.';end if;
  perform public.collection_assert_operational_policy(p_company_id);
  update public.collection_cases set status='requires_human',assigned_to=p_assigned_to,next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where id=p_case_id and company_id=p_company_id and status<>'closed' returning * into v;if not found then raise exception 'Caso no disponible.';end if;
  update public.collection_tasks set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason='Caso escalado a atención humana',lease_owner=null,lease_expires_at=null where case_id=p_case_id and status in('pending','leased');
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,p_case_id,'case_escalated',trim(p_reason),jsonb_build_object('assigned_to',p_assigned_to),'{}',gen_random_uuid()::text);return to_jsonb(v);
end $$;

create or replace function public.collection_close_case(p_company_id uuid,p_case_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_cases%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);if nullif(trim(p_reason),'') is null then raise exception 'Motivo obligatorio.';end if;
  perform public.collection_assert_operational_policy(p_company_id);
  update public.collection_cases set status='closed',closed_at=clock_timestamp(),closed_reason=trim(p_reason),next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where id=p_case_id and company_id=p_company_id and status<>'closed' returning * into v;if not found then raise exception 'Caso no disponible.';end if;
  update public.collection_promises set status='cancelled',resolved_at=clock_timestamp(),resolution_reason='Caso cerrado: '||trim(p_reason) where case_id=p_case_id and status='active';
  update public.collection_tasks set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason='Caso cerrado: '||trim(p_reason),lease_owner=null,lease_expires_at=null where case_id=p_case_id and status in('pending','leased');
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,p_case_id,'case_closed',trim(p_reason),'{}','{}',gen_random_uuid()::text);return to_jsonb(v);
end $$;

create or replace function public.collection_list_assignees(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.user_id,'name',coalesce(nullif(trim(p.full_name),''),x.user_id::text)) order by coalesce(nullif(trim(p.full_name),''),x.user_id::text))
    from(select distinct ur.user_id from public.user_roles ur where ur.is_active and(ur.company_id=p_company_id or ur.company_id is null))x left join public.profiles p on p.id=x.user_id),'[]'::jsonb);
end
$$;

revoke all on function public.collection_assert_manage_access(uuid),public.collection_assert_operational_policy(uuid),public.collection_sync_cases(uuid,integer),public.collection_generate_followups(uuid,integer),public.collection_list_cases(uuid,text,text,integer,integer),public.collection_get_case(uuid,uuid),public.collection_schedule_action(uuid,uuid,timestamptz,text,uuid),public.collection_register_promise(uuid,uuid,numeric,date,text,uuid),public.collection_escalate_case(uuid,uuid,text,uuid),public.collection_close_case(uuid,uuid,text),public.collection_list_assignees(uuid) from public,anon,authenticated;
grant execute on function public.collection_sync_cases(uuid,integer),public.collection_generate_followups(uuid,integer),public.collection_schedule_action(uuid,uuid,timestamptz,text,uuid),public.collection_register_promise(uuid,uuid,numeric,date,text,uuid),public.collection_escalate_case(uuid,uuid,text,uuid),public.collection_close_case(uuid,uuid,text) to authenticated;
grant execute on function public.collection_list_cases(uuid,text,text,integer,integer),public.collection_get_case(uuid,uuid),public.collection_list_assignees(uuid) to authenticated;
