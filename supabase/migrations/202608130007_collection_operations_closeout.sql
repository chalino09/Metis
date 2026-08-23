-- Cierre operativo de Fase 2: política administrable, lotes reanudables y bloqueos explícitos.

create table public.collection_blocks(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  case_id uuid not null references public.collection_cases(id) on delete cascade,
  block_type text not null check(block_type in('dispute','no_contact')),
  status text not null default 'active' check(status in('active','resolved')),
  reason text not null check(length(trim(reason))>0),
  evidence text not null check(length(trim(evidence))>0),
  assigned_to uuid references auth.users(id) on delete restrict,
  resolved_by uuid references auth.users(id) on delete restrict,
  resolved_at timestamptz,
  resolution_reason text,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  check((status='active' and resolved_at is null and resolved_by is null and resolution_reason is null) or(status='resolved' and resolved_at is not null and resolved_by is not null and length(trim(resolution_reason))>0))
);
create unique index collection_one_active_block_kind_idx on public.collection_blocks(case_id,block_type) where status='active';
create index collection_blocks_case_idx on public.collection_blocks(case_id,created_at desc);
alter table public.collection_blocks enable row level security;
create policy collection_blocks_read on public.collection_blocks for select to authenticated using(public.has_company_permission(company_id,'view_collection_automation'));
revoke all on public.collection_blocks from authenticated;
grant select on public.collection_blocks to authenticated;

create or replace function public.collection_list_policies(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar la política de cobranza.';end if;
  return jsonb_build_object(
    'configuration_status',case when exists(select 1 from public.collection_policy_versions p where p.company_id=p_company_id and p.status='approved' and public.collection_policy_is_complete(p) and p.effective_from<=clock_timestamp() and(p.effective_to is null or p.effective_to>clock_timestamp())) then 'configured' else 'not_configured' end,
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'version',p.version,'status',p.status,'timezone',p.timezone,'allowed_weekdays',p.allowed_weekdays,'contact_window_start',p.contact_window_start,'contact_window_end',p.contact_window_end,'minimum_contact_interval',p.minimum_contact_interval::text,'maximum_attempts',p.maximum_attempts,'operational_owner_id',p.operational_owner_id,'escalation_owner_id',p.escalation_owner_id,'reason',p.reason,'approved_at',p.approved_at,'effective_from',p.effective_from,'created_at',p.created_at,'complete',public.collection_policy_is_complete(p)) order by p.version desc) from public.collection_policy_versions p where p.company_id=p_company_id),'[]'::jsonb)
  );
end $$;

