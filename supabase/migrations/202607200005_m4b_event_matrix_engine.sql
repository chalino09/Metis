-- M4B · matriz y motor contable operativo. Reutiliza catálogo, controles,
-- periodos, pólizas, auditoría e inmutabilidad de M4A; todavía no sustituye RPC operativos.

insert into public.permissions(code,description) values
  ('configure_accounting_events','Configurar la matriz de eventos contables.'),
  ('approve_accounting_events','Aprobar y activar una matriz contable operativa.'),
  ('reprocess_accounting_events','Reprocesar eventos contables pendientes.')
on conflict(code) do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p where r.code in ('super_admin','direccion_admin') and p.code in ('configure_accounting_events','approve_accounting_events','reprocess_accounting_events') on conflict do nothing;

create table public.accounting_event_rule_sets(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  accounting_config_version_id uuid not null references public.accounting_config_versions(id) on delete restrict,
  version integer not null check(version>0),
  status text not null default 'draft' check(status in ('draft','approved','superseded')),
  cost_method text not null check(cost_method in ('replacement_cost','standard_cost','average_cost')),
  recognition_policy jsonb not null default '{}' check(jsonb_typeof(recognition_policy)='object'),
  reason text not null check(nullif(trim(reason),'') is not null),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  approved_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),approved_at timestamptz,
  unique(company_id,version),
  check((status='draft' and approved_at is null) or (status in ('approved','superseded') and approved_at is not null))
);
create unique index accounting_event_rule_sets_approved_idx on public.accounting_event_rule_sets(company_id) where status='approved';

