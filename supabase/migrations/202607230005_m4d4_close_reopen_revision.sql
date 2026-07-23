-- M4D4: una reapertura conserva el cierre anterior y habilita una nueva corrida.
-- Sólo puede existir una corrida activa por periodo; las cerradas/reabiertas son evidencia histórica.

alter table public.accounting_close_runs drop constraint if exists accounting_close_runs_company_id_period_id_key;
create unique index if not exists accounting_close_runs_one_active_period_idx
  on public.accounting_close_runs(company_id,period_id)
  where status in ('prepared','approved');