create or replace function public.collection_sync_cases(p_company_id uuid,p_batch_size integer default 100,p_after_customer_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_size integer:=least(greatest(coalesce(p_batch_size,100),1),500);v_created integer:=0;v_updated integer:=0;v_closed integer:=0;v_scanned integer:=0;v_next uuid;v_has_more boolean:=false;
begin
  perform public.collection_assert_manage_access(p_company_id);perform public.collection_assert_operational_policy(p_company_id);
  with balances as materialized(
    select r.customer_id,sum(r.outstanding_amount) outstanding,coalesce(sum(r.outstanding_amount) filter(where r.due_date<current_date),0) overdue,min(r.due_date) oldest_due
    from public.customer_receivables r where r.company_id=p_company_id and r.outstanding_amount>0 group by r.customer_id
  ), page as materialized(
    select b.* from balances b join public.customers c on c.id=b.customer_id and c.company_id=p_company_id and c.is_active
    where p_after_customer_id is null or b.customer_id>p_after_customer_id order by b.customer_id limit v_size
  ), inserted as(
    insert into public.collection_cases(company_id,customer_id,status,technical_reason,priority_score,created_by)
    select p_company_id,p.customer_id,'pending','Saldo abierto detectado en CxC',public.collection_priority_score(p.overdue,p.outstanding,p.oldest_due),auth.uid() from page p
    on conflict(company_id,customer_id) do nothing returning 1
  ), updated as(
    update public.collection_cases cc set priority_score=public.collection_priority_score(p.overdue,p.outstanding,p.oldest_due),updated_at=clock_timestamp()
    from page p where cc.company_id=p_company_id and cc.customer_id=p.customer_id and cc.status<>'closed' returning 1
  ) select (select count(*) from inserted),(select count(*) from updated),(select count(*) from page),(select customer_id from page order by customer_id desc limit 1) into v_created,v_updated,v_scanned,v_next;
  if v_next is not null then
    select exists(select 1 from public.customer_receivables r join public.customers c on c.id=r.customer_id and c.company_id=p_company_id and c.is_active where r.company_id=p_company_id and r.outstanding_amount>0 and r.customer_id>v_next) into v_has_more;
  end if;
  with closed as(
    update public.collection_cases cc set status='closed',closed_at=clock_timestamp(),closed_reason='Sin saldo abierto en CxC',next_action_at=null,next_action_reason=null,updated_at=clock_timestamp()
    where cc.company_id=p_company_id and cc.status<>'closed' and not exists(select 1 from public.customer_receivables r where r.company_id=p_company_id and r.customer_id=cc.customer_id and r.outstanding_amount>0) returning id
  ), cancelled as(
    update public.collection_tasks t set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason='Caso cerrado por saldo liquidado',lease_owner=null,lease_expires_at=null where t.status in('pending','leased') and t.case_id in(select id from closed) returning 1
  ) select count(*) into v_closed from closed;
  perform public.collection_refresh_promises(p_company_id);
  perform public.write_sales_audit(p_company_id,'collection.cases_synchronized','collection_cases',null,jsonb_build_object('created',v_created,'updated',v_updated,'closed',v_closed,'scanned',v_scanned,'next_cursor',v_next,'has_more',v_has_more));
  return jsonb_build_object('created',v_created,'updated',v_updated,'closed',v_closed,'scanned',v_scanned,'next_cursor',v_next,'has_more',v_has_more);
end $$;

create or replace function public.collection_register_block(p_company_id uuid,p_case_id uuid,p_block_type text,p_reason text,p_evidence text,p_assigned_to uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_blocks%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);perform public.collection_assert_operational_policy(p_company_id);
  if p_block_type not in('dispute','no_contact') or nullif(trim(p_reason),'') is null or nullif(trim(p_evidence),'') is null then raise exception 'Tipo, motivo y evidencia son obligatorios.';end if;
  if not exists(select 1 from public.collection_cases where id=p_case_id and company_id=p_company_id and status<>'closed') then raise exception 'Caso no disponible.';end if;
  insert into public.collection_blocks(company_id,case_id,block_type,reason,evidence,assigned_to) values(p_company_id,p_case_id,p_block_type,trim(p_reason),trim(p_evidence),p_assigned_to)
    on conflict(case_id,block_type) where status='active' do update set reason=excluded.reason,evidence=excluded.evidence,assigned_to=excluded.assigned_to returning * into v;
  update public.collection_cases set status='requires_human',assigned_to=coalesce(p_assigned_to,assigned_to),next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where id=p_case_id;
  update public.collection_tasks set status='cancelled',cancelled_at=clock_timestamp(),cancelled_reason=case when p_block_type='no_contact' then 'Solicitud de no contacto' else 'Disputa activa' end,lease_owner=null,lease_expires_at=null where case_id=p_case_id and status in('pending','leased');
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,p_case_id,'block_registered',trim(p_reason),jsonb_build_object('block_type',p_block_type,'evidence',trim(p_evidence),'assigned_to',p_assigned_to),jsonb_build_object('block_id',v.id),gen_random_uuid()::text);
  return to_jsonb(v);
end $$;

create or replace function public.collection_resolve_block(p_company_id uuid,p_block_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$declare v public.collection_blocks%rowtype;begin
  perform public.collection_assert_manage_access(p_company_id);if nullif(trim(p_reason),'') is null then raise exception 'Motivo de resolución obligatorio.';end if;
  update public.collection_blocks set status='resolved',resolved_at=clock_timestamp(),resolved_by=auth.uid(),resolution_reason=trim(p_reason) where id=p_block_id and company_id=p_company_id and status='active' returning * into v;if not found then raise exception 'Bloqueo no disponible.';end if;
  if not exists(select 1 from public.collection_blocks where case_id=v.case_id and status='active') then update public.collection_cases set status='pending',next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where id=v.case_id and status='requires_human';end if;
  insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key) values(p_company_id,v.case_id,'block_resolved',trim(p_reason),jsonb_build_object('block_type',v.block_type),jsonb_build_object('block_id',v.id),gen_random_uuid()::text);return to_jsonb(v);
end $$;

