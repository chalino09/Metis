-- M4B · pólizas manuales limitadas. Volumen esperado: excepcional (decenas/mes),
-- no captura masiva. La solicitud no contabiliza; otra persona debe aprobar.

insert into public.permissions(code,description) values
 ('approve_accounting_adjustments','Aprobar o rechazar pólizas manuales solicitadas por otra persona.'),
 ('reverse_accounting_adjustments','Revertir pólizas manuales mediante una póliza inversa.')
on conflict(code) do update set description=excluded.description;
insert into public.role_permissions(role_id,permission_id) select r.id,p.id from public.roles r cross join public.permissions p where r.code in ('super_admin','direccion_admin') and p.code in ('approve_accounting_adjustments','reverse_accounting_adjustments') on conflict do nothing;

alter table public.accounting_journal_entries add column reversal_of_entry_id uuid unique references public.accounting_journal_entries(id) on delete restrict;

create table public.accounting_manual_adjustments(
 id uuid primary key default gen_random_uuid(),
 company_id uuid not null references public.companies(id) on delete cascade,
 adjustment_type text not null check(adjustment_type in ('reclassification','correction','closing_adjustment')),
 entry_date date not null,description text not null check(nullif(trim(description),'') is not null),
 reason text not null check(nullif(trim(reason),'') is not null),
 status text not null default 'submitted' check(status in ('submitted','approved','rejected','reversed')),
 client_request_id uuid not null,requested_by uuid not null references auth.users(id) on delete restrict,requested_at timestamptz not null default now(),
 decided_by uuid references auth.users(id) on delete set null,decided_at timestamptz,decision_reason text,decision_request_id uuid,
 journal_entry_id uuid unique references public.accounting_journal_entries(id) on delete restrict,
 reversed_by uuid references auth.users(id) on delete set null,reversed_at timestamptz,reversal_reason text,reversal_request_id uuid,
 reversal_entry_id uuid unique references public.accounting_journal_entries(id) on delete restrict,
 unique(company_id,client_request_id),unique(company_id,decision_request_id),unique(company_id,reversal_request_id),
 check((status='submitted' and decided_at is null and journal_entry_id is null) or (status='rejected' and decided_at is not null and journal_entry_id is null) or (status in ('approved','reversed') and decided_at is not null and journal_entry_id is not null)),
 check((status='reversed')=(reversal_entry_id is not null and reversed_at is not null))
);
create table public.accounting_manual_adjustment_lines(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.companies(id) on delete cascade,
 adjustment_id uuid not null references public.accounting_manual_adjustments(id) on delete restrict,
 line_number integer not null check(line_number>0),account_id uuid not null,description text,
 debit numeric(18,6) not null default 0 check(debit>=0),credit numeric(18,6) not null default 0 check(credit>=0),
 foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict,
 unique(adjustment_id,line_number),check((debit>0)<>(credit>0))
);
create index accounting_manual_adjustments_inbox_idx on public.accounting_manual_adjustments(company_id,status,entry_date,id);

create or replace function public.guard_manual_adjustment_immutable()
returns trigger language plpgsql set search_path=public as $$begin raise exception 'La solicitud contable es inmutable; rechace o revierta.';end$$;
create trigger accounting_manual_adjustment_lines_immutable before update or delete on public.accounting_manual_adjustment_lines for each row execute function public.guard_manual_adjustment_immutable();

