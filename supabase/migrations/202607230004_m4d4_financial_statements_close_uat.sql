-- Satrapy · M4D4. Estados oficiales, conciliación y cierre canónico de periodo.
-- Reutiliza pólizas, auxiliares, dimensiones y accounting_periods; no crea otro libro.

insert into public.permissions(code,description) values
 ('prepare_accounting_close','Preparar vista previa inmutable del cierre contable.'),
 ('approve_accounting_close','Aprobar un cierre preparado por otra persona.'),
 ('reopen_accounting_close','Reabrir excepcionalmente un periodo cerrado por M4D4.')
on conflict(code) do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in ('prepare_accounting_close','approve_accounting_close','reopen_accounting_close')
on conflict do nothing;

create table if not exists public.accounting_close_runs(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 period_id uuid not null references public.accounting_periods(id) on delete restrict,
 status text not null default 'prepared' check(status in ('prepared','approved','closed','reopened')),
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),
 snapshot_sha256 text not null check(snapshot_sha256~'^[0-9a-f]{64}$'),
 prepared_request_id uuid not null, prepared_by uuid not null references auth.users(id) on delete restrict default auth.uid(), prepared_at timestamptz not null default now(),
 approval_reason text, approval_request_id uuid unique, approved_by uuid references auth.users(id) on delete restrict, approved_at timestamptz,
 close_request_id uuid unique, closed_by uuid references auth.users(id) on delete restrict, closed_at timestamptz,
 reopen_reason text, reopen_request_id uuid unique, reopened_by uuid references auth.users(id) on delete restrict, reopened_at timestamptz,
 unique(company_id,period_id), unique(company_id,prepared_request_id),
 check((status in ('approved','closed','reopened'))=(approved_at is not null)),
 check((status in ('closed','reopened'))=(closed_at is not null)),
 check((status='reopened')=(reopened_at is not null))
);
create table if not exists public.accounting_close_checks(
 id uuid primary key default gen_random_uuid(), close_run_id uuid not null references public.accounting_close_runs(id) on delete restrict,
 company_id uuid not null references public.companies(id) on delete cascade,
 check_code text not null, blocking boolean not null default true, expected_amount numeric(18,6), actual_amount numeric(18,6), difference numeric(18,6), passed boolean not null, detail jsonb not null default '{}' check(jsonb_typeof(detail)='object'),
 created_at timestamptz not null default now(), unique(close_run_id,check_code)
);
create index if not exists accounting_close_runs_company_period_idx on public.accounting_close_runs(company_id,period_id,status);