create or replace function public.collection_refresh_promises(p_company_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$declare v_broken integer;begin
  update public.collection_promises p set status='broken',resolved_at=clock_timestamp(),resolution_reason='Fecha prometida vencida sin pago suficiente'
  where p.company_id=p_company_id and p.status='active' and p.promised_for<current_date and p.amount>coalesce((select sum(pay.amount) from public.receivable_payments pay join public.collection_cases cc on cc.customer_id=pay.customer_id and cc.id=p.case_id where pay.company_id=p.company_id and pay.received_at>=p.created_at),0);
  get diagnostics v_broken=row_count;
  update public.collection_cases cc set status='pending',next_action_at=null,next_action_reason=null,updated_at=clock_timestamp() where cc.company_id=p_company_id and cc.status='managing' and exists(select 1 from public.collection_promises p where p.case_id=cc.id and p.status='broken');
  if v_broken>0 then insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key)
    select p.company_id,p.case_id,'promise_broken','Fecha prometida vencida sin pago suficiente',jsonb_build_object('promise_id',p.id),jsonb_build_object('amount',p.amount),'promise-broken:'||p.id from public.collection_promises p where p.company_id=p_company_id and p.status='broken' and p.resolved_at>=clock_timestamp()-interval '1 second' on conflict do nothing;end if;
  return jsonb_build_object('broken',v_broken);
end $$;

create or replace function public.collection_fulfill_promises_from_payment()
returns trigger language plpgsql security definer set search_path=public as $$begin
  with fulfilled as(
    update public.collection_promises p set status='fulfilled',resolved_at=clock_timestamp(),resolution_reason='Pago confirmado en CxC'
    from public.collection_cases cc where p.case_id=cc.id and p.company_id=new.company_id and cc.customer_id=new.customer_id and p.status='active' and p.amount<=coalesce((select sum(pay.amount) from public.receivable_payments pay where pay.company_id=new.company_id and pay.customer_id=new.customer_id and pay.received_at>=p.created_at),0) returning p.*
  ) insert into public.collection_actions(company_id,case_id,action_type,reason,safe_arguments,result,idempotency_key)
    select company_id,case_id,'promise_fulfilled','Pago confirmado en CxC',jsonb_build_object('promise_id',id),jsonb_build_object('payment_id',new.id),'promise-fulfilled:'||id from fulfilled;
  return new;
end $$;
create trigger receivable_payments_fulfill_collection_promises after insert on public.receivable_payments for each row execute function public.collection_fulfill_promises_from_payment();

create or replace function public.collection_list_cases(p_company_id uuid,p_status text default 'open',p_query text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total integer;v_items jsonb;v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  if coalesce(p_status,'open') not in('open','pending','managing','requires_human','closed') then raise exception 'Estado no válido.';end if;
  with balances as materialized(select customer_id,sum(outstanding_amount) outstanding,coalesce(sum(outstanding_amount) filter(where due_date<current_date),0) overdue from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id),base as materialized(select cc.*,c.code,c.display_name,coalesce(b.outstanding,0) outstanding,coalesce(b.overdue,0) overdue,cp.amount promise_amount,cp.promised_for,coalesce(array_agg(cb.block_type order by cb.block_type) filter(where cb.status='active'),'{}') blocks from public.collection_cases cc join public.customers c on c.id=cc.customer_id left join balances b on b.customer_id=cc.customer_id left join public.collection_promises cp on cp.case_id=cc.id and cp.status='active' left join public.collection_blocks cb on cb.case_id=cc.id and cb.status='active' where cc.company_id=p_company_id and(case when coalesce(p_status,'open')='open' then cc.status<>'closed' else cc.status=p_status end) and(coalesce(trim(p_query),'')='' or lower(c.display_name||' '||c.code) like '%'||lower(trim(p_query))||'%') group by cc.id,c.code,c.display_name,b.outstanding,b.overdue,cp.amount,cp.promised_for)
  select count(*) into v_total from base;
  with balances as materialized(select customer_id,sum(outstanding_amount) outstanding,coalesce(sum(outstanding_amount) filter(where due_date<current_date),0) overdue from public.customer_receivables where company_id=p_company_id and outstanding_amount>0 group by customer_id),base as materialized(select cc.*,c.code,c.display_name,coalesce(b.outstanding,0) outstanding,coalesce(b.overdue,0) overdue,cp.amount promise_amount,cp.promised_for,coalesce(array_agg(cb.block_type order by cb.block_type) filter(where cb.status='active'),'{}') blocks from public.collection_cases cc join public.customers c on c.id=cc.customer_id left join balances b on b.customer_id=cc.customer_id left join public.collection_promises cp on cp.case_id=cc.id and cp.status='active' left join public.collection_blocks cb on cb.case_id=cc.id and cb.status='active' where cc.company_id=p_company_id and(case when coalesce(p_status,'open')='open' then cc.status<>'closed' else cc.status=p_status end) and(coalesce(trim(p_query),'')='' or lower(c.display_name||' '||c.code) like '%'||lower(trim(p_query))||'%') group by cc.id,c.code,c.display_name,b.outstanding,b.overdue,cp.amount,cp.promised_for),paged as(select * from base order by priority_score desc,overdue desc,outstanding desc,display_name,id limit v_size offset(v_page-1)*v_size)
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'customer_id',customer_id,'customer_code',code,'customer_name',display_name,'status',status,'priority_score',priority_score,'assigned_to',assigned_to,'next_action_at',next_action_at,'next_action_reason',next_action_reason,'outstanding_amount',outstanding,'overdue_amount',overdue,'promise_amount',promise_amount,'promised_for',promised_for,'blocks',to_jsonb(blocks)) order by priority_score desc,overdue desc,outstanding desc,display_name),'[]') into v_items from paged;
  select jsonb_build_object('open_cases',count(*) filter(where cc.status<>'closed'),'requires_human',count(*) filter(where cc.status='requires_human'),'active_promises',(select count(*) from public.collection_promises where company_id=p_company_id and status='active'),'recovered_amount',coalesce((select sum(pay.amount) from public.receivable_payments pay where pay.company_id=p_company_id and exists(select 1 from public.collection_cases case_paid where case_paid.company_id=p_company_id and case_paid.customer_id=pay.customer_id and pay.received_at>=case_paid.created_at)),0),'recovery_basis','Pagos confirmados desde la apertura de cada caso') into v_summary from public.collection_cases cc where cc.company_id=p_company_id;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'summary',v_summary);