create or replace function public.submit_accounting_adjustment(p_company_id uuid,p_adjustment_type text,p_entry_date date,p_description text,p_reason text,p_lines jsonb,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_adjustment public.accounting_manual_adjustments%rowtype;v_count int;v_debit numeric;v_credit numeric;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'post_accounting_adjustments') then raise exception 'No autorizado para solicitar ajustes.';end if;
 if p_adjustment_type not in ('reclassification','correction','closing_adjustment') or nullif(trim(coalesce(p_description,'')),'') is null or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 2 and 1000 then raise exception 'Tipo, descripción, motivo, llave y partidas válidas son obligatorios.';end if;
 select * into v_adjustment from public.accounting_manual_adjustments where company_id=p_company_id and client_request_id=p_client_request_id;if found then return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',true);end if;
 if not exists(select 1 from public.accounting_periods where company_id=p_company_id and p_entry_date between starts_on and ends_on and status='open') then raise exception 'La fecha no pertenece a un periodo abierto.';end if;
 insert into public.accounting_manual_adjustments(company_id,adjustment_type,entry_date,description,reason,client_request_id,requested_by) values(p_company_id,p_adjustment_type,p_entry_date,trim(p_description),trim(p_reason),p_client_request_id,auth.uid()) returning * into v_adjustment;
 insert into public.accounting_manual_adjustment_lines(company_id,adjustment_id,line_number,account_id,description,debit,credit) select p_company_id,v_adjustment.id,x.line_number,x.account_id,nullif(trim(x.description),''),coalesce(x.debit,0),coalesce(x.credit,0) from jsonb_to_recordset(p_lines)x(line_number int,account_id uuid,description text,debit numeric,credit numeric) join public.accounting_accounts a on a.id=x.account_id and a.company_id=p_company_id and a.accepts_posting and a.is_active;
 select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0) into v_count,v_debit,v_credit from public.accounting_manual_adjustment_lines where adjustment_id=v_adjustment.id;if v_count<>jsonb_array_length(p_lines) or round(v_debit-v_credit,6)<>0 then raise exception 'La solicitud no cumple cuentas afectables y doble entrada.';end if;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'accounting.adjustment_submitted','accounting_manual_adjustment',v_adjustment.id,jsonb_build_object('type',p_adjustment_type,'lines',v_count,'reason',trim(p_reason)));return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',false);
end$$;

