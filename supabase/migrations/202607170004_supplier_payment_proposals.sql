-- Satrapy · M3E1: vencimientos y propuestas de pago.
-- Una propuesta es una instrucción interna; nunca crea pagos ni aplicaciones y nunca
-- modifica facturas, inventario, costos o saldos de cuentas por pagar.

insert into public.permissions(code,description) values
  ('prepare_supplier_payment_proposals','Preparar y enviar propuestas de pago a proveedores.'),
  ('approve_supplier_payment_proposals','Aprobar o rechazar propuestas de pago a proveedores.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'prepare_supplier_payment_proposals','approve_supplier_payment_proposals'
) on conflict do nothing;

create table public.supplier_payment_proposals(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  status text not null default 'draft' check(status in ('draft','submitted','approved','rejected','cancelled')),
  total_proposed numeric(18,6) not null default 0 check(total_proposed>=0),
  submitted_at timestamptz,
  submitted_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  rejected_at timestamptz,
  rejected_by uuid references auth.users(id) on delete set null,
  rejection_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  cancellation_reason text,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((status='submitted')=(submitted_at is not null) or status in ('approved','rejected','cancelled')),
  check((status='approved')=(approved_at is not null)),
  check((status='rejected')=(rejected_at is not null)),
  check((status='cancelled')=(cancelled_at is not null)),
  check(status<>'rejected' or nullif(trim(coalesce(rejection_reason,'')),'') is not null),
  check(status<>'cancelled' or nullif(trim(coalesce(cancellation_reason,'')),'') is not null)
);
create index supplier_payment_proposals_inbox_idx on public.supplier_payment_proposals(company_id,status,created_at desc,id desc);
create index supplier_payment_proposals_supplier_idx on public.supplier_payment_proposals(company_id,supplier_id,currency_code,status,created_at desc,id desc);
create trigger supplier_payment_proposals_updated_at before update on public.supplier_payment_proposals for each row execute function public.set_updated_at();

create table public.supplier_payment_proposal_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  proposal_id uuid not null references public.supplier_payment_proposals(id) on delete cascade,
  accounts_payable_id uuid not null references public.accounts_payable(id) on delete restrict,
  proposed_amount numeric(18,6) not null check(proposed_amount>0),
  balance_snapshot numeric(18,6) not null check(balance_snapshot>0),
  projected_balance_snapshot numeric(18,6) generated always as (round(balance_snapshot-proposed_amount,6)) stored,
  due_date_snapshot date not null,
  created_at timestamptz not null default now(),
  unique(proposal_id,accounts_payable_id),
  check(proposed_amount<=balance_snapshot)
);
create index supplier_payment_proposal_lines_payable_idx on public.supplier_payment_proposal_lines(company_id,accounts_payable_id,proposal_id);

create table public.supplier_payment_proposal_requests(
  company_id uuid not null references public.companies(id) on delete cascade,
  request_id uuid not null,
  proposal_id uuid not null references public.supplier_payment_proposals(id) on delete cascade,
  operation text not null check(operation in ('save','submit','approve','reject','cancel')),
  result jsonb not null,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key(company_id,request_id)
);

create or replace function public.guard_supplier_payment_proposal_line_mutation()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;v_company uuid;
begin
  select status,company_id into v_status,v_company from public.supplier_payment_proposals where id=coalesce(new.proposal_id,old.proposal_id);
  if v_status is distinct from 'draft' then raise exception 'Sólo un borrador permite modificar sus CxP.';end if;
  if tg_op<>'DELETE' and new.company_id<>v_company then raise exception 'La partida no pertenece a la empresa de la propuesta.';end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger guard_supplier_payment_proposal_line_mutation before insert or update or delete on public.supplier_payment_proposal_lines for each row execute function public.guard_supplier_payment_proposal_line_mutation();

alter table public.supplier_payment_proposals enable row level security;
alter table public.supplier_payment_proposal_lines enable row level security;
alter table public.supplier_payment_proposal_requests enable row level security;