end $$;

create or replace function public.collection_get_case(p_company_id uuid,p_case_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$declare v_case public.collection_cases%rowtype;v_customer public.customers%rowtype;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then raise exception 'No autorizado para consultar cobranza.';end if;
  select * into v_case from public.collection_cases where id=p_case_id and company_id=p_company_id;if not found then raise exception 'Caso no encontrado.';end if;select * into v_customer from public.customers where id=v_case.customer_id;
  return jsonb_build_object('case',to_jsonb(v_case),'customer',jsonb_build_object('id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name),'contact',coalesce((select to_jsonb(c)-'company_id'-'customer_id'-'created_by' from public.customer_contacts c where c.company_id=p_company_id and c.customer_id=v_case.customer_id order by c.is_primary desc,c.created_at limit 1),'null'),'documents',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',s.folio,'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at) from public.customer_receivables r left join public.sales s on s.id=r.sale_id where r.company_id=p_company_id and r.customer_id=v_case.customer_id and r.outstanding_amount>0),'[]'),'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'received_at',p.received_at,'payment_method_code',p.payment_method_code) order by p.received_at desc) from public.receivable_payments p where p.company_id=p_company_id and p.customer_id=v_case.customer_id),'[]'),'promises',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.collection_promises p where p.case_id=v_case.id),'[]'),'blocks',coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from public.collection_blocks b where b.case_id=v_case.id),'[]'),'timeline',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'type',a.action_type,'reason',a.reason,'created_at',a.created_at,'result',a.result) order by a.created_at desc) from public.collection_actions a where a.case_id=v_case.id),'[]'));
end $$;

revoke all on function public.collection_list_policies(uuid),public.collection_sync_cases(uuid,integer,uuid),public.collection_register_block(uuid,uuid,text,text,text,uuid),public.collection_resolve_block(uuid,uuid,text),public.collection_refresh_promises(uuid),public.collection_list_cases(uuid,text,text,integer,integer),public.collection_get_case(uuid,uuid) from public,anon,authenticated;
grant execute on function public.collection_list_policies(uuid),public.collection_list_cases(uuid,text,text,integer,integer),public.collection_get_case(uuid,uuid) to authenticated;
grant execute on function public.collection_sync_cases(uuid,integer,uuid),public.collection_register_block(uuid,uuid,text,text,text,uuid),public.collection_resolve_block(uuid,uuid,text),public.collection_refresh_promises(uuid) to authenticated;