create or replace function public.decide_accounting_adjustment(p_adjustment_id uuid,p_decision text,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_adjustment public.accounting_manual_adjustments%rowtype;v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;v_count int;
begin
 select * into v_adjustment from public.accounting_manual_adjustments where id=p_adjustment_id for update;if not found or auth.uid() is null or not public.has_company_permission(v_adjustment.company_id,'approve_accounting_adjustments') then raise exception 'Solicitud no disponible.';end if;
 if v_adjustment.decision_request_id=p_client_request_id then return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',true);end if;if v_adjustment.status<>'submitted' then raise exception 'La solicitud ya fue decidida.';end if;if auth.uid()=v_adjustment.requested_by then raise exception 'El solicitante no puede aprobar ni rechazar su propio ajuste.';end if;if p_decision not in ('approve','reject') or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Decisión, motivo y llave son obligatorios.';end if;
 if p_decision='reject' then update public.accounting_manual_adjustments set status='rejected',decided_by=auth.uid(),decided_at=now(),decision_reason=trim(p_reason),decision_request_id=p_client_request_id where id=p_adjustment_id returning * into v_adjustment;insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_adjustment.company_id,auth.uid(),'accounting.adjustment_rejected','accounting_manual_adjustment',v_adjustment.id,jsonb_build_object('reason',p_reason));return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',false);end if;
 select * into v_period from public.accounting_periods where company_id=v_adjustment.company_id and v_adjustment.entry_date between starts_on and ends_on for update;if not found or v_period.status<>'open' then raise exception 'El periodo ya no está abierto.';end if;
 insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id) values(v_adjustment.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),v_adjustment.entry_date,v_adjustment.description,'manual_adjustment','draft',p_client_request_id) returning * into v_entry;
 insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit) select company_id,v_entry.id,line_number,account_id,description,debit,credit from public.accounting_manual_adjustment_lines where adjustment_id=v_adjustment.id order by line_number;get diagnostics v_count=row_count;
 update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),content_sha256=encode(digest((select jsonb_agg(to_jsonb(l) order by line_number)::text from public.accounting_journal_lines l where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id returning * into v_entry;
 update public.accounting_manual_adjustments set status='approved',decided_by=auth.uid(),decided_at=now(),decision_reason=trim(p_reason),decision_request_id=p_client_request_id,journal_entry_id=v_entry.id where id=p_adjustment_id returning * into v_adjustment;insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_adjustment.company_id,auth.uid(),'accounting.adjustment_approved','accounting_manual_adjustment',v_adjustment.id,jsonb_build_object('journal_entry_id',v_entry.id,'lines',v_count,'reason',p_reason));return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',false);
end$$;

create or replace function public.reverse_accounting_adjustment(p_adjustment_id uuid,p_entry_date date,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_adjustment public.accounting_manual_adjustments%rowtype;v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;
begin
 select * into v_adjustment from public.accounting_manual_adjustments where id=p_adjustment_id for update;if not found or auth.uid() is null or not public.has_company_permission(v_adjustment.company_id,'reverse_accounting_adjustments') then raise exception 'Ajuste no disponible.';end if;if v_adjustment.reversal_request_id=p_client_request_id then return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',true);end if;if v_adjustment.status<>'approved' or nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Sólo un ajuste aprobado puede revertirse con motivo y llave.';end if;
 select * into v_period from public.accounting_periods where company_id=v_adjustment.company_id and p_entry_date between starts_on and ends_on for update;if not found or v_period.status<>'open' then raise exception 'La reversa requiere un periodo abierto.';end if;
 insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,client_request_id,reversal_of_entry_id) values(v_adjustment.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),p_entry_date,'Reversa: '||v_adjustment.description,'manual_adjustment','draft',p_client_request_id,v_adjustment.journal_entry_id) returning * into v_entry;
 insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,description,debit,credit) select company_id,v_entry.id,line_number,account_id,coalesce(description,'Reversa'),credit,debit from public.accounting_journal_lines where journal_entry_id=v_adjustment.journal_entry_id order by line_number;
 update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),content_sha256=encode(digest((select jsonb_agg(to_jsonb(l) order by line_number)::text from public.accounting_journal_lines l where journal_entry_id=v_entry.id),'sha256'),'hex') where id=v_entry.id returning * into v_entry;
 update public.accounting_manual_adjustments set status='reversed',reversed_by=auth.uid(),reversed_at=now(),reversal_reason=trim(p_reason),reversal_request_id=p_client_request_id,reversal_entry_id=v_entry.id where id=p_adjustment_id returning * into v_adjustment;insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_adjustment.company_id,auth.uid(),'accounting.adjustment_reversed','accounting_manual_adjustment',v_adjustment.id,jsonb_build_object('original_entry_id',v_adjustment.journal_entry_id,'reversal_entry_id',v_entry.id,'reason',p_reason));return to_jsonb(v_adjustment)||jsonb_build_object('idempotent',false);
end$$;

alter table public.accounting_manual_adjustments enable row level security;alter table public.accounting_manual_adjustment_lines enable row level security;
create policy accounting_manual_adjustments_read on public.accounting_manual_adjustments for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
create policy accounting_manual_adjustment_lines_read on public.accounting_manual_adjustment_lines for select to authenticated using(public.has_company_permission(company_id,'view_accounting'));
grant select on public.accounting_manual_adjustments,public.accounting_manual_adjustment_lines to authenticated;
revoke all on function public.post_accounting_adjustment(uuid,date,text,jsonb,uuid) from authenticated;
revoke all on function public.submit_accounting_adjustment(uuid,text,date,text,text,jsonb,uuid),public.decide_accounting_adjustment(uuid,text,text,uuid),public.reverse_accounting_adjustment(uuid,date,text,uuid) from public,anon;
grant execute on function public.submit_accounting_adjustment(uuid,text,date,text,text,jsonb,uuid),public.decide_accounting_adjustment(uuid,text,text,uuid),public.reverse_accounting_adjustment(uuid,date,text,uuid) to authenticated;