create policy supplier_payment_proposals_read on public.supplier_payment_proposals for select to authenticated using(
  public.has_company_permission(company_id,'view_accounts_payable') and
  (public.has_company_permission(company_id,'prepare_supplier_payment_proposals') or public.has_company_permission(company_id,'approve_supplier_payment_proposals'))
);
create policy supplier_payment_proposal_lines_read on public.supplier_payment_proposal_lines for select to authenticated using(
  public.has_company_permission(company_id,'view_accounts_payable') and
  (public.has_company_permission(company_id,'prepare_supplier_payment_proposals') or public.has_company_permission(company_id,'approve_supplier_payment_proposals'))
);
-- Las llaves de idempotencia son internas y no se exponen por RLS.

create or replace function public.search_supplier_payable_due_inbox(
  p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_currency_code text default null,
  p_due_bucket text default null,p_due_from date default null,p_due_to date default null,
  p_min_balance numeric default null,p_max_balance numeric default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then raise exception 'No autorizado para consultar vencimientos de CxP.';end if;
  if p_due_bucket is not null and p_due_bucket not in ('overdue','upcoming','future') then raise exception 'Clasificación de vencimiento inválida.';end if;
  if p_due_from is not null and p_due_to is not null and p_due_from>p_due_to then raise exception 'Rango de vencimiento inválido.';end if;
  if p_min_balance is not null and p_min_balance<0 or p_max_balance is not null and p_max_balance<0 or p_min_balance is not null and p_max_balance is not null and p_min_balance>p_max_balance then raise exception 'Rango de saldo inválido.';end if;
  with filtered as materialized(
    select ap.id,ap.supplier_id,s.code supplier_code,s.display_name supplier_name,ap.supplier_invoice_id,
      concat_ws('-',si.series,si.folio) invoice_number,ap.currency_code,ap.original_amount,ap.outstanding_amount,
      ap.issued_date,ap.due_date,
      case when ap.due_date<current_date then 'overdue' when ap.due_date<=current_date+15 then 'upcoming' else 'future' end due_bucket
    from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id
    where ap.company_id=p_company_id and ap.reversed_at is null and ap.outstanding_amount>0
      and (p_supplier_id is null or ap.supplier_id=p_supplier_id)
      and (p_currency_code is null or ap.currency_code=upper(trim(p_currency_code)))
      and (p_due_from is null or ap.due_date>=p_due_from) and (p_due_to is null or ap.due_date<=p_due_to)
      and (p_min_balance is null or ap.outstanding_amount>=p_min_balance) and (p_max_balance is null or ap.outstanding_amount<=p_max_balance)
      and (p_due_bucket is null or case when ap.due_date<current_date then 'overdue' when ap.due_date<=current_date+15 then 'upcoming' else 'future' end=p_due_bucket)
      and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
  )
  select count(*) into v_total from filtered;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date,x.id),'[]'::jsonb) into v_items from (
    select * from (
      select ap.id,ap.supplier_id,s.code supplier_code,s.display_name supplier_name,ap.supplier_invoice_id,
        concat_ws('-',si.series,si.folio) invoice_number,ap.currency_code,ap.original_amount,ap.outstanding_amount,
        ap.issued_date,ap.due_date,
        case when ap.due_date<current_date then 'overdue' when ap.due_date<=current_date+15 then 'upcoming' else 'future' end due_bucket
      from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id
      where ap.company_id=p_company_id and ap.reversed_at is null and ap.outstanding_amount>0
        and (p_supplier_id is null or ap.supplier_id=p_supplier_id)
        and (p_currency_code is null or ap.currency_code=upper(trim(p_currency_code)))
        and (p_due_from is null or ap.due_date>=p_due_from) and (p_due_to is null or ap.due_date<=p_due_to)
        and (p_min_balance is null or ap.outstanding_amount>=p_min_balance) and (p_max_balance is null or ap.outstanding_amount<=p_max_balance)
        and (p_due_bucket is null or case when ap.due_date<current_date then 'overdue' when ap.due_date<=current_date+15 then 'upcoming' else 'future' end=p_due_bucket)
        and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
      order by ap.due_date,ap.id limit v_size offset(v_page-1)*v_size
    ) q
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'upcoming_through',current_date+15);
end $$;