create table public.accounting_event_role_accounts(
  rule_set_id uuid not null references public.accounting_event_rule_sets(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  account_role text not null check(account_role in ('sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment')),
  account_id uuid not null,
  primary key(rule_set_id,account_role),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict
);

create table public.accounting_events(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  rule_set_id uuid references public.accounting_event_rule_sets(id) on delete restrict,
  event_type text not null check(event_type in ('sale_confirmed','sale_cancelled','receivable_payment_confirmed','receivable_payment_reversed','cash_opened','cash_movement_recorded','cash_movement_reversed','cash_closed','purchase_receipt_confirmed','purchase_receipt_reversed','inventory_adjustment_posted','inventory_adjustment_reversed','supplier_invoice_confirmed','supplier_invoice_reversed','supplier_credit_note_confirmed','supplier_credit_note_reversed','supplier_payment_confirmed','supplier_payment_reversed')),
  source_entity_type text not null,source_entity_id uuid not null,source_version integer not null default 1 check(source_version>0),
  accounting_date date not null,occurred_at timestamptz not null,payload jsonb not null default '{}' check(jsonb_typeof(payload)='object'),
  requested_lines jsonb not null default '[]' check(jsonb_typeof(requested_lines)='array'),
  status text not null default 'pending' check(status in ('pending','posted')),
  journal_entry_id uuid,original_event_id uuid references public.accounting_events(id) on delete restrict,
  created_at timestamptz not null default now(),posted_at timestamptz,
  unique(company_id,event_type,source_entity_type,source_entity_id,source_version),
  check((status='posted')=(journal_entry_id is not null))
);
create index accounting_events_pending_idx on public.accounting_events(company_id,status,accounting_date,id);

alter table public.accounting_journal_entries drop constraint accounting_journal_entries_source_type_check;
alter table public.accounting_journal_entries add constraint accounting_journal_entries_source_type_check check(source_type in ('opening','manual_adjustment','operational_event'));
alter table public.accounting_journal_entries add column accounting_event_id uuid unique references public.accounting_events(id) on delete restrict;
alter table public.accounting_events add constraint accounting_events_journal_fkey foreign key(journal_entry_id) references public.accounting_journal_entries(id) on delete restrict;

create or replace function public.create_accounting_event_rule_set(p_company_id uuid,p_cost_method text,p_recognition_policy jsonb,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;v_set public.accounting_event_rule_sets%rowtype;v_version int;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting_events') then raise exception 'No autorizado para configurar eventos contables.';end if;
  select * into v_config from public.accounting_config_versions where company_id=p_company_id and status='approved';
  if not found then raise exception 'M4A debe tener una configuración aprobada.';end if;
  if p_cost_method not in ('replacement_cost','standard_cost','average_cost') or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Método de costo y motivo son obligatorios.';end if;
  if exists(select 1 from public.accounting_event_rule_sets where company_id=p_company_id and status='draft') then raise exception 'Ya existe una matriz en borrador.';end if;
  select coalesce(max(version),0)+1 into v_version from public.accounting_event_rule_sets where company_id=p_company_id;
  insert into public.accounting_event_rule_sets(company_id,accounting_config_version_id,version,cost_method,recognition_policy,reason) values(p_company_id,v_config.id,v_version,p_cost_method,coalesce(p_recognition_policy,'{}'),trim(p_reason)) returning * into v_set;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.event_matrix_created','accounting_event_rule_set',v_set.id,jsonb_build_object('version',v_version,'cost_method',p_cost_method));return to_jsonb(v_set);
end $$;

create or replace function public.set_accounting_event_role_account(p_rule_set_id uuid,p_account_role text,p_account_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_set public.accounting_event_rule_sets%rowtype;
begin
  select * into v_set from public.accounting_event_rule_sets where id=p_rule_set_id for update;
  if not found or v_set.status<>'draft' or auth.uid() is null or not public.has_company_permission(v_set.company_id,'configure_accounting_events') then raise exception 'Matriz no editable.';end if;
  if not exists(select 1 from public.accounting_accounts where id=p_account_id and company_id=v_set.company_id and accepts_posting and is_active) then raise exception 'Selecciona una cuenta afectable activa.';end if;
  insert into public.accounting_event_role_accounts(rule_set_id,company_id,account_role,account_id) values(v_set.id,v_set.company_id,p_account_role,p_account_id) on conflict(rule_set_id,account_role) do update set account_id=excluded.account_id;
  return jsonb_build_object('rule_set_id',v_set.id,'account_role',p_account_role,'account_id',p_account_id);
end $$;

create or replace function public.approve_accounting_event_rule_set(p_rule_set_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_set public.accounting_event_rule_sets%rowtype;v_missing text[];
begin
  select * into v_set from public.accounting_event_rule_sets where id=p_rule_set_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_set.company_id,'approve_accounting_events') then raise exception 'Matriz no disponible.';end if;
  if v_set.status<>'draft' then return to_jsonb(v_set)||jsonb_build_object('idempotent',true);end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo de aprobación es obligatorio.';end if;
  select array_agg(role) into v_missing from unnest(array['sales_revenue','sales_discounts','cost_of_goods_sold','goods_received_not_invoiced','purchase_variance','supplier_expense','cash_opening_offset','cash_close_offset','cash_movement_offset','cash_over_short','supplier_credit_note_offset','inventory_adjustment']) role where not exists(select 1 from public.accounting_event_role_accounts a where a.rule_set_id=v_set.id and a.account_role=role);
  if cardinality(v_missing)>0 then raise exception 'Faltan cuentas en la matriz: %',array_to_string(v_missing,', ');end if;
  if not exists(select 1 from public.accounting_control_accounts where config_version_id=v_set.accounting_config_version_id group by config_version_id having count(*)=9) then raise exception 'La configuración M4A perdió cuentas de control.';end if;
  update public.accounting_event_rule_sets set status='superseded' where company_id=v_set.company_id and status='approved';
  update public.accounting_event_rule_sets set status='approved',approved_by=auth.uid(),approved_at=now(),reason=trim(p_reason) where id=v_set.id returning * into v_set;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_set.company_id,auth.uid(),'accounting.event_matrix_approved','accounting_event_rule_set',v_set.id,jsonb_build_object('version',v_set.version,'reason',p_reason));return to_jsonb(v_set)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.complete_accounting_event_rule_set(p_rule_set_id uuid,p_role_accounts jsonb,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_set public.accounting_event_rule_sets%rowtype;v_role record;
begin
  select * into v_set from public.accounting_event_rule_sets where id=p_rule_set_id for update;
  if not found or v_set.status<>'draft' or auth.uid() is null or not public.has_company_permission(v_set.company_id,'configure_accounting_events') or not public.has_company_permission(v_set.company_id,'approve_accounting_events') then raise exception 'Matriz no disponible para completar.';end if;
  if jsonb_typeof(p_role_accounts)<>'object' then raise exception 'Las cuentas de la matriz son obligatorias.';end if;
  for v_role in select key,value from jsonb_each_text(p_role_accounts) loop perform public.set_accounting_event_role_account(v_set.id,v_role.key,v_role.value::uuid);end loop;
  return public.approve_accounting_event_rule_set(v_set.id,p_reason);
end $$;

create or replace function public.resolve_accounting_event_role(p_rule_set_id uuid,p_role text)
returns uuid language sql stable security definer set search_path=public as $$
  select coalesce((select c.account_id from public.accounting_event_rule_sets s join public.accounting_control_accounts c on c.config_version_id=s.accounting_config_version_id where s.id=p_rule_set_id and c.control_key=p_role),(select a.account_id from public.accounting_event_role_accounts a where a.rule_set_id=p_rule_set_id and a.account_role=p_role))
$$;

create or replace function public.post_pending_accounting_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_event public.accounting_events%rowtype;v_set public.accounting_event_rule_sets%rowtype;v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;v_line record;v_account uuid;v_debit numeric:=0;v_credit numeric:=0;v_number int:=0;
begin
  select * into v_event from public.accounting_events where id=p_event_id for update;
  if not found then raise exception 'Evento contable no disponible.';end if;
  if v_event.status='posted' then return to_jsonb(v_event)||jsonb_build_object('idempotent',true);end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=v_event.company_id and status='approved';if not found then return to_jsonb(v_event)||jsonb_build_object('waiting_for_matrix',true);end if;
  select * into v_period from public.accounting_periods where company_id=v_event.company_id and v_event.accounting_date between starts_on and ends_on for update;
  if not found or v_period.status<>'open' then raise exception 'El evento pertenece a un periodo inexistente o cerrado.';end if;
  if jsonb_array_length(v_event.requested_lines)<2 or jsonb_array_length(v_event.requested_lines)>1000 then raise exception 'El evento no contiene partidas válidas.';end if;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)x(role text,debit numeric,credit numeric,description text) loop
    if coalesce(v_line.debit,0)<0 or coalesce(v_line.credit,0)<0 or (coalesce(v_line.debit,0)>0)=(coalesce(v_line.credit,0)>0) then raise exception 'Partida operativa inválida.';end if;
    v_account:=public.resolve_accounting_event_role(v_set.id,v_line.role);if v_account is null then raise exception 'La matriz no resuelve el rol %.',v_line.role;end if;v_debit:=v_debit+coalesce(v_line.debit,0);v_credit:=v_credit+coalesce(v_line.credit,0);
  end loop;
  if round(v_debit-v_credit,6)<>0 then raise exception 'El evento no cumple doble entrada.';end if;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,immutable,client_request_id,accounting_event_id) values(v_event.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),v_event.accounting_date,coalesce(nullif(v_event.payload->>'description',''),v_event.event_type),'operational_event','draft',false,v_event.id,v_event.id) returning * into v_entry;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)x(role text,debit numeric,credit numeric,description text) loop v_number:=v_number+1;v_account:=public.resolve_accounting_event_role(v_set.id,v_line.role);insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit) values(v_event.company_id,v_entry.id,v_number,v_account,v_line.description,coalesce(v_line.debit,0),coalesce(v_line.credit,0));end loop;
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),content_sha256=encode(digest((select jsonb_agg(to_jsonb(l) order by line_number)::text from public.accounting_journal_lines l where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id;
  update public.accounting_events set status='posted',rule_set_id=v_set.id,journal_entry_id=v_entry.id,posted_at=now() where id=v_event.id returning * into v_event;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_event.company_id,auth.uid(),'accounting.operational_event_posted','accounting_event',v_event.id,jsonb_build_object('event_type',v_event.event_type,'source_type',v_event.source_entity_type,'source_id',v_event.source_entity_id,'journal_entry_id',v_entry.id));return to_jsonb(v_event)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.capture_accounting_event(p_company_id uuid,p_event_type text,p_source_entity_type text,p_source_entity_id uuid,p_source_version int,p_accounting_date date,p_occurred_at timestamptz,p_lines jsonb,p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_event public.accounting_events%rowtype;
begin
  insert into public.accounting_events(company_id,event_type,source_entity_type,source_entity_id,source_version,accounting_date,occurred_at,requested_lines,payload) values(p_company_id,p_event_type,p_source_entity_type,p_source_entity_id,coalesce(p_source_version,1),p_accounting_date,p_occurred_at,coalesce(p_lines,'[]'),coalesce(p_payload,'{}')) on conflict(company_id,event_type,source_entity_type,source_entity_id,source_version) do nothing returning * into v_event;
  if not found then select * into v_event from public.accounting_events where company_id=p_company_id and event_type=p_event_type and source_entity_type=p_source_entity_type and source_entity_id=p_source_entity_id and source_version=coalesce(p_source_version,1);return to_jsonb(v_event)||jsonb_build_object('idempotent',true);end if;
  return public.post_pending_accounting_event(v_event.id);
end $$;

create or replace function public.reprocess_accounting_events(p_company_id uuid,p_limit int default 100)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_event record;v_processed int:=0;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reprocess_accounting_events') then raise exception 'No autorizado para reprocesar eventos.';end if;
  for v_event in select id from public.accounting_events where company_id=p_company_id and status='pending' order by accounting_date,id limit least(greatest(coalesce(p_limit,100),1),1000) for update skip locked loop perform public.post_pending_accounting_event(v_event.id);v_processed:=v_processed+1;end loop;return jsonb_build_object('processed',v_processed);
end $$;

alter table public.accounting_event_rule_sets enable row level security;alter table public.accounting_event_role_accounts enable row level security;alter table public.accounting_events enable row level security;
create policy accounting_event_rule_sets_read on public.accounting_event_rule_sets for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_event_role_accounts_read on public.accounting_event_role_accounts for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_events_read on public.accounting_events for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
grant select on public.accounting_event_rule_sets,public.accounting_event_role_accounts,public.accounting_events to authenticated;
revoke all on function public.capture_accounting_event(uuid,text,text,uuid,int,date,timestamptz,jsonb,jsonb),public.post_pending_accounting_event(uuid),public.resolve_accounting_event_role(uuid,text) from public,anon,authenticated;
revoke all on function public.create_accounting_event_rule_set(uuid,text,jsonb,text),public.set_accounting_event_role_account(uuid,text,uuid),public.approve_accounting_event_rule_set(uuid,text),public.complete_accounting_event_rule_set(uuid,jsonb,text),public.reprocess_accounting_events(uuid,int) from public,anon;
grant execute on function public.create_accounting_event_rule_set(uuid,text,jsonb,text),public.set_accounting_event_role_account(uuid,text,uuid),public.approve_accounting_event_rule_set(uuid,text),public.complete_accounting_event_rule_set(uuid,jsonb,text),public.reprocess_accounting_events(uuid,int) to authenticated;
