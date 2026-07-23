begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

select hasnt_table('public', 'accounting_close_runs', 'M4D1 leaves no enterprise-close runs');
select hasnt_table('public', 'accounting_close_checks', 'M4D1 leaves no enterprise-close checks');
select hasnt_function('public', 'prepare_accounting_close', array['uuid', 'uuid'], 'M4D1 leaves no prepare-close RPC');
select hasnt_function('public', 'approve_accounting_close', array['uuid', 'text'], 'M4D1 leaves no approve-close RPC');
select hasnt_function('public', 'canonical_accounting_close_auxiliaries', array['uuid', 'date'], 'M4D1 leaves no premature close auxiliaries');

select * from finish();
rollback;