create or replace function public.save_supplier_payment_proposal(
  p_company_id uuid,p_proposal_id uuid,p_supplier_id uuid,p_currency_code text,p_lines jsonb,
  p_client_request_id uuid,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_proposal_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_payable public.accounts_payable%rowtype;v_line jsonb;v_id uuid;v_amount numeric;v_total numeric:=0;v_result jsonb;v_distinct int;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') then raise exception 'No autorizado para preparar propuestas de pago.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_proposal_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then
    if v_existing.operation<>'save' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;
    return v_existing.result||jsonb_build_object('idempotent',true);
  end if;
  if upper(trim(coalesce(p_currency_code,'')))!~'^[A-Z]{3}$' then raise exception 'Moneda inválida.';end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La propuesta requiere al menos una CxP.';end if;
  select count(distinct value->>'accounts_payable_id') into v_distinct from jsonb_array_elements(p_lines);
  if v_distinct<>jsonb_array_length(p_lines) then raise exception 'Una CxP no puede repetirse en la propuesta.';end if;
  if p_proposal_id is null then
    v_id:=gen_random_uuid();
    insert into public.supplier_payment_proposals(id,company_id,supplier_id,currency_code) values(v_id,p_company_id,p_supplier_id,upper(trim(p_currency_code)));
  else
    select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
    if not found or v_proposal.status<>'draft' then raise exception 'Borrador de propuesta no disponible.';end if;
    if p_expected_updated_at is not null and v_proposal.updated_at<>p_expected_updated_at then raise exception 'La propuesta cambió; recargue antes de guardar.';end if;
    v_id:=v_proposal.id;
    update public.supplier_payment_proposals set supplier_id=p_supplier_id,currency_code=upper(trim(p_currency_code)),updated_by=auth.uid() where id=v_id;
    delete from public.supplier_payment_proposal_lines where proposal_id=v_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    begin v_amount:=(v_line->>'proposed_amount')::numeric;exception when others then raise exception 'Importe propuesto inválido.';end;
    select * into v_payable from public.accounts_payable where id=(v_line->>'accounts_payable_id')::uuid and company_id=p_company_id for update;
    if not found or v_payable.reversed_at is not null or v_payable.outstanding_amount<=0 then raise exception 'CxP no disponible para propuesta.';end if;
    if v_payable.supplier_id<>p_supplier_id or v_payable.currency_code<>upper(trim(p_currency_code)) then raise exception 'Todas las CxP deben pertenecer al mismo proveedor y moneda.';end if;
    if v_amount<=0 or v_amount>v_payable.outstanding_amount then raise exception 'El importe propuesto debe ser positivo y no superar el saldo actual.';end if;
    insert into public.supplier_payment_proposal_lines(company_id,proposal_id,accounts_payable_id,proposed_amount,balance_snapshot,due_date_snapshot)
    values(p_company_id,v_id,v_payable.id,v_amount,v_payable.outstanding_amount,v_payable.due_date);
    v_total:=v_total+v_amount;
  end loop;
  update public.supplier_payment_proposals set total_proposed=round(v_total,6),updated_by=auth.uid() where id=v_id returning * into v_proposal;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_proposal_id is null then 'supplier_payment_proposal.created' else 'supplier_payment_proposal.updated' end,'supplier_payment_proposal',v_id,jsonb_build_object('supplier_id',p_supplier_id,'currency_code',upper(trim(p_currency_code)),'line_count',jsonb_array_length(p_lines),'total_proposed',v_total,'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_id,'status','draft','total_proposed',round(v_total,6),'updated_at',v_proposal.updated_at,'idempotent',false);
  insert into public.supplier_payment_proposal_requests(company_id,request_id,proposal_id,operation,result) values(p_company_id,p_client_request_id,v_id,'save',v_result);
  return v_result;
end $$;

create or replace function public.submit_supplier_payment_proposal(p_company_id uuid,p_proposal_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_proposal_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') then raise exception 'No autorizado para enviar propuestas de pago.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_proposal_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then if v_existing.operation<>'submit' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;return v_existing.result||jsonb_build_object('idempotent',true);end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status<>'draft' or not exists(select 1 from public.supplier_payment_proposal_lines where proposal_id=p_proposal_id) then raise exception 'Borrador de propuesta no disponible.';end if;
  if exists(select 1 from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id where l.proposal_id=p_proposal_id and (ap.company_id<>p_company_id or ap.supplier_id<>v_proposal.supplier_id or ap.currency_code<>v_proposal.currency_code or ap.reversed_at is not null or ap.outstanding_amount<l.proposed_amount)) then raise exception 'Una CxP cambió o ya no cubre el importe propuesto.';end if;
  update public.supplier_payment_proposals set status='submitted',submitted_at=now(),submitted_by=auth.uid(),updated_by=auth.uid() where id=p_proposal_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_payment_proposal.submitted','supplier_payment_proposal',p_proposal_id,jsonb_build_object('total_proposed',v_proposal.total_proposed,'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',p_proposal_id,'status','submitted','idempotent',false);
  insert into public.supplier_payment_proposal_requests(company_id,request_id,proposal_id,operation,result) values(p_company_id,p_client_request_id,p_proposal_id,'submit',v_result);
  return v_result;
end $$;

create or replace function public.decide_supplier_payment_proposal(p_company_id uuid,p_proposal_id uuid,p_decision text,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_proposal_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_result jsonb;v_operation text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'approve_supplier_payment_proposals') then raise exception 'No autorizado para decidir propuestas de pago.';end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decisión inválida.';end if;
  if p_decision='rejected' and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El rechazo requiere motivo.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  v_operation:=case when p_decision='approved' then 'approve' else 'reject' end;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_proposal_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then if v_existing.operation<>v_operation then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;return v_existing.result||jsonb_build_object('idempotent',true);end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status<>'submitted' then raise exception 'Propuesta en aprobación no disponible.';end if;
  if p_decision='approved' and exists(select 1 from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id where l.proposal_id=p_proposal_id and (ap.company_id<>p_company_id or ap.supplier_id<>v_proposal.supplier_id or ap.currency_code<>v_proposal.currency_code or ap.reversed_at is not null or ap.outstanding_amount<l.proposed_amount)) then raise exception 'Una CxP cambió o ya no cubre el importe propuesto.';end if;
  if p_decision='approved' then
    update public.supplier_payment_proposals set status='approved',approved_at=now(),approved_by=auth.uid(),updated_by=auth.uid() where id=p_proposal_id;
  else
    update public.supplier_payment_proposals set status='rejected',rejected_at=now(),rejected_by=auth.uid(),rejection_reason=trim(p_reason),updated_by=auth.uid() where id=p_proposal_id;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_payment_proposal.'||p_decision,'supplier_payment_proposal',p_proposal_id,jsonb_build_object('reason',nullif(trim(coalesce(p_reason,'')),''),'total_proposed',v_proposal.total_proposed,'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',p_proposal_id,'status',p_decision,'idempotent',false);
  insert into public.supplier_payment_proposal_requests(company_id,request_id,proposal_id,operation,result) values(p_company_id,p_client_request_id,p_proposal_id,v_operation,v_result);
  return v_result;
end $$;

create or replace function public.cancel_supplier_payment_proposal(p_company_id uuid,p_proposal_id uuid,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_proposal_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') then raise exception 'No autorizado para cancelar propuestas de pago.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La cancelación requiere motivo.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_proposal_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then if v_existing.operation<>'cancel' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;return v_existing.result||jsonb_build_object('idempotent',true);end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status not in ('draft','submitted') then raise exception 'Propuesta no disponible para cancelación.';end if;
  update public.supplier_payment_proposals set status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim(p_reason),updated_by=auth.uid() where id=p_proposal_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_payment_proposal.cancelled','supplier_payment_proposal',p_proposal_id,jsonb_build_object('reason',trim(p_reason),'previous_status',v_proposal.status,'total_proposed',v_proposal.total_proposed,'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',p_proposal_id,'status','cancelled','idempotent',false);
  insert into public.supplier_payment_proposal_requests(company_id,request_id,proposal_id,operation,result) values(p_company_id,p_client_request_id,p_proposal_id,'cancel',v_result);
  return v_result;
end $$;

create or replace function public.search_supplier_payment_proposals(p_company_id uuid,p_status text default null,p_supplier_id uuid default null,p_currency_code text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') or not (public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') or public.has_company_permission(p_company_id,'approve_supplier_payment_proposals')) then raise exception 'No autorizado para consultar propuestas de pago.';end if;
  select count(*) into v_total from public.supplier_payment_proposals p where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code)));
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc),'[]'::jsonb) into v_items from (
    select p.id,p.supplier_id,s.code supplier_code,s.display_name supplier_name,p.currency_code,p.status,p.total_proposed,p.created_by,p.created_at,p.updated_at,p.submitted_at,p.approved_at,p.rejected_at,p.cancelled_at,count(l.id) line_count
    from public.supplier_payment_proposals p join public.suppliers s on s.id=p.supplier_id left join public.supplier_payment_proposal_lines l on l.proposal_id=p.id
    where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code)))
    group by p.id,s.id order by p.created_at desc,p.id desc limit v_size offset(v_page-1)*v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_supplier_payment_proposal_detail(p_company_id uuid,p_proposal_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') or not (public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals') or public.has_company_permission(p_company_id,'approve_supplier_payment_proposals')) then raise exception 'No autorizado para consultar propuestas de pago.';end if;
  select to_jsonb(p)||jsonb_build_object(
    'supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name),
    'lines',(select coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('supplier_invoice_id',ap.supplier_invoice_id,'invoice_number',concat_ws('-',si.series,si.folio),'issued_date',ap.issued_date,'due_date',ap.due_date,'current_balance',ap.outstanding_amount,'projected_balance',round(ap.outstanding_amount-l.proposed_amount,6),'payable_reversed_at',ap.reversed_at) order by ap.due_date,ap.id),'[]'::jsonb) from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id join public.supplier_invoices si on si.id=ap.supplier_invoice_id where l.proposal_id=p.id),
    'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at,a.id),'[]'::jsonb) from public.audit_log a where a.company_id=p_company_id and a.entity_type='supplier_payment_proposal' and a.entity_id=p.id)
  ) into v_result from public.supplier_payment_proposals p join public.suppliers s on s.id=p.supplier_id where p.id=p_proposal_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Propuesta no encontrada.';end if;
  return v_result;