create or replace function public.accounting_close_snapshot(p_company_id uuid,p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare p public.accounting_periods%rowtype; v_checks jsonb; v_tb jsonb; v_bs jsonb;
begin
 select * into p from public.accounting_periods where id=p_period_id and company_id=p_company_id;
 if not found then raise exception 'Periodo no pertenece a la empresa.'; end if;
 select jsonb_agg(jsonb_build_object('code',check_code,'blocking',blocking,'expected',expected_amount,'actual',actual_amount,'difference',difference,'passed',passed,'detail',detail) order by check_code)
 into v_checks from (
   with controls as (
    select c.control_key,c.account_id,a.normal_balance,x.amount auxiliary_amount,
      case when a.normal_balance='debit' then coalesce(sum(l.debit-l.credit),0) else coalesce(sum(l.credit-l.debit),0) end ledger_amount,x.detail
    from public.accounting_control_accounts c join public.accounting_accounts a on a.id=c.account_id
    join public.canonical_accounting_auxiliaries(p_company_id,p.ends_on) x on x.control_key=c.control_key
    left join public.accounting_journal_lines l on l.company_id=p_company_id and l.account_id=c.account_id
    left join public.accounting_journal_entries e on e.id=l.journal_entry_id and e.status='posted' and e.entry_date<=p.ends_on
    where c.config_version_id=(select id from public.accounting_config_versions where company_id=p_company_id and status='approved')
    group by c.control_key,c.account_id,a.normal_balance,x.amount,x.detail
   ), checks as (
    select 'control_'||control_key check_code,true blocking,auxiliary_amount expected_amount,ledger_amount actual_amount,round(ledger_amount-auxiliary_amount,6) difference,round(ledger_amount-auxiliary_amount,6)=0 passed,detail from controls
    union all select 'journal_balanced',true,0,coalesce(sum(debit-credit),0),coalesce(sum(debit-credit),0),coalesce(sum(debit-credit),0)=0,jsonb_build_object('basis','pólizas contabilizadas al corte') from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id where l.company_id=p_company_id and e.status='posted' and e.entry_date<=p.ends_on
    union all select 'pending_events',true,0,count(*),count(*),count(*)=0,jsonb_build_object('basis','eventos pendientes al corte') from public.accounting_events where company_id=p_company_id and status='pending' and accounting_date<=p.ends_on
    union all select 'draft_journals',true,0,count(*),count(*),count(*)=0,jsonb_build_object('basis','pólizas borrador al corte') from public.accounting_journal_entries where company_id=p_company_id and status='draft' and entry_date<=p.ends_on
    union all select 'undecided_adjustments',true,0,count(*),count(*),count(*)=0,jsonb_build_object('basis','ajustes enviados sin decisión') from public.accounting_manual_adjustments where company_id=p_company_id and status='submitted' and entry_date<=p.ends_on
    union all select 'bank_pending_reconciliation',true,0,coalesce(sum((detail->>'pending_movements')::numeric),0),coalesce(sum((detail->>'pending_movements')::numeric),0),coalesce(sum((detail->>'pending_movements')::numeric),0)=0,jsonb_build_object('basis','últimos estados promovidos') from public.canonical_accounting_auxiliaries(p_company_id,p.ends_on) where control_key='banks'
   ) select * from checks
 ) q;
 v_tb:=public.list_accounting_report(p_company_id,'trial_balance',p.starts_on,p.ends_on,null,1,1)->'totals';
 v_bs:=public.list_accounting_report(p_company_id,'balance_sheet',p.starts_on,p.ends_on,null,1,1)->'totals';
 -- No incluye reloj: el hash representa evidencia contable, no el instante de consulta.
 return jsonb_build_object('period_id',p.id,'period_code',p.period_code,'starts_on',p.starts_on,'ends_on',p.ends_on,'checks',coalesce(v_checks,'[]'::jsonb),'trial_balance',v_tb,'balance_sheet',v_bs);
end $$;

create or replace function public.prepare_accounting_close(p_company_id uuid,p_period_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_run public.accounting_close_runs%rowtype; v_snapshot jsonb; v_hash text;
begin
 if auth.uid() is null or p_client_request_id is null or not public.has_company_permission(p_company_id,'prepare_accounting_close') then raise exception 'No autorizado para preparar el cierre.'; end if;
 select * into v_run from public.accounting_close_runs where company_id=p_company_id and prepared_request_id=p_client_request_id; if found then return to_jsonb(v_run)||jsonb_build_object('idempotent',true); end if;
 if not exists(select 1 from public.accounting_periods where id=p_period_id and company_id=p_company_id and status='open') then raise exception 'El periodo debe estar abierto.'; end if;
 v_snapshot:=public.accounting_close_snapshot(p_company_id,p_period_id); v_hash:=encode(digest(v_snapshot::text,'sha256'),'hex');
 insert into public.accounting_close_runs(company_id,period_id,snapshot,snapshot_sha256,prepared_request_id) values(p_company_id,p_period_id,v_snapshot,v_hash,p_client_request_id) returning * into v_run;
 insert into public.accounting_close_checks(close_run_id,company_id,check_code,blocking,expected_amount,actual_amount,difference,passed,detail)
 select v_run.id,p_company_id,x->>'code',(x->>'blocking')::boolean,(x->>'expected')::numeric,(x->>'actual')::numeric,(x->>'difference')::numeric,(x->>'passed')::boolean,coalesce(x->'detail','{}'::jsonb) from jsonb_array_elements(v_snapshot->'checks') x;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.close_prepared','accounting_close_run',v_run.id,jsonb_build_object('snapshot_sha256',v_hash,'period_id',p_period_id));
 return to_jsonb(v_run)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.approve_accounting_close(p_close_run_id uuid,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.accounting_close_runs%rowtype;
begin
 select * into v_run from public.accounting_close_runs where id=p_close_run_id for update;
 if not found or auth.uid() is null or not public.has_company_permission(v_run.company_id,'approve_accounting_close') then raise exception 'Cierre no disponible.'; end if;
 if v_run.approval_request_id=p_client_request_id then return to_jsonb(v_run)||jsonb_build_object('idempotent',true); end if;
 if v_run.status<>'prepared' or v_run.prepared_by=auth.uid() or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'La aprobación exige otra persona, motivo y solicitud única.'; end if;
 update public.accounting_close_runs set status='approved',approved_by=auth.uid(),approved_at=now(),approval_reason=trim(p_reason),approval_request_id=p_client_request_id where id=v_run.id returning * into v_run;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_run.company_id,auth.uid(),'accounting.close_approved','accounting_close_run',v_run.id,jsonb_build_object('reason',trim(p_reason)));
 return to_jsonb(v_run)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.confirm_accounting_close(p_close_run_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_run public.accounting_close_runs%rowtype; v_period public.accounting_periods%rowtype; v_snapshot jsonb; v_hash text;
begin
 select * into v_run from public.accounting_close_runs where id=p_close_run_id for update;
 if not found or auth.uid() is null or not public.has_company_permission(v_run.company_id,'close_accounting_periods') then raise exception 'Cierre no disponible.'; end if;
 if v_run.close_request_id=p_client_request_id then return to_jsonb(v_run)||jsonb_build_object('idempotent',true); end if;
 if v_run.status<>'approved' or p_client_request_id is null then raise exception 'El cierre debe estar aprobado.'; end if;
 select * into v_period from public.accounting_periods where id=v_run.period_id for update; if v_period.status<>'open' then raise exception 'El periodo ya no está abierto.'; end if;
 v_snapshot:=public.accounting_close_snapshot(v_run.company_id,v_run.period_id); v_hash:=encode(digest(v_snapshot::text,'sha256'),'hex');
 if v_hash<>v_run.snapshot_sha256 then raise exception 'La vista previa cambió; recalcule y vuelva a aprobar.'; end if;
 if exists(select 1 from public.accounting_close_checks where close_run_id=v_run.id and blocking and not passed) then raise exception 'Existen diferencias bloqueantes de cierre.'; end if;
 update public.accounting_periods set status='closed',closed_by=auth.uid(),closed_at=now() where id=v_period.id;
 insert into public.accounting_period_events(company_id,period_id,action,reason,actor_id) values(v_run.company_id,v_period.id,'closed','Cierre M4D4 aprobado: '||v_run.id,auth.uid());
 update public.accounting_close_runs set status='closed',closed_by=auth.uid(),closed_at=now(),close_request_id=p_client_request_id where id=v_run.id returning * into v_run;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_run.company_id,auth.uid(),'accounting.close_confirmed','accounting_close_run',v_run.id,jsonb_build_object('snapshot_sha256',v_hash));
 return to_jsonb(v_run)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.reopen_accounting_close(p_close_run_id uuid,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_run public.accounting_close_runs%rowtype; v_period public.accounting_periods%rowtype;
begin
 select * into v_run from public.accounting_close_runs where id=p_close_run_id for update;
 if not found or auth.uid() is null or not public.has_company_permission(v_run.company_id,'reopen_accounting_close') then raise exception 'Cierre no disponible.'; end if;
 if v_run.reopen_request_id=p_client_request_id then return to_jsonb(v_run)||jsonb_build_object('idempotent',true); end if;
 if v_run.status<>'closed' or v_run.closed_by=auth.uid() or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'La reapertura exige otra persona, motivo y solicitud única.'; end if;
 select * into v_period from public.accounting_periods where id=v_run.period_id for update; if v_period.status<>'closed' then raise exception 'El periodo no está cerrado.'; end if;
 update public.accounting_periods set status='open',closed_at=null,reopened_by=auth.uid(),reopened_at=now(),reopen_reason=trim(p_reason) where id=v_period.id;
 insert into public.accounting_period_events(company_id,period_id,action,reason,actor_id) values(v_run.company_id,v_period.id,'reopened',trim(p_reason),auth.uid());
 update public.accounting_close_runs set status='reopened',reopened_by=auth.uid(),reopened_at=now(),reopen_reason=trim(p_reason),reopen_request_id=p_client_request_id where id=v_run.id returning * into v_run;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_run.company_id,auth.uid(),'accounting.close_reopened','accounting_close_run',v_run.id,jsonb_build_object('reason',trim(p_reason)));
 return to_jsonb(v_run)||jsonb_build_object('idempotent',false);
end $$;

-- Consulta oficial consolidada y vistas administrativas por ubicación. El filtro nunca sustituye el consolidado.
create or replace function public.list_financial_report(
 p_company_id uuid,p_report_type text,p_starts_on date,p_ends_on date,p_location_id uuid default null,p_unassigned boolean default false,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_base jsonb; v_rows jsonb; v_total bigint; v_totals jsonb; v_balanced boolean; v_offset int; v_scope text;
begin
 if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_financial_statements') or public.has_company_permission(p_company_id,'view_accounting')) then raise exception 'No autorizado para consultar estados financieros.';end if;
 if p_location_id is not null and not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id) then raise exception 'La ubicación no pertenece a la empresa.';end if;
 if p_location_id is null and not p_unassigned then
   v_base:=public.list_accounting_report(p_company_id,case when p_report_type='enterprise_consolidated' then 'trial_balance' else p_report_type end,p_starts_on,p_ends_on,null,p_page,p_page_size);
   return v_base||jsonb_build_object('scope',case when p_report_type='enterprise_consolidated' then 'official_enterprise_consolidated' else 'official_enterprise_consolidated' end,'location_id',null,'location_label','Consolidado empresarial');
 end if;
 p_page:=greatest(coalesce(p_page,1),1);p_page_size:=least(greatest(coalesce(p_page_size,50),1),200);v_offset:=(p_page-1)*p_page_size;v_scope:='administrative_location_filter';
 select count(*) into v_total from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id
 where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on
   and ((p_location_id is not null and l.location_id=p_location_id) or (p_unassigned and l.location_id is null));
 with rows as materialized (
  select e.entry_date,e.entry_number,a.id account_id,a.code,a.name,a.account_type,a.normal_balance,l.location_id,coalesce(loc.name,'Sin asignar') location_label,l.line_number,l.description,l.debit,l.credit
  from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id join public.accounting_accounts a on a.id=l.account_id left join public.locations loc on loc.id=l.location_id
  where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on and ((p_location_id is not null and l.location_id=p_location_id) or (p_unassigned and l.location_id is null))
 ) select coalesce(jsonb_agg(to_jsonb(x) order by x.code,x.entry_date,x.entry_number,x.line_number),'[]'::jsonb) into v_rows from (select * from rows order by code,entry_date,entry_number,line_number limit p_page_size offset v_offset)x;
 -- Los totales no dependen de la página.
 select jsonb_build_object('debit',coalesce(sum(l.debit),0),'credit',coalesce(sum(l.credit),0)),coalesce(sum(l.debit-l.credit),0)=0 into v_totals,v_balanced from public.accounting_journal_lines l join public.accounting_journal_entries e on e.id=l.journal_entry_id where l.company_id=p_company_id and e.status='posted' and e.entry_date between p_starts_on and p_ends_on and ((p_location_id is not null and l.location_id=p_location_id) or (p_unassigned and l.location_id is null));
 return jsonb_build_object('report_type',p_report_type,'starts_on',p_starts_on,'ends_on',p_ends_on,'page',p_page,'page_size',p_page_size,'total',v_total,'rows',v_rows,'totals',v_totals,'balanced',v_balanced,'scope',v_scope,'location_id',p_location_id,'location_label',case when p_unassigned then 'Sin asignar' else (select name from public.locations where id=p_location_id) end,'generated_at',clock_timestamp());
end $$;

alter table public.accounting_close_runs enable row level security;
alter table public.accounting_close_checks enable row level security;
create policy accounting_close_runs_read on public.accounting_close_runs for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_close_checks_read on public.accounting_close_checks for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
grant select on public.accounting_close_runs,public.accounting_close_checks to authenticated;
revoke all on function public.accounting_close_snapshot(uuid,uuid),public.prepare_accounting_close(uuid,uuid,uuid),public.approve_accounting_close(uuid,text,uuid),public.confirm_accounting_close(uuid,uuid),public.reopen_accounting_close(uuid,text,uuid),public.list_financial_report(uuid,text,date,date,uuid,boolean,integer,integer) from public,anon;
grant execute on function public.prepare_accounting_close(uuid,uuid,uuid),public.approve_accounting_close(uuid,text,uuid),public.confirm_accounting_close(uuid,uuid),public.reopen_accounting_close(uuid,text,uuid),public.list_financial_report(uuid,text,date,date,uuid,boolean,integer,integer) to authenticated;
