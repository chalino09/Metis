do $$begin
 if (select count(*) from public.accounting_journal_entries where company_id='4d100000-0000-4000-8000-000000000001')<>1 then raise exception 'La consulta concurrente alteró pólizas.';end if;
 if to_regprocedure('public.list_accounting_report(uuid,text,date,date,uuid,integer,integer)') is null then raise exception 'Falta reporte canónico.';end if;
end$$;