end $$;

revoke all on function public.search_supplier_payable_due_inbox(uuid,text,uuid,text,text,date,date,numeric,numeric,integer,integer) from public;
revoke all on function public.save_supplier_payment_proposal(uuid,uuid,uuid,text,jsonb,uuid,timestamptz) from public;
revoke all on function public.submit_supplier_payment_proposal(uuid,uuid,uuid) from public;
revoke all on function public.decide_supplier_payment_proposal(uuid,uuid,text,text,uuid) from public;
revoke all on function public.cancel_supplier_payment_proposal(uuid,uuid,text,uuid) from public;
revoke all on function public.search_supplier_payment_proposals(uuid,text,uuid,text,integer,integer) from public;
revoke all on function public.get_supplier_payment_proposal_detail(uuid,uuid) from public;
grant execute on function public.search_supplier_payable_due_inbox(uuid,text,uuid,text,text,date,date,numeric,numeric,integer,integer) to authenticated;
grant execute on function public.save_supplier_payment_proposal(uuid,uuid,uuid,text,jsonb,uuid,timestamptz) to authenticated;
grant execute on function public.submit_supplier_payment_proposal(uuid,uuid,uuid) to authenticated;
grant execute on function public.decide_supplier_payment_proposal(uuid,uuid,text,text,uuid) to authenticated;
grant execute on function public.cancel_supplier_payment_proposal(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.search_supplier_payment_proposals(uuid,text,uuid,text,integer,integer) to authenticated;
grant execute on function public.get_supplier_payment_proposal_detail(uuid,uuid) to authenticated;
