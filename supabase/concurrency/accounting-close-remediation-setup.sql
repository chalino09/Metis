begin;

create table public.accounting_close_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  status text not null,
  prepared_at timestamptz not null default now()
);

create table public.accounting_close_checks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  close_run_id uuid not null references public.accounting_close_runs(id),
  status text not null,
  created_at timestamptz not null default now()
);

create function public.prepare_accounting_close(uuid, uuid)
returns jsonb language sql as $$ select '{}'::jsonb $$;
create function public.approve_accounting_close(uuid, text)
returns jsonb language sql as $$ select '{}'::jsonb $$;
create function public.canonical_accounting_close_auxiliaries(uuid, date)
returns table(auxiliary_type text, amount numeric, detail jsonb)
language sql as $$ select null::text, 0::numeric, '{}'::jsonb where false $$;

with inserted_run as (
  insert into public.accounting_close_runs(status)
  values ('preview')
  returning id
)
insert into public.accounting_close_checks(close_run_id, status)
select id, 'blocking'
from inserted_run;
