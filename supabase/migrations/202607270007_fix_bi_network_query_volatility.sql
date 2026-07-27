-- BI Fase 6 · La consulta registra auditoría, por lo que debe ser VOLATILE.
-- Este parche corrige entornos donde 202607270006 ya fue aplicada.

alter function public.bi_dependency_network_query(
  uuid,date,date,uuid,uuid,uuid,uuid,text[],text,text,text,text,text,text,text,uuid,integer,integer,integer
) volatile;

alter function public.bi_dependency_network_drilldown(
  uuid,text,uuid,uuid,date,date,integer,integer
) volatile;
