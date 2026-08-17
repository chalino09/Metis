-- Fase 5 final: contrato, paridad con explorador, rechazo y aislamiento.
begin;

do $fixtures$
declare c1 uuid:='81400001-0000-4000-8000-000000000001';c2 uuid:='81400001-0000-4000-8000-000000000002';u uuid:='81400001-0000-4000-8000-000000000003';
begin
  insert into public.companies(id,legal_name,display_name)values(c1,'Contrato BI A','Contrato BI A'),(c2,'Contrato BI B','Contrato BI B');
  insert into auth.users(id,aud,role,email,encrypted_password)values(u,'authenticated','authenticated','bi-contract@example.com','');
  insert into public.user_roles(user_id,role_id,company_id)select u,id,c1 from public.roles where code='direccion_admin';
  insert into public.payroll_periods(company_id,payment_frequency,starts_on,ends_on,payment_date,status,prepared_at,approved_at)
  values(c1,'weekly','2026-01-01','2026-01-07','2026-01-07','approved',now(),now()),(c1,'weekly','2026-01-08','2026-01-14','2026-01-14','approved',now(),now());
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub',u::text,true);
end;$fixtures$;

set local role authenticated;
do $assertions$
declare c1 uuid:='81400001-0000-4000-8000-000000000001';c2 uuid:='81400001-0000-4000-8000-000000000002';catalog jsonb;agent jsonb;human jsonb;blocked boolean:=false;
begin
  perform set_config('request.jwt.claim.role','authenticated',true);perform set_config('request.jwt.claim.sub','81400001-0000-4000-8000-000000000003',true);
  catalog:=public.bi_get_metric_catalog(c1);
  if catalog#>>'{contract,version}'<>'1.0.0'or(catalog#>>'{contract,arbitrary_sql}')::boolean then raise exception'Contrato inválido: %',catalog->'contract';end if;
  if not exists(select 1 from jsonb_array_elements(catalog->'metrics')m where m->>'metric_id'='payroll_runs'and m->>'contract_version'='1.0.0')then raise exception'Falta métrica versionada.';end if;
  human:=public.bi_explorer_query(c1,array['payroll_runs'],'period','bar','2026-01-01','2026-01-31',null,null,null,null,true,1,25);
  agent:=public.bi_query_metric(c1,'{"metric_id":"payroll_runs","period":{"from":"2026-01-01","to":"2026-01-31"},"comparison":"previous_period","granularity":"total","dimensions":["period"],"filters":{},"order":"group_label_asc","page":1,"limit":25}');
  if agent->'series'<>human->'items'then raise exception'Agent y explorador no reconcilian: %, %',agent->'series',human->'items';end if;
  if agent#>>'{quality,state}'<>'complete'or agent->>'definition_version'<>'1.0.0'then raise exception'Respuesta incompleta: %',agent;end if;
  begin perform public.bi_query_metric(c1,'{"metric_id":"payroll_runs","period":{"from":"2026-01-01","to":"2026-01-31"},"granularity":"day","dimensions":["period"]}');exception when others then blocked:=position('Granularidad' in sqlerrm)>0;end;
  if not blocked then raise exception'Se aceptó granularidad incompatible.';end if;
  blocked:=false;begin perform public.bi_query_metric(c2,'{"metric_id":"payroll_runs","period":{"from":"2026-01-01","to":"2026-01-31"},"granularity":"total","dimensions":["period"]}');exception when others then blocked:=position('no disponible' in lower(sqlerrm))>0;end;
  if not blocked then raise exception'Se permitió consulta cruzada.';end if;
  if not exists(select 1 from public.audit_log where company_id=c1 and action='bi.agent_metric_queried'and metadata->>'metric_id'='payroll_runs')then raise exception'Falta auditoría agent.';end if;
end;$assertions$;
reset role;
rollback;
